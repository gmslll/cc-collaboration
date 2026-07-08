package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/cc-collaboration/pkg/handoffschema"
)

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(on)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	if err := db.PingContext(context.Background()); err != nil {
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	if _, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS handoffs (
  id          TEXT PRIMARY KEY,
  sender      TEXT NOT NULL,
  recipient   TEXT NOT NULL,
  urgency     TEXT NOT NULL,
  state       TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  picked_at   INTEGER,
  repo_name   TEXT NOT NULL DEFAULT '',
  branch      TEXT NOT NULL DEFAULT '',
  headline    TEXT NOT NULL DEFAULT '',
  kind        TEXT NOT NULL DEFAULT '',
  payload     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_handoffs_recipient_state_created
  ON handoffs(recipient, state, created_at);

CREATE TABLE IF NOT EXISTS comments (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  handoff_id  TEXT NOT NULL REFERENCES handoffs(id) ON DELETE CASCADE,
  sender      TEXT NOT NULL,
  body        TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_comments_handoff_created
  ON comments(handoff_id, created_at);

CREATE TABLE IF NOT EXISTS attachments (
  handoff_id  TEXT NOT NULL REFERENCES handoffs(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  sha256      TEXT NOT NULL,
  size        INTEGER NOT NULL,
  content     BLOB NOT NULL,
  PRIMARY KEY (handoff_id, name)
);

CREATE TABLE IF NOT EXISTS handoff_recipients (
  handoff_id  TEXT NOT NULL REFERENCES handoffs(id) ON DELETE CASCADE,
  recipient   TEXT NOT NULL,
  state       TEXT NOT NULL DEFAULT 'pending',
  picked_at   INTEGER,
  PRIMARY KEY (handoff_id, recipient)
);
CREATE INDEX IF NOT EXISTS idx_handoff_recipients_recipient_state
  ON handoff_recipients(recipient, state);

CREATE TABLE IF NOT EXISTS users (
  identity      TEXT PRIMARY KEY,
  password_hash TEXT NOT NULL DEFAULT '',
  display_name  TEXT NOT NULL DEFAULT '',
  is_admin      INTEGER NOT NULL DEFAULT 0,
  disabled      INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash  TEXT PRIMARY KEY,
  identity    TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_identity ON sessions(identity);

CREATE TABLE IF NOT EXISTS machine_tokens (
  token_hash  TEXT PRIMARY KEY,
  identity    TEXT NOT NULL,
  label       TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_machine_tokens_identity ON machine_tokens(identity);

CREATE TABLE IF NOT EXISTS organizations (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  owner_identity TEXT NOT NULL,
  created_at     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS organization_members (
  org_id    TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  identity  TEXT NOT NULL,
  role      TEXT NOT NULL,
  PRIMARY KEY (org_id, identity)
);
CREATE INDEX IF NOT EXISTS idx_organization_members_identity ON organization_members(identity);

CREATE TABLE IF NOT EXISTS projects (
  id             TEXT PRIMARY KEY,
  org_id         TEXT NOT NULL DEFAULT '',
  name           TEXT NOT NULL,
  owner_identity TEXT NOT NULL,
  created_at     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS project_repos (
  repo_name   TEXT PRIMARY KEY,
  project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_project_repos_project ON project_repos(project_id);

CREATE TABLE IF NOT EXISTS project_members (
  project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  identity    TEXT NOT NULL,
  role        TEXT NOT NULL,
  PRIMARY KEY (project_id, identity)
);
CREATE INDEX IF NOT EXISTS idx_project_members_identity ON project_members(identity);
`); err != nil {
		return err
	}
	// Idempotent column additions for installs that predate the column.
	// SQLite returns "duplicate column name" when it already exists; treat
	// that as success.
	for _, ddl := range []struct{ what, sql string }{
		{"kind", `ALTER TABLE handoffs ADD COLUMN kind TEXT NOT NULL DEFAULT ''`},
		{"recipients", `ALTER TABLE handoffs ADD COLUMN recipients TEXT NOT NULL DEFAULT ''`},
		{"bug_group_id", `ALTER TABLE handoffs ADD COLUMN bug_group_id TEXT NOT NULL DEFAULT ''`},
		{"project_org_id", `ALTER TABLE projects ADD COLUMN org_id TEXT NOT NULL DEFAULT ''`},
	} {
		if _, err := s.db.Exec(ddl.sql); err != nil {
			if !strings.Contains(err.Error(), "duplicate column name") {
				return fmt.Errorf("add %s column: %w", ddl.what, err)
			}
		}
	}
	if _, err := s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_handoffs_bug_group ON handoffs(bug_group_id)`); err != nil {
		return fmt.Errorf("create bug_group index: %w", err)
	}
	if err := s.backfillOrganizations(); err != nil {
		return err
	}
	// One-time backfill: for every legacy handoff with no handoff_recipients
	// row, insert one mirroring its scalar (recipient, state, picked_at) so
	// the JOIN-based ListPending / Ack paths see old data uniformly.
	// Gate on a cheap COUNT first — the LEFT JOIN scan isn't free and we
	// shouldn't pay it on every boot once backfill is done. Steady state:
	// 0 orphan rows ⇒ index hit, no INSERT.
	var orphans int
	if err := s.db.QueryRow(`
SELECT COUNT(*) FROM handoffs h
  LEFT JOIN handoff_recipients r ON r.handoff_id = h.id AND r.recipient = h.recipient
 WHERE h.recipient != '' AND r.handoff_id IS NULL`).Scan(&orphans); err != nil {
		return fmt.Errorf("check backfill needed: %w", err)
	}
	if orphans > 0 {
		if _, err := s.db.Exec(`
INSERT INTO handoff_recipients (handoff_id, recipient, state, picked_at)
SELECT h.id, h.recipient, h.state, h.picked_at
  FROM handoffs h
  LEFT JOIN handoff_recipients r ON r.handoff_id = h.id AND r.recipient = h.recipient
 WHERE h.recipient != '' AND r.handoff_id IS NULL`); err != nil {
			return fmt.Errorf("backfill handoff_recipients: %w", err)
		}
	}

	// Todo feature tables (new sibling entity, kept in its own Exec block so
	// it never touches the handoffs migration above). project_id is a
	// nullable FK (NULL = personal todo) rather than NOT NULL DEFAULT '' —
	// unlike project_repos, a todo can legitimately have no project, and a
	// real (non-null) FK gets us "deleting a project cascades its team
	// todos" for free via the store's foreign_keys=on pragma, without
	// touching personal todos (their project_id is NULL, never matched by
	// the cascade).
	if _, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS todos (
  id                     TEXT PRIMARY KEY,
  project_id             TEXT REFERENCES projects(id) ON DELETE CASCADE,
  owner_identity         TEXT NOT NULL,
  title                  TEXT NOT NULL,
  body_md                TEXT NOT NULL DEFAULT '',
  status                 TEXT NOT NULL DEFAULT 'pending',
  priority               TEXT NOT NULL DEFAULT 'normal',
  assignee_identity      TEXT NOT NULL DEFAULT '',
  assignee_session_id    TEXT NOT NULL DEFAULT '',
  assignee_session_label TEXT NOT NULL DEFAULT '',
  recurrence             TEXT NOT NULL DEFAULT '',
  due_at                 INTEGER,
  next_occurrence_at     INTEGER,
  created_at             INTEGER NOT NULL,
  updated_at             INTEGER NOT NULL,
  completed_at           INTEGER
);
CREATE INDEX IF NOT EXISTS idx_todos_owner ON todos(owner_identity);
CREATE INDEX IF NOT EXISTS idx_todos_project ON todos(project_id);
CREATE INDEX IF NOT EXISTS idx_todos_assignee ON todos(assignee_identity);
CREATE INDEX IF NOT EXISTS idx_todos_status_next ON todos(status, next_occurrence_at);

CREATE TABLE IF NOT EXISTS todo_comments (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  todo_id         TEXT NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
  author_identity TEXT NOT NULL,
  body            TEXT NOT NULL,
  created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_todo_comments_todo_created ON todo_comments(todo_id, created_at);

CREATE TABLE IF NOT EXISTS todo_attachments (
  todo_id     TEXT NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  sha256      TEXT NOT NULL,
  size        INTEGER NOT NULL,
  content     BLOB NOT NULL,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (todo_id, name)
);
`); err != nil {
		return fmt.Errorf("create todo tables: %w", err)
	}
	// Todo feature, Phase 0: Linear-import + session-resume columns, added
	// together in one pass (see pkg/todoschema/todo.go for field docs) so
	// Track A (Linear import) and Track B (session resume) share a single
	// migration instead of each racing to append their own.
	for _, ddl := range []struct{ what, sql string }{
		{"source_ref", `ALTER TABLE todos ADD COLUMN source_ref TEXT NOT NULL DEFAULT ''`},
		{"source_url", `ALTER TABLE todos ADD COLUMN source_url TEXT NOT NULL DEFAULT ''`},
		{"source_provider", `ALTER TABLE todos ADD COLUMN source_provider TEXT NOT NULL DEFAULT ''`},
		{"source_team_key", `ALTER TABLE todos ADD COLUMN source_team_key TEXT NOT NULL DEFAULT ''`},
		{"source_project_id", `ALTER TABLE todos ADD COLUMN source_project_id TEXT NOT NULL DEFAULT ''`},
		{"assignee_agent_session_id", `ALTER TABLE todos ADD COLUMN assignee_agent_session_id TEXT NOT NULL DEFAULT ''`},
		{"assignee_workdir", `ALTER TABLE todos ADD COLUMN assignee_workdir TEXT NOT NULL DEFAULT ''`},
		{"assignee_agent_kind", `ALTER TABLE todos ADD COLUMN assignee_agent_kind TEXT NOT NULL DEFAULT ''`},
		// workspace_name/repo_name: optional workspace/repo binding (see
		// pkg/todoschema.Todo field docs). Added in its own pass since it
		// postdates the Phase 0 five-column migration above.
		{"workspace_name", `ALTER TABLE todos ADD COLUMN workspace_name TEXT NOT NULL DEFAULT ''`},
		{"repo_name", `ALTER TABLE todos ADD COLUMN repo_name TEXT NOT NULL DEFAULT ''`},
		// group_name: free-form, user-defined bucket (see pkg/todoschema.Todo
		// field docs) — plain string, no separate table, same pattern as
		// workspace_name/repo_name above.
		{"group_name", `ALTER TABLE todos ADD COLUMN group_name TEXT NOT NULL DEFAULT ''`},
		// Linear incremental import + external-assignee display (see
		// pkg/todoschema.Todo field docs): source_updated_at is the idempotency
		// watermark that lets re-import skip unchanged issues; the two assignee
		// columns hold the external assignee's name/avatar for the card.
		{"source_updated_at", `ALTER TABLE todos ADD COLUMN source_updated_at TEXT NOT NULL DEFAULT ''`},
		{"source_assignee_name", `ALTER TABLE todos ADD COLUMN source_assignee_name TEXT NOT NULL DEFAULT ''`},
		{"source_assignee_avatar_url", `ALTER TABLE todos ADD COLUMN source_assignee_avatar_url TEXT NOT NULL DEFAULT ''`},
	} {
		if _, err := s.db.Exec(ddl.sql); err != nil {
			if !strings.Contains(err.Error(), "duplicate column name") {
				return fmt.Errorf("add %s column: %w", ddl.what, err)
			}
		}
	}
	if _, err := s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_todos_source_ref ON todos(source_ref) WHERE source_ref != ''`); err != nil {
		return fmt.Errorf("create source_ref index: %w", err)
	}
	if _, err := s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_todos_source_scope ON todos(source_provider, source_team_key, source_project_id) WHERE source_provider != ''`); err != nil {
		return fmt.Errorf("create source scope index: %w", err)
	}
	if _, err := s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_todos_group ON todos(group_name) WHERE group_name != ''`); err != nil {
		return fmt.Errorf("create group_name index: %w", err)
	}

	// Status taxonomy migration: 6 values -> 8 (see pkg/todoschema/todo.go's
	// Status doc). Unlike every other block in this function, this rewrites
	// existing DATA, not schema — each WHERE targets only the old spelling,
	// so re-running on an already-migrated (or brand-new, empty) database is
	// a harmless no-op, matching migrate()'s no-schema_version-table,
	// run-every-boot, idempotence-by-construction style.
	//   pending, assigned -> todo (assigned duplicated AssigneeIdentity, no
	//     longer a distinct status)
	//   blocked -> in_progress (not part of the new taxonomy)
	//   cancelled -> canceled (single-L spelling)
	for _, stmt := range []string{
		`UPDATE todos SET status = 'todo' WHERE status = 'pending'`,
		`UPDATE todos SET status = 'todo' WHERE status = 'assigned'`,
		`UPDATE todos SET status = 'in_progress' WHERE status = 'blocked'`,
		`UPDATE todos SET status = 'canceled' WHERE status = 'cancelled'`,
	} {
		if _, err := s.db.Exec(stmt); err != nil {
			return fmt.Errorf("migrate status taxonomy: %w", err)
		}
	}

	// Per-identity UI settings (key -> opaque JSON value), synced across a
	// user's own devices so e.g. the Todo board's view config (scope / team
	// source / Linear team key) renders identically on desktop and phone. Small
	// KV; the value is a blob the client owns and the relay never interprets.
	// See internal/relay/store/settings.go and internal/relay/settings.go.
	if _, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS user_settings (
  identity   TEXT NOT NULL,
  key        TEXT NOT NULL,
  value      TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (identity, key)
);`); err != nil {
		return fmt.Errorf("create user_settings table: %w", err)
	}
	return nil
}

func defaultOrganizationID(identity string) string {
	sum := sha256.Sum256([]byte(identity))
	return "org_" + hex.EncodeToString(sum[:])[:12]
}

func (s *Store) backfillOrganizations() error {
	ctx := context.Background()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := time.Now().UTC().UnixMilli()
	rows, err := tx.QueryContext(ctx, `
SELECT identity FROM users
UNION
SELECT owner_identity FROM projects WHERE owner_identity != ''
UNION
SELECT identity FROM project_members WHERE identity != ''`)
	if err != nil {
		return fmt.Errorf("scan organization owners: %w", err)
	}
	var identities []string
	for rows.Next() {
		var identity string
		if err := rows.Scan(&identity); err != nil {
			rows.Close()
			return err
		}
		if strings.TrimSpace(identity) != "" {
			identities = append(identities, identity)
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	for _, identity := range identities {
		orgID := defaultOrganizationID(identity)
		name := identity + "'s team"
		if _, err := tx.ExecContext(ctx,
			`INSERT OR IGNORE INTO organizations(id, name, owner_identity, created_at) VALUES(?, ?, ?, ?)`,
			orgID, name, identity, now); err != nil {
			return fmt.Errorf("backfill organization %s: %w", identity, err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT OR IGNORE INTO organization_members(org_id, identity, role) VALUES(?, ?, ?)`,
			orgID, identity, OrgRoleOwner); err != nil {
			return fmt.Errorf("backfill organization owner %s: %w", identity, err)
		}
	}
	rows, err = tx.QueryContext(ctx, `SELECT id, owner_identity FROM projects WHERE owner_identity != ''`)
	if err != nil {
		return err
	}
	type projectOwner struct {
		projectID string
		owner     string
	}
	var projects []projectOwner
	for rows.Next() {
		var po projectOwner
		if err := rows.Scan(&po.projectID, &po.owner); err != nil {
			rows.Close()
			return err
		}
		projects = append(projects, po)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	for _, po := range projects {
		if _, err := tx.ExecContext(ctx,
			`UPDATE projects SET org_id = ? WHERE id = ? AND org_id = ''`,
			defaultOrganizationID(po.owner), po.projectID); err != nil {
			return err
		}
	}
	rows, err = tx.QueryContext(ctx, `
SELECT DISTINCT p.org_id, pm.identity, pm.role
  FROM projects p
  JOIN project_members pm ON pm.project_id = p.id
 WHERE p.org_id != '' AND pm.identity != ''`)
	if err != nil {
		return err
	}
	type member struct {
		orgID, identity, role string
	}
	var members []member
	for rows.Next() {
		var m member
		if err := rows.Scan(&m.orgID, &m.identity, &m.role); err != nil {
			rows.Close()
			return err
		}
		members = append(members, m)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	for _, m := range members {
		role := OrgRoleMember
		if m.role == RoleOwner {
			role = OrgRoleOwner
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO organization_members(org_id, identity, role) VALUES(?, ?, ?)
			 ON CONFLICT(org_id, identity) DO UPDATE SET role =
			   CASE WHEN organization_members.role = ? THEN organization_members.role ELSE excluded.role END`,
			m.orgID, m.identity, role, OrgRoleOwner); err != nil {
			return err
		}
	}
	return tx.Commit()
}

var ErrNotFound = errors.New("handoff not found")
var ErrLastOwner = errors.New("last owner cannot be removed")

func (s *Store) Insert(ctx context.Context, p *handoffschema.Package) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()
	if err := insertHandoffInTx(ctx, tx, p); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit insert: %w", err)
	}
	return nil
}

// insertHandoffInTx writes the package to `handoffs` and fans one row per
// recipient into `handoff_recipients`, all inside the caller's transaction.
// Shared between Insert (own tx) and Reassign (which already owns a tx that
// also flips the previous recipient's slot atomically with the new handoff).
func insertHandoffInTx(ctx context.Context, tx *sql.Tx, p *handoffschema.Package) error {
	payload, err := json.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}
	recipients := p.EffectiveRecipients()
	// Capsules aren't delivered to anyone — they live in the plaza, keyed by
	// visibility — so they legitimately have no recipient. Every other kind must.
	if len(recipients) == 0 && p.RequiresRecipient() {
		return fmt.Errorf("insert handoff: no recipients")
	}
	firstRecipient := ""
	if len(recipients) > 0 {
		firstRecipient = recipients[0]
	}
	recipientsJSON := ""
	if len(p.Recipients) > 0 {
		buf, err := json.Marshal(p.Recipients)
		if err != nil {
			return fmt.Errorf("marshal recipients: %w", err)
		}
		recipientsJSON = string(buf)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO handoffs(id, sender, recipient, recipients, urgency, state, created_at, repo_name, branch, headline, kind, bug_group_id, payload)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		p.ID, p.Sender, firstRecipient, recipientsJSON, string(p.Urgency),
		string(handoffschema.StatePending), p.CreatedAt.UnixMilli(),
		p.Repo.Name, p.Repo.Branch, p.Headline(), string(p.Kind), p.BugGroupID, string(payload),
	); err != nil {
		return fmt.Errorf("insert handoff: %w", err)
	}
	for _, r := range recipients {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO handoff_recipients(handoff_id, recipient, state) VALUES(?, ?, ?)`,
			p.ID, r, string(handoffschema.StatePending),
		); err != nil {
			return fmt.Errorf("insert handoff_recipient %s: %w", r, err)
		}
	}
	return nil
}

func (s *Store) Get(ctx context.Context, id string) (*handoffschema.Package, handoffschema.State, error) {
	var payload string
	var state string
	err := s.db.QueryRowContext(ctx,
		`SELECT payload, state FROM handoffs WHERE id = ?`, id,
	).Scan(&payload, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", ErrNotFound
	}
	if err != nil {
		return nil, "", err
	}
	var p handoffschema.Package
	if err := json.Unmarshal([]byte(payload), &p); err != nil {
		return nil, "", fmt.Errorf("unmarshal payload: %w", err)
	}
	return &p, handoffschema.State(state), nil
}

// ListPending returns compact list items addressed to recipient in pending state, oldest-first.
// Reads only denormalized columns; never decodes the full payload BLOB. Joins
// handoff_recipients so multi-recipient bug handoffs show up for every
// recipient until each individual slot is acked or reassigned.
func (s *Store) ListPending(ctx context.Context, recipient string, limit int) ([]handoffschema.ListItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT h.id, h.sender, h.recipients, h.urgency, h.state, h.created_at,
		        h.repo_name, h.branch, h.headline, h.kind, h.bug_group_id
		   FROM handoffs h
		   JOIN handoff_recipients r ON r.handoff_id = h.id
		  WHERE r.recipient = ? AND r.state = ? AND h.state = ?
		  ORDER BY h.created_at ASC LIMIT ?`,
		recipient, string(handoffschema.StatePending), string(handoffschema.StatePending), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []handoffschema.ListItem
	for rows.Next() {
		item, err := scanListItem(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

// ListHistory returns compact list items addressed to recipient where the
// per-recipient slot has been picked up or reassigned away, newest-first.
// "Picked" surfaces normal closure; "reassigned" surfaces bugs the caller
// kicked over to the other side (still useful to look back at).
func (s *Store) ListHistory(ctx context.Context, recipient string, limit int) ([]handoffschema.ListItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT h.id, h.sender, h.recipients, h.urgency, h.state, h.created_at,
		        h.repo_name, h.branch, h.headline, h.kind, h.bug_group_id
		   FROM handoffs h
		   JOIN handoff_recipients r ON r.handoff_id = h.id
		  WHERE r.recipient = ? AND r.state IN (?, ?)
		  ORDER BY h.created_at DESC LIMIT ?`,
		recipient, string(handoffschema.StatePicked), string(handoffschema.StateReassigned), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []handoffschema.ListItem
	for rows.Next() {
		item, err := scanListItem(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

// ListCapsules returns the plaza rows visible to [identity]: every public
// capsule plus the caller's own (any visibility), newest first. Visibility
// lives in the JSON payload, so this loads capsule rows and filters in Go —
// fine for the plaza's modest scale; [limit] bounds the scan.
func (s *Store) ListCapsules(ctx context.Context, identity string, limit int) ([]handoffschema.CapsuleListItem, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT payload FROM handoffs WHERE kind = ? ORDER BY created_at DESC LIMIT ?`,
		string(handoffschema.KindCapsule), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []handoffschema.CapsuleListItem
	for rows.Next() {
		var payload string
		if err := rows.Scan(&payload); err != nil {
			return nil, err
		}
		var p handoffschema.Package
		if err := json.Unmarshal([]byte(payload), &p); err != nil {
			continue // skip a corrupt row rather than fail the whole plaza
		}
		// Public capsules to anyone, private ones only to their owner.
		if !p.CapsuleVisibleTo(identity) {
			continue
		}
		out = append(out, handoffschema.NewCapsuleListItem(&p))
	}
	return out, rows.Err()
}

// capsuleOwnerRow fetches (sender, kind) for id, enforcing "exists + is a
// capsule + owned by owner" — the shared guard for owner-only capsule edits.
func capsuleOwnerRow(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, id, owner string) error {
	var sender, kind string
	err := q.QueryRowContext(ctx, `SELECT sender, kind FROM handoffs WHERE id = ?`, id).Scan(&sender, &kind)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if kind != string(handoffschema.KindCapsule) {
		return ErrNotFound // not a capsule — don't leak other handoffs here
	}
	if sender != owner {
		return fmt.Errorf("%w: capsule is owned by %s", ErrForbidden, sender)
	}
	return nil
}

// DeleteCapsule removes an owner's capsule (and, via FK cascade, its
// attachments) from the plaza. Only capsules, only the owner.
func (s *Store) DeleteCapsule(ctx context.Context, id, owner string) error {
	if err := capsuleOwnerRow(ctx, s.db, id, owner); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM handoffs WHERE id = ?`, id)
	return err
}

// UpdateCapsuleMeta edits an owner's capsule metadata in place — visibility
// and/or summary (nil = unchanged). Only capsules, only the owner; attachment
// bodies (persona/seed) are not touched here.
func (s *Store) UpdateCapsuleMeta(ctx context.Context, id, owner string, visibility, summary *string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := capsuleOwnerRow(ctx, tx, id, owner); err != nil {
		return err
	}
	var payload string
	if err := tx.QueryRowContext(ctx, `SELECT payload FROM handoffs WHERE id = ?`, id).Scan(&payload); err != nil {
		return err
	}
	var p handoffschema.Package
	if err := json.Unmarshal([]byte(payload), &p); err != nil {
		return fmt.Errorf("decode capsule payload: %w", err)
	}
	p.ApplyCapsuleEdit(visibility, summary)
	updated, err := json.Marshal(&p)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE handoffs SET payload = ?, headline = ? WHERE id = ?`,
		string(updated), p.Headline(), id,
	); err != nil {
		return err
	}
	return tx.Commit()
}

// scanListItem reads one row produced by the standard ListItem column set
// (h.id, h.sender, h.recipients, h.urgency, h.state, h.created_at,
// h.repo_name, h.branch, h.headline, h.kind, h.bug_group_id) — recipients
// optionally includes h.recipient as a scalar (ListSent uses that variant).
func scanListItem(rows *sql.Rows) (handoffschema.ListItem, error) {
	var (
		id, sender, recipientsJSON, urgency, state string
		repoName, branch, headline, kind           string
		bugGroupID                                 string
		createdMS                                  int64
	)
	if err := rows.Scan(&id, &sender, &recipientsJSON, &urgency, &state, &createdMS,
		&repoName, &branch, &headline, &kind, &bugGroupID); err != nil {
		return handoffschema.ListItem{}, err
	}
	item := handoffschema.ListItem{
		ID:         id,
		Kind:       handoffschema.Kind(kind),
		Sender:     sender,
		Urgency:    handoffschema.Urgency(urgency),
		State:      handoffschema.State(state),
		CreatedAt:  time.UnixMilli(createdMS).UTC(),
		RepoName:   repoName,
		Branch:     branch,
		Headline:   headline,
		BugGroupID: bugGroupID,
	}
	if recipientsJSON != "" {
		var rs []string
		if err := json.Unmarshal([]byte(recipientsJSON), &rs); err == nil {
			item.Recipients = rs
		}
	}
	return item, nil
}

func (s *Store) InsertComment(ctx context.Context, handoffID, sender, body string) (handoffschema.Comment, error) {
	now := time.Now().UTC()
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO comments(handoff_id, sender, body, created_at) VALUES(?, ?, ?, ?)`,
		handoffID, sender, body, now.UnixMilli(),
	)
	if err != nil {
		return handoffschema.Comment{}, err
	}
	id, _ := res.LastInsertId()
	return handoffschema.Comment{
		ID:        id,
		HandoffID: handoffID,
		Sender:    sender,
		Body:      body,
		CreatedAt: now,
	}, nil
}

// ListCommentsSince returns comments visible to identity (caller is sender,
// per-recipient slot owner, or any participant in the same bug_group_id) with
// id > since, excluding comments the caller posted themselves. Also returns
// the global max comment id for cursor bootstrap. limit <= 0 means "max_id
// only, no rows"; limit is capped at 500.
//
// Bug-group broadcast: the CTE `my_groups` collects every bug_group_id the
// caller participates in (as sender or current/historical recipient). For
// classic 2-party handoffs that have empty bug_group_id, the CTE contributes
// no rows and the extra clause is a no-op — semantics match the legacy
// (h.sender = ? OR h.recipient = ?) query.
func (s *Store) ListCommentsSince(ctx context.Context, identity string, since int64, limit int) ([]handoffschema.Comment, int64, error) {
	var maxID int64
	if err := s.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM comments`).Scan(&maxID); err != nil {
		return nil, 0, err
	}
	if limit <= 0 {
		return nil, maxID, nil
	}
	if limit > 500 {
		limit = 500
	}
	rows, err := s.db.QueryContext(ctx,
		`WITH my_groups AS (
		   SELECT DISTINCT h.bug_group_id FROM handoffs h
		     LEFT JOIN handoff_recipients r ON r.handoff_id = h.id
		    WHERE h.bug_group_id != '' AND (h.sender = ?1 OR r.recipient = ?1)
		 )
		 SELECT c.id, c.handoff_id, c.sender, c.body, c.created_at
		   FROM comments c
		   JOIN handoffs h ON c.handoff_id = h.id
		   LEFT JOIN handoff_recipients r ON r.handoff_id = h.id AND r.recipient = ?1
		  WHERE c.id > ?2 AND c.sender != ?1
		    AND (h.sender = ?1
		         OR r.recipient = ?1
		         OR (h.bug_group_id != '' AND h.bug_group_id IN (SELECT bug_group_id FROM my_groups)))
		  GROUP BY c.id
		  ORDER BY c.id ASC LIMIT ?3`,
		identity, since, limit,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []handoffschema.Comment
	for rows.Next() {
		var c handoffschema.Comment
		var createdMS int64
		if err := rows.Scan(&c.ID, &c.HandoffID, &c.Sender, &c.Body, &createdMS); err != nil {
			return nil, 0, err
		}
		c.CreatedAt = time.UnixMilli(createdMS).UTC()
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	return out, maxID, nil
}

// BugGroupParticipants returns the union of sender + handoff_recipients.recipient
// across every handoff with the given bug_group_id. Used by the server to fan
// out comment SSE events to everyone who has ever touched the bug chain, so
// tester + original-side + reassigned-side all stay in sync.
func (s *Store) BugGroupParticipants(ctx context.Context, bugGroupID string) ([]string, error) {
	if bugGroupID == "" {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT DISTINCT identity FROM (
		   SELECT sender AS identity FROM handoffs WHERE bug_group_id = ?
		   UNION
		   SELECT r.recipient FROM handoff_recipients r
		     JOIN handoffs h ON h.id = r.handoff_id WHERE h.bug_group_id = ?
		 )`,
		bugGroupID, bugGroupID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		if id != "" {
			out = append(out, id)
		}
	}
	return out, rows.Err()
}

func (s *Store) ListComments(ctx context.Context, handoffID string) ([]handoffschema.Comment, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, sender, body, created_at FROM comments
		 WHERE handoff_id = ? ORDER BY created_at ASC`,
		handoffID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []handoffschema.Comment
	for rows.Next() {
		var c handoffschema.Comment
		var createdMS int64
		if err := rows.Scan(&c.ID, &c.Sender, &c.Body, &createdMS); err != nil {
			return nil, err
		}
		c.HandoffID = handoffID
		c.CreatedAt = time.UnixMilli(createdMS).UTC()
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) PutAttachment(ctx context.Context, handoffID, name, sha256Hex string, content []byte) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO attachments(handoff_id, name, sha256, size, content)
		 VALUES(?, ?, ?, ?, ?)
		 ON CONFLICT(handoff_id, name) DO UPDATE SET
		   sha256 = excluded.sha256,
		   size   = excluded.size,
		   content= excluded.content`,
		handoffID, name, sha256Hex, len(content), content,
	)
	return err
}

// GetAttachment returns the raw bytes plus sha256/size, or ErrNotFound.
func (s *Store) GetAttachment(ctx context.Context, handoffID, name string) ([]byte, string, int, error) {
	var content []byte
	var sum string
	var size int
	err := s.db.QueryRowContext(ctx,
		`SELECT content, sha256, size FROM attachments WHERE handoff_id = ? AND name = ?`,
		handoffID, name,
	).Scan(&content, &sum, &size)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", 0, ErrNotFound
	}
	if err != nil {
		return nil, "", 0, err
	}
	return content, sum, size, nil
}

// Ack marks the caller's per-recipient slot as picked. When every slot on the
// handoff has closed (picked or reassigned), the parent handoffs.state also
// rolls forward to "picked". For legacy single-recipient handoffs this matches
// the original semantics exactly (one slot ⇒ slot-close == parent-close).
func (s *Store) Ack(ctx context.Context, id, byIdentity string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// Make sure the handoff exists first so the per-slot UPDATE NotFound vs
	// Forbidden distinction stays accurate.
	var parentState string
	if err := tx.QueryRowContext(ctx, `SELECT state FROM handoffs WHERE id = ?`, id).Scan(&parentState); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}

	res, err := tx.ExecContext(ctx,
		`UPDATE handoff_recipients SET state = ?, picked_at = ?
		 WHERE handoff_id = ? AND recipient = ? AND state = ?`,
		string(handoffschema.StatePicked), time.Now().UnixMilli(),
		id, byIdentity, string(handoffschema.StatePending),
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		// Check whether the caller is even a recipient. If yes but already
		// picked/reassigned, it's idempotent-OK; otherwise forbidden.
		var slotState string
		err := tx.QueryRowContext(ctx,
			`SELECT state FROM handoff_recipients WHERE handoff_id = ? AND recipient = ?`,
			id, byIdentity,
		).Scan(&slotState)
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("%w: handoff not addressed to %s", ErrForbidden, byIdentity)
		}
		if err != nil {
			return err
		}
		// slot already closed — idempotent success, no state to advance
	}

	// Roll parent state forward when no pending slots remain. We treat
	// 'reassigned' as a terminal slot state — if every slot is either
	// picked or reassigned, the handoff is "done" from the relay's POV.
	var pending int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM handoff_recipients WHERE handoff_id = ? AND state = ?`,
		id, string(handoffschema.StatePending),
	).Scan(&pending); err != nil {
		return err
	}
	if pending == 0 && parentState == string(handoffschema.StatePending) {
		if _, err := tx.ExecContext(ctx,
			`UPDATE handoffs SET state = ?, picked_at = ? WHERE id = ? AND state = ?`,
			string(handoffschema.StatePicked), time.Now().UnixMilli(),
			id, string(handoffschema.StatePending),
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// Reassign closes one recipient's slot (state → reassigned), then inserts a
// fresh bug handoff inheriting the original's bug_group_id (allocating one if
// it was empty). Caller passes a pre-built Package for the new handoff; the
// store just runs the transaction. Returns ErrForbidden if `from` isn't a
// pending/picked recipient of `id`, ErrConflict if `to` is already busy in
// the same bug group, ErrNotFound if the handoff doesn't exist.
func (s *Store) Reassign(ctx context.Context, id, from string, newPkg *handoffschema.Package, reason string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var bugGroupID, kind string
	if err := tx.QueryRowContext(ctx, `SELECT bug_group_id, kind FROM handoffs WHERE id = ?`, id).Scan(&bugGroupID, &kind); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if kind != string(handoffschema.KindBug) {
		return fmt.Errorf("%w: handoff %s is kind=%s, only bug handoffs can be reassigned", ErrConflict, id, kind)
	}

	var slotState string
	err = tx.QueryRowContext(ctx,
		`SELECT state FROM handoff_recipients WHERE handoff_id = ? AND recipient = ?`,
		id, from,
	).Scan(&slotState)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%w: %s is not a recipient of %s", ErrForbidden, from, id)
	}
	if err != nil {
		return err
	}
	if slotState != string(handoffschema.StatePending) && slotState != string(handoffschema.StatePicked) {
		return fmt.Errorf("%w: cannot reassign slot in state %s", ErrConflict, slotState)
	}

	// Allocate a bug_group_id on the parent if this is the first reassign.
	if bugGroupID == "" {
		bugGroupID = "bg_" + id
		if _, err := tx.ExecContext(ctx,
			`UPDATE handoffs SET bug_group_id = ? WHERE id = ?`,
			bugGroupID, id,
		); err != nil {
			return err
		}
	}

	// Loop guard: refuse if `to` has *ever* been a recipient in the same
	// bug group. "They already weighed in; bouncing back means you should be
	// talking, not transferring." comment_handoff is the escape hatch.
	for _, to := range newPkg.Recipients {
		var seen int
		if err := tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM handoff_recipients r
			   JOIN handoffs h ON h.id = r.handoff_id
			  WHERE h.bug_group_id = ? AND r.recipient = ?`,
			bugGroupID, to,
		).Scan(&seen); err != nil {
			return err
		}
		if seen > 0 {
			return fmt.Errorf("%w: %s has already been involved in this bug group — use comment_handoff to coordinate instead of reassigning back", ErrConflict, to)
		}
	}

	if _, err := tx.ExecContext(ctx,
		`UPDATE handoff_recipients SET state = ?, picked_at = ?
		 WHERE handoff_id = ? AND recipient = ?`,
		string(handoffschema.StateReassigned), time.Now().UnixMilli(), id, from,
	); err != nil {
		return err
	}

	newPkg.BugGroupID = bugGroupID
	newPkg.ReassignedFrom = id
	newPkg.ReassignedReason = reason
	if err := insertHandoffInTx(ctx, tx, newPkg); err != nil {
		return err
	}

	// Roll the parent handoff forward if all its slots are closed now.
	var pending int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM handoff_recipients WHERE handoff_id = ? AND state = ?`,
		id, string(handoffschema.StatePending),
	).Scan(&pending); err != nil {
		return err
	}
	if pending == 0 {
		if _, err := tx.ExecContext(ctx,
			`UPDATE handoffs SET state = ?, picked_at = ? WHERE id = ? AND state = ?`,
			string(handoffschema.StatePicked), time.Now().UnixMilli(),
			id, string(handoffschema.StatePending),
		); err != nil {
			return err
		}
	}

	return tx.Commit()
}

// ErrConflict signals a state-machine violation — the caller asked for a
// transition the row's current state doesn't allow (e.g. retracting a handoff
// that's already been picked up). Server maps this to HTTP 409.
var ErrConflict = errors.New("state conflict")

// ErrForbidden signals an authorization failure — caller is not the sender
// (for retract) or not sender/recipient (for status). Server maps to 403.
var ErrForbidden = errors.New("forbidden")

// Retract marks a pending handoff as retracted, sender-only. On success
// returns the recipient identities so the caller can fan out
// handoff.retracted SSE events without a second roundtrip. For multi-recipient
// bug handoffs every recipient gets the notification. Returns ErrNotFound if
// id doesn't exist, ErrForbidden if caller isn't the sender, ErrConflict if
// the handoff was already picked or retracted.
func (s *Store) Retract(ctx context.Context, id, byIdentity string) ([]string, error) {
	var sender, recipient, recipientsJSON, state string
	err := s.db.QueryRowContext(ctx,
		`SELECT sender, recipient, recipients, state FROM handoffs WHERE id = ?`, id,
	).Scan(&sender, &recipient, &recipientsJSON, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if sender != byIdentity {
		return nil, fmt.Errorf("%w: handoff is owned by %s", ErrForbidden, sender)
	}
	if state != string(handoffschema.StatePending) {
		return nil, fmt.Errorf("%w: cannot retract handoff in state %s", ErrConflict, state)
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE handoffs SET state = ? WHERE id = ? AND sender = ? AND state = ?`,
		string(handoffschema.StateRetracted), id, byIdentity, string(handoffschema.StatePending),
	); err != nil {
		return nil, err
	}
	// Notify every recipient that still had an open slot.
	rows, err := s.db.QueryContext(ctx,
		`SELECT recipient FROM handoff_recipients WHERE handoff_id = ? AND state = ?`,
		id, string(handoffschema.StatePending),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var targets []string
	for rows.Next() {
		var r string
		if err := rows.Scan(&r); err != nil {
			return nil, err
		}
		targets = append(targets, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(targets) == 0 {
		// Fall back to the scalar/json recipient list so we at least notify
		// somebody when the handoff_recipients backfill hasn't run yet
		// (defense-in-depth; the migrate() backfill should always have
		// covered legacy rows by now).
		if recipientsJSON != "" {
			var rs []string
			if json.Unmarshal([]byte(recipientsJSON), &rs) == nil {
				targets = rs
			}
		}
		if len(targets) == 0 && recipient != "" {
			targets = []string{recipient}
		}
	}
	return targets, nil
}

// ListSent returns the caller's most recent sent handoffs (any state),
// newest-first. Mirrors ListPending for the sender side; senders can use this
// to see "did the recipient pick it up yet?" without polling status one-by-one.
// For multi-recipient bug handoffs Recipients is populated; Recipient remains
// the first recipient for back-compat with old clients reading the scalar.
func (s *Store) ListSent(ctx context.Context, sender string, limit int) ([]handoffschema.ListItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, sender, recipient, recipients, urgency, state, created_at, repo_name, branch, headline, kind, bug_group_id FROM handoffs
		 WHERE sender = ?
		 ORDER BY created_at DESC LIMIT ?`,
		sender, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []handoffschema.ListItem
	for rows.Next() {
		var (
			id, snd, recipient, recipientsJSON, urgency, state string
			repoName, branch, headline, kind, bugGroupID       string
			createdMS                                          int64
		)
		if err := rows.Scan(&id, &snd, &recipient, &recipientsJSON, &urgency, &state, &createdMS,
			&repoName, &branch, &headline, &kind, &bugGroupID); err != nil {
			return nil, err
		}
		item := handoffschema.ListItem{
			ID:         id,
			Kind:       handoffschema.Kind(kind),
			Sender:     snd,
			Recipient:  recipient,
			Urgency:    handoffschema.Urgency(urgency),
			State:      handoffschema.State(state),
			CreatedAt:  time.UnixMilli(createdMS).UTC(),
			RepoName:   repoName,
			Branch:     branch,
			Headline:   headline,
			BugGroupID: bugGroupID,
		}
		if recipientsJSON != "" {
			var rs []string
			if err := json.Unmarshal([]byte(recipientsJSON), &rs); err == nil {
				item.Recipients = rs
			}
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

// Status returns the per-handoff status snapshot for callers who want
// state + picked_at + comment summary without re-fetching the package
// payload. Caller must be the sender or recipient (server enforces). For
// bug handoffs PickupBy carries per-recipient slot state so testers can see
// "backend picked it up but frontend hasn't even read it" at a glance.
func (s *Store) Status(ctx context.Context, id string) (handoffschema.Status, error) {
	var (
		sender, recipient, recipientsJSON, state, bugGroupID string
		createdMS                                            int64
		pickedMS                                             sql.NullInt64
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT sender, recipient, recipients, state, created_at, picked_at, bug_group_id FROM handoffs WHERE id = ?`, id,
	).Scan(&sender, &recipient, &recipientsJSON, &state, &createdMS, &pickedMS, &bugGroupID)
	if errors.Is(err, sql.ErrNoRows) {
		return handoffschema.Status{}, ErrNotFound
	}
	if err != nil {
		return handoffschema.Status{}, err
	}

	var commentCount int
	var lastID sql.NullInt64
	err = s.db.QueryRowContext(ctx,
		`SELECT COUNT(*), MAX(id) FROM comments WHERE handoff_id = ?`, id,
	).Scan(&commentCount, &lastID)
	if err != nil {
		return handoffschema.Status{}, fmt.Errorf("count comments: %w", err)
	}

	out := handoffschema.Status{
		ID:           id,
		State:        handoffschema.State(state),
		Sender:       sender,
		Recipient:    recipient,
		CreatedAt:    time.UnixMilli(createdMS).UTC(),
		CommentCount: commentCount,
		BugGroupID:   bugGroupID,
	}
	if recipientsJSON != "" {
		var rs []string
		if err := json.Unmarshal([]byte(recipientsJSON), &rs); err == nil {
			out.Recipients = rs
		}
	}
	if pickedMS.Valid {
		t := time.UnixMilli(pickedMS.Int64).UTC()
		out.PickedAt = &t
	}

	// Per-recipient slot states. Only relevant when there's more than one
	// recipient — for 2-party delivery / request the parent state +
	// picked_at already says everything. Skip the extra query on the common
	// case to keep Status cheap.
	if len(out.Recipients) > 0 {
		slotRows, err := s.db.QueryContext(ctx,
			`SELECT recipient, state, picked_at FROM handoff_recipients WHERE handoff_id = ?`,
			id,
		)
		if err != nil {
			return handoffschema.Status{}, fmt.Errorf("read recipient slots: %w", err)
		}
		pickup := map[string]handoffschema.RecipientStatus{}
		for slotRows.Next() {
			var slotRecipient, slotState string
			var slotPickedMS sql.NullInt64
			if err := slotRows.Scan(&slotRecipient, &slotState, &slotPickedMS); err != nil {
				slotRows.Close()
				return handoffschema.Status{}, err
			}
			rs := handoffschema.RecipientStatus{State: handoffschema.State(slotState)}
			if slotPickedMS.Valid {
				t := time.UnixMilli(slotPickedMS.Int64).UTC()
				rs.PickedAt = &t
			}
			pickup[slotRecipient] = rs
		}
		slotRows.Close()
		if len(pickup) > 0 {
			out.PickupBy = pickup
		}
	}

	if lastID.Valid {
		var lc handoffschema.Comment
		var bodyMS int64
		err = s.db.QueryRowContext(ctx,
			`SELECT id, sender, body, created_at FROM comments WHERE id = ?`, lastID.Int64,
		).Scan(&lc.ID, &lc.Sender, &lc.Body, &bodyMS)
		if err != nil {
			return handoffschema.Status{}, fmt.Errorf("fetch last comment: %w", err)
		}
		lc.HandoffID = id
		lc.CreatedAt = time.UnixMilli(bodyMS).UTC()
		// Truncate to 80 runes — Status is meant for summary display, full
		// body comes from ListComments when the user wants details.
		if r := []rune(lc.Body); len(r) > 80 {
			lc.Body = string(r[:80]) + "…"
		}
		out.LastComment = &lc
	}
	return out, nil
}
