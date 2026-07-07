package linear

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/todoschema"
)

// ImportResult summarizes one `cc-handoff todo import-linear` /
// import_linear_issues run.
type ImportResult struct {
	TeamKey         string
	LinearProjectID string
	ProjectID       string
	Issues          int
	Created         int
	Updated         int
	// Unchanged counts issues skipped because their Linear updatedAt matched the
	// stored source_updated_at (incremental import — no re-write / re-upload).
	Unchanged     int
	Attachments   int
	SkippedAssets int
}

// ImportTeamIssuesForRepo is the shared "do the whole import" entry point
// used by both `cc-handoff todo import-linear` (cmd/cc-handoff/todo.go) and
// the import_linear_issues MCP tool (internal/mcp/todo_tools.go) — see the
// feature plan's Track A. It resolves cwd's config, builds the Linear + relay
// clients, fetches every issue for teamKey (falling back to the repo's
// configured [integrations.linear] team_key when teamKey is empty), and
// upserts each as a todo keyed by SourceRef ("linear:<identifier>") so
// re-running is idempotent. linearProjectID optionally narrows the Linear
// source to one project under the team; empty imports the whole team.
// projectID scopes created todos to a cc-handoff team project; empty means
// personal todos owned by the caller's identity.
func ImportTeamIssuesForRepo(ctx context.Context, cwd, teamKey, linearProjectID, projectID string) (ImportResult, error) {
	res, err := config.Resolve(cwd)
	var (
		relayURL            string
		token               string
		me                  string
		linearPersonalToken string
		linearCfg           config.LinearIntegration
	)
	if err == nil {
		relayURL = res.RelayURL
		token = res.Token
		me = res.Me
		linearPersonalToken = res.LinearPersonalToken
		linearCfg = res.Linear
	} else {
		u, _, userErr := config.LoadUser()
		if userErr != nil {
			return ImportResult{}, userErr
		}
		if u == nil {
			return ImportResult{}, fmt.Errorf("user config missing; run `cc-handoff init`")
		}
		relayURL = u.RelayURL
		token = u.Token
		me = u.Identity
		linearPersonalToken = u.LinearPersonalToken
	}
	if linearPersonalToken == "" {
		return ImportResult{}, fmt.Errorf("linear_personal_token not set in user config (~/.config/cc-handoff/config.toml). " +
			"Generate one at Linear → Account → Security & Access → Personal API Keys.")
	}
	teamKey = strings.TrimSpace(teamKey)
	linearProjectID = strings.TrimSpace(linearProjectID)
	projectID = strings.TrimSpace(projectID)
	if teamKey == "" {
		teamKey = strings.TrimSpace(linearCfg.TeamKey)
	}
	if linearProjectID == "" {
		linearProjectID = strings.TrimSpace(linearCfg.ProjectID)
	}
	if teamKey == "" {
		return ImportResult{}, fmt.Errorf("no Linear team key: pass --team, or set [integrations.linear] team_key in .cc-handoff.toml")
	}
	if linearProjectID != "" && !looksLikeUUID(linearProjectID) {
		return ImportResult{}, fmt.Errorf("linear project_id must be a UUID (got %q); in Linear Web open the project and copy its model UUID", linearProjectID)
	}
	if relayURL == "" || token == "" || me == "" {
		return ImportResult{}, fmt.Errorf("incomplete user config: relay_url/token/identity must be set")
	}

	gql := NewClient(linearPersonalToken)
	todoClient := transport.New(relayURL, token)

	// Candidate identity pool for assignee-email matching (see
	// matchAssigneeIdentity): always the caller's own identity, plus every
	// member of the target project when importing into a team project.
	candidates := []string{me}
	if projectID != "" {
		members, err := todoClient.ListProjectMembers(ctx, projectID)
		if err != nil {
			return ImportResult{}, fmt.Errorf("list project %s members: %w", projectID, err)
		}
		for _, m := range members {
			candidates = append(candidates, m.Identity)
		}
	}

	issues, err := GetTeamIssues(ctx, gql, teamKey, linearProjectID)
	if err != nil {
		source := teamKey
		if linearProjectID != "" {
			source = fmt.Sprintf("%s project %s", teamKey, linearProjectID)
		}
		return ImportResult{}, fmt.Errorf("fetch linear issues for %s: %w", source, err)
	}

	result := ImportResult{
		TeamKey:         teamKey,
		LinearProjectID: linearProjectID,
		ProjectID:       projectID,
		Issues:          len(issues),
	}
	for _, iss := range issues {
		created, unchanged, uploaded, skipped, err := upsertTodoFromIssue(ctx, todoClient, gql, iss, teamKey, linearProjectID, projectID, candidates)
		if err != nil {
			return result, fmt.Errorf("import %s: %w", iss.Identifier, err)
		}
		if unchanged {
			result.Unchanged++
			continue
		}
		if created {
			result.Created++
		} else {
			result.Updated++
		}
		result.Attachments += uploaded
		result.SkippedAssets += skipped
	}
	return result, nil
}

// upsertTodoFromIssue applies the mapping rules from the feature plan to one
// Linear issue: find-by-SourceRef decides create vs. update. Assignee
// matching only applies on create — a re-import shouldn't clobber a manual
// reassignment made inside cc-handoff after the fact.
func upsertTodoFromIssue(ctx context.Context, c *transport.Client, gql *Client, iss Issue, teamKey, linearProjectID, projectID string, candidates []string) (created, unchanged bool, uploaded, skipped int, err error) {
	sourceRef := "linear:" + iss.Identifier
	sourceProvider := "linear"
	sourceProjectID := linearProjectID
	if sourceProjectID == "" {
		sourceProjectID = strings.TrimSpace(iss.ProjectID)
	}
	status := mapIssueStatus(iss.StateType, iss.StateName)
	priority := mapIssuePriority(iss.Priority)
	bodyMD := composeBodyMD(iss.Labels, iss.Description)

	existing, found, err := c.FindTodoBySourceRef(ctx, sourceRef, projectID)
	if err != nil {
		return false, false, 0, 0, fmt.Errorf("lookup: %w", err)
	}
	if found {
		// Skip an issue whose Linear updatedAt is unchanged since the last import
		// — no PatchTodo / SetTodoStatus / attachment re-upload. Guard on a
		// non-empty stored watermark so rows imported before source_updated_at
		// existed still take one full pass (which backfills it).
		if iss.UpdatedAt != "" && existing.SourceUpdatedAt == iss.UpdatedAt {
			return false, true, 0, 0, nil
		}
		title := iss.Title
		if _, err := c.PatchTodo(ctx, existing.ID, transport.TodoPatch{
			Title:                   &title,
			BodyMD:                  &bodyMD,
			Priority:                &priority,
			DueAt:                   transport.OptionalTime{Set: true, Value: iss.DueDate},
			SourceProvider:          &sourceProvider,
			SourceTeamKey:           &teamKey,
			SourceProjectID:         &sourceProjectID,
			SourceUpdatedAt:         &iss.UpdatedAt,
			SourceAssigneeName:      &iss.AssigneeName,
			SourceAssigneeAvatarURL: &iss.AssigneeAvatarURL,
		}); err != nil {
			return false, false, 0, 0, fmt.Errorf("patch: %w", err)
		}
		if _, err := c.SetTodoStatus(ctx, existing.ID, status); err != nil {
			return false, false, 0, 0, fmt.Errorf("set status: %w", err)
		}
		uploaded, skipped, err = uploadAndRewrite(ctx, c, gql, existing.ID, bodyMD, iss)
		return false, false, uploaded, skipped, err
	}

	out, err := c.CreateTodo(ctx, &todoschema.Todo{
		ProjectID:               projectID,
		Title:                   iss.Title,
		BodyMD:                  bodyMD,
		Priority:                priority,
		DueAt:                   iss.DueDate,
		SourceRef:               sourceRef,
		SourceURL:               iss.URL,
		SourceProvider:          sourceProvider,
		SourceTeamKey:           teamKey,
		SourceProjectID:         sourceProjectID,
		SourceUpdatedAt:         iss.UpdatedAt,
		SourceAssigneeName:      iss.AssigneeName,
		SourceAssigneeAvatarURL: iss.AssigneeAvatarURL,
	})
	if err != nil {
		return false, false, 0, 0, fmt.Errorf("create: %w", err)
	}
	if status != todoschema.StatusTodo {
		if _, err := c.SetTodoStatus(ctx, out.ID, status); err != nil {
			return true, false, 0, 0, fmt.Errorf("set status: %w", err)
		}
	}
	if assignee := matchAssigneeIdentity(candidates, iss.AssigneeEmail); assignee != "" {
		if _, err := c.AssignTodo(ctx, out.ID, assignee, "", "", "", "", ""); err != nil {
			return true, false, 0, 0, fmt.Errorf("assign: %w", err)
		}
	}
	uploaded, skipped, err = uploadAndRewrite(ctx, c, gql, out.ID, bodyMD, iss)
	return true, false, uploaded, skipped, err
}

func looksLikeUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, r := range s {
		switch i {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		default:
			if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
				return false
			}
		}
	}
	return true
}

var markdownURLRe = regexp.MustCompile(`!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)`)

// uploadIssueAssets downloads every image/file the issue references and
// re-uploads it as a todo attachment. It returns, alongside the counts, a
// map from each source URL to the bare attachment name it was stored under so
// the caller can rewrite the body's image refs (TodoBodyView resolves body
// `![alt](name)` refs by attachment name, not URL — an un-rewritten
// uploads.linear.app URL renders as a broken image).
func uploadIssueAssets(ctx context.Context, c *transport.Client, gql *Client, todoID string, iss Issue) (uploaded, skipped int, renamed map[string]string) {
	usedNames := map[string]bool{}
	renamed = map[string]string{}
	for _, asset := range issueAssets(iss) {
		name, content, err := downloadIssueAsset(ctx, gql, asset)
		if err != nil || len(content) == 0 {
			skipped++
			continue
		}
		name = uniqueAssetName(name, usedNames)
		if err := c.UploadTodoAttachment(ctx, todoID, name, content); err != nil {
			skipped++
			continue
		}
		renamed[asset.URL] = name
		uploaded++
	}
	return uploaded, skipped, renamed
}

// uploadAndRewrite uploads the issue's assets to the todo, then rewrites the
// body's image refs from the source URLs to the bare attachment names just
// created and PATCHes the body when anything changed.
func uploadAndRewrite(ctx context.Context, c *transport.Client, gql *Client, todoID, bodyMD string, iss Issue) (uploaded, skipped int, err error) {
	uploaded, skipped, renamed := uploadIssueAssets(ctx, c, gql, todoID, iss)
	if newBody := rewriteImageRefs(bodyMD, renamed); newBody != bodyMD {
		if _, err := c.PatchTodo(ctx, todoID, transport.TodoPatch{BodyMD: &newBody}); err != nil {
			return uploaded, skipped, fmt.Errorf("rewrite body: %w", err)
		}
	}
	return uploaded, skipped, nil
}

// rewriteImageRefs swaps `![alt](url)` image references for the bare attachment
// name each URL was uploaded under. Only image refs (leading `!`) are touched;
// plain `[text](url)` links keep their URL so they stay navigable.
func rewriteImageRefs(body string, renamed map[string]string) string {
	if len(renamed) == 0 {
		return body
	}
	return markdownURLRe.ReplaceAllStringFunc(body, func(m string) string {
		if !strings.HasPrefix(m, "!") {
			return m // image refs only; plain [text](url) links keep their URL
		}
		// m always matches markdownURLRe, so submatch[1] (the URL) is present.
		// Trim quotes the same way markdownURLs did when it built the keys, so a
		// quoted ref still resolves to its uploaded attachment.
		url := markdownURLRe.FindStringSubmatch(m)[1]
		name, ok := renamed[strings.Trim(url, `"'`)]
		if !ok {
			return m
		}
		return strings.Replace(m, url, name, 1)
	})
}

func uniqueAssetName(name string, used map[string]bool) string {
	if !used[name] {
		used[name] = true
		return name
	}
	ext := path.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	if stem == "" {
		stem = "linear-attachment"
	}
	for i := 2; ; i++ {
		candidate := fmt.Sprintf("%s-%d%s", stem, i, ext)
		if !used[candidate] {
			used[candidate] = true
			return candidate
		}
	}
}

func issueAssets(iss Issue) []IssueAsset {
	seen := map[string]bool{}
	var out []IssueAsset
	add := func(a IssueAsset) {
		a.URL = strings.TrimSpace(a.URL)
		if a.URL == "" || seen[a.URL] {
			return
		}
		seen[a.URL] = true
		out = append(out, a)
	}
	for _, a := range iss.Assets {
		add(a)
	}
	for _, u := range markdownURLs(iss.Description) {
		add(IssueAsset{URL: u})
	}
	for _, body := range iss.Comments {
		for _, u := range markdownURLs(body) {
			add(IssueAsset{URL: u})
		}
	}
	return out
}

func markdownURLs(s string) []string {
	var out []string
	for _, m := range markdownURLRe.FindAllStringSubmatch(s, -1) {
		if len(m) > 1 {
			out = append(out, strings.Trim(m[1], `"'`))
		}
	}
	return out
}

func downloadIssueAsset(ctx context.Context, gql *Client, asset IssueAsset) (string, []byte, error) {
	u, err := url.Parse(asset.URL)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return "", nil, fmt.Errorf("invalid url")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, asset.URL, nil)
	if err != nil {
		return "", nil, err
	}
	if strings.Contains(u.Host, "linear.app") {
		req.Header.Set("Authorization", gql.Token)
	}
	resp, err := gql.HTTP.Do(req)
	if err != nil {
		return "", nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return "", nil, fmt.Errorf("download %s: %s", asset.URL, resp.Status)
	}
	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	if strings.Contains(ct, "text/html") {
		return "", nil, fmt.Errorf("skip html")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, handoff.AttachmentMaxBytes+1))
	if err != nil {
		return "", nil, err
	}
	if len(body) > handoff.AttachmentMaxBytes {
		return "", nil, fmt.Errorf("attachment too large")
	}
	name := assetName(asset, ct)
	return name, body, nil
}

func assetName(asset IssueAsset, contentType string) string {
	if name := cleanAssetName(asset.Title); name != "" && path.Ext(name) != "" {
		return name
	}
	if u, err := url.Parse(asset.URL); err == nil {
		if base := cleanAssetName(path.Base(u.Path)); base != "" && base != "." && base != "/" {
			if path.Ext(base) == "" {
				base += extensionForContentType(contentType)
			}
			return base
		}
	}
	name := cleanAssetName(asset.Title)
	if name == "" {
		name = "linear-attachment"
	}
	return name + extensionForContentType(contentType)
}

func cleanAssetName(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Map(func(r rune) rune {
		switch r {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|':
			return '-'
		default:
			return r
		}
	}, s)
	rs := []rune(s)
	if len(rs) > 120 {
		s = string(rs[:120])
	}
	return strings.Trim(s, ". ")
}

func extensionForContentType(ct string) string {
	switch {
	case strings.Contains(ct, "image/png"):
		return ".png"
	case strings.Contains(ct, "image/jpeg"):
		return ".jpg"
	case strings.Contains(ct, "image/gif"):
		return ".gif"
	case strings.Contains(ct, "image/webp"):
		return ".webp"
	case strings.Contains(ct, "application/pdf"):
		return ".pdf"
	default:
		return ".bin"
	}
}

// mapIssueStatus maps Linear's state.type onto our (now Linear-shaped)
// Status — backlog/unstarted/completed/canceled each have a direct 1:1
// counterpart, unlike the old 6-value taxonomy where backlog and unstarted
// both had to compress onto the same "pending" bucket. Any unrecognized type
// (Linear adds new ones rarely, but schemas drift) falls back to triage
// rather than erroring the whole import — "needs a human to figure out what
// this is" is triage's actual purpose.
//
// The "started" type is the one exception to the clean 1:1 mapping: Linear's
// coarse type enum has no "review" category, so a team's custom "In Review"
// state is still type=started, indistinguishable from "In Progress" by type
// alone. So started disambiguates on the human-readable state.name (which
// GetTeamIssues already fetches into Issue.StateName) — a review-ish name maps
// to StatusInReview, everything else stays StatusInProgress. The other four
// types have no such intra-type ambiguity and ignore stateName entirely.
func mapIssueStatus(stateType, stateName string) todoschema.Status {
	switch stateType {
	case "backlog":
		return todoschema.StatusBacklog
	case "unstarted":
		return todoschema.StatusTodo
	case "started":
		if isReviewStateName(stateName) {
			return todoschema.StatusInReview
		}
		return todoschema.StatusInProgress
	case "completed":
		return todoschema.StatusDone
	case "canceled":
		return todoschema.StatusCanceled
	default:
		return todoschema.StatusTriage
	}
}

// isReviewStateName reports whether a Linear state.name denotes a review
// stage. It's only consulted when stateType=="started" (the only type that
// carries "same type, different meaning" ambiguity). The match is a
// case-insensitive "review" substring, which covers the common "In Review"
// and "Code Review" namings without guessing at team-specific conventions
// like "QA" or "Testing" that nobody has reported — deliberately under-
// matching rather than over-fitting. StatusDuplicate is intentionally out of
// scope: Linear has no native "duplicate" workflow state (duplicate is an
// issue-relation field, not something this function can see).
func isReviewStateName(name string) bool {
	return strings.Contains(strings.ToLower(name), "review")
}

// mapIssuePriority compresses Linear's own priority scale onto our
// low/normal/high. Linear's scale is NOT a plain ascending low→high range —
// it's 0=no priority, 1=urgent, 2=high, 3=medium, 4=low (urgent is the
// *lowest* number) — so the mapping mirrors that real semantics rather than
// splitting the 0-4 range in numeric order.
func mapIssuePriority(p int) todoschema.Priority {
	switch p {
	case 1, 2: // urgent, high
		return todoschema.PriorityHigh
	case 4: // low
		return todoschema.PriorityLow
	default: // 0 (no priority), 3 (medium), or anything unexpected
		return todoschema.PriorityNormal
	}
}

// composeBodyMD prepends a label line to description when Linear issue
// carries labels — there's no dedicated label field on todoschema.Todo (see
// the feature plan's explicitly-out-of-scope note), so labels live as the
// body's first line instead.
func composeBodyMD(labels []string, description string) string {
	if len(labels) == 0 {
		return description
	}
	return "🏷 " + strings.Join(labels, ", ") + "\n\n" + description
}

// matchAssigneeIdentity does a best-effort, case-insensitive match of a
// Linear assignee's email against the candidate identity pool (the caller
// plus, when importing into a team project, that project's members).
// Returns "" (no error) when nothing matches — an unmatched assignee simply
// leaves the todo unassigned, per the feature plan.
func matchAssigneeIdentity(candidates []string, email string) string {
	email = strings.TrimSpace(email)
	if email == "" {
		return ""
	}
	for _, id := range candidates {
		if strings.EqualFold(strings.TrimSpace(id), email) {
			return id
		}
	}
	return ""
}
