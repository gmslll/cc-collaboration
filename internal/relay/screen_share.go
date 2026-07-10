package relay

import (
	"context"
	"encoding/json"
	"io/fs"
	"net/http"
	"regexp"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/cc-collaboration/internal/relay/auth"
)

var screenShareRoomRE = regexp.MustCompile(`^[A-Za-z0-9_-]{4,64}$`)

type screenShareConn struct {
	id     uint64
	role   string // "host" | "viewer"
	send   chan []byte
	mu     sync.Mutex
	closed bool
}

type screenShareRoom struct {
	identity string
	room     string
}

type screenShareBroker struct {
	mu     sync.Mutex
	nextID atomic.Uint64
	conns  map[screenShareRoom][]*screenShareConn
}

func newScreenShareBroker() *screenShareBroker {
	return &screenShareBroker{conns: map[screenShareRoom][]*screenShareConn{}}
}

func (b *screenShareBroker) add(identity, room, role string) *screenShareConn {
	c := &screenShareConn{id: b.nextID.Add(1), role: role, send: make(chan []byte, 256)}
	key := screenShareRoom{identity: identity, room: room}
	b.mu.Lock()
	b.conns[key] = append(b.conns[key], c)
	b.mu.Unlock()
	return c
}

func (b *screenShareBroker) remove(identity, room string, c *screenShareConn) {
	key := screenShareRoom{identity: identity, room: room}
	b.mu.Lock()
	list := b.conns[key]
	for i, x := range list {
		if x == c {
			b.conns[key] = append(list[:i:i], list[i+1:]...)
			break
		}
	}
	if len(b.conns[key]) == 0 {
		delete(b.conns, key)
	}
	b.mu.Unlock()
	c.mu.Lock()
	if !c.closed {
		close(c.send)
		c.closed = true
	}
	c.mu.Unlock()
}

func (b *screenShareBroker) peers(identity, room string, from *screenShareConn, to uint64) []*screenShareConn {
	key := screenShareRoom{identity: identity, room: room}
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []*screenShareConn
	for _, c := range b.conns[key] {
		if c == from {
			continue
		}
		if to != 0 {
			if c.id == to {
				out = append(out, c)
			}
			continue
		}
		if c.role != from.role {
			out = append(out, c)
		}
	}
	return out
}

func (b *screenShareBroker) rolePeers(identity, room, role string) []*screenShareConn {
	key := screenShareRoom{identity: identity, room: room}
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []*screenShareConn
	for _, c := range b.conns[key] {
		if c.role == role {
			out = append(out, c)
		}
	}
	return out
}

func deliverScreenShare(c *screenShareConn, frame []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	select {
	case c.send <- frame:
	default:
	}
}

func screenShareFileServer() http.Handler {
	sub, err := fs.Sub(screenShareFiles, "screen_share")
	if err != nil {
		return http.NotFoundHandler()
	}
	return http.StripPrefix("/share/", http.FileServerFS(sub))
}

// screenShareWS is GET /v1/screen-share/ws?role=host|viewer&room=...
//
// The route carries only WebRTC signaling frames (offer/answer/ice). Media stays
// peer-to-peer in the browsers unless ICE falls back to a configured TURN server
// in a future iteration.
func (s *Server) screenShareWS(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	if identity == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.ScreenShareBroker == nil {
		http.Error(w, "screen share not enabled", http.StatusNotImplemented)
		return
	}
	room := r.URL.Query().Get("room")
	if !screenShareRoomRE.MatchString(room) {
		http.Error(w, "invalid room", http.StatusBadRequest)
		return
	}
	role := r.URL.Query().Get("role")
	if role != "host" {
		role = "viewer"
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
		CompressionMode:    websocket.CompressionContextTakeover,
	})
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(2 << 20)

	c := s.ScreenShareBroker.add(identity, room, role)
	defer s.ScreenShareBroker.remove(identity, room, c)

	ctx := r.Context()
	if hello, err := json.Marshal(map[string]any{"t": "_hello", "connId": c.id, "role": role, "room": room}); err == nil {
		deliverScreenShare(c, hello)
	}
	s.screenShareNotifyPeers(identity, room, c, "connect")
	defer s.screenShareNotifyPeers(identity, room, c, "disconnect")

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
		active, err := s.Store.UserActive(ctx, identity)
		if err != nil || !active {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var env struct {
			To uint64 `json:"to"`
		}
		_ = json.Unmarshal(data, &env)
		for _, p := range s.ScreenShareBroker.peers(identity, room, c, env.To) {
			deliverScreenShare(p, data)
		}
	}
}

func (s *Server) screenShareNotifyPeers(identity, room string, c *screenShareConn, event string) {
	other := "viewer"
	if c.role == "viewer" {
		other = "host"
	}
	note, err := json.Marshal(map[string]any{"t": "_peer", "event": event, "connId": c.id, "role": c.role, "room": room})
	if err != nil {
		return
	}
	for _, p := range s.ScreenShareBroker.rolePeers(identity, room, other) {
		deliverScreenShare(p, note)
	}
}
