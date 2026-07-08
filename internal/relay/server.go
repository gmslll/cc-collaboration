package relay

import (
	"bufio"
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
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

// appFiles is the Flutter Web client bundle (the browser version of the phone's
// remote workspace), served at /app/. Built with
// `flutter build web -t lib/main_web.dart --base-href /app/` and copied here.
// `all:` so nested assets/ and canvaskit/ dirs are embedded too.
//
//go:embed all:app
var appFiles embed.FS

//go:embed screen_share/*
var screenShareFiles embed.FS

type Server struct {
	Store  *store.Store
	Tokens *auth.Tokens
	Hub    *sse.Hub
	// WsBroker pipes opaque frames between a user's own devices (a desktop host
	// and a phone client) for the remote-workspace feature. Lazily created in
	// Handler if nil. In-memory/transient like the Hub.
	WsBroker *wsBroker
	// Sessions holds each identity's published terminal sessions so a peer can
	// target a specific remote session (POST /v1/sessions, GET
	// /v1/users/{id}/sessions). Lazily created in Handler; in-memory/transient,
	// TTL'd and cleared on presence offline.
	Sessions *sessionRegistry
	// ScreenShareBroker pipes WebRTC signaling frames for the browser screen
	// share feature. It is separate from WsBroker so remote-workspace frames and
	// screen-share SDP/ICE frames cannot cross streams.
	ScreenShareBroker *screenShareBroker
	// SeedAdmins are operator-configured admin identities (from -admins /
	// RELAY_ADMINS). They are always admin even without a users row, so an
	// operator can never be locked out. Effective admin = SeedAdmins ∪
	// users.is_admin.
	SeedAdmins []string
}

func (s *Server) Handler() http.Handler {
	// Don't overwrite an externally-set callback (eases tests that wire their
	// own presence observer; harmless on the standard main.go path where
	// Handler is called once per Server with a fresh Hub).
	if s.Hub != nil && s.Hub.OnPresenceChange == nil {
		s.Hub.OnPresenceChange = s.broadcastPresence
	}
	if s.WsBroker == nil {
		s.WsBroker = newWsBroker()
	}
	if s.Sessions == nil {
		s.Sessions = newSessionRegistry()
	}
	if s.ScreenShareBroker == nil {
		s.ScreenShareBroker = newScreenShareBroker()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("/", s.uiIndex)
	mux.HandleFunc("/ui", s.uiIndex)
	mux.Handle("GET /ui/", http.FileServerFS(uiFiles))
	mux.Handle("GET /app/", http.FileServerFS(appFiles))
	mux.HandleFunc("/share", s.screenShareIndex)
	mux.Handle("GET /share/", screenShareFileServer())

	api := http.NewServeMux()
	api.HandleFunc("POST /v1/handoffs", s.submit)
	api.HandleFunc("GET /v1/handoffs", s.list)
	api.HandleFunc("GET /v1/capsules", s.listCapsules)
	api.HandleFunc("PATCH /v1/capsules/{id}", s.patchCapsule)
	api.HandleFunc("DELETE /v1/capsules/{id}", s.deleteCapsule)
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
	api.HandleFunc("POST /v1/sessions", s.postSessions)
	api.HandleFunc("GET /v1/users/{identity}/sessions", s.getUserSessions)
	api.HandleFunc("POST /v1/messages", s.postMessage)
	// Account endpoints (authenticated): logout / whoami / change own password.
	api.HandleFunc("POST /v1/logout", s.logout)
	api.HandleFunc("GET /v1/me", s.me)
	api.HandleFunc("POST /v1/password", s.changePassword)
	// Account management (admin only).
	api.HandleFunc("GET /v1/users", s.listUsers)
	api.HandleFunc("POST /v1/users", s.createUser)
	api.HandleFunc("POST /v1/users/{id}/admin", s.setUserAdmin)
	api.HandleFunc("POST /v1/users/{id}/disable", s.setUserDisabled)
	api.HandleFunc("POST /v1/users/{id}/reset-password", s.resetUserPassword)
	// Organizations: SaaS teams/workspaces. Any authenticated user can create
	// one; owners/admins manage membership.
	api.HandleFunc("GET /v1/orgs", s.listOrganizations)
	api.HandleFunc("POST /v1/orgs", s.createOrganization)
	api.HandleFunc("GET /v1/orgs/{id}", s.getOrganization)
	api.HandleFunc("POST /v1/orgs/{id}/members", s.addOrganizationMember)
	api.HandleFunc("DELETE /v1/orgs/{id}/members/{identity}", s.removeOrganizationMember)
	// Projects: self-service create + owner/admin management.
	api.HandleFunc("GET /v1/projects", s.listProjects)
	api.HandleFunc("POST /v1/projects", s.createProject)
	api.HandleFunc("GET /v1/projects/{id}", s.getProject)
	api.HandleFunc("PATCH /v1/projects/{id}", s.renameProject)
	api.HandleFunc("DELETE /v1/projects/{id}", s.deleteProject)
	api.HandleFunc("POST /v1/projects/{id}/repos", s.mapRepo)
	api.HandleFunc("DELETE /v1/projects/{id}/repos", s.unmapRepo)
	api.HandleFunc("POST /v1/projects/{id}/members", s.addMember)
	api.HandleFunc("DELETE /v1/projects/{id}/members/{identity}", s.removeMember)
	// Self-service machine tokens (any authenticated user, own tokens only).
	api.HandleFunc("GET /v1/tokens", s.listTokens)
	api.HandleFunc("POST /v1/tokens", s.createToken)
	api.HandleFunc("DELETE /v1/tokens/{id}", s.deleteToken)
	// Per-identity synced UI settings (any authenticated user, own keys only) —
	// see internal/relay/settings.go.
	api.HandleFunc("GET /v1/settings/{key}", s.getSetting)
	api.HandleFunc("PUT /v1/settings/{key}", s.putSetting)
	// Todos: personal + project-scoped, freely-mutable-status items (see
	// internal/relay/todos.go). Authorization lives entirely in
	// internal/relay/store/todos.go; these handlers just translate
	// ErrForbidden/ErrNotFound.
	api.HandleFunc("POST /v1/todos", s.createTodo)
	api.HandleFunc("GET /v1/todos", s.listTodos)
	// Registered as a literal segment alongside the {id} wildcard below —
	// Go 1.22's ServeMux prefers the more specific (non-wildcard) pattern for
	// the literal path "/v1/todos/by-source" regardless of registration order.
	api.HandleFunc("GET /v1/todos/by-source", s.findTodoBySourceRef)
	// Same "literal segment beats the {id} wildcard" rule as by-source above.
	api.HandleFunc("GET /v1/todos/groups", s.listTodoGroups)
	api.HandleFunc("POST /v1/todos/groups/rename", s.renameTodoGroup)
	api.HandleFunc("POST /v1/todos/groups/clear", s.clearTodoGroup)
	api.HandleFunc("GET /v1/todos/{id}", s.getTodo)
	api.HandleFunc("PATCH /v1/todos/{id}", s.patchTodo)
	api.HandleFunc("DELETE /v1/todos/{id}", s.deleteTodo)
	api.HandleFunc("POST /v1/todos/{id}/status", s.setTodoStatus)
	api.HandleFunc("POST /v1/todos/{id}/assign", s.assignTodo)
	api.HandleFunc("POST /v1/todos/{id}/recur-advance", s.recurAdvanceTodo)
	api.HandleFunc("POST /v1/todos/{id}/comment", s.postTodoComment)
	api.HandleFunc("GET /v1/todos/{id}/comments", s.listTodoComments)
	api.HandleFunc("POST /v1/todos/{id}/attachments/{name}", s.putTodoAttachment)
	api.HandleFunc("GET /v1/todos/{id}/attachments/{name}", s.getTodoAttachment)

	// Login and register are the /v1 routes that must NOT require a bearer (you
	// don't have one yet); registering them on the outer mux makes the
	// more-specific pattern win over the "/v1/" catch-all, so they bypass the
	// auth middleware. register is open self-registration (non-admin accounts).
	mux.HandleFunc("POST /v1/login", s.login)
	mux.HandleFunc("POST /v1/register", s.register)

	resolver := &bearerResolver{store: s.Store, seed: s.Tokens}
	// /v1/ws needs query-param auth (browsers can't set the WS handshake header),
	// so register it on the outer mux with a query-allowing wrapper — the more
	// specific pattern wins, leaving the /v1/ catch-all header-only. Mirrors the
	// /v1/login special-case above.
	mux.Handle("GET /v1/ws",
		auth.MiddlewareAllowingQueryToken(resolver)(http.HandlerFunc(s.ws)))
	mux.Handle("GET /v1/screen-share/ws",
		auth.MiddlewareAllowingQueryToken(resolver)(http.HandlerFunc(s.screenShareWS)))
	mux.Handle("/v1/", auth.Middleware(resolver)(api))
	return logging(mux)
}

// broadcastPresence is wired as Hub.OnPresenceChange. Fans a user.online /
// user.offline event out to every OTHER subscribed identity.
func (s *Server) broadcastPresence(identity string, online bool) {
	// A user that just went fully offline has no live sessions to target.
	if !online && s.Sessions != nil {
		s.Sessions.clear(identity)
	}
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
	if !s.requireReachableIdentity(w, r, alert.Recipient) {
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

func (s *Server) screenShareIndex(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	http.Redirect(w, r, "/share/", http.StatusFound)
}

func (s *Server) submit(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var p handoffschema.Package
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<20)).Decode(&p); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	// Capsules go to the plaza (keyed by visibility), not to a recipient's
	// inbox — so they alone may omit a recipient. Every other kind must have one.
	if len(p.EffectiveRecipients()) == 0 && p.RequiresRecipient() {
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

// listCapsules serves the plaza: GET /v1/capsules returns the capsules visible
// to the caller (all public + the caller's own private), newest first.
func (s *Server) listCapsules(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	limit := 0
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	items, err := s.Store.ListCapsules(r.Context(), identity, limit)
	if err != nil {
		http.Error(w, "list capsules: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if items == nil {
		items = []handoffschema.CapsuleListItem{}
	}
	writeJSON(w, http.StatusOK, items)
}

// deleteCapsule removes the caller's own capsule from the plaza (owner-only).
func (s *Server) deleteCapsule(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	if err := s.Store.DeleteCapsule(r.Context(), r.PathValue("id"), identity); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// patchCapsule edits the caller's own capsule metadata — visibility / summary
// (owner-only).
func (s *Server) patchCapsule(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var body struct {
		Visibility *string `json:"visibility,omitempty"`
		Summary    *string `json:"summary,omitempty"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&body); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.Store.UpdateCapsuleMeta(r.Context(), r.PathValue("id"), identity, body.Visibility, body.Summary); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
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

	// Project-scoped / admin-wide listing surfaces handoffs the caller isn't a
	// party to (unlike ?as=, which is anchored to the caller). scope=project
	// lists every handoff in the caller's projects, or one named project they
	// belong to; scope=all is admin-only and lists everything.
	switch r.URL.Query().Get("scope") {
	case "all":
		if !s.isAdmin(r.Context(), identity) {
			http.Error(w, "admin only", http.StatusForbidden)
			return
		}
		items, err := s.Store.ListAll(r.Context(), limit)
		if err != nil {
			http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
		return
	case "project":
		var (
			repos []string
			err   error
		)
		if pid := r.URL.Query().Get("project"); pid != "" {
			if !s.isAdmin(r.Context(), identity) {
				if _, ok, _ := s.Store.MemberRole(r.Context(), pid, identity); !ok {
					http.Error(w, "forbidden", http.StatusForbidden)
					return
				}
			}
			repos, err = s.Store.ListProjectRepos(r.Context(), pid)
		} else {
			repos, err = s.Store.VisibleRepoNames(r.Context(), identity)
		}
		if err != nil {
			http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
			return
		}
		items, err := s.Store.ListByRepos(r.Context(), repos, limit)
		if err != nil {
			http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
		return
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
	if !s.canViewPackage(r.Context(), pkg, identity) {
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

// canViewPackage is the single read-authorization gate, layering project/admin
// visibility on top of the legacy participant rule (all additive, so 2-party
// flows with no projects behave exactly as before):
//   - a global admin sees everything;
//   - a participant (sender / recipient / bug-group) sees it, as always;
//   - any member (owner/member/viewer) of the project owning the handoff's repo
//     sees every handoff in that project.
func (s *Server) canViewPackage(ctx context.Context, pkg *handoffschema.Package, identity string) bool {
	if s.isAdmin(ctx, identity) {
		return true
	}
	// Capsules follow the plaza's visibility rule, not the recipient one.
	if pkg.EffectiveKind() == handoffschema.KindCapsule {
		return pkg.CapsuleVisibleTo(identity)
	}
	if s.callerCanView(ctx, pkg, identity) {
		return true
	}
	if repo := pkg.Repo.Name; repo != "" {
		if _, ok, err := s.Store.RepoVisibleTo(ctx, repo, identity); err == nil && ok {
			return true
		}
	}
	return false
}

// canComment gates comment-posting given the already-computed participant set
// (so we don't re-query the bug group that postComment already needs for SSE
// fan-out): admins and participants always can; a project member can unless
// they're a read-only viewer.
func (s *Server) canComment(ctx context.Context, pkg *handoffschema.Package, identity string, participants []string) bool {
	if s.isAdmin(ctx, identity) {
		return true
	}
	if slices.Contains(participants, identity) {
		return true
	}
	if repo := pkg.Repo.Name; repo != "" {
		if role, ok, err := s.Store.RepoVisibleTo(ctx, repo, identity); err == nil && ok && role != store.RoleViewer {
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
func (s *Server) listOnlineUsers(w http.ResponseWriter, r *http.Request) {
	if s.Hub == nil {
		http.Error(w, "events not enabled", http.StatusNotImplemented)
		return
	}
	online := map[string]bool{}
	for _, id := range s.Hub.OnlineRecipients() {
		online[id] = true
	}
	known := s.Tokens.Identities()
	if ids, err := s.Store.KnownIdentities(context.Background()); err == nil {
		known = append(known, ids...)
	}
	for id := range online {
		known = append(known, id)
	}
	slices.Sort(known)
	known = slices.Compact(known)
	activeKnown := known[:0]
	for _, id := range known {
		if active, err := s.Store.UserActive(r.Context(), id); err == nil && active {
			activeKnown = append(activeKnown, id)
		}
	}
	known = activeKnown
	caller := auth.Identity(r.Context())
	if !s.isAdmin(r.Context(), caller) {
		visible := known[:0]
		for _, id := range known {
			ok, err := s.canReachIdentity(r.Context(), caller, id)
			if err != nil {
				http.Error(w, "filter online users: "+err.Error(), http.StatusInternalServerError)
				return
			}
			if ok {
				visible = append(visible, id)
			}
		}
		known = visible
	}
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
	if !s.canViewPackage(r.Context(), pkg, identity) {
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
	// Compute participants once (also needed for SSE fan-out below) and gate on
	// them — open to participants, admins, and project owner/member (not viewer).
	participants := s.packageParticipants(r.Context(), pkg)
	if !s.canComment(r.Context(), pkg, identity, participants) {
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
	// Authorize via the shared gate (one extra PK lookup for the repo +
	// participants). Replaces the previously-inlined participant check so admin
	// / project visibility applies here too.
	pkg, _, err := s.Store.Get(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !s.canViewPackage(r.Context(), pkg, identity) {
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

// statusRecorder must forward the optional ResponseWriter interfaces the inner
// writer supports, or wrapping it here silently disables them.
var (
	_ http.Flusher  = (*statusRecorder)(nil)
	_ http.Hijacker = (*statusRecorder)(nil)
)

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

// Hijack delegates to the underlying ResponseWriter so the WebSocket handler
// (/v1/ws) can take over the connection. Without this the wrapped writer fails
// the http.Hijacker assertion and websocket.Accept returns 501.
func (s *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := s.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, fmt.Errorf("underlying ResponseWriter does not support hijacking")
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
