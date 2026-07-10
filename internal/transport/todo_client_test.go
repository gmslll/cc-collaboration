package transport

import (
	"context"
	"encoding/json"
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

func TestTodoClientNormalizesTeamFields(t *testing.T) {
	type request struct {
		Method string
		Path   string
		Query  map[string]string
		Body   map[string]string
	}
	seen := make(chan request, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		req := request{
			Method: r.Method,
			Path:   r.URL.Path,
			Query: map[string]string{
				"ref":     r.URL.Query().Get("ref"),
				"project": r.URL.Query().Get("project"),
				"scope":   r.URL.Query().Get("scope"),
				"status":  r.URL.Query().Get("status"),
				"group":   r.URL.Query().Get("group"),
			},
		}
		switch r.URL.Path {
		case "/v1/todos":
			if r.Method == http.MethodPost {
				var body struct {
					ProjectID        string `json:"project_id"`
					Title            string `json:"title"`
					BodyMD           string `json:"body_md"`
					Priority         string `json:"priority"`
					Recurrence       string `json:"recurrence"`
					AssigneeIdentity string `json:"assignee_identity"`
					WorkspaceName    string `json:"workspace_name"`
					RepoName         string `json:"repo_name"`
					GroupName        string `json:"group_name"`
					SourceRef        string `json:"source_ref"`
				}
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Errorf("decode create body: %v", err)
				}
				req.Body = map[string]string{
					"project_id":        body.ProjectID,
					"title":             body.Title,
					"body_md":           body.BodyMD,
					"priority":          body.Priority,
					"recurrence":        body.Recurrence,
					"assignee_identity": body.AssigneeIdentity,
					"workspace_name":    body.WorkspaceName,
					"repo_name":         body.RepoName,
					"group_name":        body.GroupName,
					"source_ref":        body.SourceRef,
				}
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"id":"td1","title":"created"}`))
			} else {
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"items":[]}`))
			}
		case "/v1/todos/by-source":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"found":false}`))
		case "/v1/todos/td1/assign", "/v1/todos/groups/rename", "/v1/todos/groups/clear":
			var body map[string]string
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Errorf("decode body: %v", err)
			}
			req.Body = body
			w.WriteHeader(http.StatusOK)
			if strings.HasSuffix(r.URL.Path, "/assign") {
				_, _ = w.Write([]byte(`{"id":"td1","title":"assigned"}`))
			} else {
				_, _ = w.Write([]byte(`{"ok":true}`))
			}
		case "/v1/todos/groups":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"groups":[]}`))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
		seen <- req
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	ctx := context.Background()
	if _, err := client.CreateTodo(ctx, &todoschema.Todo{
		ProjectID:        " project-1 ",
		Title:            "  keep title padding  ",
		BodyMD:           "  keep body padding  ",
		Priority:         " high ",
		Recurrence:       " weekly ",
		AssigneeIdentity: " dev@x ",
		WorkspaceName:    " Workspace ",
		RepoName:         " Repo ",
		GroupName:        " Sprint ",
		SourceRef:        " linear:ENG-1 ",
	}); err != nil {
		t.Fatal(err)
	}
	req := <-seen
	if req.Body["project_id"] != "project-1" ||
		req.Body["priority"] != "high" ||
		req.Body["recurrence"] != "weekly" ||
		req.Body["assignee_identity"] != "dev@x" ||
		req.Body["workspace_name"] != "Workspace" ||
		req.Body["repo_name"] != "Repo" ||
		req.Body["group_name"] != "Sprint" ||
		req.Body["source_ref"] != "linear:ENG-1" {
		t.Fatalf("create body not normalized: %+v", req.Body)
	}
	if req.Body["title"] != "  keep title padding  " || req.Body["body_md"] != "  keep body padding  " {
		t.Fatalf("create title/body should be preserved: %+v", req.Body)
	}

	if _, err := client.ListTodos(ctx, TodoListFilter{Scope: " project ", ProjectID: " project-1 ", Status: " in_review ", GroupName: " Sprint "}); err != nil {
		t.Fatal(err)
	}
	req = <-seen
	if req.Query["scope"] != "project" || req.Query["project"] != "project-1" || req.Query["status"] != "in_review" || req.Query["group"] != "Sprint" {
		t.Fatalf("list query not normalized: %+v", req.Query)
	}

	if _, _, err := client.FindTodoBySourceRef(ctx, " linear:ENG-1 ", " project-1 "); err != nil {
		t.Fatal(err)
	}
	req = <-seen
	if req.Query["ref"] != "linear:ENG-1" || req.Query["project"] != "project-1" {
		t.Fatalf("by-source query not normalized: %+v", req.Query)
	}

	if _, err := client.AssignTodo(ctx, "td1", "  ", " ts1 ", " codex ", " agent ", " /tmp/repo ", " codex "); err != nil {
		t.Fatal(err)
	}
	req = <-seen
	if req.Body["assignee_identity"] != "" ||
		req.Body["assignee_session_id"] != "" ||
		req.Body["assignee_session_label"] != "" ||
		req.Body["assignee_agent_session_id"] != "" ||
		req.Body["assignee_workdir"] != "" ||
		req.Body["assignee_agent_kind"] != "" {
		t.Fatalf("blank assignee should clear session fields: %+v", req.Body)
	}

	if _, err := client.ListTodoGroups(ctx, " project-1 "); err != nil {
		t.Fatal(err)
	}
	req = <-seen
	if req.Query["project"] != "project-1" {
		t.Fatalf("groups query not normalized: %+v", req.Query)
	}
	if err := client.RenameTodoGroup(ctx, " project-1 ", " Old ", " New "); err != nil {
		t.Fatal(err)
	}
	req = <-seen
	if req.Body["project_id"] != "project-1" || req.Body["old_name"] != "Old" || req.Body["new_name"] != "New" {
		t.Fatalf("rename body not normalized: %+v", req.Body)
	}
	if err := client.ClearTodoGroup(ctx, " project-1 ", " Old "); err != nil {
		t.Fatal(err)
	}
	req = <-seen
	if req.Body["project_id"] != "project-1" || req.Body["name"] != "Old" {
		t.Fatalf("clear body not normalized: %+v", req.Body)
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
