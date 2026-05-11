package store

import (
	"context"
	"database/sql"
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
`); err != nil {
		return err
	}
	// Idempotent column addition for installs that predate the kind column.
	// SQLite returns "duplicate column name" when it already exists; treat
	// that as success.
	if _, err := s.db.Exec(`ALTER TABLE handoffs ADD COLUMN kind TEXT NOT NULL DEFAULT ''`); err != nil {
		if !strings.Contains(err.Error(), "duplicate column name") {
			return fmt.Errorf("add kind column: %w", err)
		}
	}
	return nil
}

var ErrNotFound = errors.New("handoff not found")

func (s *Store) Insert(ctx context.Context, p *handoffschema.Package) error {
	payload, err := json.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}
	headline, _, _ := strings.Cut(p.SummaryMD, "\n")
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO handoffs(id, sender, recipient, urgency, state, created_at, repo_name, branch, headline, kind, payload)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		p.ID, p.Sender, p.Recipient, string(p.Urgency),
		string(handoffschema.StatePending), p.CreatedAt.UnixMilli(),
		p.Repo.Name, p.Repo.Branch, headline, string(p.Kind), string(payload),
	)
	if err != nil {
		return fmt.Errorf("insert handoff: %w", err)
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
// Reads only denormalized columns; never decodes the full payload BLOB.
func (s *Store) ListPending(ctx context.Context, recipient string, limit int) ([]handoffschema.ListItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, sender, urgency, state, created_at, repo_name, branch, headline, kind FROM handoffs
		 WHERE recipient = ? AND state = ?
		 ORDER BY created_at ASC LIMIT ?`,
		recipient, string(handoffschema.StatePending), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []handoffschema.ListItem
	for rows.Next() {
		var (
			id, sender, urgency, state, repoName, branch, headline, kind string
			createdMS                                                    int64
		)
		if err := rows.Scan(&id, &sender, &urgency, &state, &createdMS, &repoName, &branch, &headline, &kind); err != nil {
			return nil, err
		}
		out = append(out, handoffschema.ListItem{
			ID:        id,
			Kind:      handoffschema.Kind(kind),
			Sender:    sender,
			Urgency:   handoffschema.Urgency(urgency),
			State:     handoffschema.State(state),
			CreatedAt: time.UnixMilli(createdMS).UTC(),
			RepoName:  repoName,
			Branch:    branch,
			Headline:  headline,
		})
	}
	return out, rows.Err()
}

// ListHistory returns compact list items addressed to recipient that have
// already been picked up, newest-first. Lets a recipient look back at "what
// did I receive recently?" — pending items live in ListPending, retracted
// items are intentionally excluded here.
func (s *Store) ListHistory(ctx context.Context, recipient string, limit int) ([]handoffschema.ListItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, sender, urgency, state, created_at, repo_name, branch, headline, kind FROM handoffs
		 WHERE recipient = ? AND state = ?
		 ORDER BY created_at DESC LIMIT ?`,
		recipient, string(handoffschema.StatePicked), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []handoffschema.ListItem
	for rows.Next() {
		var (
			id, sender, urgency, state, repoName, branch, headline, kind string
			createdMS                                                    int64
		)
		if err := rows.Scan(&id, &sender, &urgency, &state, &createdMS, &repoName, &branch, &headline, &kind); err != nil {
			return nil, err
		}
		out = append(out, handoffschema.ListItem{
			ID:        id,
			Kind:      handoffschema.Kind(kind),
			Sender:    sender,
			Urgency:   handoffschema.Urgency(urgency),
			State:     handoffschema.State(state),
			CreatedAt: time.UnixMilli(createdMS).UTC(),
			RepoName:  repoName,
			Branch:    branch,
			Headline:  headline,
		})
	}
	return out, rows.Err()
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

// ListCommentsSince returns comments visible to identity (caller is sender or
// recipient of the handoff) with id > since, excluding comments the caller
// posted themselves. Also returns the global max comment id for cursor bootstrap.
// limit <= 0 means "max_id only, no rows"; limit is capped at 500.
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
		`SELECT c.id, c.handoff_id, c.sender, c.body, c.created_at
		   FROM comments c JOIN handoffs h ON c.handoff_id = h.id
		  WHERE c.id > ? AND c.sender != ? AND (h.sender = ? OR h.recipient = ?)
		  ORDER BY c.id ASC LIMIT ?`,
		since, identity, identity, identity, limit,
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

func (s *Store) Ack(ctx context.Context, id, byIdentity string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE handoffs SET state = ?, picked_at = ?
		 WHERE id = ? AND recipient = ? AND state = ?`,
		string(handoffschema.StatePicked), time.Now().UnixMilli(),
		id, byIdentity, string(handoffschema.StatePending),
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		// Either not found, not addressed to caller, or already picked. The latter is idempotent-OK.
		// Distinguish by re-reading.
		var state, recipient string
		err := s.db.QueryRowContext(ctx,
			`SELECT state, recipient FROM handoffs WHERE id = ?`, id,
		).Scan(&state, &recipient)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if recipient != byIdentity {
			return fmt.Errorf("forbidden: handoff not addressed to %s", byIdentity)
		}
		// already picked — idempotent success
	}
	return nil
}

// ErrConflict signals a state-machine violation — the caller asked for a
// transition the row's current state doesn't allow (e.g. retracting a handoff
// that's already been picked up). Server maps this to HTTP 409.
var ErrConflict = errors.New("state conflict")

// ErrForbidden signals an authorization failure — caller is not the sender
// (for retract) or not sender/recipient (for status). Server maps to 403.
var ErrForbidden = errors.New("forbidden")

// Retract marks a pending handoff as retracted, sender-only. On success
// returns the recipient identity so the caller can fan out a
// handoff.retracted SSE event without a second roundtrip. Returns
// ErrNotFound if id doesn't exist, ErrForbidden if caller isn't the sender,
// ErrConflict if the handoff was already picked or retracted.
func (s *Store) Retract(ctx context.Context, id, byIdentity string) (string, error) {
	// Fetch sender + recipient + state in one query, then UPDATE if the
	// pre-state allows it. Two roundtrips on the success path (down from
	// three when callers had to call Status() first) and avoids the
	// expensive Status (with comment counts) on failure paths.
	var sender, recipient, state string
	err := s.db.QueryRowContext(ctx,
		`SELECT sender, recipient, state FROM handoffs WHERE id = ?`, id,
	).Scan(&sender, &recipient, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if sender != byIdentity {
		return "", fmt.Errorf("%w: handoff is owned by %s", ErrForbidden, sender)
	}
	if state != string(handoffschema.StatePending) {
		return "", fmt.Errorf("%w: cannot retract handoff in state %s", ErrConflict, state)
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE handoffs SET state = ? WHERE id = ? AND sender = ? AND state = ?`,
		string(handoffschema.StateRetracted), id, byIdentity, string(handoffschema.StatePending),
	); err != nil {
		return "", err
	}
	return recipient, nil
}

// ListSent returns the caller's most recent sent handoffs (any state),
// newest-first. Mirrors ListPending for the sender side; senders can use this
// to see "did the recipient pick it up yet?" without polling status one-by-one.
func (s *Store) ListSent(ctx context.Context, sender string, limit int) ([]handoffschema.ListItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, sender, recipient, urgency, state, created_at, repo_name, branch, headline, kind FROM handoffs
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
			id, snd, recipient, urgency, state, repoName, branch, headline, kind string
			createdMS                                                            int64
		)
		if err := rows.Scan(&id, &snd, &recipient, &urgency, &state, &createdMS, &repoName, &branch, &headline, &kind); err != nil {
			return nil, err
		}
		out = append(out, handoffschema.ListItem{
			ID:        id,
			Kind:      handoffschema.Kind(kind),
			Sender:    snd,
			Recipient: recipient,
			Urgency:   handoffschema.Urgency(urgency),
			State:     handoffschema.State(state),
			CreatedAt: time.UnixMilli(createdMS).UTC(),
			RepoName:  repoName,
			Branch:    branch,
			Headline:  headline,
		})
	}
	return out, rows.Err()
}

// Status returns the per-handoff status snapshot for callers who want
// state + picked_at + comment summary without re-fetching the package
// payload. Caller must be the sender or recipient (server enforces).
func (s *Store) Status(ctx context.Context, id string) (handoffschema.Status, error) {
	var (
		sender, recipient, state string
		createdMS                int64
		pickedMS                 sql.NullInt64
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT sender, recipient, state, created_at, picked_at FROM handoffs WHERE id = ?`, id,
	).Scan(&sender, &recipient, &state, &createdMS, &pickedMS)
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
	}
	if pickedMS.Valid {
		t := time.UnixMilli(pickedMS.Int64).UTC()
		out.PickedAt = &t
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
