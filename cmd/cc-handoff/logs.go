package main

import (
	"bufio"
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/internal/config"
)

// defaultLogTailLines is how many trailing lines `logs` keeps when the error
// pattern doesn't match anything — better to surface the latest output than an
// empty excerpt.
const defaultLogTailLines = 200

// defaultErrorRe is the compiled built-in error pattern, reused by the push
// path to find the signature line inside an alert body.
var defaultErrorRe = regexp.MustCompile(config.DefaultLogErrorPattern)

func runLogs(ctx context.Context, args []string) error {
	if len(args) > 0 && args[0] == "config" {
		return runLogsConfig(ctx, args[1:])
	}

	fs := flag.NewFlagSet("logs", flag.ContinueOnError)
	wsName := fs.String("workspace", "", "narrow the project lookup to this workspace")
	grep := fs.String("grep", "", "error-matching regexp (overrides the log source's grep; default: "+config.DefaultLogErrorPattern+")")
	lines := fs.Int("lines", defaultLogTailLines, "trailing lines to keep when nothing matches the error pattern")
	contextN := fs.Int("context", 0, "lines of context on each side of the latest match (overrides the log source; default: 20)")
	open := fs.Bool("open", false, "after fetching, launch the agent in the project to analyze (in-place exec; --window for a new terminal)")
	window := fs.Bool("window", false, "with --open, open a new terminal window instead of replacing the current shell")
	noGrade := fs.Bool("no-grade", false, "skip the configured local-AI severity grader for this run")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: cc-handoff logs <project> [--workspace NAME] [--grep RE] [--context N] [-lines N] [--open [--window]]")
	}
	project := pos[0]

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	ws, p, err := resolveProject(u, project, *wsName)
	if err != nil {
		return err
	}
	if p.Log == nil || strings.TrimSpace(p.Log.Command) == "" {
		cfgPath, _ := config.UserConfigPath()
		if cfgPath == "" {
			cfgPath = "your user config"
		}
		return fmt.Errorf("project %q has no log source configured; add a [workspace.project.log] block with host + command to %s",
			p.Name, cfgPath)
	}

	pattern := cmp.Or(*grep, p.Log.Grep, config.DefaultLogErrorPattern)
	re, err := regexp.Compile(pattern)
	if err != nil {
		return fmt.Errorf("invalid grep pattern %q: %w", pattern, err)
	}
	ctxLines := cmp.Or(*contextN, p.Log.Context, config.DefaultLogContext)

	fmt.Printf("fetching logs for %s …\n", p.Name)
	raw, err := fetchLogSource(ctx, p.Log)
	if err != nil {
		return err
	}
	excerpt, matchLine := extractLatestError(raw, re, ctxLines, *lines)
	if strings.TrimSpace(excerpt) == "" {
		return fmt.Errorf("log source returned no output (command: %s)", p.Log.Command)
	}

	// Dedup before grading so a recurring error doesn't burn a (slow) grader call.
	file, dup := logTriageTarget(p.Path, cmp.Or(matchLine, excerpt))
	if dup {
		fmt.Printf("duplicate error, already backed up — %s\n", file)
	} else {
		var level string
		if u.GradeCommand != "" && !*noGrade {
			if level = gradeSeverity(ctx, u.GradeCommand, excerpt); level != "" {
				fmt.Printf("severity: %s\n", level)
			}
		}
		body := logTriageMarkdown(p.Name, logSourceLabel(p.Log), time.Now().Format(time.RFC3339), pattern, level, excerpt)
		if err := writeTriageFile(file, body); err != nil {
			return err
		}
		fmt.Printf("wrote %s\n", file)
	}

	if !*open {
		fmt.Printf("analyze it with: cc-handoff logs %s --open\n", p.Name)
		return nil
	}
	ag, err := agent.Resolve(cmp.Or(ws.Agent, u.Agent))
	if err != nil {
		return err
	}
	return launchAgentWithPrompt(ctx, ag, p.Path, file, ws.PreLaunch, *window)
}

// runLogsConfig interactively configures (or edits) a project's log source —
// the guided alternative to hand-editing [workspace.project.log] in the user
// config. Pre-fills the current values so it doubles as an editor.
func runLogsConfig(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("logs config", flag.ContinueOnError)
	wsName := fs.String("workspace", "", "narrow the project lookup to this workspace")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: cc-handoff logs config <project> [--workspace NAME]")
	}

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	ws, p, err := resolveProject(u, pos[0], *wsName)
	if err != nil {
		return err
	}
	cur := config.LogSource{}
	if p.Log != nil {
		cur = *p.Log
	}

	rd := bufio.NewReader(os.Stdin)
	prompt := func(label, current string) string {
		if current != "" {
			fmt.Printf("%s [%s]: ", label, current)
		} else {
			fmt.Printf("%s: ", label)
		}
		line, _ := rd.ReadString('\n')
		if line = strings.TrimSpace(line); line == "" {
			return current
		}
		return line
	}

	host := prompt("Log host (ssh target, blank = run command locally)", cur.Host)
	command := prompt("Log command (its stdout is the raw log stream)", cur.Command)
	if strings.TrimSpace(command) == "" {
		return fmt.Errorf("log command is required")
	}
	grep := prompt("Error grep regexp (blank = default "+config.DefaultLogErrorPattern+")", cur.Grep)
	ctxCur := ""
	if cur.Context > 0 {
		ctxCur = strconv.Itoa(cur.Context)
	}
	contextN := 0
	if s := prompt("Context lines around the match (blank = default 20)", ctxCur); s != "" {
		if contextN, err = strconv.Atoi(s); err != nil {
			return fmt.Errorf("context must be a number: %w", err)
		}
	}

	src := config.LogSource{Host: host, Command: command, Grep: grep, Context: contextN}
	if err := attachLogSource(u, ws.Name, p.Name, p.Path, src); err != nil {
		return err
	}
	path, err := config.SaveUser(u)
	if err != nil {
		return err
	}
	fmt.Printf("configured log source for %q in %s\n", p.Name, path)
	fmt.Printf("fetch it with: cc-handoff logs %s\n", p.Name)
	return nil
}

// attachLogSource sets src as the project's log source in u, materializing an
// explicit [[workspace.project]] entry when the project was only auto-discovered
// (matched by name within the workspace). Mutates u in place; caller SaveUser.
func attachLogSource(u *config.User, wsName, projName, projPath string, src config.LogSource) error {
	ws := findWorkspace(u, wsName)
	if ws == nil {
		return fmt.Errorf("workspace %q not found", wsName)
	}
	for i := range ws.Projects {
		if ws.Projects[i].Name == projName {
			ws.Projects[i].Log = &src
			return nil
		}
	}
	ws.Projects = append(ws.Projects, config.Project{Name: projName, Path: projPath, Log: &src})
	return nil
}

// fetchLogSource runs the log source's command and returns its stdout. With a
// Host it runs `ssh <host> <command>`; without, it runs the command through the
// local shell so pipes / kubectl logs / docker logs work as written.
func fetchLogSource(ctx context.Context, src *config.LogSource) (string, error) {
	if strings.TrimSpace(src.Host) != "" {
		return runCapture(ctx, "ssh", src.Host, src.Command)
	}
	name, args := localShell(src.Command)
	return runCapture(ctx, name, args...)
}

// localShell returns the platform invocation that runs command as a single
// string: `sh -c` on Unix, `cmd /c` on Windows. Shared by the log fetcher and
// the severity grader.
func localShell(command string) (name string, args []string) {
	if runtime.GOOS == "windows" {
		return "cmd", []string{"/c", command}
	}
	return "sh", []string{"-c", command}
}

// runCapture runs a command and returns its stdout, folding stderr into the
// error on failure. Mirrors internal/sources/git's run() so the failure
// message is actionable (which command, what it printed).
func runCapture(ctx context.Context, name string, args ...string) (string, error) {
	return runCaptureIn(ctx, nil, name, args...)
}

// runCaptureIn is runCapture with an optional stdin reader (nil = no stdin) —
// used by the grader to pipe the prompt in.
func runCaptureIn(ctx context.Context, stdin io.Reader, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = stdin
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s %s: %w (stderr: %s)", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}

// extractLatestError returns the most relevant slice of raw log output — the
// LAST line matching re plus contextN lines on each side — along with that
// matched line itself (used as the stable dedup signature). When nothing
// matches, it falls back to the trailing tailN lines and an empty matchLine.
// Pure — the unit tests pin its boundary behavior.
func extractLatestError(raw string, re *regexp.Regexp, contextN, tailN int) (excerpt, matchLine string) {
	lines := strings.Split(strings.TrimRight(raw, "\n"), "\n")
	last := -1
	for i, ln := range lines {
		if re.MatchString(ln) {
			last = i
		}
	}
	if last < 0 {
		if tailN > 0 && len(lines) > tailN {
			lines = lines[len(lines)-tailN:]
		}
		return strings.Join(lines, "\n"), ""
	}
	start := last - contextN
	if start < 0 {
		start = 0
	}
	end := last + contextN + 1
	if end > len(lines) {
		end = len(lines)
	}
	return strings.Join(lines[start:end], "\n"), lines[last]
}

// errorFingerprint reduces an error line to a stable signature so the same
// failure recurring with a different timestamp / id / address / line number
// dedups to one backup. It normalizes the volatile parts, then hashes — see
// fingerprintNormalize for what's collapsed.
func errorFingerprint(line string) string {
	sum := sha256.Sum256([]byte(fingerprintNormalize(line)))
	return hex.EncodeToString(sum[:])[:12]
}

var (
	fpHex  = regexp.MustCompile(`0x[0-9a-fA-F]+`)
	fpUUID = regexp.MustCompile(`[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}`)
	fpNum  = regexp.MustCompile(`\d+`)
	fpWS   = regexp.MustCompile(`\s+`)
)

// fingerprintNormalize strips the parts of an error line that vary between
// otherwise-identical occurrences: hex addresses, UUIDs, and digit runs
// (timestamps, ids, line numbers, ports), then collapses whitespace. Order
// matters — UUIDs and hex are masked before the digit pass so they aren't
// partially eaten.
func fingerprintNormalize(line string) string {
	line = fpUUID.ReplaceAllString(line, "UUID")
	line = fpHex.ReplaceAllString(line, "0xHEX")
	line = fpNum.ReplaceAllString(line, "0")
	return strings.TrimSpace(fpWS.ReplaceAllString(line, " "))
}

// logTriageTarget returns the triage file path for an error signature and
// whether that file already exists — i.e. the same error has already been
// backed up. Path is <projectDir>/.cc-handoff/logs/<fingerprint>.md. Callers
// check exists to dedup (and to skip the slow grader on repeats) before writing.
func logTriageTarget(projectDir, signature string) (path string, exists bool) {
	path = filepath.Join(projectDir, ".cc-handoff", "logs", errorFingerprint(signature)+".md")
	_, err := os.Stat(path)
	return path, err == nil
}

// writeTriageFile writes body to path (a logTriageTarget result), creating the
// logs dir. Dedup is the caller's call via logTriageTarget; this always writes.
func writeTriageFile(path, body string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create %s: %w", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// logSourceLabel renders a LogSource's provenance line for the triage header.
func logSourceLabel(src *config.LogSource) string {
	if strings.TrimSpace(src.Host) != "" {
		return "ssh " + src.Host + ": " + src.Command
	}
	return "local: " + src.Command
}

// logTriageMarkdown renders the triage prompt: provenance header (with the
// graded severity when present), the fenced log excerpt, and the
// troubleshooting task. Shared shape so the manual `logs` path and the pushed
// log.alert path produce comparable prompts.
func logTriageMarkdown(project, source, fetchedAt, pattern, level, excerpt string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# 日志排查 — %s\n\n", project)
	if level != "" {
		fmt.Fprintf(&b, "- 严重等级: %s\n", level)
	}
	fmt.Fprintf(&b, "- 来源: %s\n", source)
	fmt.Fprintf(&b, "- 抓取时间: %s\n", fetchedAt)
	if pattern != "" {
		fmt.Fprintf(&b, "- 过滤: `%s`\n", pattern)
	}
	b.WriteString("\n## 日志摘录\n\n```log\n")
	b.WriteString(excerpt)
	b.WriteString("\n```\n\n## 任务\n\n")
	b.WriteString("请分析上面的日志,定位最新错误的根因;必要时读取相关源码,给出修复方案或直接修复。\n")
	return b.String()
}
