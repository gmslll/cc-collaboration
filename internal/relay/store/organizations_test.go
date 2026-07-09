package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestOrganizationsAndOwnerInvariant(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "admin@x", OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "other@x", OrgRoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := st.RemoveOrganizationMember(ctx, "org1", "owner@x"); err != nil {
		t.Fatal(err)
	}
	org, err := st.GetOrganization(ctx, "org1")
	if err != nil {
		t.Fatal(err)
	}
	if org.OwnerIdentity != "other@x" {
		t.Fatalf("owner_identity = %q", org.OwnerIdentity)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "other@x", OrgRoleAdmin); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("demote last owner: want ErrLastOwner, got %v", err)
	}
	if err := st.RemoveOrganizationMember(ctx, "org1", "other@x"); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("remove last owner: want ErrLastOwner, got %v", err)
	}
}

func TestOrganizationStoreNormalizesTeamInputs(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if !ValidOrgRole(" admin ") {
		t.Fatal("ValidOrgRole should accept padded roles")
	}
	if !OrgRoleCanManage(" admin ") {
		t.Fatal("OrgRoleCanManage should accept padded admin role")
	}
	if err := st.CreateOrganization(ctx, " org1 ", " Acme ", " owner@x ", now); err != nil {
		t.Fatal(err)
	}
	org, err := st.GetOrganization(ctx, " org1 ")
	if err != nil {
		t.Fatal(err)
	}
	if org.ID != "org1" || org.Name != "Acme" || org.OwnerIdentity != "owner@x" {
		t.Fatalf("organization not normalized: %+v", org)
	}

	if err := st.AddOrganizationMember(ctx, " org1 ", " admin@x ", " admin "); err != nil {
		t.Fatal(err)
	}
	if role, ok, err := st.OrganizationMemberRole(ctx, " org1 ", " admin@x "); err != nil || !ok || role != OrgRoleAdmin {
		t.Fatalf("organization member role = %q ok=%v err=%v", role, ok, err)
	}
	members, err := st.ListOrganizationMembers(ctx, " org1 ")
	if err != nil {
		t.Fatal(err)
	}
	for _, member := range members {
		if member.Identity == " admin@x " || member.Role == " admin " {
			t.Fatalf("padded organization member leaked into store: %+v", members)
		}
	}
	if orgs, err := st.MemberOrganizations(ctx, " admin@x "); err != nil || len(orgs) != 1 || orgs[0].ID != "org1" || orgs[0].Role != OrgRoleAdmin {
		t.Fatalf("member organizations = %+v err=%v", orgs, err)
	}
	if orgs, err := st.ListOrganizationsForIdentity(ctx, " admin@x "); err != nil || len(orgs) != 1 || orgs[0].ID != "org1" || orgs[0].Role != OrgRoleAdmin {
		t.Fatalf("organizations for identity = %+v err=%v", orgs, err)
	}
	if owners, err := st.CountOrganizationOwners(ctx, " org1 "); err != nil || owners != 1 {
		t.Fatalf("organization owners = %d err=%v", owners, err)
	}
	if err := st.RemoveOrganizationMember(ctx, " org1 ", " admin@x "); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := st.OrganizationMemberRole(ctx, "org1", "admin@x"); err != nil || ok {
		t.Fatalf("removed normalized organization member still present: ok=%v err=%v", ok, err)
	}
}

func TestOrganizationOwnerInvariantIgnoresDisabledOwners(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "disabled-owner@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "disabled-owner@x", OrgRoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := st.SetDisabled(ctx, "disabled-owner@x", true); err != nil {
		t.Fatal(err)
	}

	if err := st.AddOrganizationMember(ctx, "org1", "owner@x", OrgRoleAdmin); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("demote last active owner with disabled owner present: want ErrLastOwner, got %v", err)
	}
	if err := st.RemoveOrganizationMember(ctx, "org1", "owner@x"); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("remove last active owner with disabled owner present: want ErrLastOwner, got %v", err)
	}

	if err := st.CreateUser(ctx, User{Identity: "active-owner@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "active-owner@x", OrgRoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := st.RemoveOrganizationMember(ctx, "org1", "owner@x"); err != nil {
		t.Fatal(err)
	}
	org, err := st.GetOrganization(ctx, "org1")
	if err != nil {
		t.Fatal(err)
	}
	if org.OwnerIdentity != "active-owner@x" {
		t.Fatalf("owner_identity = %q, want active-owner@x", org.OwnerIdentity)
	}
}

func TestListOrganizationMembersHidesDisabledUsers(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "active@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "disabled@x", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	for _, identity := range []string{"active@x", "legacy@x"} {
		if err := st.AddOrganizationMember(ctx, "org1", identity, OrgRoleMember); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.CreateUser(ctx, User{Identity: "will-disable@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "will-disable@x", OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.SetDisabled(ctx, "will-disable@x", true); err != nil {
		t.Fatal(err)
	}

	members, err := st.ListOrganizationMembers(ctx, "org1")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, m := range members {
		got[m.Identity] = true
	}
	for _, want := range []string{"owner@x", "active@x", "legacy@x"} {
		if !got[want] {
			t.Fatalf("organization member %q missing from %+v", want, members)
		}
	}
	if got["disabled@x"] || got["will-disable@x"] {
		t.Fatalf("disabled organization member leaked into list: %+v", members)
	}
}

func TestOrganizationWriteRejectsDisabledUsers(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateUser(ctx, User{Identity: "disabled@x", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "disabled-org", "Disabled", "disabled@x", now); !errors.Is(err, ErrForbidden) {
		t.Fatalf("disabled owner create organization: want ErrForbidden, got %v", err)
	}
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "disabled@x", OrgRoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("add disabled organization member: want ErrForbidden, got %v", err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "legacy@x", OrgRoleMember); err != nil {
		t.Fatalf("legacy organization member should remain allowed: %v", err)
	}
}

func TestRemoveOrganizationMemberRevokesProjectMemberships(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "member@x", OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "p1", "org1", "App", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "member@x", RoleMember); err != nil {
		t.Fatal(err)
	}

	if err := st.RemoveOrganizationMember(ctx, "org1", "member@x"); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := st.OrganizationMemberRole(ctx, "org1", "member@x"); err != nil || ok {
		t.Fatalf("organization membership still present: ok=%v err=%v", ok, err)
	}
	if _, ok, err := st.MemberRole(ctx, "p1", "member@x"); err != nil || ok {
		t.Fatalf("project membership still present: ok=%v err=%v", ok, err)
	}
}

func TestRemoveOrganizationOwnerProtectsProjectOwnerInvariant(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "other@x", OrgRoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "p1", "org1", "App", "owner@x", now); err != nil {
		t.Fatal(err)
	}

	if err := st.RemoveOrganizationMember(ctx, "org1", "owner@x"); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("remove owner with sole-owned project: want ErrLastOwner, got %v", err)
	}
	if role, ok, err := st.OrganizationMemberRole(ctx, "org1", "owner@x"); err != nil || !ok || role != OrgRoleOwner {
		t.Fatalf("organization owner should remain after failed removal: role=%q ok=%v err=%v", role, ok, err)
	}
	if role, ok, err := st.MemberRole(ctx, "p1", "owner@x"); err != nil || !ok || role != RoleOwner {
		t.Fatalf("project owner should remain after failed removal: role=%q ok=%v err=%v", role, ok, err)
	}

	if err := st.AddMember(ctx, "p1", "other@x", RoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := st.RemoveOrganizationMember(ctx, "org1", "owner@x"); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := st.OrganizationMemberRole(ctx, "org1", "owner@x"); err != nil || ok {
		t.Fatalf("organization membership still present: ok=%v err=%v", ok, err)
	}
	if _, ok, err := st.MemberRole(ctx, "p1", "owner@x"); err != nil || ok {
		t.Fatalf("project membership still present: ok=%v err=%v", ok, err)
	}
	p, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if p.OwnerIdentity != "other@x" {
		t.Fatalf("project owner_identity = %q, want other@x", p.OwnerIdentity)
	}
}
