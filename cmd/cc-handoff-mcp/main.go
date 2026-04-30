package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/cc-collaboration/internal/mcp"
	"github.com/cc-collaboration/internal/version"
)

func main() {
	// MCP requires stdout for protocol; redirect logs to stderr.
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.Printf("cc-handoff-mcp starting: %s", version.Full())

	exe, startMtime := resolveExecutableMtime()
	if exe == "" {
		log.Print("warning: could not resolve own executable path; staleness detection disabled")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tools := withStalenessCheck(mcp.DefaultTools(), exe, startMtime)

	srv := &mcp.Server{
		Info:  mcp.ServerInfo{Name: "cc-handoff", Version: version.Version},
		Tools: tools,
	}
	if err := srv.Run(ctx, os.Stdin, os.Stdout); err != nil {
		log.Fatalf("mcp: %v", err)
	}
}

// withStalenessCheck wraps each tool's handler so that, when the binary on
// disk has been replaced after this process started, every tool result gets
// a leading warning. Catches the common case where the user upgrades
// cc-handoff-mcp but forgets that an already-running Claude session is still
// on the old code — silently sending stale schemas.
func withStalenessCheck(tools []mcp.Tool, exe string, startMtime time.Time) []mcp.Tool {
	if exe == "" || startMtime.IsZero() {
		return tools
	}
	for i := range tools {
		original := tools[i].Handler
		tools[i].Handler = func(ctx context.Context, args json.RawMessage) (mcp.ToolResult, error) {
			res, err := original(ctx, args)
			if w := stalenessWarning(exe, startMtime); w != "" {
				res.Content = append([]mcp.ContentBlock{{Type: "text", Text: w}}, res.Content...)
			}
			return res, err
		}
	}
	return tools
}

// resolveExecutableMtime returns the running binary's path and its mtime,
// captured once at startup. The path is fixed for a process lifetime so we
// only need os.Executable() this one time; subsequent staleness checks just
// re-stat the cached path.
func resolveExecutableMtime() (string, time.Time) {
	exe, err := os.Executable()
	if err != nil {
		return "", time.Time{}
	}
	fi, err := os.Stat(exe)
	if err != nil {
		return exe, time.Time{}
	}
	return exe, fi.ModTime()
}

func stalenessWarning(exe string, startMtime time.Time) string {
	fi, err := os.Stat(exe)
	if err != nil || !fi.ModTime().After(startMtime) {
		return ""
	}
	return fmt.Sprintf(
		"⚠️ cc-handoff-mcp binary on disk has been replaced (rebuilt %s) after this process started. The tool result above was produced by the OLD code. Run `/mcp` → Reconnect to pick up the new build (current running version: %s).\n\n",
		fi.ModTime().Format(time.RFC3339), version.Full(),
	)
}
