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
	_, err := s.db.Exec(`
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
`)
	return err
}

var ErrNotFound = errors.New("handoff not found")

func (s *Store) Insert(ctx context.Context, p *handoffschema.Package) error {
	payload, err := json.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}
	headline, _, _ := strings.Cut(p.SummaryMD, "\n")
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO handoffs(id, sender, recipient, urgency, state, created_at, repo_name, branch, headline, payload)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		p.ID, p.Sender, p.Recipient, string(p.Urgency),
		string(handoffschema.StatePending), p.CreatedAt.UnixMilli(),
		p.Repo.Name, p.Repo.Branch, headline, string(payload),
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
		`SELECT id, sender, urgency, state, created_at, repo_name, branch, headline FROM handoffs
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
			id, sender, urgency, state, repoName, branch, headline string
			createdMS                                              int64
		)
		if err := rows.Scan(&id, &sender, &urgency, &state, &createdMS, &repoName, &branch, &headline); err != nil {
			return nil, err
		}
		out = append(out, handoffschema.ListItem{
			ID:        id,
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
