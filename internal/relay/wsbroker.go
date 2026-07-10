package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/cc-collaboration/internal/relay/auth"
)

// The ws broker pipes opaque frames between a single user's own devices so a
// phone "client" can drive a desktop "host" workspace (terminal streams + file
// requests). It only interprets the top-level routing envelope: `to` selects an
// opposite-role peer and `from` is overwritten with the authenticated connId.
// Application payloads remain opaque, and another identity can never reach your
// host.
//
// A frame from a client is delivered to that identity's host(s); a frame from a
// host to the identity's client(s). A frame may target one peer via its
// top-level "to" connId (e.g. a host replying to the specific client that asked).
// State is in-memory and transient, exactly like the SSE Hub.

type wsConn struct {
	id        uint64
	role      string // "host" | "client"
	send      chan []byte
	done      chan struct{}
	closeOnce sync.Once
	closed    atomic.Bool
	cancel    context.CancelFunc
	onClose   func()
}

type wsBroker struct {
	mu     sync.Mutex
	nextID atomic.Uint64
	conns  map[string][]*wsConn // identity -> connections
}

func newWsBroker() *wsBroker { return &wsBroker{conns: map[string][]*wsConn{}} }

func (b *wsBroker) add(identity, role string, cancels ...context.CancelFunc) *wsConn {
	var cancel context.CancelFunc
	if len(cancels) > 0 {
		cancel = cancels[0]
	}
	c := &wsConn{
		id:     b.nextID.Add(1),
		role:   role,
		send:   make(chan []byte, 256),
		done:   make(chan struct{}),
		cancel: cancel,
	}
	c.onClose = func() { b.detach(identity, c) }
	b.mu.Lock()
	b.conns[identity] = append(b.conns[identity], c)
	b.mu.Unlock()
	return c
}

func (b *wsBroker) remove(identity string, c *wsConn) {
	c.close()
	b.detach(identity, c)
}

func (b *wsBroker) detach(identity string, c *wsConn) {
	b.mu.Lock()
	list := b.conns[identity]
	for i, x := range list {
		if x == c {
			b.conns[identity] = append(list[:i:i], list[i+1:]...)
			break
		}
	}
	if len(b.conns[identity]) == 0 {
		delete(b.conns, identity)
	}
	b.mu.Unlock()
}

func (c *wsConn) close() {
	c.closeOnce.Do(func() {
		c.closed.Store(true)
		close(c.done)
		if c.cancel != nil {
			c.cancel()
		}
		if c.onClose != nil {
			c.onClose()
		}
	})
}

// peers returns where a frame from `from` should go: the single connection with
// id==to if to>0, else every opposite-role connection of the same identity.
// Directed frames remain role-isolated: guessing a connId must not let one
// client address another client (or one host address another host).
func (b *wsBroker) peers(identity string, from *wsConn, to uint64) []*wsConn {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []*wsConn
	for _, c := range b.conns[identity] {
		if c == from || c.role == from.role {
			continue
		}
		if to != 0 {
			if c.id == to {
				out = append(out, c)
			}
		} else {
			out = append(out, c)
		}
	}
	return out
}

// rolePeers returns the identity's connections with the given role.
func (b *wsBroker) rolePeers(identity, role string) []*wsConn {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []*wsConn
	for _, c := range b.conns[identity] {
		if c.role == role {
			out = append(out, c)
		}
	}
	return out
}

// deliverBestEffort is reserved for explicitly disposable frames: Relay PTY
// output (which gets a reliable route-failure below) and peer presence hints.
func deliverBestEffort(c *wsConn, frame []byte) bool {
	if c.closed.Load() {
		return false
	}
	select {
	case c.send <- frame:
		return !c.closed.Load()
	case <-c.done:
		return false
	default:
		return false
	}
}

// deliverReliable applies bounded backpressure using the connection's fixed
// queue. A stuck WebSocket writer has its own 15s write deadline; writer failure
// closes done, which releases every blocked producer without a goroutine leak.
func deliverReliable(ctx context.Context, c *wsConn, frame []byte) bool {
	if c.closed.Load() {
		return false
	}
	select {
	case c.send <- frame:
		return !c.closed.Load()
	case <-c.done:
		return false
	case <-ctx.Done():
		return false
	}
}

func frameType(env map[string]json.RawMessage) string {
	var typ string
	_ = json.Unmarshal(env["t"], &typ)
	return typ
}

func relayOutputFailure(from, to uint64, env map[string]json.RawMessage) []byte {
	var sid, routeID string
	_ = json.Unmarshal(env["sid"], &sid)
	_ = json.Unmarshal(env["routeId"], &routeID)
	if sid == "" || routeID == "" {
		return nil
	}
	failure, err := json.Marshal(map[string]any{
		"t":       "term.routeFailed",
		"from":    from,
		"to":      to,
		"sid":     sid,
		"routeId": routeID,
		"reason":  "Relay 输出队列已满，请重新载入终端",
	})
	if err != nil {
		return nil
	}
	return failure
}

// deliverApplication keeps all application/control frames reliable except PTY
// output. If output is dropped, a modern route gets a reliable recovery frame;
// a legacy route is disconnected so its normal reconnect/history replay heals it.
func deliverApplication(
	ctx context.Context,
	from *wsConn,
	to *wsConn,
	frame []byte,
	env map[string]json.RawMessage,
) {
	if frameType(env) != "term.output" {
		if !deliverReliable(ctx, to, frame) {
			// Never silently lose an accepted reliable frame. Closing the target
			// forces its normal reconnect/resync path if the sender/server context
			// ended while backpressured.
			to.close()
		}
		return
	}
	if deliverBestEffort(to, frame) {
		return
	}
	failure := relayOutputFailure(from.id, to.id, env)
	if failure == nil {
		to.close()
		return
	}
	// Recovery belongs to the recipient route once the dropped frame was
	// accepted by the broker. Do not let a sender disconnect cancel this final
	// signal; the recipient's done channel still bounds/unblocks the enqueue.
	if !deliverReliable(context.Background(), to, failure) {
		to.close()
	}
}

func pumpWSWriter(
	ctx context.Context,
	c *wsConn,
	write func(context.Context, []byte) error,
) {
	defer c.close()
	for {
		select {
		case frame := <-c.send:
			if c.closed.Load() {
				return
			}
			wctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := write(wctx, frame)
			cancel()
			if err != nil {
				return
			}
		case <-c.done:
			return
		case <-ctx.Done():
			return
		}
	}
}

// ws is GET /v1/ws?role=host|client: upgrades to WebSocket, registers the
// connection under the authenticated identity, and pumps frames to/from peers.
func (s *Server) ws(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	if identity == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.WsBroker == nil {
		http.Error(w, "ws not enabled", http.StatusNotImplemented)
		return
	}
	role := r.URL.Query().Get("role")
	if role != "host" {
		role = "client"
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
		// permessage-deflate: terminal output (ANSI redraws, repeated text)
		// compresses ~6-8x. dart:io clients already offer it by default, so this
		// just enables negotiation; it's transparent to frame routing below.
		CompressionMode: websocket.CompressionContextTakeover,
	})
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(8 << 20) // allow large terminal / file-read frames

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	c := s.WsBroker.add(identity, role, cancel)
	defer s.WsBroker.remove(identity, c)

	// Hand the device its own connId, then tell the opposite role a peer joined
	// (so a host learns its clients' connIds for directed replies).
	if hello, err := json.Marshal(map[string]any{"t": "_hello", "connId": c.id, "role": role}); err == nil {
		deliverReliable(ctx, c, hello)
	}
	s.wsNotifyPeers(identity, c, "connect")
	defer s.wsNotifyPeers(identity, c, "disconnect")

	go pumpWSWriter(ctx, c, func(wctx context.Context, frame []byte) error {
		return conn.Write(wctx, websocket.MessageText, frame)
	})

	for {
		typ, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		active, err := s.Store.UserActive(ctx, identity)
		if err != nil || !active {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var env map[string]json.RawMessage
		if err := json.Unmarshal(data, &env); err != nil || env == nil {
			continue
		}
		var to uint64
		if raw := env["to"]; raw != nil {
			if err := json.Unmarshal(raw, &to); err != nil {
				continue
			}
		}
		// The connection id is authenticated transport metadata. Never trust a
		// caller-provided `from`, because PTY routes use it as a peer identity.
		from, err := json.Marshal(c.id)
		if err != nil {
			continue
		}
		env["from"] = from
		stamped, err := json.Marshal(env)
		if err != nil {
			continue
		}
		for _, p := range s.WsBroker.peers(identity, c, to) {
			deliverApplication(ctx, c, p, stamped, env)
		}
	}
}

// wsNotifyPeers tells the opposite-role connections that a peer connected or
// disconnected, so a host can track which phones are currently attached.
func (s *Server) wsNotifyPeers(identity string, c *wsConn, event string) {
	other := "client"
	if c.role == "client" {
		other = "host"
	}
	note, err := json.Marshal(map[string]any{"t": "_peer", "event": event, "connId": c.id, "role": c.role})
	if err != nil {
		return
	}
	for _, p := range s.WsBroker.rolePeers(identity, other) {
		deliverBestEffort(p, note)
	}
}
