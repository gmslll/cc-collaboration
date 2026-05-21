package desktop

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/theme"
)

// installTray wires the OS system tray menu and rewires window-close so the
// process keeps running in the background — the only way SSE-driven
// notifications make sense as a replacement for `cc-handoff watch`. On
// platforms without a tray (very minimal Linux WMs) the assertion fails and
// close-to-quit stays as the default.
func (a *App) installTray() {
	desk, ok := a.fyneApp.(desktop.App)
	if !ok {
		return
	}
	menu := fyne.NewMenu("cc-handoff",
		fyne.NewMenuItem("Show", func() {
			a.window.Show()
			a.window.RequestFocus()
		}),
		fyne.NewMenuItemSeparator(),
		fyne.NewMenuItem("Refresh", a.refreshAllAsync),
		fyne.NewMenuItemSeparator(),
		fyne.NewMenuItem("Quit", a.fyneApp.Quit),
	)
	desk.SetSystemTrayMenu(menu)
	desk.SetSystemTrayIcon(theme.MailComposeIcon())
	a.window.SetCloseIntercept(func() { a.window.Hide() })
}
