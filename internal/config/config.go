package config

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"

	"github.com/BurntSushi/toml"
	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/pkg/handoffschema"
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
	// LinearPersonalToken is the user's Linear API key used by linear-sync to
	// pull notifications. Lives at user-level (not repo-level) so the secret
	// stays out of git. Empty disables the linear-sync feature.
	LinearPersonalToken string `toml:"linear_personal_token,omitempty"`
	// WorkspaceRoot is the base directory under which `workspace create`/`add`
	// carve a new workspace dir when no explicit path is given. Empty falls
	// back to ~/cc-handoff-workspaces. Supports a leading ~ for the home dir.
	WorkspaceRoot string `toml:"workspace_root,omitempty"`
	// Workspaces is the user's workspace launcher list. Each workspace is a
	// root directory holding one or more projects. Cross-project, so it lives
	// at user level rather than in any single repo's .cc-handoff.toml.
	Workspaces []Workspace `toml:"workspace,omitempty"`
}

// Workspace is one launcher entry: a root directory plus one or more projects.
// It is a purely local concept — the relay never sees it. Projects come from
// two sources merged at read time (see ListProjects): the git repos found by
// scanning the workspace root, plus the entries explicitly tracked here (the
// ones added/cloned via `cc-handoff workspace add`).
type Workspace struct {
	Name string `toml:"name"` // display name; empty falls back to basename(Path)
	// Path is the workspace root directory. Empty resolves to
	// <WorkspaceRoot>/<Name>. Supports a leading ~.
	Path string `toml:"path,omitempty"`
	// PreLaunch is a shell snippet inserted between `cd <project>` and the
	// agent invocation in the generated launch command, same semantics as
	// Triggers.PreLaunch (e.g. "nvm use", "clset 6").
	PreLaunch string `toml:"pre_launch,omitempty"`
	// Editor is an optional editor-launch command appended to the generated
	// command, e.g. "code ." or "cursor .". Empty means no editor.
	Editor string `toml:"editor,omitempty"`
	// Agent overrides which agent command the generated launch uses
	// ("claude" | "codex" | ...). Empty falls back to User.Agent, then "claude".
	Agent string `toml:"agent,omitempty"`
	// Projects are the explicitly tracked projects, primarily the ones cloned
	// via `workspace add` (so the source URL is remembered). Repos discovered
	// by scanning Path need not be listed here.
	Projects []Project `toml:"project,omitempty"`
}

// Project is one project inside a Workspace.
type Project struct {
	Name string `toml:"name"`
	// Path is the project directory: absolute, or relative to the workspace root.
	Path string `toml:"path,omitempty"`
	// GitHub records the source URL when the project was added via clone.
	GitHub string `toml:"github,omitempty"`
	// Log is the optional log source for `cc-handoff logs <project>`. A pointer
	// so a project without one stays byte-identical in the config file. nil
	// means "no log source configured" — `logs` errors out and says how to add
	// one.
	Log *LogSource `toml:"log,omitempty"`
}

// LogSource describes how to pull a project's logs for `cc-handoff logs`.
// Command's stdout is the raw log stream; the "latest error + context"
// extraction happens locally on the captured output (predictable, no fragile
// remote-command splicing). Host empty runs Command locally — handy for
// `kubectl logs` / `docker logs` / a local file.
type LogSource struct {
	// Host is the ssh target (e.g. "deploy@10.0.0.5"). Empty runs Command on
	// this machine instead of over ssh.
	Host string `toml:"host,omitempty"`
	// Command prints the log stream to stdout, e.g.
	// "tail -n 2000 /var/log/app/error.log" or
	// "journalctl -u app -n 2000 --no-pager".
	Command string `toml:"command"`
	// Grep is the error-matching regexp used to find the latest failure. Empty
	// falls back to DefaultLogErrorPattern.
	Grep string `toml:"grep,omitempty"`
	// Context is how many lines on each side of the latest match to include.
	// Zero falls back to DefaultLogContext.
	Context int `toml:"context,omitempty"`
}

const (
	// DefaultLogErrorPattern matches the latest failure line when a LogSource
	// (or the --grep flag) doesn't set its own. Case-insensitive.
	DefaultLogErrorPattern = `(?i)(error|panic|fatal|traceback|exception)`
	// DefaultLogContext is the per-side context line count used when neither
	// the LogSource nor --context sets one.
	DefaultLogContext = 20
)

// Repo-level config: lives at <repo-root>/.cc-handoff.toml.
type Repo struct {
	Identity       Identity       `toml:"identity"`
	Paths          Paths          `toml:"paths"`
	PartnerMapping PartnerMapping `toml:"partner_mapping"`
	Triggers       Triggers       `toml:"triggers"`
	Inbox          Inbox          `toml:"inbox,omitempty"`
	Integrations   Integrations   `toml:"integrations,omitempty"`
}

// Integrations groups optional third-party integrations. Each sub-integration
// is independent: leaving the whole section out (or setting enabled=false on
// a specific one) makes cc-handoff behave exactly as before, with no extra
// prompt sections or external API calls.
type Integrations struct {
	Linear LinearIntegration `toml:"linear,omitempty"`
}

// LinearIntegration controls Linear-issue sync. cc-handoff itself never calls
// the Linear API; instead, when Enabled is true, MCP tool results get an
// extra "## 同步到 Linear" block appended at the end, listing the exact
// mcp__linear__* calls Claude should make. Authentication and HTTP are
// delegated to whichever Linear MCP server the user already has configured.
type LinearIntegration struct {
	Enabled       bool     `toml:"enabled"`
	TeamKey       string   `toml:"team_key"`
	DefaultLabels []string `toml:"default_labels,omitempty"`
	// MCPPrefix overrides the Linear MCP tool-name prefix (default "linear"),
	// for installs that namespace their MCP tools differently.
	MCPPrefix     string              `toml:"mcp_prefix,omitempty"`
	SyncOnSubmit  bool                `toml:"sync_on_submit,omitempty"`
	SyncOnPickup  bool                `toml:"sync_on_pickup,omitempty"`
	SyncOnComment bool                `toml:"sync_on_comment,omitempty"`
	SyncOnRetract bool                `toml:"sync_on_retract,omitempty"`
	Notifications LinearNotifications `toml:"notifications,omitempty"`
}

// LinearNotifications opts the local watch daemon (or a manual sync command)
// into pulling Linear notifications via the user's personal API token. Empty
// PollInterval (or "0") leaves the background poller off — only the manual
// `cc-handoff linear-sync` / `mcp__cc-handoff__linear_sync` paths fire.
type LinearNotifications struct {
	PollInterval string   `toml:"poll_interval,omitempty"`
	Types        []string `toml:"types,omitempty"`
}

// Inbox controls where Materialize writes handoff packages. Empty Dir means
// "auto": .cc-handoff/inbox by default, falling back to legacy
// .claude/handoff-inbox when that already exists in the repo.
type Inbox struct {
	Dir string `toml:"dir,omitempty"`
}

type Identity struct {
	Me string `toml:"me,omitempty"` // optional override of user-level identity
	// Partner is the legacy single-recipient field used by
	// submit_handoff/submit_request. Required for 2-party repos; tester
	// repos that only ever fan out to multiple sides can leave it empty as
	// long as Partners is set.
	Partner string `toml:"partner,omitempty"`
	// Partners is the multi-recipient list used by submit_bug as the default
	// `to=[...]` value. Empty means "fall back to [Partner]". Set this for
	// tester repos: partners = ["backend", "frontend"].
	Partners []string `toml:"partners,omitempty"`
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
	// MuteUserPresence: default false (fire desktop notifications when other
	// identities come online / go offline). Set true to silence them.
	MuteUserPresence bool `toml:"mute_user_presence,omitempty"`
	// PreLaunch is a shell snippet inserted between `cd <repo>` and the agent
	// invocation in auto-launch flows. Use it to switch OAuth accounts /
	// activate envs / load .nvmrc before the agent starts.
	// Example: pre_launch = "clset 6"
	PreLaunch string `toml:"pre_launch,omitempty"`
	// LaunchInteractive controls how the agent is started. Default false →
	// existing one-shot mode (e.g. `claude -p "$(cat prompt.md)"`). True →
	// start the agent interactively (no -p) and inject the prompt body via
	// the terminal app's API after the REPL is ready.
	LaunchInteractive bool `toml:"launch_interactive,omitempty"`
	// LaunchMode picks the terminal placement: LaunchModeWindow (default) opens
	// a brand-new window; LaunchModeSplit splits the current window.
	// Windows always uses a new window regardless.
	LaunchMode string `toml:"launch_mode,omitempty"`
	// AckOnLaunch decides if/when an auto-launched handoff is ack'd on the
	// relay (state moves pending → picked):
	//   - "never" (default): manual /pickup later, like the existing flow
	//   - "after_exit": ack only after the agent finishes processing —
	//                   for interactive launches, we append a postlude line
	//                   to the prompt body asking the agent to call
	//                   pickup_handoff MCP at the end of its turn; for
	//                   one-shot (-p) launches, the shell chains
	//                   `<claude> && cc-handoff pickup <id>` so pickup
	//                   runs only on a clean claude exit
	//   - "on_launch": ack via `cc-handoff pickup <id>` chained right
	//                  before the agent invocation. Only valid with
	//                  launch_interactive=false; the launcher errors out
	//                  if both are set (backgrounding the agent breaks
	//                  the terminal-side prompt injection)
	AckOnLaunch string `toml:"ack_on_launch,omitempty"`
	// AutoLaunchOnAlert gates the push-log flow: when true, a log.alert event
	// received over watch auto-launches the agent in the alert's project to
	// triage. Default false keeps it manual — watch only writes the log file
	// and pops a desktop notification, and the user runs the agent themselves.
	AutoLaunchOnAlert bool `toml:"auto_launch_on_alert,omitempty"`
}

const (
	LaunchModeWindow = "window"
	LaunchModeSplit  = "split"
)

const (
	AckOnLaunchNever       = "never"
	AckOnLaunchAfterExit   = "after_exit"
	AckOnLaunchOnLaunch    = "on_launch"
	AckOnLaunchSlashPickup = "slash_pickup"
)

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

// ResolveSwaggerPath turns a paths.swagger config value (which may be empty,
// relative, or absolute) into an absolute path or "". Relative paths are
// joined with repoRoot so a setting like `paths.swagger = "docs/swagger.yaml"`
// works regardless of where the sender invokes cc-handoff from.
func ResolveSwaggerPath(repoRoot, spec string) string {
	if spec == "" || filepath.IsAbs(spec) {
		return spec
	}
	return filepath.Join(repoRoot, spec)
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
	// Partner is the default single recipient for /handoff and /request.
	// Equals Partners[0] when only Partners was configured; equals the raw
	// identity.partner otherwise. Empty only on tester repos that solely
	// fan out — submit_handoff / submit_request will error in that case
	// unless the caller passes an explicit `to=`.
	Partner string
	// Partners is the default recipient list used by /submit-bug. Falls
	// back to [Partner] when identity.partners isn't set, so existing
	// 2-party repos transparently get a one-element list.
	Partners []string
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
	InboxOverride       string
	Linear              LinearIntegration
	LinearPersonalToken string
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
	partners := handoffschema.DedupeIdentities(r.Identity.Partners)
	partner := r.Identity.Partner
	if partner == "" && len(partners) > 0 {
		partner = partners[0]
	}
	if len(partners) == 0 && partner != "" {
		partners = []string{partner}
	}
	out := &Resolved{
		RelayURL:            u.RelayURL,
		Token:               u.Token,
		Me:                  me,
		Partner:             partner,
		Partners:            partners,
		RepoName:            repoName,
		Base:                base,
		Swagger:             r.Paths.Swagger,
		Triggers:            r.Triggers,
		Rules:               r.PartnerMapping.Rules,
		Agent:               ag,
		InboxOverride:       r.Inbox.Dir,
		Linear:              r.Integrations.Linear,
		LinearPersonalToken: u.LinearPersonalToken,
	}
	if out.RelayURL == "" || out.Token == "" || out.Me == "" {
		return nil, fmt.Errorf("incomplete config: relay_url/token/identity must be set in user config")
	}
	if len(out.Partners) == 0 {
		return nil, fmt.Errorf("incomplete repo config: identity.partner or identity.partners must be set in %s", RepoConfigPath(cwd))
	}
	return out, nil
}
