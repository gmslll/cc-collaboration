package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/zserge/lorca"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/desktop"
)

func runDesktop(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("desktop", flag.ContinueOnError)
	width := fs.Int("width", 1280, "initial window width in pixels")
	height := fs.Int("height", 820, "initial window height in pixels")
	chromePath := fs.String("chrome", "", "path to a Chromium-based browser; auto-detected if empty")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("usage: cc-handoff desktop [--width N] [--height N] [--chrome PATH]")
	}

	user, path, err := config.LoadUser()
	if err != nil {
		return err
	}
	if user == nil {
		return fmt.Errorf("user config missing at %s; run `cc-handoff init`", path)
	}
	if user.RelayURL == "" || user.Token == "" {
		return fmt.Errorf("incomplete config in %s; relay_url and token must be set", path)
	}

	// Lorca's LocateChrome only knows Google Chrome's canonical paths; we
	// probe Edge / Brave / Chromium as well so the Windows-with-only-Edge
	// (Win10/11 default) case works out of the box.
	browser := *chromePath
	if browser == "" {
		browser = desktop.FindChromium()
	}
	if browser == "" {
		return fmt.Errorf("no Chromium-based browser found.\n" +
			"Install Google Chrome, Microsoft Edge, or Brave, or pass --chrome PATH.\n" +
			"Workaround: `cc-handoff ui --open` opens the same UI in your default browser.")
	}
	_ = os.Setenv("LOCATE_CHROME", browser)

	// --remote-allow-origins is required by Chrome M111+ for the remote
	// debugging WebSocket; without it the handshake returns 403 and Lorca
	// (unmaintained since 2021) reports "bad status".
	ui, err := lorca.New("", "", *width, *height, "--remote-allow-origins=*")
	if err != nil {
		return fmt.Errorf("start chromium window: %w", err)
	}
	defer ui.Close()

	// Bind must happen before Load — Lorca registers bindings on the next
	// document via Page.addScriptToEvaluateOnNewDocument.
	if err := ui.Bind("ccHandoffPickup", pickupHandler(ctx)); err != nil {
		return fmt.Errorf("bind ccHandoffPickup: %w", err)
	}

	// Best-effort discovery of the receiver repo this window represents.
	// app.js forwards it as the second arg to ccHandoffPickup so the
	// shelled-out `cc-handoff pickup` uses --repo and isn't pinned to the
	// child's inherited cwd. Empty when the launch dir isn't a configured
	// repo — pickup then falls back to its own cwd-based behavior.
	defaultRepo := ""
	if cwd, err := os.Getwd(); err == nil {
		if cfgPath := config.RepoConfigPath(cwd); cfgPath != "" {
			if _, statErr := os.Stat(cfgPath); statErr == nil {
				defaultRepo = filepath.Dir(cfgPath)
			}
		}
	}

	// Two-load dance: Lorca opens on a data: URL where localStorage is
	// disabled. First Load gets us onto the relay origin; Eval injects token
	// + default-repo into localStorage; second Load re-runs app.js which now
	// reads them. dataset.mode isn't persisted — app.js detects desktop mode
	// by the presence of window.ccHandoffPickup (Bind survives every reload).
	target := relayUIURL(user.RelayURL)
	if err := ui.Load(target); err != nil {
		return fmt.Errorf("navigate: %w", err)
	}
	bootstrap := fmt.Sprintf(
		`localStorage.setItem(%q,%q);localStorage.setItem(%q,%q);`,
		"cc-handoff-token", user.Token,
		"cc-handoff-default-repo", defaultRepo,
	)
	if err := ui.Eval(bootstrap).Err(); err != nil {
		return fmt.Errorf("inject bootstrap: %w", err)
	}
	if err := ui.Load(target); err != nil {
		return fmt.Errorf("reload: %w", err)
	}

	select {
	case <-ui.Done():
	case <-ctx.Done():
	}
	return nil
}

// pickupHandler shells out to `cc-handoff pickup <id>` so the JS-driven
// pickup behaves identically to the user running it in their terminal —
// terminal-launch, materialize, repo-config validation all inherited. JS
// passes repoPath so the multi-repo workflow (one identity, several receiver
// repos) reaches the subcommand's --repo flag instead of being pinned to
// whichever cwd `cc-handoff desktop` was launched from.
func pickupHandler(ctx context.Context) func(id, repoPath string) (string, error) {
	return func(id, repoPath string) (string, error) {
		if id == "" {
			return "", fmt.Errorf("handoff id required")
		}
		self, err := os.Executable()
		if err != nil {
			self = os.Args[0]
		}
		args := []string{"pickup", id}
		if repoPath != "" {
			args = append(args, "--repo", repoPath)
		}
		// Detach from the parent's signal-cancelled ctx: when the user
		// closes the window or hits Ctrl-C cc-handoff, we don't want a
		// half-finished pickup leaving an inconsistent inbox dir on disk.
		// We still pass a fresh ctx so a future caller could time it out.
		runCtx := context.WithoutCancel(ctx)
		var stdout, stderr bytes.Buffer
		cmd := exec.CommandContext(runCtx, self, args...)
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		runErr := cmd.Run()
		out := strings.TrimSpace(stdout.String() + stderr.String())
		if runErr != nil {
			if out == "" {
				return "", runErr
			}
			return "", fmt.Errorf("%s: %w", out, runErr)
		}
		if out == "" {
			out = "pickup ok"
		}
		return out, nil
	}
}
