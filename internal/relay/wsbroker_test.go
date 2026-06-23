package relay

import "testing"

func connIDs(cs []*wsConn) []uint64 {
	out := make([]uint64, len(cs))
	for i, c := range cs {
		out[i] = c.id
	}
	return out
}

func TestWsBrokerRoutesByIdentityAndRole(t *testing.T) {
	b := newWsBroker()
	host := b.add("alice", "host")
	client := b.add("alice", "client")
	bobHost := b.add("bob", "host")

	// A client frame (to=0) goes to its own identity's host, nothing else.
	if got := b.peers("alice", client, 0); len(got) != 1 || got[0] != host {
		t.Fatalf("client→host routing wrong: %v", connIDs(got))
	}
	// A host frame (to=0) goes to its own identity's client.
	if got := b.peers("alice", host, 0); len(got) != 1 || got[0] != client {
		t.Fatalf("host→client routing wrong: %v", connIDs(got))
	}
	// Cross-identity isolation: bob's host must never receive alice's frames.
	for _, p := range b.peers("alice", client, 0) {
		if p == bobHost {
			t.Fatal("alice frame leaked to bob's host")
		}
	}
	// bob's host has no peers (no bob client connected).
	if got := b.peers("bob", bobHost, 0); len(got) != 0 {
		t.Fatalf("bob host should have no peers: %v", connIDs(got))
	}
	// Directed reply: a host can target one specific client by connId.
	if got := b.peers("alice", host, client.id); len(got) != 1 || got[0] != client {
		t.Fatalf("directed host→client wrong: %v", connIDs(got))
	}
	// rolePeers selects by role for presence notifications.
	if got := b.rolePeers("alice", "client"); len(got) != 1 || got[0] != client {
		t.Fatalf("rolePeers(client) wrong: %v", connIDs(got))
	}
	// After removal the host has no client peer and alice is cleaned up if empty.
	b.remove("alice", client)
	if got := b.peers("alice", host, 0); len(got) != 0 {
		t.Fatalf("after remove, host should have no peers: %v", connIDs(got))
	}
	b.remove("alice", host)
	if _, ok := b.conns["alice"]; ok {
		t.Fatal("identity entry should be deleted when last conn leaves")
	}
}
