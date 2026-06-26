// Package localbus is the storage half of the desktop app's local session
// message bus. The desktop app delivers a peer message into a sibling session
// one of two ways depending on whether that session's agent is mid-turn:
//
//   - idle  → paste the text straight into the target's PTY (immediate turn);
//   - busy  → drop the message into this inbox, where the target session's
//     PostToolUse / Stop hook (`cc-handoff bus-hook`) drains it as
//     additionalContext, so a running turn sees the message at its next tool
//     boundary instead of having it queue behind the whole turn.
//
// The inbox is keyed by the receiver's session id, the same CC_SESSION_ID the
// app injects into the session env. This file is the on-disk contract between
// the app (writer, in Dart) and the hook (reader, here): mirror it on both
// sides. It deliberately mirrors internal/inbox/unread.go (the cross-machine
// comment markers the Stop hook drains) so the two wake paths read the same.
package localbus

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Msg is one peer message parked for a busy session. It carries the sender's
// session id and label so the hook can render the same "[来自 调研 · ts2]"
// header (and reply cheat-sheet) the app pastes for an idle target — the
// receiving agent shouldn't be able to tell which delivery path was used.
type Msg struct {
	From      string `json:"from"`                // sender session id (e.g. "ts2")
	FromLabel string `json:"fromLabel,omitempty"` // sender's human label
	Body      string `json:"body"`
}

// Entry pairs a parked Msg with its on-disk path so the hook can delete the
// markers it actually delivered (and only those).
type Entry struct {
	Path string
	Msg  Msg
}

// InboxDir is <busDir>/inbox/<sessionID> — the drop box the app writes to and
// the receiver's hook drains. Keyed by session id so each session drains only
// its own messages.
func InboxDir(busDir, sessionID string) string {
	return filepath.Join(busDir, "inbox", sessionID)
}

// WriteMsg persists one message as <inbox>/<seq>.json. Atomic (tmp+rename) so
// the hook's reader never sees a half-written file. seq should be a
// lexically-sortable, unique token (the app uses a microsecond timestamp +
// random suffix) so ListMsgs returns FIFO order. Provided for completeness and
// Go-side tests; in production the desktop app is the writer.
func WriteMsg(busDir, sessionID, seq string, m Msg) error {
	dir := InboxDir(busDir, sessionID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, seq+".json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// ListMsgs returns every parked message for sessionID in FIFO order (by
// filename, which the writer makes time-ordered). A missing inbox returns
// (nil, nil) — the common "no messages waiting" case, not an error. Files that
// fail to parse are skipped rather than aborting the drain, matching
// inbox.ListUnread: one corrupt marker must not strand the rest.
func ListMsgs(busDir, sessionID string) ([]Entry, error) {
	dir := InboxDir(busDir, sessionID)
	files, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []Entry
	for _, f := range files {
		if f.IsDir() || !strings.HasSuffix(f.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, f.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var m Msg
		if err := json.Unmarshal(raw, &m); err != nil {
			continue
		}
		out = append(out, Entry{Path: path, Msg: m})
	}
	sort.Slice(out, func(i, j int) bool {
		return filepath.Base(out[i].Path) < filepath.Base(out[j].Path)
	})
	return out, nil
}

// ClearMsgs deletes the marker files of delivered entries. Per-file errors are
// logged and swallowed: a partial failure must not strand markers and re-fire
// the same messages on the next hook (a wake-loop), mirroring inbox.ClearUnread.
func ClearMsgs(entries []Entry) {
	for _, e := range entries {
		if err := os.Remove(e.Path); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "warning: clear bus message %s: %v\n", e.Path, err)
		}
	}
}
