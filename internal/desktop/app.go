// Package desktop implements the Fyne-based native client for cc-handoff.
// Phase 2 ships Inbox / Sent / History views with a detail pane and the three
// core actions (Mark Picked, Retract, Comment). Phase 3 will wire SSE for
// live refresh; Phase 4 adds system tray + native notifications.
package desktop

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	fyneapp "fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"

	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

const appID = "ai.claude.cc-handoff"

const (
	viewInbox   = "recipient"
	viewSent    = "sender"
	viewHistory = "history"
)

type App struct {
	client   *transport.Client
	identity string

	fyneApp fyne.App
	window  fyne.Window

	// UI state (guarded by mu)
	mu       sync.Mutex
	view     string
	limit    int
	filter   string
	items    []handoffschema.ListItem
	online   []handoffschema.OnlineUser
	selected string
	pkg      *handoffschema.Package
	status   *handoffschema.Status
	comments []handoffschema.Comment

	// widgets
	list        *widget.List
	onlineList  *widget.List
	statusLabel *widget.Label
	searchEntry *widget.Entry
	limitSelect *widget.Select
	listTitle   *widget.Label
	listMeta    *widget.Label
	tabButtons  map[string]*widget.Button
	detail      *detailPane
}

func NewApp(client *transport.Client, identity string) *App {
	return &App{
		client:   client,
		identity: identity,
		view:     viewInbox,
		limit:    50,
	}
}

func (a *App) Run() error {
	a.fyneApp = fyneapp.NewWithID(appID)
	a.window = a.fyneApp.NewWindow(fmt.Sprintf("cc-handoff — %s", a.identity))
	a.window.Resize(fyne.NewSize(1180, 720))

	a.window.SetContent(a.buildUI())
	a.refreshAllAsync()

	ctx, cancel := context.WithCancel(context.Background())
	a.fyneApp.Lifecycle().SetOnStopped(cancel)
	a.installTray()
	a.startSSE(ctx)

	a.window.ShowAndRun()
	return nil
}

func (a *App) buildUI() fyne.CanvasObject {
	a.tabButtons = map[string]*widget.Button{
		viewInbox:   widget.NewButton("Inbox", func() { a.switchView(viewInbox) }),
		viewSent:    widget.NewButton("Sent", func() { a.switchView(viewSent) }),
		viewHistory: widget.NewButton("History", func() { a.switchView(viewHistory) }),
	}
	a.markActiveTab()

	a.searchEntry = widget.NewEntry()
	a.searchEntry.SetPlaceHolder("Filter id / sender / repo / headline")
	a.searchEntry.OnChanged = func(s string) {
		a.mu.Lock()
		a.filter = strings.ToLower(strings.TrimSpace(s))
		a.mu.Unlock()
		fyne.Do(a.list.Refresh)
		a.updateListMeta()
	}

	a.limitSelect = widget.NewSelect([]string{"25", "50", "100", "200"}, func(s string) {
		switch s {
		case "25":
			a.limit = 25
		case "100":
			a.limit = 100
		case "200":
			a.limit = 200
		default:
			a.limit = 50
		}
		a.refreshListAsync()
	})
	a.limitSelect.SetSelected("50")

	refresh := widget.NewButton("Refresh", a.refreshAllAsync)

	topBar := container.NewBorder(
		nil, nil,
		container.NewHBox(a.tabButtons[viewInbox], a.tabButtons[viewSent], a.tabButtons[viewHistory]),
		container.NewHBox(widget.NewLabel("Limit"), a.limitSelect, refresh),
		widget.NewLabel(""),
	)

	a.list = widget.NewList(
		func() int { return len(a.filteredItems()) },
		func() fyne.CanvasObject { return widget.NewLabel("") },
		func(id widget.ListItemID, obj fyne.CanvasObject) {
			items := a.filteredItems()
			if id < 0 || id >= len(items) {
				return
			}
			obj.(*widget.Label).SetText(formatRow(items[id]))
		},
	)
	a.list.OnSelected = func(id widget.ListItemID) {
		items := a.filteredItems()
		if id < 0 || id >= len(items) {
			return
		}
		a.selectHandoff(items[id].ID)
	}

	a.listTitle = widget.NewLabel(viewTitle(a.view))
	a.listMeta = widget.NewLabel("")

	a.onlineList = widget.NewList(
		func() int {
			a.mu.Lock()
			defer a.mu.Unlock()
			return len(a.online)
		},
		func() fyne.CanvasObject { return widget.NewLabel("") },
		func(id widget.ListItemID, obj fyne.CanvasObject) {
			a.mu.Lock()
			defer a.mu.Unlock()
			if id < 0 || id >= len(a.online) {
				return
			}
			u := a.online[id]
			dot := "○"
			if u.Online {
				dot = "●"
			}
			obj.(*widget.Label).SetText(fmt.Sprintf("%s %s", dot, u.Identity))
		},
	)

	leftHeader := container.NewVBox(
		container.NewBorder(nil, nil, a.listTitle, nil, a.listMeta),
		a.searchEntry,
	)
	leftSplit := container.NewVSplit(
		container.NewBorder(leftHeader, nil, nil, nil, a.list),
		container.NewBorder(widget.NewLabel("Online"), nil, nil, nil, a.onlineList),
	)
	leftSplit.SetOffset(0.7)

	a.detail = newDetailPane(a)

	body := container.NewHSplit(leftSplit, a.detail.container)
	body.SetOffset(0.34)

	a.statusLabel = widget.NewLabel("Ready")
	return container.NewBorder(topBar, a.statusLabel, nil, nil, body)
}

// switchView changes the current list view (Inbox/Sent/History) and clears
// the current selection so the detail pane resets.
func (a *App) switchView(v string) {
	a.mu.Lock()
	if a.view == v {
		a.mu.Unlock()
		return
	}
	a.view = v
	a.selected = ""
	a.pkg = nil
	a.status = nil
	a.comments = nil
	a.mu.Unlock()
	a.markActiveTab()
	fyne.Do(func() {
		a.list.UnselectAll()
		a.listTitle.SetText(viewTitle(v))
		a.detail.clear()
	})
	a.refreshListAsync()
}

func (a *App) markActiveTab() {
	for view, btn := range a.tabButtons {
		if view == a.view {
			btn.Importance = widget.HighImportance
		} else {
			btn.Importance = widget.MediumImportance
		}
		btn.Refresh()
	}
}

func (a *App) refreshAllAsync() {
	go a.refreshList()
	go a.refreshOnline()
}

func (a *App) refreshListAsync() { go a.refreshList() }

func (a *App) refreshList() {
	a.setStatus("Loading list…")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	view := a.currentView()
	var items []handoffschema.ListItem
	var err error
	switch view {
	case viewSent:
		items, err = a.client.ListSent(ctx, a.limit)
	case viewHistory:
		items, err = a.client.ListHistory(ctx, a.limit)
	default:
		items, err = a.client.List(ctx, "")
	}
	if err != nil {
		a.setStatus(fmt.Sprintf("Load failed: %v", err))
		return
	}

	a.mu.Lock()
	a.items = items
	a.mu.Unlock()

	fyne.Do(a.list.Refresh)
	a.updateListMeta()
	a.setStatus(fmt.Sprintf("Loaded %d handoff(s)", len(items)))
}

func (a *App) refreshOnline() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	users, err := a.client.ListOnlineUsers(ctx)
	if err != nil {
		return
	}
	a.mu.Lock()
	a.online = users
	a.mu.Unlock()
	fyne.Do(a.onlineList.Refresh)
}

func (a *App) selectHandoff(id string) {
	a.mu.Lock()
	a.selected = id
	a.mu.Unlock()
	go a.loadSelected()
}

func (a *App) loadSelected() {
	a.setStatus("Loading detail…")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	id := a.currentSelected()
	if id == "" {
		return
	}

	pkg, errPkg := a.client.Get(ctx, id)
	st, errSt := a.client.Status(ctx, id)
	cms, errCm := a.client.ListComments(ctx, id)
	if errPkg != nil {
		a.setStatus(fmt.Sprintf("Detail load failed: %v", errPkg))
		return
	}
	if errSt != nil {
		// Status may fail on very old relays; surface but keep package.
		a.setStatus(fmt.Sprintf("Status failed: %v", errSt))
	}
	if errCm != nil {
		a.setStatus(fmt.Sprintf("Comments failed: %v", errCm))
	}

	a.mu.Lock()
	a.pkg = pkg
	a.status = st
	a.comments = cms
	a.mu.Unlock()

	fyne.Do(a.detail.render)
	a.setStatus(fmt.Sprintf("Loaded handoff %s", id))
}

func (a *App) ackSelected() {
	id := a.currentSelected()
	if id == "" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := a.client.Ack(ctx, id); err != nil {
			a.toast("Ack failed: " + err.Error())
			return
		}
		a.toast("Marked picked.")
		a.loadSelected()
		a.refreshList()
	}()
}

func (a *App) retractSelected() {
	id := a.currentSelected()
	if id == "" {
		return
	}
	reasonEntry := widget.NewMultiLineEntry()
	reasonEntry.SetPlaceHolder("Reason (optional)")
	dialog.ShowCustomConfirm("Retract handoff", "Retract", "Cancel", reasonEntry, func(ok bool) {
		if !ok {
			return
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			if err := a.client.Retract(ctx, id, strings.TrimSpace(reasonEntry.Text)); err != nil {
				a.toast("Retract failed: " + err.Error())
				return
			}
			a.toast("Retracted.")
			a.loadSelected()
			a.refreshList()
		}()
	}, a.window)
}

func (a *App) postComment(body string) {
	id := a.currentSelected()
	if id == "" || strings.TrimSpace(body) == "" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if _, err := a.client.Comment(ctx, id, strings.TrimSpace(body)); err != nil {
			a.toast("Comment failed: " + err.Error())
			return
		}
		a.toast("Comment posted.")
		a.loadSelected()
	}()
}

func (a *App) currentView() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.view
}

func (a *App) currentSelected() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.selected
}

// filteredItems returns the visible subset of a.items honoring a.filter.
// Locks internally so callers don't need to.
func (a *App) filteredItems() []handoffschema.ListItem {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.filter == "" {
		return a.items
	}
	out := make([]handoffschema.ListItem, 0, len(a.items))
	for _, it := range a.items {
		if strings.Contains(haystack(it), a.filter) {
			out = append(out, it)
		}
	}
	return out
}

func (a *App) updateListMeta() {
	loaded := len(a.items)
	shown := len(a.filteredItems())
	fyne.Do(func() {
		a.listMeta.SetText(fmt.Sprintf("%d shown / %d loaded", shown, loaded))
	})
}

func (a *App) setStatus(s string) {
	if a.statusLabel == nil {
		return
	}
	fyne.Do(func() { a.statusLabel.SetText(s) })
}

// toast shows a transient message in the status bar. Phase 4 will route this
// through a richer notification surface; for now overloading the status line
// keeps the implementation small.
func (a *App) toast(s string) { a.setStatus(s) }
