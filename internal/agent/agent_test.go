package agent

import (
	"strings"
	"testing"
)

func TestResolve(t *testing.T) {
	cases := []struct {
		name string
		want string
		err  bool
	}{
		{"", "claude", false}, // backwards-compat: empty → claude
		{"claude", "claude", false},
		{"codex", "codex", false},
		{"manual", "manual", false},
		{"aider", "", true},
		{"random", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, err := Resolve(c.name)
			if c.err {
				if err == nil {
					t.Fatalf("Resolve(%q) wanted error, got %v", c.name, a)
				}
				return
			}
			if err != nil {
				t.Fatalf("Resolve(%q) unexpected error: %v", c.name, err)
			}
			if a.Name() != c.want {
				t.Fatalf("Resolve(%q).Name() = %q, want %q", c.name, a.Name(), c.want)
			}
		})
	}
}

func TestPOSIXSingleQuote(t *testing.T) {
	cases := map[string]string{
		"":           `''`,
		"plain":      `'plain'`,
		"with space": `'with space'`,
		"with'q":     `'with'\''q'`,
		"a'b'c":      `'a'\''b'\''c'`,
	}
	for in, want := range cases {
		if got := POSIXSingleQuote(in); got != want {
			t.Errorf("POSIXSingleQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPSSingleQuote(t *testing.T) {
	cases := map[string]string{
		"":                `''`,
		"plain":           `'plain'`,
		"with'q":          `'with''q'`,
		`C:\Users\me\dir`: `'C:\Users\me\dir'`,
	}
	for in, want := range cases {
		if got := PSSingleQuote(in); got != want {
			t.Errorf("PSSingleQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestClaudePOSIXPromptCmd(t *testing.T) {
	got := claudeAgent{}.POSIXPromptCmd("/tmp/repo with space", "/tmp/repo with space/.cc-handoff/inbox/h_x/prompt.md", "", false)
	want := `cd '/tmp/repo with space' && claude -p "$(cat '/tmp/repo with space/.cc-handoff/inbox/h_x/prompt.md')"`
	if got != want {
		t.Errorf("got  %q\nwant %q", got, want)
	}
}

func TestClaudePowerShellPromptCmd(t *testing.T) {
	got := claudeAgent{}.PowerShellPromptCmd(`C:\repo with space`, `C:\repo with space\.cc-handoff\inbox\h_x\prompt.md`, "", false)
	want := `Set-Location -LiteralPath 'C:\repo with space'; claude -p (Get-Content -Raw -LiteralPath 'C:\repo with space\.cc-handoff\inbox\h_x\prompt.md')`
	if got != want {
		t.Errorf("got  %q\nwant %q", got, want)
	}
}

func TestClaudePOSIXPromptCmdPreLaunchAndInteractive(t *testing.T) {
	got := claudeAgent{}.POSIXPromptCmd("/repo", "/repo/p.md", "clset 6", true)
	want := `cd '/repo' && clset 6 && claude`
	if got != want {
		t.Errorf("interactive+preLaunch: got %q, want %q", got, want)
	}
	got = claudeAgent{}.POSIXPromptCmd("/repo", "/repo/p.md", "clset 6", false)
	want = `cd '/repo' && clset 6 && claude -p "$(cat '/repo/p.md')"`
	if got != want {
		t.Errorf("oneshot+preLaunch: got %q, want %q", got, want)
	}
}

func TestCodexPOSIXPromptCmd(t *testing.T) {
	got := codexAgent{}.POSIXPromptCmd("/repo", "/repo/.cc-handoff/inbox/h_x/prompt.md", "", false)
	want := `cd '/repo' && codex exec "$(cat '/repo/.cc-handoff/inbox/h_x/prompt.md')"`
	if got != want {
		t.Errorf("got  %q\nwant %q", got, want)
	}
}

func TestCodexPowerShellPromptCmd(t *testing.T) {
	got := codexAgent{}.PowerShellPromptCmd(`C:\repo`, `C:\repo\.cc-handoff\inbox\h_x\prompt.md`, "", false)
	want := `Set-Location -LiteralPath 'C:\repo'; codex exec (Get-Content -Raw -LiteralPath 'C:\repo\.cc-handoff\inbox\h_x\prompt.md')`
	if got != want {
		t.Errorf("got  %q\nwant %q", got, want)
	}
}

func TestInstructionsFile(t *testing.T) {
	cases := []struct {
		agent     Agent
		wantFile  string
		hasMCPRef bool
	}{
		{claudeAgent{}, "CLAUDE.md", true},
		{codexAgent{}, "AGENTS.md", true},
		{manualAgent{}, "", false},
	}
	for _, c := range cases {
		t.Run(c.agent.Name(), func(t *testing.T) {
			f, snippet := c.agent.InstructionsFile()
			if f != c.wantFile {
				t.Errorf("filename = %q, want %q", f, c.wantFile)
			}
			if c.hasMCPRef && !strings.Contains(snippet, "submit_handoff") {
				t.Errorf("snippet missing tool reference: %s", snippet)
			}
			if !c.hasMCPRef && snippet != "" {
				t.Errorf("manual agent should have empty snippet, got: %s", snippet)
			}
		})
	}
}

func TestSupportsCommands(t *testing.T) {
	cases := []struct {
		agent Agent
		want  bool
	}{
		{claudeAgent{}, true},
		{codexAgent{}, true},
		{manualAgent{}, false},
	}
	for _, c := range cases {
		t.Run(c.agent.Name(), func(t *testing.T) {
			if got := c.agent.SupportsCommands(); got != c.want {
				t.Errorf("SupportsCommands = %v, want %v", got, c.want)
			}
		})
	}
}
