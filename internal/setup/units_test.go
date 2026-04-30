package setup

import (
	"bytes"
	"strings"
	"testing"
)

func TestRenderUnit_Launchd(t *testing.T) {
	var buf bytes.Buffer
	err := RenderUnit(PlatformLaunchd, UnitParams{
		BinPath: "/usr/local/bin/cc-handoff",
		WorkDir: "/Users/me/repo",
	}, &buf)
	if err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	for _, want := range []string{
		"<plist version=\"1.0\">",
		"/usr/local/bin/cc-handoff",
		"/Users/me/repo",
		"com.cc-handoff.watch",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

func TestRenderUnit_Systemd(t *testing.T) {
	var buf bytes.Buffer
	err := RenderUnit(PlatformSystemd, UnitParams{
		BinPath: "/usr/local/bin/cc-handoff",
		WorkDir: "/home/me/repo",
	}, &buf)
	if err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	for _, want := range []string{
		"[Service]",
		"WorkingDirectory=/home/me/repo",
		"ExecStart=/usr/local/bin/cc-handoff watch",
		"WantedBy=default.target",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

func TestRenderUnit_WindowsTask(t *testing.T) {
	var buf bytes.Buffer
	err := RenderUnit(PlatformWindowsTask, UnitParams{
		BinPath: `C:\Users\me\AppData\Local\Programs\cc-handoff\cc-handoff.exe`,
		WorkDir: `C:\Users\me\repo`,
	}, &buf)
	if err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	for _, want := range []string{
		`<?xml version="1.0" encoding="UTF-8"?>`,
		`<LogonTrigger>`,
		`<Command>C:\Users\me\AppData\Local\Programs\cc-handoff\cc-handoff.exe</Command>`,
		`<Arguments>watch</Arguments>`,
		`<WorkingDirectory>C:\Users\me\repo</WorkingDirectory>`,
		`<RestartOnFailure>`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

func TestRenderUnit_RequiresParams(t *testing.T) {
	if err := RenderUnit(PlatformLaunchd, UnitParams{WorkDir: "/x"}, &bytes.Buffer{}); err == nil {
		t.Error("expected error when BinPath is empty")
	}
	if err := RenderUnit(PlatformLaunchd, UnitParams{BinPath: "/x"}, &bytes.Buffer{}); err == nil {
		t.Error("expected error when WorkDir is empty")
	}
}

func TestRenderUnit_UnknownPlatform(t *testing.T) {
	err := RenderUnit("upstart", UnitParams{BinPath: "/x", WorkDir: "/y"}, &bytes.Buffer{})
	if err == nil {
		t.Error("expected error for unknown platform")
	}
}
