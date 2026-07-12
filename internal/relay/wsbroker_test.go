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

func TestHandleWSControlProbeRepliesOnlyToCaller(t *testing.T) {
	b := newWsBroker()
	host := b.add("alice", "host")
	client := b.add("alice", "client")
	defer b.remove("alice", host)
	defer b.remove("alice", client)
	s := &Server{WsBroker: b}

	var env map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"t":"_probe","id":42}`), &env); err != nil {
		t.Fatal(err)
	}
	if !s.handleWSControl("alice", client, env) {
		t.Fatal("probe was not consumed by the broker")
	}
	select {
	case raw := <-client.send:
		var ack struct {
			Type string `json:"t"`
			ID   int64  `json:"id"`
		}
		if err := json.Unmarshal(raw, &ack); err != nil {
			t.Fatal(err)
		}
		if ack.Type != wsProbeAckFrameType || ack.ID != 42 {
			t.Fatalf("unexpected probe ack: %+v", ack)
		}
	default:
		t.Fatal("probe ack was not queued")
	}
	select {
	case raw := <-host.send:
		t.Fatalf("probe leaked to host: %s", raw)
	default:
	}
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
	var relayList map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"t":"list"}`), &relayList); err != nil {
		t.Fatal(err)
	}
	client.observePTYMode(relayList)
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

func TestWsBrokerStrictClientFiltersRelayTerminalContent(t *testing.T) {
	b := newWsBroker()
	host := b.add("alice", "host")
	client := b.add("alice", "client")
	defer b.remove("alice", host)
	defer b.remove("alice", client)

	deliver := func(frame string) {
		var env map[string]json.RawMessage
		if err := json.Unmarshal([]byte(frame), &env); err != nil {
			t.Fatal(err)
		}
		deliverApplication(context.Background(), host, client, []byte(frame), env)
	}

	// Unknown clients fail closed before their first list/mode declaration.
	deliver(`{"t":"term.output","sid":"s1","routeId":"r1","seq":1,"d":"secret"}`)
	if len(client.send) != 0 {
		t.Fatal("unknown client received Relay terminal content")
	}

	var strictList map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"t":"list","ptyMode":"p2p"}`), &strictList); err != nil {
		t.Fatal(err)
	}
	client.observePTYMode(strictList)
	for _, frame := range []string{
		`{"t":"term.output","sid":"s1","routeId":"r1","seq":1,"d":"secret"}`,
		`{"t":"screen","sid":"s1","text":"secret"}`,
		`{"t":"reply","sid":"s1","text":"secret"}`,
		`{"t":"status","sid":"s1","text":"secret"}`,
		`{"t":"activity","sid":"s1","items":[{"text":"secret"}]}`,
		`{"t":"overview","items":[{"preview":"secret"}]}`,
	} {
		deliver(frame)
	}
	if len(client.send) != 0 {
		t.Fatal("strict client received Relay terminal content")
	}

	deliver(`{"t":"overview","ptySafe":true,"items":[{"preview":""}]}`)
	deliver(`{"t":"sessions","items":[]}`)
	if len(client.send) != 2 {
		t.Fatalf("strict-safe metadata was not delivered: queue=%d", len(client.send))
	}

	var relayMode map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"t":"pty.signal","kind":"mode","mode":"relay"}`), &relayMode); err != nil {
		t.Fatal(err)
	}
	client.observePTYMode(relayMode)
	deliver(`{"t":"term.output","sid":"s1","routeId":"r2","seq":1,"d":"allowed"}`)
	if len(client.send) != 3 {
		t.Fatal("Relay-mode client did not receive terminal output")
	}
}

func TestWsBrokerReliableEnqueueSurvivesTemporaryBackpressure(t *testing.T) {
	b := newWsBroker()
	peer := b.add("alice", "host")
	defer b.remove("alice", peer)
	for i := 0; i < cap(peer.send); i++ {
		deliverBestEffort(peer, []byte(`{"t":"term.output"}`))
	}

	input := []byte(`{"t":"term.input","d":"\r"}`)
	delivered := make(chan bool, 1)
	go func() {
		delivered <- deliverReliable(context.Background(), peer, input)
	}()
	// A transient stall longer than the removed 500ms cutoff must not discard
	// the user's final key/Enter. The writer deadline or connection close remains
	// the upper bound for a genuinely dead peer.
	time.Sleep(600 * time.Millisecond)
	<-peer.send
	select {
	case ok := <-delivered:
		if !ok {
			t.Fatal("temporary backpressure dropped a reliable frame")
		}
	case <-time.After(time.Second):
		t.Fatal("reliable frame did not enter the queue after capacity returned")
	}
	var last []byte
	for i := 0; i < cap(peer.send); i++ {
		last = <-peer.send
	}
	if string(last) != string(input) {
		t.Fatalf("last reliable frame = %s, want %s", last, input)
	}
}

func TestWsBrokerDisconnectClosesPeerWhenPresenceQueueIsFull(t *testing.T) {
	b := newWsBroker()
	host := b.add("alice", "host")
	client := b.add("alice", "client")
	defer b.remove("alice", client)
	for i := 0; i < cap(host.send); i++ {
		if !deliverBestEffort(host, []byte(`{"t":"_peer"}`)) {
			t.Fatal("failed to fill host queue")
		}
	}

	s := &Server{WsBroker: b}
	s.wsNotifyPeers("alice", client, "disconnect")

	if !host.closed.Load() {
		t.Fatal("host with a saturated presence queue was left stale")
	}
	if peers := b.rolePeers("alice", "host"); len(peers) != 0 {
		t.Fatalf("closed host remained registered: %v", connIDs(peers))
	}
}

func TestWsBrokerStrictClientDisconnectKeepsHostAndSendsPresence(t *testing.T) {
	b := newWsBroker()
	host := b.add("alice", "host")
	client := b.add("alice", "client")
	defer b.remove("alice", host)
	defer b.remove("alice", client)
	var strictMode map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"t":"pty.signal","kind":"mode","mode":"p2p"}`), &strictMode); err != nil {
		t.Fatal(err)
	}
	client.observePTYMode(strictMode)

	(&Server{WsBroker: b}).wsNotifyPeers("alice", client, "disconnect")

	if host.closed.Load() {
		t.Fatal("ordinary strict disconnect evicted the shared host")
	}
	select {
	case raw := <-host.send:
		var note map[string]any
		if err := json.Unmarshal(raw, &note); err != nil {
			t.Fatal(err)
		}
		if note["t"] != "_peer" || note["event"] != "disconnect" || note["connId"] != float64(client.id) {
			t.Fatalf("unexpected presence note: %#v", note)
		}
	default:
		t.Fatal("strict disconnect did not enqueue presence")
	}
}

func TestWsBrokerStrictBarrierEvictsOnlyCurrentIdentityHosts(t *testing.T) {
	b := newWsBroker()
	hostA := b.add("alice", "host")
	hostB := b.add("alice", "host")
	client := b.add("alice", "client")
	otherClient := b.add("alice", "client")
	otherHost := b.add("bob", "host")
	defer b.remove("alice", client)
	defer b.remove("alice", otherClient)
	defer b.remove("bob", otherHost)

	var barrier map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"t":"pty.strictBarrier","to":999}`), &barrier); err != nil {
		t.Fatal(err)
	}
	s := &Server{WsBroker: b}
	if !s.handleWSControl("alice", client, barrier) {
		t.Fatal("strict barrier was not consumed")
	}
	if !hostA.closed.Load() || !hostB.closed.Load() {
		t.Fatal("strict barrier left an alice host connected")
	}
	if otherClient.closed.Load() {
		t.Fatal("strict barrier closed a same-identity client")
	}
	if otherHost.closed.Load() {
		t.Fatal("strict barrier crossed identity boundary")
	}
	if got := client.ptyMode.Load(); got != wsPTYModeStrict {
		t.Fatalf("barrier client mode = %d, want strict", got)
	}
	if got := b.rolePeers("alice", "host"); len(got) != 0 {
		t.Fatalf("barrier hosts remained registered: %v", connIDs(got))
	}
	if len(otherClient.send) != 0 {
		t.Fatal("broker-owned barrier leaked to an application peer")
	}

	// The frame is broker-owned even from the wrong role, but only a client may
	// activate it.
	if !s.handleWSControl("bob", otherHost, barrier) {
		t.Fatal("host barrier frame was not swallowed")
	}
	if otherHost.closed.Load() {
		t.Fatal("host role activated a strict barrier")
	}
}

func TestWsBrokerQueueHasAByteBudget(t *testing.T) {
	b := newWsBroker()
	peer := b.add("alice", "client")
	defer b.remove("alice", peer)
	frame := make([]byte, wsMaxQueuedBytes/2+1)
	if !deliverBestEffort(peer, frame) {
		t.Fatal("first frame should fit the byte budget")
	}
	if deliverBestEffort(peer, frame) {
		t.Fatal("second frame exceeded the byte budget")
	}
}

func TestWsBrokerSingleSlowClientDoesNotBlockHost(t *testing.T) {
	b := newWsBroker()
	host := b.add("alice", "host")
	client := b.add("alice", "client")
	defer b.remove("alice", host)
	defer b.remove("alice", client)
	var relayList map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"t":"list"}`), &relayList); err != nil {
		t.Fatal(err)
	}
	client.observePTYMode(relayList)
	for i := 0; i < cap(client.send); i++ {
		if !deliverBestEffort(client, []byte(`{"t":"term.output"}`)) {
			t.Fatal("failed to fill client queue")
		}
	}
	frame := []byte(`{"t":"screen","sid":"s1","seq":1}`)
	var env map[string]json.RawMessage
	if err := json.Unmarshal(frame, &env); err != nil {
		t.Fatal(err)
	}

	deliverApplications(context.Background(), host, []*wsConn{client}, frame, env)

	if !client.closed.Load() {
		t.Fatal("single saturated client remained connected and blocked its Host")
	}
}

func TestWsBrokerSlowPeerDoesNotDelayConsecutiveHealthyFanout(t *testing.T) {
	b := newWsBroker()
	from := b.add("alice", "host")
	slow := b.add("alice", "client")
	healthy := b.add("alice", "client")
	defer b.remove("alice", from)
	defer b.remove("alice", slow)
	defer b.remove("alice", healthy)
	for _, client := range []*wsConn{slow, healthy} {
		var relayList map[string]json.RawMessage
		if err := json.Unmarshal([]byte(`{"t":"list"}`), &relayList); err != nil {
			t.Fatal(err)
		}
		client.observePTYMode(relayList)
	}
	for i := 0; i < cap(slow.send)-1; i++ {
		if !deliverBestEffort(slow, []byte(`{"t":"term.output"}`)) {
			t.Fatal("failed to fill slow peer")
		}
	}
	frames := [][]byte{
		[]byte(`{"t":"screen","sid":"s1","seq":1}`),
		[]byte(`{"t":"screen","sid":"s1","seq":2}`),
		[]byte(`{"t":"screen","sid":"s1","seq":3}`),
	}
	done := make(chan struct{})
	go func() {
		for _, frame := range frames {
			var env map[string]json.RawMessage
			if err := json.Unmarshal(frame, &env); err != nil {
				t.Error(err)
				return
			}
			deliverApplications(context.Background(), from, []*wsConn{slow, healthy}, frame, env)
		}
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("slow peer blocked the sender across fanout frames")
	}
	if !slow.closed.Load() {
		t.Fatal("saturated fanout peer remained connected after a reliable miss")
	}
	for _, want := range frames {
		select {
		case got := <-healthy.send:
			if string(got) != string(want) {
				t.Fatalf("healthy peer got %s, want %s", got, want)
			}
		default:
			t.Fatalf("healthy peer missed consecutive frame %s", want)
		}
	}
}
