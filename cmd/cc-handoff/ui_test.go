package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

func TestRelayUIURL(t *testing.T) {
	for _, tc := range []struct {
		base string
		want string
	}{
		{base: "https://handoff.example.com", want: "https://handoff.example.com/ui/"},
		{base: "https://handoff.example.com/", want: "https://handoff.example.com/ui/"},
	} {
		if got := relayUIURL(tc.base); got != tc.want {
			t.Fatalf("relayUIURL(%q)=%q, want %q", tc.base, got, tc.want)
		}
	}
}

func TestRunUIPrintsURLWithoutTokenByDefault(t *testing.T) {
	isolateUserConfig(t)
	if _, err := config.SaveUser(&config.User{
		RelayURL: "https://handoff.example.com/",
		Token:    "secret-token",
		Identity: "alex@frontend",
	}); err != nil {
		t.Fatal(err)
	}

	stdout := captureStdout(t, func() {
		if err := runUI(context.Background(), nil); err != nil {
			t.Fatalf("runUI: %v", err)
		}
	})

	if !strings.Contains(stdout, "Relay UI: https://handoff.example.com/ui/") {
		t.Fatalf("stdout missing UI URL:\n%s", stdout)
	}
	if !strings.Contains(stdout, "Identity: alex@frontend") {
		t.Fatalf("stdout missing identity:\n%s", stdout)
	}
	if strings.Contains(stdout, "secret-token") {
		t.Fatalf("stdout leaked token by default:\n%s", stdout)
	}
}

func TestRunUIOpenUsesBrowserHook(t *testing.T) {
	isolateUserConfig(t)
	if _, err := config.SaveUser(&config.User{
		RelayURL: "https://handoff.example.com",
		Token:    "secret-token",
		Identity: "alex@frontend",
	}); err != nil {
		t.Fatal(err)
	}

	prev := openBrowser
	t.Cleanup(func() { openBrowser = prev })
	var opened string
	openBrowser = func(ctx context.Context, url string) error {
		opened = url
		return nil
	}

	_ = captureStdout(t, func() {
		if err := runUI(context.Background(), []string{"--open"}); err != nil {
			t.Fatalf("runUI --open: %v", err)
		}
	})
	if opened != "https://handoff.example.com/ui/" {
		t.Fatalf("opened=%q, want relay UI URL", opened)
	}
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	orig := os.Stdout
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = write
	defer func() {
		os.Stdout = orig
		_ = read.Close()
		_ = write.Close()
	}()

	fn()
	if err := write.Close(); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(read); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}

func TestRunUIMissingUserConfig(t *testing.T) {
	isolateUserConfig(t)
	err := runUI(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "user config missing") {
		t.Fatalf("runUI missing config err=%v, want user config missing", err)
	}
}

func isolateUserConfig(t *testing.T) {
	t.Helper()
	home := filepath.Join(t.TempDir(), "home")
	if runtime.GOOS == "windows" {
		t.Setenv("APPDATA", filepath.Join(home, "AppData", "Roaming"))
	} else {
		t.Setenv("HOME", home)
	}
}
