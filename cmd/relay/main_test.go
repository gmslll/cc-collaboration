package main

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/cc-collaboration/internal/relay/store"
)

func TestRunUserAddNormalizesIdentity(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")

	if err := runUserAdd([]string{
		"-db", dbPath,
		"-identity", " user@x ",
		"-password", "secret pass",
		"-display", " User ",
	}); err != nil {
		t.Fatal(err)
	}
	if err := runUserAdd([]string{
		"-db", dbPath,
		"-identity", " user@x ",
		"-password", "secret pass 2",
	}); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	users, err := st.ListUsers(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(users) != 1 {
		t.Fatalf("users = %+v, want one normalized account", users)
	}
	if users[0].Identity != "user@x" || users[0].DisplayName != "User" {
		t.Fatalf("useradd account not normalized: %+v", users[0])
	}
}
