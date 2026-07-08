package relay

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/store"
)

func (s *Server) requireOrgRole(w http.ResponseWriter, r *http.Request, orgID string, ok func(role string) bool) bool {
	identity := auth.Identity(r.Context())
	if s.isAdmin(r.Context(), identity) {
		return true
	}
	if role, found, err := s.Store.OrganizationMemberRole(r.Context(), orgID, identity); err == nil && found && ok(role) {
		return true
	}
	http.Error(w, "forbidden", http.StatusForbidden)
	return false
}

func (s *Server) requireOrgMember(w http.ResponseWriter, r *http.Request, orgID string) bool {
	return s.requireOrgRole(w, r, orgID, func(string) bool { return true })
}

func (s *Server) requireOrgManager(w http.ResponseWriter, r *http.Request, orgID string) bool {
	return s.requireOrgRole(w, r, orgID, store.OrgRoleCanManage)
}

func (s *Server) createOrganization(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		http.Error(w, "name required", http.StatusBadRequest)
		return
	}
	now := time.Now().UTC()
	id := handoff.NewID(now)
	if err := s.Store.CreateOrganization(r.Context(), id, name, identity, now); err != nil {
		http.Error(w, "create organization: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, store.Organization{ID: id, Name: name, OwnerIdentity: identity, CreatedAt: now})
}

func (s *Server) listOrganizations(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var (
		orgs []store.Organization
		err  error
	)
	if s.isAdmin(r.Context(), identity) {
		orgs, err = s.Store.ListOrganizations(r.Context())
	} else {
		orgs, err = s.Store.ListOrganizationsForIdentity(r.Context(), identity)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"organizations": orgs})
}

func (s *Server) getOrganization(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("id")
	if !s.requireOrgMember(w, r, orgID) {
		return
	}
	org, err := s.Store.GetOrganization(r.Context(), orgID)
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	members, err := s.Store.ListOrganizationMembers(r.Context(), orgID)
	if err != nil {
		http.Error(w, "list organization members: "+err.Error(), http.StatusInternalServerError)
		return
	}
	projects, err := s.Store.ListProjectsForOrganization(r.Context(), orgID)
	if err != nil {
		http.Error(w, "list organization projects: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"organization": org,
		"members":      members,
		"projects":     projects,
	})
}

func (s *Server) addOrganizationMember(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("id")
	if !s.requireOrgManager(w, r, orgID) {
		return
	}
	if _, err := s.Store.GetOrganization(r.Context(), orgID); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	var req struct {
		Identity string `json:"identity"`
		Role     string `json:"role"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	identity := strings.TrimSpace(req.Identity)
	role := strings.TrimSpace(req.Role)
	if role == "" {
		role = store.OrgRoleMember
	}
	if identity == "" || !store.ValidOrgRole(role) {
		http.Error(w, "identity and role (owner|admin|member|guest) required", http.StatusBadRequest)
		return
	}
	u, err := s.Store.GetUser(r.Context(), identity)
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if u.Disabled {
		http.Error(w, "user disabled", http.StatusBadRequest)
		return
	}
	if err := s.Store.AddOrganizationMember(r.Context(), orgID, identity, role); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) removeOrganizationMember(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("id")
	if !s.requireOrgManager(w, r, orgID) {
		return
	}
	if _, err := s.Store.GetOrganization(r.Context(), orgID); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if err := s.Store.RemoveOrganizationMember(r.Context(), orgID, r.PathValue("identity")); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
