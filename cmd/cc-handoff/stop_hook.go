package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
)

// runStopHook is invoked by Claude Code's Stop hook. It scans the receiver's
// inbox for unread partner comments dropped by `cc-handoff watch`, drains
// them, and emits a Stop-hook JSON response that pulls Claude back into
// another turn with the comment bodies in the standard decision reason.
//
// Exit-code policy: always 0. A non-zero exit triggers Claude Code's blocking
// error path (stderr → user) which would surprise the user every time they're
// not in a cc-handoff repo. Quiet no-op is the right behavior off the happy
// path. We also drain stdin if Claude Code is piping the hook payload, just
// to keep the writer side from blocking.
func runStopHook(ctx context.Context, args []string) error {
	// Drain stdin unconditionally and before any short-circuit return:
	// Claude Code pipes a (potentially kilobyte-sized) hook payload, and
	// returning early without consuming it can leave the writer side
	// blocked or surface an EPIPE in Claude's transcript.
	_, _ = io.Copy(io.Discard, os.Stdin)

	cwd, err := os.Getwd()
	if err != nil {
		return nil
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return nil
	}
	if !res.Triggers.WakeOnComment {
		return nil
	}

	inboxDir := inbox.InboxDir(config.RepoRoot(cwd), res.InboxOverride)
	entries, err := inbox.ListUnread(inboxDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stop-hook: list unread: %v\n", err)
		return nil
	}
	if len(entries) == 0 {
		return nil
	}

	var ctxText strings.Builder
	fmt.Fprintf(&ctxText, "📨 Partner reply 已到 (%d 条 comment(s))。\n\n", len(entries))
	ctxText.WriteString("下一步:\n")
	ctxText.WriteString("1. 阅读下面每条 reply,理解 partner 的回答;\n")
	ctxText.WriteString("2. 如果之前在等这个 reply 才能继续,接着按之前的计划做;\n")
	ctxText.WriteString("3. 如需追问,继续用 comment_handoff。\n\n")
	for _, e := range entries {
		fmt.Fprintf(&ctxText, "--- handoff %s · comment #%d · from %s ---\n%s\n\n",
			e.HandoffID, e.Comment.ID, e.Comment.Sender, e.Comment.Body)
	}

	// Claude Code Stop accepts only the standard top-level decision/reason
	// continuation shape. Put the full instruction in reason; Stop does not
	// support hookSpecificOutput.additionalContext. Preserve unread markers if
	// stdout itself fails so a later Stop can retry them.
	if err := writeStopHookDecision(os.Stdout, ctxText.String()); err != nil {
		fmt.Fprintf(os.Stderr, "stop-hook: encode JSON: %v\n", err)
		return nil
	}
	inbox.ClearUnread(entries)
	return nil
}
