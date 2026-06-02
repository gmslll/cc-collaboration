//go:build !darwin && !windows

package notify

import (
	"context"
	"errors"
)

// OpenTerminalCommand is unsupported on Linux/other: no GUI terminal automation
// is wired up. The workspace launcher's default in-place exec path covers the
// SSH/headless case these platforms are typically used in.
func OpenTerminalCommand(_ context.Context, _, _, _ string) error {
	return errors.New("OpenTerminalCommand: opening a terminal window is not supported on this platform; use the default in-place launch")
}
