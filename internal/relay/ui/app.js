// Desktop mode is detected by the presence of the Lorca-bound function.
// Lorca's Page.addScriptToEvaluateOnNewDocument re-binds on every navigation,
// so window.ccHandoffPickup survives Cmd-R / DevTools reloads — using it as
// the mode signal means dataset.mode is correct on every render without
// needing to persist anything in localStorage.
if (typeof window.ccHandoffPickup === "function") {
  document.documentElement.dataset.mode = "desktop";
}

// Workspaces are a local concept: the relay never sees local paths. The
// desktop subcommand pre-injects the list into localStorage (see desktop.go).
// In plain browser mode there's no injection, so the list is empty and the tab
// stays hidden — it degrades cleanly.
const state = {
  token: localStorage.getItem("cc-handoff-token") || "",
  defaultRepo: localStorage.getItem("cc-handoff-default-repo") || "",
  me: null, // { identity, is_admin, organizations: [{id,name,role}], projects: [{id,name,role}] }
  organizations: [], // loaded in the Teams pane (GET /v1/orgs)
  projects: [], // loaded in the Projects pane (GET /v1/projects)
  preferredProjectOrgID: "",
  projectID: "", // selected project for the scope=project handoff view
  projectLabel: "",
  view: "recipient",
  items: [],
  selectedID: "",
  selectedPackage: null,
  selectedStatus: null,
  comments: [],
  promptText: "",
  online: [],
  workspaces: parseWorkspaces(localStorage.getItem("cc-handoff-workspaces")),
};

function parseWorkspaces(raw) {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

const els = {
  loginForm: document.querySelector("#login-form"),
  loginIdentity: document.querySelector("#login-identity"),
  loginPassword: document.querySelector("#login-password"),
  registerButton: document.querySelector("#register-button"),
  tokenConnect: document.querySelector("#token-connect"),
  signoutButton: document.querySelector("#signout-button"),
  tokenInput: document.querySelector("#token-input"),
  authMessage: document.querySelector("#auth-message"),
  sessionLabel: document.querySelector("#session-label"),
  tabOrgs: document.querySelector("#tab-orgs"),
  tabProjects: document.querySelector("#tab-projects"),
  tabAccount: document.querySelector("#tab-account"),
  tabAdmin: document.querySelector("#tab-admin"),
  orgsPane: document.querySelector("#orgs-pane"),
  orgsList: document.querySelector("#orgs-list"),
  newOrgForm: document.querySelector("#new-org-form"),
  newOrgName: document.querySelector("#new-org-name"),
  projectsPane: document.querySelector("#projects-pane"),
  projectsList: document.querySelector("#projects-list"),
  newProjectForm: document.querySelector("#new-project-form"),
  newProjectName: document.querySelector("#new-project-name"),
  newProjectOrg: document.querySelector("#new-project-org"),
  accountPane: document.querySelector("#account-pane"),
  passwordForm: document.querySelector("#password-form"),
  passwordOld: document.querySelector("#password-old"),
  passwordNew: document.querySelector("#password-new"),
  newTokenForm: document.querySelector("#new-token-form"),
  newTokenLabel: document.querySelector("#new-token-label"),
  tokensList: document.querySelector("#tokens-list"),
  adminPane: document.querySelector("#admin-pane"),
  newUserForm: document.querySelector("#new-user-form"),
  newUserIdentity: document.querySelector("#new-user-identity"),
  newUserPassword: document.querySelector("#new-user-password"),
  newUserAdmin: document.querySelector("#new-user-admin"),
  usersList: document.querySelector("#users-list"),
  refreshButton: document.querySelector("#refresh-button"),
  tabs: document.querySelectorAll(".tab-button"),
  searchInput: document.querySelector("#search-input"),
  limitSelect: document.querySelector("#limit-select"),
  listTitle: document.querySelector("#list-title"),
  listMeta: document.querySelector("#list-meta"),
  handoffList: document.querySelector("#handoff-list"),
  onlineCount: document.querySelector("#online-count"),
  onlineList: document.querySelector("#online-list"),
  emptyState: document.querySelector("#empty-state"),
  detailView: document.querySelector("#detail-view"),
  detailBadges: document.querySelector("#detail-badges"),
  detailTitle: document.querySelector("#detail-title"),
  detailSubtitle: document.querySelector("#detail-subtitle"),
  pickupButton: document.querySelector("#pickup-button"),
  ackButton: document.querySelector("#ack-button"),
  reassignButton: document.querySelector("#reassign-button"),
  retractButton: document.querySelector("#retract-button"),
  reassignDialog: document.querySelector("#reassign-dialog"),
  reassignForm: document.querySelector("#reassign-form"),
  reassignTarget: document.querySelector("#reassign-target"),
  reassignReason: document.querySelector("#reassign-reason"),
  reassignContext: document.querySelector("#reassign-context"),
  reassignCancel: document.querySelector("#reassign-cancel"),
  statusState: document.querySelector("#status-state"),
  statusCreated: document.querySelector("#status-created"),
  statusComments: document.querySelector("#status-comments"),
  statusPicked: document.querySelector("#status-picked"),
  recipientSlots: document.querySelector("#recipient-slots"),
  summaryContent: document.querySelector("#summary-content"),
  copySummaryButton: document.querySelector("#copy-summary-button"),
  metadataList: document.querySelector("#metadata-list"),
  apiDeltaPanel: document.querySelector("#api-delta-panel"),
  apiDeltaContent: document.querySelector("#api-delta-content"),
  promptPanel: document.querySelector("#prompt-panel"),
  promptContent: document.querySelector("#prompt-content"),
  copyPromptButton: document.querySelector("#copy-prompt-button"),
  copyPickupCmdButton: document.querySelector("#copy-pickup-cmd-button"),
  commentsList: document.querySelector("#comments-list"),
  reloadCommentsButton: document.querySelector("#reload-comments-button"),
  commentForm: document.querySelector("#comment-form"),
  commentInput: document.querySelector("#comment-input"),
  toast: document.querySelector("#toast"),
  listPane: document.querySelector(".list-pane"),
  detailPane: document.querySelector(".detail-pane"),
  workspacesTab: document.querySelector("#tab-workspaces"),
  workspacesPane: document.querySelector("#workspaces-pane"),
  workspacesMeta: document.querySelector("#workspaces-meta"),
  workspaceList: document.querySelector("#workspace-list"),
};

setConnectedLabel();
setupWorkspacesTab();
wireEvents();
renderList();
if (state.token) {
  onConnected();
}

// The Workspaces tab only makes sense in desktop mode (the only place the list
// gets injected). Hide it entirely otherwise.
function setupWorkspacesTab() {
  const available = state.workspaces.length > 0;
  els.workspacesTab.classList.toggle("hidden", !available);
}

function wireEvents() {
  els.loginForm.addEventListener("submit", onLogin);
  els.registerButton.addEventListener("click", onRegister);
  els.tokenConnect.addEventListener("click", onUseToken);
  els.signoutButton.addEventListener("click", onSignout);
  els.newOrgForm.addEventListener("submit", onCreateOrganization);
  els.newProjectForm.addEventListener("submit", onCreateProject);
  els.passwordForm.addEventListener("submit", onChangePassword);
  els.newTokenForm.addEventListener("submit", onCreateToken);
  els.newUserForm.addEventListener("submit", onCreateUser);
  els.projectsList.addEventListener("click", onProjectsListClick);
  els.projectsList.addEventListener("submit", onProjectsListSubmit);
  els.orgsList.addEventListener("click", onOrganizationsListClick);
  els.orgsList.addEventListener("submit", onOrganizationsListSubmit);
  els.tokensList.addEventListener("click", onTokensListClick);
  els.usersList.addEventListener("click", onUsersListClick);

  els.refreshButton.addEventListener("click", refreshAll);
  els.limitSelect.addEventListener("change", refreshAll);
  els.searchInput.addEventListener("input", renderList);

  els.tabs.forEach((button) => {
    button.addEventListener("click", () => switchView(button.dataset.view));
  });

  els.workspaceList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-launch]");
    if (!button) return;
    const ws = state.workspaces[Number(button.dataset.launch)];
    if (ws) copyToClipboard(ws.command, "启动命令已复制，去终端粘贴执行");
  });

  els.handoffList.addEventListener("click", (event) => {
    const row = event.target.closest("[data-id]");
    if (!row) return;
    selectHandoff(row.dataset.id);
  });

  els.pickupButton.addEventListener("click", onPickup);

  els.ackButton.addEventListener("click", async () => {
    if (!state.selectedID) return;
    await api(`/v1/handoffs/${encodeURIComponent(state.selectedID)}/ack`, { method: "POST" });
    toast("已标记为已接收");
    await refreshSelected();
    await loadList();
  });

  els.retractButton.addEventListener("click", async () => {
    if (!state.selectedID) return;
    const reason = window.prompt("撤回原因（可选）", "");
    if (reason === null) return;
    await api(`/v1/handoffs/${encodeURIComponent(state.selectedID)}/retract`, {
      method: "POST",
      body: JSON.stringify({ reason }),
    });
    toast("已撤回");
    await refreshSelected();
    await loadList();
  });

  els.reassignButton.addEventListener("click", openReassignDialog);
  els.reassignCancel.addEventListener("click", () => els.reassignDialog.close());
  els.reassignForm.addEventListener("submit", submitReassign);

  els.copySummaryButton.addEventListener("click", () => {
    copyToClipboard(els.summaryContent.textContent || "", "摘要已复制");
  });

  els.copyPromptButton.addEventListener("click", () => {
    if (!state.promptText) {
      toast("Prompt 尚未加载");
      return;
    }
    copyToClipboard(state.promptText, "Prompt 已复制，去 Claude / Codex 粘贴即可");
  });

  els.copyPickupCmdButton.addEventListener("click", () => {
    if (!state.selectedID) return;
    copyToClipboard(`cc-handoff pickup ${state.selectedID}`, "CLI 命令已复制，去终端粘贴执行");
  });

  els.reloadCommentsButton.addEventListener("click", loadComments);

  els.commentForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const body = els.commentInput.value.trim();
    if (!body || !state.selectedID) return;
    await api(`/v1/handoffs/${encodeURIComponent(state.selectedID)}/comment`, {
      method: "POST",
      body: JSON.stringify({ body }),
    });
    els.commentInput.value = "";
    toast("评论已发送");
    await loadComments();
    await refreshSelected();
  });
}

async function onPickup() {
  if (!state.selectedID) return;
  // Desktop fork-exec via Lorca Bind; browser mode falls back to clipboard.
  if (typeof window.ccHandoffPickup === "function") {
    els.pickupButton.disabled = true;
    toast("正在 pickup…");
    try {
      const out = await window.ccHandoffPickup(state.selectedID, state.defaultRepo || "");
      toast(`接收完成\n${out.split("\n")[0]}`);
      await refreshSelected();
      await loadList();
    } catch (err) {
      toast(`接收失败：${err.message || err}`);
    } finally {
      els.pickupButton.disabled = false;
    }
    return;
  }
  copyToClipboard(`cc-handoff pickup ${state.selectedID}`, "已复制 CLI 命令到剪贴板，去终端粘贴执行");
}

async function openReassignDialog() {
  if (!state.selectedID) return;
  const pkg = state.selectedPackage;
  if (!pkg) return;

  els.reassignContext.textContent = `当前 handoff：${pkg.id}　·　bug group：${pkg.bug_group_id || "-"}`;

  let onlineUsers = state.online;
  if (!onlineUsers.length) {
    try {
      const data = await api("/v1/users/online");
      onlineUsers = data.users || [];
    } catch (err) {
      toast(`无法加载在线列表：${err.message}`);
      return;
    }
  }

  const participants = new Set([
    pkg.sender || "",
    pkg.recipient || "",
    ...(pkg.recipients || []),
  ]);
  const candidates = onlineUsers.filter((u) => !participants.has(u.identity));

  els.reassignTarget.innerHTML = "";
  if (!candidates.length) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "（无可用目标）";
    opt.disabled = true;
    opt.selected = true;
    els.reassignTarget.append(opt);
  } else {
    candidates.forEach((u) => {
      const opt = document.createElement("option");
      opt.value = u.identity;
      opt.textContent = `${u.identity}${u.online ? "（在线）" : "（离线）"}`;
      els.reassignTarget.append(opt);
    });
  }
  els.reassignReason.value = "";
  els.reassignDialog.showModal();
}

async function submitReassign(event) {
  event.preventDefault();
  if (!state.selectedID) return;
  const to = els.reassignTarget.value.trim();
  const reason = els.reassignReason.value.trim();
  if (!to || !reason) {
    toast("请选择目标并填写原因");
    return;
  }
  try {
    const result = await api(`/v1/handoffs/${encodeURIComponent(state.selectedID)}/reassign`, {
      method: "POST",
      body: JSON.stringify({ to, reason }),
    });
    els.reassignDialog.close();
    toast(`已转交给 ${result.reassigned_to}，新 id ${result.id}`);
    await refreshSelected();
    await loadList();
  } catch (err) {
    toast(`转交失败：${err.message}`);
  }
}

async function refreshAll() {
  if (!state.token) {
    state.items = [];
    renderList();
    renderOnline([]);
    return;
  }
  if (state.view === "organizations") {
    await Promise.allSettled([loadOnline(), loadOrganizations()]);
    return;
  }
  if (state.view === "projects") {
    await Promise.allSettled([loadOnline(), loadProjects()]);
    return;
  }
  if (state.view === "account") return loadAccount();
  if (state.view === "admin") return loadAdmin();
  if (state.view === "workspaces") return renderWorkspaces();
  await Promise.allSettled([loadOnline(), loadList()]);
}

async function loadList() {
  try {
    const limit = encodeURIComponent(els.limitSelect.value);
    let q;
    if (state.view === "project" && state.projectID) {
      q = `scope=project&project=${encodeURIComponent(state.projectID)}`;
    } else if (state.view === "all") {
      q = "scope=all";
    } else {
      q = `as=${encodeURIComponent(state.view)}`;
    }
    const data = await api(`/v1/handoffs?${q}&limit=${limit}`);
    state.items = data.items || [];
    renderList();
  } catch (err) {
    authError(err);
  }
}

async function loadOnline() {
  try {
    const data = await api("/v1/users/online");
    state.online = data.users || [];
    renderOnline(state.online);
  } catch (err) {
    authError(err);
  }
}

async function selectHandoff(id) {
  state.selectedID = id;
  renderList();
  await refreshSelected();
}

async function refreshSelected() {
  if (!state.selectedID) {
    renderDetail();
    return;
  }
  try {
    const id = encodeURIComponent(state.selectedID);
    const [pkg, status, commentsData, promptText] = await Promise.all([
      api(`/v1/handoffs/${id}`),
      api(`/v1/handoffs/${id}/status`),
      api(`/v1/handoffs/${id}/comments`),
      api(`/v1/handoffs/${id}/prompt`, { expectText: true }).catch(() => ""),
    ]);
    state.selectedPackage = pkg;
    state.selectedStatus = status;
    state.comments = commentsData.comments || [];
    state.promptText = promptText;
    renderDetail();
  } catch (err) {
    toast(err.message);
  }
}

async function loadComments() {
  if (!state.selectedID) return;
  try {
    const data = await api(`/v1/handoffs/${encodeURIComponent(state.selectedID)}/comments`);
    state.comments = data.comments || [];
    renderComments();
  } catch (err) {
    toast(err.message);
  }
}

async function api(path, options = {}) {
  if (!state.token) {
    throw new Error("Missing relay token.");
  }
  const headers = new Headers(options.headers || {});
  headers.set("Authorization", `Bearer ${state.token}`);
  if (options.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const resp = await fetch(path, { ...options, headers });
  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(body.trim() || `${resp.status} ${resp.statusText}`);
  }
  if (resp.status === 204) return null;
  const text = await resp.text();
  if (options.expectText) return text;
  return text ? JSON.parse(text) : null;
}

async function copyToClipboard(text, message) {
  try {
    await navigator.clipboard.writeText(text);
    toast(message);
  } catch (err) {
    toast(`复制失败：${err.message || err}`);
  }
}

function renderList() {
  const title = viewTitle(state.view);
  els.listTitle.textContent = title;
  const query = els.searchInput.value.trim().toLowerCase();
  const items = state.items.filter((item) => haystack(item).includes(query));
  els.listMeta.textContent = state.token
    ? listMetaLabel(items.length, state.items.length)
    : "Connect to load handoffs.";

  if (!items.length) {
    els.handoffList.innerHTML = `<div class="empty-list">${escapeHTML(state.token ? "No handoffs match this view." : "No token configured.")}</div>`;
    return;
  }

  els.handoffList.innerHTML = items.map((item) => {
    const active = item.id === state.selectedID ? " active" : "";
    const headline = item.headline || "(no summary headline)";
    const people = recipientsLabel(item) || item.sender || "";
    return `
      <button class="handoff-row${active}" type="button" data-id="${escapeAttr(item.id)}">
        <span class="row-top">
          <span class="row-id">${escapeHTML(item.id)}</span>
          <span class="badge ${badgeClass(item.state)}">${escapeHTML(item.state || "pending")}</span>
        </span>
        <span class="row-title">${escapeHTML(headline)}</span>
        <span class="row-meta">
          ${kindBadge(item.kind)}
          ${item.urgency === "urgent" ? `<span class="badge urgent">urgent</span>` : ""}
          <span>${escapeHTML(people)}</span>
          ${item.repo_name ? `<span>${escapeHTML(item.repo_name)}</span>` : ""}
          <span>${escapeHTML(formatDate(item.created_at))}</span>
        </span>
      </button>
    `;
  }).join("");
}

function renderOnline(users) {
  const online = users.filter((user) => user.online).length;
  els.onlineCount.textContent = `${online} online`;
  if (!users.length) {
    els.onlineList.innerHTML = `<p class="muted">No known users.</p>`;
    return;
  }
  els.onlineList.innerHTML = users.map((user) => `
    <div class="online-user">
      <span>${escapeHTML(user.identity)}</span>
      <span class="presence ${user.online ? "online" : ""}" title="${user.online ? "Online" : "Offline"}"></span>
    </div>
  `).join("");
}

const HANDOFF_VIEWS = ["recipient", "sender", "history", "project", "all"];

// switchView is the single entry point for tab/pane changes: it resets the
// selection, highlights the tab, swaps the visible pane, and kicks the right
// loader. Handoff views (incl. the project-scoped + admin-all lists) share the
// list/detail grid; projects/account/admin/workspaces each have their own pane.
function switchView(view) {
  state.view = view;
  state.selectedID = "";
  state.selectedPackage = null;
  state.selectedStatus = null;
  state.comments = [];
  els.tabs.forEach((tab) => tab.classList.toggle("active", tab.dataset.view === view));
  applyMainView(view);
  if (view === "workspaces") return renderWorkspaces();
  if (view === "organizations") return Promise.allSettled([loadOnline(), loadOrganizations()]);
  if (view === "projects") return Promise.allSettled([loadOnline(), loadProjects()]);
  if (view === "account") return loadAccount();
  if (view === "admin") return loadAdmin();
  renderDetail();
  refreshAll();
}

function applyMainView(view) {
  const handoff = HANDOFF_VIEWS.includes(view);
  els.listPane.classList.toggle("hidden", !handoff);
  els.detailPane.classList.toggle("hidden", !handoff);
  els.workspacesPane.classList.toggle("hidden", view !== "workspaces");
  els.orgsPane.classList.toggle("hidden", view !== "organizations");
  els.projectsPane.classList.toggle("hidden", view !== "projects");
  els.accountPane.classList.toggle("hidden", view !== "account");
  els.adminPane.classList.toggle("hidden", view !== "admin");
}

function renderWorkspaces() {
  const items = state.workspaces;
  els.workspacesMeta.textContent = items.length
    ? `${items.length} 个项目 · 点击「复制启动命令」到终端粘贴执行。`
    : "未配置 workspace。用 `cc-handoff workspace add <name> <github-url|path>` 添加。";
  if (!items.length) {
    els.workspaceList.innerHTML = `<div class="empty-list">${escapeHTML("No workspaces configured.")}</div>`;
    return;
  }
  els.workspaceList.innerHTML = items.map((ws, i) => `
    <div class="workspace-row">
      <div class="workspace-info">
        <span class="workspace-name">${escapeHTML(ws.name || "(unnamed)")}</span>
        ${ws.workspace ? `<span class="badge">${escapeHTML(ws.workspace)}</span>` : ""}
        <span class="workspace-path">${escapeHTML(ws.path || "")}</span>
        <pre class="cli-cmd">${escapeHTML(ws.command || "")}</pre>
      </div>
      <button class="secondary" type="button" data-launch="${i}">复制启动命令</button>
    </div>
  `).join("");
}

function renderDetail() {
  const pkg = state.selectedPackage;
  const status = state.selectedStatus;
  els.emptyState.classList.toggle("hidden", Boolean(pkg));
  els.detailView.classList.toggle("hidden", !pkg);
  if (!pkg) return;

  const item = state.items.find((row) => row.id === pkg.id) || {};
  const kind = pkg.kind || item.kind || "delivery";
  const headline = firstLine(pkg.summary_md) || item.headline || pkg.id;
  els.detailBadges.innerHTML = [
    `<span class="badge ${badgeClass(status?.state || item.state)}">${escapeHTML(status?.state || item.state || "pending")}</span>`,
    `<span class="badge ${kind}">${escapeHTML(kind)}</span>`,
    pkg.urgency === "urgent" ? `<span class="badge urgent">urgent</span>` : "",
    pkg.bug_group_id ? `<span class="badge">bug group</span>` : "",
  ].join("");
  els.detailTitle.textContent = headline;
  els.detailSubtitle.textContent = `${pkg.sender || "-"} -> ${recipientsFromPackage(pkg).join(", ") || pkg.recipient || "-"}`;

  els.statusState.textContent = status?.state || "-";
  els.statusCreated.textContent = formatDate(status?.created_at || pkg.created_at);
  els.statusComments.textContent = String(status?.comment_count ?? state.comments.length);
  els.statusPicked.textContent = status?.picked_at ? formatDate(status.picked_at) : "-";

  renderRecipientSlots(status);
  els.summaryContent.textContent = pkg.summary_md || "";
  renderMetadata(pkg);
  renderAPIDelta(pkg.api_delta);
  els.promptContent.textContent = state.promptText || "(prompt 加载中…)";
  renderComments();

  const pending = status?.state === "pending";
  const canAck = state.view !== "sender" && pending;
  const canRetract = state.view === "sender" && pending;
  els.pickupButton.disabled = !canAck;
  els.ackButton.disabled = !canAck;
  els.retractButton.disabled = !canRetract;
  els.reassignButton.classList.toggle("hidden", !(canAck && kind === "bug"));
}

function renderRecipientSlots(status) {
  const pickup = status?.pickup_by || {};
  const entries = Object.entries(pickup);
  els.recipientSlots.classList.toggle("hidden", entries.length === 0);
  els.recipientSlots.innerHTML = entries.map(([identity, slot]) => `
    <span class="badge ${badgeClass(slot.state)}">${escapeHTML(identity)}: ${escapeHTML(slot.state)}${slot.picked_at ? ` - ${escapeHTML(formatDate(slot.picked_at))}` : ""}</span>
  `).join("");
}

function renderMetadata(pkg) {
  const rows = [
    ["ID", pkg.id],
    ["Repo", pkg.repo?.name],
    ["Branch", pkg.repo?.branch],
    ["Head SHA", pkg.repo?.head_sha],
    ["Base SHA", pkg.repo?.base_sha],
    ["Sender", pkg.sender],
    ["Recipients", recipientsFromPackage(pkg).join(", ") || pkg.recipient],
    ["Created", formatDate(pkg.created_at)],
    ["Amends", pkg.amends_handoff],
    ["Responds To", pkg.responds_to],
    ["Module Paths", (pkg.module_paths || []).join(", ")],
    ["Attachments", (pkg.attachments || []).map((a) => `${a.name} (${formatBytes(a.size)})`).join(", ")],
    ["Changed Paths", (pkg.git?.changed_paths || []).join(", ")],
    ["Bug Group", pkg.bug_group_id],
    ["Reassigned From", pkg.reassigned_from],
  ].filter(([, value]) => value);

  els.metadataList.innerHTML = rows.map(([key, value]) => `
    <div>
      <dt>${escapeHTML(key)}</dt>
      <dd>${escapeHTML(String(value))}</dd>
    </div>
  `).join("");
}

function renderAPIDelta(delta) {
  const groups = [
    ["Added", delta?.added],
    ["Changed", delta?.changed],
    ["Removed", delta?.removed],
  ].filter(([, ops]) => ops && ops.length);
  els.apiDeltaPanel.classList.toggle("hidden", groups.length === 0);
  els.apiDeltaContent.innerHTML = groups.map(([label, ops]) => `
    <div class="delta-group">
      <h4>${escapeHTML(label)}</h4>
      ${ops.map((op) => `
        <div class="delta-op">
          <span class="method">${escapeHTML(op.method || "")}</span>
          <span>${escapeHTML(op.path || "")}${op.summary ? ` - ${escapeHTML(op.summary)}` : ""}</span>
        </div>
      `).join("")}
    </div>
  `).join("");
}

function renderComments() {
  if (!state.comments.length) {
    els.commentsList.innerHTML = `<p class="muted">No comments yet.</p>`;
    return;
  }
  els.commentsList.innerHTML = state.comments.map((comment) => `
    <article class="comment">
      <div class="comment-header">
        <strong>${escapeHTML(comment.sender)}</strong>
        <span>${escapeHTML(formatDate(comment.created_at))}</span>
      </div>
      <p class="comment-body">${escapeHTML(comment.body)}</p>
    </article>
  `).join("");
}

function setConnectedLabel() {
  const connected = Boolean(state.token);
  els.sessionLabel.textContent = connected ? (state.me?.identity || "connected") : "Not connected";
  els.signoutButton.classList.toggle("hidden", !connected);
}

function authError(err) {
  const msg = err.message || String(err);
  if (msg.includes("401") || msg.includes("invalid token") || msg.includes("missing bearer")) {
    els.authMessage.textContent = "Token rejected by relay.";
  }
  toast(msg);
}

function toast(message) {
  els.toast.textContent = message;
  els.toast.classList.remove("hidden");
  window.clearTimeout(toast.timer);
  toast.timer = window.setTimeout(() => els.toast.classList.add("hidden"), 3600);
}

function viewTitle(view) {
  if (view === "sender") return "Sent";
  if (view === "history") return "History";
  if (view === "project") return state.projectID ? `Project · ${currentProjectLabel()}` : "Project handoffs";
  if (view === "all") return "All handoffs";
  return "Inbox";
}

function currentProjectLabel() {
  const project = state.projects.find((p) => p.id === state.projectID)
    || (state.me?.projects || []).find((p) => p.id === state.projectID);
  return state.projectLabel || project?.name || state.projectID || "Project";
}

function listMetaLabel(shown, loaded) {
  const base = `${shown} shown from ${loaded} loaded`;
  if (state.view === "project") {
    return state.projectID ? `${base} · ${currentProjectLabel()}` : `${base} · all visible projects`;
  }
  if (state.view === "all") {
    return `${base} · admin scope`;
  }
  return base;
}

function haystack(item) {
  return [
    item.id,
    item.sender,
    item.recipient,
    ...(item.recipients || []),
    item.repo_name,
    item.branch,
    item.headline,
    item.kind,
    item.state,
  ].filter(Boolean).join(" ").toLowerCase();
}

function recipientsLabel(item) {
  if (state.view === "sender") {
    return (item.recipients && item.recipients.length ? item.recipients.join(", ") : item.recipient) || "";
  }
  return item.sender || "";
}

function recipientsFromPackage(pkg) {
  return pkg.recipients && pkg.recipients.length ? pkg.recipients : (pkg.recipient ? [pkg.recipient] : []);
}

function kindBadge(kind) {
  const value = kind || "delivery";
  return `<span class="badge ${escapeAttr(value)}">${escapeHTML(value)}</span>`;
}

function badgeClass(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9_-]/g, "");
}

function firstLine(value) {
  return (value || "").split(/\r?\n/, 1)[0].trim();
}

function formatDate(value) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function formatBytes(value) {
  if (!Number.isFinite(value)) return "-";
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeAttr(value) {
  return escapeHTML(value);
}

// --- auth: login / token / signout ---

function setToken(tok) {
  state.token = tok || "";
  if (state.token) {
    localStorage.setItem("cc-handoff-token", state.token);
  } else {
    localStorage.removeItem("cc-handoff-token");
  }
}

async function onLogin(event) {
  event.preventDefault();
  const identity = els.loginIdentity.value.trim();
  const password = els.loginPassword.value;
  if (!identity || !password) {
    toast("请输入 identity 和密码");
    return;
  }
  try {
    const resp = await fetch("/v1/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identity, password }),
    });
    if (!resp.ok) {
      els.authMessage.textContent = "登录失败：identity 或密码错误。";
      toast("登录失败");
      return;
    }
    const data = await resp.json();
    setToken(data.token);
    els.loginPassword.value = "";
    await onConnected();
  } catch (err) {
    toast(`登录失败：${err.message || err}`);
  }
}

// onRegister self-registers a new (non-admin) account from the same identity +
// password fields, then signs in exactly like onLogin (the response carries a
// ready-to-use session token).
async function onRegister(event) {
  event.preventDefault();
  const identity = els.loginIdentity.value.trim();
  const password = els.loginPassword.value;
  if (!identity || !password) {
    toast("请输入 identity 和密码");
    return;
  }
  try {
    const resp = await fetch("/v1/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identity, password }),
    });
    if (!resp.ok) {
      const msg = resp.status === 409 ? "该账号已注册" : "注册失败，请重试。";
      els.authMessage.textContent = msg;
      toast(msg);
      return;
    }
    const data = await resp.json();
    setToken(data.token);
    els.loginPassword.value = "";
    await onConnected({ view: "organizations" });
  } catch (err) {
    toast(`注册失败：${err.message || err}`);
  }
}

function onUseToken() {
  const tok = els.tokenInput.value.trim();
  if (!tok) {
    toast("请粘贴机器 token");
    return;
  }
  setToken(tok);
  els.tokenInput.value = "";
  onConnected();
}

async function onSignout() {
  try {
    if (state.token) await api("/v1/logout", { method: "POST" });
  } catch {
    // ignore — clearing the local token is what matters.
  }
  setToken("");
  state.me = null;
  state.organizations = [];
  state.projects = [];
  state.items = [];
  state.projectID = "";
  state.projectLabel = "";
  setupRoleTabs();
  setConnectedLabel();
  switchView("recipient");
  renderList();
  renderOnline([]);
}

// onConnected runs once a token is established (login or paste): learn who we
// are, reveal role-appropriate tabs, then load the default view.
async function onConnected(options = {}) {
  try {
    state.me = await api("/v1/me");
  } catch (err) {
    state.me = null;
    setupRoleTabs();
    setConnectedLabel();
    authError(err);
    return;
  }
  els.authMessage.textContent = `已登录为 ${state.me.identity}`;
  setupRoleTabs();
  setConnectedLabel();
  if (options.view) {
    await switchView(options.view);
    return;
  }
  refreshAll();
}

async function refreshMe() {
  state.me = await api("/v1/me");
  setupRoleTabs();
  setConnectedLabel();
}

// setupRoleTabs reveals Teams/Projects/Account to every signed-in user so a
// freshly registered account can bootstrap its first team and project.
function setupRoleTabs() {
  const me = state.me;
  els.tabOrgs.classList.toggle("hidden", !me);
  els.tabProjects.classList.toggle("hidden", !me);
  els.tabAdmin.classList.toggle("hidden", !(me && me.is_admin));
  els.tabAccount.classList.toggle("hidden", !me);
}

// --- organizations / teams pane ---

async function loadOrganizations() {
  if (!state.token) return;
  try {
    const data = await api("/v1/orgs");
    state.organizations = data.organizations || [];
    renderOrganizations();
    renderProjectOrgOptions();
  } catch (err) {
    toast(err.message);
  }
}

function organizationRole(id) {
  const org = (state.me?.organizations || []).find((o) => o.id === id);
  if (org) return org.role;
  return state.me?.is_admin ? "admin" : "member";
}

function organizationName(id) {
  const org = state.organizations.find((o) => o.id === id) || (state.me?.organizations || []).find((o) => o.id === id);
  return org?.name || id || "Default team";
}

function canManageOrganization(role) {
  return state.me?.is_admin || role === "owner" || role === "admin";
}

function isOnlineIdentity(identity) {
  return state.online.some((user) => user.identity === identity && user.online);
}

function memberPresence(identity) {
  const online = isOnlineIdentity(identity);
  return `<span class="presence ${online ? "online" : ""}" title="${online ? "Online" : "Offline"}"></span>`;
}

function roleTone(role) {
  return ["owner", "admin", "member", "viewer", "guest"].includes(role) ? `role-${role}` : "role-member";
}

function metricTile(label, value) {
  return `<div class="team-metric"><span>${escapeHTML(label)}</span><strong>${escapeHTML(String(value))}</strong></div>`;
}

function identityLabel(member) {
  const name = (member.display_name || "").trim();
  return name ? `${member.identity} · ${name}` : member.identity;
}

function memberCandidateOptions(candidates) {
  if (!candidates.length) {
    return `<option value="">无可选成员</option>`;
  }
  return [
    `<option value="">选择成员</option>`,
    ...candidates.map((m) => `<option value="${escapeAttr(m.identity)}">${escapeHTML(identityLabel(m))}</option>`),
  ].join("");
}

function reachableUserCandidates(existingMembers = []) {
  const existing = new Set(existingMembers.map((m) => m.identity));
  return state.online
    .filter((user) => user.identity && !existing.has(user.identity))
    .map((user) => ({ identity: user.identity, display_name: user.online ? "在线" : "离线" }));
}

function memberCandidateForm(kind, candidates, roles) {
  const roleOptions = roles.map((role) => `<option value="${escapeAttr(role)}">${escapeHTML(role)}</option>`).join("");
  const emptyHint = candidates.length ? "" : `<span class="member-picker-hint">没有候选时仍可手动输入 identity。</span>`;
  return `
    <form class="inline-form member-invite-form member-picker" data-form="${escapeAttr(kind)}">
      <select name="candidate" aria-label="选择成员">
        ${memberCandidateOptions(candidates)}
      </select>
      <input type="text" name="identity" aria-label="成员 identity" placeholder="或手动输入 identity">
      <select name="role" aria-label="成员角色">${roleOptions}</select>
      <button type="submit" class="secondary">加成员</button>
      ${emptyHint}
    </form>`;
}

function renderMemberTable(members, options = {}) {
  if (!members.length) {
    return `<div class="empty-inline">还没有成员。</div>`;
  }
  const removeAttr = options.removeAttr || "";
  const canRemove = Boolean(options.canRemove && removeAttr);
  return `
    <div class="member-table ${canRemove ? "has-actions" : ""}" role="table" aria-label="${escapeAttr(options.label || "成员")}">
      <div class="member-table-row member-table-head" role="row">
        <span role="columnheader">成员</span>
        <span role="columnheader">角色</span>
        <span role="columnheader">状态</span>
        ${canRemove ? `<span role="columnheader">操作</span>` : ""}
      </div>
      ${members.map((m) => {
        const displayName = (m.display_name || "").trim();
        const online = isOnlineIdentity(m.identity);
        return `
          <div class="member-table-row" role="row">
            <span class="member-person" role="cell">
              <span class="member-identity">${escapeHTML(m.identity)}</span>
              ${displayName ? `<small>${escapeHTML(displayName)}</small>` : ""}
            </span>
            <span role="cell"><span class="role-pill ${roleTone(m.role)}">${escapeHTML(m.role)}</span></span>
            <span class="member-state" role="cell">${memberPresence(m.identity)}${online ? "在线" : "离线"}</span>
            ${canRemove ? `<span class="member-actions" role="cell"><button type="button" class="link-danger" ${removeAttr}="${escapeAttr(m.identity)}" aria-label="移除成员 ${escapeAttr(m.identity)}">移除</button></span>` : ""}
          </div>`;
      }).join("")}
    </div>`;
}

function renderOrganizations() {
  if (!state.organizations.length) {
    els.orgsList.innerHTML = `<div class="empty-list">还没有团队。新建一个团队，然后在 Projects 里创建项目。</div>`;
    return;
  }
  els.orgsList.innerHTML = state.organizations.map((org) => {
    const role = organizationRole(org.id);
    const canManage = canManageOrganization(role);
    return `
      <div class="aux-card org-card" data-org="${escapeAttr(org.id)}">
        <div class="aux-card-head">
          <div class="org-title">
            <strong>${escapeHTML(org.name)}</strong>
            <span class="badge">${escapeHTML(role)}</span>
          </div>
          <div class="aux-card-actions">
            ${canManage ? `<button class="secondary" type="button" data-action="manage-org">管理</button>` : ""}
          </div>
        </div>
        <div class="muted org-meta">owner · ${escapeHTML(org.owner_identity || "-")} · ${escapeHTML(org.id)}</div>
        <div class="aux-card-body hidden" data-body></div>
      </div>`;
  }).join("");
}

async function onOrganizationsListClick(event) {
  const card = event.target.closest("[data-org]");
  if (!card) return;
  const id = card.dataset.org;
  const body = card.querySelector("[data-body]");
  const action = event.target.closest("[data-action]")?.dataset.action;
  try {
    if (action === "manage-org") {
      if (!body.classList.contains("hidden")) {
        body.classList.add("hidden");
        return;
      }
      await renderOrganizationManage(id, body);
      body.classList.remove("hidden");
      return;
    }
    const member = event.target.closest("[data-remove-org-member]")?.dataset.removeOrgMember;
    if (member !== undefined) {
      await api(`/v1/orgs/${encodeURIComponent(id)}/members/${encodeURIComponent(member)}`, { method: "DELETE" });
      toast("已移除团队成员");
      await refreshMe();
      await loadOrganizations();
      const next = organizationBody(id);
      if (next) {
        await renderOrganizationManage(id, next);
        next.classList.remove("hidden");
      }
    }
  } catch (err) {
    toast(err.message);
  }
}

async function onOrganizationsListSubmit(event) {
  event.preventDefault();
  const form = event.target;
  const card = form.closest("[data-org]");
  if (!card || form.dataset.form !== "org-member") return;
  const id = card.dataset.org;
  const candidate = form.querySelector("[name=candidate]")?.value.trim() || "";
  const manual = form.querySelector("[name=identity]")?.value.trim() || "";
  const identity = manual || candidate;
  const role = form.querySelector("[name=role]").value;
  if (!identity) return;
  try {
    await api(`/v1/orgs/${encodeURIComponent(id)}/members`, { method: "POST", body: JSON.stringify({ identity, role }) });
    toast("已添加团队成员");
    form.reset();
    await refreshMe();
    await loadOrganizations();
    const next = organizationBody(id);
    if (next) {
      await renderOrganizationManage(id, next);
      next.classList.remove("hidden");
    }
  } catch (err) {
    toast(err.message);
  }
}

function organizationBody(id) {
  const card = Array.from(els.orgsList.querySelectorAll("[data-org]")).find((el) => el.dataset.org === id);
  return card?.querySelector("[data-body]") || null;
}

async function renderOrganizationManage(id, body) {
  try {
    const data = await api(`/v1/orgs/${encodeURIComponent(id)}`);
    const members = data.members || [];
    const projects = data.projects || [];
    const role = organizationRole(id);
    const canManage = canManageOrganization(role);
    const onlineCount = members.filter((m) => isOnlineIdentity(m.identity)).length;
    body.innerHTML = `
      <div class="team-summary-strip">
        ${metricTile("项目", projects.length)}
        ${metricTile("成员", members.length)}
        ${metricTile("在线", onlineCount)}
        ${metricTile("你的角色", role)}
      </div>
      <div class="manage-block">
        <h4>项目</h4>
        <div class="team-project-grid">
          ${projects.length ? projects.map((p) => `
            <button class="team-project-card" type="button" data-jump-project="${escapeAttr(p.id)}">
              <span>${escapeHTML(p.name)}</span>
              <small>${escapeHTML(p.owner_identity || "")}</small>
            </button>`).join("") : `<span class="muted">这个团队下还没有项目。</span>`}
        </div>
      </div>
      <div class="manage-block">
        <h4>成员</h4>
        ${renderMemberTable(members, { canRemove: canManage, removeAttr: "data-remove-org-member", label: "团队成员" })}
        ${canManage ? memberCandidateForm("org-member", reachableUserCandidates(members), ["member", "admin", "guest", "owner"]) : ""}
      </div>`;
    body.querySelectorAll("[data-jump-project]").forEach((button) => {
      button.addEventListener("click", () => {
        state.projectID = button.dataset.jumpProject;
        state.projectLabel = button.querySelector("span")?.textContent || "";
        switchView("project");
      });
    });
  } catch (err) {
    body.innerHTML = `<p class="muted">${escapeHTML(err.message)}</p>`;
  }
}

async function onCreateOrganization(event) {
  event.preventDefault();
  const name = els.newOrgName.value.trim();
  if (!name) return;
  try {
    const org = await api("/v1/orgs", { method: "POST", body: JSON.stringify({ name }) });
    if (org?.id) state.preferredProjectOrgID = org.id;
    els.newOrgName.value = "";
    toast("团队已创建");
    await refreshMe();
    await loadOrganizations();
    if (org?.id) {
      const body = organizationBody(org.id);
      if (body) {
        await renderOrganizationManage(org.id, body);
        body.classList.remove("hidden");
      }
    }
  } catch (err) {
    toast(err.message);
  }
}

// --- projects pane ---

async function loadProjects() {
  if (!state.token) return;
  try {
    const [projectsData, orgsData] = await Promise.all([
      api("/v1/projects"),
      api("/v1/orgs").catch(() => ({ organizations: state.organizations || [] })),
    ]);
    state.organizations = orgsData.organizations || [];
    renderProjectOrgOptions();
    const data = projectsData;
    state.projects = data.projects || [];
    renderProjects();
  } catch (err) {
    toast(err.message);
  }
}

function renderProjectOrgOptions() {
  const orgs = (state.organizations || []).filter((org) => canManageOrganization(organizationRole(org.id)));
  if (!els.newProjectOrg) return;
  const selected = state.preferredProjectOrgID || els.newProjectOrg.value || "";
  if (!orgs.length) {
    els.newProjectOrg.innerHTML = `<option value="">我的默认团队</option>`;
    return;
  }
  els.newProjectOrg.innerHTML = [
    `<option value="">我的默认团队</option>`,
    ...orgs.map((org) => `<option value="${escapeAttr(org.id)}">${escapeHTML(org.name)}</option>`),
  ].join("");
  els.newProjectOrg.value = Array.from(els.newProjectOrg.options).some((option) => option.value === selected) ? selected : "";
}

function projectRole(id) {
  const p = (state.me?.projects || []).find((pr) => pr.id === id);
  if (p) return p.role;
  return state.me?.is_admin ? "admin" : "member";
}

function renderProjects() {
  if (!state.projects.length) {
    els.projectsList.innerHTML = `<div class="empty-list">还没有项目。用上面的表单新建一个。</div>`;
    return;
  }
  els.projectsList.innerHTML = state.projects.map((p) => {
    const role = projectRole(p.id);
    const canManage = role === "owner" || state.me?.is_admin;
    return `
      <div class="aux-card" data-project="${escapeAttr(p.id)}">
        <div class="aux-card-head">
          <div>
            <strong>${escapeHTML(p.name)}</strong> <span class="badge">${escapeHTML(role)}</span>
            ${p.org_id ? `<span class="badge soft">${escapeHTML(organizationName(p.org_id))}</span>` : ""}
          </div>
          <div class="aux-card-actions">
            <button class="secondary" type="button" data-action="browse">查看 handoff</button>
            ${canManage ? `<button class="secondary" type="button" data-action="manage">管理</button>` : ""}
          </div>
        </div>
        <div class="aux-card-body hidden" data-body></div>
      </div>`;
  }).join("");
}

async function onProjectsListClick(event) {
  const card = event.target.closest("[data-project]");
  if (!card) return;
  const id = card.dataset.project;
  const body = card.querySelector("[data-body]");
  const action = event.target.closest("[data-action]")?.dataset.action;
  try {
    if (action === "browse") {
      state.projectID = id;
      const project = state.projects.find((p) => p.id === id);
      state.projectLabel = project?.name || "";
      switchView("project");
      return;
    }
    if (action === "manage") {
      if (!body.classList.contains("hidden")) {
        body.classList.add("hidden");
        return;
      }
      await renderProjectManage(id, body);
      body.classList.remove("hidden");
      return;
    }
    const repo = event.target.closest("[data-unmap]")?.dataset.unmap;
    if (repo !== undefined) {
      await api(`/v1/projects/${encodeURIComponent(id)}/repos?repo_name=${encodeURIComponent(repo)}`, { method: "DELETE" });
      toast("已移除 repo");
      await renderProjectManage(id, body);
      return;
    }
    const member = event.target.closest("[data-remove-member]")?.dataset.removeMember;
    if (member !== undefined) {
      await api(`/v1/projects/${encodeURIComponent(id)}/members/${encodeURIComponent(member)}`, { method: "DELETE" });
      toast("已移除成员");
      await renderProjectManage(id, body);
    }
  } catch (err) {
    toast(err.message);
  }
}

function projectBody(id) {
  const card = Array.from(els.projectsList.querySelectorAll("[data-project]")).find((el) => el.dataset.project === id);
  return card?.querySelector("[data-body]") || null;
}

async function onProjectsListSubmit(event) {
  event.preventDefault();
  const form = event.target;
  const card = form.closest("[data-project]");
  if (!card) return;
  const id = card.dataset.project;
  try {
    if (form.dataset.form === "repo") {
      const name = form.querySelector("input").value.trim();
      if (!name) return;
      await api(`/v1/projects/${encodeURIComponent(id)}/repos`, { method: "POST", body: JSON.stringify({ repo_name: name }) });
      toast("已绑定 repo");
    } else if (form.dataset.form === "member") {
      const candidate = form.querySelector("[name=candidate]")?.value.trim() || "";
      const manual = form.querySelector("[name=identity]")?.value.trim() || "";
      const identity = manual || candidate;
      const role = form.querySelector("[name=role]").value;
      if (!identity) return;
      await api(`/v1/projects/${encodeURIComponent(id)}/members`, { method: "POST", body: JSON.stringify({ identity, role }) });
      toast("已添加成员");
    }
    await renderProjectManage(id, card.querySelector("[data-body]"));
  } catch (err) {
    toast(err.message);
  }
}

async function renderProjectManage(id, body) {
  try {
    const data = await api(`/v1/projects/${encodeURIComponent(id)}`);
    const repos = data.repos || [];
    const members = data.members || [];
    const project = data.project || {};
    let orgMembers = [];
    if (project.org_id) {
      try {
        const orgData = await api(`/v1/orgs/${encodeURIComponent(project.org_id)}`);
        orgMembers = orgData.members || [];
      } catch {
        orgMembers = [];
      }
    }
    const projectMemberIDs = new Set(members.map((m) => m.identity));
    const memberCandidates = orgMembers.filter((m) => !projectMemberIDs.has(m.identity));
    const onlineCount = members.filter((m) => isOnlineIdentity(m.identity)).length;
    body.innerHTML = `
      <div class="team-summary-strip">
        ${metricTile("成员", members.length)}
        ${metricTile("在线", onlineCount)}
        ${metricTile("Repos", repos.length)}
        ${metricTile("团队", organizationName(project.org_id))}
      </div>
      <div class="manage-block project-context">
        <span class="muted">团队</span>
        <strong>${escapeHTML(organizationName(project.org_id))}</strong>
      </div>
      <div class="manage-block">
        <h4>Repos</h4>
        <div class="chip-row">
          ${repos.length ? repos.map((r) => `<span class="chip">${escapeHTML(r)}<button type="button" data-unmap="${escapeAttr(r)}" aria-label="移除 repo ${escapeAttr(r)}" title="移除">×</button></span>`).join("") : `<span class="muted">无</span>`}
        </div>
        <form class="inline-form" data-form="repo">
          <input type="text" aria-label="要绑定的 repo 名" placeholder="repo 名（如 kunlun-backend）">
          <button type="submit" class="secondary">绑定 repo</button>
        </form>
      </div>
      <div class="manage-block">
        <h4>成员</h4>
        ${renderMemberTable(members, { canRemove: true, removeAttr: "data-remove-member", label: "项目成员" })}
        ${memberCandidateForm("member", memberCandidates, ["member", "viewer", "owner"])}
      </div>`;
  } catch (err) {
    body.innerHTML = `<p class="muted">${escapeHTML(err.message)}</p>`;
  }
}

async function onCreateProject(event) {
  event.preventDefault();
  const name = els.newProjectName.value.trim();
  const orgID = els.newProjectOrg.value;
  if (!name) return;
  try {
    const project = await api("/v1/projects", { method: "POST", body: JSON.stringify({ name, org_id: orgID }) });
    state.preferredProjectOrgID = orgID;
    els.newProjectName.value = "";
    toast("项目已创建");
    await refreshMe();
    await loadProjects();
    if (project?.id) {
      const body = projectBody(project.id);
      if (body) {
        await renderProjectManage(project.id, body);
        body.classList.remove("hidden");
      }
    }
  } catch (err) {
    toast(err.message);
  }
}

// --- account pane: password + machine tokens ---

async function loadAccount() {
  if (!state.token) return;
  try {
    const data = await api("/v1/tokens");
    renderTokens(data.tokens || []);
  } catch (err) {
    toast(err.message);
  }
}

function renderTokens(tokens) {
  if (!tokens.length) {
    els.tokensList.innerHTML = `<div class="empty-list">还没有机器 token。</div>`;
    return;
  }
  els.tokensList.innerHTML = tokens.map((t) => `
    <div class="aux-card">
      <div class="aux-card-head">
        <div><strong>${escapeHTML(t.label || "(no label)")}</strong> <span class="muted">${escapeHTML(formatDate(t.created_at))}</span></div>
        <button class="link-danger" type="button" data-revoke="${escapeAttr(t.id)}">吊销</button>
      </div>
    </div>`).join("");
}

async function onTokensListClick(event) {
  const id = event.target.closest("[data-revoke]")?.dataset.revoke;
  if (id === undefined) return;
  if (!window.confirm("吊销这个 token？用它的机器会立即失效。")) return;
  try {
    await api(`/v1/tokens/${encodeURIComponent(id)}`, { method: "DELETE" });
    toast("已吊销");
    await loadAccount();
  } catch (err) {
    toast(err.message);
  }
}

async function onCreateToken(event) {
  event.preventDefault();
  try {
    const data = await api("/v1/tokens", { method: "POST", body: JSON.stringify({ label: els.newTokenLabel.value.trim() }) });
    els.newTokenLabel.value = "";
    await copyToClipboard(data.token, "token 已复制（只显示这一次！粘进 cc-handoff init）");
    await loadAccount();
  } catch (err) {
    toast(err.message);
  }
}

async function onChangePassword(event) {
  event.preventDefault();
  if (els.passwordNew.value.length < 8) {
    toast("新密码至少 8 位");
    return;
  }
  try {
    await api("/v1/password", { method: "POST", body: JSON.stringify({ old: els.passwordOld.value, new: els.passwordNew.value }) });
    els.passwordOld.value = "";
    els.passwordNew.value = "";
    toast("密码已更新");
  } catch (err) {
    toast(err.message);
  }
}

// --- admin pane: accounts ---

async function loadAdmin() {
  if (!state.token) return;
  try {
    const data = await api("/v1/users");
    renderUsers(data.users || []);
  } catch (err) {
    toast(err.message);
  }
}

function renderUsers(users) {
  if (!users.length) {
    els.usersList.innerHTML = `<div class="empty-list">没有账号。</div>`;
    return;
  }
  els.usersList.innerHTML = users.map((u) => `
    <div class="aux-card" data-user="${escapeAttr(u.identity)}" data-admin="${u.is_admin ? "1" : "0"}" data-disabled="${u.disabled ? "1" : "0"}">
      <div class="aux-card-head">
        <div>
          <strong>${escapeHTML(u.identity)}</strong>
          ${u.is_admin ? `<span class="badge">admin</span>` : ""}
          ${u.disabled ? `<span class="badge expired">disabled</span>` : ""}
        </div>
        <div class="aux-card-actions">
          <button class="secondary" type="button" data-uaction="admin">${u.is_admin ? "取消 admin" : "设为 admin"}</button>
          <button class="secondary" type="button" data-uaction="disable">${u.disabled ? "启用" : "停用"}</button>
          <button class="secondary" type="button" data-uaction="reset">重置密码</button>
        </div>
      </div>
    </div>`).join("");
}

async function onUsersListClick(event) {
  const card = event.target.closest("[data-user]");
  const action = event.target.closest("[data-uaction]")?.dataset.uaction;
  if (!card || !action) return;
  const id = card.dataset.user;
  try {
    if (action === "admin") {
      await api(`/v1/users/${encodeURIComponent(id)}/admin`, { method: "POST", body: JSON.stringify({ is_admin: card.dataset.admin !== "1" }) });
      toast("已更新");
    } else if (action === "disable") {
      await api(`/v1/users/${encodeURIComponent(id)}/disable`, { method: "POST", body: JSON.stringify({ disabled: card.dataset.disabled !== "1" }) });
      toast("已更新");
    } else if (action === "reset") {
      const data = await api(`/v1/users/${encodeURIComponent(id)}/reset-password`, { method: "POST" });
      await copyToClipboard(data.password, `新密码已复制（只显示这一次）：${data.password}`);
    }
    await loadAdmin();
  } catch (err) {
    toast(err.message);
  }
}

async function onCreateUser(event) {
  event.preventDefault();
  const identity = els.newUserIdentity.value.trim();
  if (!identity) {
    toast("请填 identity");
    return;
  }
  try {
    const body = { identity, is_admin: els.newUserAdmin.checked };
    const pw = els.newUserPassword.value.trim();
    if (pw) body.password = pw;
    const data = await api("/v1/users", { method: "POST", body: JSON.stringify(body) });
    els.newUserIdentity.value = "";
    els.newUserPassword.value = "";
    els.newUserAdmin.checked = false;
    if (data.password) {
      await copyToClipboard(data.password, `账号已建，初始密码已复制（只显示这一次）：${data.password}`);
    } else {
      toast("账号已创建");
    }
    await loadAdmin();
  } catch (err) {
    toast(err.message);
  }
}
