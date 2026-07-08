package relay

import (
	"testing"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// TestSessionRegistryTTLAndClear is a white-box test of the in-memory registry:
// entries survive within the TTL, expire after it (pruned lazily on read), and
// clear() drops them (the presence-offline path).
func TestSessionRegistryTTLAndClear(t *testing.T) {
	now := time.Unix(1000, 0)
	r := newSessionRegistry()
	r.nowFunc = func() time.Time { return now }

	r.set("alice", []handoffschema.SessionInfo{{ID: "ts0", Label: "api"}})
	if got := r.get("alice"); len(got) != 1 || got[0].ID != "ts0" {
		t.Fatalf("get after set: %+v", got)
	}

	now = now.Add(publishedSessionTTL - time.Second) // still within TTL
	if got := r.get("alice"); len(got) != 1 {
		t.Fatalf("should still be live: %+v", got)
	}

	now = now.Add(2 * time.Second) // past TTL
	if got := r.get("alice"); got != nil {
		t.Fatalf("should be expired: %+v", got)
	}

	r.set("bob", []handoffschema.SessionInfo{{ID: "ts1"}})
	r.clear("bob")
	if got := r.get("bob"); got != nil {
		t.Fatalf("clear should drop sessions: %+v", got)
	}
}

func TestSessionRegistryEmptySetDeletesEntry(t *testing.T) {
	r := newSessionRegistry()

	r.set("alice", []handoffschema.SessionInfo{{ID: "ts0"}})
	r.set("alice", nil)

	if got := r.get("alice"); got != nil {
		t.Fatalf("empty set should clear sessions: %+v", got)
	}
	if _, ok := r.byID["alice"]; ok {
		t.Fatal("empty set should delete registry entry")
	}
}
