package relay_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/todoschema"
)

// todoTestRig spins up a bare relay (store + tokens + hub) for todo-route
// tests, mirroring attachmentTestRig/projects_test's rig but also returning
// the Hub — SSE fan-out assertions subscribe to it directly rather than
// opening a real /v1/events HTTP stream.
func todoTestRig(t *testing.T) (*httptest.Server, *store.Store, *sse.Hub) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: auth.NewTokens(), Hub: hub}).Handler())
	t.Cleanup(srv.Close)
	return srv, st, hub
}

func patchJSON(t *testing.T, url, bearer string, payload any) (int, []byte) {
	t.Helper()
	b, _ := json.Marshal(payload)
	req, _ := http.NewRequest(http.MethodPatch, url, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	return do(t, req)
}

func patchRawJSON(t *testing.T, url, bearer, payload string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPatch, url, bytes.NewBufferString(payload))
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	return do(t, req)
}

// waitForEventType reads from sub until it sees an event of type wantType,
// skipping anything else — subscribing itself fans out user.online/offline
// presence events to every other subscriber (see Hub.OnPresenceChange), so a
// naive single-recv would flakily catch one of those instead of the
// todo.* event under test.
func waitForEventType(t *testing.T, sub *sse.Subscriber, wantType string, timeout time.Duration) sse.Event {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case ev := <-sub.C():
			if ev.Type == wantType {
				return ev
			}
		case <-deadline:
			t.Fatalf("timed out waiting for event type %q", wantType)
			return sse.Event{}
		}
	}
}

func decodeTodo(t *testing.T, body []byte) todoschema.Todo {
	t.Helper()
	var td todoschema.Todo
	if err := json.Unmarshal(body, &td); err != nil {
		t.Fatalf("decode todo: %v; body=%s", err, body)
	}
	return td
}

func createTodoHTTP(t *testing.T, url, bearer string, payload map[string]any) todoschema.Todo {
	t.Helper()
	code, body := postJSON(t, url+"/v1/todos", bearer, payload)
	if code != http.StatusCreated {
		t.Fatalf("create todo: status=%d body=%s", code, body)
	}
	return decodeTodo(t, body)
}

// --- personal todo: owner-only access ---

func TestTodoPersonalCrossUserForbidden(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "alice@x", "alicepass1")
	mkUser(t, st, "bob@x", "bobpass123")
	aliceTok := loginToken(t, srv.URL, "alice@x", "alicepass1")
	bobTok := loginToken(t, srv.URL, "bob@x", "bobpass123")

	td := createTodoHTTP(t, srv.URL, aliceTok, map[string]any{"title": "buy milk"})

	if code, _ := getAuthed(t, srv.URL+"/v1/todos/"+td.ID, bobTok); code != http.StatusForbidden {
		t.Errorf("stranger GET = %d, want 403", code)
	}
	if code, _ := patchJSON(t, srv.URL+"/v1/todos/"+td.ID, bobTok, map[string]any{"title": "hijacked"}); code != http.StatusForbidden {
		t.Errorf("stranger PATCH = %d, want 403", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/status", bobTok, map[string]any{"status": "done"}); code != http.StatusForbidden {
		t.Errorf("stranger status = %d, want 403", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/comment", bobTok, map[string]any{"body": "nope"}); code != http.StatusForbidden {
		t.Errorf("stranger comment = %d, want 403", code)
	}
	if code, _ := deleteAuthed(t, srv.URL+"/v1/todos/"+td.ID, bobTok); code != http.StatusForbidden {
		t.Errorf("stranger DELETE = %d, want 403", code)
	}

	if code, body := getAuthed(t, srv.URL+"/v1/todos/"+td.ID, aliceTok); code != http.StatusOK {
		t.Fatalf("owner GET = %d %s", code, body)
	}
	if code, _ := deleteAuthed(t, srv.URL+"/v1/todos/"+td.ID, aliceTok); code != http.StatusOK {
		t.Errorf("owner DELETE = %d, want 200", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/todos/"+td.ID, aliceTok); code != http.StatusNotFound {
		t.Errorf("GET deleted todo = %d, want 404", code)
	}
}

// --- team todo: viewer is read-only, member can edit but not delete ---

func TestTodoTeamViewerReadOnly(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "owner@x", "ownerpass1")
	mkUser(t, st, "member@x", "memberpass1")
	mkUser(t, st, "viewer@x", "viewerpass1")
	ownerTok := loginToken(t, srv.URL, "owner@x", "ownerpass1")
	memberTok := loginToken(t, srv.URL, "member@x", "memberpass1")
	viewerTok := loginToken(t, srv.URL, "viewer@x", "viewerpass1")

	proj := createProjectHTTP(t, srv.URL, ownerTok, "Kunlun")

	for _, m := range []struct{ identity, role string }{
		{"member@x", "member"}, {"viewer@x", "viewer"},
	} {
		if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", ownerTok,
			map[string]string{"identity": m.identity, "role": m.role}); code != http.StatusOK {
			t.Fatalf("add member %s: %d", m.identity, code)
		}
	}

	td := createTodoHTTP(t, srv.URL, ownerTok, map[string]any{"title": "ship the release", "project_id": proj.ID})

	if code, _ := getAuthed(t, srv.URL+"/v1/todos/"+td.ID, viewerTok); code != http.StatusOK {
		t.Errorf("viewer GET = %d, want 200", code)
	}
	if code, _ := patchJSON(t, srv.URL+"/v1/todos/"+td.ID, viewerTok, map[string]any{"title": "nope"}); code != http.StatusForbidden {
		t.Errorf("viewer PATCH = %d, want 403", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/status", viewerTok, map[string]any{"status": "in_progress"}); code != http.StatusForbidden {
		t.Errorf("viewer status = %d, want 403", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/comment", viewerTok, map[string]any{"body": "nope"}); code != http.StatusForbidden {
		t.Errorf("viewer comment = %d, want 403", code)
	}

	if code, body := patchJSON(t, srv.URL+"/v1/todos/"+td.ID, memberTok, map[string]any{"title": "ship the release today"}); code != http.StatusOK {
		t.Fatalf("member PATCH = %d %s", code, body)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/comment", memberTok, map[string]any{"body": "on it"}); code != http.StatusCreated {
		t.Errorf("member comment = %d, want 201", code)
	}
	if code, _ := deleteAuthed(t, srv.URL+"/v1/todos/"+td.ID, memberTok); code != http.StatusForbidden {
		t.Errorf("member DELETE = %d, want 403 (edit != delete)", code)
	}
	if code, _ := deleteAuthed(t, srv.URL+"/v1/todos/"+td.ID, ownerTok); code != http.StatusOK {
		t.Errorf("owner DELETE = %d, want 200", code)
	}
}

func TestTodoAssignSessionMustMatchTodoProjectWhenPublished(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "owner@x", "ownerpass1")
	mkUser(t, st, "member@x", "memberpass1")
	ownerTok := loginToken(t, srv.URL, "owner@x", "ownerpass1")
	memberTok := loginToken(t, srv.URL, "member@x", "memberpass1")

	createProject := func(name string) string {
		t.Helper()
		proj := createProjectHTTP(t, srv.URL, ownerTok, name)
		if code, body := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", ownerTok,
			map[string]string{"identity": "member@x", "role": "member"}); code != http.StatusOK {
			t.Fatalf("add member to %q = %d %s", name, code, body)
		}
		return proj.ID
	}
	projectA := createProject("Project A")
	projectB := createProject("Project B")

	if code, body := postJSON(t, srv.URL+"/v1/sessions", memberTok, map[string]any{"sessions": []map[string]string{
		{"id": "same", "label": "same project", "project_id": projectA, "project": "Project A"},
		{"id": "other", "label": "other project", "project_id": projectB, "project": "Project B"},
	}}); code != http.StatusOK {
		t.Fatalf("publish member sessions = %d %s", code, body)
	}

	td := createTodoHTTP(t, srv.URL, ownerTok, map[string]any{"title": "team task", "project_id": projectA})
	if code, body := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/assign", ownerTok, map[string]any{
		"assignee_identity":      "member@x",
		"assignee_session_id":    "same",
		"assignee_session_label": "same project",
	}); code != http.StatusOK {
		t.Fatalf("assign same-project session = %d %s", code, body)
	}

	if code, _ := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/assign", ownerTok, map[string]any{
		"assignee_identity":      "member@x",
		"assignee_session_id":    "other",
		"assignee_session_label": "other project",
	}); code != http.StatusForbidden {
		t.Fatalf("assign cross-project session = %d, want 403", code)
	}

	code, body := getAuthed(t, srv.URL+"/v1/todos/"+td.ID, ownerTok)
	if code != http.StatusOK {
		t.Fatalf("get after rejected assign = %d %s", code, body)
	}
	got := decodeTodo(t, body)
	if got.AssigneeSessionID != "same" {
		t.Fatalf("rejected cross-project assign changed session id to %q", got.AssigneeSessionID)
	}

	if code, body := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/assign", ownerTok, map[string]any{
		"assignee_identity":      "member@x",
		"assignee_session_id":    "legacy-offline-session",
		"assignee_session_label": "manual resume",
	}); code != http.StatusOK {
		t.Fatalf("assign unpublished legacy session = %d %s", code, body)
	}
}

func TestTodoMutationsRejectTrailingJSON(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "alice@x", "alicepass1")
	aliceTok := loginToken(t, srv.URL, "alice@x", "alicepass1")

	if code, body := postRawJSON(t, srv.URL+"/v1/todos", aliceTok,
		`{"title":"bad first"} {"title":"bad second"}`); code != http.StatusBadRequest {
		t.Fatalf("create todo trailing json = %d %s", code, body)
	}
	if code, body := getAuthed(t, srv.URL+"/v1/todos", aliceTok); code != http.StatusOK || bytes.Contains(body, []byte("bad first")) {
		t.Fatalf("trailing create mutated list: code=%d body=%s", code, body)
	}

	td := createTodoHTTP(t, srv.URL, aliceTok, map[string]any{"title": "baseline"})
	if code, body := patchRawJSON(t, srv.URL+"/v1/todos/"+td.ID, aliceTok,
		`{"title":"bad patch"} {"title":"bad second"}`); code != http.StatusBadRequest {
		t.Fatalf("patch todo trailing json = %d %s", code, body)
	}
	if code, body := getAuthed(t, srv.URL+"/v1/todos/"+td.ID, aliceTok); code != http.StatusOK {
		t.Fatalf("get todo after trailing patch = %d %s", code, body)
	} else if got := decodeTodo(t, body); got.Title != "baseline" {
		t.Fatalf("trailing patch changed title: %+v", got)
	}

	if code, body := postRawJSON(t, srv.URL+"/v1/todos/"+td.ID+"/status", aliceTok,
		`{"status":"done"} {"status":"todo"}`); code != http.StatusBadRequest {
		t.Fatalf("status trailing json = %d %s", code, body)
	}
	if code, body := getAuthed(t, srv.URL+"/v1/todos/"+td.ID, aliceTok); code != http.StatusOK {
		t.Fatalf("get todo after trailing status = %d %s", code, body)
	} else if got := decodeTodo(t, body); got.Status != todoschema.StatusTodo {
		t.Fatalf("trailing status changed todo: %+v", got)
	}

	if code, body := postRawJSON(t, srv.URL+"/v1/todos/"+td.ID+"/comment", aliceTok,
		`{"body":"bad comment"} {"body":"bad second"}`); code != http.StatusBadRequest {
		t.Fatalf("comment trailing json = %d %s", code, body)
	}
	if code, body := getAuthed(t, srv.URL+"/v1/todos/"+td.ID+"/comments", aliceTok); code != http.StatusOK || bytes.Contains(body, []byte("bad comment")) {
		t.Fatalf("trailing comment inserted comment: code=%d body=%s", code, body)
	}
}

// --- SSE fan-out: team todo events reach project members plus team managers;
// personal todo events reach only the owner ---

func TestTodoSSEFanOut(t *testing.T) {
	srv, st, hub := todoTestRig(t)
	mkUser(t, st, "owner@x", "ownerpass1")
	mkUser(t, st, "member@x", "memberpass1")
	mkUser(t, st, "org-admin@x", "adminpass1")
	mkUser(t, st, "disabled-admin@x", "disabledpass1")
	mkUser(t, st, "outsider@x", "outsiderpass1")
	ownerTok := loginToken(t, srv.URL, "owner@x", "ownerpass1")

	proj := createProjectHTTP(t, srv.URL, ownerTok, "Kunlun")
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", ownerTok,
		map[string]string{"identity": "member@x", "role": "member"}); code != http.StatusOK {
		t.Fatalf("add member: %d", code)
	}
	p, err := st.GetProject(t.Context(), proj.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(t.Context(), p.OrgID, "org-admin@x", store.OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(t.Context(), p.OrgID, "disabled-admin@x", store.OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	if err := st.SetDisabled(t.Context(), "disabled-admin@x", true); err != nil {
		t.Fatal(err)
	}

	ownerSub, cancelOwner := hub.Subscribe("owner@x")
	defer cancelOwner()
	memberSub, cancelMember := hub.Subscribe("member@x")
	defer cancelMember()
	orgAdminSub, cancelOrgAdmin := hub.Subscribe("org-admin@x")
	defer cancelOrgAdmin()
	disabledAdminSub, cancelDisabledAdmin := hub.Subscribe("disabled-admin@x")
	defer cancelDisabledAdmin()
	outsiderSub, cancelOutsider := hub.Subscribe("outsider@x")
	defer cancelOutsider()

	td := createTodoHTTP(t, srv.URL, ownerTok, map[string]any{"title": "ship the release", "project_id": proj.ID})

	for name, sub := range map[string]*sse.Subscriber{"owner": ownerSub, "member": memberSub, "team admin": orgAdminSub} {
		ev := waitForEventType(t, sub, sse.EventTypeTodoCreated, 2*time.Second)
		got := decodeTodo(t, ev.Data)
		if got.ID != td.ID {
			t.Errorf("%s got todo id %q, want %q", name, got.ID, td.ID)
		}
	}
	for name, sub := range map[string]*sse.Subscriber{"outsider": outsiderSub, "disabled team admin": disabledAdminSub} {
		select {
		case ev := <-sub.C():
			if ev.Type == sse.EventTypeTodoCreated {
				t.Errorf("%s unexpectedly received %q", name, ev.Type)
			}
		case <-time.After(100 * time.Millisecond):
			// expected: no event for inaccessible identities
		}
	}

	// Personal todo: only its owner is targeted.
	memberSub2, cancelMember2 := hub.Subscribe("member@x")
	defer cancelMember2()
	personal := createTodoHTTP(t, srv.URL, ownerTok, map[string]any{"title": "personal errand"})
	ev := waitForEventType(t, ownerSub, sse.EventTypeTodoCreated, 2*time.Second)
	got := decodeTodo(t, ev.Data)
	if got.ID != personal.ID {
		t.Errorf("owner got todo id %q, want %q", got.ID, personal.ID)
	}
	select {
	case ev := <-memberSub2.C():
		if ev.Type == sse.EventTypeTodoCreated {
			t.Errorf("non-owner unexpectedly received personal todo event %q", ev.Type)
		}
	case <-time.After(100 * time.Millisecond):
		// expected
	}
}

// --- attachments: upload/download round trip + view-gated ---

func TestTodoAttachmentRoundTrip(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "alice@x", "alicepass1")
	mkUser(t, st, "bob@x", "bobpass123")
	aliceTok := loginToken(t, srv.URL, "alice@x", "alicepass1")
	bobTok := loginToken(t, srv.URL, "bob@x", "bobpass123")

	td := createTodoHTTP(t, srv.URL, aliceTok, map[string]any{"title": "with photo"})

	content := []byte("fake-png-bytes")
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/todos/"+td.ID+"/attachments/photo.png", bytes.NewReader(content))
	req.Header.Set("Authorization", "Bearer "+aliceTok)
	req.Header.Set("Content-Type", "application/octet-stream")
	code, body := do(t, req)
	if code != http.StatusCreated {
		t.Fatalf("upload = %d %s", code, body)
	}
	var uploadResp struct {
		Name   string `json:"name"`
		SHA256 string `json:"sha256"`
		Size   int    `json:"size"`
	}
	_ = json.Unmarshal(body, &uploadResp)
	if uploadResp.Name != "photo.png" || uploadResp.Size != len(content) || uploadResp.SHA256 == "" {
		t.Fatalf("unexpected upload response: %+v", uploadResp)
	}

	getReq, _ := http.NewRequest(http.MethodGet, srv.URL+"/v1/todos/"+td.ID+"/attachments/photo.png", nil)
	getReq.Header.Set("Authorization", "Bearer "+aliceTok)
	code, dl := do(t, getReq)
	if code != http.StatusOK {
		t.Fatalf("download = %d", code)
	}
	if string(dl) != string(content) {
		t.Fatalf("downloaded content = %q, want %q", dl, content)
	}

	strangerReq, _ := http.NewRequest(http.MethodGet, srv.URL+"/v1/todos/"+td.ID+"/attachments/photo.png", nil)
	strangerReq.Header.Set("Authorization", "Bearer "+bobTok)
	if code, _ := do(t, strangerReq); code != http.StatusForbidden {
		t.Errorf("stranger download = %d, want 403", code)
	}

	// GetTodo reflects the attachment in both count and metadata.
	if code, getBody := getAuthed(t, srv.URL+"/v1/todos/"+td.ID, aliceTok); code == http.StatusOK {
		got := decodeTodo(t, getBody)
		if got.AttachmentCount != 1 || len(got.Attachments) != 1 || got.Attachments[0].Name != "photo.png" {
			t.Errorf("GetTodo attachments not reflected: %+v", got)
		}
	}
}

// --- PATCH due_at: key absent leaves it alone, null clears it, a value sets it ---

func TestTodoPatchDueAtNullVsAbsentHTTP(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "alice@x", "alicepass1")
	aliceTok := loginToken(t, srv.URL, "alice@x", "alicepass1")

	due := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
	td := createTodoHTTP(t, srv.URL, aliceTok, map[string]any{"title": "t", "due_at": due.Format(time.RFC3339)})
	if td.DueAt == nil || !td.DueAt.Equal(due) {
		t.Fatalf("create didn't set due_at: %+v", td.DueAt)
	}

	// Absent key: due_at untouched.
	code, body := patchJSON(t, srv.URL+"/v1/todos/"+td.ID, aliceTok, map[string]any{"title": "t2"})
	if code != http.StatusOK {
		t.Fatalf("patch (absent due_at) = %d %s", code, body)
	}
	got := decodeTodo(t, body)
	if got.DueAt == nil || !got.DueAt.Equal(due) {
		t.Fatalf("absent due_at should be untouched, got %+v", got.DueAt)
	}

	// Explicit null: clears due_at.
	code, body = patchJSON(t, srv.URL+"/v1/todos/"+td.ID, aliceTok, map[string]any{"due_at": nil})
	if code != http.StatusOK {
		t.Fatalf("patch (null due_at) = %d %s", code, body)
	}
	got = decodeTodo(t, body)
	if got.DueAt != nil {
		t.Fatalf("null due_at should clear it, got %+v", got.DueAt)
	}

	// A value: sets due_at.
	newDue := time.Now().Add(48 * time.Hour).UTC().Truncate(time.Second)
	code, body = patchJSON(t, srv.URL+"/v1/todos/"+td.ID, aliceTok, map[string]any{"due_at": newDue.Format(time.RFC3339)})
	if code != http.StatusOK {
		t.Fatalf("patch (set due_at) = %d %s", code, body)
	}
	got = decodeTodo(t, body)
	if got.DueAt == nil || !got.DueAt.Equal(newDue) {
		t.Fatalf("due_at not set, got %+v", got.DueAt)
	}
}

// --- recur-advance: manual "reset now" for a due, recurring, done todo ---

func TestTodoRecurAdvanceHTTP(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "alice@x", "alicepass1")
	aliceTok := loginToken(t, srv.URL, "alice@x", "alicepass1")

	td := createTodoHTTP(t, srv.URL, aliceTok, map[string]any{"title": "water plants", "recurrence": "daily"})

	// Not done yet: recur-advance refuses.
	if code, _ := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/recur-advance", aliceTok, nil); code != http.StatusConflict {
		t.Errorf("recur-advance on non-done todo = %d, want 409", code)
	}

	if code, body := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/status", aliceTok, map[string]any{"status": "done"}); code != http.StatusOK {
		t.Fatalf("set status done = %d %s", code, body)
	}

	code, body := postJSON(t, srv.URL+"/v1/todos/"+td.ID+"/recur-advance", aliceTok, nil)
	if code != http.StatusOK {
		t.Fatalf("recur-advance = %d %s", code, body)
	}
	got := decodeTodo(t, body)
	if got.Status != todoschema.StatusTodo || got.CompletedAt != nil || got.NextOccurrenceAt != nil {
		t.Fatalf("recur-advance didn't reset cleanly: %+v", got)
	}
}

// --- source_ref: import-linear idempotency support (see internal/linear/import.go) ---

func TestCreateTodoSourceRefAndFindBySourceRefHTTP(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "alice@x", "alicepass1")
	mkUser(t, st, "bob@x", "bobpass123")
	aliceTok := loginToken(t, srv.URL, "alice@x", "alicepass1")
	bobTok := loginToken(t, srv.URL, "bob@x", "bobpass123")

	td := createTodoHTTP(t, srv.URL, aliceTok, map[string]any{
		"title":      "Fix the thing",
		"source_ref": "linear:ENG-456",
		"source_url": "https://linear.app/x/issue/ENG-456",
	})
	if td.SourceRef != "linear:ENG-456" || td.SourceURL != "https://linear.app/x/issue/ENG-456" {
		t.Fatalf("createTodo did not persist source_ref/source_url: %+v", td)
	}

	// Missing ref query param is a 400.
	if code, _ := getAuthed(t, srv.URL+"/v1/todos/by-source", aliceTok); code != http.StatusBadRequest {
		t.Errorf("by-source with no ref = %d, want 400", code)
	}

	code, body := getAuthed(t, srv.URL+"/v1/todos/by-source?ref=linear:ENG-456", aliceTok)
	if code != http.StatusOK {
		t.Fatalf("by-source found = %d %s", code, body)
	}
	var found struct {
		Found bool            `json:"found"`
		Todo  todoschema.Todo `json:"todo"`
	}
	if err := json.Unmarshal(body, &found); err != nil {
		t.Fatalf("decode by-source response: %v", err)
	}
	if !found.Found || found.Todo.ID != td.ID {
		t.Fatalf("by-source should find the imported todo: %+v", found)
	}

	// A different, never-imported ref reports found=false, not a 404.
	code, body = getAuthed(t, srv.URL+"/v1/todos/by-source?ref=linear:ENG-999", aliceTok)
	if code != http.StatusOK {
		t.Fatalf("by-source not-found = %d %s", code, body)
	}
	var notFound struct {
		Found bool `json:"found"`
	}
	if err := json.Unmarshal(body, &notFound); err != nil {
		t.Fatalf("decode by-source response: %v", err)
	}
	if notFound.Found {
		t.Fatalf("by-source on unseen ref should report found=false")
	}

	// A stranger can't discover alice's personal todo through by-source either,
	// and should be free to import the same external issue into their own view.
	code, body = getAuthed(t, srv.URL+"/v1/todos/by-source?ref=linear:ENG-456", bobTok)
	if code != http.StatusOK {
		t.Fatalf("stranger by-source = %d %s", code, body)
	}
	if err := json.Unmarshal(body, &notFound); err != nil {
		t.Fatalf("decode stranger by-source response: %v", err)
	}
	if notFound.Found {
		t.Fatalf("stranger by-source should report found=false")
	}
}

func TestFindTodoBySourceRefHTTPScopesToProject(t *testing.T) {
	srv, st, _ := todoTestRig(t)
	mkUser(t, st, "alice@x", "alicepass1")
	aliceTok := loginToken(t, srv.URL, "alice@x", "alicepass1")

	proj := createProjectHTTP(t, srv.URL, aliceTok, "Kunlun")

	personal := createTodoHTTP(t, srv.URL, aliceTok, map[string]any{
		"title":      "Personal copy",
		"source_ref": "linear:ENG-456",
	})
	team := createTodoHTTP(t, srv.URL, aliceTok, map[string]any{
		"title":      "Team copy",
		"project_id": proj.ID,
		"source_ref": "linear:ENG-456",
	})

	var found struct {
		Found bool            `json:"found"`
		Todo  todoschema.Todo `json:"todo"`
	}
	code, body := getAuthed(t, srv.URL+"/v1/todos/by-source?ref=linear:ENG-456", aliceTok)
	if code != http.StatusOK {
		t.Fatalf("personal by-source = %d %s", code, body)
	}
	if err := json.Unmarshal(body, &found); err != nil {
		t.Fatalf("decode personal by-source: %v", err)
	}
	if !found.Found || found.Todo.ID != personal.ID {
		t.Fatalf("personal by-source should find personal copy: %+v", found)
	}

	code, body = getAuthed(t, srv.URL+"/v1/todos/by-source?ref=linear:ENG-456&project="+proj.ID, aliceTok)
	if code != http.StatusOK {
		t.Fatalf("project by-source = %d %s", code, body)
	}
	if err := json.Unmarshal(body, &found); err != nil {
		t.Fatalf("decode project by-source: %v", err)
	}
	if !found.Found || found.Todo.ID != team.ID {
		t.Fatalf("project by-source should find team copy: %+v", found)
	}
}
