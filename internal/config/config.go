package config

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"

	"github.com/BurntSushi/toml"
	"github.com/cc-collaboration/internal/agent"
)

// User-level config: shared across repos on this machine.
// Lives at ~/.config/cc-handoff/config.toml.
type User struct {
	RelayURL string `toml:"relay_url"`
	Token    string `toml:"token"`
	Identity string `toml:"identity"`
	// Agent picks the AI agent adapter cc-handoff drives: "claude" |
	// "codex" | "manual". Empty falls back to "claude" for backwards
	// compatibility with installs predating multi-agent support.
	Agent string `toml:"agent,omitempty"`
}

// Repo-level config: lives at <repo-root>/.cc-handoff.toml.
type Repo struct {
	Identity       Identity       `toml:"identity"`
	Paths          Paths          `toml:"paths"`
	PartnerMapping PartnerMapping `toml:"partner_mapping"`
	Triggers       Triggers       `toml:"triggers"`
	Inbox          Inbox          `toml:"inbox,omitempty"`
}

// Inbox controls where Materialize writes handoff packages. Empty Dir means
// "auto": .cc-handoff/inbox by default, falling back to legacy
// .claude/handoff-inbox when that already exists in the repo.
type Inbox struct {
	Dir string `toml:"dir,omitempty"`
}

type Identity struct {
	Me      string `toml:"me,omitempty"` // optional override of user-level identity
	Partner string `toml:"partner"`      // default recipient
}

type Paths struct {
	Swagger string `toml:"swagger,omitempty"` // optional, e.g. "docs/swagger.yaml"
	Base    string `toml:"base,omitempty"`    // git base ref; defaults to "origin/main"
	Repo    string `toml:"repo,omitempty"`    // human-readable repo name; defaults to basename(cwd)
}

type PartnerMapping struct {
	Rules []Rule `toml:"rule,omitempty"`
}

type Rule struct {
	WhenPathMatches        string   `toml:"when_path_matches"`
	SuggestEdit            []string `toml:"suggest_edit,omitempty"`
	SuggestCreateIfMissing bool     `toml:"suggest_create_if_missing,omitempty"`
}

type Triggers struct {
	AutoLaunch       bool   `toml:"auto_launch"`
	AutoLaunchNormal bool   `toml:"auto_launch_normal,omitempty"`
	TerminalApp      string `toml:"terminal_app,omitempty"`
	WakeOnComment    bool   `toml:"wake_on_comment,omitempty"`
}

const (
	TerminalAppTerminal        = "terminal"
	TerminalAppITerm2          = "iterm2"
	TerminalAppWindowsTerminal = "windows-terminal"
	TerminalAppPowerShell      = "powershell"
)

// UserConfigPath returns the canonical user-level config path. On Windows it
// resolves to %AppData%\cc-handoff\config.toml; on macOS/Linux it stays at
// ~/.config/cc-handoff/config.toml for backwards compatibility with existing
// installs that predate Windows support.
func UserConfigPath() (string, error) {
	if runtime.GOOS == "windows" {
		dir, err := os.UserConfigDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(dir, "cc-handoff", "config.toml"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "cc-handoff", "config.toml"), nil
}

func LoadUser() (*User, string, error) {
	p, err := UserConfigPath()
	if err != nil {
		return nil, "", err
	}
	var u User
	if _, err := toml.DecodeFile(p, &u); err != nil {
		if os.IsNotExist(err) {
			return nil, p, nil
		}
		return nil, p, fmt.Errorf("read %s: %w", p, err)
	}
	return &u, p, nil
}

func SaveUser(u *User) (string, error) {
	p, err := UserConfigPath()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return "", err
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return "", err
	}
	defer f.Close()
	enc := toml.NewEncoder(f)
	if err := enc.Encode(u); err != nil {
		return "", err
	}
	return p, nil
}

// RepoConfigPath returns the path to .cc-handoff.toml at the repo root,
// searching upward from cwd until a .git directory is found, falling back to cwd.
func RepoConfigPath(cwd string) string {
	dir := cwd
	for {
		if fi, err := os.Stat(filepath.Join(dir, ".git")); err == nil && fi.IsDir() {
			return filepath.Join(dir, ".cc-handoff.toml")
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return filepath.Join(cwd, ".cc-handoff.toml")
		}
		dir = parent
	}
}

// RepoRoot returns the directory containing the .cc-handoff.toml (or cwd if not in a repo).
func RepoRoot(cwd string) string {
	return filepath.Dir(RepoConfigPath(cwd))
}

func LoadRepo(cwd string) (*Repo, string, error) {
	p := RepoConfigPath(cwd)
	var r Repo
	if _, err := toml.DecodeFile(p, &r); err != nil {
		if os.IsNotExist(err) {
			return nil, p, nil
		}
		return nil, p, fmt.Errorf("read %s: %w", p, err)
	}
	return &r, p, nil
}

func SaveRepo(path string, r *Repo) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	return toml.NewEncoder(f).Encode(r)
}

// Resolved is the merged view used by submit/list/pickup/watch.
type Resolved struct {
	RelayURL string
	Token    string
	Me       string
	Partner  string
	RepoName string
	Base     string
	Swagger  string
	Triggers Triggers
	Rules    []Rule
	Agent    agent.Agent
	// InboxOverride is the raw user-supplied [inbox] dir from
	// .cc-handoff.toml; "" means auto-detect. Callers resolve to an absolute
	// path once via inbox.InboxDir(repoRoot, override) and reuse that for
	// the lifetime of the command — config.Resolved can't hold the resolved
	// path itself without an import cycle (rules → config → inbox →
	// handoff → rules).
	InboxOverride string
}

func Resolve(cwd string) (*Resolved, error) {
	u, _, err := LoadUser()
	if err != nil {
		return nil, err
	}
	if u == nil {
		return nil, fmt.Errorf("user config missing; run `cc-handoff init`")
	}
	r, _, err := LoadRepo(cwd)
	if err != nil {
		return nil, err
	}
	if r == nil {
		return nil, fmt.Errorf("repo config missing at %s; run `cc-handoff init`", RepoConfigPath(cwd))
	}
	me := r.Identity.Me
	if me == "" {
		me = u.Identity
	}
	repoName := r.Paths.Repo
	if repoName == "" {
		repoName = filepath.Base(RepoRoot(cwd))
	}
	base := r.Paths.Base
	if base == "" {
		base = "origin/main"
	}
	ag, err := agent.Resolve(u.Agent)
	if err != nil {
		return nil, fmt.Errorf("user config: %w", err)
	}
	out := &Resolved{
		RelayURL:      u.RelayURL,
		Token:         u.Token,
		Me:            me,
		Partner:       r.Identity.Partner,
		RepoName:      repoName,
		Base:          base,
		Swagger:       r.Paths.Swagger,
		Triggers:      r.Triggers,
		Rules:         r.PartnerMapping.Rules,
		Agent:         ag,
		InboxOverride: r.Inbox.Dir,
	}
	if out.RelayURL == "" || out.Token == "" || out.Me == "" {
		return nil, fmt.Errorf("incomplete config: relay_url/token/identity must be set in user config")
	}
	if out.Partner == "" {
		return nil, fmt.Errorf("incomplete repo config: identity.partner must be set in %s", RepoConfigPath(cwd))
	}
	return out, nil
}
