package relay

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

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
	otherClient := b.add("alice", "client")
	bobHost := b.add("bob", "host")

	// A client frame (to=0) goes to its own identity's host, nothing else.
	if got := b.peers("alice", client, 0); len(got) != 1 || got[0] != host {
		t.Fatalf("client→host routing wrong: %v", connIDs(got))
	}
	// A host frame (to=0) goes to its own identity's client.
	if got := b.peers("alice", host, 0); len(got) != 2 || got[0] != client || got[1] != otherClient {
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
	if got := b.peers("alice", client, otherClient.id); len(got) != 0 {
		t.Fatalf("directed same-role frame was not isolated: %v", connIDs(got))
	}
	// rolePeers selects by role for presence notifications.
	if got := b.rolePeers("alice", "client"); len(got) != 2 || got[0] != client || got[1] != otherClient {
		t.Fatalf("rolePeers(client) wrong: %v", connIDs(got))
	}
	// After removal the host has no client peer and alice is cleaned up if empty.
	b.remove("alice", client)
	b.remove("alice", otherClient)
	if got := b.peers("alice", host, 0); len(got) != 0 {
		t.Fatalf("after remove, host should have no peers: %v", connIDs(got))
	}
	b.remove("alice", host)
	if _, ok := b.conns["alice"]; ok {
		t.Fatal("identity entry should be deleted when last conn leaves")
	}
}

func TestWsBrokerReliableFrameBackpressuresWithoutDroppingLastInput(t *testing.T) {
	b := newWsBroker()
	peer := b.add("alice", "host")
	defer b.remove("alice", peer)
	for i := 0; i < cap(peer.send); i++ {
		if !deliverBestEffort(peer, []byte(`{"t":"term.output"}`)) {
			t.Fatalf("queue filled early at %d", i)
		}
	}

	lastInput := []byte(`{"t":"term.input","d":"\r"}`)
	delivered := make(chan bool, 1)
	go func() { delivered <- deliverReliable(context.Background(), peer, lastInput) }()
	select {
	case <-delivered:
		t.Fatal("reliable input must backpressure while the queue is full")
	case <-time.After(20 * time.Millisecond):
	}

	<-peer.send
	select {
	case ok := <-delivered:
		if !ok {
			t.Fatal("reliable input was not enqueued after capacity became available")
		}
	case <-time.After(time.Second):
		t.Fatal("reliable input stayed blocked after capacity became available")
	}

	var last []byte
	for i := 0; i < cap(peer.send); i++ {
		last = <-peer.send
	}
	if string(last) != string(lastInput) {
		t.Fatalf("last reliable input was dropped: got %s", last)
	}
}

func TestWsBrokerDroppedOutputQueuesReliableRouteFailure(t *testing.T) {
	b := newWsBroker()
	host := b.add("alice", "host")
	client := b.add("alice", "client")
	defer b.remove("alice", host)
	defer b.remove("alice", client)
	for i := 0; i < cap(client.send); i++ {
		deliverBestEffort(client, []byte(`{"t":"term.output"}`))
	}

	frame := []byte(`{"t":"term.output","sid":"s1","routeId":"r1","from":1,"to":2,"seq":99,"d":"lost"}`)
	var env map[string]json.RawMessage
	if err := json.Unmarshal(frame, &env); err != nil {
		t.Fatal(err)
	}
	senderCtx, cancelSender := context.WithCancel(context.Background())
	cancelSender() // the last output's recovery must survive sender teardown.
	done := make(chan struct{})
	go func() {
		deliverApplication(senderCtx, host, client, frame, env)
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("full output queue unexpectedly accepted the dropped frame")
	case <-time.After(20 * time.Millisecond):
	}
	<-client.send
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("route failure did not enter the queue")
	}

	var recovery map[string]any
	for i := 0; i < cap(client.send); i++ {
		data := <-client.send
		if i == cap(client.send)-1 {
			if err := json.Unmarshal(data, &recovery); err != nil {
				t.Fatal(err)
			}
		}
	}
	if recovery["t"] != "term.routeFailed" || recovery["routeId"] != "r1" {
		t.Fatalf("missing reliable recovery frame: %#v", recovery)
	}
	if recovery["from"] != float64(host.id) || recovery["to"] != float64(client.id) {
		t.Fatalf("recovery identity was not broker-stamped: %#v", recovery)
	}
}

func TestWsBrokerPeerCloseReleasesBackpressuredReliableFrame(t *testing.T) {
	b := newWsBroker()
	peer := b.add("alice", "host")
	for i := 0; i < cap(peer.send); i++ {
		deliverBestEffort(peer, []byte(`{"t":"term.output"}`))
	}
	delivered := make(chan bool, 1)
	go func() {
		delivered <- deliverReliable(
			context.Background(),
			peer,
			[]byte(`{"t":"term.input","d":"\r"}`),
		)
	}()
	select {
	case <-delivered:
		t.Fatal("reliable producer did not backpressure")
	case <-time.After(20 * time.Millisecond):
	}
	peer.close()
	select {
	case ok := <-delivered:
		if ok {
			t.Fatal("closed peer reported a reliable delivery")
		}
	case <-time.After(time.Second):
		t.Fatal("closed peer did not release reliable producer")
	}
}

func TestWsBrokerWriterFailureCancelsAndRemovesConnection(t *testing.T) {
	b := newWsBroker()
	ctx, cancel := context.WithCancel(context.Background())
	peer := b.add("alice", "client", cancel)
	if !deliverReliable(ctx, peer, []byte(`{"t":"list"}`)) {
		t.Fatal("failed to enqueue writer test frame")
	}
	done := make(chan struct{})
	go func() {
		pumpWSWriter(ctx, peer, func(context.Context, []byte) error {
			return errors.New("write failed")
		})
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("writer failure did not stop the connection")
	}
	select {
	case <-ctx.Done():
	default:
		t.Fatal("writer failure did not cancel the reader context")
	}
	if got := b.rolePeers("alice", "client"); len(got) != 0 {
		t.Fatalf("failed writer remained registered: %v", connIDs(got))
	}
}
