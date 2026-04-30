//go:build !darwin && !windows

package notify

import (
	"context"
	"errors"
)

// LaunchTerminal is unsupported on Linux and other non-desktop platforms.
// cc-handoff watch may still run on Linux for relay testing; auto-launch is
// gated by triggers.auto_launch=false. macOS and Windows have their own
// implementations in mac_launch.go and mac_launch_windows.go.
func LaunchTerminal(_ context.Context, _ LaunchOpts) error {
	return errors.New("LaunchTerminal: not supported on this platform")
}
