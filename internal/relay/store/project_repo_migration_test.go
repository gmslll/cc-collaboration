package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

func TestProjectRepoCloneURLMigrationPreservesLegacyRows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  owner_identity TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE project_repos (
  repo_name TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE
);
INSERT INTO projects(id, name, owner_identity, created_at) VALUES('p1', 'Legacy', 'owner@x', 1);
INSERT INTO project_repos(repo_name, project_id) VALUES('legacy-repo', 'p1');
`); err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	for pass := 1; pass <= 2; pass++ {
		st, err := Open(path)
		if err != nil {
			t.Fatalf("Open pass %d: %v", pass, err)
		}
		bindings, err := st.ListProjectRepoBindings(context.Background(), "p1")
		if err != nil {
			st.Close()
			t.Fatalf("bindings pass %d: %v", pass, err)
		}
		if len(bindings) != 1 || bindings[0].RepoName != "legacy-repo" || bindings[0].CloneURL != "" {
			st.Close()
			t.Fatalf("bindings pass %d = %+v", pass, bindings)
		}
		if err := st.Close(); err != nil {
			t.Fatal(err)
		}
	}
}
