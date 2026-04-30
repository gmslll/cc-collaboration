//go:build windows

package notify

import (
	"context"
	"os/exec"
	"strings"
)

// winToastTemplate is the PowerShell snippet that posts a generic toast via
// the WinRT ToastNotificationManager. PowerShell 5.1 (preinstalled on
// Win10 1809+ and Win11) resolves the WinRT types via the
// [...,ContentType=WindowsRuntime] cast — no BurntToast module required.
const winToastTemplate = `[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime] | Out-Null;` +
	`$x = New-Object Windows.Data.Xml.Dom.XmlDocument;` +
	`$x.LoadXml('<toast><visual><binding template="ToastGeneric">` +
	`<text>%TITLE%</text><text>%SUB%</text><text>%BODY%</text>` +
	`</binding></visual></toast>');` +
	`$t = [Windows.UI.Notifications.ToastNotification]::new($x);` +
	`[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('cc-handoff').Show($t)`

// xmlEscaper handles the five XML predefined entities for user text embedded
// in the toast XML literal. Hoisted to package scope so Show doesn't allocate
// a fresh replacer on every notification (watch fires this per handoff and
// per comment).
var xmlEscaper = strings.NewReplacer(
	"&", "&amp;",
	"<", "&lt;",
	">", "&gt;",
	`"`, "&quot;",
	"'", "&apos;",
)

// Show posts a Windows toast notification by shelling out to powershell.exe.
// Returns an error only if powershell itself fails to launch / exits non-zero;
// when banners are suppressed by Focus Assist the call still succeeds.
func Show(ctx context.Context, n Notification) error {
	script := strings.NewReplacer(
		"%TITLE%", xmlEscape(n.Title),
		"%SUB%", xmlEscape(n.Subtitle),
		"%BODY%", xmlEscape(n.Body),
	).Replace(winToastTemplate)
	return exec.CommandContext(ctx, "powershell.exe",
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-Command", script).Run()
}

func xmlEscape(s string) string { return xmlEscaper.Replace(s) }
