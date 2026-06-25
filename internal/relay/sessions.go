package relay

import (
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
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	s.Sessions.set(identity, body.Sessions)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// getUserSessions returns another user's currently-open sessions (empty if
// offline / never published / expired). Any authenticated user may query — it's
// presence-level info, like /v1/users/online.
func (s *Server) getUserSessions(w http.ResponseWriter, r *http.Request) {
	sessions := s.Sessions.get(r.PathValue("identity"))
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
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&msg); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(msg.Recipient) == "" {
		http.Error(w, "recipient required", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(msg.Body) == "" {
		http.Error(w, "body required", http.StatusBadRequest)
		return
	}
	if s.Hub != nil {
		out := handoffschema.Message{From: sender, SessionID: msg.SessionID, Body: msg.Body}
		if data, err := json.Marshal(out); err == nil {
			s.Hub.Publish(sse.Event{Type: sse.EventTypeMessageDeliver, Recipient: msg.Recipient, Data: data})
		}
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true})
}
