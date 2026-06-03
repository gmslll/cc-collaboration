package main

import (
	"bytes"
	"cmp"
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/internal/config"
)

// defaultLogTailLines is how many trailing lines `logs` keeps when the error
// pattern doesn't match anything — better to surface the latest output than an
// empty excerpt.
const defaultLogTailLines = 200

func runLogs(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("logs", flag.ContinueOnError)
	wsName := fs.String("workspace", "", "narrow the project lookup to this workspace")
	grep := fs.String("grep", "", "error-matching regexp (overrides the log source's grep; default: "+config.DefaultLogErrorPattern+")")
	lines := fs.Int("lines", defaultLogTailLines, "trailing lines to keep when nothing matches the error pattern")
	contextN := fs.Int("context", 0, "lines of context on each side of the latest match (overrides the log source; default: 20)")
	open := fs.Bool("open", false, "after fetching, launch the agent in the project to analyze (in-place exec; --window for a new terminal)")
	window := fs.Bool("window", false, "with --open, open a new terminal window instead of replacing the current shell")
	if err := fs.Parse(args); err != nil {
		return err
	}
	pos := fs.Args()
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
	excerpt := extractLatestError(raw, re, ctxLines, *lines)
	if strings.TrimSpace(excerpt) == "" {
		return fmt.Errorf("log source returned no output (command: %s)", p.Log.Command)
	}

	file, err := writeLogTriage(p.Path, p.Name, p.Log, excerpt, pattern)
	if err != nil {
		return err
	}
	fmt.Printf("wrote %s\n", file)

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

// fetchLogSource runs the log source's command and returns its stdout. With a
// Host it runs `ssh <host> <command>`; without, it runs the command through the
// local shell so pipes / kubectl logs / docker logs work as written.
func fetchLogSource(ctx context.Context, src *config.LogSource) (string, error) {
	if strings.TrimSpace(src.Host) != "" {
		return runCapture(ctx, "ssh", src.Host, src.Command)
	}
	if runtime.GOOS == "windows" {
		return runCapture(ctx, "cmd", "/c", src.Command)
	}
	return runCapture(ctx, "sh", "-c", src.Command)
}

// runCapture runs a command and returns its stdout, folding stderr into the
// error on failure. Mirrors internal/sources/git's run() so the failure
// message is actionable (which command, what it printed).
func runCapture(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s %s: %w (stderr: %s)", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}

// extractLatestError returns the most relevant slice of raw log output: the
// LAST line matching re plus contextN lines on each side. When nothing matches,
// it falls back to the trailing tailN lines so the caller still sees recent
// output. Pure — the unit tests pin its boundary behavior.
func extractLatestError(raw string, re *regexp.Regexp, contextN, tailN int) string {
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
		return strings.Join(lines, "\n")
	}
	start := last - contextN
	if start < 0 {
		start = 0
	}
	end := last + contextN + 1
	if end > len(lines) {
		end = len(lines)
	}
	return strings.Join(lines[start:end], "\n")
}

// writeLogTriage writes the fetched excerpt as a triage prompt under the
// project's .cc-handoff/logs dir and returns the file path. The file doubles as
// the prompt fed to the agent on --open.
func writeLogTriage(projectDir, project string, src *config.LogSource, excerpt, pattern string) (string, error) {
	source := "local: " + src.Command
	if strings.TrimSpace(src.Host) != "" {
		source = "ssh " + src.Host + ": " + src.Command
	}
	body := logTriageMarkdown(project, source, time.Now().Format(time.RFC3339), pattern, excerpt)
	return writeLogTriageFile(projectDir, body)
}

// logTriageMarkdown renders the triage prompt: provenance header, the fenced
// log excerpt, and the troubleshooting task. Shared shape so the manual `logs`
// path and the pushed log.alert path produce comparable prompts.
func logTriageMarkdown(project, source, fetchedAt, pattern, excerpt string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# 日志排查 — %s\n\n", project)
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

// writeLogTriageFile writes body to <projectDir>/.cc-handoff/logs/<ts>.md and
// returns the path. Shared by the manual and pushed log paths.
func writeLogTriageFile(projectDir, body string) (string, error) {
	dir := filepath.Join(projectDir, ".cc-handoff", "logs")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create %s: %w", dir, err)
	}
	file := filepath.Join(dir, time.Now().Format("20060102-150405")+".md")
	if err := os.WriteFile(file, []byte(body), 0o644); err != nil {
		return "", fmt.Errorf("write %s: %w", file, err)
	}
	return file, nil
}
