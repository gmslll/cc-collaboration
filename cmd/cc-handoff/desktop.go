package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"

	"github.com/zserge/lorca"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/desktop"
)

// data-mode value the Web UI's CSS checks via `:root[data-mode="desktop"]`
// to hide the auth panel; the token is already in localStorage by then.
const desktopDataMode = "desktop"

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

	// Bind the local pickup helper before Load so app.js sees it on the
	// first render. JS calls `await window.ccHandoffPickup(id)`; we shell
	// out to the same binary so behavior matches `cc-handoff pickup` 1:1.
	if err := ui.Bind("ccHandoffPickup", pickupHandler(ctx)); err != nil {
		return fmt.Errorf("bind ccHandoffPickup: %w", err)
	}

	// Pre-inject the token into localStorage so app.js (which reads
	// `localStorage.getItem("cc-handoff-token")` on load) skips the auth
	// panel. data-mode has to wait until after Load because the new
	// document doesn't inherit dataset from about:blank.
	if err := ui.Eval(fmt.Sprintf(`localStorage.setItem(%q, %q);`, "cc-handoff-token", user.Token)).Err(); err != nil {
		return fmt.Errorf("inject token: %w", err)
	}
	if err := ui.Load(relayUIURL(user.RelayURL)); err != nil {
		return fmt.Errorf("navigate: %w", err)
	}
	_ = ui.Eval(fmt.Sprintf(`document.documentElement.dataset.mode = %q;`, desktopDataMode)).Err()

	select {
	case <-ui.Done():
	case <-ctx.Done():
	}
	return nil
}

// pickupHandler shells out to `cc-handoff pickup <id>` so the JS-driven
// pickup behaves identically to the user running it in their terminal —
// terminal-launch, materialize, repo-config validation all inherited.
func pickupHandler(ctx context.Context) func(id string) (string, error) {
	return func(id string) (string, error) {
		if id == "" {
			return "", fmt.Errorf("handoff id required")
		}
		self, err := os.Executable()
		if err != nil {
			self = os.Args[0]
		}
		var stdout, stderr bytes.Buffer
		cmd := exec.CommandContext(ctx, self, "pickup", id)
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		runErr := cmd.Run()
		out := stdout.String() + stderr.String()
		if runErr != nil {
			if out == "" {
				out = runErr.Error()
			}
			return "", fmt.Errorf("%s", out)
		}
		if out == "" {
			out = "pickup ok"
		}
		return out, nil
	}
}
