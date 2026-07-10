package relay

import (
	"context"
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

// requireAccount gates SaaS/team-account features to real DB accounts.
// Legacy tokens.json identities can still authenticate for backwards-compatible
// automation, but they must register/login before owning teams or minting
// account-scoped machine tokens.
func (s *Server) requireAccount(w http.ResponseWriter, r *http.Request) (store.User, bool) {
	identity := auth.Identity(r.Context())
	u, err := s.Store.GetUser(r.Context(), identity)
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "请先注册或登录账号", http.StatusUnauthorized)
		return store.User{}, false
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return store.User{}, false
	}
	if u.Deleted {
		http.Error(w, "账号已删除", http.StatusForbidden)
		return store.User{}, false
	}
	if u.Disabled {
		http.Error(w, "账号已停用", http.StatusForbidden)
		return store.User{}, false
	}
	return u, true
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
	if err := decodeJSONBody(w, r, 16<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	identity := strings.TrimSpace(req.Identity)
	u, err := s.Store.GetUser(r.Context(), identity)
	// Uniform failure — don't leak which of {no account, wrong password,
	// disabled} occurred.
	if err != nil || u.Disabled || u.Deleted || u.PasswordHash == "" || !auth.CheckPassword(u.PasswordHash, req.Password) {
		http.Error(w, "invalid credentials", http.StatusUnauthorized)
		return
	}
	s.issueSession(w, r, u.Identity, http.StatusOK)
}

// register provisions a normal (non-admin, enabled) account from {identity,
// password} and immediately issues a session, so the new user is signed in
// without a separate login. It can be disabled for enterprise deployments.
// Like login, it is registered on the outer mux because the caller has no
// bearer token yet.
func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	if s.DisableRegistration {
		http.Error(w, "self-registration disabled", http.StatusForbidden)
		return
	}
	var req struct {
		Identity string `json:"identity"`
		Password string `json:"password"`
	}
	if err := decodeJSONBody(w, r, 16<<10, &req); err != nil {
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
	machineToken, machineTokenID, err := s.createMachineToken(r.Context(), identity, "default", time.Now())
	if err != nil {
		http.Error(w, "create machine token: "+err.Error(), http.StatusInternalServerError)
		return
	}
	resp, err := s.newSessionResponse(r, identity)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	resp["machine_token"] = machineToken
	resp["machine_token_id"] = machineTokenID
	writeJSON(w, http.StatusCreated, resp)
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
	resp, err := s.newSessionResponse(r, identity)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, status, resp)
}

func (s *Server) newSessionResponse(r *http.Request, identity string) (map[string]any, error) {
	raw, err := auth.NewToken()
	if err != nil {
		return nil, errors.New("mint session: " + err.Error())
	}
	now := time.Now()
	if err := s.Store.CreateSession(r.Context(), auth.HashToken(raw), identity, now, now.Add(sessionTTL)); err != nil {
		return nil, errors.New("create session: " + err.Error())
	}
	return map[string]any{
		"token":    raw,
		"identity": identity,
		"is_admin": s.isAdmin(r.Context(), identity),
	}, nil
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
	invitations, err := s.Store.ListInvitationsForIdentity(r.Context(), identity)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if invitations == nil {
		invitations = []store.Invitation{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"identity":      identity,
		"is_admin":      s.isAdmin(r.Context(), identity),
		"organizations": organizations,
		"projects":      projects,
		"invitations":   invitations,
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
	if err := decodeJSONBody(w, r, 16<<10, &req); err != nil {
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
	if err := decodeJSONBody(w, r, 4<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	s.accountMu.Lock()
	defer s.accountMu.Unlock()
	if !s.requireAdmin(w, r) {
		return
	}
	identity := strings.TrimSpace(r.PathValue("id"))
	if !req.IsAdmin {
		if identity == auth.Identity(r.Context()) {
			http.Error(w, "cannot demote current account", http.StatusConflict)
			return
		}
		if s.isAdmin(r.Context(), identity) {
			hasOther, err := s.hasOtherAvailableAdmin(r.Context(), identity)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			if !hasOther {
				http.Error(w, "last available admin cannot be demoted", http.StatusConflict)
				return
			}
		}
	}
	if err := s.Store.SetAdmin(r.Context(), identity, req.IsAdmin); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) setUserDisabled(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	identity := strings.TrimSpace(r.PathValue("id"))
	var req struct {
		Disabled bool `json:"disabled"`
	}
	if err := decodeJSONBody(w, r, 4<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	s.accountMu.Lock()
	defer s.accountMu.Unlock()
	if !s.requireAdmin(w, r) {
		return
	}
	if req.Disabled {
		if identity == auth.Identity(r.Context()) {
			http.Error(w, "cannot disable current account", http.StatusConflict)
			return
		}
		if s.isAdmin(r.Context(), identity) {
			hasOther, err := s.hasOtherAvailableAdmin(r.Context(), identity)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			if !hasOther {
				http.Error(w, "last available admin cannot be disabled", http.StatusConflict)
				return
			}
		}
	}
	if err := s.Store.SetDisabled(r.Context(), identity, req.Disabled); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if req.Disabled && s.Sessions != nil {
		s.Sessions.clear(identity)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// deleteUser irreversibly tombstones an account. Only a global admin may call
// it; the current account and the final effective admin are protected here,
// while the store owns the atomic credential/relationship transition.
func (s *Server) deleteUser(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	identity := strings.TrimSpace(r.PathValue("id"))
	if identity == "" {
		http.Error(w, "identity required", http.StatusBadRequest)
		return
	}
	if identity == auth.Identity(r.Context()) {
		http.Error(w, "cannot delete current account", http.StatusConflict)
		return
	}

	s.accountMu.Lock()
	defer s.accountMu.Unlock()
	if !s.requireAdmin(w, r) {
		return
	}
	u, err := s.Store.GetUser(r.Context(), identity)
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if u.Deleted {
		http.Error(w, "account already deleted", http.StatusNotFound)
		return
	}
	if s.isAdmin(r.Context(), identity) {
		hasOther, err := s.hasOtherAvailableAdmin(r.Context(), identity)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if !hasOther {
			http.Error(w, "last available admin cannot be deleted", http.StatusConflict)
			return
		}
	}
	if err := s.Store.DeleteUser(r.Context(), identity, time.Now().UTC()); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if s.Sessions != nil {
		s.Sessions.clear(identity)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) hasOtherAvailableAdmin(ctx context.Context, excluded string) (bool, error) {
	users, err := s.Store.ListUsers(ctx)
	if err != nil {
		return false, err
	}
	candidates := make(map[string]struct{}, len(users)+len(s.SeedAdmins))
	for _, identity := range s.SeedAdmins {
		if identity = strings.TrimSpace(identity); identity != "" {
			candidates[identity] = struct{}{}
		}
	}
	for _, u := range users {
		if u.IsAdmin {
			candidates[u.Identity] = struct{}{}
		}
	}
	for identity := range candidates {
		if identity != excluded && s.isAdmin(ctx, identity) {
			return true, nil
		}
	}
	return false, nil
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
	if err := decodeJSONBody(w, r, 16<<10, &req); err != nil {
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
