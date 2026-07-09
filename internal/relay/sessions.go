package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// publishedSessionTTL bounds how long a published session list lives without a refresh.
// The app republishes on every change and on a ~30s heartbeat, so a stale list
// (app crashed / network gone) disappears within this window even if the
// presence-offline hook misses the transition.
const publishedSessionTTL = 90 * time.Second

const (
	maxPublishedSessions      = 64
	maxSessionIDLen           = 96
	maxSessionLabelLen        = 160
	maxSessionProjectLen      = 160
	maxSessionWorkdirLen      = 512
	defaultSessionLabelPrefix = "Session "
)

// sessionRegistry holds each identity's currently-open terminal sessions so a
// peer can target a specific remote session. In-memory + transient (like the
// SSE hub): an identity's entry is refreshed on publish, dropped on presence
// offline, and expires after publishedSessionTTL.
type sessionRegistry struct {
	mu      sync.Mutex
	byID    map[string]sessionEntry
	nowFunc func() time.Time // overridable in tests
}

type sessionEntry struct {
	sessions []handoffschema.SessionInfo
	expires  time.Time
}

func newSessionRegistry() *sessionRegistry {
	return &sessionRegistry{byID: map[string]sessionEntry{}, nowFunc: time.Now}
}

func (r *sessionRegistry) now() time.Time {
	if r.nowFunc != nil {
		return r.nowFunc()
	}
	return time.Now()
}

// set replaces identity's session list and refreshes its TTL.
func (r *sessionRegistry) set(identity string, sessions []handoffschema.SessionInfo) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(sessions) == 0 {
		delete(r.byID, identity)
		return
	}
	r.byID[identity] = sessionEntry{sessions: sessions, expires: r.now().Add(publishedSessionTTL)}
}

// get returns identity's live sessions (nil if none / expired). Expired entries
// are pruned lazily on read.
func (r *sessionRegistry) get(identity string) []handoffschema.SessionInfo {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.byID[identity]
	if !ok {
		return nil
	}
	if r.now().After(e.expires) {
		delete(r.byID, identity)
		return nil
	}
	return e.sessions
}

// clear drops identity's sessions — called when it goes presence-offline.
func (r *sessionRegistry) clear(identity string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.byID, identity)
}

// postSessions upserts the caller's currently-open terminal sessions so peers
// can target a specific one. Identity comes from the token (you can't publish
// for someone else). Transient: refreshed each call, dropped on offline/TTL.
func (s *Server) postSessions(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var body struct {
		Sessions []handoffschema.SessionInfo `json:"sessions"`
	}
	if err := decodeJSONBody(w, r, 1<<20, &body); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	s.Sessions.set(identity, normalizePublishedSessions(body.Sessions))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func normalizePublishedSessions(in []handoffschema.SessionInfo) []handoffschema.SessionInfo {
	if len(in) == 0 {
		return nil
	}
	out := make([]handoffschema.SessionInfo, 0, min(len(in), maxPublishedSessions))
	for _, s := range in {
		if len(out) >= maxPublishedSessions {
			break
		}
		id := truncateRunes(strings.TrimSpace(s.ID), maxSessionIDLen)
		if id == "" {
			continue
		}
		label := truncateRunes(strings.TrimSpace(s.Label), maxSessionLabelLen)
		if label == "" {
			label = defaultSessionLabelPrefix + id
		}
		out = append(out, handoffschema.SessionInfo{
			ID:        id,
			Label:     label,
			Project:   truncateRunes(strings.TrimSpace(s.Project), maxSessionProjectLen),
			ProjectID: truncateRunes(strings.TrimSpace(s.ProjectID), maxSessionProjectLen),
			Workdir:   truncateRunes(strings.TrimSpace(s.Workdir), maxSessionWorkdirLen),
		})
	}
	return out
}

func truncateRunes(s string, max int) string {
	if max <= 0 {
		return ""
	}
	for i := range s {
		if max == 0 {
			return s[:i]
		}
		max--
	}
	return s
}

// getUserSessions returns a reachable user's currently-open sessions (empty if
// offline / never published / expired). Reachable means self, admin, or shared
// organization/project membership.
func (s *Server) getUserSessions(w http.ResponseWriter, r *http.Request) {
	target := r.PathValue("identity")
	if !s.requireReachableIdentity(w, r, target) {
		return
	}
	sessions := s.Sessions.get(target)
	if sessions == nil {
		sessions = []handoffschema.SessionInfo{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions})
}

// postMessage delivers a short text from the authenticated sender to a specific
// session on the recipient's machine, as a transient message.deliver event. Not
// persisted: the recipient's app must be online to receive it (and then asks
// the user to confirm before injecting). From is stamped from the token.
func (s *Server) postMessage(w http.ResponseWriter, r *http.Request) {
	sender := auth.Identity(r.Context())
	var msg handoffschema.Message
	if err := decodeJSONBody(w, r, 1<<20, &msg); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	msg.Recipient = strings.TrimSpace(msg.Recipient)
	msg.SessionID = strings.TrimSpace(msg.SessionID)
	if msg.Recipient == "" {
		http.Error(w, "recipient required", http.StatusBadRequest)
		return
	}
	if msg.SessionID == "" {
		http.Error(w, "session_id required", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(msg.Body) == "" {
		http.Error(w, "body required", http.StatusBadRequest)
		return
	}
	if !s.requireReachableIdentity(w, r, msg.Recipient) {
		return
	}
	if !publishedSessionExists(s.Sessions.get(msg.Recipient), msg.SessionID) {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}
	if s.Hub != nil {
		out := handoffschema.Message{From: sender, SessionID: msg.SessionID, Body: msg.Body}
		if data, err := json.Marshal(out); err == nil {
			s.publishToActive(r.Context(), sse.Event{Type: sse.EventTypeMessageDeliver, Recipient: msg.Recipient, Data: data})
		}
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true})
}

func publishedSessionExists(sessions []handoffschema.SessionInfo, id string) bool {
	for _, s := range sessions {
		if s.ID == id {
			return true
		}
	}
	return false
}

func (s *Server) requireReachableIdentity(w http.ResponseWriter, r *http.Request, target string) bool {
	caller := auth.Identity(r.Context())
	ok, err := s.canReachIdentity(r.Context(), caller, target)
	if err != nil {
		http.Error(w, "check identity reachability: "+err.Error(), http.StatusInternalServerError)
		return false
	}
	if !ok {
		http.Error(w, "forbidden", http.StatusForbidden)
		return false
	}
	return true
}

func (s *Server) canReachIdentity(ctx context.Context, caller, target string) (bool, error) {
	active, err := s.Store.UserActive(ctx, target)
	if err != nil {
		return false, err
	}
	if !active {
		return false, nil
	}
	if caller == target || s.isAdmin(ctx, caller) {
		return true, nil
	}
	return s.identitiesShareTeam(ctx, caller, target)
}

func (s *Server) identitiesShareTeam(ctx context.Context, a, b string) (bool, error) {
	return s.Store.IdentitiesShareTeam(ctx, a, b)
}
