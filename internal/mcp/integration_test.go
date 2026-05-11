package mcp_test

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/mcp"
	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

// TestMCPEndToEnd drives the MCP server in-process: spins up the relay via
// httptest, sets up two temp repos, then sends JSON-RPC messages through a
// pipe so we can exercise initialize / tools/list / tools/call without a
// subprocess.
func TestMCPEndToEnd(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}

	// ---- relay ----
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	mustWrite(t, tokensPath, `[
		{"token":"tok-back","identity":"user@backend"},
		{"token":"tok-front","identity":"alex@frontend"}
	]`)
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}
	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: hub}).Handler())
	t.Cleanup(srv.Close)
	relayURL := srv.URL

	// ---- backend repo ----
	back := initRepo(t, "backend")
	mustWrite(t, filepath.Join(back, ".cc-handoff.toml"), `
[identity]
partner = "alex@frontend"

[paths]
base = "origin/main"
repo = "backend-demo"

[partner_mapping]
[[partner_mapping.rule]]
when_path_matches         = "^internal/module/(?P<domain>[^/]+)/"
suggest_edit              = ["lib/api/{domain}.ts"]
suggest_create_if_missing = true
`)
	mustMkdirAll(t, filepath.Join(back, "internal/module/customers/handler"))
	mustWrite(t, filepath.Join(back, "internal/module/customers/handler/routes.go"), "package handler\n")
	mustGit(t, back, "add", ".")
	mustGit(t, back, "commit", "-qm", "feat(customers)")

	backHome := setupHome(t, relayURL, "tok-back", "user@backend")

	// ---- frontend repo ----
	front := initRepo(t, "frontend")
	mustWrite(t, filepath.Join(front, ".cc-handoff.toml"), `
[identity]
partner = "user@backend"

[paths]
base = "origin/main"
repo = "frontend-demo"
`)

	frontHome := setupHome(t, relayURL, "tok-front", "alex@frontend")

	// ---- backend MCP session: submit_handoff ----
	chdir(t, back)
	t.Setenv("HOME", backHome)
	resp := mcpRoundtrip(t, []map[string]any{
		{"jsonrpc": "2.0", "id": 1, "method": mcp.MethodInitialize, "params": map[string]any{
			"protocolVersion": mcp.ProtocolVersion,
			"capabilities":    map[string]any{},
			"clientInfo":      map[string]any{"name": "test", "version": "0"},
		}},
		{"jsonrpc": "2.0", "method": mcp.NotificationInitialized},
		{"jsonrpc": "2.0", "id": 2, "method": mcp.MethodToolsList},
		{"jsonrpc": "2.0", "id": 3, "method": mcp.MethodToolsCall, "params": map[string]any{
			"name": mcp.ToolSubmitHandoff,
			"arguments": map[string]any{
				"summary": "新增 POST /customers/export，导出客户列表为 CSV。",
				"note":    "导出文件名必须以 `customers-YYYY-MM-DD.csv` 命名；下载按钮 loading 时禁用避免重复点击。",
				"to":      "alex@frontend",
				"cwd":     back,
			},
		}},
	})

	byID := indexByID(resp)
	result := mustResult(t, byID[1])
	if result["protocolVersion"] != mcp.ProtocolVersion {
		t.Errorf("protocolVersion: got %v", result["protocolVersion"])
	}
	if caps, _ := result["capabilities"].(map[string]any); caps == nil {
		t.Error("missing capabilities in initialize response")
	}

	// tools/list
	toolsRes := mustResult(t, byID[2])
	tools, _ := toolsRes["tools"].([]any)
	if len(tools) != 11 {
		t.Fatalf("tools/list: want 11 tools, got %d", len(tools))
	}
	wantNames := map[string]bool{
		mcp.ToolSubmitHandoff:   false,
		mcp.ToolSubmitRequest:   false,
		mcp.ToolListInbox:       false,
		mcp.ToolPickupHandoff:   false,
		mcp.ToolCommentHandoff:  false,
		mcp.ToolStatusHandoff:   false,
		mcp.ToolListSent:        false,
		mcp.ToolListHistory:     false,
		mcp.ToolRetractHandoff:  false,
		mcp.ToolListLocalInbox:  false,
		mcp.ToolListOnlineUsers: false,
	}
	for _, t0 := range tools {
		m, _ := t0.(map[string]any)
		if name, _ := m["name"].(string); name != "" {
			if _, ok := wantNames[name]; ok {
				wantNames[name] = true
			}
		}
	}
	for n, seen := range wantNames {
		if !seen {
			t.Errorf("tools/list missing tool %q", n)
		}
	}

	// tools/call submit_handoff
	submitRes := mustResult(t, byID[3])
	content, _ := submitRes["content"].([]any)
	if len(content) == 0 {
		t.Fatal("submit_handoff returned no content")
	}
	first, _ := content[0].(map[string]any)
	text, _ := first["text"].(string)
	if !strings.Contains(text, "Submitted handoff `h_") {
		t.Errorf("submit_handoff text unexpected:\n%s", text)
	}
	if !strings.Contains(text, "targeting_hints") {
		t.Error("submit response missing targeting_hints summary")
	}
	if isErr, _ := submitRes["isError"].(bool); isErr {
		t.Errorf("submit_handoff returned isError: %s", text)
	}

	// ---- frontend MCP session: list_inbox + pickup_handoff ----
	chdir(t, front)
	t.Setenv("HOME", frontHome)
	resp2 := mcpRoundtrip(t, []map[string]any{
		{"jsonrpc": "2.0", "id": 11, "method": mcp.MethodInitialize, "params": map[string]any{
			"protocolVersion": mcp.ProtocolVersion,
			"capabilities":    map[string]any{},
			"clientInfo":      map[string]any{"name": "test", "version": "0"},
		}},
		{"jsonrpc": "2.0", "method": mcp.NotificationInitialized},
		{"jsonrpc": "2.0", "id": 12, "method": mcp.MethodToolsCall, "params": map[string]any{
			"name":      mcp.ToolListInbox,
			"arguments": map[string]any{"cwd": front},
		}},
	})
	byID = indexByID(resp2)
	listRes := mustResult(t, byID[12])
	listText := contentText(t, listRes)
	if !strings.Contains(listText, "h_") || !strings.Contains(listText, "user@backend") {
		t.Fatalf("list_inbox unexpected:\n%s", listText)
	}
	// Extract the id we need to pick up.
	id := extractHandoffID(listText)
	if id == "" {
		t.Fatalf("could not extract handoff id from:\n%s", listText)
	}

	resp3 := mcpRoundtrip(t, []map[string]any{
		{"jsonrpc": "2.0", "id": 21, "method": mcp.MethodInitialize, "params": map[string]any{
			"protocolVersion": mcp.ProtocolVersion,
			"capabilities":    map[string]any{},
			"clientInfo":      map[string]any{"name": "test", "version": "0"},
		}},
		{"jsonrpc": "2.0", "method": mcp.NotificationInitialized},
		{"jsonrpc": "2.0", "id": 22, "method": mcp.MethodToolsCall, "params": map[string]any{
			"name": mcp.ToolPickupHandoff,
			"arguments": map[string]any{
				"id":  id,
				"cwd": front,
			},
		}},
	})
	pickRes := mustResult(t, indexByID(resp3)[22])
	pickText := contentText(t, pickRes)
	if !strings.Contains(pickText, "Picked up handoff") {
		t.Fatalf("pickup_handoff missing confirmation:\n%s", pickText)
	}
	if !strings.Contains(pickText, "/customers/export") {
		t.Errorf("pickup_handoff prompt missing endpoint summary content")
	}
	if !strings.Contains(pickText, "lib/api/customers.ts") {
		t.Errorf("pickup_handoff prompt missing rule-derived hint")
	}
	for _, f := range []string{"package.json", "summary.md", "prompt.md"} {
		path := filepath.Join(front, ".cc-handoff/inbox", id, f)
		if _, err := os.Stat(path); err != nil {
			t.Errorf("expected materialized file %s: %v", f, err)
		}
	}
	// full.diff must NOT exist — the new flow ships only API delta + commits + paths,
	// and the recipient's Claude generates INTEGRATION.md from those.
	if _, err := os.Stat(filepath.Join(front, ".cc-handoff/inbox", id, "full.diff")); err == nil {
		t.Error("full.diff should not be materialized in the new prompt-driven flow")
	}
	// prompt.md must instruct the receiver to write INTEGRATION.md, not edit code directly.
	promptBytes, err := os.ReadFile(filepath.Join(front, ".cc-handoff/inbox", id, "prompt.md"))
	if err != nil {
		t.Fatalf("read prompt.md: %v", err)
	}
	prompt := string(promptBytes)
	for _, want := range []string{
		"docs/integrations/" + id + ".md", // target path is repo-root, per-handoff
		"停下",                              // human-in-the-loop marker
		"comment_handoff",                 // step 0: ambiguity → ask back
		"风格锚点",                            // step 4: avoid style drift
		"⚠️ 后端备注 / 需求",                    // NoteMD section header
		"customers-YYYY-MM-DD.csv",        // verbatim NoteMD content
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt.md missing expected directive %q; got:\n%s", want, prompt)
		}
	}
}

// mcpRoundtrip drives a fresh mcp.Server via in-process pipes and returns all
// responses (notifications produce none).
func mcpRoundtrip(t *testing.T, msgs []map[string]any) []map[string]any {
	t.Helper()
	srv := &mcp.Server{
		Info:  mcp.ServerInfo{Name: "cc-handoff", Version: "test"},
		Tools: mcp.DefaultTools(),
	}
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var serverErr error
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		serverErr = srv.Run(ctx, inR, outW)
		_ = outW.Close()
	}()

	enc := json.NewEncoder(inW)
	enc.SetEscapeHTML(false)
	go func() {
		defer inW.Close()
		for _, m := range msgs {
			if err := enc.Encode(m); err != nil {
				t.Errorf("write msg: %v", err)
				return
			}
		}
	}()

	var responses []map[string]any
	scanner := bufio.NewScanner(outR)
	scanner.Buffer(make([]byte, 0, 64<<10), 4<<20)
	expectN := 0
	for _, m := range msgs {
		if _, hasID := m["id"]; hasID {
			expectN++
		}
	}
	for scanner.Scan() {
		var resp map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &resp); err != nil {
			t.Fatalf("decode response: %v\nline: %s", err, scanner.Text())
		}
		responses = append(responses, resp)
		if len(responses) == expectN {
			break
		}
	}
	wg.Wait()
	if serverErr != nil && serverErr != context.Canceled {
		// Server.Run returns nil on EOF (clean stdin close).
		// Unexpected errors fail the test.
		t.Logf("server.Run returned: %v", serverErr)
	}
	return responses
}

func mustResult(t *testing.T, resp map[string]any) map[string]any {
	t.Helper()
	if e, ok := resp["error"].(map[string]any); ok && e != nil {
		t.Fatalf("rpc error: %+v", e)
	}
	r, _ := resp["result"].(map[string]any)
	if r == nil {
		t.Fatalf("missing result in response: %+v", resp)
	}
	return r
}

func contentText(t *testing.T, result map[string]any) string {
	t.Helper()
	content, _ := result["content"].([]any)
	if len(content) == 0 {
		t.Fatalf("no content in result: %+v", result)
	}
	first, _ := content[0].(map[string]any)
	s, _ := first["text"].(string)
	return s
}

var handoffIDRE = regexp.MustCompile(`h_\d{8}_[A-Z0-9]+`)

func extractHandoffID(s string) string {
	return handoffIDRE.FindString(s)
}

func indexByID(responses []map[string]any) map[float64]map[string]any {
	out := make(map[float64]map[string]any, len(responses))
	for _, r := range responses {
		if id, ok := r["id"].(float64); ok {
			out[id] = r
		}
	}
	return out
}

// ---- helpers ----

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=test",
		"GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=test",
		"GIT_COMMITTER_EMAIL=test@example.com",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

func initRepo(t *testing.T, name string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	mustMkdirAll(t, dir)
	mustGit(t, dir, "-c", "init.defaultBranch=main", "init", "-q")
	mustWrite(t, filepath.Join(dir, "README.md"), "# "+name)
	mustGit(t, dir, "add", ".")
	mustGit(t, dir, "commit", "-qm", "init")
	mustGit(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	return dir
}

func setupHome(t *testing.T, relayURL, token, identity string) string {
	t.Helper()
	home := filepath.Join(t.TempDir(), "home")
	mustWrite(t, filepath.Join(home, ".config/cc-handoff/config.toml"),
		"relay_url = \""+relayURL+"\"\n"+
			"token     = \""+token+"\"\n"+
			"identity  = \""+identity+"\"\n",
	)
	return home
}

// chdir changes the test process's working directory and restores it on
// cleanup. Mutates global state — keep this test serial (no t.Parallel()).
func chdir(t *testing.T, dir string) {
	t.Helper()
	prev, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(prev) })
}
