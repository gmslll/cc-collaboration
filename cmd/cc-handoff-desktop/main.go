// cc-handoff-desktop is the native Fyne desktop client for cc-handoff. It
// talks to the same relay as `cc-handoff` and the embedded Web UI; subsequent
// phases will add system tray + SSE so it can replace `cc-handoff watch`
// for users who prefer a single GUI process over the CLI + browser pair.
package main

import (
	"log"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/desktop"
	"github.com/cc-collaboration/internal/transport"
)

func main() {
	user, path, err := config.LoadUser()
	if err != nil {
		log.Fatalf("load user config: %v", err)
	}
	if user == nil {
		log.Fatalf("user config missing at %s; run `cc-handoff init` first", path)
	}
	if user.RelayURL == "" || user.Token == "" || user.Identity == "" {
		log.Fatalf("incomplete user config at %s; relay_url/token/identity must all be set", path)
	}

	client := transport.New(user.RelayURL, user.Token)
	a := desktop.NewApp(client, user.Identity)
	if err := a.Run(); err != nil {
		log.Printf("desktop app exited: %v", err)
		os.Exit(1)
	}
}
