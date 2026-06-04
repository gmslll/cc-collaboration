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
	if ok, _ := st.UserIsAdmin(ctx, "ghost"); ok {
		t.Error("missing user should not be admin")
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
