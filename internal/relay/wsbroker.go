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
// requests). It is deliberately dumb: it never interprets payloads, only routes
// by the authenticated identity + connection role, so the relay stays a thin
// transport and another user can never reach your host (different identity).
//
// A frame from a client is delivered to that identity's host(s); a frame from a
// host to the identity's client(s). A frame may target one peer via its
// top-level "to" connId (e.g. a host replying to the specific client that asked).
// State is in-memory and transient, exactly like the SSE Hub.

type wsConn struct {
	id   uint64
	role string // "host" | "client"
	send chan []byte
}

type wsBroker struct {
	mu     sync.Mutex
	nextID atomic.Uint64
	conns  map[string][]*wsConn // identity -> connections
}

func newWsBroker() *wsBroker { return &wsBroker{conns: map[string][]*wsConn{}} }

func (b *wsBroker) add(identity, role string) *wsConn {
	c := &wsConn{id: b.nextID.Add(1), role: role, send: make(chan []byte, 256)}
	b.mu.Lock()
	b.conns[identity] = append(b.conns[identity], c)
	b.mu.Unlock()
	return c
}

func (b *wsBroker) remove(identity string, c *wsConn) {
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
	close(c.send)
}

// peers returns where a frame from `from` should go: the single connection with
// id==to if to>0, else every opposite-role connection of the same identity.
func (b *wsBroker) peers(identity string, from *wsConn, to uint64) []*wsConn {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []*wsConn
	for _, c := range b.conns[identity] {
		if c == from {
			continue
		}
		if to != 0 {
			if c.id == to {
				out = append(out, c)
			}
		} else if c.role != from.role {
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

// deliver enqueues a frame for a peer, dropping it if the peer is hopelessly
// behind rather than blocking the sender (one slow phone must not stall a host).
func deliver(c *wsConn, frame []byte) {
	select {
	case c.send <- frame:
	default:
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

	c := s.WsBroker.add(identity, role)
	defer s.WsBroker.remove(identity, c)

	ctx := r.Context()

	// Hand the device its own connId, then tell the opposite role a peer joined
	// (so a host learns its clients' connIds for directed replies).
	if hello, err := json.Marshal(map[string]any{"t": "_hello", "connId": c.id, "role": role}); err == nil {
		deliver(c, hello)
	}
	s.wsNotifyPeers(identity, c, "connect")
	defer s.wsNotifyPeers(identity, c, "disconnect")

	go func() {
		for frame := range c.send {
			wctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := conn.Write(wctx, websocket.MessageText, frame)
			cancel()
			if err != nil {
				return
			}
		}
	}()

	for {
		typ, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var env struct {
			To uint64 `json:"to"`
		}
		_ = json.Unmarshal(data, &env)
		for _, p := range s.WsBroker.peers(identity, c, env.To) {
			deliver(p, data)
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
		deliver(p, note)
	}
}
