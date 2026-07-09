package transport

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/cc-collaboration/pkg/todoschema"
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
	seen := make(chan string, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- r.RequestURI
		w.Header().Set("X-Content-Sha256", "")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("content"))
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	if err := client.UploadTodoAttachment(context.Background(), "td/1#frag", "screenshots/fix #1.png", []byte("content")); err != nil {
		t.Fatal(err)
	}
	if _, err := client.FetchTodoAttachment(context.Background(), "td/1#frag", "screenshots/fix #1.png"); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 2; i++ {
		got := <-seen
		if !strings.Contains(got, "/v1/todos/td%2F1%23frag/attachments/screenshots%2Ffix%20%231.png") {
			t.Fatalf("request URI = %q, want escaped todo id and attachment name", got)
		}
	}
}

func TestTodoIDPathSegmentsAreEscaped(t *testing.T) {
	seen := make(chan string, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- r.RequestURI
		w.WriteHeader(http.StatusOK)
		if strings.HasSuffix(r.URL.Path, "/comments") {
			_, _ = w.Write([]byte(`{"comments":[]}`))
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	ctx := context.Background()
	id := "td/team#1"
	if _, err := client.GetTodo(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := client.PatchTodo(ctx, id, TodoPatch{}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.SetTodoStatus(ctx, id, todoschema.StatusInProgress); err != nil {
		t.Fatal(err)
	}
	if _, err := client.AssignTodo(ctx, id, "owner@team", "ts1", "label", "agent1", "/tmp/repo", "codex"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.RecurAdvanceTodo(ctx, id); err != nil {
		t.Fatal(err)
	}
	if err := client.DeleteTodo(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := client.CommentTodo(ctx, id, "body"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ListTodoComments(ctx, id); err != nil {
		t.Fatal(err)
	}

	want := []string{
		"/v1/todos/td%2Fteam%231",
		"/v1/todos/td%2Fteam%231",
		"/v1/todos/td%2Fteam%231/status",
		"/v1/todos/td%2Fteam%231/assign",
		"/v1/todos/td%2Fteam%231/recur-advance",
		"/v1/todos/td%2Fteam%231",
		"/v1/todos/td%2Fteam%231/comment",
		"/v1/todos/td%2Fteam%231/comments",
	}
	for _, wantURI := range want {
		if got := <-seen; got != wantURI {
			t.Fatalf("request URI = %q, want %q", got, wantURI)
		}
	}
}
