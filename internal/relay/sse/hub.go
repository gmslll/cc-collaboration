// Package sse implements a tiny in-memory pub/sub for relay events.
// Subscribers filter by recipient identity; publishers fan out to all
// matching subscribers without blocking on slow clients.
package sse

import (
	"maps"
	"slices"
	"sync"
	"sync/atomic"
)

// EventTypeHandoffCreated is published when a new handoff is recorded by the
// relay. Subscribers should typically GET the full package by id and ack.
const EventTypeHandoffCreated = "handoff.created"

// EventTypeCommentCreated is published when a comment is appended to a
// handoff. Pushed to whichever side did NOT post the comment.
const EventTypeCommentCreated = "comment.created"

// EventTypeHandoffRetracted is published when a sender retracts a handoff
// that hasn't been picked up yet. Pushed to the recipient so their watch can
// surface "this was retracted" instead of leaving stale prompt files
// looking unhandled.
const EventTypeHandoffRetracted = "handoff.retracted"

// EventTypeUserOnline / EventTypeUserOffline are presence events: fan out to
// every OTHER subscribed identity when a new identity's first watch session
// connects (online) or its last one drops (offline). Reconnect blips can
// surface as offline-then-online — receivers can mute via the
// `mute_user_presence` trigger.
const EventTypeUserOnline = "user.online"
const EventTypeUserOffline = "user.offline"

// EventTypeLogAlert is published when a server-side hook forwards a log alert
// (POST /v1/alerts) for a recipient. Pushed to that recipient's watch, which
// writes it as a triage prompt and optionally auto-launches the agent.
const EventTypeLogAlert = "log.alert"

// EventTypeMessageDeliver is published when a user sends a short text to a
// specific session on another user's machine (POST /v1/messages). Pushed to the
// recipient, whose app asks the user to confirm before injecting it. Transient,
// like alerts — not persisted, no replay.
const EventTypeMessageDeliver = "message.deliver"

// EventTypeTodoCreated / EventTypeTodoUpdated / EventTypeTodoStatusChanged /
// EventTypeTodoAssigned / EventTypeTodoDeleted / EventTypeTodoCommentCreated
// are published by the Todo feature (internal/relay/todos.go). Unlike the
// handoff events above, every one of these carries the *complete* Todo JSON
// as its payload (not just an id) — see Server.publishTodoEvent — so a
// subscriber can upsert its local copy in place without a follow-up GET.
const (
	EventTypeTodoCreated        = "todo.created"
	EventTypeTodoUpdated        = "todo.updated"
	EventTypeTodoStatusChanged  = "todo.status_changed"
	EventTypeTodoAssigned       = "todo.assigned"
	EventTypeTodoDeleted        = "todo.deleted"
	EventTypeTodoCommentCreated = "todo.comment_created"
)

// subscriberBuffer caps per-subscriber backlog. A slow client can fall behind
// and drop events; recovery happens via Last-Event-Id reconnect, so the buffer
// only needs to absorb short bursts during a write to the wire.
const subscriberBuffer = 16

type Event struct {
	ID   uint64 // monotonic; clients use this as Last-Event-Id for resume
	Type string

	// Recipient is server-side filter metadata used by Hub.Publish. Clients
	// never observe it: SSE wire format only carries id, event, data.
	Recipient string

	Data []byte // pre-encoded JSON payload sent as the SSE `data:` line
}

type Subscriber struct {
	id        uint64
	recipient string
	ch        chan Event
}

func (s *Subscriber) C() <-chan Event { return s.ch }

type Hub struct {
	mu     sync.RWMutex
	nextID uint64
	subs   map[uint64]*Subscriber
	seq    atomic.Uint64

	// OnPresenceChange, if set, is invoked when an identity transitions between
	// having zero and at least one active subscriber. Called outside the hub
	// lock so the callback may itself call back into the hub (e.g. Publish)
	// without deadlocking. Same identity may flap on SSE reconnect blips.
	OnPresenceChange func(identity string, online bool)
}

func NewHub() *Hub {
	return &Hub{subs: make(map[uint64]*Subscriber)}
}

// Subscribe returns a channel that receives events addressed to recipient.
// The buffered channel drops events on slow consumers — the watch client
// must reconnect with Last-Event-Id to recover.
func (h *Hub) Subscribe(recipient string) (*Subscriber, func()) {
	h.mu.Lock()
	id := h.nextID
	h.nextID++
	sub := &Subscriber{id: id, recipient: recipient, ch: make(chan Event, subscriberBuffer)}
	becameOnline := h.countByIdentityLocked(recipient) == 0
	h.subs[id] = sub
	h.mu.Unlock()

	if becameOnline && h.OnPresenceChange != nil {
		h.OnPresenceChange(recipient, true)
	}

	cancel := func() {
		h.mu.Lock()
		var becameOffline bool
		if _, ok := h.subs[id]; ok {
			delete(h.subs, id)
			close(sub.ch)
			becameOffline = h.countByIdentityLocked(recipient) == 0
		}
		h.mu.Unlock()
		if becameOffline && h.OnPresenceChange != nil {
			h.OnPresenceChange(recipient, false)
		}
	}
	return sub, cancel
}

// countByIdentityLocked counts active subscribers for identity. Caller must
// hold h.mu (read or write).
func (h *Hub) countByIdentityLocked(identity string) int {
	n := 0
	for _, s := range h.subs {
		if s.recipient == identity {
			n++
		}
	}
	return n
}

// OnlineRecipients returns the active subscriber identities, deduped across
// any per-machine watch sessions a single identity might be running.
func (h *Hub) OnlineRecipients() []string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	seen := make(map[string]struct{}, len(h.subs))
	for _, s := range h.subs {
		seen[s.recipient] = struct{}{}
	}
	return slices.Sorted(maps.Keys(seen))
}

// Publish assigns a monotonic ID and fans out to matching subscribers.
// Non-blocking: if a subscriber's buffer is full, the event is dropped for
// that client.
func (h *Hub) Publish(e Event) Event {
	e.ID = h.seq.Add(1)
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, s := range h.subs {
		if s.recipient != e.Recipient {
			continue
		}
		select {
		case s.ch <- e:
		default:
		}
	}
	return e
}

// PublishExcept fans the event out to every active subscriber whose
// recipient identity differs from `except`. Used for presence broadcast
// where the identity coming online/offline shouldn't be notified about
// itself — this is the authoritative self-exclusion; receivers don't need
// to filter their own identity out of the payload.
func (h *Hub) PublishExcept(except string, e Event) Event {
	e.ID = h.seq.Add(1)
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, s := range h.subs {
		if s.recipient == except {
			continue
		}
		select {
		case s.ch <- e:
		default:
		}
	}
	return e
}
