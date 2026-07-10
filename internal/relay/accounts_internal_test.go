package relay

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay/store"
)

func TestHasOtherAvailableAdminProtectsLastAdmin(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateUser(ctx, store.User{Identity: "only@x", IsAdmin: true}, now); err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: st}
	if other, err := s.hasOtherAvailableAdmin(ctx, "only@x"); err != nil || other {
		t.Fatalf("only admin: other=%v err=%v", other, err)
	}
	if err := st.CreateUser(ctx, store.User{Identity: "other@x", IsAdmin: true}, now); err != nil {
		t.Fatal(err)
	}
	if other, err := s.hasOtherAvailableAdmin(ctx, "only@x"); err != nil || !other {
		t.Fatalf("active second admin: other=%v err=%v", other, err)
	}
	if err := st.SetDisabled(ctx, "other@x", true); err != nil {
		t.Fatal(err)
	}
	if other, err := s.hasOtherAvailableAdmin(ctx, "only@x"); err != nil || other {
		t.Fatalf("disabled second admin: other=%v err=%v", other, err)
	}

	// Operator-seeded admins are part of the effective admin set even without
	// a users row, matching Server.isAdmin's lockout-prevention semantics.
	s.SeedAdmins = []string{"seed@ops"}
	if other, err := s.hasOtherAvailableAdmin(ctx, "only@x"); err != nil || !other {
		t.Fatalf("seed admin: other=%v err=%v", other, err)
	}
}
