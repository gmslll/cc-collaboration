//go:build !windows

package main

import (
	"cmp"
	"fmt"
	"os"
	"syscall"
)

// execInShell replaces the current process with the user's interactive shell
// running command. This is the SSH-friendly launch path: the terminal you're
// already in cd's into the project and starts the agent — no new window, no
// copy-paste. It does not return on success (the process image is replaced).
//
// We use `$SHELL -i -c` rather than `/bin/sh -c` so that rc-defined shell
// functions in command's pre_launch (nvm use, clset, …) resolve, matching what
// Terminal.app's `do script` gives you. $SHELL empty falls back to /bin/sh.
//
// Tradeoff: `-i` is an interactive shell, so it pays the rc-sourcing cost and
// can print a job-control notice over SSH. That's accepted on purpose — without
// it the common pre_launch functions silently fail. If launch latency ever
// becomes a concern, this is the knob to revisit (a non-interactive mode would
// break those functions).
func execInShell(command string) error {
	sh := cmp.Or(os.Getenv("SHELL"), "/bin/sh")
	if err := syscall.Exec(sh, []string{sh, "-i", "-c", command}, os.Environ()); err != nil {
		return fmt.Errorf("exec %s: %w", sh, err)
	}
	return nil // unreachable on success
}
