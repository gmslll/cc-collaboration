package store

import (
	"context"
	"testing"
)

func TestUserSettings(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	// Missing key returns ("", false, nil) — a client-side default, not an error.
	if v, found, err := st.GetSetting(ctx, "a@x", "todo.view"); err != nil || found || v != "" {
		t.Fatalf("missing setting: got (%q, %v, %v), want (\"\", false, nil)", v, found, err)
	}

	// Insert, then read back verbatim.
	if err := st.SetSetting(ctx, "a@x", "todo.view", `{"scope":"team"}`); err != nil {
		t.Fatal(err)
	}
	v, found, err := st.GetSetting(ctx, "a@x", "todo.view")
	if err != nil || !found || v != `{"scope":"team"}` {
		t.Fatalf("after set: got (%q, %v, %v)", v, found, err)
	}

	// Upsert overwrites the same (identity, key) rather than erroring.
	if err := st.SetSetting(ctx, "a@x", "todo.view", `{"scope":"all"}`); err != nil {
		t.Fatal(err)
	}
	if v, _, _ := st.GetSetting(ctx, "a@x", "todo.view"); v != `{"scope":"all"}` {
		t.Fatalf("after upsert: got %q", v)
	}

	// Per-identity isolation: another user never sees a@x's value.
	if _, found, _ := st.GetSetting(ctx, "b@x", "todo.view"); found {
		t.Fatal("setting leaked across identities")
	}
}
