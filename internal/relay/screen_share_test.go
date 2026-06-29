package relay

import "testing"

func TestScreenShareBrokerRoutesOnlyWithinIdentityAndRoom(t *testing.T) {
	b := newScreenShareBroker()

	host := b.add("alice", "ROOM1", "host")
	viewer := b.add("alice", "ROOM1", "viewer")
	otherRoom := b.add("alice", "ROOM2", "viewer")
	otherUser := b.add("bob", "ROOM1", "viewer")

	got := b.peers("alice", "ROOM1", host, 0)
	if len(got) != 1 || got[0] != viewer {
		t.Fatalf("broadcast peers = %#v, want only same identity/room viewer", got)
	}

	got = b.peers("alice", "ROOM1", host, otherRoom.id)
	if len(got) != 0 {
		t.Fatalf("direct peer in other room delivered: %#v", got)
	}

	got = b.peers("alice", "ROOM1", host, otherUser.id)
	if len(got) != 0 {
		t.Fatalf("direct peer for other identity delivered: %#v", got)
	}
}
