//go:build windows

package main

import "fmt"

// execInShell is unsupported on Windows: syscall.Exec has no process-image
// replacement semantics there. Use `--window` to open a new terminal, or copy
// the printed launch command and run it yourself.
func execInShell(command string) error {
	return fmt.Errorf("in-place launch is not supported on Windows; use --window or copy the command:\n  %s", command)
}
