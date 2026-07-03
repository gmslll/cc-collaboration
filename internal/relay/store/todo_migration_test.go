package store

import (
	"context"
	"testing"
)

// TestMigrateStatusTaxonomyBackfill locks in the one-time data migration in
// sqlite.go's migrate(): legacy status spellings (pending/assigned/blocked/
// cancelled, from the pre-taxonomy-rework 6-value Status) get remapped onto
// the new 8-value taxonomy, and re-running migrate() — as happens on every
// relay boot, see the migrate() doc — is a harmless no-op rather than
// re-touching already-migrated rows.
func TestMigrateStatusTaxonomyBackfill(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	insert := func(id, status string) {
		t.Helper()
		// Bypass CreateTodo (which validates against the current, new-only
		// Status enum and would reject these) to simulate rows that were
		// written before this migration existed.
		if _, err := st.db.ExecContext(ctx,
			`INSERT INTO todos(id, owner_identity, title, status, priority, recurrence, created_at, updated_at)
			 VALUES(?, 'alice@x', 'x', ?, 'normal', '', 0, 0)`, id, status,
		); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}
	insert("legacy-pending", "pending")
	insert("legacy-assigned", "assigned")
	insert("legacy-blocked", "blocked")
	insert("legacy-cancelled", "cancelled")
	insert("already-new", "in_review") // must not be touched by any WHERE clause

	statusOf := func(id string) string {
		t.Helper()
		var s string
		if err := st.db.QueryRowContext(ctx, `SELECT status FROM todos WHERE id = ?`, id).Scan(&s); err != nil {
			t.Fatalf("read status of %s: %v", id, err)
		}
		return s
	}

	want := map[string]string{
		"legacy-pending":   "todo",
		"legacy-assigned":  "todo",
		"legacy-blocked":   "in_progress",
		"legacy-cancelled": "canceled",
		"already-new":      "in_review",
	}

	if err := st.migrate(); err != nil {
		t.Fatalf("first migrate: %v", err)
	}
	for id, w := range want {
		if got := statusOf(id); got != w {
			t.Errorf("%s status after migrate = %q, want %q", id, got, w)
		}
	}

	// Idempotent: migrate() runs on every boot with no schema_version gate
	// (see its doc comment) — a second run must leave already-migrated rows
	// exactly as they are.
	if err := st.migrate(); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	for id, w := range want {
		if got := statusOf(id); got != w {
			t.Errorf("%s status after second migrate = %q, want unchanged %q", id, got, w)
		}
	}
}
