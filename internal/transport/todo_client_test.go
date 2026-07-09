package transport

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestListTodosEncodesEveryQueryParam(t *testing.T) {
	seen := make(chan map[string]string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/todos" {
			t.Errorf("path = %q, want /v1/todos", r.URL.Path)
		}
		q := r.URL.Query()
		seen <- map[string]string{
			"scope":   q.Get("scope"),
			"project": q.Get("project"),
			"status":  q.Get("status"),
			"group":   q.Get("group"),
			"limit":   q.Get("limit"),
			"extra":   q.Get("x"),
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"items":[]}`))
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	_, err := client.ListTodos(context.Background(), TodoListFilter{
		Scope:     "project+team",
		ProjectID: "p1&x=wrong",
		Status:    "todo+review",
		GroupName: "sprint 1 & urgent",
		Limit:     25,
	})
	if err != nil {
		t.Fatal(err)
	}

	got := <-seen
	want := map[string]string{
		"scope":   "project+team",
		"project": "p1&x=wrong",
		"status":  "todo+review",
		"group":   "sprint 1 & urgent",
		"limit":   "25",
		"extra":   "",
	}
	for k, wantValue := range want {
		if got[k] != wantValue {
			t.Fatalf("query %s = %q, want %q (all params: %#v)", k, got[k], wantValue, got)
		}
	}
}

func TestFetchTodoAttachmentEscapesAttachmentName(t *testing.T) {
	seen := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- r.RequestURI
		w.Header().Set("X-Content-Sha256", "")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("content"))
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	if _, err := client.FetchTodoAttachment(context.Background(), "td1", "screenshots/fix #1.png"); err != nil {
		t.Fatal(err)
	}

	got := <-seen
	if !strings.Contains(got, "/v1/todos/td1/attachments/screenshots%2Ffix%20%231.png") {
		t.Fatalf("request URI = %q, want escaped attachment name", got)
	}
}
