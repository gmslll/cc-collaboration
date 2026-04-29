package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/cc-collaboration/internal/mcp"
)

func main() {
	// MCP requires stdout for protocol; redirect logs to stderr.
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := &mcp.Server{
		Info:  mcp.ServerInfo{Name: "cc-handoff", Version: "0.1.0"},
		Tools: mcp.DefaultTools(),
	}
	if err := srv.Run(ctx, os.Stdin, os.Stdout); err != nil {
		log.Fatalf("mcp: %v", err)
	}
}
