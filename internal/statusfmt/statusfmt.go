package statusfmt

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

type Mode int

const (
	ModeCLI Mode = iota
	ModeMarkdown
)

type Options struct {
	Mode       Mode
	LocalTimes bool
}

func CLI(st *handoffschema.Status) string {
	return Format(st, Options{Mode: ModeCLI, LocalTimes: true})
}

func Markdown(st *handoffschema.Status) string {
	return Format(st, Options{Mode: ModeMarkdown, LocalTimes: false})
}

func Format(st *handoffschema.Status, opts Options) string {
	if st == nil {
		return ""
	}
	if opts.Mode == ModeMarkdown {
		return formatMarkdown(st, opts)
	}
	return formatCLI(st, opts)
}

func formatCLI(st *handoffschema.Status, opts Options) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "handoff %s\n", st.ID)
	fmt.Fprintf(&sb, "  state     : %s\n", st.State)
	fmt.Fprintf(&sb, "  sender    : %s\n", st.Sender)
	if len(st.Recipients) > 0 {
		fmt.Fprintf(&sb, "  recipients: %s\n", strings.Join(st.Recipients, ", "))
	} else {
		fmt.Fprintf(&sb, "  recipient : %s\n", st.Recipient)
	}
	fmt.Fprintf(&sb, "  created   : %s\n", formatTime(st.CreatedAt, time.RFC3339, opts.LocalTimes))
	if len(st.Recipients) > 0 {
		writeCLIPickupBy(&sb, st, opts)
	} else if st.PickedAt != nil {
		fmt.Fprintf(&sb, "  picked    : %s\n", formatTime(*st.PickedAt, time.RFC3339, opts.LocalTimes))
	} else {
		fmt.Fprintf(&sb, "  picked    : (not yet)\n")
	}
	fmt.Fprintf(&sb, "  comments  : %d\n", st.CommentCount)
	if st.LastComment != nil {
		fmt.Fprintf(&sb, "  last      : %s @ %s\n              %s\n",
			st.LastComment.Sender,
			formatTime(st.LastComment.CreatedAt, "2006-01-02T15:04:05", opts.LocalTimes),
			st.LastComment.Body,
		)
	}
	return sb.String()
}

func writeCLIPickupBy(sb *strings.Builder, st *handoffschema.Status, opts Options) {
	fmt.Fprintf(sb, "  pickup_by :\n")
	for _, recipient := range recipientOrder(st) {
		slot, ok := st.PickupBy[recipient]
		if !ok {
			fmt.Fprintf(sb, "    %s: unknown\n", recipient)
			continue
		}
		fmt.Fprintf(sb, "    %s: %s", recipient, slot.State)
		if slot.PickedAt != nil {
			fmt.Fprintf(sb, " @ %s", formatTime(*slot.PickedAt, time.RFC3339, opts.LocalTimes))
		}
		sb.WriteByte('\n')
	}
}

func formatMarkdown(st *handoffschema.Status, opts Options) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "handoff `%s`\n", st.ID)
	fmt.Fprintf(&sb, "- state: %s\n", st.State)
	fmt.Fprintf(&sb, "- sender: %s\n", st.Sender)
	if len(st.Recipients) > 0 {
		fmt.Fprintf(&sb, "- recipients: %s\n", quoteIdentities(st.Recipients))
	} else {
		fmt.Fprintf(&sb, "- recipient: %s\n", st.Recipient)
	}
	fmt.Fprintf(&sb, "- created: %s\n", formatTime(st.CreatedAt, "2006-01-02 15:04:05 MST", opts.LocalTimes))
	if len(st.Recipients) > 0 {
		sb.WriteString("- pickup_by:\n")
		for _, recipient := range recipientOrder(st) {
			slot, ok := st.PickupBy[recipient]
			if !ok {
				fmt.Fprintf(&sb, "  - `%s`: unknown\n", recipient)
				continue
			}
			fmt.Fprintf(&sb, "  - `%s`: %s", recipient, slot.State)
			if slot.PickedAt != nil {
				fmt.Fprintf(&sb, " at %s", formatTime(*slot.PickedAt, "2006-01-02 15:04:05 MST", opts.LocalTimes))
			}
			sb.WriteByte('\n')
		}
	} else if st.PickedAt != nil {
		fmt.Fprintf(&sb, "- picked: %s\n", formatTime(*st.PickedAt, "2006-01-02 15:04:05 MST", opts.LocalTimes))
	} else {
		sb.WriteString("- picked: (not yet)\n")
	}
	fmt.Fprintf(&sb, "- comments: %d\n", st.CommentCount)
	if st.LastComment != nil {
		fmt.Fprintf(&sb, "- last comment by %s: %s\n", st.LastComment.Sender, st.LastComment.Body)
	}
	return sb.String()
}

func recipientOrder(st *handoffschema.Status) []string {
	seen := make(map[string]struct{}, len(st.Recipients)+len(st.PickupBy))
	out := make([]string, 0, len(st.Recipients)+len(st.PickupBy))
	for _, recipient := range st.Recipients {
		recipient = strings.TrimSpace(recipient)
		if recipient == "" {
			continue
		}
		if _, ok := seen[recipient]; ok {
			continue
		}
		seen[recipient] = struct{}{}
		out = append(out, recipient)
	}
	var extras []string
	for recipient := range st.PickupBy {
		recipient = strings.TrimSpace(recipient)
		if recipient == "" {
			continue
		}
		if _, ok := seen[recipient]; ok {
			continue
		}
		extras = append(extras, recipient)
	}
	sort.Strings(extras)
	out = append(out, extras...)
	return out
}

func quoteIdentities(ids []string) string {
	if len(ids) == 0 {
		return ""
	}
	quoted := make([]string, 0, len(ids))
	for _, id := range ids {
		if strings.TrimSpace(id) == "" {
			continue
		}
		quoted = append(quoted, "`"+id+"`")
	}
	return strings.Join(quoted, ", ")
}

func formatTime(t time.Time, layout string, local bool) string {
	if local {
		t = t.Local()
	} else {
		t = t.UTC()
	}
	return t.Format(layout)
}
