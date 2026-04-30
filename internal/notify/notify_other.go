//go:build !darwin && !windows

package notify

import "context"

// Show is a no-op on Linux and other non-desktop platforms. Watch supports
// macOS (osascript) and Windows (toast notifications); this stub keeps the
// relay binary portable to Linux for VPS builds where notifications are
// neither available nor wanted.
func Show(_ context.Context, _ Notification) error { return nil }
