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
	if err := client.UploadAttachment(context.Background(), "h/1#frag", "screenshots/fix #1.png", []byte("content")); err != nil {
		t.Fatal(err)
	}
	if _, err := client.FetchAttachment(context.Background(), "h/1#frag", "screenshots/fix #1.png"); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 2; i++ {
		got := <-seen
		if !strings.Contains(got, "/v1/handoffs/h%2F1%23frag/attachments/screenshots%2Ffix%20%231.png") {
			t.Fatalf("request URI = %q, want escaped handoff id and attachment name", got)
		}
	}
}

func TestHandoffIDPathSegmentsAreEscaped(t *testing.T) {
	seen := make(chan string, 7)
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
	id := "h/team#1"
	if _, err := client.Get(ctx, id); err != nil {
		t.Fatal(err)
	}
	if err := client.Ack(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Comment(ctx, id, "body"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Status(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Reassign(ctx, id, "next", "reason"); err != nil {
		t.Fatal(err)
	}
	if err := client.Retract(ctx, id, "reason"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ListComments(ctx, id); err != nil {
		t.Fatal(err)
	}

	want := []string{
		"/v1/handoffs/h%2Fteam%231",
		"/v1/handoffs/h%2Fteam%231/ack",
		"/v1/handoffs/h%2Fteam%231/comment",
		"/v1/handoffs/h%2Fteam%231/status",
		"/v1/handoffs/h%2Fteam%231/reassign",
		"/v1/handoffs/h%2Fteam%231/retract",
		"/v1/handoffs/h%2Fteam%231/comments",
	}
	for _, wantURI := range want {
		if got := <-seen; got != wantURI {
			t.Fatalf("request URI = %q, want %q", got, wantURI)
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

func TestProjectAndOrganizationPathIDsAreEscaped(t *testing.T) {
	seen := make(chan string, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- r.RequestURI
		w.WriteHeader(http.StatusOK)
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/projects/"):
			_, _ = w.Write([]byte(`{"project":{"id":"team/a#1","org_id":"org/b#2"},"members":[]}`))
		case strings.HasPrefix(r.URL.Path, "/v1/orgs/"):
			_, _ = w.Write([]byte(`{"members":[]}`))
		default:
			_, _ = w.Write([]byte(`{}`))
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	if _, err := client.ListProjectMembers(context.Background(), "team/a#1"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ListOrganizationMembers(context.Background(), "org/b#2"); err != nil {
		t.Fatal(err)
	}

	projectURI := <-seen
	orgURI := <-seen
	if !strings.Contains(projectURI, "/v1/projects/team%2Fa%231") {
		t.Fatalf("project URI = %q, want escaped project id", projectURI)
	}
	if !strings.Contains(orgURI, "/v1/orgs/org%2Fb%232") {
		t.Fatalf("org URI = %q, want escaped org id", orgURI)
	}
}
