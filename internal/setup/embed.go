// Package setup contains opt-in install steps that `cc-handoff init` and
// `cc-handoff watch print-unit` use to materialize files outside the user's
// repo (slash commands, launchd plist, systemd unit). The package never
// touches the filesystem on its own — all writes flow through commands.go,
// which prompts before overwriting.
package setup

import "embed"

//go:embed templates/commands/handoff.md templates/commands/handoff-module.md templates/commands/pickup.md templates/commands/request.md templates/commands/handoff-from-linear.md templates/commands/submit-bug.md
var commandsFS embed.FS

//go:embed templates/units/launchd.plist.tmpl templates/units/systemd-user.service.tmpl templates/units/windows-task.xml.tmpl
var unitsFS embed.FS

// CommandFiles enumerates the slash command files in copy order. The list is
// the source of truth for which files init copies and which file names land
// in the destination .claude/commands/ directory.
var CommandFiles = []string{
	"handoff.md",
	"handoff-module.md",
	"pickup.md",
	"request.md",
	"handoff-from-linear.md",
	"submit-bug.md",
}
