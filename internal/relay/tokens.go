package relay

import (
	"context"
	"net/http"
	"time"

	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/store"
)

// Self-service machine tokens. Any authenticated user manages their OWN
// long-lived bearer tokens (for CLI / watch / MCP); the raw value is shown once
// at creation. These are distinct from the operator-managed tokens.json, which
// the resolver still accepts unchanged.

// listTokens lists the caller's machine tokens (id = hash, never the raw value).
func (s *Server) listTokens(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAccount(w, r); !ok {
		return
	}
	identity := auth.Identity(r.Context())
	toks, err := s.Store.ListMachineTokens(r.Context(), identity)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if toks == nil {
		toks = []store.MachineToken{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"tokens": toks})
}

// createToken mints a machine token for the caller and returns the raw value
// once. Only its hash is stored.
func (s *Server) createToken(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAccount(w, r); !ok {
		return
	}
	identity := auth.Identity(r.Context())
	var req struct {
		Label string `json:"label"`
	}
	if err := decodeJSONBody(w, r, 4<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}

	raw, id, err := s.createMachineToken(r.Context(), identity, req.Label, time.Now())
	if err != nil {
		http.Error(w, "create token: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"token": raw, "label": req.Label, "id": id})
}

func (s *Server) createMachineToken(ctx context.Context, identity, label string, now time.Time) (string, string, error) {
	raw, err := auth.NewToken()
	if err != nil {
		return "", "", err
	}
	id := auth.HashToken(raw)
	if err := s.Store.CreateMachineToken(ctx, id, identity, label, now); err != nil {
		return "", "", err
	}
	return raw, id, nil
}

// deleteToken revokes one of the caller's tokens by id (its hash). Scoped to the
// owner, so revoking a token you don't own is a 404.
func (s *Server) deleteToken(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAccount(w, r); !ok {
		return
	}
	identity := auth.Identity(r.Context())
	if err := s.Store.DeleteMachineToken(r.Context(), identity, r.PathValue("id")); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
