package localbus

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInboxRoundTripFIFO(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts1"

	// Write out of lexical order to prove ListMsgs sorts by filename (FIFO).
	msgs := []struct {
		seq string
		m   Msg
	}{
		{"100-1", Msg{From: "ts0", FromLabel: "调研", Body: "first"}},
		{"300-0", Msg{From: "ts2", FromLabel: "api", Body: "third"}},
		{"200-0", Msg{From: "ts0", FromLabel: "调研", Body: "second"}},
	}
	for _, w := range msgs {
		if err := WriteMsg(bus, sid, w.seq, w.m); err != nil {
			t.Fatalf("WriteMsg %s: %v", w.seq, err)
		}
	}

	// On-disk layout: <bus>/inbox/<sid>/<seq>.json
	if _, err := os.Stat(filepath.Join(bus, "inbox", sid, "200-0.json")); err != nil {
		t.Errorf("missing marker: %v", err)
	}
	// A message for a different session must not leak into sid's inbox.
	if err := WriteMsg(bus, "ts9", "001-0", Msg{From: "ts0", Body: "other"}); err != nil {
		t.Fatal(err)
	}

	entries, err := ListMsgs(bus, sid)
	if err != nil {
		t.Fatalf("ListMsgs: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("got %d entries, want 3", len(entries))
	}
	wantBodies := []string{"first", "second", "third"} // FIFO by filename
	for i, e := range entries {
		if e.Msg.Body != wantBodies[i] {
			t.Errorf("entry[%d] body=%q, want %q (FIFO broken)", i, e.Msg.Body, wantBodies[i])
		}
	}
	if entries[0].Msg.FromLabel != "调研" {
		t.Errorf("payload not round-tripped: %q", entries[0].Msg.FromLabel)
	}

	ClearMsgs(entries)
	again, err := ListMsgs(bus, sid)
	if err != nil {
		t.Fatalf("ListMsgs after clear: %v", err)
	}
	if len(again) != 0 {
		t.Errorf("expected 0 after clear, got %d", len(again))
	}
	ClearMsgs(entries) // safe re-clear
}

func TestListMsgsMissingInboxReturnsNil(t *testing.T) {
	got, err := ListMsgs(t.TempDir(), "nobody")
	if err != nil {
		t.Fatalf("expected nil error for missing inbox, got %v", err)
	}
	if got != nil {
		t.Errorf("expected nil entries, got %v", got)
	}
}

func TestListMsgsSkipsCorruptFile(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts1"
	if err := WriteMsg(bus, sid, "200-0", Msg{From: "ts0", Body: "good"}); err != nil {
		t.Fatal(err)
	}
	// A half-written / non-JSON marker must be skipped, not abort the drain.
	bad := filepath.Join(InboxDir(bus, sid), "100-0.json")
	if err := os.WriteFile(bad, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	entries, err := ListMsgs(bus, sid)
	if err != nil {
		t.Fatalf("ListMsgs: %v", err)
	}
	if len(entries) != 1 || entries[0].Msg.Body != "good" {
		t.Fatalf("expected 1 good entry, got %+v", entries)
	}
}
