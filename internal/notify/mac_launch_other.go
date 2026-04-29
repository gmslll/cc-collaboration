//go:build !darwin

package notify

import (
	"context"
	"errors"
)

type LaunchOpts struct {
	App        string
	CWD        string
	PromptFile string
	Dry        bool
}

// LaunchTerminal is unsupported off macOS. cc-handoff watch may still run on
// Linux for relay testing; auto-launch is gated by triggers.auto_launch=false.
func LaunchTerminal(_ context.Context, _ LaunchOpts) error {
	return errors.New("LaunchTerminal: not supported on this platform")
}
