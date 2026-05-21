package desktop

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/cc-collaboration/internal/notify"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// startSSE subscribes the desktop client to the relay event stream. The
// subscription auto-reconnects until ctx is cancelled (which happens when the
// main window is closed). Events drive incremental list / detail / online
// refreshes; nothing here triggers native notifications yet — Phase 4 layers
// that on top.
func (a *App) startSSE(ctx context.Context) {
	go func() {
		err := a.client.Subscribe(ctx, a.identity, a.handleEvent)
		if err != nil && ctx.Err() == nil {
			log.Printf("desktop sse: %v", err)
			a.toast(fmt.Sprintf("SSE disconnected: %v", err))
		}
	}()
}

func (a *App) handleEvent(ev transport.SSEEvent) error {
	switch ev.Type {
	case sse.EventTypeHandoffCreated:
		var item handoffschema.ListItem
		if err := json.Unmarshal(ev.Data, &item); err != nil {
			return nil
		}
		a.onHandoffCreated(item)
	case sse.EventTypeHandoffRetracted:
		var ret handoffschema.RetractEvent
		_ = json.Unmarshal(ev.Data, &ret)
		// Recipient view loses the row; sender's view still shows it as
		// retracted. Easiest correct path is to refetch the active list.
		a.refreshListAsync()
		a.toast("Handoff retracted by sender.")
		go a.notifyRetracted(ret)
	case sse.EventTypeCommentCreated:
		var c handoffschema.Comment
		if err := json.Unmarshal(ev.Data, &c); err != nil {
			return nil
		}
		a.onCommentCreated(c)
	case sse.EventTypeUserOnline, sse.EventTypeUserOffline:
		go a.refreshOnline()
	}
	return nil
}

func (a *App) onHandoffCreated(item handoffschema.ListItem) {
	mine := isRecipient(item, a.identity)
	// Only the Inbox view automatically pulls in new arrivals; Sent /
	// History stay manual to avoid surprising rearrangement while the user
	// is reading.
	if a.currentView() == viewInbox && mine {
		a.refreshListAsync()
	}
	a.toast(fmt.Sprintf("New handoff %s from %s", item.ID, item.Sender))
	if mine {
		subtitle := item.RepoName
		if subtitle == "" {
			subtitle = item.Sender
		}
		body := item.Headline
		if body == "" {
			body = item.ID
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = notify.Show(ctx, notify.Notification{
				Title:    "cc-handoff",
				Subtitle: subtitle,
				Body:     body,
			})
		}()
	}
}

func (a *App) onCommentCreated(c handoffschema.Comment) {
	if c.HandoffID == a.currentSelected() {
		go a.loadSelected()
	}
	a.toast(fmt.Sprintf("Comment on %s by %s", c.HandoffID, c.Sender))
	// The relay only fans comment.created out to participants other than
	// the comment's author, so every event reaching us is for us. Always
	// notify; users can mute via macOS Focus / Windows Quiet hours.
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = notify.Show(ctx, notify.Notification{
			Title:    "cc-handoff comment",
			Subtitle: c.HandoffID,
			Body:     c.Sender + ": " + firstLine(c.Body),
		})
	}()
}

func (a *App) notifyRetracted(ret handoffschema.RetractEvent) {
	body := "by " + ret.Sender
	if ret.Reason != "" {
		body += ": " + ret.Reason
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = notify.Show(ctx, notify.Notification{
		Title:    "cc-handoff retracted",
		Subtitle: ret.ID,
		Body:     body,
	})
}

func isRecipient(it handoffschema.ListItem, identity string) bool {
	if it.Recipient == identity {
		return true
	}
	for _, r := range it.Recipients {
		if r == identity {
			return true
		}
	}
	return false
}
