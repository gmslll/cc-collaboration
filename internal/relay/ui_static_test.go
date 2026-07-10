package relay_test

import (
	"os"
	"strings"
	"testing"
)

func TestProjectManageUIActionsAreRoleGated(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	required := []string{
		`const canManage = canManageOrganization(role);`,
		"${canManage ? `<button type=\"button\" data-unmap=",
		"${canManage ? `<form class=\"inline-form\" data-form=\"repo\">",
		`renderMemberTable(members, { canRemove: canManage, removeAttr: "data-remove-member", canChangeRole: canManage, roleAttr: "data-member-role", roles: ["member", "viewer", "owner"], label: "项目成员" })`,
		`${canManage ? memberCandidateForm("member", memberCandidates, ["member", "viewer", "owner"]) : ""}`,
	}
	for _, want := range required {
		if !strings.Contains(js, want) {
			t.Fatalf("project management UI is missing role gate fragment %q", want)
		}
	}
	forbidden := []string{
		`renderMemberTable(members, { canRemove: true, removeAttr: "data-remove-member", label: "项目成员" })`,
		`renderMemberTable(members, { canRemove: canManage, removeAttr: "data-remove-member", canChangeRole: true`,
		`${memberCandidateForm("member", memberCandidates, ["member", "viewer", "owner"])}`,
	}
	for _, bad := range forbidden {
		if strings.Contains(js, bad) {
			t.Fatalf("project management UI still renders ungated fragment %q", bad)
		}
	}
}

func TestMemberTableDoesNotRenderLastOwnerAsRemovable(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	start := strings.Index(js, "function renderMemberTable(members, options = {}) {")
	if start < 0 {
		t.Fatal("could not locate renderMemberTable function body")
	}
	end := strings.Index(js[start:], "\nfunction renderOrganizations()")
	if end < 0 {
		t.Fatal("could not locate renderMemberTable function body")
	}
	body := js[start : start+end]
	required := []string{
		`const ownerCount = members.filter((m) => roleKey(m.role) === "owner").length;`,
		`const isLastOwner = roleKey(m.role) === "owner" && ownerCount <= 1;`,
		`const removeBlockReasons = options.removeBlockReasons || {};`,
		`const removeDisabledReason = options.removeDisabledReason || "";`,
		`const removeBlockReason = isLastOwner ? "至少保留一个负责人" : removeDisabledReason || removeBlockReasons[identityKey(m.identity)] || "";`,
		`${isLastOwner ? ` + "`disabled title=\"至少保留一个负责人\"`" + ` : ""}>${roleSelectOptions(roleOptions, m.role)}</select>`,
		`disabled title="${escapeAttr(removeBlockReason)}"`,
		`aria-label="不能移除成员 ${escapeAttr(m.identity)}"`,
		": `<button type=\"button\" class=\"link-danger\" ${removeAttr}=\"${escapeAttr(m.identity)}\" aria-label=\"移除成员 ${escapeAttr(m.identity)}\">移除</button>`;",
	}
	for _, want := range required {
		if !strings.Contains(body, want) {
			t.Fatalf("member table is missing last-owner guard fragment %q", want)
		}
	}
}

func TestMemberRoleControlsAreRoleGated(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	required := []string{
		`els.projectsList.addEventListener("change", onProjectsListChange);`,
		`els.orgsList.addEventListener("change", onOrganizationsListChange);`,
		`const canChangeRole = Boolean(options.canChangeRole && roleAttr && roleOptions.length);`,
		"? `<select class=\"member-role-select\" ${roleAttr}=\"${escapeAttr(m.identity)}\" aria-label=\"更新成员 ${escapeAttr(m.identity)} 的角色\"",
		`const select = event.target.closest("[data-member-role]");`,
		`const select = event.target.closest("[data-org-member-role]");`,
		"await api(`/v1/projects/${encodeURIComponent(id)}/members`, { method: \"POST\", body: JSON.stringify({ identity, role }) });",
		"await api(`/v1/orgs/${encodeURIComponent(id)}/members`, { method: \"POST\", body: JSON.stringify({ identity, role }) });",
		`renderMemberTable(members, { canRemove: canManage, removeAttr: "data-remove-org-member", canChangeRole: canManage, roleAttr: "data-org-member-role", roles: ["member", "admin", "guest", "owner"], label: "团队成员", removeBlockReasons: removalGuards.removeBlockReasons, removeDisabledReason: removalGuards.removeDisabledReason })`,
		`renderMemberTable(members, { canRemove: canManage, removeAttr: "data-remove-member", canChangeRole: canManage, roleAttr: "data-member-role", roles: ["member", "viewer", "owner"], label: "项目成员" })`,
	}
	for _, want := range required {
		if !strings.Contains(js, want) {
			t.Fatalf("member role controls are missing gated fragment %q", want)
		}
	}
}

func TestMemberTableKeepsMobileCellLabels(t *testing.T) {
	jsBytes, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	cssBytes, err := os.ReadFile("ui/styles.css")
	if err != nil {
		t.Fatal(err)
	}
	js := string(jsBytes)
	css := string(cssBytes)
	requiredJS := []string{
		`<span class="member-person" role="cell" data-label="成员">`,
		`<span class="member-role" role="cell" data-label="角色">${roleControl}</span>`,
		`<span class="member-state" role="cell" data-label="状态">${memberPresence(m.identity)}<span class="member-state-text">${online ? "在线" : "离线"}</span></span>`,
		`<span class="member-actions" role="cell" data-label="操作">${removeButton}</span>`,
	}
	for _, want := range requiredJS {
		if !strings.Contains(js, want) {
			t.Fatalf("member table is missing mobile cell label markup %q", want)
		}
	}
	requiredCSS := []string{
		`.member-table-row [role="cell"][data-label] {`,
		`grid-template-columns: 72px minmax(0, 1fr);`,
		`.member-table-row [role="cell"][data-label]::before {`,
		`content: attr(data-label);`,
		`.member-state[role="cell"][data-label] {`,
		`grid-template-columns: 72px auto minmax(0, 1fr);`,
		`.member-state-text {`,
		`.member-person[role="cell"][data-label] .member-identity,`,
	}
	for _, want := range requiredCSS {
		if !strings.Contains(css, want) {
			t.Fatalf("member table is missing mobile cell label CSS %q", want)
		}
	}
}

func TestRelayUIIdentityComparisonsAreTrimmed(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	required := []string{
		`function identityKey(identity) {`,
		`return String(identity || "").trim();`,
		`return Boolean(id && state.online.some((user) => identityKey(user.identity) === id && user.online));`,
		`const existing = new Set(existingMembers.map((m) => identityKey(m.identity)).filter(Boolean));`,
		`return identity && !existing.has(identity);`,
		`identity: identityKey(user.identity), display_name: user.online ? "在线" : "离线"`,
		`removeBlockReasons[identityKey(m.identity)]`,
		`const identity = identityKey(owners[0].identity);`,
		`const projectMemberIDs = new Set(members.map((m) => identityKey(m.identity)).filter(Boolean));`,
	}
	for _, want := range required {
		if !strings.Contains(js, want) {
			t.Fatalf("relay UI identity comparison is missing trim fragment %q", want)
		}
	}
}

func TestRoleLabelsAreLocalizedInManagementUI(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	required := []string{
		`function roleKey(role) {`,
		`return String(role || "").trim();`,
		`function roleLabel(role, scope = "team") {`,
		`const value = roleKey(role);`,
		`if (value === "owner") return "负责人";`,
		`if (value === "admin") return "管理员";`,
		`if (value === "viewer") return "只读";`,
		`if (value === "guest") return "访客";`,
		`const current = roleKey(currentRole);`,
		`${escapeHTML(roleLabel(role, "team"))}`,
		`${metricTile("你的角色", roleLabel(role, "team"))}`,
		`${escapeHTML(roleLabel(role, "project"))}`,
		`${escapeHTML(roleLabel(m.role, roleOptions.includes("viewer") ? "project" : "team"))}`,
	}
	for _, want := range required {
		if !strings.Contains(js, want) {
			t.Fatalf("management UI is missing localized role label fragment %q", want)
		}
	}
	if strings.Contains(js, `<span class="badge">${escapeHTML(role)}</span>`) {
		t.Fatal("management UI still renders raw role badge text")
	}
	if strings.Contains(js, `>${escapeHTML(role)}</option>`) {
		t.Fatal("management UI still renders raw role option text")
	}
}

func TestRelayUIChromeUsesLocalizedTeamCopy(t *testing.T) {
	htmlBytes, err := os.ReadFile("ui/index.html")
	if err != nil {
		t.Fatal(err)
	}
	jsBytes, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	html := string(htmlBytes)
	js := string(jsBytes)
	requiredHTML := []string{
		`<html lang="zh-CN">`,
		`data-view="organizations">团队</button>`,
		`data-view="projects">项目</button>`,
		`data-view="account">账号</button>`,
		`data-view="admin">管理</button>`,
		`data-view="workspaces">工作区</button>`,
		`<h2 id="list-title">收件箱</h2>`,
		`<h2>选择一个 handoff</h2>`,
		`<span>状态</span>`,
		`<h3 id="comments-title">评论</h3>`,
		`<h2 id="orgs-title">团队</h2>`,
		`负责人/管理员可邀请成员。`,
	}
	for _, want := range requiredHTML {
		if !strings.Contains(html, want) {
			t.Fatalf("relay UI html is missing localized copy %q", want)
		}
	}
	requiredJS := []string{
		`els.onlineCount.textContent = ` + "`${online} 在线`" + `;`,
		"els.onlineList.innerHTML = `<p class=\"muted\">暂无已知用户。</p>`;",
		"els.commentsList.innerHTML = `<p class=\"muted\">还没有评论。</p>`;",
		`if (view === "sender") return "已发送";`,
		`if (view === "project") return state.projectID ? ` + "`项目 · ${currentProjectLabel()}`" + ` : "项目 handoff";`,
		`const base = ` + "`显示 ${shown} 条，共加载 ${loaded} 条`" + `;`,
		`return org?.name || id || "默认团队";`,
		`负责人 · ${escapeHTML(org.owner_identity || "-")} · ${escapeHTML(org.id)}`,
	}
	for _, want := range requiredJS {
		if !strings.Contains(js, want) {
			t.Fatalf("relay UI js is missing localized copy %q", want)
		}
	}
}

func TestRelayUIDisplaysDeliveryTarget(t *testing.T) {
	htmlBytes, err := os.ReadFile("ui/index.html")
	if err != nil {
		t.Fatal(err)
	}
	jsBytes, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	cssBytes, err := os.ReadFile("ui/styles.css")
	if err != nil {
		t.Fatal(err)
	}
	html := string(htmlBytes)
	js := string(jsBytes)
	css := string(cssBytes)
	requiredHTML := []string{
		`<div id="delivery-target" class="delivery-target hidden"></div>`,
	}
	for _, want := range requiredHTML {
		if !strings.Contains(html, want) {
			t.Fatalf("relay UI html is missing delivery target fragment %q", want)
		}
	}
	requiredJS := []string{
		`deliveryTarget: document.querySelector("#delivery-target"),`,
		`renderDeliveryTarget(pkg.delivery_target);`,
		`["Delivery Target", deliveryTargetLabel(pkg.delivery_target)],`,
		`function renderDeliveryTarget(target) {`,
		`function deliveryTargetParts(target) {`,
		`const clean = String(value || "").trim();`,
		`add("项目", target.project_id);`,
		`add("团队", target.org_id);`,
		`add("指定成员", target.member);`,
		`function deliveryTargetLabel(target) {`,
	}
	for _, want := range requiredJS {
		if !strings.Contains(js, want) {
			t.Fatalf("relay UI js is missing delivery target fragment %q", want)
		}
	}
	requiredCSS := []string{
		`.delivery-target {`,
		`.delivery-target-title {`,
		`.delivery-target-items {`,
		`.delivery-target-items span {`,
		`text-overflow: ellipsis;`,
	}
	for _, want := range requiredCSS {
		if !strings.Contains(css, want) {
			t.Fatalf("relay UI css is missing delivery target fragment %q", want)
		}
	}
}

func TestRelayUIProjectCardsShowTeamContext(t *testing.T) {
	jsBytes, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	cssBytes, err := os.ReadFile("ui/styles.css")
	if err != nil {
		t.Fatal(err)
	}
	js := string(jsBytes)
	css := string(cssBytes)
	requiredJS := []string{
		`const teamName = organizationName(p.org_id);`,
		`<div class="aux-card project-card" data-project="${escapeAttr(p.id)}">`,
		`<div class="project-title">`,
		`<span class="badge soft">${escapeHTML(teamName)}</span>`,
		`<div class="muted project-meta">团队 · ${escapeHTML(teamName)} · 负责人 · ${escapeHTML(p.owner_identity || "-")} · ${escapeHTML(p.id)}</div>`,
	}
	for _, want := range requiredJS {
		if !strings.Contains(js, want) {
			t.Fatalf("relay UI project cards are missing team context fragment %q", want)
		}
	}
	requiredCSS := []string{
		`.project-title,`,
		`.project-meta {`,
		`.project-card .aux-card-head {`,
		`font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;`,
	}
	for _, want := range requiredCSS {
		if !strings.Contains(css, want) {
			t.Fatalf("relay UI project cards are missing team context CSS %q", want)
		}
	}
}

func TestAdminAccountsUIUsesLocalizedStatusCopy(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	required := []string{
		`<span class="badge">系统管理员</span>`,
		`<span class="badge warning">已停用</span>`,
		`<span class="badge success">已启用</span>`,
		`u.is_admin ? "取消管理员" : "授予管理员"`,
	}
	for _, want := range required {
		if !strings.Contains(js, want) {
			t.Fatalf("admin account UI is missing localized status copy %q", want)
		}
	}
	if strings.Contains(js, `<span class="badge">admin</span>`) {
		t.Fatal("admin account UI still renders raw admin badge text")
	}
	if strings.Contains(js, `<span class="badge expired">disabled</span>`) {
		t.Fatal("admin account UI still renders raw disabled badge text")
	}
}

func TestAdminAccountsUIProvidesGuardedDelete(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	required := []string{
		`<span class="badge expired">已删除</span>`,
		`data-uaction="delete"`,
		`title="不能删除当前登录账号"`,
		`window.confirm(` + "`确定删除账号 ${id}？",
		`该 identity 不能重新注册，所有登录和机器 token 会立即失效。`,
		`state.pendingUserActions.add(id);`,
		"await api(`/v1/users/${encodeURIComponent(id)}`, { method: \"DELETE\" });",
		`state.pendingUserActions.delete(id);`,
	}
	for _, want := range required {
		if !strings.Contains(js, want) {
			t.Fatalf("admin account UI is missing delete-state fragment %q", want)
		}
	}
}

func TestAdminAccountsUIProtectsCurrentAdminRoleAndStatus(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	for _, want := range []string{
		`disabled title="不能取消当前账号管理员"`,
		`disabled title="不能停用当前账号"`,
		`id === state.me?.identity && (action === "admin" || action === "disable" || action === "delete")`,
	} {
		if !strings.Contains(js, want) {
			t.Fatalf("admin UI missing current-account guard %q", want)
		}
	}
}

func TestAdminAccountsUIFiltersTombstoneArchive(t *testing.T) {
	jsBytes, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	htmlBytes, err := os.ReadFile("ui/index.html")
	if err != nil {
		t.Fatal(err)
	}
	cssBytes, err := os.ReadFile("ui/styles.css")
	if err != nil {
		t.Fatal(err)
	}
	js := string(jsBytes)
	html := string(htmlBytes)
	css := string(cssBytes)
	for _, want := range []string{
		`adminUserView: "active"`,
		`adminUserQuery: ""`,
		`adminUserStatus: "all"`,
		`state.adminUserView = button.dataset.adminUserView;`,
		`state.adminUserQuery = els.adminUserSearch.value;`,
		`state.adminUserStatus = els.adminUserStatus.value;`,
		`const showDeleted = state.adminUserView === "deleted";`,
		`if (Boolean(u.deleted) !== showDeleted) return false;`,
		`if (query && !identity.includes(query) && !displayName.includes(query)) return false;`,
		`return state.adminUserStatus === "disabled" ? Boolean(u.disabled) : !u.disabled;`,
		`els.adminUserStatusWrap.classList.toggle("hidden", showDeleted);`,
		`const actions = u.deleted`,
		`? ""`,
		`? { ...u, is_admin: false, disabled: true, deleted: true }`,
		`renderUsers(state.adminUsers);`,
	} {
		if !strings.Contains(js, want) {
			t.Fatalf("relay admin archive UI is missing behavior fragment %q", want)
		}
	}
	for _, want := range []string{
		`id="open-create-user"`,
		`id="admin-user-search"`,
		`id="admin-user-tabs"`,
		`data-admin-user-view="active"`,
		`data-admin-user-view="deleted"`,
		`role="tab" aria-selected="true">现有账号</button>`,
		`role="tab" aria-selected="false">已删除</button>`,
		`id="admin-user-status"`,
		`<option value="enabled">启用</option>`,
		`<option value="disabled">停用</option>`,
		`<dialog id="create-user-dialog"`,
		`<form id="new-user-form">`,
	} {
		if !strings.Contains(html, want) {
			t.Fatalf("relay admin account UI is missing toolbar/dialog markup %q", want)
		}
	}
	adminStart := strings.Index(html, `<section id="admin-pane"`)
	if adminStart < 0 {
		t.Fatal("relay admin account UI is missing admin pane")
	}
	adminEndOffset := strings.Index(html[adminStart:], `</section>`)
	if adminEndOffset < 0 {
		t.Fatal("relay admin account UI has an unterminated admin pane")
	}
	adminPane := html[adminStart : adminStart+adminEndOffset]
	if strings.Contains(adminPane, `id="new-user-form"`) {
		t.Fatal("relay admin account UI still renders the create form permanently in the admin pane")
	}
	for _, want := range []string{
		`.admin-user-toolbar {`,
		`.admin-user-search {`,
		`.admin-user-tabs {`,
		`display: inline-flex;`,
		`.admin-user-tab.active {`,
		`min-height: 28px;`,
		`.admin-user-row {`,
		`grid-template-columns: minmax(240px, 5fr) minmax(108px, 2fr) minmax(96px, 2fr) 38px;`,
		`min-height: 58px;`,
		`.admin-user-menu {`,
		`.admin-create-dialog {`,
		`@media (max-width: 700px) {`,
		`grid-template-rows: auto auto;`,
		`min-height: 72px;`,
	} {
		if !strings.Contains(css, want) {
			t.Fatalf("relay admin account UI is missing dense responsive style %q", want)
		}
	}
	for _, want := range []string{
		`els.createUserDialog.showModal();`,
		`setCreateUserPending(true);`,
		`els.createUserDialog.close();`,
		`setCreateUserPending(false);`,
	} {
		if !strings.Contains(js, want) {
			t.Fatalf("relay admin account UI is missing create dialog behavior %q", want)
		}
	}
}

func TestAdminAccountsUIInvalidatesStaleAuthAndManagesActionMenus(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	for _, want := range []string{
		`authEpoch: 0`,
		`if (next !== state.token) invalidateAuthContext();`,
		`function invalidateAuthContext() {`,
		`state.authEpoch += 1;`,
		`state.pendingUserActions.clear();`,
		`if (els.createUserDialog.open) els.createUserDialog.close();`,
		`function authRequestCurrent(epoch) {`,
		`if (!authRequestCurrent(authEpoch)) return;`,
		`async function copyToClipboardForAuth(text, message, authEpoch) {`,
		`if (authRequestCurrent(authEpoch)) toast(message);`,
		`await copyToClipboardForAuth(data.password,`,
		`if (authRequestCurrent(authEpoch)) setCreateUserPending(false);`,
		`els.usersList.addEventListener("toggle", onAdminUserMenuToggle, true);`,
		`if (!event.target.closest?.(".admin-user-menu")) closeAdminUserMenus();`,
		`if (event.key === "Escape") closeAdminUserMenus();`,
		`function closeAdminUserMenus(except = null) {`,
		`details.admin-user-menu[open]`,
		`closeAdminUserMenus(menu);`,
	} {
		if !strings.Contains(js, want) {
			t.Fatalf("relay admin account UI is missing stale-auth/menu guard %q", want)
		}
	}
}

func TestOrganizationManageUIProtectsProjectSoleOwners(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	required := []string{
		`async function organizationMemberRemovalGuards(projects = []) {`,
		`const owners = members.filter((m) => roleKey(m.role) === "owner");`,
		`if (owners.length === 1) {`,
		`removeBlockReasons[identity] = ` + "`先转移项目负责人: ${names.join(\", \")}`" + `;`,
		`removeDisabledReason: uncheckedProjectNames.length ? projectOwnerGuardMessage(uncheckedProjectNames) : "",`,
		`${inlineWarning(removalGuards.removeDisabledReason)}`,
	}
	for _, want := range required {
		if !strings.Contains(js, want) {
			t.Fatalf("organization management UI is missing project-owner guard fragment %q", want)
		}
	}
}

func TestProjectRolePrefersFreshProjectListRole(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	start := strings.Index(js, "function projectRole(id) {")
	if start < 0 {
		t.Fatal("could not locate projectRole function body")
	}
	end := strings.Index(js[start:], "\nfunction renderProjects()")
	if end < 0 {
		t.Fatal("could not locate projectRole function body")
	}
	body := js[start : start+end]
	required := []string{
		`const project = (state.projects || []).find((pr) => pr.id === id);`,
		`if (roleKey(project?.role)) return roleKey(project.role);`,
		`const p = (state.me?.projects || []).find((pr) => pr.id === id);`,
		`return state.me?.is_admin ? "admin" : "viewer";`,
	}
	for _, want := range required {
		if !strings.Contains(body, want) {
			t.Fatalf("projectRole is missing freshness/safe-fallback fragment %q", want)
		}
	}
	if strings.Contains(body, `return state.me?.is_admin ? "admin" : "member";`) {
		t.Fatal("projectRole still falls back to editable-looking member role for unknown projects")
	}
}

func TestOrganizationRolePrefersFreshOrganizationListRole(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	start := strings.Index(js, "function organizationRole(id) {")
	if start < 0 {
		t.Fatal("could not locate organizationRole function body")
	}
	end := strings.Index(js[start:], "\nfunction organizationName(id)")
	if end < 0 {
		t.Fatal("could not locate organizationRole function body")
	}
	body := js[start : start+end]
	required := []string{
		`const fresh = (state.organizations || []).find((o) => o.id === id);`,
		`if (roleKey(fresh?.role)) return roleKey(fresh.role);`,
		`const org = (state.me?.organizations || []).find((o) => o.id === id);`,
	}
	for _, want := range required {
		if !strings.Contains(body, want) {
			t.Fatalf("organizationRole is missing freshness fragment %q", want)
		}
	}
	if strings.Index(body, `state.me?.organizations`) < strings.Index(body, `state.organizations`) {
		t.Fatal("organizationRole checks stale me.organizations before fresh state.organizations")
	}
}

func TestRelayUIBuildsHandoffListQueryWithURLSearchParams(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	start := strings.Index(js, "async function loadList() {")
	if start < 0 {
		t.Fatal("could not locate loadList function body")
	}
	end := strings.Index(js[start:], "\nasync function loadOnline()")
	if end < 0 {
		t.Fatal("could not locate loadList function body")
	}
	body := js[start : start+end]
	required := []string{
		`const q = new URLSearchParams({ limit: els.limitSelect.value });`,
		`q.set("scope", "project");`,
		`q.set("project", state.projectID);`,
		`q.set("scope", "all");`,
		`q.set("as", state.view);`,
		"await api(`/v1/handoffs?${q.toString()}`);",
	}
	for _, want := range required {
		if !strings.Contains(body, want) {
			t.Fatalf("loadList is missing structured query fragment %q", want)
		}
	}
	forbidden := []string{
		"`scope=project&project=${encodeURIComponent(state.projectID)}`",
		"`as=${encodeURIComponent(state.view)}`",
		"`/v1/handoffs?${q}&limit=${limit}`",
	}
	for _, bad := range forbidden {
		if strings.Contains(body, bad) {
			t.Fatalf("loadList still contains hand-built query fragment %q", bad)
		}
	}
}
