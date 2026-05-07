package relay

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"time"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/handoffschema"
)

type Server struct {
	Store  *store.Store
	Tokens *auth.Tokens
	Hub    *sse.Hub
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)

	api := http.NewServeMux()
	api.HandleFunc("POST /v1/handoffs", s.submit)
	api.HandleFunc("GET /v1/handoffs", s.list)
	api.HandleFunc("GET /v1/handoffs/{id}", s.get)
	api.HandleFunc("GET /v1/handoffs/{id}/status", s.status)
	api.HandleFunc("POST /v1/handoffs/{id}/ack", s.ack)
	api.HandleFunc("POST /v1/handoffs/{id}/retract", s.retract)
	api.HandleFunc("POST /v1/handoffs/{id}/comment", s.postComment)
	api.HandleFunc("GET /v1/handoffs/{id}/comments", s.listHandoffComments)
	api.HandleFunc("GET /v1/comments", s.listInboxComments)
	api.HandleFunc("POST /v1/handoffs/{id}/attachments/{name}", s.putAttachment)
	api.HandleFunc("GET /v1/handoffs/{id}/attachments/{name}", s.getAttachment)
	api.HandleFunc("GET /v1/events", s.events)
	api.HandleFunc("GET /v1/users/online", s.listOnlineUsers)

	mux.Handle("/v1/", s.Tokens.Middleware(api))
	return logging(mux)
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) submit(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var p handoffschema.Package
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<20)).Decode(&p); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if p.Recipient == "" {
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
	if s.Hub != nil {
		notice := handoffschema.ListItem{
			ID:        p.ID,
			Kind:      p.Kind,
			Sender:    p.Sender,
			Urgency:   p.Urgency,
			State:     handoffschema.StatePending,
			CreatedAt: p.CreatedAt,
			RepoName:  p.Repo.Name,
			Branch:    p.Repo.Branch,
		}
		if data, err := json.Marshal(notice); err == nil {
			s.Hub.Publish(sse.Event{Type: sse.EventTypeHandoffCreated, Recipient: p.Recipient, Data: data})
		}
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":         p.ID,
		"created_at": p.CreatedAt,
	})
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
	// caller's pending inbox. Either way the role is anchored to the
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
	default:
		http.Error(w, "as must be 'sender' or 'recipient'", http.StatusBadRequest)
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
	if pkg.Recipient != identity && pkg.Sender != identity {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	writeJSON(w, http.StatusOK, pkg)
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
// rejects callers that aren't the sender or recipient. Returns nil if the
// response has already been written (404/500/403).
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
	if identity != pkg.Sender && identity != pkg.Recipient {
		http.Error(w, "forbidden", http.StatusForbidden)
		return nil, ""
	}
	return pkg, identity
}

func (s *Server) postComment(w http.ResponseWriter, r *http.Request) {
	pkg, identity := s.requireParticipant(w, r)
	if pkg == nil {
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
		target := pkg.Recipient
		if identity == pkg.Recipient {
			target = pkg.Sender
		}
		if data, err := json.Marshal(c); err == nil {
			s.Hub.Publish(sse.Event{Type: sse.EventTypeCommentCreated, Recipient: target, Data: data})
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

const attachmentMaxBytes = 50 << 20 // 50 MB ought to cover any sensible diff

func (s *Server) putAttachment(w http.ResponseWriter, r *http.Request) {
	pkg, identity := s.requireParticipant(w, r)
	if pkg == nil {
		return
	}
	if identity != pkg.Sender {
		http.Error(w, "forbidden: only sender can upload attachments", http.StatusForbidden)
		return
	}
	name := r.PathValue("name")

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, attachmentMaxBytes))
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
// Caller must be sender or recipient (peer parties only).
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
	if st.Sender != identity && st.Recipient != identity {
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

	recipient, err := s.Store.Retract(r.Context(), id, identity)
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
			s.Hub.Publish(sse.Event{Type: sse.EventTypeHandoffRetracted, Recipient: recipient, Data: data})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id})
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
