package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestOrganizationInvitationAcceptsIntoTeam(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}

	inv, err := st.CreateOrganizationInvitation(ctx, "inv1", "org1", " dev@x ", " member ", "owner@x", now)
	if err != nil {
		t.Fatal(err)
	}
	if inv.Identity != "dev@x" || inv.Role != OrgRoleMember || inv.OrgName != "Acme" {
		t.Fatalf("invitation not normalized/enriched: %+v", inv)
	}
	pending, err := st.ListInvitationsForIdentity(ctx, "dev@x")
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 || pending[0].ID != "inv1" {
		t.Fatalf("pending invitations = %+v", pending)
	}
	if err := st.AcceptInvitation(ctx, "inv1", "dev@x"); err != nil {
		t.Fatal(err)
	}
	if role, ok, err := st.OrganizationMemberRole(ctx, "org1", "dev@x"); err != nil || !ok || role != OrgRoleMember {
		t.Fatalf("accepted organization role = %q ok=%v err=%v", role, ok, err)
	}
	pending, err = st.ListInvitationsForIdentity(ctx, "dev@x")
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 0 {
		t.Fatalf("accepted invitation still pending: %+v", pending)
	}
}

func TestOrganizationInvitationUpsertReturnsLatestID(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateOrganizationInvitation(ctx, "inv-old", "org1", "dev@x", OrgRoleMember, "owner@x", now); err != nil {
		t.Fatal(err)
	}
	inv, err := st.CreateOrganizationInvitation(ctx, "inv-new", "org1", "dev@x", OrgRoleAdmin, "owner@x", now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if inv.ID != "inv-new" || inv.Role != OrgRoleAdmin {
		t.Fatalf("upserted invitation = %+v", inv)
	}
	pending, err := st.ListInvitationsForIdentity(ctx, "dev@x")
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 || pending[0].ID != "inv-new" {
		t.Fatalf("pending invitations after upsert = %+v", pending)
	}
}

func TestProjectInvitationAcceptAddsTeamAndProjectMembership(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "p1", "org1", "Backend", "owner@x", now); err != nil {
		t.Fatal(err)
	}

	inv, err := st.CreateProjectInvitation(ctx, "inv1", "p1", "dev@x", RoleMember, "owner@x", now)
	if err != nil {
		t.Fatal(err)
	}
	if inv.Scope != InvitationScopeProject || inv.ProjectName != "Backend" || inv.OrgName != "Acme" {
		t.Fatalf("project invitation not enriched: %+v", inv)
	}
	if err := st.AcceptInvitation(ctx, "inv1", "dev@x"); err != nil {
		t.Fatal(err)
	}
	if role, ok, err := st.OrganizationMemberRole(ctx, "org1", "dev@x"); err != nil || !ok || role != OrgRoleMember {
		t.Fatalf("accepted project invitation organization role = %q ok=%v err=%v", role, ok, err)
	}
	if role, ok, err := st.MemberRole(ctx, "p1", "dev@x"); err != nil || !ok || role != RoleMember {
		t.Fatalf("accepted project role = %q ok=%v err=%v", role, ok, err)
	}
}

func TestAcceptInvitationAppliesRoleAfterProjectInviteCreatedTeamMembership(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "p1", "org1", "Backend", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateOrganizationInvitation(ctx, "org-inv", "org1", "dev@x", OrgRoleAdmin, "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateProjectInvitation(ctx, "project-inv", "p1", "dev@x", RoleMember, "owner@x", now); err != nil {
		t.Fatal(err)
	}

	if err := st.AcceptInvitation(ctx, "project-inv", "dev@x"); err != nil {
		t.Fatal(err)
	}
	if role, ok, err := st.OrganizationMemberRole(ctx, "org1", "dev@x"); err != nil || !ok || role != OrgRoleMember {
		t.Fatalf("project invite organization role = %q ok=%v err=%v", role, ok, err)
	}
	if err := st.AcceptInvitation(ctx, "org-inv", "dev@x"); err != nil {
		t.Fatal(err)
	}
	if role, ok, err := st.OrganizationMemberRole(ctx, "org1", "dev@x"); err != nil || !ok || role != OrgRoleAdmin {
		t.Fatalf("organization invite should upgrade role after project invite: role=%q ok=%v err=%v", role, ok, err)
	}
}

func TestAcceptProjectInvitationDoesNotDemoteExistingOwner(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "p1", "org1", "Backend", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateProjectInvitation(ctx, "project-inv", "p1", "dev@x", RoleMember, "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "dev@x", OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "dev@x", RoleOwner); err != nil {
		t.Fatal(err)
	}

	if err := st.AcceptInvitation(ctx, "project-inv", "dev@x"); err != nil {
		t.Fatal(err)
	}
	if role, ok, err := st.MemberRole(ctx, "p1", "dev@x"); err != nil || !ok || role != RoleOwner {
		t.Fatalf("project owner should not be demoted by stale invite: role=%q ok=%v err=%v", role, ok, err)
	}
}

func TestDeleteProjectRemovesPendingProjectInvitations(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "p1", "org1", "Backend", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateProjectInvitation(ctx, "project-inv", "p1", "dev@x", RoleMember, "owner@x", now); err != nil {
		t.Fatal(err)
	}

	if err := st.DeleteProject(ctx, "p1"); err != nil {
		t.Fatal(err)
	}
	pending, err := st.ListInvitationsForIdentity(ctx, "dev@x")
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 0 {
		t.Fatalf("deleted project invitation still pending: %+v", pending)
	}
}

func TestDeleteEmptyDefaultOrganizationRemovesPendingInvitations(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateUser(ctx, User{Identity: "owner@x"}, now); err != nil {
		t.Fatal(err)
	}
	org, err := st.EnsureDefaultOrganization(ctx, "owner@x", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateOrganizationInvitation(ctx, "org-inv", org.ID, "dev@x", OrgRoleMember, "owner@x", now); err != nil {
		t.Fatal(err)
	}

	if err := st.SetDisabled(ctx, "owner@x", true); err != nil {
		t.Fatal(err)
	}
	pending, err := st.ListInvitationsForIdentity(ctx, "dev@x")
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 0 {
		t.Fatalf("deleted organization invitation still pending: %+v", pending)
	}
}

func TestAcceptInvitationRemovesMissingOrganizationInvitation(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if _, err := st.db.ExecContext(ctx,
		`INSERT INTO invitations(id, scope, org_id, project_id, identity, role, inviter_identity, created_at)
		 VALUES(?, ?, ?, '', ?, ?, ?, ?)`,
		"orphan-org", InvitationScopeOrg, "missing-org", "dev@x", OrgRoleMember, "owner@x", now.UnixMilli()); err != nil {
		t.Fatal(err)
	}

	if err := st.AcceptInvitation(ctx, "orphan-org", "dev@x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing organization accept = %v, want ErrNotFound", err)
	}
	pending, err := st.ListInvitationsForIdentity(ctx, "dev@x")
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 0 {
		t.Fatalf("missing organization invitation still pending: %+v", pending)
	}
}

func TestAcceptInvitationRemovesMissingProjectInvitation(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`INSERT INTO invitations(id, scope, org_id, project_id, identity, role, inviter_identity, created_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		"orphan-project", InvitationScopeProject, "org1", "missing-project", "dev@x", RoleMember, "owner@x", now.UnixMilli()); err != nil {
		t.Fatal(err)
	}

	if err := st.AcceptInvitation(ctx, "orphan-project", "dev@x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing project accept = %v, want ErrNotFound", err)
	}
	pending, err := st.ListInvitationsForIdentity(ctx, "dev@x")
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 0 {
		t.Fatalf("missing project invitation still pending: %+v", pending)
	}
}
