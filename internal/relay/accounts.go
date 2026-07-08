package relay

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/store"
)

// sessionTTL is how long a UI login session stays valid.
const sessionTTL = 30 * 24 * time.Hour

// bearerResolver resolves a presented bearer credential to an identity by
// consulting, in order: UI login sessions, DB machine tokens, and the legacy
// file token registry (seed). All three yield an identity; role/account state
// is looked up separately by identity, independent of credential type.
type bearerResolver struct {
	store *store.Store
	seed  auth.Resolver
}

func (b *bearerResolver) Resolve(ctx context.Context, raw string) (string, bool) {
	h := auth.HashToken(raw)
	if id, ok, err := b.store.SessionIdentity(ctx, h, time.Now()); err == nil && ok {
		return b.active(ctx, id)
	}
	if id, ok, err := b.store.MachineTokenIdentity(ctx, h); err == nil && ok {
		return b.active(ctx, id)
	}
	if b.seed != nil {
		if id, ok := b.seed.Resolve(ctx, raw); ok {
			return b.active(ctx, id)
		}
	}
	return "", false
}

func (b *bearerResolver) active(ctx context.Context, identity string) (string, bool) {
	if ok, err := b.store.UserActive(ctx, identity); err == nil && ok {
		return identity, true
	}
	return "", false
}

// isAdmin reports whether identity is an effective admin: an operator-seeded
// admin (SeedAdmins) or a DB-flagged one (users.is_admin). A disabled DB user
// is never effective, even if it also appears in SeedAdmins; missing DB users
// remain allowed so operator seed admins cannot be locked out accidentally.
func (s *Server) isAdmin(ctx context.Context, identity string) bool {
	active, err := s.Store.UserActive(ctx, identity)
	if err != nil || !active {
		return false
	}
	if slices.Contains(s.SeedAdmins, identity) {
		return true
	}
	ok, err := s.Store.UserIsAdmin(ctx, identity)
	return err == nil && ok
}

// login verifies an account's password and issues a session token, returned in
// the JSON body; the UI sends it back as a normal Bearer. Unauthenticated
// (registered outside the auth middleware).
func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Identity string `json:"identity"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	identity := strings.TrimSpace(req.Identity)
	u, err := s.Store.GetUser(r.Context(), identity)
	// Uniform failure — don't leak which of {no account, wrong password,
	// disabled} occurred.
	if err != nil || u.Disabled || u.PasswordHash == "" || !auth.CheckPassword(u.PasswordHash, req.Password) {
		http.Error(w, "invalid credentials", http.StatusUnauthorized)
		return
	}
	s.issueSession(w, r, u.Identity, http.StatusOK)
}

// register provisions a normal (non-admin, enabled) account from {identity,
// password} and immediately issues a session, so the new user is signed in
// without a separate login. Open self-registration: no admin, no invite, no
// approval. Like login, it's registered on the outer mux (bypasses the auth
// middleware) since the caller has no token yet.
func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Identity string `json:"identity"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	identity := strings.TrimSpace(req.Identity)
	if identity == "" {
		http.Error(w, "identity required", http.StatusBadRequest)
		return
	}
	if req.Password == "" {
		http.Error(w, "password required", http.StatusBadRequest)
		return
	}
	reserved, err := s.identityReserved(r.Context(), identity)
	if err != nil {
		http.Error(w, "check identity: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if reserved {
		http.Error(w, "该账号已注册", http.StatusConflict)
		return
	}
	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := s.Store.CreateUser(r.Context(), store.User{
		Identity: identity, PasswordHash: hash,
	}, time.Now()); err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			http.Error(w, "该账号已注册", http.StatusConflict)
			return
		}
		http.Error(w, "create user: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if _, err := s.Store.EnsureDefaultOrganization(r.Context(), identity, time.Now().UTC()); err != nil {
		http.Error(w, "create organization: "+err.Error(), http.StatusInternalServerError)
		return
	}
	s.issueSession(w, r, identity, http.StatusCreated)
}

func (s *Server) identityReserved(ctx context.Context, identity string) (bool, error) {
	if _, err := s.Store.GetUser(ctx, identity); err == nil {
		return true, nil
	} else if !errors.Is(err, store.ErrNotFound) {
		return false, err
	}
	tokens, err := s.Store.ListMachineTokens(ctx, identity)
	if err != nil {
		return false, err
	}
	if len(tokens) > 0 {
		return true, nil
	}
	return s.Tokens != nil && slices.Contains(s.Tokens.Identities(), identity), nil
}

// issueSession mints a session token for identity, persists it, and writes the
// standard auth body ({token, identity, is_admin}) with status. Shared by login
// and register so both hand back an immediately-usable session.
func (s *Server) issueSession(w http.ResponseWriter, r *http.Request, identity string, status int) {
	raw, err := auth.NewToken()
	if err != nil {
		http.Error(w, "mint session: "+err.Error(), http.StatusInternalServerError)
		return
	}
	now := time.Now()
	if err := s.Store.CreateSession(r.Context(), auth.HashToken(raw), identity, now, now.Add(sessionTTL)); err != nil {
		http.Error(w, "create session: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, status, map[string]any{
		"token":    raw,
		"identity": identity,
		"is_admin": s.isAdmin(r.Context(), identity),
	})
}

// logout revokes the caller's current session (if the presented bearer is one).
// Machine tokens are unaffected.
func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if raw, ok := bearerToken(r); ok {
		_ = s.Store.DeleteSession(r.Context(), auth.HashToken(raw))
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// me returns the caller's identity, effective admin flag, and project
// memberships (with roles) so the UI can decide which views to show.
func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	projects, err := s.Store.MemberProjects(r.Context(), identity)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	organizations, err := s.Store.MemberOrganizations(r.Context(), identity)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if projects == nil {
		projects = []store.ProjectRole{}
	}
	if organizations == nil {
		organizations = []store.OrganizationRole{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"identity":      identity,
		"is_admin":      s.isAdmin(r.Context(), identity),
		"organizations": organizations,
		"projects":      projects,
	})
}

// --- account management (admin only) ---

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	users, err := s.Store.ListUsers(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

// createUser provisions an account. With no password one is generated and
// returned once.
func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	var req struct {
		Identity    string `json:"identity"`
		Password    string `json:"password"`
		DisplayName string `json:"display_name"`
		IsAdmin     bool   `json:"is_admin"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	identity := strings.TrimSpace(req.Identity)
	if identity == "" {
		http.Error(w, "identity required", http.StatusBadRequest)
		return
	}
	pw, generated := req.Password, false
	if pw == "" {
		var err error
		if pw, err = auth.GeneratePassword(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		generated = true
	}
	hash, err := auth.HashPassword(pw)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := s.Store.CreateUser(r.Context(), store.User{
		Identity: identity, PasswordHash: hash, DisplayName: req.DisplayName, IsAdmin: req.IsAdmin,
	}, time.Now()); err != nil {
		code := http.StatusInternalServerError
		if strings.Contains(err.Error(), "UNIQUE") {
			code = http.StatusConflict
		}
		http.Error(w, "create user: "+err.Error(), code)
		return
	}
	if _, err := s.Store.EnsureDefaultOrganization(r.Context(), identity, time.Now().UTC()); err != nil {
		http.Error(w, "create organization: "+err.Error(), http.StatusInternalServerError)
		return
	}
	resp := map[string]any{"identity": identity, "is_admin": req.IsAdmin}
	if generated {
		resp["password"] = pw
	}
	writeJSON(w, http.StatusCreated, resp)
}

func (s *Server) setUserAdmin(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	var req struct {
		IsAdmin bool `json:"is_admin"`
	}
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req)
	if err := s.Store.SetAdmin(r.Context(), r.PathValue("id"), req.IsAdmin); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) setUserDisabled(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	var req struct {
		Disabled bool `json:"disabled"`
	}
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req)
	if err := s.Store.SetDisabled(r.Context(), r.PathValue("id"), req.Disabled); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// resetUserPassword generates a new password for an account and returns it once.
func (s *Server) resetUserPassword(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	pw, err := auth.GeneratePassword()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	hash, err := auth.HashPassword(pw)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := s.Store.SetPasswordHash(r.Context(), r.PathValue("id"), hash); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"password": pw})
}

// changePassword updates the caller's own password after verifying the old one.
func (s *Server) changePassword(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var req struct {
		Old string `json:"old"`
		New string `json:"new"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(req.New) < 8 {
		http.Error(w, "new password must be at least 8 characters", http.StatusBadRequest)
		return
	}
	u, err := s.Store.GetUser(r.Context(), identity)
	if err != nil || u.PasswordHash == "" || !auth.CheckPassword(u.PasswordHash, req.Old) {
		http.Error(w, "old password incorrect", http.StatusForbidden)
		return
	}
	hash, err := auth.HashPassword(req.New)
	if err != nil {
		http.Error(w, "hash: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if err := s.Store.SetPasswordHash(r.Context(), identity, hash); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// bearerToken extracts the raw bearer credential from the request, if present.
func bearerToken(r *http.Request) (string, bool) {
	const prefix = "Bearer "
	hdr := r.Header.Get("Authorization")
	if !strings.HasPrefix(hdr, prefix) {
		return "", false
	}
	return strings.TrimPrefix(hdr, prefix), true
}
