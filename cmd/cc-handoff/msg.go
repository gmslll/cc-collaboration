package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The `msg` subcommands are the agent-facing half of the desktop app's local
// session message bus. They never touch the relay: they read sessions.json and
// drop messages into outbox/ under $CC_BUS_DIR for the running app to deliver
// into a sibling terminal session. The app injects CC_BUS_DIR / CC_SESSION_ID /
// CC_SESSION_NAME into every session it spawns.

// busSession mirrors one entry of the app's sessions.json registry.
type busSession struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Name    string `json:"name,omitempty"`
	Workdir string `json:"workdir"`
	PID     int    `json:"pid,omitempty"`
}

func runMsg(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: cc-handoff msg <list|send|whoami>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "list":
		return runMsgList(rest)
	case "send":
		return runMsgSend(ctx, rest)
	case "whoami":
		return runMsgWhoami()
	default:
		return fmt.Errorf("unknown msg subcommand %q (want list|send|whoami)", sub)
	}
}

// busDir returns the local-bus directory the app injected, or a friendly error
// when run from a terminal the app didn't spawn.
func busDir() (string, error) {
	d := os.Getenv("CC_BUS_DIR")
	if d == "" {
		return "", errors.New("当前终端不在 App 会话总线内(缺少 CC_BUS_DIR);请在桌面 App 唤起的终端里运行")
	}
	return d, nil
}

func loadSessions(dir string) ([]busSession, error) {
	b, err := os.ReadFile(filepath.Join(dir, "sessions.json"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var ss []busSession
	if err := json.Unmarshal(b, &ss); err != nil {
		return nil, fmt.Errorf("会话注册表损坏: %w", err)
	}
	return ss, nil
}

func runMsgList(args []string) error {
	fs := flag.NewFlagSet("msg list", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON instead of a table")
	if err := fs.Parse(args); err != nil {
		return err
	}
	dir, err := busDir()
	if err != nil {
		return err
	}
	ss, err := loadSessions(dir)
	if err != nil {
		return err
	}
	self := os.Getenv("CC_SESSION_ID")
	peers := make([]busSession, 0, len(ss))
	for _, s := range ss {
		if s.ID != self {
			peers = append(peers, s)
		}
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(peers)
	}
	if len(peers) == 0 {
		fmt.Println("没有其它会话。")
		return nil
	}
	fmt.Printf("%-6s  %-20s  %s\n", "ID", "NAME", "DIR")
	for _, s := range peers {
		fmt.Printf("%-6s  %-20s  %s\n", s.ID, s.Label, s.Workdir)
	}
	return nil
}

func runMsgWhoami() error {
	if _, err := busDir(); err != nil {
		return err
	}
	fmt.Printf("%s\t%s\n", os.Getenv("CC_SESSION_ID"), os.Getenv("CC_SESSION_NAME"))
	return nil
}

func runMsgSend(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("msg send", flag.ContinueOnError)
	noSubmit := fs.Bool("no-submit", false, "只填入对方输入框,不自动回车")
	timeout := fs.Duration("timeout", 5*time.Second, "等待投递结果的超时")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) < 2 {
		return errors.New("usage: cc-handoff msg send <target> <text...> [--no-submit]")
	}
	target := rest[0]
	body := strings.Join(rest[1:], " ")

	dir, err := busDir()
	if err != nil {
		return err
	}
	outbox := filepath.Join(dir, "outbox")
	if err := os.MkdirAll(outbox, 0o700); err != nil {
		return err
	}
	id, err := randID()
	if err != nil {
		return err
	}
	payload, err := json.Marshal(map[string]any{
		"from":   os.Getenv("CC_SESSION_ID"),
		"to":     target,
		"body":   body,
		"submit": !*noSubmit,
	})
	if err != nil {
		return err
	}

	// Atomic publish: write a temp file then rename into outbox so the app's
	// watcher never reads a half-written message.
	jsonPath := filepath.Join(outbox, id+".json")
	tmpPath := filepath.Join(outbox, "."+id+".tmp")
	if err := os.WriteFile(tmpPath, payload, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, jsonPath); err != nil {
		os.Remove(tmpPath)
		return err
	}

	// Wait for the app's explicit receipt: it claims the message (rename to
	// .taken) then writes <id>.ok on success or <id>.err on failure. We poll for
	// either marker — keyed on the marker, not on the .json vanishing, since the
	// claim removes .json well before delivery finishes. No marker before the
	// deadline → nobody is listening.
	okPath := filepath.Join(outbox, id+".ok")
	errPath := filepath.Join(outbox, id+".err")
	deadline := time.Now().Add(*timeout)
	for {
		if eb, e := os.ReadFile(errPath); e == nil {
			os.Remove(errPath)
			return errors.New(strings.TrimSpace(string(eb)))
		}
		if _, e := os.Stat(okPath); e == nil {
			os.Remove(okPath)
			fmt.Printf("已发送到 %s\n", target)
			return nil
		}
		if time.Now().After(deadline) {
			os.Remove(jsonPath) // unconsumed; clean up our drop
			return errors.New("无人接收(桌面 App 未在监听本地会话总线)")
		}
		select {
		case <-ctx.Done():
			os.Remove(jsonPath)
			return ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func randID() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return fmt.Sprintf("%d-%s", os.Getpid(), hex.EncodeToString(b)), nil
}
