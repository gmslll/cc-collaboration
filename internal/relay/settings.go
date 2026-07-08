package relay

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/cc-collaboration/internal/relay/auth"
)

const maxSettingBodyBytes = 64 << 10
const maxSettingKeyBytes = 128

// Per-identity synced settings: a tiny key -> opaque-JSON store scoped to the
// caller's identity. Used so a user's own devices (same identity) show an
// identical view — the Todo board's scope / team source / Linear team key —
// without every device having to reconfigure local prefs. The relay treats the
// value as an opaque blob; only the client knows its shape.

// getSetting returns {"found": true, "value": <json>} for the caller's key, or
// {"found": false} when unset (so the client falls back to its local default).
func (s *Server) getSetting(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	key := r.PathValue("key")
	if !validSettingKey(w, key) {
		return
	}
	value, found, err := s.Store.GetSetting(r.Context(), identity, key)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !found {
		writeJSON(w, http.StatusOK, map[string]any{"found": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"found": true,
		"value": json.RawMessage(value),
	})
}

// putSetting upserts the caller's key from a {"value": <json>} body. The value
// is any JSON the client owns; the relay stores it verbatim.
func (s *Server) putSetting(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	key := r.PathValue("key")
	if !validSettingKey(w, key) {
		return
	}
	var body struct {
		Value json.RawMessage `json:"value"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxSettingBodyBytes)).Decode(&body); err != nil {
		http.Error(w, "invalid body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(body.Value) == 0 {
		http.Error(w, "missing value", http.StatusBadRequest)
		return
	}
	if err := s.Store.SetSetting(r.Context(), identity, key, string(body.Value)); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func validSettingKey(w http.ResponseWriter, key string) bool {
	if strings.TrimSpace(key) == "" {
		http.Error(w, "missing key", http.StatusBadRequest)
		return false
	}
	if len(key) > maxSettingKeyBytes {
		http.Error(w, "key too long", http.StatusBadRequest)
		return false
	}
	return true
}
