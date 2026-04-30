// Package version exposes the cc-handoff build version. Version is set at
// build time via -ldflags "-X github.com/cc-collaboration/internal/version.Version=$(cat VERSION)".
// Both cmd/cc-handoff and cmd/cc-handoff-mcp import it so they report the
// same string. Falls back to the in-tree default ("dev") for `go run`.
package version

import (
	"fmt"
	"runtime/debug"
)

// Version is the semantic version stamped at link time. "dev" means the
// binary was built without ldflags (e.g. plain `go build` or `go run`).
var Version = "dev"

// Full returns "<version> (<short-sha>[-dirty]) built <time>" — what the CLI
// `version` subcommand prints and what the MCP server logs at startup. The
// VCS bits come from runtime/debug.ReadBuildInfo, which is always available
// for binaries built from a git checkout.
func Full() string {
	revision, modified, buildTime := vcsInfo()
	if revision == "" {
		return fmt.Sprintf("cc-handoff %s", Version)
	}
	short := revision
	if len(short) > 12 {
		short = short[:12]
	}
	dirty := ""
	if modified {
		dirty = "-dirty"
	}
	if buildTime == "" {
		return fmt.Sprintf("cc-handoff %s (%s%s)", Version, short, dirty)
	}
	return fmt.Sprintf("cc-handoff %s (%s%s) built %s", Version, short, dirty, buildTime)
}

func vcsInfo() (revision string, modified bool, buildTime string) {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return
	}
	for _, s := range info.Settings {
		switch s.Key {
		case "vcs.revision":
			revision = s.Value
		case "vcs.modified":
			modified = s.Value == "true"
		case "vcs.time":
			buildTime = s.Value
		}
	}
	return
}
