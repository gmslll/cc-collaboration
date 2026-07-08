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
