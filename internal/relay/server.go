package relay

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/handoffschema"
)

//go:embed ui/*
var uiFiles embed.FS

type Server struct {
	Store  *store.Store
	Tokens *auth.Tokens
	Hub    *sse.Hub
}

func (s *Server) Handler() http.Handler {
	// Don't overwrite an externally-set callback (eases tests that wire their
	// own presence observer; harmless on the standard main.go path where
	// Handler is called once per Server with a fresh Hub).
	if s.Hub != nil && s.Hub.OnPresenceChange == nil {
		s.Hub.OnPresenceChange = s.broadcastPresence
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("/", s.uiIndex)
	mux.HandleFunc("/ui", s.uiIndex)
	mux.Handle("GET /ui/", http.FileServerFS(uiFiles))

	api := http.NewServeMux()
	api.HandleFunc("POST /v1/handoffs", s.submit)
	api.HandleFunc("GET /v1/handoffs", s.list)
	api.HandleFunc("GET /v1/handoffs/{id}", s.get)
	api.HandleFunc("GET /v1/handoffs/{id}/status", s.status)
	api.HandleFunc("GET /v1/handoffs/{id}/prompt", s.prompt)
	api.HandleFunc("POST /v1/handoffs/{id}/ack", s.ack)
	api.HandleFunc("POST /v1/handoffs/{id}/retract", s.retract)
	api.HandleFunc("POST /v1/handoffs/{id}/reassign", s.reassign)
	api.HandleFunc("POST /v1/handoffs/{id}/comment", s.postComment)
	api.HandleFunc("GET /v1/handoffs/{id}/comments", s.listHandoffComments)
	api.HandleFunc("GET /v1/comments", s.listInboxComments)
	api.HandleFunc("POST /v1/handoffs/{id}/attachments/{name}", s.putAttachment)
	api.HandleFunc("GET /v1/handoffs/{id}/attachments/{name}", s.getAttachment)
	api.HandleFunc("GET /v1/events", s.events)
	api.HandleFunc("GET /v1/users/online", s.listOnlineUsers)
	api.HandleFunc("POST /v1/alerts", s.postAlert)

	mux.Handle("/v1/", s.Tokens.Middleware(api))
	return logging(mux)
}

// broadcastPresence is wired as Hub.OnPresenceChange. Fans a user.online /
// user.offline event out to every OTHER subscribed identity.
func (s *Server) broadcastPresence(identity string, online bool) {
	eventType := sse.EventTypeUserOnline
	if !online {
		eventType = sse.EventTypeUserOffline
	}
	data, err := json.Marshal(handoffschema.OnlineUser{Identity: identity, Online: online})
	if err != nil {
		return
	}
	s.Hub.PublishExcept(identity, sse.Event{Type: eventType, Data: data})
}

// postAlert receives a server-side log alert and fans it out to the target
// recipient's watch as a log.alert SSE event. The relay does not persist
// alerts — like other events they're best-effort; a missed alert is recovered
// by the next one, not by replay. The authenticated identity is stamped as the
// sender so clients can't spoof it.
func (s *Server) postAlert(w http.ResponseWriter, r *http.Request) {
	sender := auth.Identity(r.Context())
	var alert handoffschema.LogAlert
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&alert); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(alert.Recipient) == "" {
		http.Error(w, "recipient required", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(alert.Message) == "" {
		http.Error(w, "message required", http.StatusBadRequest)
		return
	}
	alert.Sender = sender
	if s.Hub != nil {
		if data, err := json.Marshal(alert); err == nil {
			s.Hub.Publish(sse.Event{Type: sse.EventTypeLogAlert, Recipient: alert.Recipient, Data: data})
		}
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true})
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) uiIndex(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.URL.Path != "/" && r.URL.Path != "/ui" {
		http.NotFound(w, r)
		return
	}
	http.Redirect(w, r, "/ui/", http.StatusFound)
}

func (s *Server) submit(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var p handoffschema.Package
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<20)).Decode(&p); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(p.EffectiveRecipients()) == 0 {
		http.Error(w, "recipient required", http.StatusBadRequest)
		return
	}
	// Server overrides sender + id + created_at + schema_version to prevent spoofing.
	p.Sender = identity
	if p.SchemaVersion == 0 {
		p.SchemaVersion = handoffschema.SchemaVersion
	}
	if p.Urgency == "" {
		p.Urgency = handoffschema.UrgencyNormal
	}
	now := time.Now().UTC()
	p.CreatedAt = now
	p.ID = handoff.NewID(now)

	if err := s.Store.Insert(r.Context(), &p); err != nil {
		http.Error(w, "insert: "+err.Error(), http.StatusInternalServerError)
		return
	}
	s.publishHandoffCreated(&p, p.EffectiveRecipients())
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":         p.ID,
		"created_at": p.CreatedAt,
	})
}

// publishHandoffCreated fans a handoff.created SSE event out to each of the
// targeted recipients. No-op when the Hub isn't configured (e.g. in tests
// that don't wire one). Marshalling failure is silent — events are
// best-effort; reconnect-with-Last-Event-Id is the recovery path.
func (s *Server) publishHandoffCreated(p *handoffschema.Package, targets []string) {
	if s.Hub == nil || len(targets) == 0 {
		return
	}
	notice := handoffschema.NoticeListItem(p, handoffschema.StatePending)
	data, err := json.Marshal(notice)
	if err != nil {
		return
	}
	for _, rec := range targets {
		s.Hub.Publish(sse.Event{Type: sse.EventTypeHandoffCreated, Recipient: rec, Data: data})
	}
}

func (s *Server) list(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}

	// ?as=sender lists handoffs the caller sent (any state, newest-first);
	// ?as=recipient (default, also matches old ?recipient= queries) lists
	// caller's pending inbox; ?as=history lists caller's already-picked
	// receipts (history view). Either way the role is anchored to the
	// authenticated identity — there's no third-party visibility.
	role := r.URL.Query().Get("as")
	if role == "" {
		// Back-compat: old clients pass ?recipient=<me>. Treat both as
		// "recipient" role; reject cross-identity recipient queries.
		recipient := r.URL.Query().Get("recipient")
		if recipient != "" && recipient != identity {
			http.Error(w, "can only list your own inbox", http.StatusForbidden)
			return
		}
		role = "recipient"
	}

	switch role {
	case "recipient":
		items, err := s.Store.ListPending(r.Context(), identity, limit)
		if err != nil {
			http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
	case "sender":
		items, err := s.Store.ListSent(r.Context(), identity, limit)
		if err != nil {
			http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
	case "history":
		items, err := s.Store.ListHistory(r.Context(), identity, limit)
		if err != nil {
			http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
	default:
		http.Error(w, "as must be 'sender', 'recipient', or 'history'", http.StatusBadRequest)
	}
}

func (s *Server) get(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")
	pkg, _, err := s.Store.Get(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !s.callerCanView(r.Context(), pkg, identity) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	writeJSON(w, http.StatusOK, pkg)
}

// prompt renders the receiver-side prompt.md from the stored Package — pure
// function, no recipient-side repo / git / swagger access needed.
// ?mode=direct selects the direct-edit template; default is doc-first.
func (s *Server) prompt(w http.ResponseWriter, r *http.Request) {
	pkg, _ := s.requireParticipant(w, r)
	if pkg == nil {
		return
	}
	mode := inbox.ModeDocFirst
	if r.URL.Query().Get("mode") == "direct" {
		mode = inbox.ModeDirect
	}
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, inbox.RenderPromptMD(pkg, mode))
}

// packageParticipants returns the union of sender + EffectiveRecipients +
// every BugGroupParticipants entry. Used by callerCanView and commentTargets
// so both auth + comment fan-out can share one BugGroupParticipants query.
// The bug-group expansion is load-bearing: tester sent the original bug to
// backend only, then backend reassigned to frontend — tester is no longer on
// the new handoff's sender/recipient set, but they still belong to the group.
func (s *Server) packageParticipants(ctx context.Context, pkg *handoffschema.Package) []string {
	seen := map[string]struct{}{}
	add := func(id string) {
		if id != "" {
			seen[id] = struct{}{}
		}
	}
	add(pkg.Sender)
	for _, r := range pkg.EffectiveRecipients() {
		add(r)
	}
	if pkg.BugGroupID != "" {
		if extra, err := s.Store.BugGroupParticipants(ctx, pkg.BugGroupID); err == nil {
			for _, p := range extra {
				add(p)
			}
		}
	}
	out := make([]string, 0, len(seen))
	for id := range seen {
		out = append(out, id)
	}
	return out
}

func (s *Server) callerCanView(ctx context.Context, pkg *handoffschema.Package, identity string) bool {
	for _, p := range s.packageParticipants(ctx, pkg) {
		if p == identity {
			return true
		}
	}
	return false
}

func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	if s.Hub == nil {
		http.Error(w, "events not enabled", http.StatusNotImplemented)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	sub, cancel := s.Hub.Subscribe(identity)
	defer cancel()

	// SSE comment as keep-alive; some intermediaries close idle connections after 30-60s.
	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()

	fmt.Fprint(w, ": connected\n\n")
	flusher.Flush()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ping.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case ev, open := <-sub.C():
			if !open {
				return
			}
			fmt.Fprintf(w, "id: %d\nevent: %s\ndata: %s\n\n", ev.ID, ev.Type, ev.Data)
			flusher.Flush()
		}
	}
}

// listOnlineUsers exposes the relay roster so a caller can answer "is my
// partner currently watching?" before sending an urgent handoff or comment.
func (s *Server) listOnlineUsers(w http.ResponseWriter, _ *http.Request) {
	if s.Hub == nil {
		http.Error(w, "events not enabled", http.StatusNotImplemented)
		return
	}
	online := map[string]bool{}
	for _, id := range s.Hub.OnlineRecipients() {
		online[id] = true
	}
	known := s.Tokens.Identities()
	users := make([]handoffschema.OnlineUser, 0, len(known))
	for _, id := range known {
		users = append(users, handoffschema.OnlineUser{Identity: id, Online: online[id]})
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

// requireParticipant fetches the handoff for the {id} path segment and
// rejects callers that aren't the sender, a recipient slot owner, or a
// bug-group co-participant. Returns nil if the response has already been
// written (404/500/403).
func (s *Server) requireParticipant(w http.ResponseWriter, r *http.Request) (*handoffschema.Package, string) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")
	pkg, _, err := s.Store.Get(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return nil, ""
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return nil, ""
	}
	if !s.callerCanView(r.Context(), pkg, identity) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return nil, ""
	}
	return pkg, identity
}

func (s *Server) postComment(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")
	pkg, _, err := s.Store.Get(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	// One BugGroupParticipants query covers both auth and SSE fan-out — the
	// shared helper means we don't pay twice on the bug-group hot path.
	participants := s.packageParticipants(r.Context(), pkg)
	caller := false
	for _, p := range participants {
		if p == identity {
			caller = true
			break
		}
	}
	if !caller {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	var req struct {
		Body string `json:"body"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.Body == "" {
		http.Error(w, "body required", http.StatusBadRequest)
		return
	}

	c, err := s.Store.InsertComment(r.Context(), pkg.ID, identity, req.Body)
	if err != nil {
		http.Error(w, "insert: "+err.Error(), http.StatusInternalServerError)
		return
	}

	if s.Hub != nil {
		if data, err := json.Marshal(c); err == nil {
			for _, t := range participants {
				if t == identity {
					continue
				}
				s.Hub.Publish(sse.Event{Type: sse.EventTypeCommentCreated, Recipient: t, Data: data})
			}
		}
	}
	writeJSON(w, http.StatusCreated, c)
}

func (s *Server) listHandoffComments(w http.ResponseWriter, r *http.Request) {
	pkg, _ := s.requireParticipant(w, r)
	if pkg == nil {
		return
	}
	comments, err := s.Store.ListComments(r.Context(), pkg.ID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"comments": comments})
}

// listInboxComments returns comments addressed to the caller across every
// handoff they participate in, with id > since. Used by `cc-handoff watch`
// catch-up on startup to surface comments missed while offline.
func (s *Server) listInboxComments(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var since int64
	if v := r.URL.Query().Get("since"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			http.Error(w, "invalid since", http.StatusBadRequest)
			return
		}
		since = n
	}
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			http.Error(w, "invalid limit", http.StatusBadRequest)
			return
		}
		limit = n
	}

	comments, maxID, err := s.Store.ListCommentsSince(r.Context(), identity, since, limit)
	if err != nil {
		http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"comments": comments,
		"max_id":   maxID,
	})
}

func (s *Server) putAttachment(w http.ResponseWriter, r *http.Request) {
	pkg, _ := s.requireParticipant(w, r)
	if pkg == nil {
		return
	}
	name := r.PathValue("name")
	// Reject anything other than a bare, non-traversal basename. The name
	// flows directly into both DB storage and (on the receiver)
	// inbox/<id>/attachments/<name>; "../etc/passwd" must never get there,
	// and "." / ".." pass filepath.Base unchanged so they need explicit
	// rejection on top.
	if name == "" || name == "." || name == ".." ||
		name != filepath.Base(name) ||
		strings.ContainsAny(name, `/\`) {
		http.Error(w, "invalid attachment name", http.StatusBadRequest)
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, handoff.AttachmentMaxBytes))
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	sum := sha256.Sum256(body)
	hexSum := hex.EncodeToString(sum[:])

	if want := r.Header.Get("X-Content-Sha256"); want != "" && want != hexSum {
		http.Error(w, "sha256 mismatch", http.StatusBadRequest)
		return
	}

	if err := s.Store.PutAttachment(r.Context(), pkg.ID, name, hexSum, body); err != nil {
		http.Error(w, "store: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"name":   name,
		"sha256": hexSum,
		"size":   len(body),
	})
}

func (s *Server) getAttachment(w http.ResponseWriter, r *http.Request) {
	pkg, _ := s.requireParticipant(w, r)
	if pkg == nil {
		return
	}
	name := r.PathValue("name")

	content, sum, _, err := s.Store.GetAttachment(r.Context(), pkg.ID, name)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "attachment not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Content-Sha256", sum)
	_, _ = w.Write(content)
}

func (s *Server) ack(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")
	err := s.Store.Ack(r.Context(), id, identity)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		// auth-style errors come back as forbidden strings
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// status returns state + picked_at + comment summary for a single handoff.
// Caller must be a participant — sender, recipient slot owner, or bug-group
// co-participant.
func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")
	st, err := s.Store.Status(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	allowed := st.Sender == identity || st.Recipient == identity
	if !allowed {
		for _, rec := range st.Recipients {
			if rec == identity {
				allowed = true
				break
			}
		}
	}
	if !allowed && st.BugGroupID != "" {
		participants, err := s.Store.BugGroupParticipants(r.Context(), st.BugGroupID)
		if err == nil {
			for _, p := range participants {
				if p == identity {
					allowed = true
					break
				}
			}
		}
	}
	if !allowed {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// retract marks a still-pending handoff as retracted. Sender-only; broadcasts
// a handoff.retracted SSE event so the recipient's watch surfaces the
// withdrawal. Returns 409 if the recipient already picked it up — past that
// point coordinate via comments.
func (s *Server) retract(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")

	// Optional reason body. {} also fine.
	var body struct {
		Reason string `json:"reason,omitempty"`
	}
	if r.ContentLength > 0 {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
			http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
			return
		}
	}

	recipients, err := s.Store.Retract(r.Context(), id, identity)
	switch {
	case errors.Is(err, store.ErrNotFound):
		http.Error(w, "not found", http.StatusNotFound)
		return
	case errors.Is(err, store.ErrForbidden):
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	case errors.Is(err, store.ErrConflict):
		http.Error(w, err.Error()+" — coordinate via comment instead", http.StatusConflict)
		return
	case err != nil:
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if s.Hub != nil {
		ev := handoffschema.RetractEvent{ID: id, Sender: identity, Reason: body.Reason}
		if data, err := json.Marshal(ev); err == nil {
			for _, rec := range recipients {
				s.Hub.Publish(sse.Event{Type: sse.EventTypeHandoffRetracted, Recipient: rec, Data: data})
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id})
}

// reassign forwards a bug handoff to a different identity. The caller (the
// current recipient who decided "this is not my bug") closes their slot and
// the relay creates a fresh bug handoff for `to`, sharing the original's
// bug_group_id so comments stay synced across the whole reassign chain.
func (s *Server) reassign(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")

	var req struct {
		To     string `json:"to"`
		Reason string `json:"reason"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.To == "" {
		http.Error(w, "to required", http.StatusBadRequest)
		return
	}
	if req.To == identity {
		http.Error(w, "cannot reassign to yourself", http.StatusBadRequest)
		return
	}

	orig, _, err := s.Store.Get(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	newPkg := handoff.BuildReassignment(orig, req.To, req.Reason, identity, time.Now().UTC())

	if err := s.Store.Reassign(r.Context(), id, identity, newPkg, req.Reason); err != nil {
		switch {
		case errors.Is(err, store.ErrNotFound):
			http.Error(w, "not found", http.StatusNotFound)
		case errors.Is(err, store.ErrForbidden):
			http.Error(w, err.Error(), http.StatusForbidden)
		case errors.Is(err, store.ErrConflict):
			http.Error(w, err.Error(), http.StatusConflict)
		default:
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}

	s.publishHandoffCreated(newPkg, []string{req.To})

	writeJSON(w, http.StatusCreated, map[string]any{
		"id":              newPkg.ID,
		"reassigned_to":   req.To,
		"bug_group_id":    newPkg.BugGroupID,
		"reassigned_from": id,
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.code = code
	s.ResponseWriter.WriteHeader(code)
}

// Flush delegates to the underlying ResponseWriter so SSE handlers retain
// streaming. Without this, type-asserting the wrapped writer to http.Flusher
// fails even though the inner writer supports it.
func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// auditLogger lazily initializes a JSON slog handler writing to stderr.
// Lazy so test code that constructs a Server in-process can swap it via
// slog.SetDefault(...) before the first request.
func auditLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
}

var handoffIDInPath = regexp.MustCompile(`^/v1/handoffs/([^/]+)`)

func logging(next http.Handler) http.Handler {
	logger := auditLogger()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		var identity string
		ctx := auth.WithIdentityHolder(r.Context(), &identity)
		rec := &statusRecorder{ResponseWriter: w, code: 200}
		next.ServeHTTP(rec, r.WithContext(ctx))

		attrs := []slog.Attr{
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
			slog.Int("status", rec.code),
			slog.Int64("ms", time.Since(start).Milliseconds()),
		}
		if identity != "" {
			attrs = append(attrs, slog.String("identity", identity))
		}
		if m := handoffIDInPath.FindStringSubmatch(r.URL.Path); len(m) == 2 {
			attrs = append(attrs, slog.String("handoff_id", m[1]))
		}
		logger.LogAttrs(r.Context(), slog.LevelInfo, "relay.request", attrs...)
	})
}
