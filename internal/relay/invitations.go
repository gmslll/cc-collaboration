package relay

import (
	"net/http"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/store"
)

func (s *Server) listMyInvitations(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAccount(w, r); !ok {
		return
	}
	invitations, err := s.Store.ListInvitationsForIdentity(r.Context(), auth.Identity(r.Context()))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"invitations": invitations})
}

func (s *Server) createOrganizationInvitation(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("id")
	if !s.requireOrgManager(w, r, orgID) {
		return
	}
	var req struct {
		Identity string `json:"identity"`
		Role     string `json:"role"`
	}
	if err := decodeJSONBody(w, r, 16<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	role := strings.TrimSpace(req.Role)
	if role == "" {
		role = store.OrgRoleMember
	}
	inv, err := s.Store.CreateOrganizationInvitation(
		r.Context(),
		handoff.NewID(time.Now().UTC()),
		orgID,
		req.Identity,
		role,
		auth.Identity(r.Context()),
		time.Now().UTC(),
	)
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"invitation": inv})
}

func (s *Server) cancelOrganizationInvitation(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("id")
	if !s.requireOrgManager(w, r, orgID) {
		return
	}
	inv, err := s.Store.GetInvitation(r.Context(), r.PathValue("invitation_id"))
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if inv.Scope != store.InvitationScopeOrg || inv.OrgID != strings.TrimSpace(orgID) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err := s.Store.DeleteInvitation(r.Context(), inv.ID); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) createProjectInvitation(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("id")
	if !s.requireProjectManager(w, r, projectID) {
		return
	}
	var req struct {
		Identity string `json:"identity"`
		Role     string `json:"role"`
	}
	if err := decodeJSONBody(w, r, 16<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	role := strings.TrimSpace(req.Role)
	if role == "" {
		role = store.RoleMember
	}
	if !s.canInviteProjectTarget(w, r, projectID, req.Identity) {
		return
	}
	inv, err := s.Store.CreateProjectInvitation(
		r.Context(),
		handoff.NewID(time.Now().UTC()),
		projectID,
		req.Identity,
		role,
		auth.Identity(r.Context()),
		time.Now().UTC(),
	)
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"invitation": inv})
}

func (s *Server) cancelProjectInvitation(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("id")
	if !s.requireProjectManager(w, r, projectID) {
		return
	}
	inv, err := s.Store.GetInvitation(r.Context(), r.PathValue("invitation_id"))
	if err != nil {
		s.writeStoreErr(w, err)
		return
	}
	if inv.Scope != store.InvitationScopeProject || inv.ProjectID != strings.TrimSpace(projectID) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err := s.Store.DeleteInvitation(r.Context(), inv.ID); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) acceptInvitation(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAccount(w, r); !ok {
		return
	}
	if err := s.Store.AcceptInvitation(r.Context(), r.PathValue("id"), auth.Identity(r.Context())); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) declineInvitation(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAccount(w, r); !ok {
		return
	}
	if err := s.Store.DeclineInvitation(r.Context(), r.PathValue("id"), auth.Identity(r.Context())); err != nil {
		s.writeStoreErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) canInviteProjectTarget(w http.ResponseWriter, r *http.Request, projectID, targetIdentity string) bool {
	targetIdentity = strings.TrimSpace(targetIdentity)
	if targetIdentity == "" {
		http.Error(w, "identity required", http.StatusBadRequest)
		return false
	}
	project, err := s.Store.GetProject(r.Context(), projectID)
	if err != nil {
		s.writeStoreErr(w, err)
		return false
	}
	if _, ok, err := s.Store.OrganizationMemberRole(r.Context(), project.OrgID, targetIdentity); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return false
	} else if ok {
		return true
	}
	return true
}
