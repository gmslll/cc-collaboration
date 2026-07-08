package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestUsersCRUD(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateUser(ctx, User{Identity: "a@x", PasswordHash: "h", IsAdmin: true}, now); err != nil {
		t.Fatal(err)
	}
	u, err := st.GetUser(ctx, "a@x")
	if err != nil {
		t.Fatal(err)
	}
	if u.PasswordHash != "h" || !u.IsAdmin || u.Disabled {
		t.Fatalf("got %+v", u)
	}
	if _, err := st.GetUser(ctx, "nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing user: want ErrNotFound, got %v", err)
	}

	if err := st.SetPasswordHash(ctx, "a@x", "h2"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetAdmin(ctx, "a@x", false); err != nil {
		t.Fatal(err)
	}
	if err := st.SetDisabled(ctx, "a@x", true); err != nil {
		t.Fatal(err)
	}
	u, _ = st.GetUser(ctx, "a@x")
	if u.PasswordHash != "h2" || u.IsAdmin || !u.Disabled {
		t.Fatalf("updates not applied: %+v", u)
	}
	if err := st.SetAdmin(ctx, "ghost", true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("updating missing user: want ErrNotFound, got %v", err)
	}

	if ok, _ := st.UserIsAdmin(ctx, "a@x"); ok {
		t.Error("expected not admin after SetAdmin(false)")
	}
	if err := st.CreateUser(ctx, User{Identity: "disabled-admin@x", IsAdmin: true, Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	if ok, _ := st.UserIsAdmin(ctx, "disabled-admin@x"); ok {
		t.Error("disabled user should not be an effective admin")
	}
	if ok, _ := st.UserIsAdmin(ctx, "ghost"); ok {
		t.Error("missing user should not be admin")
	}
}

func TestSetDisabledProtectsOwnerInvariants(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateUser(ctx, User{Identity: "owner@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "other@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org1", "other@x", OrgRoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "p1", "org1", "App", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateSession(ctx, "session-owner", "owner@x", now, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateMachineToken(ctx, "machine-owner", "owner@x", "laptop", now); err != nil {
		t.Fatal(err)
	}

	if err := st.SetDisabled(ctx, "owner@x", true); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("disable project last owner: want ErrLastOwner, got %v", err)
	}
	if active, err := st.UserActive(ctx, "owner@x"); err != nil || !active {
		t.Fatalf("failed disable should keep owner active: active=%v err=%v", active, err)
	}
	if _, ok, err := st.SessionIdentity(ctx, "session-owner", now); err != nil || !ok {
		t.Fatalf("failed disable should keep session: ok=%v err=%v", ok, err)
	}
	if _, ok, err := st.MachineTokenIdentity(ctx, "machine-owner"); err != nil || !ok {
		t.Fatalf("failed disable should keep machine token: ok=%v err=%v", ok, err)
	}

	if err := st.AddMember(ctx, "p1", "other@x", RoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := st.SetDisabled(ctx, "owner@x", true); err != nil {
		t.Fatal(err)
	}
	if active, err := st.UserActive(ctx, "owner@x"); err != nil || active {
		t.Fatalf("disable should mark owner inactive: active=%v err=%v", active, err)
	}
	org, err := st.GetOrganization(ctx, "org1")
	if err != nil {
		t.Fatal(err)
	}
	if org.OwnerIdentity != "other@x" {
		t.Fatalf("organization owner_identity = %q, want other@x", org.OwnerIdentity)
	}
	p, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if p.OwnerIdentity != "other@x" {
		t.Fatalf("project owner_identity = %q, want other@x", p.OwnerIdentity)
	}
	if _, ok, err := st.SessionIdentity(ctx, "session-owner", now); err != nil || ok {
		t.Fatalf("disabled owner session should be removed: ok=%v err=%v", ok, err)
	}
	if _, ok, err := st.MachineTokenIdentity(ctx, "machine-owner"); err != nil || ok {
		t.Fatalf("disabled owner machine token should be removed: ok=%v err=%v", ok, err)
	}
}

func TestSessions(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateSession(ctx, "h1", "a@x", now, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	id, ok, err := st.SessionIdentity(ctx, "h1", now)
	if err != nil || !ok || id != "a@x" {
		t.Fatalf("got id=%q ok=%v err=%v", id, ok, err)
	}
	if _, ok, _ := st.SessionIdentity(ctx, "h1", now.Add(2*time.Hour)); ok {
		t.Error("expired session resolved")
	}
	if err := st.DeleteSession(ctx, "h1"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := st.SessionIdentity(ctx, "h1", now); ok {
		t.Error("deleted session resolved")
	}
}

func TestMachineTokens(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateMachineToken(ctx, "th1", "a@x", "laptop", now); err != nil {
		t.Fatal(err)
	}
	id, ok, err := st.MachineTokenIdentity(ctx, "th1")
	if err != nil || !ok || id != "a@x" {
		t.Fatalf("got id=%q ok=%v err=%v", id, ok, err)
	}

	// Seed is idempotent: a duplicate doesn't error.
	if err := st.SeedMachineToken(ctx, "th2", "b@y", now); err != nil {
		t.Fatal(err)
	}
	if err := st.SeedMachineToken(ctx, "th2", "b@y", now); err != nil {
		t.Fatalf("duplicate seed errored: %v", err)
	}

	toks, _ := st.ListMachineTokens(ctx, "a@x")
	if len(toks) != 1 || toks[0].Hash != "th1" || toks[0].Label != "laptop" {
		t.Fatalf("got %+v", toks)
	}

	// Revoke is scoped to the owner.
	if err := st.DeleteMachineToken(ctx, "other@z", "th1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("wrong owner revoke: want ErrNotFound, got %v", err)
	}
	if err := st.DeleteMachineToken(ctx, "a@x", "th1"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := st.MachineTokenIdentity(ctx, "th1"); ok {
		t.Error("revoked token still resolves")
	}
}
