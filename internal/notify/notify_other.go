//go:build !darwin

package notify

import "context"

// Show is a no-op on non-darwin platforms. Watch is currently macOS-only;
// this stub keeps the relay binary portable to Linux for VPS builds.
func Show(_ context.Context, _ Notification) error { return nil }
