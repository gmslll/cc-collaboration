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
	h.subs[id] = sub
	h.mu.Unlock()

	cancel := func() {
		h.mu.Lock()
		if _, ok := h.subs[id]; ok {
			delete(h.subs, id)
			close(sub.ch)
		}
		h.mu.Unlock()
	}
	return sub, cancel
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
