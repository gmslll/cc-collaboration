package transport

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestListHandoffsEncodesRecipientQuery(t *testing.T) {
	seen := make(chan map[string]string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		seen <- map[string]string{
			"recipient": q.Get("recipient"),
			"extra":     q.Get("x"),
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"items":[]}`))
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	if _, err := client.List(context.Background(), "backend+lead&x=wrong"); err != nil {
		t.Fatal(err)
	}

	got := <-seen
	if got["recipient"] != "backend+lead&x=wrong" || got["extra"] != "" {
		t.Fatalf("query params = %#v", got)
	}
}

func TestHandoffAttachmentEscapesAttachmentName(t *testing.T) {
	seen := make(chan string, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- r.RequestURI
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("content"))
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	if err := client.UploadAttachment(context.Background(), "h1", "screenshots/fix #1.png", []byte("content")); err != nil {
		t.Fatal(err)
	}
	if _, err := client.FetchAttachment(context.Background(), "h1", "screenshots/fix #1.png"); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 2; i++ {
		got := <-seen
		if !strings.Contains(got, "/v1/handoffs/h1/attachments/screenshots%2Ffix%20%231.png") {
			t.Fatalf("request URI = %q, want escaped attachment name", got)
		}
	}
}

func TestSubscribeEncodesRecipientQuery(t *testing.T) {
	seen := make(chan map[string]string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		seen <- map[string]string{
			"recipient": q.Get("recipient"),
			"extra":     q.Get("x"),
		}
		http.Error(w, "stop", http.StatusTeapot)
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	var lastID uint64
	_ = client.subscribeOnce(context.Background(), client.streamingClient(), "alice+backend&x=wrong", &lastID, func(SSEEvent) error {
		return nil
	})

	got := <-seen
	if got["recipient"] != "alice+backend&x=wrong" || got["extra"] != "" {
		t.Fatalf("query params = %#v", got)
	}
}

func TestListProjectHandoffsEncodesQuery(t *testing.T) {
	seen := make(chan map[string]string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		seen <- map[string]string{
			"scope":   q.Get("scope"),
			"project": q.Get("project"),
			"limit":   q.Get("limit"),
			"extra":   q.Get("x"),
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"items":[]}`))
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	if _, err := client.ListProjectHandoffs(context.Background(), "p1&x=wrong", 25); err != nil {
		t.Fatal(err)
	}

	got := <-seen
	if got["scope"] != "project" || got["project"] != "p1&x=wrong" || got["limit"] != "25" || got["extra"] != "" {
		t.Fatalf("query params = %#v", got)
	}
}
