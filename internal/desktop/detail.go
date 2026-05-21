package desktop

import (
	"fmt"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// detailPane is the right-hand pane: header (title/subtitle/badges),
// action bar (Ack / Retract), a scrollable markdown body rendering
// status+summary+metadata+API delta+comments, and a comment composer.
type detailPane struct {
	app       *App
	container fyne.CanvasObject

	title    *widget.Label
	subtitle *widget.Label
	body     *widget.RichText

	ackBtn     *widget.Button
	retractBtn *widget.Button

	commentInput *widget.Entry
	postBtn      *widget.Button
}

func newDetailPane(a *App) *detailPane {
	d := &detailPane{app: a}

	d.title = widget.NewLabelWithStyle("(no selection)", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	d.title.Wrapping = fyne.TextWrapWord
	d.subtitle = widget.NewLabel("")
	d.subtitle.Wrapping = fyne.TextWrapWord

	d.ackBtn = widget.NewButton("Mark picked", a.ackSelected)
	d.retractBtn = widget.NewButton("Retract", a.retractSelected)
	d.ackBtn.Disable()
	d.retractBtn.Disable()

	d.body = widget.NewRichTextFromMarkdown("")
	d.body.Wrapping = fyne.TextWrapWord
	bodyScroll := container.NewVScroll(d.body)

	d.commentInput = widget.NewMultiLineEntry()
	d.commentInput.SetPlaceHolder("Write a comment…")
	d.commentInput.SetMinRowsVisible(2)
	d.postBtn = widget.NewButton("Post comment", func() {
		text := d.commentInput.Text
		d.commentInput.SetText("")
		a.postComment(text)
	})
	d.postBtn.Disable()

	header := container.NewVBox(
		d.title,
		d.subtitle,
		container.NewHBox(d.ackBtn, d.retractBtn),
		widget.NewSeparator(),
	)
	footer := container.NewBorder(
		widget.NewSeparator(),
		nil, nil,
		d.postBtn,
		d.commentInput,
	)
	d.container = container.NewBorder(header, footer, nil, nil, bodyScroll)
	return d
}

// render rebinds the detail pane to whatever the App currently has loaded.
// Caller must be on the Fyne UI goroutine (use fyne.Do).
func (d *detailPane) render() {
	a := d.app
	a.mu.Lock()
	pkg := a.pkg
	status := a.status
	comments := a.comments
	view := a.view
	a.mu.Unlock()

	if pkg == nil {
		d.clear()
		return
	}

	headline := firstLine(pkg.SummaryMD)
	if headline == "" {
		headline = pkg.ID
	}
	d.title.SetText(headline)

	recipients := recipientsFromPackage(pkg)
	d.subtitle.SetText(fmt.Sprintf("%s → %s", nonEmpty(pkg.Sender, "-"), strings.Join(recipients, ", ")))

	state := ""
	if status != nil {
		state = string(status.State)
	}

	pickedAt := "-"
	if status != nil && status.PickedAt != nil {
		pickedAt = formatTime(*status.PickedAt)
	}
	commentCount := len(comments)
	if status != nil {
		commentCount = status.CommentCount
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "## Status\n\n")
	fmt.Fprintf(&sb, "- **State:** %s\n", nonEmpty(state, "-"))
	fmt.Fprintf(&sb, "- **Created:** %s\n", formatTime(pkg.CreatedAt))
	fmt.Fprintf(&sb, "- **Picked:** %s\n", pickedAt)
	fmt.Fprintf(&sb, "- **Comments:** %d\n", commentCount)
	if pkg.Urgency == handoffschema.UrgencyUrgent {
		fmt.Fprintf(&sb, "- **Urgency:** urgent\n")
	}
	if string(pkg.Kind) != "" {
		fmt.Fprintf(&sb, "- **Kind:** %s\n", pkg.Kind)
	}
	if status != nil && len(status.PickupBy) > 0 {
		fmt.Fprintf(&sb, "\n### Recipient slots\n\n")
		for ident, slot := range status.PickupBy {
			ts := ""
			if slot.PickedAt != nil {
				ts = " — " + formatTime(*slot.PickedAt)
			}
			fmt.Fprintf(&sb, "- **%s:** %s%s\n", ident, slot.State, ts)
		}
	}

	fmt.Fprintf(&sb, "\n## Summary\n\n")
	if strings.TrimSpace(pkg.SummaryMD) == "" {
		sb.WriteString("_(no summary)_\n")
	} else {
		sb.WriteString(pkg.SummaryMD)
		sb.WriteString("\n")
	}

	fmt.Fprintf(&sb, "\n## Metadata\n\n")
	rows := metadataRows(pkg)
	for _, r := range rows {
		fmt.Fprintf(&sb, "- **%s:** %s\n", r.key, r.value)
	}

	if pkg.APIDelta != nil {
		groups := []struct {
			label string
			ops   []handoffschema.Operation
		}{
			{"Added", pkg.APIDelta.Added},
			{"Changed", pkg.APIDelta.Changed},
			{"Removed", pkg.APIDelta.Removed},
		}
		printed := false
		for _, g := range groups {
			if len(g.ops) == 0 {
				continue
			}
			if !printed {
				fmt.Fprintf(&sb, "\n## API delta\n")
				printed = true
			}
			fmt.Fprintf(&sb, "\n### %s\n\n", g.label)
			for _, op := range g.ops {
				summary := ""
				if op.Summary != "" {
					summary = " — " + op.Summary
				}
				fmt.Fprintf(&sb, "- `%s %s`%s\n", op.Method, op.Path, summary)
			}
		}
	}

	fmt.Fprintf(&sb, "\n## Comments (%d)\n\n", len(comments))
	if len(comments) == 0 {
		sb.WriteString("_(no comments yet)_\n")
	} else {
		for _, c := range comments {
			fmt.Fprintf(&sb, "**%s** · %s\n\n%s\n\n---\n\n", c.Sender, formatTime(c.CreatedAt), c.Body)
		}
	}

	d.body.ParseMarkdown(sb.String())

	// Action button gating mirrors app.js:
	//   - Ack is enabled only on Inbox views with a still-pending handoff.
	//   - Retract is enabled only on Sent views with a still-pending handoff.
	pending := state == "" || state == string(handoffschema.StatePending)
	if view == viewInbox && pending {
		d.ackBtn.Enable()
	} else {
		d.ackBtn.Disable()
	}
	if view == viewSent && pending {
		d.retractBtn.Enable()
	} else {
		d.retractBtn.Disable()
	}
	d.postBtn.Enable()
}

func (d *detailPane) clear() {
	d.title.SetText("(no selection)")
	d.subtitle.SetText("")
	d.body.ParseMarkdown("Select a handoff from the list to view details.")
	d.ackBtn.Disable()
	d.retractBtn.Disable()
	d.postBtn.Disable()
}

type metadataRow struct {
	key, value string
}

func metadataRows(pkg *handoffschema.Package) []metadataRow {
	out := []metadataRow{
		{"ID", pkg.ID},
		{"Repo", pkg.Repo.Name},
		{"Branch", pkg.Repo.Branch},
		{"Head SHA", pkg.Repo.HeadSHA},
		{"Base SHA", pkg.Repo.BaseSHA},
		{"Sender", pkg.Sender},
		{"Recipients", strings.Join(recipientsFromPackage(pkg), ", ")},
		{"Amends", pkg.AmendsHandoff},
		{"Responds To", pkg.RespondsTo},
		{"Module Paths", strings.Join(pkg.ModulePaths, ", ")},
		{"Bug Group", pkg.BugGroupID},
		{"Reassigned From", pkg.ReassignedFrom},
	}
	if len(pkg.Attachments) > 0 {
		names := make([]string, 0, len(pkg.Attachments))
		for _, a := range pkg.Attachments {
			names = append(names, fmt.Sprintf("%s (%s)", a.Name, formatBytes(a.Size)))
		}
		out = append(out, metadataRow{"Attachments", strings.Join(names, ", ")})
	}
	if pkg.Git != nil && len(pkg.Git.ChangedPaths) > 0 {
		out = append(out, metadataRow{"Changed Paths", strings.Join(pkg.Git.ChangedPaths, ", ")})
	}
	filtered := out[:0]
	for _, r := range out {
		if strings.TrimSpace(r.value) != "" {
			filtered = append(filtered, r)
		}
	}
	return filtered
}
