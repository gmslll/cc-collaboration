package relay

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/store"
)

// requireAdmin gates a handler to effective admins (seed or DB-flagged).
func (s *Server) requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	if s.isAdmin(r.Context(), auth.Identity(r.Context())) {
		return true
	}
	http.Error(w, "admin only", http.StatusForbidden)
	return false
}

// requireProjectRole gates a handler to a global admin, or a project member
// whose role satisfies ok(role). Writes a 403 and returns false otherwise.
func (s *Server) requireProjectRole(w http.ResponseWriter, r *http.Request, projectID string, ok func(role string) bool) bool {
	identity := auth.Identity(r.Context())
	if s.isAdmin(r.Context(), identity) {
		return true
	}
	if role, found, err := s.Store.MemberRole(r.Context(), projectID, identity); err == nil && found && ok(role) {
		return true
	}
	http.Error(w, "forbidden", http.StatusForbidden)
	return false
}

// requireProjectOwner gates a handler to the project's owner or a global admin.
func (s *Server) requireProjectOwner(w http.ResponseWriter, r *http.Request, projectID string) bool {
	return s.requireProjectRole(w, r, projectID, func(role string) bool { return role == store.RoleOwner })
}

// requireProjectMember gates a handler to any member of the project (or admin).
func (s *Server) requireProjectMember(w http.ResponseWriter, r *http.Request, projectID string) bool {
	return s.requireProjectRole(w, r, projectID, func(string) bool { return true })
}

// createProject is self-service: any authenticated user creates a project and
// becomes its owner.
func (s *Server) createProject(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var req struct {
		Name  string `json:"name"`
		OrgID string `json:"org_id"`
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
	var err error
	orgID := strings.TrimSpace(req.OrgID)
	if orgID == "" {
		err = s.Store.CreateProject(r.Context(), id, name, identity, now)
	} else {
		if !s.requireOrgManager(w, r, orgID) {
			return
		}
		if _, err := s.Store.GetOrganization(r.Context(), orgID); err != nil {
			s.writeStoreErr(w, err)
			return
		}
		if _, ok, err := s.Store.OrganizationMemberRole(r.Context(), orgID, identity); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		} else if !ok && s.isAdmin(r.Context(), identity) {
			if err := s.Store.AddOrganizationMember(r.Context(), orgID, identity, store.OrgRoleAdmin); err != nil {
				s.writeStoreErr(w, err)
				return
			}
		}
		err = s.Store.CreateProjectInOrg(r.Context(), id, orgID, name, identity, now)
	}
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	p, _ := s.Store.GetProject(r.Context(), id)
	p.Role = store.RoleOwner
	writeJSON(w, http.StatusCreated, p)
}

// listProjects returns all projects for an admin, else the caller's projects.
func (s *Server) listProjects(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var (
		ps  []store.Project
		err error
	)
	if s.isAdmin(r.Context(), identity) {
		ps, err = s.Store.ListProjects(r.Context())
		for i := range ps {
			ps[i].Role = "admin"
		}
	} else {
		ps, err = s.Store.ListProjectsForIdentity(r.Context(), identity)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"projects": ps})
}

// getProject returns a project with its repos + members (any member or admin).
func (s *Server) getProject(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.requireProjectMember(w, r, id) {
		return
	}
	p, err := s.Store.GetProject(r.Context(), id)
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	repos, err := s.Store.ListProjectRepos(r.Context(), id)
	if err != nil {
		http.Error(w, "list project repos: "+err.Error(), http.StatusInternalServerError)
		return
	}
	members, err := s.Store.ListMembers(r.Context(), id)
	if err != nil {
		http.Error(w, "list project members: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"project": p, "repos": repos, "members": members})
}

func (s *Server) renameProject(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.requireProjectOwner(w, r, id) {
		return
	}
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "name required", http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		http.Error(w, "name required", http.StatusBadRequest)
		return
	}
	if err := s.Store.RenameProject(r.Context(), id, name); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) deleteProject(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.requireProjectOwner(w, r, id) {
		return
	}
	if err := s.Store.DeleteProject(r.Context(), id); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) mapRepo(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.requireProjectOwner(w, r, id) {
		return
	}
	var req struct {
		RepoName string `json:"repo_name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil || strings.TrimSpace(req.RepoName) == "" {
		http.Error(w, "repo_name required", http.StatusBadRequest)
		return
	}
	if err := s.Store.MapRepo(r.Context(), req.RepoName, id); err != nil {
		http.Error(w, "map repo: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// unmapRepo takes the repo name as a query param (repo names can contain "/",
// which would break a path segment).
func (s *Server) unmapRepo(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.requireProjectOwner(w, r, id) {
		return
	}
	repo := r.URL.Query().Get("repo_name")
	if repo == "" {
		http.Error(w, "repo_name query param required", http.StatusBadRequest)
		return
	}
	if err := s.Store.UnmapRepo(r.Context(), repo); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) addMember(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.requireProjectOwner(w, r, id) {
		return
	}
	caller := auth.Identity(r.Context())
	var req struct {
		Identity string `json:"identity"`
		Role     string `json:"role"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.Identity) == "" || !store.ValidRole(req.Role) {
		http.Error(w, "identity and role (owner|member|viewer) required", http.StatusBadRequest)
		return
	}
	identity := strings.TrimSpace(req.Identity)
	u, err := s.Store.GetUser(r.Context(), identity)
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if u.Disabled {
		http.Error(w, "user disabled", http.StatusBadRequest)
		return
	}
	p, err := s.Store.GetProject(r.Context(), id)
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if _, ok, err := s.Store.OrganizationMemberRole(r.Context(), p.OrgID, identity); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	} else if !ok {
		if !s.isAdmin(r.Context(), caller) {
			role, callerInOrg, err := s.Store.OrganizationMemberRole(r.Context(), p.OrgID, caller)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			if !callerInOrg || !store.OrgRoleCanManage(role) {
				http.Error(w, "target user must already belong to the team", http.StatusForbidden)
				return
			}
		}
		if err := s.Store.AddOrganizationMember(r.Context(), p.OrgID, identity, store.OrgRoleMember); err != nil {
			s.writeStoreErr(w, err)
			return
		}
	}
	if err := s.Store.AddMember(r.Context(), id, identity, req.Role); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) removeMember(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.requireProjectOwner(w, r, id) {
		return
	}
	if err := s.Store.RemoveMember(r.Context(), id, r.PathValue("identity")); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// writeStoreErr maps store.ErrNotFound to 404, anything else to 500.
func (s *Server) writeStoreErr(w http.ResponseWriter, err error) {
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if errors.Is(err, store.ErrForbidden) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if errors.Is(err, store.ErrLastOwner) {
		http.Error(w, "last owner cannot be removed", http.StatusConflict)
		return
	}
	http.Error(w, err.Error(), http.StatusInternalServerError)
}
