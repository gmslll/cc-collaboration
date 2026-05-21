// Package desktop hosts helpers for the `cc-handoff desktop` subcommand.
// Right now it only provides Chromium detection — Lorca's built-in
// LocateChrome() only looks for Google Chrome, so users with just Edge
// (the default on Windows 10/11) or Brave / Chromium would otherwise see
// a silent failure.
package desktop

import (
	"os"
	"path/filepath"
	"runtime"
)

// FindChromium returns the path to a Chromium-based browser usable as the
// Lorca host, or "" if none is installed. The probe order is Chrome → Edge
// → Brave → Chromium so that users get the most familiar window chrome when
// they have a choice. Lorca's LocateChrome honors the LOCATE_CHROME env var;
// callers should setenv this return value before calling lorca.New.
func FindChromium() string {
	for _, p := range candidatePaths() {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p
		}
	}
	return ""
}

func candidatePaths() []string {
	switch runtime.GOOS {
	case "darwin":
		return []string{
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
			"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
			"/Applications/Chromium.app/Contents/MacOS/Chromium",
			"/Applications/Arc.app/Contents/MacOS/Arc",
		}
	case "windows":
		var paths []string
		programFiles := []string{
			os.Getenv("ProgramFiles"),
			os.Getenv("ProgramFiles(x86)"),
			os.Getenv("LocalAppData"),
		}
		for _, base := range programFiles {
			if base == "" {
				continue
			}
			paths = append(paths,
				filepath.Join(base, "Google", "Chrome", "Application", "chrome.exe"),
				filepath.Join(base, "Microsoft", "Edge", "Application", "msedge.exe"),
				filepath.Join(base, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
				filepath.Join(base, "Chromium", "Application", "chrome.exe"),
			)
		}
		return paths
	default:
		// Linux / others — kept short; users on Linux mostly already have
		// the Web UI working in a regular browser and `cc-handoff desktop`
		// is a Mac+Windows convenience.
		return []string{
			"/usr/bin/google-chrome",
			"/usr/bin/google-chrome-stable",
			"/usr/bin/microsoft-edge",
			"/usr/bin/microsoft-edge-stable",
			"/usr/bin/brave-browser",
			"/usr/bin/chromium",
			"/usr/bin/chromium-browser",
		}
	}
}
