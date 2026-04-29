// Package notify wraps platform-specific desktop notifications.
// On macOS it shells out to `osascript`; on other platforms Notify is a no-op.
package notify

// Notification is the minimal cross-platform payload.
type Notification struct {
	Title    string
	Subtitle string
	Body     string
}
