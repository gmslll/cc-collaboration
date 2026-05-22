const state = {
  token: localStorage.getItem("cc-handoff-token") || "",
  view: "recipient",
  items: [],
  selectedID: "",
  selectedPackage: null,
  selectedStatus: null,
  comments: [],
  promptText: "",
  online: [],
};

const els = {
  authForm: document.querySelector("#auth-form"),
  tokenInput: document.querySelector("#token-input"),
  authMessage: document.querySelector("#auth-message"),
  sessionLabel: document.querySelector("#session-label"),
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
};

els.tokenInput.value = state.token;
setConnectedLabel();
wireEvents();
renderList();
if (state.token) {
  refreshAll();
}

function wireEvents() {
  els.authForm.addEventListener("submit", (event) => {
    event.preventDefault();
    state.token = els.tokenInput.value.trim();
    if (state.token) {
      localStorage.setItem("cc-handoff-token", state.token);
    } else {
      localStorage.removeItem("cc-handoff-token");
    }
    setConnectedLabel();
    refreshAll();
  });

  els.refreshButton.addEventListener("click", refreshAll);
  els.limitSelect.addEventListener("change", refreshAll);
  els.searchInput.addEventListener("input", renderList);

  els.tabs.forEach((button) => {
    button.addEventListener("click", () => {
      state.view = button.dataset.view;
      state.selectedID = "";
      state.selectedPackage = null;
      state.selectedStatus = null;
      state.comments = [];
      els.tabs.forEach((tab) => tab.classList.toggle("active", tab === button));
      renderDetail();
      refreshAll();
    });
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
      const out = await window.ccHandoffPickup(state.selectedID);
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
  await Promise.allSettled([loadOnline(), loadList()]);
}

async function loadList() {
  try {
    const limit = encodeURIComponent(els.limitSelect.value);
    const data = await api(`/v1/handoffs?as=${encodeURIComponent(state.view)}&limit=${limit}`);
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
    ? `${items.length} shown from ${state.items.length} loaded`
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
  els.sessionLabel.textContent = state.token ? "Token configured" : "Not connected";
  els.authMessage.textContent = state.token ? "Token saved in local storage." : "Stored locally in this browser.";
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
  return view === "sender" ? "Sent" : view === "history" ? "History" : "Inbox";
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
