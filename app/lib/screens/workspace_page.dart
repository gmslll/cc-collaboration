import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/sse.dart';
import '../api/todo_models.dart';
import '../file_icons.dart';
import '../fs_clipboard.dart';
import '../local/cli.dart';
import '../local/agent_resolver.dart';
import '../local/agent_transcript.dart';
import '../local/capsule_distill.dart';
import '../local/config.dart';
import '../local/diff_parse.dart';
import '../local/git.dart';
import '../local/hook_activity.dart';
import '../local/identity.dart';
import '../local/local_bus.dart';
import '../local/online_send_layout.dart';
import '../local/lsp/lsp_client.dart';
import '../local/path_utils.dart';
import '../local/prefs.dart';
import '../local/project_order.dart';
import '../local/session_overview.dart';
import '../local/todo_materialize.dart';
import '../local/todo_permissions.dart';
import '../local/todo_store.dart';
import '../local/todo_workspace_scope.dart';
import '../local/worktrees.dart';
import '../plugins/plugin_manager.dart';
import '../remote/file_transfer.dart';
import '../remote/remote_host.dart';
import '../theme.dart';
import '../voice/voice.dart';
import '../widgets.dart';
import '../widgets/history_commit_tile.dart';
import '../widgets/inbox_item_card.dart';
import '../widgets/split_pane.dart';
import '../widgets/todo_card.dart';
import 'workspace/file_pane_state.dart';
import 'diff_page.dart';
import 'diff_split.dart';
import 'diff_view.dart';
import 'editor_page.dart';
import 'file_browser_page.dart';
import 'github_pr_page.dart';
import 'handoff_detail_view.dart';
import 'plugins_page.dart';
import 'repo_config_page.dart';
import 'terminal_deck.dart';
import 'terminal_pane.dart';
import 'todo_detail_view.dart';
import 'workspace/git_graph.dart';

part 'workspace/branch_dialog.dart';
part 'workspace/navigation_dialogs.dart';
part 'workspace/search_dialogs.dart';
part 'workspace/git_history_dialogs.dart';
part 'workspace/git_mixin.dart';
part 'workspace/search_mixin.dart';
part 'workspace/commit_changes_menu.dart';
part 'workspace/git_log_branch_menu.dart';
part 'workspace/git_log_commit_menu.dart';
part 'workspace/git_log_difftree_menu.dart';
part 'workspace/symbol_index.dart';

enum _BottomTool { terminal, git }

enum _GitView { changes, log, stash }

enum _LeftToolView { project, structure, changes, stash }

enum _ChangeFilter { all, staged, unstaged, untracked, conflicts }

enum _BranchFilter { all, local, remote, current, unpublished, diverged }

const _workingTreeDiffSelection = '__working_tree_diff__';

double workspaceConfirmDialogWidth(Size size, {double preferred = 420}) {
  final available = size.width - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

// 取前 take 行拼成预览,超出部分加 "...and N more"(用于确认对话框)。
String _previewList(List<String> items, {int take = 5}) =>
    items.take(take).join('\n') +
    (items.length > take ? '\n...and ${items.length - take} more' : '');

bool workspaceCommitActionEnabled({
  required bool hasCommitTarget,
  required String message,
  required bool loading,
}) => !loading && hasCommitTarget && message.trim().isNotEmpty;

List<OnlineUser> onlineSendSelectableUsers(
  Iterable<OnlineUser> users,
  String selfIdentity, {
  Iterable<String>? allowedIdentities,
}) {
  final seen = <String>{};
  final allowed = allowedIdentities == null
      ? null
      : {
          for (final identity in allowedIdentities)
            if (identityLookupKey(identity).isNotEmpty)
              identityLookupKey(identity),
        };
  final selectable = <OnlineUser>[];
  for (final user in users) {
    final key = identityLookupKey(user.identity);
    if (!user.online ||
        key.isEmpty ||
        sameIdentity(user.identity, selfIdentity) ||
        (allowed != null && !allowed.contains(key))) {
      continue;
    }
    if (seen.add(key)) selectable.add(user);
  }
  return selectable;
}

bool onlineSendIdentitySelected(String? selected, String identity) =>
    selected != null && sameIdentity(selected, identity);

List<RemoteSession> onlineSendSessionsForProject(
  Iterable<RemoteSession> sessions, {
  String? projectId,
  String? projectName,
}) {
  final pid = (projectId ?? '').trim();
  final name = (projectName ?? '').trim();
  if (pid.isEmpty && name.isEmpty) return sessions.toList();
  return [
    for (final session in sessions)
      if (pid.isNotEmpty
          ? (session.projectId.trim().isNotEmpty
                ? session.projectId.trim() == pid
                : name.isNotEmpty && session.project.trim() == name)
          : session.project.trim() == name)
        session,
  ];
}

Set<String> onlineSendProjectRecipientIdentities(ProjectDetail detail) => {
  if (identityLookupKey(detail.project.ownerIdentity).isNotEmpty)
    detail.project.ownerIdentity,
  for (final member in detail.members)
    if (identityLookupKey(member.identity).isNotEmpty) member.identity,
};

Set<String> onlineSendProjectReachableIdentities(
  ProjectDetail detail, {
  OrganizationDetail? organization,
}) {
  final identities = onlineSendProjectRecipientIdentities(detail);
  if (organization == null) return identities;
  for (final member in organization.members) {
    final role = member.role.trim().toLowerCase();
    if ((role == 'owner' || role == 'admin') &&
        identityLookupKey(member.identity).isNotEmpty) {
      identities.add(member.identity);
    }
  }
  return identities;
}

bool onlineSendProjectNameIsAmbiguous(
  Iterable<ProjectRole> projects,
  String? name,
) {
  final target = (name ?? '').trim();
  if (target.isEmpty) return false;
  final ids = <String>{};
  for (final project in projects) {
    if (project.name.trim() == target && project.id.trim().isNotEmpty) {
      ids.add(project.id.trim());
    }
  }
  return ids.length > 1;
}

String? onlineSendProjectIdForLocalProject(
  Iterable<ProjectRole> projectRoles,
  ProjectCfg project,
) {
  final configuredProjectId = project.projectId.trim();
  if (configuredProjectId.isNotEmpty) return configuredProjectId;
  return uniqueProjectIdByName(projectRoles, project.name);
}

bool remoteSpawnProjectMatchesRequestedId(
  ProjectCfg project,
  String? requestedProjectId,
) {
  final requested = (requestedProjectId ?? '').trim();
  if (requested.isEmpty) return true;
  return project.projectId.trim() == requested;
}

class _OnlineSendProjectScopeError implements Exception {
  const _OnlineSendProjectScopeError();
}

bool incomingMessageTargetIsOpen(
  Iterable<TerminalSession> sessions,
  TerminalSession target,
) => sessions.any((session) => session.id == target.id);

bool incomingMessageSessionMatchesProject({
  required String sessionProjectId,
  required String sessionProjectName,
  required String messageProjectId,
  required String messageProjectName,
}) {
  final msgPid = messageProjectId.trim();
  final msgProject = messageProjectName.trim();
  if (msgPid.isEmpty && msgProject.isEmpty) return true;
  final sessionPid = sessionProjectId.trim();
  if (msgPid.isNotEmpty && sessionPid.isNotEmpty) return sessionPid == msgPid;
  final sessionProject = sessionProjectName.trim();
  return msgProject.isNotEmpty && sessionProject == msgProject;
}

const _searchSkipDirs = {
  '.git',
  'node_modules',
  'build',
  '.dart_tool',
  '.idea',
  'dist',
  'vendor',
  'target',
  '.gradle',
  'Pods',
  '.next',
  '__pycache__',
  '.venv',
};

class WorkspaceFieldSpec {
  final String label;
  final String? hint;
  final bool required;

  const WorkspaceFieldSpec({
    required this.label,
    this.hint,
    this.required = false,
  });
}

class WorkspaceFieldsDialog extends StatefulWidget {
  final String title;
  final String okLabel;
  final List<WorkspaceFieldSpec> fields;

  const WorkspaceFieldsDialog({
    super.key,
    required this.title,
    required this.okLabel,
    required this.fields,
  });

  @override
  State<WorkspaceFieldsDialog> createState() => _WorkspaceFieldsDialogState();
}

class _WorkspaceFieldsDialogState extends State<WorkspaceFieldsDialog> {
  late final List<TextEditingController> _ctls = [
    for (final _ in widget.fields) TextEditingController(),
  ];

  @override
  void dispose() {
    for (final ctl in _ctls) {
      ctl.dispose();
    }
    super.dispose();
  }

  void _submit() => Navigator.pop(context, [for (final ctl in _ctls) ctl.text]);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < widget.fields.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: TextField(
                controller: _ctls[i],
                autofocus: i == 0,
                decoration: InputDecoration(
                  labelText: widget.fields[i].label,
                  hintText: widget.fields[i].hint,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.okLabel)),
      ],
    );
  }
}

class WorkspaceSessionRenameDialog extends StatefulWidget {
  final String initialName;
  final String hint;

  const WorkspaceSessionRenameDialog({
    super.key,
    this.initialName = '',
    required this.hint,
  });

  @override
  State<WorkspaceSessionRenameDialog> createState() =>
      _WorkspaceSessionRenameDialogState();
}

class _WorkspaceSessionRenameDialogState
    extends State<WorkspaceSessionRenameDialog> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctl.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        decoration: InputDecoration(
          labelText: '名称(留空 = 默认)',
          hintText: widget.hint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

class WorkspaceCommitBranchDialog extends StatefulWidget {
  final String initialBranch;
  final String shortHash;
  final String subject;

  const WorkspaceCommitBranchDialog({
    super.key,
    required this.initialBranch,
    required this.shortHash,
    required this.subject,
  });

  @override
  State<WorkspaceCommitBranchDialog> createState() =>
      _WorkspaceCommitBranchDialogState();
}

class _WorkspaceCommitBranchDialogState
    extends State<WorkspaceCommitBranchDialog> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.initialBranch,
  );

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctl.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Branch from Commit'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.shortHash} · ${widget.subject}',
            style: CcType.code(size: 12, color: CcColors.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Branch name'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create and Checkout'),
        ),
      ],
    );
  }
}

class WorkspaceSettingsDraft {
  final String preLaunch;
  final String editor;
  final String agent;

  const WorkspaceSettingsDraft({
    required this.preLaunch,
    required this.editor,
    required this.agent,
  });
}

class WorkspaceSettingsDialog extends StatefulWidget {
  final String workspaceName;
  final String initialPreLaunch;
  final String initialEditor;
  final String initialAgent;

  const WorkspaceSettingsDialog({
    super.key,
    required this.workspaceName,
    this.initialPreLaunch = '',
    this.initialEditor = '',
    this.initialAgent = 'claude',
  });

  @override
  State<WorkspaceSettingsDialog> createState() =>
      _WorkspaceSettingsDialogState();
}

class _WorkspaceSettingsDialogState extends State<WorkspaceSettingsDialog> {
  late final TextEditingController _preCtl = TextEditingController(
    text: widget.initialPreLaunch,
  );
  late final TextEditingController _editorCtl = TextEditingController(
    text: widget.initialEditor,
  );
  late String _agent = _safeAgent(widget.initialAgent);

  static String _safeAgent(String value) =>
      value == 'codex' || value == 'manual' ? value : 'claude';

  @override
  void dispose() {
    _preCtl.dispose();
    _editorCtl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(
    context,
    WorkspaceSettingsDraft(
      preLaunch: _preCtl.text,
      editor: _editorCtl.text,
      agent: _agent,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        '「${widget.workspaceName.isEmpty ? '默认' : widget.workspaceName}」工作区设置',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _preCtl,
            decoration: const InputDecoration(
              labelText: 'pre_launch(起 agent 前跑)',
              hintText: 'nvm use 18',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _editorCtl,
            decoration: const InputDecoration(
              labelText: 'editor(编辑器命令)',
              hintText: 'code .',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('agent', style: TextStyle(color: CcColors.muted)),
              const Spacer(),
              DropdownButton<String>(
                value: _agent,
                items: const [
                  DropdownMenuItem(value: 'claude', child: Text('claude')),
                  DropdownMenuItem(value: 'codex', child: Text('codex')),
                  DropdownMenuItem(value: 'manual', child: Text('manual')),
                ],
                onChanged: (v) => setState(() => _agent = _safeAgent(v ?? '')),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

// _DiffTreeNode is one node of the directory tree built from a commit's changed
// files (the right pane of the 3-pane Log).
class _DiffTreeNode {
  final String name;
  final Map<String, _DiffTreeNode> children = {};
  final List<FileDiff> files = [];
  _DiffTreeNode(this.name);
}

// _LogBranchNode is one folder/leaf in the Git Log branch sidebar.
class _LogBranchNode {
  final String name;
  final String path;
  final Map<String, _LogBranchNode> children = {};
  GitBranch? branch;

  _LogBranchNode(this.name, this.path);
}

class _OpenFile {
  // For a code tab, [path] is the file path. For a read-only diff tab, [diffs]
  // is non-null (the commit/compare files) and [path] is a stable id/label.
  final String path;
  int? line;
  bool dirty = false;
  List<FileDiff>? diffs; // non-null = a read-only diff tab
  String? diffInitialPath; // file to select first inside the diff
  bool
  diffShowTree; // diff tabs: show DiffView's own file tree (false = single-pane)
  // diffReload re-fetches this diff tab's files at a given git context (for the
  // 全部/相关 toggle); captures the source (commit/compare/working). Null = no toggle.
  Future<List<FileDiff>> Function(int context)? diffReload;
  final GlobalKey<CodeEditorPaneState> key = GlobalKey<CodeEditorPaneState>();
  bool previewMode = false; // .md tabs: rendered preview vs source

  _OpenFile(this.path, {this.line}) : diffShowTree = true;
  _OpenFile.diff(
    this.path,
    this.diffs, {
    this.diffInitialPath,
    this.diffShowTree = true,
    this.diffReload,
  }) : line = null;

  bool get isDiff => diffs != null;
  String get name => isDiff ? path : pathBaseName(path);
}

class _CodeSymbol {
  final String name;
  final String kind;
  final int line;
  final int indent;
  final IconData icon;

  const _CodeSymbol({
    required this.name,
    required this.kind,
    required this.line,
    required this.indent,
    required this.icon,
  });
}

class _CodeLocation {
  final String path;
  final int? line;

  const _CodeLocation(this.path, {this.line});

  bool sameAs(_CodeLocation other) => path == other.path && line == other.line;
  String get key => '$path:${line ?? 0}';
  String get name => pathBaseName(path);
  String get label => line == null ? path : '$path:$line';
}

// _ParkedMessage is a cross-user message the user chose to handle "稍后" — kept
// (and persisted) until injected later, manually or when the target session
// next goes idle. [sessionId] is the local session the sender targeted.
class _ParkedMessage {
  final String from, sessionId, body, project, projectId;
  _ParkedMessage(
    this.from,
    this.sessionId,
    this.body, {
    this.project = '',
    this.projectId = '',
  });
  Map<String, dynamic> toJson() => {
    'from': from,
    'session_id': sessionId,
    'body': body,
    'project': project,
    'project_id': projectId,
  };
  _ParkedMessage.fromJson(Map j)
    : from = (j['from'] ?? '').toString(),
      sessionId = (j['session_id'] ?? '').toString(),
      body = (j['body'] ?? '').toString(),
      project = (j['project'] ?? '').toString(),
      projectId = (j['project_id'] ?? '').toString();
}

// WorkspacePage is the project-centric cockpit (desktop only): a terminal deck
// (left, primary) + a Workspace → Project → (Worktrees + Tasks) tree (right).
// Launch a claude/codex session in any project or worktree; tap a task for its
// 对接文档; create/remove workspaces, projects and worktrees (shells the CLI).
// Open agent sessions persist and reopen next launch (TerminalHost.persistKey).
class WorkspacePage extends StatefulWidget {
  final RelayClient? client;
  final AppConfig config;
  // overviewStore is the shared 会话总览 projection: WorkspacePage produces into
  // it, the top-level SessionOverviewPage renders from it (created + injected by
  // HomeShell so both pages share one instance).
  final SessionOverviewStore overviewStore;
  // me + store back the 待办 sidebar (_todosSidebarPanel) — same TodoStore
  // instance HomeShell hands the top-level TodosPage, so both stay in sync
  // off one SSE subscription.
  final Me? me;
  final TodoStore store;
  const WorkspacePage({
    super.key,
    required this.client,
    required this.config,
    required this.overviewStore,
    required this.me,
    required this.store,
  });

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage>
    with
        TerminalHost,
        _GitMixin,
        _SearchMixin,
        _CommitChangesMenu,
        _GitLogBranchMenu,
        _GitLogCommitMenu,
        _GitLogDiffTreeMenu,
        _SymbolIndex,
        FsClipboardActions {
  @override
  late AppConfig _cfg = widget.config; // reloaded after config mutations

  // Shares this workspace (terminals + project files) to the user's phone via
  // the relay. Opt-in — off until the toolbar "cast" toggle. See lib/remote.
  late RemoteHost _remoteHost = _newRemoteHost();
  bool _remoteWasConnected = false;
  int _remoteLastClients = 0;
  String? _remoteShownErr;
  // The most recent desktop→phone send batch, shown live in the progress dialog.
  List<FileXfer> _sendBatch = const [];

  RemoteHost _newRemoteHost() => RemoteHost(
    relayUrl: _cfg.relayUrl,
    token: _cfg.token,
    sessions: () => terms,
    roots: () => [
      for (final ws in _cfg.workspaces)
        for (final p in ws.projects)
          RemoteRoot(p.name, p.path, ws.name, p.projectId),
    ],
    // All workspace names (incl. empty ones) so the phone can see + add projects
    // to a workspace that has no projects yet.
    workspaces: () => [for (final ws in _cfg.workspaces) ws.name],
    onNewSession: _remoteNewSession,
    onCloseSession: _remoteCloseSession,
    onRenameSession: _remoteRenameSession,
    onConfigAction: _remoteConfigAction,
    onAssignTodo: _remoteAssignTodo,
  );

  // Local session message bus: lets sibling sessions (and the agents inside
  // them) forward point-to-point messages to each other without the relay. The
  // desktop cockpit is the single owner that watches the outbox.
  late final LocalBus _localBus = LocalBus(
    registry: localBusRegistry,
    deliver: deliverLocalMessage,
    readOutput: readOutput,
    readUsage: readUsage,
    spawn: _busSpawn,
    kill: killLocalSession,
  );

  // Relay presence: while the workspace is open we hold an SSE subscription (so
  // peers see us online + their cross-user messages reach us) and republish our
  // open sessions on a heartbeat so a peer can target a specific one.
  StreamSubscription<SseEvent>? _relaySse;
  Timer? _sessionHeartbeat;
  // Periodic preview refresh for the 会话总览; runs only while observed (overview
  // page visible) or a phone is connected — see _syncOverviewTicker.
  Timer? _overviewTicker;
  Timer? _hookActivityTicker;
  final Map<String, String> _hookActivityFingerprints = {};
  Offset? _lastContextMenuPosition;

  // Parked ("稍后") cross-user messages: persisted across restarts, surfaced as a
  // toolbar badge, injected later (manually, or auto when the target session
  // next goes idle). _msgDialogOpen guards against stacked inject popups.
  final List<_ParkedMessage> _parked = [];
  bool _msgDialogOpen = false;
  String? _parkedFilePath; // cached path to parked_messages.json

  // Voice: read agent replies aloud (TTS) + voice input (STT) for the active
  // terminal. _ttsOn gates reading; _listening reflects an in-progress mic.
  final VoiceService _voice = VoiceService();
  bool _ttsOn = Prefs.getBool('ws.tts');
  bool _listening = false;
  // When on, `cc-handoff msg read` reads a peer's structured transcript (assistant
  // text + tool markers, from its on-disk JSONL) instead of scraping the screen.
  // `msg read --transcript` forces it per-call regardless of this toggle. Read in
  // LocalBus._process via Prefs('ws.read_transcript').
  bool _readTranscript = Prefs.getBool('ws.read_transcript');

  void _onRemoteChange() {
    if (!mounted) return;
    final h = _remoteHost;
    if (h.connected && !_remoteWasConnected) {
      _remoteSnack('已连接 relay · 在手机端打开「远程」标签即可操作');
      _remoteShownErr = null;
    }
    if (h.clientCount > _remoteLastClients) {
      _remoteSnack('手机已连接（${h.clientCount}）');
    }
    final err = h.lastError;
    if (h.sharing && !h.connected && err != null && err != _remoteShownErr) {
      _remoteShownErr = err;
      _remoteSnack('共享连接失败：$err', error: true);
    }
    _remoteWasConnected = h.connected;
    _remoteLastClients = h.clientCount;
    _syncOverviewTicker(); // a phone connecting/leaving toggles the observer set
    setState(() {});
  }

  // ----------------------------------------------- 会话总览 (session overview) --
  //
  // WorkspacePage is the single producer of the overview snapshot (it owns the
  // live sessions + can read their transcripts). It publishes to the in-process
  // SessionOverviewStore (the desktop top-level page) AND to the RemoteHost
  // (broadcast to phones) from the same built list, so the preview is computed
  // once and both ends agree.

  // _cardFor projects one live session into its overview snapshot: the
  // workspace/project/worktree hierarchy (reusing _projectForFile's longest-
  // prefix match; the worktree comes from the <project>/.worktrees/<name>
  // layout), the derived status, current usage, and the cached preview.
  SessionCard _cardFor(TerminalSession s) {
    final hit = _projectForFile(s.workdir);
    String workspace = '', project = '';
    String? worktree;
    if (hit != null) {
      project = hit.project.name;
      final rel = hit.rel;
      if (rel.startsWith('.worktrees/')) {
        worktree = rel.substring('.worktrees/'.length).split('/').first;
      } else if (rel.isNotEmpty) {
        worktree = rel.split('/').first;
      }
      for (final w in _cfg.workspaces) {
        if (w.projects.any((p) => p.path == hit.project.path)) {
          workspace = w.name;
          break;
        }
      }
    }
    final activities = _recentHookActivities(s, limit: 4);
    final latest = _latestHookActivityFrom(activities);
    final status = _statusFor(s, latest);
    final detail = _statusDetailFor(s, status, latest);
    return SessionCard(
      sid: s.id,
      label: s.label,
      agentKind: s.isAgent ? s.agentKind : '',
      isAgent: s.isAgent,
      workspace: workspace,
      project: project,
      projectId: hit?.project.projectId ?? '',
      worktree: worktree,
      status: status,
      statusDetail: detail,
      usageLabel: s.usage.value?.shortLabel(),
      preview: s.overviewPreview ?? '',
      agentSessionId: s.agentSessionId,
      workdir: s.workdir,
      recentActivity: [for (final a in activities) a.overviewSummary()],
      isSupervisor: s.supervisor,
    );
  }

  HookActivity? _latestHookActivity(TerminalSession s) {
    if (!s.isAgent) return null;
    return _latestHookActivityFrom(_recentHookActivities(s, limit: 8));
  }

  List<HookActivity> _recentHookActivities(TerminalSession s, {int limit = 8}) {
    if (!s.isAgent) return const [];
    return localBusHookActivities(s.id, limit: limit);
  }

  HookActivity? _latestHookActivityFrom(List<HookActivity> recent) {
    for (final a in recent) {
      if (a.event != 'SessionStart') {
        return a;
      }
    }
    return null;
  }

  SessionStatus _statusFor(TerminalSession s, HookActivity? a) {
    if (!s.isAgent) return SessionStatus.shell;
    if (s.needsReview) return SessionStatus.needsReview;
    if (s.busy) return _busyStatusFromHook(a);
    if (a == null) return SessionStatus.waitingInput;
    if (a.event == 'PermissionRequest') return SessionStatus.waitingPermission;
    if (a.event == 'PostToolUse' && a.exitCode != null && a.exitCode != 0) {
      return SessionStatus.toolFailed;
    }
    if (a.event == 'Stop' || a.event == 'SubagentStop') {
      return SessionStatus.waitingInput;
    }
    return SessionStatus.idle;
  }

  SessionStatus _busyStatusFromHook(HookActivity? a) {
    if (a == null) return SessionStatus.working;
    if (a.event == 'PreToolUse') return SessionStatus.runningTool;
    if (a.event == 'PostToolUse') {
      if (a.exitCode != null && a.exitCode != 0) {
        return SessionStatus.toolFailed;
      }
      return SessionStatus.toolDone;
    }
    if (a.event == 'PermissionRequest') return SessionStatus.waitingPermission;
    if (a.event == 'SubagentStart' || a.event == 'SubagentStop') {
      return SessionStatus.subagent;
    }
    if (a.event == 'PreCompact' || a.event == 'PostCompact') {
      return SessionStatus.compacting;
    }
    return SessionStatus.working;
  }

  String _statusDetailFor(
    TerminalSession s,
    SessionStatus status,
    HookActivity? a,
  ) {
    if (!s.isAgent) return s.workdir;
    if (status == SessionStatus.needsReview) {
      final msg = a?.lastAssistantMessage.trim();
      return msg == null || msg.isEmpty
          ? '已完成，等待查看'
          : '已完成：${_clipStatus(msg)}';
    }
    if (status == SessionStatus.waitingInput) return '等待输入';
    if (a == null) return '正在处理';
    return switch (status) {
      SessionStatus.runningTool => '正在运行 ${_toolLabel(a)}',
      SessionStatus.toolDone => '${_toolLabel(a)} 完成，继续处理',
      SessionStatus.toolFailed =>
        '${_toolLabel(a)} 失败${a.exitCode == null ? '' : ' exit ${a.exitCode}'}',
      SessionStatus.waitingPermission =>
        a.toolName.isEmpty ? '等待权限确认' : '等待权限：${a.toolName}',
      SessionStatus.compacting =>
        a.event == 'PreCompact' ? '正在压缩上下文' : '上下文压缩完成',
      SessionStatus.subagent =>
        a.event == 'SubagentStart' ? '子代理开始处理' : '子代理完成，继续处理',
      SessionStatus.idle => '空闲 · 最近 ${_activityBrief(a)}',
      SessionStatus.working => _workingDetail(a),
      _ => '',
    };
  }

  String _workingDetail(HookActivity a) {
    if (a.event == 'UserPromptSubmit') return '已提交 prompt，开始处理';
    return '正在处理 · ${_activityBrief(a)}';
  }

  String _statusTextFor(TerminalSession s) {
    final latest = _latestHookActivity(s);
    final status = _statusFor(s, latest);
    final detail = _statusDetailFor(s, status, latest);
    return detail.isEmpty
        ? statusLabel(status)
        : '${statusLabel(status)} · $detail';
  }

  String _activityBrief(HookActivity a) {
    if (a.toolName.isNotEmpty) return a.toolName;
    if (a.source.isNotEmpty) return a.source;
    return a.event;
  }

  String _toolLabel(HookActivity a) =>
      a.toolName.isNotEmpty ? a.toolName : '工具';

  String _clipStatus(String s, [int max = 120]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  void _publishOverview() {
    if (!mounted) return;
    final cards = [for (final s in terms) _cardFor(s)];
    widget.overviewStore.publish(cards);
    _remoteHost.setOverview(cards);
    _remoteHost.broadcastOverview();
  }

  // markSessionReviewed clears a session's "待 review" flag (完成且未查看) from ANY
  // "the user is now looking at it" path, then republishes so the bus registry +
  // overview drop the highlight. The three viewers funnel through here: local
  // foregrounding (onActiveTermChanged), a phone/web watching it (onSessionWatched),
  // and the overview quick-reply popup previewing its live screen (via
  // overviewStore.reviewedHandler) — so review-clear isn't coupled to the local tab.
  // Guarded so a no-op view (already reviewed / unknown sid) costs nothing.
  void markSessionReviewed(String sid) {
    final s = sessionById(sid);
    if (s == null || !s.needsReview) return;
    s.needsReview = false;
    unawaited(_localBus.syncRegistry());
    _publishOverview();
  }

  void _publishHookActivities() {
    if (!mounted) return;
    var changed = false;
    var overviewChanged = false;
    final overviewObserved =
        widget.overviewStore.observed.value || _remoteHost.clientCount > 0;
    for (final s in terms) {
      if (!s.isAgent) continue;
      final items = localBusHookActivities(s.id, limit: 12);
      final fp = items
          .map(
            (a) =>
                '${a.at.microsecondsSinceEpoch}:${a.event}:${a.toolName}:${a.exitCode ?? ''}',
          )
          .join('|');
      if (_hookActivityFingerprints[s.id] == fp) continue;
      _hookActivityFingerprints[s.id] = fp;
      if (_remoteHost.watching(s.id)) {
        _remoteHost.broadcastActivity(s.id, items);
        _remoteHost.broadcastStatus(
          s.id,
          s.busy,
          _statusTextFor(s),
          usage: s.usage.value?.shortLabel(),
        );
      }
      changed = true;
      if (overviewObserved) overviewChanged = true;
    }
    if (changed) {
      unawaited(_localBus.syncRegistry());
      if (overviewChanged) _publishOverview();
    }
  }

  // _refreshPreview caches a session's latest content: an agent's most-recent
  // reply from its on-disk transcript (falling back to the terminal tail before
  // the first reply), or the terminal tail for a plain shell. Best-effort —
  // never throws. Does NOT publish; callers publish once after a batch.
  Future<void> _refreshPreview(TerminalSession s) async {
    try {
      String preview;
      if (s.isAgent) {
        final path = await s.transcriptPath(); // cached resolution
        preview = path == null
            ? ''
            : await renderTranscriptTail(
                path,
                lines: 6,
                agentKind: s.agentKind,
              );
        if (preview.trim().isEmpty) preview = s.renderSnapshot(6);
      } else {
        preview = s.renderSnapshot(6);
      }
      s.overviewPreview = preview;
    } catch (_) {
      // transient (file rotated / mid-write) — keep the previous preview.
    }
  }

  // _refreshAllPreviews refreshes every session's preview concurrently, then
  // publishes the snapshot ONCE (not per session).
  Future<void> _refreshAllPreviews() async {
    await Future.wait([for (final s in terms.toList()) _refreshPreview(s)]);
    _publishOverview();
  }

  // _syncOverviewTicker starts a ~4s preview refresh only while someone is
  // looking (overview page visible, or a phone connected), and stops it
  // otherwise so idle workspaces do no transcript I/O.
  void _syncOverviewTicker() {
    final want =
        widget.overviewStore.observed.value || _remoteHost.clientCount > 0;
    if (want && _overviewTicker == null) {
      unawaited(_refreshAllPreviews()); // immediate first pass
      _overviewTicker = Timer.periodic(
        const Duration(seconds: 4),
        (_) => unawaited(_refreshAllPreviews()),
      );
    } else if (!want && _overviewTicker != null) {
      _overviewTicker!.cancel();
      _overviewTicker = null;
    }
  }

  void _remoteSnack(String msg, {bool error = false}) => snack(
    context,
    msg,
    background: error ? CcColors.danger : null,
    duration: Duration(seconds: error ? 6 : 3),
    clearPrevious: true,
  );

  // Share-toggle accent: amber while connecting, green once a phone is on,
  // blue when connected but still waiting for one. Null = not sharing.
  Color? _remoteActiveColor() {
    final h = _remoteHost;
    if (!h.sharing) return null;
    if (!h.connected) return CcColors.warning;
    return h.clientCount > 0 ? CcColors.ok : CcColors.accentBright;
  }

  Map<String, List<ListItem>> _tasksByRepo = const {};
  int _taskLoadGeneration = 0;
  // project path -> worktrees. Key absent = not loaded; value null = loading;
  // value list = loaded (possibly empty).
  final Map<String, List<Worktree>?> _worktrees = {};
  int _fileTreeRefreshToken = 0;
  // expansion controllers per project path, so launching a session can expand
  // its project to reveal the new session node.
  final Map<String, ExpansibleController> _proj = {};
  bool _busy = false;
  ListItem? _detailItem;
  @override
  final List<_OpenFile> _codeFiles = [];
  final List<_CodeLocation> _codeBackStack = [];
  final List<_CodeLocation> _codeForwardStack = [];
  @override
  int _activeFile = -1;
  // Split-pane file editor: which pane each open file lives in + each pane's
  // own active file. Both maps stay empty while _filePaneTree is a lone
  // PaneLeaf (the common unsplit case) — every helper below that writes to
  // them is guarded on "already split", so the unsplit render path never
  // touches this state and behaves exactly as before. A path absent from
  // _fileToPane defaults to living in the original 'root' pane/leaf.
  PaneNode _filePaneTree = const PaneLeaf('root');
  String _focusedPaneId = 'root';
  int _panePaneSeq = 0;
  final Map<String, String> _fileToPane = {};
  final Map<String, String?> _paneActivePath = {};
  _BottomTool _bottomTool =
      Prefs.getString('ws.bottomTool', def: 'terminal') == 'git'
      ? _BottomTool.git
      : _BottomTool.terminal;
  // Collapse state for the Commit panel's two JetBrains-style tree roots:
  // tracked "Changes N files" and untracked "Unversioned Files N files".
  bool _changesTreeCollapsed = false;
  bool _untrackedTreeCollapsed = false;
  final _structureQueryCtl = TextEditingController();
  final _workspaceFocus = FocusNode(debugLabel: 'workspace-shell');
  final _commitFocus = FocusNode(debugLabel: 'commit-message');
  final _stashFocus = FocusNode(debugLabel: 'stash-name');
  // 每棵项目文件树一个焦点节点：文件树聚焦时才响应 Cmd/Ctrl+C/X/V，避免抢终端/编辑器的复制粘贴。
  final Map<String, FocusNode> _fileTreeFocus = {};
  final List<String> _recentFiles = [];
  final List<_CodeLocation> _recentLocations = [];
  String _structureQuery = '';
  bool _projectCollapsed = Prefs.getBool('ws.projectCollapsed');
  bool _projectAutoscrollFromSource = Prefs.getBool(
    'ws.projectAutoscrollFromSource',
  );
  String? _revealedProjectFilePath;
  _LeftToolView _leftToolView = _leftToolViewFromPref(
    Prefs.getString('ws.leftTool', def: 'project'),
  );
  bool _detailCollapsed = Prefs.getBool('ws.detailCollapsed');
  // Starts collapsed (unlike _detailCollapsed) — 待办 is a new panel and
  // shouldn't eat canvas width until the user opts in via the toolbar icon.
  bool _todosSidebarCollapsed = Prefs.getBool(
    'ws.todosSidebarCollapsed',
    def: true,
  );
  // The todo currently drilled into inside the sidebar (list ↔ detail swap in
  // place, no Navigator) — null shows the list.
  Todo? _todosSidebarSelected;
  // Starts collapsed, same rationale as _todosSidebarCollapsed above — 收件箱
  // is a new panel too.
  bool _inboxSidebarCollapsed = Prefs.getBool(
    'ws.inboxSidebarCollapsed',
    def: true,
  );
  // The handoff currently drilled into inside the sidebar (list ↔ detail swap
  // in place, no Navigator) — null shows the list. Reuses ListItem +
  // HandoffDetailView, same as _detailItem/_detailPanel.
  ListItem? _inboxSidebarSelected;
  bool _terminalCollapsed = Prefs.getBool('ws.terminalCollapsed');
  double _treeWidth = Prefs.getDouble('ws.treeWidth', def: 340);
  double _detailWidth = Prefs.getDouble('ws.detailWidth', def: 520);
  double _todosSidebarWidth = Prefs.getDouble('ws.todosSidebarWidth', def: 420);
  double _inboxSidebarWidth = Prefs.getDouble('ws.inboxSidebarWidth', def: 420);
  double _terminalHeight = Prefs.getDouble('ws.terminalHeight', def: 360);
  double _logBranchWidth = Prefs.getDouble('ws.logBranchWidth', def: 240);
  double _logDiffWidth = Prefs.getDouble('ws.logDiffWidth', def: 340);
  final Set<String> _logBranchExpanded = {};
  final Set<String> _logBranchGroupsCollapsed = {};
  // shared comfortable-but-compact density for the tree's leaf rows.
  static const _tileDensity = VisualDensity(vertical: -1);
  // Fixed height of a Git Log commit row — shared by the ListView itemExtent and
  // the graph rail's CustomPaint so per-row graph slices stack seamlessly.
  static const _logRowHeight = 30.0;

  @override
  String? get persistKey => 'workspace_sessions';

  static _LeftToolView _leftToolViewFromPref(String value) => switch (value) {
    'structure' => _LeftToolView.structure,
    'changes' => _LeftToolView.changes,
    'stash' => _LeftToolView.stash,
    // branches/log moved to the bottom panel; a stale pref falls back to Commit.
    _ => _LeftToolView.project,
  };

  static String _leftToolPref(_LeftToolView view) => switch (view) {
    _LeftToolView.project => 'project',
    _LeftToolView.structure => 'structure',
    _LeftToolView.changes => 'changes',
    _LeftToolView.stash => 'stash',
  };

  // True (non-null) for the left's git views (changes/stash) — used to decide
  // whether the left panel shows git and to trigger a refresh.
  static _GitView? _gitViewForLeftTool(_LeftToolView view) => switch (view) {
    _LeftToolView.changes => _GitView.changes,
    _LeftToolView.stash => _GitView.stash,
    _ => null,
  };

  Future<void> _ensureSupervisorDocs(String dir) {
    return Cli.run(['supervisor', 'init', '--dir', dir]).catchError((_) => '');
  }

  @override
  void initState() {
    super.initState();
    onTermsChanged = () {
      _remoteHost.broadcastSessions();
      _localBus.syncRegistry(); // keep sessions.json current for `msg list`
      _publishSessions(); // keep the relay's session registry current too
      _publishOverview(); // membership changed → refresh the 会话总览 snapshot
      unawaited(_refreshAllPreviews()); // pull a preview for any new session
    };
    // A session's busy state flipped (turn start/finish) → keep the overview's
    // 思考中/待 review state live on both the desktop page and connected phones.
    onAgentBusyChanged = (s) {
      unawaited(_localBus.syncRegistry());
      _publishOverview();
    };
    // An agent finishing a turn pops a desktop banner (TerminalHost) and pushes
    // the same "任务通知" to any connected phone (reuses the shared copy helper).
    onAgentDone = (s) {
      final (title, body) = agentDoneNotice(s);
      _remoteHost.broadcastNotify(title, body, sid: s.id);
      _resumeParkedFor(s); // a freed-up session can take a parked message
      // Extract the reply once (advances the cursor): speak it locally if our
      // toggle is on for the active session (so multiple agents don't talk over
      // each other), and/or push it to a phone watching this session so it can
      // read the reply aloud too.
      // Turn finished → refresh this session's reply preview (the just-produced
      // assistant message is what the user reviews) then republish. needsReview
      // was already set in _fireDone and republished via onBusyChanged.
      unawaited(
        _refreshPreview(s).then((_) {
          unawaited(_localBus.syncRegistry());
          _publishOverview();
        }),
      );
      final speakLocal =
          _ttsOn && terms.isNotEmpty && terms[activeTerm].id == s.id;
      final phoneWants = _remoteHost.watching(s.id);
      if (speakLocal || phoneWants) {
        _voice.readReplyText(s).then((text) {
          if (text == null || text.isEmpty) {
            // No prose reply (e.g. tool-only turn) — still clear the phone's
            // "thinking" Live Activity so it doesn't spin forever.
            if (phoneWants) _remoteHost.broadcastStatus(s.id, false, '已完成');
            return;
          }
          if (speakLocal) _voice.speak(text);
          if (phoneWants) {
            _remoteHost.broadcastReply(s.id, text);
            _remoteHost.broadcastStatus(s.id, false, text);
          }
        });
      }
    };
    // Right-click "发送到在线用户…" in any terminal routes the selection here
    // only when relay is actually configured.
    _syncOnlineSendAction();
    // When the active session changes (any path: switch/add/close/restore),
    // re-arm TTS so it reads the now-front session's future turns, not its
    // backlog or another tab's.
    onActiveTermChanged = () {
      if (_ttsOn && terms.isNotEmpty) _voice.armBaseline(terms[activeTerm]);
      // Bringing a session to the front = the user is looking at it → mark it
      // reviewed (shared entry, clears 待 review + republishes).
      if (activeTerm >= 0 && activeTerm < terms.length) {
        markSessionReviewed(terms[activeTerm].id);
      }
      // Every active change also republishes so the now-front session's freshly
      // refreshed usage lands in the registry/overview (markSessionReviewed above
      // only republishes when it actually clears a review).
      unawaited(_localBus.syncRegistry());
      _publishOverview();
    };
    // The 会话总览 page (a top-level nav sibling that can't reach `terms`) opens a
    // session through the shared store: reopen its tab, focus it, reveal the
    // bottom terminal. onActiveTermChanged (above) then clears its 待 review.
    widget.overviewStore.openHandler = (sid) {
      final i = terms.indexWhere((t) => t.id == sid);
      if (i < 0) return;
      reopenTermView(i);
      if (_terminalCollapsed) setState(() => _terminalCollapsed = false);
    };
    // Quick-reply popup support: inject input into a live session and read its
    // current screen, so the overview can confirm/reply without switching here.
    widget.overviewStore.inputHandler = (sid, text, {submit = false}) {
      final s = sessionById(sid);
      if (s == null) return;
      if (text.isNotEmpty) {
        if (submit) {
          s.pasteText(text); // bracketed paste …
          s.sendText('\r'); // … then submit
        } else {
          s.sendText(text); // raw keys (menu digit / y / Esc)
        }
      } else if (submit) {
        s.sendText('\r'); // bare 确认
      }
    };
    widget.overviewStore.previewHandler = (sid) async => sessionById(
      sid,
    )?.snapshotSized(); // coloured live screen + geometry (incl. prompt)
    // Opening a session's quick-reply preview in the overview = viewing it → clear
    // its 待 review (the overview can't reach `terms`, so it routes through here).
    widget.overviewStore.reviewedHandler = markSessionReviewed;
    // 待办 top-level page dispatch support (also can't reach `terms`/`_cfg`
    // directly): deliverLocalMessage already matches dispatchHandler's shape
    // verbatim; spawnHandler needs project resolution + optional worktree
    // creation first, so it routes through _spawnForDispatch below.
    widget.overviewStore.dispatchHandler = deliverLocalMessage;
    widget.overviewStore.spawnHandler = _spawnForDispatch;
    // "打成胶囊": capture+distill a session into a shareable capsule, then ship
    // it. Both need config/relay + Cli, which only live here.
    widget.overviewStore.captureCapsuleHandler = _captureSessionCapsule;
    widget.overviewStore.submitCapsuleHandler = _submitSessionCapsule;
    // Run the light preview-refresh ticker only while the overview page is on
    // screen or a phone is connected (both observe the snapshot).
    widget.overviewStore.observed.addListener(_syncOverviewTicker);
    _publishOverview(); // seed the store (restore + later changes republish)
    // When a phone opens a session, baseline its reading cursor so we push it
    // future replies (not the backlog) for phone-side TTS.
    _remoteHost.onSessionWatched = (sid) {
      final s = sessionById(sid);
      if (s != null) _voice.armBaseline(s);
      // A phone/web opening (watching) the session = viewing it → clear 待 review.
      markSessionReviewed(sid);
    };
    // A phone-sent file landed in ~/Downloads/cc-recv — toast it with a
    // shortcut to reveal it in Finder.
    _remoteHost.onFileReceived = (name, path) {
      if (!mounted) return;
      final m = ScaffoldMessenger.of(context);
      m.clearSnackBars();
      m.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('收到手机文件：$name'),
          action: SnackBarAction(
            label: '在 Finder 中显示',
            onPressed: () => Process.run('open', ['-R', path]),
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    };
    // A file sent from inside a session (an image): the host already pasted its
    // path into that session's terminal, so just confirm it landed.
    _remoteHost.onSessionFile = (sid, name, path) {
      if (!mounted) return;
      snack(context, '手机发来图片：$name（已粘贴到会话）', clearPrevious: true);
    };
    // Keep the mic button in sync with the recognizer (handles silence/timeout
    // auto-stop, not just explicit stop).
    _voice.onListeningChange = (v) {
      if (mounted) setState(() => _listening = v);
    };
    _voice.init();
    _localBus.start();
    _hookActivityTicker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _publishHookActivities(),
    );
    // Wire the bus lifecycle hooks so busy agent sessions can record activity
    // and receive sibling messages at Stop. Idempotent + env-guarded;
    // fire-and-forget so a missing/old cc-handoff binary never blocks startup.
    Cli.installConfiguredBusHooks();
    _connectRelayPresence();
    _loadParked();
    // Any newly spawned session surfaces the bottom terminal panel (even if it
    // was showing Git) so the launched agent is visible. Restore doesn't go
    // through addTerm, so a restored Git view isn't hijacked on startup.
    onTermAdded = () => _setBottomTool(_BottomTool.terminal);
    _remoteHost.addListener(_onRemoteChange);
    PluginManager.instance.detectAll();
    PluginManager.instance.addListener(_onPluginsChanged);
    _loadTasks();
    // After restoring persisted sessions, expand the projects that own them so
    // the session tabs are visible in the tree.
    restoreTerms().then((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _expandWithSessions(),
      );
    });
  }

  ExpansibleController _ctlFor(String path) =>
      _proj.putIfAbsent(path, ExpansibleController.new);

  @override
  void didUpdateWidget(covariant WorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final relayChanged =
        oldWidget.config.relayUrl != widget.config.relayUrl ||
        oldWidget.config.token != widget.config.token ||
        oldWidget.config.identity != widget.config.identity ||
        (oldWidget.client == null) != (widget.client == null);
    if (!relayChanged && oldWidget.config == widget.config) return;

    _cfg = widget.config;
    _syncOnlineSendAction();
    if (relayChanged) {
      _remoteHost.removeListener(_onRemoteChange);
      _remoteHost.dispose();
      _remoteHost = _newRemoteHost();
      _remoteHost.addListener(_onRemoteChange);
      _relaySse?.cancel();
      _relaySse = null;
      _sessionHeartbeat?.cancel();
      _sessionHeartbeat = null;
      if (widget.client == null) {
        _tasksByRepo = const {};
        _detailItem = null;
        _inboxSidebarSelected = null;
        _todosSidebarSelected = null;
      }
      _connectRelayPresence();
    } else {
      _publishSessions();
    }
    _loadTasks();
    _publishOverview();
  }

  // Format-plugin availability/enable changes (detection finishing, toggles in
  // the plugins dialog) repaint the editor toolbar's 格式化 / 预览 affordances.
  void _onPluginsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _formatActiveFile() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    final f = _codeFiles[_activeFile];
    if (f.isDiff) return;
    await f.key.currentState?.formatViaPlugin();
  }

  // 格式化 / 源码-预览 affordances for the active code tab (shared with the
  // standalone EditorPage; they collapse to nothing when not applicable).
  Widget _formatTabButton() => formatPluginButton(
    path: _codeFiles[_activeFile].path,
    onFormat: _formatActiveFile,
  );

  Widget _previewTabButton() {
    final f = _codeFiles[_activeFile];
    return previewToggleButton(
      path: f.path,
      previewMode: f.previewMode,
      onToggle: () => setState(() => f.previewMode = !f.previewMode),
    );
  }

  @override
  void dispose() {
    _commitCtl.dispose();
    _stashCtl.dispose();
    _structureQueryCtl.dispose();
    _workspaceFocus.dispose();
    _commitFocus.dispose();
    _stashFocus.dispose();
    for (final n in _fileTreeFocus.values) {
      n.dispose();
    }
    _remoteHost.removeListener(_onRemoteChange);
    PluginManager.instance.removeListener(_onPluginsChanged);
    _remoteHost.dispose();
    _localBus.dispose();
    _relaySse?.cancel();
    _sessionHeartbeat?.cancel();
    _overviewTicker?.cancel();
    _hookActivityTicker?.cancel();
    widget.overviewStore.observed.removeListener(_syncOverviewTicker);
    widget.overviewStore.openHandler = null;
    widget.overviewStore.inputHandler = null;
    widget.overviewStore.previewHandler = null;
    widget.overviewStore.captureCapsuleHandler = null;
    widget.overviewStore.submitCapsuleHandler = null;
    widget.overviewStore.reviewedHandler = null;
    widget.overviewStore.dispatchHandler = null;
    widget.overviewStore.spawnHandler = null;
    _voice.dispose();
    disposeTerms();
    LspManager.instance.shutdownAll();
    super.dispose();
  }

  // ----------------------------------------------- cross-user messaging ----

  // _connectRelayPresence holds an SSE subscription (keeps us online for peers +
  // receives their messages) and republishes our sessions on a heartbeat so a
  // peer can target a specific one. No-op when the relay isn't configured.
  // _relayConfigured is true when we have a relay URL + token to talk to.
  bool get _relayConfigured =>
      widget.client != null &&
      _cfg.relayUrl.isNotEmpty &&
      _cfg.token.isNotEmpty;
  bool get _canSendToOnline => _relayConfigured;

  void _syncOnlineSendAction() {
    onSendToOnline = _canSendToOnline
        ? (text) => _showSendToOnlineUser(
            text,
            sourcePath: activeTerm >= 0 && activeTerm < terms.length
                ? terms[activeTerm].workdir
                : null,
          )
        : null;
  }

  ({String? projectId, String? projectName, bool ambiguous})
  _onlineSendProjectScopeForSource(String? sourcePath) {
    if (sourcePath == null) {
      return (projectId: null, projectName: null, ambiguous: false);
    }
    final project = _projectForFile(sourcePath)?.project;
    if (project == null) {
      return (projectId: null, projectName: null, ambiguous: false);
    }
    final me = widget.me;
    if (me == null) {
      return (projectId: null, projectName: project.name, ambiguous: true);
    }
    final projectId = onlineSendProjectIdForLocalProject(me.projects, project);
    if (projectId != null) {
      return (
        projectId: projectId,
        projectName: project.name,
        ambiguous: false,
      );
    }
    return (
      projectId: null,
      projectName: project.name,
      ambiguous: onlineSendProjectNameIsAmbiguous(me.projects, project.name),
    );
  }

  Future<Set<String>?> _onlineSendAllowedIdentities(
    RelayClient client,
    String? projectId,
  ) async {
    if (projectId == null) return null;
    final detail = await client.project(projectId);
    OrganizationDetail? organization;
    final orgId = detail.project.orgId;
    if (orgId.isNotEmpty) {
      try {
        organization = await client.organization(orgId);
      } catch (_) {}
    }
    return onlineSendProjectReachableIdentities(
      detail,
      organization: organization,
    );
  }

  void _connectRelayPresence() {
    if (!_relayConfigured || _cfg.identity.isEmpty) return;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    _relaySse = subscribeEvents(relayUrl, token, identity).listen((ev) {
      if (!_isCurrentRelayIdentity(relayUrl, token, identity)) return;
      _onRelayEvent(ev);
    }, onError: (_) {});
    _publishSessions();
    _sessionHeartbeat = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _publishSessions(),
    );
  }

  bool _isCurrentRelayIdentity(
    String relayUrl,
    String token,
    String identity,
  ) =>
      mounted &&
      _relayConfigured &&
      _cfg.relayUrl == relayUrl &&
      _cfg.token == token &&
      _cfg.identity == identity;

  bool _isCurrentRelayClient(RelayClient client) =>
      mounted && _relayConfigured && identical(client, widget.client);

  // _publishSessions advertises our open sessions only when publish_sessions is
  // enabled. Disabled still posts an empty list, clearing any older public list.
  void _publishSessions() {
    if (!_relayConfigured) return;
    unawaited(_publishSessionsNow().catchError((_) {}));
  }

  Future<void> _publishSessionsNow() async {
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    if (!_isCurrentRelayIdentity(relayUrl, token, identity)) return;
    var publish = _cfg.publishSessions;
    try {
      publish = (await AppConfig.load())?.publishSessions ?? publish;
    } catch (_) {}
    if (!_isCurrentRelayIdentity(relayUrl, token, identity)) return;
    final list = publish
        ? [
            for (final s in terms)
              {
                'id': s.id,
                'label': s.label,
                'project': _projectForFile(s.workdir)?.project.name ?? '',
                'project_id':
                    _projectForFile(s.workdir)?.project.projectId.trim() ?? '',
                'workdir': s.workdir,
              },
          ]
        : const <Map<String, dynamic>>[];
    await widget.client!.publishSessions(list);
  }

  // _onRelayEvent acts on the cross-user message.deliver event (other relay
  // events — handoffs/presence — are handled by the inbox page).
  void _onRelayEvent(SseEvent ev) {
    if (ev.type != 'message.deliver') return;
    Map? m;
    try {
      final d = jsonDecode(ev.data);
      if (d is Map) m = d;
    } catch (_) {}
    if (m == null) return;
    final body = (m['body'] ?? '').toString();
    if (body.isEmpty) return;
    final from = (m['from'] ?? '').toString();
    final sid = (m['session_id'] ?? '').toString();
    final project = (m['project'] ?? '').toString();
    final projectId = (m['project_id'] ?? '').toString();
    // Don't stack popups: if one is already open, park the new arrival straight
    // into the badge instead.
    if (_msgDialogOpen) {
      _park(from, sid, body, project: project, projectId: projectId);
    } else {
      _showIncomingMessage(
        from,
        sid,
        body,
        project: project,
        projectId: projectId,
      );
    }
  }

  // _showIncomingMessage asks the user to confirm (and pick the target session)
  // before injecting a peer's text — cross-user content never lands in a session
  // unprompted. Default target = the session the sender picked, else the active.
  Future<void> _showIncomingMessage(
    String from,
    String sid,
    String body, {
    String project = '',
    String projectId = '',
  }) async {
    if (!mounted) return;
    if (terms.isEmpty) {
      _snack('$from 发来内容,但当前没有会话可注入');
      return;
    }
    final candidates = [
      for (final s in terms)
        if (_incomingMessageSessionMatchesProject(
          s,
          project: project,
          projectId: projectId,
        ))
          s,
    ];
    if (candidates.isEmpty) {
      _park(
        from,
        sid,
        body,
        project: project,
        projectId: projectId,
        message: '没有匹配项目的会话,已挂起',
      );
      return;
    }
    final active = activeTerm >= 0 && activeTerm < terms.length
        ? terms[activeTerm]
        : null;
    var target =
        candidates.where((s) => s.id == sid).firstOrNull ??
        candidates.where((s) => s == active).firstOrNull ??
        candidates.first;
    _msgDialogOpen = true;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final dialogWidth = onlineSendDialogWidth(
            MediaQuery.sizeOf(ctx),
            preferred: 460,
          );
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            title: Text(
              '$from 发来内容',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            content: SizedBox(
              width: dialogWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('注入到会话:'),
                  DropdownButton<TerminalSession>(
                    value: target,
                    isExpanded: true,
                    menuMaxHeight: onlineSendSessionMenuMaxHeight(
                      MediaQuery.sizeOf(ctx),
                    ),
                    items: [
                      for (final s in candidates)
                        DropdownMenuItem(
                          value: s,
                          child: Text(
                            s.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setSt(() {
                      if (v != null) target = v;
                    }),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: onlineSendIncomingBodyMaxHeight(
                        MediaQuery.sizeOf(ctx),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Text(body, style: CcType.code(size: 12)),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'ignore'),
                child: const Text('忽略'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'park'),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'inject'),
                child: const Text('注入'),
              ),
            ],
          );
        },
      ),
    );
    _msgDialogOpen = false;
    switch (result) {
      case 'inject':
        final liveTarget = sessionById(target.id);
        if (liveTarget == null ||
            !incomingMessageTargetIsOpen(terms, liveTarget) ||
            !_incomingMessageSessionMatchesProject(
              liveTarget,
              project: project,
              projectId: projectId,
            )) {
          _park(
            from,
            sid,
            body,
            project: project,
            projectId: projectId,
            message: '目标会话已关闭或项目不匹配,已挂起',
          );
          return;
        }
        liveTarget.pasteText('[来自 $from · 远程] $body', submit: false);
        _snack('已注入到 ${liveTarget.label}');
      case 'park':
        _park(from, sid, body, project: project, projectId: projectId);
    }
  }

  bool _incomingMessageSessionMatchesProject(
    TerminalSession session, {
    required String project,
    required String projectId,
  }) {
    final hit = _projectForFile(session.workdir)?.project;
    return incomingMessageSessionMatchesProject(
      sessionProjectId: hit?.projectId ?? '',
      sessionProjectName: hit?.name ?? '',
      messageProjectId: projectId,
      messageProjectName: project,
    );
  }

  // _park stashes a cross-user message for later; surfaced via the toolbar badge.
  void _park(
    String from,
    String sid,
    String body, {
    String project = '',
    String projectId = '',
    String? message,
  }) {
    _mutateParked(
      () => _parked.add(
        _ParkedMessage(from, sid, body, project: project, projectId: projectId),
      ),
    );
    _snack(message ?? '已挂起,稍后处理');
  }

  // _mutateParked applies [fn] to the parked list (rebuilds the toolbar badge)
  // and persists once — the single seam for every add/remove.
  void _mutateParked(void Function() fn) {
    setState(fn);
    _saveParked();
  }

  Future<String> _parkedPath() async => _parkedFilePath ??=
      '${(await getApplicationSupportDirectory()).path}/parked_messages.json';

  Future<void> _loadParked() async {
    try {
      final f = File(await _parkedPath());
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is! List || !mounted) return;
      setState(() {
        _parked
          ..clear()
          ..addAll(data.whereType<Map>().map(_ParkedMessage.fromJson));
      });
    } catch (_) {}
  }

  Future<void> _saveParked() async {
    try {
      await File(
        await _parkedPath(),
      ).writeAsString(jsonEncode([for (final m in _parked) m.toJson()]));
    } catch (_) {}
  }

  // _resumeParkedFor pops the inject confirm for the first message parked for a
  // session that just went idle — unless a dialog is already open.
  void _resumeParkedFor(TerminalSession s) {
    if (_msgDialogOpen) return;
    final i = _parked.indexWhere((m) => m.sessionId == s.id);
    if (i < 0) return;
    final m = _parked[i];
    _mutateParked(() => _parked.removeAt(i));
    _showIncomingMessage(
      m.from,
      m.sessionId,
      m.body,
      project: m.project,
      projectId: m.projectId,
    );
  }

  // _showParkedList lets the user inject (处理) or discard (忽略) parked messages
  // at any time from the toolbar badge.
  Future<void> _showParkedList() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final dialogWidth = onlineSendDialogWidth(
            MediaQuery.sizeOf(ctx),
            preferred: 460,
          );
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            title: Text('待处理 (${_parked.length})'),
            content: SizedBox(
              width: dialogWidth,
              child: _parked.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('没有待处理的消息'),
                    )
                  : ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: onlineSendParkedListMaxHeight(
                          MediaQuery.sizeOf(ctx),
                        ),
                      ),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final m in List.of(_parked))
                            ListTile(
                              dense: true,
                              title: Text(
                                '${m.from} → '
                                '${sessionById(m.sessionId)?.label ?? m.sessionId}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                m.body.split('\n').first,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: SizedBox(
                                width: 92,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                      onPressed: () {
                                        _mutateParked(() => _parked.remove(m));
                                        Navigator.pop(ctx);
                                        _showIncomingMessage(
                                          m.from,
                                          m.sessionId,
                                          m.body,
                                          project: m.project,
                                          projectId: m.projectId,
                                        );
                                      },
                                      child: const Text('处理'),
                                    ),
                                    SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        tooltip: '忽略',
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 16,
                                        ),
                                        onPressed: () {
                                          _mutateParked(
                                            () => _parked.remove(m),
                                          );
                                          setSt(
                                            () {},
                                          ); // also refresh this dialog's list
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  // _showSendToOnlineUser sends [text] to a specific session of a chosen online
  // user: pick a user → load their published sessions → pick one → send.
  Future<void> _showSendToOnlineUser(String text, {String? sourcePath}) async {
    if (text.trim().isEmpty) {
      _snack('没有可发送的内容');
      return;
    }
    if (!_relayConfigured) {
      _snack('未配置 relay,无法发给在线用户');
      return;
    }
    final client = widget.client!;
    final scope = _onlineSendProjectScopeForSource(sourcePath);
    List<OnlineUser> users;
    try {
      if (scope.ambiguous) throw const _OnlineSendProjectScopeError();
      final allowedIdentities = await _onlineSendAllowedIdentities(
        client,
        scope.projectId,
      );
      if (!_isCurrentRelayClient(client)) return;
      users = onlineSendSelectableUsers(
        await client.onlineUsers(),
        _cfg.identity,
        allowedIdentities: allowedIdentities,
      );
    } on _OnlineSendProjectScopeError {
      if (!_isCurrentRelayClient(client)) return;
      _snack('当前项目未绑定唯一团队项目,无法选择团队在线用户');
      return;
    } catch (e) {
      if (!_isCurrentRelayClient(client)) return;
      _snack('获取团队在线用户失败:${errorText(e)}');
      return;
    }
    if (!mounted) return;
    if (!_isCurrentRelayClient(client)) return;
    if (users.isEmpty) {
      _snack('当前没有可发送的团队在线用户');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        String? selected;
        List<RemoteSession>? sessions; // null = 未加载
        var loading = false;
        var loadSeq = 0;
        return StatefulBuilder(
          builder: (ctx, setSt) {
            Future<void> pickUser(String identity) async {
              final seq = ++loadSeq;
              setSt(() {
                selected = identity;
                sessions = null;
                loading = true;
              });
              List<RemoteSession> loaded;
              try {
                loaded = await client.userSessions(identity);
              } catch (_) {
                loaded = const [];
              }
              if (!mounted ||
                  !ctx.mounted ||
                  !_isCurrentRelayClient(client) ||
                  seq != loadSeq ||
                  !onlineSendIdentitySelected(selected, identity)) {
                return;
              }
              final scoped = onlineSendSessionsForProject(
                loaded,
                projectId: scope.projectId,
                projectName: scope.projectName,
              );
              setSt(() {
                sessions = scoped;
                loading = false;
              });
            }

            Future<void> send(RemoteSession s) async {
              if (!_isCurrentRelayClient(client)) {
                Navigator.pop(ctx);
                _snack('账号已切换,请重新选择在线用户');
                return;
              }
              Navigator.pop(ctx);
              try {
                await client.sendMessage(
                  selected!,
                  s.id,
                  text,
                  project: s.project,
                  projectId: s.projectId,
                );
                if (!_isCurrentRelayClient(client)) return;
                _snack('已发送到 $selected · ${s.label},等待对方确认');
              } catch (e) {
                if (!_isCurrentRelayClient(client)) return;
                _snack('发送失败:${errorText(e)}');
              }
            }

            final dialogWidth = onlineSendDialogWidth(MediaQuery.sizeOf(ctx));
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              title: const Text('发送到在线用户'),
              content: SizedBox(
                width: dialogWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('在线用户:'),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: onlineSendUserListMaxHeight(
                          MediaQuery.sizeOf(ctx),
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final chipWidth = onlineSendUserChipWidth(
                              constraints,
                            );
                            return Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final u in users)
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: chipWidth,
                                    ),
                                    child: ChoiceChip(
                                      label: Text(
                                        u.identity,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      selected: onlineSendIdentitySelected(
                                        selected,
                                        u.identity,
                                      ),
                                      onSelected: (_) => pickUser(u.identity),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    const Divider(),
                    if (selected == null)
                      const Text('选择一个用户查看其会话')
                    else if (loading)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if ((sessions ?? const []).isEmpty)
                      const Text('该用户当前没有可发送的会话')
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: onlineSendSessionMenuMaxHeight(
                            MediaQuery.sizeOf(ctx),
                          ),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: sessions!.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final s = sessions![i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.terminal_rounded,
                                size: 16,
                              ),
                              title: Text(
                                s.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: s.project.isEmpty
                                  ? null
                                  : Text(
                                      s.project,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              onTap: () => send(s),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------- data ----

  AppConfig _mergeReloadedLocalConfig(AppConfig loaded) => AppConfig(
    _cfg.relayUrl,
    _cfg.token,
    _cfg.identity,
    loaded.repos,
    loaded.workspaces,
    loaded.agent,
    loaded.workspaceRoot,
    loaded.gradeCommand,
    loaded.linearToken,
    loaded.githubToken,
    loaded.terminalApp,
    loaded.claudeCommand,
    loaded.codexCommand,
    loaded.publishSessions,
  );

  Future<void> _loadTasks() async {
    final generation = ++_taskLoadGeneration;
    final client = widget.client;
    if (client == null) {
      if (_isCurrentTaskLoad(generation, client)) {
        setState(() => _tasksByRepo = const {});
      }
      return;
    }
    try {
      final lists = await Future.wait([
        client.handoffs(as: 'recipient'),
        client.handoffs(as: 'sender'),
      ]);
      final byId = <String, ListItem>{};
      for (final it in [...lists[0], ...lists[1]]) {
        byId[it.id] = it;
      }
      final byRepo = <String, List<ListItem>>{};
      for (final it in byId.values) {
        (byRepo[it.repoName] ??= []).add(it);
      }
      if (_isCurrentTaskLoad(generation, client)) {
        setState(() => _tasksByRepo = byRepo);
      }
    } catch (_) {}
  }

  bool _isCurrentTaskLoad(int generation, RelayClient? client) =>
      mounted &&
      generation == _taskLoadGeneration &&
      identical(client, widget.client);

  Future<void> _ensureWorktrees(String path) async {
    if (_worktrees.containsKey(path)) return;
    if (!mounted) return;
    setState(() => _worktrees[path] = null); // mark loading
    final wts = await listWorktrees(path);
    if (mounted) setState(() => _worktrees[path] = wts);
  }

  Future<void> _reloadConfig() async {
    final cfg = await AppConfig.load();
    if (cfg != null && mounted) {
      setState(() {
        _cfg = _mergeReloadedLocalConfig(cfg);
        _syncOnlineSendAction();
      });
      // Desktop-initiated workspace/project/worktree changes must reach connected
      // phones too — otherwise they only see config edits the phone itself made.
      _remoteHost.broadcastRoots();
    }
  }

  Future<void> _reloadWorktrees(String path) async {
    if (!mounted) return;
    setState(() => _worktrees.remove(path));
    await _ensureWorktrees(path);
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _worktrees.clear());
    await _reloadConfig();
    await _loadTasks();
    await _refreshGit();
  }

  @override
  void _snack(String s) {
    if (mounted) snack(context, s);
  }

  // _runCli runs a CLI mutation with a busy indicator + friendly errors, then an
  // optional refresh (reload config / worktrees).
  Future<void> _runCli(
    Future<void> Function() action,
    String okMsg, {
    Future<void> Function()? after,
  }) async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      if (after != null) {
        await after();
        if (!mounted) return;
      }
      _snack(okMsg);
    } catch (e) {
      if (mounted) _snack(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _launch(
    String dir,
    String agent,
    String preLaunch, {
    bool supervisor = false,
    bool todoAssistant = false,
    String? resumeAgentSessionId,
  }) {
    if (supervisor) unawaited(_ensureSupervisorDocs(dir));
    // Pass agent + preLaunch structured (not pre-joined): addTerm mints a fixed
    // session id for claude and TerminalSession rebuilds the actual command with
    // the right resume binding, so a reopened tab returns to its conversation.
    // resumeAgentSessionId (the 待办 "打开/恢复会话" respawn path) instead binds
    // that already-known transcript UUID up front, same as an app-restart
    // restore.
    addTerm(
      dir,
      agent,
      agent: agent,
      preLaunch: preLaunch.trim(),
      supervisor: supervisor,
      todoAssistant: todoAssistant,
      agentSessionId: resumeAgentSessionId,
      resume: resumeAgentSessionId != null && resumeAgentSessionId.isNotEmpty,
    );
  }

  // _openAgent launches a session in [dir] under project [p], then expands the
  // project so its new session node (the "tab") is visible in the tree.
  void _openAgent(
    ProjectCfg p,
    String dir,
    String agent,
    String preLaunch, {
    bool supervisor = false,
    bool todoAssistant = false,
    String? resumeAgentSessionId,
  }) {
    // _launch → addTerm → onTermAdded already surfaces + expands the terminal
    // panel; just expand the project so its new session node is visible.
    _launch(
      dir,
      agent,
      preLaunch,
      supervisor: supervisor,
      todoAssistant: todoAssistant,
      resumeAgentSessionId: resumeAgentSessionId,
    );
    final ctl = _ctlFor(p.path);
    if (!ctl.isExpanded) ctl.expand();
  }

  // _newShellTerminal opens a plain interactive shell (empty command) so the
  // user has a terminal they can type in and scroll, separate from the agent
  // TUIs. Runs in the current git project's dir, else the first project, else $HOME.
  void _newShellTerminal() {
    var cwd = _currentGitProject?.path ?? '';
    if (cwd.isEmpty) {
      for (final w in _cfg.workspaces) {
        if (w.projects.isNotEmpty) {
          cwd = w.projects.first.path;
          break;
        }
      }
    }
    if (cwd.isEmpty) cwd = Platform.environment['HOME'] ?? '/';
    addTerm(cwd, ''); // '' = plain interactive shell
  }

  // _sendFileToPhone opens a native file picker and offers the chosen file to
  // every connected phone over the relay (broadcast). Each phone independently
  // accepts/rejects (see RemoteHost.sendFileToClients); a live dialog tracks each
  // recipient's progress.
  Future<void> _sendFileToPhone() async {
    final res = await FilePicker.platform.pickFiles();
    final path = res?.files.single.path;
    if (path == null || !mounted) return; // cancelled
    final batch = _remoteHost.sendFileToClients(path);
    if (batch.isEmpty) {
      _remoteSnack('没有已连接的手机', error: true);
      return;
    }
    _sendBatch = batch;
    _showOutgoingDialog(pathBaseName(path));
  }

  // _showOutgoingDialog renders the just-offered batch with a live per-phone
  // progress row (等待接受 → 传输中 X% → 已完成/已拒绝/失败), rebuilt as the host
  // notifies. The user can close it any time; transfers keep running.
  void _showOutgoingDialog(String fileName) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: CcColors.panel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: ListenableBuilder(
              listenable: _remoteHost,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.upload_rounded,
                        color: CcColors.accentBright,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '发送到手机 · $fileName',
                          style: const TextStyle(
                            color: CcColors.text,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  for (final x in _sendBatch) _hostXferRow(x),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hostXferRow(FileXfer x) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                x.peerName ?? '手机',
                style: const TextStyle(color: CcColors.text),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              _hostXferStatus(x),
              style: TextStyle(color: _hostXferColor(x), fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: x.status == XferStatus.waiting ? null : x.fraction,
            minHeight: 4,
          ),
        ),
      ],
    ),
  );

  String _hostXferStatus(FileXfer x) => switch (x.status) {
    XferStatus.waiting => '等待接受…',
    XferStatus.active => '${(x.fraction * 100).round()}%',
    XferStatus.done => '已完成',
    XferStatus.rejected => '已拒绝',
    XferStatus.failed => '失败',
    XferStatus.cancelled => '已取消',
  };

  Color _hostXferColor(FileXfer x) => switch (x.status) {
    XferStatus.done => CcColors.ok,
    XferStatus.rejected ||
    XferStatus.failed ||
    XferStatus.cancelled => CcColors.danger,
    _ => CcColors.muted,
  };

  // --- remote (phone) session actions; wired into _remoteHost ---

  // _agentForPrefixedKind parses a role-prefixed spawn kind — 'supervisor' and
  // 'todo' both take the shape '<role>[:claude|:codex]' (or the '-' variant),
  // defaulting to claude — into the agent to launch, or null if [kind] isn't
  // that role. The two wrappers below name the roles _spawnManagedSession fans
  // out on; a 'todo:*' session gets the 待办助手 persona injected and
  // 'supervisor:*' the supervisor one (see TerminalSession).
  String? _agentForPrefixedKind(String kind, String prefix) {
    if (kind == prefix ||
        kind == '$prefix:claude' ||
        kind == '$prefix-claude') {
      return 'claude';
    }
    if (kind == '$prefix:codex' || kind == '$prefix-codex') return 'codex';
    return null;
  }

  String? _supervisorAgentForKind(String kind) =>
      _agentForPrefixedKind(kind, 'supervisor');

  String? _todoAgentForKind(String kind) => _agentForPrefixedKind(kind, 'todo');

  // _isSessionWorkdir guards an externally-requested workdir: it may only be the
  // project root or a path under <project>/.worktrees/ — never an arbitrary dir a
  // remote/bus client asks for. Shared by the phone-relay path and the bus spawn.
  bool _isSessionWorkdir(ProjectCfg p, String workdir) =>
      pathIsProjectWorkdir(workdir, p.path);

  // _spawnManagedSession launches a new app-managed session for project [p] and
  // returns its bus id (ts<N>). [kind]: ''/'shell' | 'claude' | 'codex' |
  // 'supervisor[:claude|:codex]' | 'todo[:claude|:codex]'. [workdir] is honored only when it passes
  // _isSessionWorkdir, else it falls back to p.path. Shared by _remoteNewSession
  // (phone relay) and _busSpawn (supervisor spawn) so both produce an identical
  // managed session that lands in the tree + on the bus.
  String _spawnManagedSession({
    required WorkspaceCfg ws,
    required ProjectCfg p,
    required String kind,
    String? workdir,
    String? resumeAgentSessionId,
  }) {
    final dir = (workdir != null && _isSessionWorkdir(p, workdir))
        ? workdir
        : p.path;
    // supervisor:* and todo:* are mutually exclusive role prefixes; at most one
    // resolves. Both fan out through _openAgent with their persona flag set.
    final supervisorAgent = _supervisorAgentForKind(kind);
    final todoAgent = _todoAgentForKind(kind);
    final specialAgent = supervisorAgent ?? todoAgent;
    // Agent sessions go through _openAgent (launch + reveal the project node) —
    // the single source of truth for that pair. A plain shell carries no
    // agent/preLaunch so it can't use _openAgent; open it and reveal directly.
    // resumeAgentSessionId only makes sense for an agent session — a plain
    // shell has no transcript to resume, so that branch ignores it.
    if (kind.isEmpty || kind == 'shell') {
      addTerm(dir, ''); // '' = plain interactive shell
      final ctl = _ctlFor(p.path);
      if (!ctl.isExpanded) ctl.expand();
    } else if (specialAgent != null) {
      _openAgent(
        p,
        dir,
        specialAgent,
        ws.preLaunch,
        supervisor: supervisorAgent != null,
        todoAssistant: todoAgent != null,
        resumeAgentSessionId: resumeAgentSessionId,
      );
    } else {
      _openAgent(
        p,
        dir,
        kind == 'codex' ? 'codex' : 'claude',
        ws.preLaunch,
        resumeAgentSessionId: resumeAgentSessionId,
      );
    }
    return terms.isNotEmpty ? terms.last.id : '';
  }

  void _remoteNewSession(String projectPath, String agent, String? workdir) {
    final kind = agent.trim().toLowerCase();
    for (final ws in _cfg.workspaces) {
      for (final p in ws.projects) {
        if (p.path == projectPath) {
          _spawnManagedSession(ws: ws, p: p, kind: kind, workdir: workdir);
          return;
        }
      }
    }
  }

  String? _projectNameForTodoProject(String? projectId) {
    final pid = (projectId ?? '').trim();
    if (pid.isEmpty) return null;
    for (final ws in _cfg.workspaces) {
      for (final p in ws.projects) {
        if (p.projectId.trim() == pid) return p.name;
      }
    }
    final me = widget.me;
    if (me != null) {
      for (final p in me.projects) {
        if (p.id.trim() == pid) return p.name;
      }
    }
    return null;
  }

  bool _remoteAssignTargetMatchesTodo(
    Todo todo, {
    required String? targetProjectId,
    required String? targetProjectName,
  }) => todoProjectTargetMatches(
    todoProjectId: todo.projectId,
    todoProjectName: _projectNameForTodoProject(todo.projectId),
    targetProjectId: targetProjectId,
    targetProjectName: targetProjectName,
  );

  // _remoteAssignTodo runs a phone's remote 一键指派 request on this desktop
  // (RemoteHost.onAssignTodo). The phone has no local session / filesystem /
  // synchronous spawn, so it delegates: we do exactly what the local assign
  // dialog's _assignToExisting / _assignToNew do — materialize the todo under the
  // target session's workdir, dispatch it there (existing sid, or a freshly
  // spawned session), then bind the todo's assignee + resume trio. Returns null
  // on success or a user-facing error the phone shows.
  Future<String?> _remoteAssignTodo(Map<String, dynamic> req) async {
    final client = widget.client;
    if (client == null) return '需要登录 relay';
    if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
    final todoId = (req['todoId'] as String?)?.trim() ?? '';
    if (todoId.isEmpty) return '缺少 todoId';
    final Todo fallback;
    try {
      fallback = await client.todo(todoId);
    } catch (e) {
      if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
      return '读取待办失败: ${errorText(e)}';
    }
    if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
    if (!mounted) return '工作区已关闭';
    final me = widget.me;
    if (me != null && !todoAccessFor(fallback, me).canAssign) {
      return '你对这条待办没有指派权限';
    }
    final requestedProjectId = (req['projectId'] as String?)?.trim() ?? '';
    final todoProjectId = fallback.projectId?.trim() ?? '';
    if (todoProjectId.isNotEmpty &&
        requestedProjectId.isNotEmpty &&
        requestedProjectId != todoProjectId) {
      return '待办项目已变化,请刷新后重新指派';
    }

    final String sid;
    var waitForAgentId = false;
    if ((req['mode'] as String?) == 'new') {
      final (spawnedSid, err) = await _spawnForDispatch(
        workspace: (req['workspace'] as String?) ?? '',
        project: (req['project'] as String?) ?? '',
        projectId: todoProjectId.isNotEmpty
            ? todoProjectId
            : requestedProjectId,
        kind: (req['kind'] as String?) ?? 'claude',
        newWorktreeBranch: req['branch'] as String?,
      );
      if (spawnedSid == null) return '新建会话失败: ${err ?? "未知错误"}';
      if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
      if (!mounted) return '工作区已关闭';
      sid = spawnedSid;
      waitForAgentId = true; // codex mints its id async — poll before binding
    } else {
      sid = (req['sid'] as String?) ?? '';
      if (sid.isEmpty) return '缺少目标会话';
      if (sessionById(sid) == null) return '目标会话不存在(可能已关闭)';
      final card = _remoteCard(sid);
      if (!_remoteAssignTargetMatchesTodo(
        fallback,
        targetProjectId: card?.projectId,
        targetProjectName: card?.project,
      )) {
        return '目标会话不属于这条团队待办的项目';
      }
    }

    // Resolve the target session's workdir — a just-spawned card may not carry it
    // the instant spawn returns, so poll briefly (mirrors _prepareAssignment).
    var card = _remoteCard(sid);
    for (var i = 0; i < 5 && (card?.workdir ?? '').isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
      if (!mounted) return '工作区已关闭';
      card = _remoteCard(sid);
    }
    if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
    if (!mounted) return '工作区已关闭';
    final prep = await prepareTodoAssignmentText(
      client: client,
      todoId: todoId,
      fallbackTodo: fallback,
      workdir: card?.workdir ?? '',
    );
    if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
    if (!mounted) return '工作区已关闭';
    final dispatchErr = deliverLocalMessage(
      LocalMsg('', sid, prep.taskText, true),
    );
    if (dispatchErr != null) return '投递失败: $dispatchErr';

    // Bind assignee + resume trio, best-effort (mirrors _syncAssignVisibility).
    card = _remoteCard(sid);
    if (waitForAgentId && (card?.agentSessionId ?? '').isEmpty) {
      for (var i = 0; i < 15 && (card?.agentSessionId ?? '').isEmpty; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
        if (!mounted) return '工作区已关闭';
        card = _remoteCard(sid);
      }
    }
    if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
    try {
      await client.assignTodo(
        todoId,
        assigneeIdentity: _cfg.identity,
        assigneeSessionId: sid,
        assigneeSessionLabel: card?.label ?? '',
        assigneeAgentSessionId: card?.agentSessionId,
        assigneeWorkdir: card?.workdir,
        assigneeAgentKind: card == null || card.agentKind.isEmpty
            ? null
            : (card.isSupervisor
                  ? 'supervisor:${card.agentKind}'
                  : card.agentKind),
      );
      if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
      await client.updateTodo(
        todoId,
        workspaceName: card?.workspace ?? '',
        repoName: card?.project ?? '',
      );
      if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
    } catch (_) {}
    // 指派 = 开始处理: bump an unstarted todo to 进行中.
    if (const {
      TodoStatus.triage,
      TodoStatus.backlog,
      TodoStatus.todo,
    }.contains(prep.full.status)) {
      try {
        await client.setTodoStatus(todoId, TodoStatus.inProgress);
        if (!_isCurrentRelayClient(client)) return '账号已切换,请重新指派';
      } catch (_) {}
    }
    return null;
  }

  SessionCard? _remoteCard(String sid) {
    for (final c in widget.overviewStore.cards) {
      if (c.sid == sid) return c;
    }
    return null;
  }

  // _captureSessionCapsule backs SessionOverviewStore.captureCapsuleHandler: it
  // freezes a live agent session into a scratch draft dir — copies the raw log +
  // neutral render (captureCapsuleTranscript), then distills persona/seed
  // (distillCapsule, hybrid: self-distill only when the session is idle AND the
  // user opted in). Returns (draft, null) or (null, error).
  Future<(CapsuleDraft?, String?)> _captureSessionCapsule(
    SessionCard card, {
    required bool preferSelfDistill,
  }) async {
    if (widget.client == null) return (null, '请先登录 relay 后再发布胶囊');
    final workdir = card.workdir;
    if (card.agentKind.isEmpty) return (null, '只有 agent 会话能打成胶囊');
    if (workdir == null || workdir.isEmpty) return (null, '会话没有工作目录');

    final draftDir = (await Directory.systemTemp.createTemp(
      'cc-capsule-',
    )).path;
    final cap = await captureCapsuleTranscript(
      agentKind: card.agentKind,
      agentSessionId: card.agentSessionId,
      workdir: workdir,
      destDir: draftDir,
      maxTextChars:
          200000, // cap the neutral render fed to the headless distill
    );
    if (cap == null) {
      return (null, '会话日志还没落盘,等它写一轮后再试');
    }

    final outcome = await distillCapsule(
      agentKind: card.agentKind,
      // Resolve the agent's real executable up front — a bare name is unreliable
      // under the GUI's minimal PATH (same helper the PTY launcher uses).
      headlessExe: await AgentResolver.resolve(card.agentKind),
      draftDir: draftDir,
      transcriptText: cap.text, // already in memory from capture — no re-read
      sessionIdle: !sessionStatusIsActive(card.status),
      userWantsSelf: preferSelfDistill,
      deliverToSession: (prompt) async {
        final s = sessionById(card.sid);
        if (s == null) return false;
        s.pasteText(prompt, submit: true);
        return true;
      },
      runProc: systemProcRunner,
    );
    if (!outcome.personaWritten) {
      try {
        await Directory(draftDir).delete(recursive: true);
      } catch (_) {}
      return (null, '后台蒸馏未产出角色 persona.md,请稍后重试或改用「让它自己蒸馏」');
    }

    return (
      CapsuleDraft(
        draftDir: draftDir,
        sourceAgent: card.agentKind,
        originSessionId: card.agentSessionId,
        workdir: workdir,
        hasTranscript: true,
        hasPersona: outcome.personaWritten,
        label: card.label,
      ),
      null,
    );
  }

  // _submitSessionCapsule backs SessionOverviewStore.submitCapsuleHandler: ship
  // the (possibly user-edited) draft via the bundled `cc-handoff capsule submit`
  // so the transport + relay-id-stamping path is shared with normal handoffs.
  // Only flags for payloads that exist on disk are passed.
  Future<(bool, String?)> _submitSessionCapsule(
    CapsuleDraft draft, {
    required String visibility,
    required String summary,
    List<String> skillZips = const [],
  }) async {
    final d = draft.draftDir;
    final args = <String>[
      'capsule',
      'submit',
      '--source-agent',
      draft.sourceAgent,
    ];
    Future<void> addIfExists(String flag, String name) async {
      if (await File('$d/$name').exists()) {
        args
          ..add(flag)
          ..add('$d/$name');
      }
    }

    void addFlag(String flag, String? v) {
      if (v != null && v.isNotEmpty) {
        args
          ..add(flag)
          ..add(v);
      }
    }

    await addIfExists('--transcript', 'transcript.jsonl');
    await addIfExists('--transcript-text', 'transcript.txt');
    await addIfExists('--persona', 'persona.md');
    await addIfExists('--seed', 'seed.md');
    addFlag('--origin-session', draft.originSessionId);
    if (visibility == 'public') args.add('--public'); // else defaults to 个人
    addFlag('--summary', summary);
    for (final z in skillZips) {
      args
        ..add('--skill')
        ..add(z);
    }

    try {
      await Cli.run(args, workingDirectory: draft.workdir);
      return (true, null);
    } on CliException catch (e) {
      return (false, e.message);
    } catch (e) {
      return (false, '$e');
    }
  }

  // _spawnForDispatch backs SessionOverviewStore.spawnHandler — the "指派待办→
  // 新建会话" path from the (future) top-level 待办 page, which has no `_cfg` of
  // its own. Resolves (workspace, project) by name against the live config
  // (same lookup as _busSpawn), optionally creates a fresh worktree branch
  // first (Cli.worktreeAdd, then listWorktrees to resolve its real path — `git
  // worktree add` doesn't hand the path back directly), then launches via
  // _spawnManagedSession. Returns (sid, null) on success or (null, error) —
  // the same result-tuple convention as _resolveTarget.
  Future<(String? sid, String? error)> _spawnForDispatch({
    required String workspace,
    required String project,
    required String kind,
    String? projectId,
    String? newWorktreeBranch,
    String? worktreeStart,
    String? resumeAgentSessionId,
    String? workdir,
  }) async {
    WorkspaceCfg? ws;
    ProjectCfg? p;
    final requestedProjectId = (projectId ?? '').trim();
    for (final w in _cfg.workspaces) {
      if (workspace.isNotEmpty && w.name != workspace) continue;
      for (final proj in w.projects) {
        if (!remoteSpawnProjectMatchesRequestedId(proj, requestedProjectId)) {
          continue;
        }
        if (proj.name == project) {
          ws = w;
          p = proj;
        }
      }
    }
    if (ws == null || p == null) {
      return (
        null,
        workspace.isEmpty
            ? '找不到项目 "$project"'
            : '找不到项目 "$project"(workspace=$workspace)',
      );
    }
    final k = kind.trim().toLowerCase();
    const validKinds = {
      '',
      'shell',
      'claude',
      'codex',
      'supervisor:claude',
      'supervisor:codex',
      'todo:claude',
      'todo:codex',
    };
    if (!validKinds.contains(k)) return (null, '未知 agent "$kind"');

    // dir starts as the caller-supplied existing workdir (e.g. a todo's saved
    // assigneeWorkdir, resolved by todo_detail_view.dart's "打开/恢复会话"
    // before it knew which project that path belonged to) — creating a fresh
    // worktree below overrides it, since those two are mutually exclusive
    // ("resume in this known dir" vs. "branch off a brand-new one").
    var dir = workdir;
    final branch = newWorktreeBranch?.trim();
    if (branch != null && branch.isNotEmpty) {
      try {
        await Cli.worktreeAdd(
          p.name,
          branch,
          workspace: ws.name,
          start: (worktreeStart?.trim().isEmpty ?? true)
              ? null
              : worktreeStart!.trim(),
        );
      } catch (e) {
        return (null, '创建 worktree 失败: $e');
      }
      final wts = await listWorktrees(p.path);
      final wt = wts.where((w) => w.branch == branch).toList();
      if (wt.isEmpty) return (null, 'worktree 创建成功但未能解析路径');
      dir = wt.first.path;
    }
    final id = _spawnManagedSession(
      ws: ws,
      p: p,
      kind: k,
      workdir: dir,
      resumeAgentSessionId: resumeAgentSessionId,
    );
    return id.isEmpty ? (null, '会话创建失败') : (id, null);
  }

  // _busSpawn serves a kind:"spawn" local-bus request (`cc-handoff supervisor
  // spawn <project>`). It resolves the project BY NAME (optionally narrowed by
  // [workspace], mirroring the Go resolveProject semantics), maps/validates the
  // agent kind, guards an explicit workdir, launches a managed session, and writes
  // the new session id into [out]. Returns null on success or a human-readable
  // error → <id>.err. Semantics match the project right-click (起 claude/codex/总管).
  Future<String?> _busSpawn(
    String project,
    String workspace,
    String agent,
    bool supervisor,
    String workdir,
    StringSink out,
  ) async {
    if (project.trim().isEmpty) return '缺少 project';
    final matches = <({WorkspaceCfg ws, ProjectCfg p})>[];
    for (final ws in _cfg.workspaces) {
      if (workspace.isNotEmpty && ws.name != workspace) continue;
      for (final p in ws.projects) {
        if (p.name == project) matches.add((ws: ws, p: p));
      }
    }
    if (matches.isEmpty) {
      return workspace.isEmpty
          ? '找不到项目 "$project"'
          : '找不到项目 "$project"(workspace=$workspace)';
    }
    if (matches.length > 1) {
      final wss = matches.map((m) => m.ws.name).join(', ');
      return '项目名 "$project" 在多个 workspace 中重复($wss);用 --workspace 指定';
    }
    final ws = matches.first.ws;
    final p = matches.first.p;
    final kind = agent.trim().toLowerCase();
    if (supervisor) {
      if (kind.isNotEmpty && kind != 'claude' && kind != 'codex') {
        return '--supervisor 只支持 --agent claude|codex';
      }
    } else if (kind.isNotEmpty &&
        kind != 'shell' &&
        kind != 'claude' &&
        kind != 'codex') {
      return '未知 agent "$agent"(want claude|codex|shell)';
    }
    // An explicit workdir must be the project root or under its .worktrees/.
    if (workdir.trim().isNotEmpty && !_isSessionWorkdir(p, workdir)) {
      return 'workdir "$workdir" 非法:必须是 ${p.path} 或其 .worktrees/ 下';
    }
    final effectiveKind = supervisor
        ? (kind == 'codex' ? 'supervisor:codex' : 'supervisor:claude')
        : kind;
    final id = _spawnManagedSession(
      ws: ws,
      p: p,
      kind: effectiveKind,
      workdir: workdir.trim().isEmpty ? null : workdir,
    );
    out.write(id);
    return null;
  }

  void _remoteCloseSession(String sid) {
    final i = terms.indexWhere((s) => s.id == sid);
    if (i >= 0) closeTerm(i);
  }

  void _remoteRenameSession(String sid, String name) {
    final i = terms.indexWhere((s) => s.id == sid);
    if (i < 0) return;
    final n = name.trim();
    setState(() => terms[i].name = n.isEmpty ? null : n);
    persistTerms();
  }

  // Runs a phone-triggered config mutation via the Cli, then reloads config so
  // the desktop tree updates and the host re-broadcasts roots to phones.
  Future<void> _remoteConfigAction(
    String action,
    Map<String, dynamic> a,
  ) async {
    switch (action) {
      case 'wt.add':
        await Cli.worktreeAdd(
          a['project'] as String,
          a['branch'] as String,
          workspace: a['workspace'] as String?,
          start: a['start'] as String?,
        );
      case 'wt.remove':
        await Cli.worktreeRemove(
          a['project'] as String,
          a['branch'] as String,
          workspace: a['workspace'] as String?,
          force: a['force'] == true,
        );
      case 'ws.new':
        await Cli.workspaceCreate(
          a['name'] as String,
          path: a['path'] as String?,
        );
      case 'ws.remove':
        await Cli.workspaceRemove(a['name'] as String);
      case 'proj.add':
        await Cli.workspaceAdd(a['workspace'] as String, a['source'] as String);
      case 'proj.remove':
        await Cli.projectRemove(
          a['workspace'] as String,
          a['project'] as String,
        );
    }
    final cfg = await AppConfig.load();
    if (cfg != null && mounted) {
      setState(() {
        _cfg = _mergeReloadedLocalConfig(cfg);
        _syncOnlineSendAction();
      });
    }
    _remoteHost.broadcastRoots();
  }

  void _selectGitProject(ProjectCfg p, {bool openTool = false}) {
    setState(() {
      _gitProject = p;
      if (openTool) {
        _bottomTool = _BottomTool.git;
        _terminalCollapsed = false;
      }
    });
    if (openTool) {
      Prefs.setString('ws.bottomTool', 'git');
      Prefs.setBool('ws.terminalCollapsed', false);
    }
    _refreshGit();
  }

  _CodeLocation? get _activeLocation {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return null;
    final file = _codeFiles[_activeFile];
    if (file.isDiff) return null; // diff tabs aren't navigable code locations
    return _CodeLocation(file.path, line: file.line);
  }

  void _pushNavigationHistory() {
    final current = _activeLocation;
    if (current == null) return;
    if (_codeBackStack.isNotEmpty && _codeBackStack.last.sameAs(current)) {
      return;
    }
    _codeBackStack.add(current);
    if (_codeBackStack.length > 80) _codeBackStack.removeAt(0);
    _codeForwardStack.clear();
  }

  @override
  void _openCodeFile(String path, {int? line, bool recordHistory = true}) {
    if (!mounted) return;
    // Opening a directory as a file throws "Is a directory" (e.g. an untracked
    // dir or a submodule clicked in the change list) — reveal it in the project
    // tree instead of adding a broken editor tab.
    if (FileSystemEntity.isDirectorySync(path)) {
      setState(() => _revealedProjectFilePath = path);
      _expandProjectForFile(path);
      return;
    }
    final target = _CodeLocation(path, line: line);
    final current = _activeLocation;
    if (recordHistory && current != null && !current.sameAs(target)) {
      _pushNavigationHistory();
    }
    final existing = _codeFiles.indexWhere((f) => f.path == path);
    setState(() {
      if (existing >= 0) {
        _codeFiles[existing].line = line;
        _activeFile = existing;
        _syncPaneFocusToActiveFile(); // jump to wherever it's already open
      } else {
        _codeFiles.add(_OpenFile(path, line: line));
        _activeFile = _codeFiles.length - 1;
        if (_filePaneTree is PaneSplit) {
          _fileToPane[path] = _focusedPaneId;
          _paneActivePath[_focusedPaneId] = path;
        }
      }
      _recentFiles.remove(path);
      _recentFiles.insert(0, path);
      if (_recentFiles.length > 12) {
        _recentFiles.removeRange(12, _recentFiles.length);
      }
      _recentLocations.removeWhere((l) => l.key == target.key);
      _recentLocations.insert(0, target);
      if (_recentLocations.length > 30) {
        _recentLocations.removeRange(30, _recentLocations.length);
      }
      if (_projectAutoscrollFromSource) {
        _revealedProjectFilePath = path;
      }
    });
    if (_projectAutoscrollFromSource) _expandProjectForFile(path);
  }

  // _openDiffTab opens a read-only diff tab in the center editor showing a
  // commit's / compare's files, focused on [initialPath]. Deduped by [title].
  @override
  void _openDiffTab(
    List<FileDiff> diffs,
    String title, {
    String? initialPath,
    bool showTree = true,
    Future<List<FileDiff>> Function(int context)? reload,
  }) {
    if (diffs.isEmpty) return;
    final existing = _codeFiles.indexWhere((f) => f.isDiff && f.path == title);
    setState(() {
      if (existing >= 0) {
        // Reuse the open diff tab but re-point it at the just-clicked file so the
        // center pane follows the commit-list selection (instead of staying put).
        final f = _codeFiles[existing];
        f.diffs = diffs;
        f.diffInitialPath = initialPath;
        f.diffShowTree = showTree;
        f.diffReload = reload;
        _activeFile = existing;
        _syncPaneFocusToActiveFile();
      } else {
        _codeFiles.add(
          _OpenFile.diff(
            title,
            diffs,
            diffInitialPath: initialPath,
            diffShowTree: showTree,
            diffReload: reload,
          ),
        );
        _activeFile = _codeFiles.length - 1;
        if (_filePaneTree is PaneSplit) {
          _fileToPane[title] = _focusedPaneId;
          _paneActivePath[_focusedPaneId] = title;
        }
      }
    });
  }

  // --- Split-pane editor bookkeeping ------------------------------------
  // See the field comment on _filePaneTree: all of this is inert until the
  // user actually splits, so it can't regress the unsplit single-pane path.

  // Thin, State-owning wrappers around the pure functions in
  // workspace/file_pane_state.dart — that file has no Flutter/State
  // dependency, so it's what actually gets unit-tested; these just glue its
  // results back into this State's mutable fields.

  String _paneOfPath(String path) => paneOfPath(_fileToPane, path);

  List<int> _paneFileIndices(String paneId) => paneFileIndices(
    [for (final f in _codeFiles) f.path],
    _fileToPane,
    paneId,
  );

  // Re-syncs pane bookkeeping after _codeFiles shrinks. Only call while
  // _filePaneTree is a PaneSplit — callers guard on that.
  void _reconcilePaneTree() {
    final r = reconcilePaneTree(
      tree: _filePaneTree,
      openPaths: [for (final f in _codeFiles) f.path],
      fileToPane: _fileToPane,
      paneActivePath: _paneActivePath,
      focusedPaneId: _focusedPaneId,
    );
    _filePaneTree = r.tree;
    _fileToPane
      ..clear()
      ..addAll(r.fileToPane);
    _paneActivePath
      ..clear()
      ..addAll(r.paneActivePath);
    _focusedPaneId = r.focusedPaneId;

    final focusedPath = _paneActivePath[_focusedPaneId];
    if (focusedPath != null) {
      final idx = _codeFiles.indexWhere((f) => f.path == focusedPath);
      if (idx >= 0) _activeFile = idx;
    } else if (_codeFiles.isEmpty) {
      _activeFile = -1;
    }
  }

  // Points _focusedPaneId + _paneActivePath at wherever the current
  // _activeFile actually lives. No-op while unsplit (by design — the
  // unsplit render path never reads these maps, so there's nothing to
  // keep in sync until a split exists).
  void _syncPaneFocusToActiveFile() {
    if (_filePaneTree is! PaneSplit) return;
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    final path = _codeFiles[_activeFile].path;
    final pane = _paneOfPath(path);
    _focusedPaneId = pane;
    _paneActivePath[pane] = path;
  }

  // Shared by the tab right-click menu and the ⋮ tab menu: both just want
  // "this tab is now the operation target" before dispatching a menu item.
  void _activateMenuTarget(int index) {
    _activeFile = index;
    _syncPaneFocusToActiveFile();
  }

  // Focuses [paneId] and syncs _activeFile to its active file, so the
  // existing (pane-unaware) toolbar actions — save, structure, find,
  // go-to-definition, etc. — operate on the right file when triggered from
  // inside a specific pane's chrome.
  void _focusPane(String paneId) {
    _focusedPaneId = paneId;
    final path = _paneActivePath[paneId];
    if (path == null) return;
    final idx = _codeFiles.indexWhere((f) => f.path == path);
    if (idx >= 0) _activeFile = idx;
  }

  // Tab click inside a specific pane's tab strip (split mode only).
  void _activatePaneTab(String paneId, String path) {
    final idx = _codeFiles.indexWhere((f) => f.path == path);
    if (idx < 0) return;
    setState(() {
      _focusedPaneId = paneId;
      _paneActivePath[paneId] = path;
      _activeFile = idx;
      if (_projectAutoscrollFromSource) _revealedProjectFilePath = path;
    });
    if (_projectAutoscrollFromSource) _expandProjectForFile(path);
  }

  // "向右分屏" / "向下分屏": pulls the tab at [index] out of its current pane
  // into a freshly-split sibling pane, and focuses that new pane.
  void _splitEditorPane(int index, SplitAxis axis) {
    if (index < 0 || index >= _codeFiles.length) return;
    final path = _codeFiles[index].path;
    setState(() {
      final r = splitPaneForFile(
        tree: _filePaneTree,
        openPaths: [for (final f in _codeFiles) f.path],
        fileToPane: _fileToPane,
        paneActivePath: _paneActivePath,
        path: path,
        axis: axis,
        newPaneId: 'pane-${_panePaneSeq++}',
      );
      _filePaneTree = r.tree;
      _fileToPane
        ..clear()
        ..addAll(r.fileToPane);
      _paneActivePath
        ..clear()
        ..addAll(r.paneActivePath);
      _focusedPaneId = r.focusedPaneId;
      _activeFile = index;
    });
  }

  void _navigateBack() {
    if (_codeBackStack.isEmpty) return;
    final current = _activeLocation;
    final target = _codeBackStack.removeLast();
    if (current != null && !current.sameAs(target)) {
      _codeForwardStack.add(current);
    }
    _openCodeFile(target.path, line: target.line, recordHistory: false);
  }

  void _navigateForward() {
    if (_codeForwardStack.isEmpty) return;
    final current = _activeLocation;
    final target = _codeForwardStack.removeLast();
    if (current != null && !current.sameAs(target)) {
      _codeBackStack.add(current);
    }
    _openCodeFile(target.path, line: target.line, recordHistory: false);
  }

  Future<void> _closeCodeFile(int i) async {
    if (i < 0 || i >= _codeFiles.length) return;
    final f = _codeFiles[i];
    if (f.dirty) {
      final ok = await _confirm(
        '关闭未保存文件?',
        '${f.path}\n\n未保存修改会保留在编辑器里,关闭后需要重新打开。',
      );
      if (!ok) return;
      if (!mounted) return;
    }
    setState(() {
      _codeFiles.removeAt(i);
      if (_codeFiles.isEmpty) {
        _activeFile = -1;
      } else if (_activeFile >= _codeFiles.length) {
        _activeFile = _codeFiles.length - 1;
      } else if (_activeFile > i) {
        _activeFile--;
      }
      if (_filePaneTree is PaneSplit) _reconcilePaneTree();
    });
  }

  Future<void> _closeActiveCodeFile() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    await _closeCodeFile(_activeFile);
  }

  void _activateCodeTab(int index) {
    if (index < 0 || index >= _codeFiles.length) return;
    setState(() {
      _activeFile = index;
      _syncPaneFocusToActiveFile();
      if (_projectAutoscrollFromSource) {
        _revealedProjectFilePath = _codeFiles[index].path;
      }
    });
    if (_projectAutoscrollFromSource) {
      _expandProjectForFile(_codeFiles[index].path);
    }
  }

  void _selectNextCodeTab() {
    if (_codeFiles.isEmpty) return;
    setState(() {
      _activeFile = _activeFile < 0 ? 0 : (_activeFile + 1) % _codeFiles.length;
      _syncPaneFocusToActiveFile();
      if (_projectAutoscrollFromSource && _activeFile >= 0) {
        _revealedProjectFilePath = _codeFiles[_activeFile].path;
      }
    });
    if (_projectAutoscrollFromSource && _activeFile >= 0) {
      _expandProjectForFile(_codeFiles[_activeFile].path);
    }
  }

  void _selectPreviousCodeTab() {
    if (_codeFiles.isEmpty) return;
    setState(() {
      _activeFile = _activeFile <= 0 ? _codeFiles.length - 1 : _activeFile - 1;
      _syncPaneFocusToActiveFile();
      if (_projectAutoscrollFromSource && _activeFile >= 0) {
        _revealedProjectFilePath = _codeFiles[_activeFile].path;
      }
    });
    if (_projectAutoscrollFromSource && _activeFile >= 0) {
      _expandProjectForFile(_codeFiles[_activeFile].path);
    }
  }

  // _closeOtherCodeFiles/_closeCodeFilesToRight/_closeCodeFilesToLeft are all
  // scoped to [keep]'s own pane (see _paneFileIndices) rather than the global
  // _codeFiles list — closing "others"/"left"/"right" from a tab in a split
  // pane must never touch files open in a *different* pane. While unsplit,
  // _paneOfPath always resolves to 'root' and _paneFileIndices('root') is
  // every open file, so scope == the whole list and behavior is unchanged
  // from before split-pane existed. _activeFile is always [keep]'s new index
  // afterward — by the time any of these run, the tab menu that dispatched
  // here has already made [keep] the active file (see _activateMenuTarget),
  // so this just keeps it active through the removal.
  Future<void> _closeOtherCodeFiles(int keep) async {
    if (keep < 0 || keep >= _codeFiles.length) return;
    final scope = _paneFileIndices(_paneOfPath(_codeFiles[keep].path));
    final closePaths = {
      for (final i in scope)
        if (i != keep) _codeFiles[i].path,
    };
    if (closePaths.isEmpty) return;
    final dirty = [
      for (final f in _codeFiles)
        if (closePaths.contains(f.path) && f.dirty) f.path,
    ];
    if (dirty.isNotEmpty) {
      final ok = await _confirm('关闭其他未保存文件?', _previewList(dirty));
      if (!ok) return;
      if (!mounted) return;
    }
    final keepPath = _codeFiles[keep].path;
    setState(() {
      _codeFiles.removeWhere((f) => closePaths.contains(f.path));
      final idx = _codeFiles.indexWhere((f) => f.path == keepPath);
      _activeFile = idx >= 0 ? idx : (_codeFiles.isEmpty ? -1 : 0);
      if (_filePaneTree is PaneSplit) _reconcilePaneTree();
    });
  }

  Future<void> _closeCodeFilesToRight(int keep) async {
    if (keep < 0 || keep >= _codeFiles.length) return;
    final scope = _paneFileIndices(_paneOfPath(_codeFiles[keep].path));
    final pos = scope.indexOf(keep);
    if (pos < 0 || pos >= scope.length - 1) return;
    final closePaths = {
      for (final i in scope.sublist(pos + 1)) _codeFiles[i].path,
    };
    final dirty = [
      for (final f in _codeFiles)
        if (closePaths.contains(f.path) && f.dirty) f.path,
    ];
    if (dirty.isNotEmpty) {
      final ok = await _confirm('关闭右侧未保存文件?', _previewList(dirty));
      if (!ok) return;
      if (!mounted) return;
    }
    final keepPath = _codeFiles[keep].path;
    setState(() {
      _codeFiles.removeWhere((f) => closePaths.contains(f.path));
      final idx = _codeFiles.indexWhere((f) => f.path == keepPath);
      _activeFile = idx >= 0 ? idx : (_codeFiles.isEmpty ? -1 : 0);
      if (_filePaneTree is PaneSplit) _reconcilePaneTree();
    });
  }

  Future<void> _closeCodeFilesToLeft(int keep) async {
    if (keep < 0 || keep >= _codeFiles.length) return;
    final scope = _paneFileIndices(_paneOfPath(_codeFiles[keep].path));
    final pos = scope.indexOf(keep);
    if (pos <= 0) return;
    final closePaths = {
      for (final i in scope.sublist(0, pos)) _codeFiles[i].path,
    };
    final dirty = [
      for (final f in _codeFiles)
        if (closePaths.contains(f.path) && f.dirty) f.path,
    ];
    if (dirty.isNotEmpty) {
      final ok = await _confirm('关闭左侧未保存文件?', _previewList(dirty));
      if (!ok) return;
      if (!mounted) return;
    }
    final keepPath = _codeFiles[keep].path;
    setState(() {
      _codeFiles.removeWhere((f) => closePaths.contains(f.path));
      final idx = _codeFiles.indexWhere((f) => f.path == keepPath);
      _activeFile = idx >= 0 ? idx : (_codeFiles.isEmpty ? -1 : 0);
      if (_filePaneTree is PaneSplit) _reconcilePaneTree();
    });
  }

  Future<void> _closeUnmodifiedCodeFiles() async {
    if (_codeFiles.every((f) => f.dirty)) {
      _snack('没有可关闭的未修改文件');
      return;
    }
    setState(() {
      final activePath = _activeFile >= 0 && _activeFile < _codeFiles.length
          ? _codeFiles[_activeFile].path
          : null;
      _codeFiles.removeWhere((f) => !f.dirty);
      if (_codeFiles.isEmpty) {
        _activeFile = -1;
      } else {
        final next = activePath == null
            ? -1
            : _codeFiles.indexWhere((f) => f.path == activePath);
        _activeFile = next >= 0 ? next : 0;
      }
      if (_filePaneTree is PaneSplit) _reconcilePaneTree();
    });
  }

  Future<void> _closeAllCodeFiles() async {
    final dirty = _codeFiles.where((f) => f.dirty).map((f) => f.path).toList();
    if (dirty.isNotEmpty) {
      final ok = await _confirm('关闭所有未保存文件?', _previewList(dirty));
      if (!ok) return;
      if (!mounted) return;
    }
    setState(() {
      _codeFiles.clear();
      _activeFile = -1;
      _filePaneTree = const PaneLeaf('root');
      _focusedPaneId = 'root';
      _fileToPane.clear();
      _paneActivePath.clear();
    });
  }

  // _closePaneFiles closes every file open in [paneId] at once, folding that
  // split back into its sibling — the editor counterpart of the terminal
  // deck's per-pane "关闭此分屏" button. Modeled on _closeOtherCodeFiles's
  // dirty-file confirm + _reconcilePaneTree collapse, but scoped to the whole
  // pane rather than "every tab except one". Guarded so a stale tap can't act
  // on the unsplit editor (no split → nothing to fold) or a pane that's
  // already gone/empty. _reconcilePaneTree already repoints focus + _activeFile
  // onto a surviving pane when the focused (here: closed) pane collapses, so
  // there's nothing extra to reposition afterward.
  Future<void> _closePaneFiles(String paneId) async {
    if (_filePaneTree is! PaneSplit) return;
    final scope = _paneFileIndices(paneId);
    if (scope.isEmpty) return;
    final closePaths = {for (final i in scope) _codeFiles[i].path};
    final dirty = [
      for (final f in _codeFiles)
        if (closePaths.contains(f.path) && f.dirty) f.path,
    ];
    if (dirty.isNotEmpty) {
      final ok = await _confirm('关闭此分屏未保存文件?', _previewList(dirty));
      if (!ok) return;
      if (!mounted) return;
    }
    setState(() {
      _codeFiles.removeWhere((f) => closePaths.contains(f.path));
      if (_filePaneTree is PaneSplit) _reconcilePaneTree();
    });
  }

  void _copyFilePath(String path) {
    Clipboard.setData(ClipboardData(text: path));
    _snack('已复制路径');
  }

  // FsClipboardActions 的三处注入点：选中项 / 提示 / 写盘后刷新。
  // 四个操作(fsCopy/fsCut/fsPaste/fsDrop) 和键盘绑定(fsShortcuts) 都来自 mixin。
  @override
  String? get fsSelectedPath => _revealedProjectFilePath;

  @override
  void fsNotify(String msg) => _snack(msg);

  @override
  Future<void> fsOnWritten(String firstPath) async {
    _refreshFileTrees(firstPath);
    await _refreshGit();
  }

  String _pathJoin(String dir, String name) =>
      dir.endsWith('/') || dir.endsWith(r'\') ? '$dir$name' : '$dir/$name';

  String _pathBaseName(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    final i = slash > backslash ? slash : backslash;
    return i < 0 ? path : path.substring(i + 1);
  }

  String _pathParent(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    final i = slash > backslash ? slash : backslash;
    return i < 0 ? '' : path.substring(0, i);
  }

  bool _pathWithin(String path, String root) =>
      path == root || path.startsWith('$root/') || path.startsWith('$root\\');

  bool _validEntryName(String name) =>
      name.trim().isNotEmpty && !name.contains('/') && !name.contains(r'\');

  Future<String?> _nameDialog(
    String title,
    String label, {
    String initial = '',
    String hint = '',
  }) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => FileNameDialog(
        title: title,
        label: label,
        initial: initial,
        hint: hint,
      ),
    );
    if (raw == null) return null;
    if (!mounted) return null;
    final name = raw.trim();
    if (!_validEntryName(name)) {
      _snack('$label 不能为空，也不能包含路径分隔符');
      return null;
    }
    return name;
  }

  void _refreshFileTrees([String? selectedPath]) {
    if (!mounted) return;
    // Files created/deleted/renamed/formatted → the go-to-definition symbol index
    // may be stale; drop it so the next jump rebuilds from disk.
    _invalidateSymbolIndex();
    setState(() {
      _fileTreeRefreshToken++;
      if (selectedPath != null) _revealedProjectFilePath = selectedPath;
    });
  }

  Future<bool> _closeAffectedOpenFiles(String path, bool isDir) async {
    final affected = _codeFiles
        .where(
          (f) =>
              !f.isDiff && (isDir ? _pathWithin(f.path, path) : f.path == path),
        )
        .toList();
    final dirty = affected.where((f) => f.dirty).map((f) => f.path).toList();
    if (dirty.isNotEmpty && !await _confirm('关闭未保存文件?', _previewList(dirty))) {
      return false;
    }
    if (!mounted) return false;
    if (affected.isEmpty) return true;
    setState(() {
      _codeFiles.removeWhere(
        (f) =>
            !f.isDiff && (isDir ? _pathWithin(f.path, path) : f.path == path),
      );
      if (_codeFiles.isEmpty) {
        _activeFile = -1;
      } else if (_activeFile >= _codeFiles.length) {
        _activeFile = _codeFiles.length - 1;
      }
      if (_filePaneTree is PaneSplit) _reconcilePaneTree();
    });
    return true;
  }

  Future<void> _newFileInDir(String dir) async {
    final name = await _nameDialog('新建文件', '文件名', hint: 'README.md');
    if (name == null) return;
    final path = _pathJoin(dir, name);
    try {
      await File(path).create(exclusive: true);
      _refreshFileTrees(path);
      _openCodeFile(path);
    } catch (e) {
      _snack('新建文件失败：$e');
    }
  }

  Future<void> _newDirectoryInDir(String dir) async {
    final name = await _nameDialog('新建目录', '目录名', hint: 'src');
    if (name == null) return;
    final path = _pathJoin(dir, name);
    try {
      await Directory(path).create();
      _refreshFileTrees(path);
    } catch (e) {
      _snack('新建目录失败：$e');
    }
  }

  Future<void> _renameFsPath(String path, bool isDir, String rootPath) async {
    if (path == rootPath) {
      _snack('不能重命名项目根目录');
      return;
    }
    final name = await _nameDialog('重命名', '名称', initial: _pathBaseName(path));
    if (name == null || !await _closeAffectedOpenFiles(path, isDir)) return;
    final target = _pathJoin(_pathParent(path), name);
    try {
      if (isDir) {
        await Directory(path).rename(target);
      } else {
        await File(path).rename(target);
      }
      _refreshFileTrees(target);
      if (!isDir) _openCodeFile(target);
    } catch (e) {
      _snack('重命名失败：$e');
    }
  }

  Future<void> _deleteFsPath(String path, bool isDir, String rootPath) async {
    if (path == rootPath) {
      _snack('不能删除项目根目录');
      return;
    }
    if (!await _confirm('删除「${_pathBaseName(path)}」?', '此操作会删除磁盘文件。')) {
      return;
    }
    if (!mounted) return;
    if (!await _closeAffectedOpenFiles(path, isDir)) return;
    try {
      if (isDir) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
      _refreshFileTrees(_pathParent(path));
      await _refreshGit();
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

  Future<void> _revealInSystem(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else {
        final target = FileSystemEntity.isDirectorySync(path)
            ? path
            : _pathParent(path);
        await Process.run('xdg-open', [target]);
      }
    } catch (e) {
      _snack('打开系统文件管理器失败：$e');
    }
  }

  Future<void> _openExternally(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      _snack('打开失败：$e');
    }
  }

  void _openShellAt(String path) {
    final dir = FileSystemEntity.isDirectorySync(path)
        ? path
        : _pathParent(path);
    addTerm(dir, '');
    _setBottomTool(_BottomTool.terminal);
  }

  void _expandProjectForFile(String path) {
    final hit = _projectForFile(path);
    if (hit == null) {
      return;
    }
    _ctlFor(hit.project.path).expand();
    Prefs.setBool('ws.sec.${hit.project.path}.files', false);
    _selectGitProject(hit.project);
  }

  void _revealFileInProject(String path) {
    final hit = _projectForFile(path);
    if (hit == null) {
      _snack('找不到文件所属项目');
      return;
    }
    setState(() => _revealedProjectFilePath = path);
    _expandProjectForFile(path);
    _openLeftTool(_LeftToolView.project);
    _snack('已展开 Project · ${hit.rel}');
  }

  void _selectOpenedFileInProject() {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    _revealFileInProject(_codeFiles[_activeFile].path);
  }

  void _revealBreadcrumbTarget(
    ({ProjectCfg project, String rel})? hit,
    String fallbackPath,
    int partIndex,
    List<String> parts,
  ) {
    if (hit == null) {
      _revealFileInProject(fallbackPath);
      return;
    }
    final target = partIndex < 0
        ? hit.project.path
        : '${hit.project.path}/${parts.take(partIndex + 1).join('/')}';
    _revealFileInProject(target);
  }

  Future<void> _showRecentFiles() async {
    if (_recentFiles.isEmpty) {
      _snack('暂无最近文件');
      return;
    }
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('最近文件'),
        children: [
          for (final p in _recentFiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Row(
                children: [
                  Icon(_iconForFile(p), size: 16, color: CcColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.code(size: 12.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (path != null) _openCodeFile(path);
  }

  Future<void> _showRecentLocations() async {
    if (_recentLocations.isEmpty) {
      _snack('暂无最近位置');
      return;
    }
    final loc = await showDialog<_CodeLocation>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Recent Locations'),
        children: [
          for (final l in _recentLocations)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, l),
              child: Row(
                children: [
                  Icon(_iconForFile(l.path), size: 16, color: CcColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.line == null ? l.name : '${l.name}:${l.line}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(size: 12.5),
                        ),
                        Text(
                          l.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(
                            size: 10.5,
                            color: CcColors.subtle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (loc != null) _openCodeFile(loc.path, line: loc.line);
  }

  Future<void> _setGitLogPathFilter() async {
    final p = _currentGitProject;
    if (p == null) {
      _snack('没有可过滤的项目');
      return;
    }
    final ctl = TextEditingController(text: _logPathFilter);
    final active = _activeFile >= 0 && _activeFile < _codeFiles.length
        ? _projectForFile(_codeFiles[_activeFile].path)
        : null;
    final activeRel = active?.project.path == p.path ? active?.rel : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Filter Log by Path'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'File or directory path',
                hintText: 'app/lib/screens/workspace_page.dart',
              ),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            if (activeRel != null && activeRel.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => ctl.text = activeRel,
                  icon: const Icon(Icons.my_location_rounded, size: 14),
                  label: Text('Use active file: $activeRel'),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (ok != true) {
      ctl.dispose();
      return;
    }
    final next = ctl.text.trim();
    ctl.dispose();
    if (!mounted) return;
    setState(() => _logPathFilter = next);
    await _refreshGit();
  }

  Future<void> _showShortcuts() async {
    final isMac = Platform.isMacOS;
    final mod = isMac ? 'Cmd' : 'Ctrl';
    final rows = [
      ('$mod+O', '快速打开文件'),
      ('$mod+F', '当前文件查找'),
      ('$mod+G', '跳转行号'),
      ('$mod+F12', '文件结构'),
      ('$mod+Alt+O', '跳转符号'),
      ('$mod+Alt+F7', '查找当前文件符号引用'),
      ('$mod+Alt+H', '打开当前文件 Git Log'),
      ('$mod+Alt+D', '打开当前文件工作区 Diff'),
      ('$mod+Alt+←/→', '代码导航后退/前进'),
      ('$mod+Shift+[/]', '切换编辑器 tab'),
      ('$mod+W', '关闭当前编辑器 tab'),
      ('$mod+Shift+1', '在 Project 中定位当前文件'),
      ('$mod+Shift+F', '全文搜索'),
      ('$mod+Shift+D', '当前文件对比 HEAD'),
      ('$mod+E', '最近文件'),
      ('$mod+Shift+E', '最近位置'),
      ('$mod+1', '切换 Project'),
      ('$mod+7', '打开 Structure'),
      ('$mod+K', '打开 Commit'),
      ('$mod+Shift+K', 'Push'),
      ('$mod+9', '打开 Commit'),
      ('$mod+Shift+9', '打开 Branches'),
      ('$mod+Alt+9', '打开 Git Log'),
      (isMac ? 'Option+F12' : 'Alt+F12', '打开 Terminal'),
      ('$mod+S', '保存当前文件'),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('快捷键'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(width: 112, child: chip(r.$1)),
                      const SizedBox(width: 12),
                      Expanded(child: Text(r.$2)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _expandWithSessions() {
    for (final ws in _cfg.workspaces) {
      for (final p in ws.projects) {
        if (_sessionsFor(p).isEmpty) continue;
        final ctl = _ctlFor(p.path);
        if (!ctl.isExpanded) ctl.expand();
      }
    }
  }

  // ----------------------------------------------------------- mutations ----

  Future<void> _newWorkspace() async {
    final v = await _fieldsDialog('新建工作区', '创建', [
      (label: '名称', hint: 'kunlun', required: true),
      (
        label: '根目录(可选)',
        hint: '默认 ~/cc-handoff-workspaces/<名>',
        required: false,
      ),
    ]);
    if (v == null) return;
    await _runCli(
      () => Cli.workspaceCreate(v[0], path: v[1].isEmpty ? null : v[1]),
      '已建工作区 ${v[0]}',
      after: _reloadConfig,
    );
  }

  // _importWorkspace picks a folder and bulk-imports every git repo under it as a
  // project (in place, not moved) into a new workspace named after the folder —
  // the one-click alternative to adding N repos one at a time. Done manually (not
  // _runCli) so the toast can report how many were imported vs skipped.
  Future<void> _importWorkspace() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择包含多个项目的目录(将扫描其中的 git 仓库)',
    );
    if (dir == null || dir.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final out = await Cli.workspaceImport(dir);
      await _reloadConfig();
      var msg = '已导入';
      try {
        final j = jsonDecode(out) as Map<String, dynamic>;
        final ws = (j['workspace'] ?? '').toString();
        final added = (j['added'] as List?)?.length ?? 0;
        final skipped = (j['skipped'] as List?)?.length ?? 0;
        msg = (added == 0 && skipped == 0)
            ? '「$ws」下没找到可导入的 git 仓库'
            : '已导入 $added 个项目到「$ws」'
                  '${skipped > 0 ? '(跳过 $skipped 个已有)' : ''}';
      } catch (_) {}
      _snack(msg);
    } catch (e) {
      _snack(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addProject(WorkspaceCfg ws) async {
    final v = await _fieldsDialog('给「${ws.name}」添加项目', '添加', [
      (
        label: 'GitHub URL 或本地路径',
        hint: 'https://github.com/org/repo.git',
        required: true,
      ),
    ]);
    if (v == null) return;
    await _runCli(
      () => Cli.workspaceAdd(ws.name, v[0]),
      '已添加(URL 会先 clone)',
      after: _reloadConfig,
    );
  }

  String _workspaceBasePath(WorkspaceCfg ws) {
    if (ws.path.trim().isNotEmpty) return ws.path.trim();
    var root = _cfg.workspaceRoot.trim();
    if (root.startsWith('~/')) {
      root = '${Platform.environment['HOME'] ?? ''}${root.substring(1)}';
    }
    if (root.isEmpty) {
      root = '${Platform.environment['HOME'] ?? ''}/cc-handoff-workspaces';
    }
    return _pathJoin(root, ws.name.isEmpty ? 'default' : ws.name);
  }

  Future<void> _newEmptyProject(WorkspaceCfg ws) async {
    final name = await _nameDialog('新建空项目', '项目名', hint: 'my-app');
    if (name == null) return;
    final path = _pathJoin(_workspaceBasePath(ws), name);
    await _runCli(
      () async {
        final dir = Directory(path);
        if (await FileSystemEntity.isFile(path)) {
          throw CliException('目标路径已存在且不是目录：$path');
        }
        if (await dir.exists()) {
          final hasEntries = !(await dir.list(followLinks: false).isEmpty);
          if (hasEntries) throw CliException('目标目录不是空目录：$path');
        } else {
          await dir.create(recursive: true);
        }
        await Cli.workspaceAdd(ws.name, path);
      },
      '已创建空项目 $name',
      after: _reloadConfig,
    );
  }

  Future<void> _removeWorkspace(WorkspaceCfg ws) async {
    if (!await _confirm('删除工作区「${ws.name}」?', '只从 config 移除,磁盘文件保留。')) return;
    await _runCli(
      () => Cli.workspaceRemove(ws.name),
      '已删除',
      after: _reloadConfig,
    );
  }

  Future<void> _removeProject(WorkspaceCfg ws, ProjectCfg p) async {
    if (!await _confirm(
      '从「${ws.name}」移除项目「${p.name}」?',
      '只从 config 移除,磁盘文件保留。',
    )) {
      return;
    }
    await _runCli(
      () => Cli.projectRemove(ws.name, p.name),
      '已移除',
      after: _reloadConfig,
    );
  }

  Future<void> _newWorktree(WorkspaceCfg ws, ProjectCfg p) async {
    final v = await _fieldsDialog('在「${p.name}」新建 worktree', '创建', [
      (label: '分支名', hint: 'feature/x', required: true),
      (label: '起点 ref(可选)', hint: '默认当前 HEAD', required: false),
    ]);
    if (v == null) return;
    await _runCli(
      () => Cli.worktreeAdd(
        p.name,
        v[0],
        workspace: ws.name,
        start: v[1].isEmpty ? null : v[1],
      ),
      '已建 worktree',
      after: () => _reloadWorktrees(p.path),
    );
  }

  Future<void> _deleteWorktree(
    WorkspaceCfg ws,
    ProjectCfg p,
    Worktree w,
  ) async {
    final br = w.branch.isEmpty ? w.name : w.branch;
    if (!await _confirm(
      '删除 worktree「$br」?',
      '会执行 git worktree remove --force。',
    )) {
      return;
    }
    await _runCli(
      () => Cli.worktreeRemove(p.name, br, workspace: ws.name, force: true),
      '已删除',
      after: () => _reloadWorktrees(p.path),
    );
  }

  // ------------------------------------------------------------- dialogs ----

  Future<List<String>?> _fieldsDialog(
    String title,
    String okLabel,
    List<({String label, String? hint, bool required})> fields,
  ) async {
    final raw = await showDialog<List<String>>(
      context: context,
      builder: (_) => WorkspaceFieldsDialog(
        title: title,
        okLabel: okLabel,
        fields: [
          for (final field in fields)
            WorkspaceFieldSpec(
              label: field.label,
              hint: field.hint,
              required: field.required,
            ),
        ],
      ),
    );
    if (raw == null) return null;
    if (!mounted) return null;
    final vals = [for (final value in raw) value.trim()];
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].required && vals[i].isEmpty) {
        _snack('${fields[i].label} 不能为空');
        return null;
      }
    }
    return vals;
  }

  @override
  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: workspaceConfirmDialogWidth(size),
            child: SingleChildScrollView(
              child: SelectableText(message, style: CcType.code(size: 12)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  void _openTask(ListItem it) {
    setState(() {
      _detailItem = it;
      _detailCollapsed = false;
      // The three right-side info panels are mutually exclusive — see
      // _setDetailCollapsed/_setTodosSidebarCollapsed/_setInboxSidebarCollapsed.
      _todosSidebarCollapsed = true;
      _inboxSidebarCollapsed = true;
    });
    Prefs.setBool('ws.detailCollapsed', false);
    Prefs.setBool('ws.todosSidebarCollapsed', true);
    Prefs.setBool('ws.inboxSidebarCollapsed', true);
  }

  // ---------------------------------------------------------------- view ----

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
            _showQuickOpen,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _showQuickOpen,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _showFindInCurrentFile,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _showFindInCurrentFile,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
            _showGoToLine,
        const SingleActivator(LogicalKeyboardKey.keyG, control: true):
            _showGoToLine,
        const SingleActivator(LogicalKeyboardKey.f12, meta: true):
            _showFileStructure,
        const SingleActivator(LogicalKeyboardKey.f12, control: true):
            _showFileStructure,
        // Go to definition: bare F12 (VS Code) + Cmd/Ctrl+B (GoLand). Cmd/Ctrl+F12
        // stays File Structure above; Cmd/Ctrl+left-click is wired in _editorCanvas.
        const SingleActivator(LogicalKeyboardKey.f12): _goToDefinition,
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
            _goToDefinition,
        const SingleActivator(LogicalKeyboardKey.keyB, control: true):
            _goToDefinition,
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true, alt: true):
            _showGoToSymbol,
        const SingleActivator(
          LogicalKeyboardKey.keyO,
          control: true,
          alt: true,
        ): _showGoToSymbol,
        const SingleActivator(LogicalKeyboardKey.f7, meta: true, alt: true):
            _showFindUsagesForActiveFile,
        const SingleActivator(LogicalKeyboardKey.f7, control: true, alt: true):
            _showFindUsagesForActiveFile,
        const SingleActivator(LogicalKeyboardKey.keyH, meta: true, alt: true):
            _openActiveFileGitLog,
        const SingleActivator(
          LogicalKeyboardKey.keyH,
          control: true,
          alt: true,
        ): _openActiveFileGitLog,
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true, alt: true):
            _openActiveFileWorkingTreeDiff,
        const SingleActivator(
          LogicalKeyboardKey.keyD,
          control: true,
          alt: true,
        ): _openActiveFileWorkingTreeDiff,
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          meta: true,
          alt: true,
        ): _navigateBack,
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          control: true,
          alt: true,
        ): _navigateBack,
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          meta: true,
          alt: true,
        ): _navigateForward,
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          control: true,
          alt: true,
        ): _navigateForward,
        const SingleActivator(
          LogicalKeyboardKey.bracketLeft,
          meta: true,
          shift: true,
        ): _selectPreviousCodeTab,
        const SingleActivator(
          LogicalKeyboardKey.bracketLeft,
          control: true,
          shift: true,
        ): _selectPreviousCodeTab,
        const SingleActivator(
          LogicalKeyboardKey.bracketRight,
          meta: true,
          shift: true,
        ): _selectNextCodeTab,
        const SingleActivator(
          LogicalKeyboardKey.bracketRight,
          control: true,
          shift: true,
        ): _selectNextCodeTab,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
            _closeActiveCodeFile,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true):
            _closeActiveCodeFile,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true):
            _showFindInFiles,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): _showFindInFiles,
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true, shift: true):
            _compareActiveFileWithHead,
        const SingleActivator(
          LogicalKeyboardKey.keyD,
          control: true,
          shift: true,
        ): _compareActiveFileWithHead,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true):
            _showRecentFiles,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true):
            _showRecentFiles,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true, shift: true):
            _showRecentLocations,
        const SingleActivator(
          LogicalKeyboardKey.keyE,
          control: true,
          shift: true,
        ): _showRecentLocations,
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true):
            _toggleProjectShortcut,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true):
            _toggleProjectShortcut,
        const SingleActivator(
          LogicalKeyboardKey.digit1,
          meta: true,
          shift: true,
        ): _selectOpenedFileInProject,
        const SingleActivator(
          LogicalKeyboardKey.digit1,
          control: true,
          shift: true,
        ): _selectOpenedFileInProject,
        const SingleActivator(LogicalKeyboardKey.digit7, meta: true):
            _openStructureShortcut,
        const SingleActivator(LogicalKeyboardKey.digit7, control: true):
            _openStructureShortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _openGitShortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openGitShortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true, shift: true):
            _pushShortcut,
        const SingleActivator(
          LogicalKeyboardKey.keyK,
          control: true,
          shift: true,
        ): _pushShortcut,
        const SingleActivator(LogicalKeyboardKey.digit9, meta: true):
            _openGitShortcut,
        const SingleActivator(LogicalKeyboardKey.digit9, control: true):
            _openGitShortcut,
        const SingleActivator(
          LogicalKeyboardKey.digit9,
          meta: true,
          shift: true,
        ): _openBranchesShortcut,
        const SingleActivator(
          LogicalKeyboardKey.digit9,
          control: true,
          shift: true,
        ): _openBranchesShortcut,
        const SingleActivator(LogicalKeyboardKey.digit9, meta: true, alt: true):
            _openLogShortcut,
        const SingleActivator(
          LogicalKeyboardKey.digit9,
          control: true,
          alt: true,
        ): _openLogShortcut,
        const SingleActivator(LogicalKeyboardKey.f12, alt: true):
            _openTerminalShortcut,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
            _saveActiveFile,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            _saveActiveFile,
      },
      child: Focus(
        focusNode: _workspaceFocus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ideToolbar(),
              Expanded(child: _ideBody()),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleProjectShortcut() {
    if (!_projectCollapsed && _leftToolView == _LeftToolView.project) {
      _setProjectCollapsed(true);
    } else {
      _openLeftTool(_LeftToolView.project);
    }
  }

  void _openStructureShortcut() => _openLeftTool(_LeftToolView.structure);

  void _openGitShortcut() => _openLeftTool(_LeftToolView.changes);

  void _openBranchesShortcut() => _showBranchDialog();

  void _openLogShortcut() => _setBottomTool(_BottomTool.git);

  void _pushShortcut() {
    final p = _currentGitProject;
    if (p == null) {
      _snack('没有可 push 的项目');
      return;
    }
    _gitPushCurrent(p);
  }

  void _openTerminalShortcut() => _setBottomTool(_BottomTool.terminal);

  String _shortcutModLabel() => Platform.isMacOS ? 'Cmd' : 'Ctrl';

  void _saveActiveFile() {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    _codeFiles[_activeFile].key.currentState?.save();
  }

  ({ProjectCfg project, String rel})? _projectForFile(String path) {
    ProjectCfg? best;
    for (final ws in _cfg.workspaces) {
      for (final p in ws.projects) {
        if (pathWithin(path, p.path)) {
          if (best == null || p.path.length > best.path.length) best = p;
        }
      }
    }
    if (best == null) return null;
    final rel = pathRelativeTo(best.path, path);
    return (project: best, rel: rel);
  }

  // _sendGroupsFor splits live sessions into same-project vs other-project,
  // relative to [sourcePath] (a session's workdir or an open file's path),
  // excluding [excludeId]. Powers the grouped "发送到会话" menus: same-project
  // sessions inline, others under 其他会话. Source with no project → all "others".
  ({List<SendTarget> same, List<SendTarget> others}) _sendGroupsFor(
    String sourcePath, {
    String? excludeId,
  }) {
    final srcProj = _projectForFile(sourcePath)?.project.path;
    final same = <SendTarget>[];
    final others = <SendTarget>[];
    for (final s in terms) {
      if (s.id == excludeId) continue;
      final sp = _projectForFile(s.workdir)?.project.path;
      (srcProj != null && sp == srcProj ? same : others).add(s.asTarget);
    }
    return (same: same, others: others);
  }

  // sendGroupsFor (overriding the flat default) groups a terminal's send targets
  // by project: same-project siblings first, other-project sessions under 其他会话.
  @override
  ({List<SendTarget> same, List<SendTarget> others}) sendGroupsFor(
    String selfId,
  ) {
    final self = sessionById(selfId);
    if (self == null) {
      return (
        same: [for (final s in peersExcluding(selfId)) s.asTarget],
        others: const [],
      );
    }
    return _sendGroupsFor(self.workdir, excludeId: selfId);
  }

  // _showEditorSendMenu forwards the active file's current selection to a chosen
  // session (grouped by project), injecting it with a 来自文件 prefix. No-op
  // without a selection. Wired to right-click in the file viewer.
  Future<void> _showEditorSendMenu(Offset globalPos) async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    final f = _codeFiles[_activeFile];
    final text = f.key.currentState?.selectedText ?? '';
    if (text.trim().isEmpty) {
      _snack('请先在文件里选中要发送的内容');
      return;
    }
    final g = _sendGroupsFor(f.path);
    final v = await showGroupedSendMenu(
      context,
      globalPos,
      same: g.same,
      others: g.others,
      extraBottom: [
        if (_canSendToOnline)
          ccMenuItem(
            value: 'online',
            icon: Icons.cloud_upload_rounded,
            label: '发送到在线用户…',
          ),
      ],
    );
    if (v == null || !mounted) return;
    if (v == 'online') {
      _showSendToOnlineUser(text, sourcePath: f.path);
      return;
    }
    if (!v.startsWith('send:')) return;
    final target = sessionById(v.substring('send:'.length));
    if (target == null) return;
    target.pasteText('[来自文件 ${pathBaseName(f.path)}] $text', submit: false);
    _snack('已发送到 ${target.label}');
  }

  Future<void> _showBlameForActiveFile() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    final file = _codeFiles[_activeFile].path;
    final hit = _projectForFile(file);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    _showBlameForProjectFile(hit.project, hit.rel);
  }

  @override
  void _showBlameForProjectFile(ProjectCfg project, String relPath) {
    if (relPath.trim().isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => _BlameDialog(project: project, relPath: relPath),
    );
  }

  Future<void> _showFileHistoryForActiveFile() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    final file = _codeFiles[_activeFile].path;
    final hit = _projectForFile(file);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    _showFileHistoryForProjectFile(hit.project, hit.rel);
  }

  @override
  void _showFileHistoryForProjectFile(ProjectCfg project, String relPath) {
    if (relPath.trim().isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => _FileHistoryDialog(project: project, relPath: relPath),
    );
  }

  Future<void> _openActiveFileGitLog() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    await _openFileGitLog(_codeFiles[_activeFile].path);
  }

  Future<void> _openFileGitLog(String path) async {
    final hit = _projectForFile(path);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    setState(() {
      _gitProject = hit.project;
      _bottomTool = _BottomTool.git;
      _terminalCollapsed = false;
      _logPathFilter = hit.rel;
      _compareTitle = null;
      _compareFiles = const [];
      _commitFiles = const [];
      _selectedCommit = null;
    });
    Prefs.setString('ws.bottomTool', 'git');
    Prefs.setBool('ws.terminalCollapsed', false);
    await _refreshGit();
  }

  Future<void> _openActiveFileWorkingTreeDiff() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    await _openFileWorkingTreeDiff(_codeFiles[_activeFile].path);
  }

  Future<void> _openFileWorkingTreeDiff(String path) async {
    final hit = _projectForFile(path);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    setState(() {
      _gitProject = hit.project;
      _bottomTool = _BottomTool.git;
      _terminalCollapsed = false;
      _selectedGitPath = hit.rel;
      _selectedChangePaths
        ..clear()
        ..add(hit.rel);
    });
    Prefs.setString('ws.bottomTool', 'git');
    Prefs.setBool('ws.terminalCollapsed', false);
    await _refreshGit();
    if (!mounted) return;
    final hasDiff = _gitFiles.any((f) => f.path == hit.rel);
    final hasChange = _gitChanges.any(
      (c) => c.path == hit.rel || c.oldPath == hit.rel,
    );
    if (!hasDiff && !hasChange) {
      _snack('当前文件没有工作区改动');
    } else {
      setState(() => _selectedGitPath = hit.rel);
    }
  }

  Future<void> _compareActiveFileWithHead() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    final file = _codeFiles[_activeFile].path;
    final hit = _projectForFile(file);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    await _compareProjectFileWithHead(hit.project, hit.rel);
  }

  @override
  Future<void> _compareProjectFileWithHead(
    ProjectCfg project,
    String relPath,
  ) async {
    if (relPath.trim().isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    try {
      final diff = await gitDiffFileWorking(project.path, relPath);
      final files = parseUnifiedDiff(diff);
      if (files.isEmpty) {
        _snack('当前文件没有相对 HEAD 的改动');
        return;
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: SizedBox(
            width: 1040,
            height: 720,
            child: Column(
              children: [
                Container(
                  height: 42,
                  padding: const EdgeInsets.only(left: 14, right: 6),
                  decoration: const BoxDecoration(
                    color: CcColors.panel,
                    border: Border(bottom: BorderSide(color: CcColors.border)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.compare_arrows_rounded,
                        size: 17,
                        color: CcColors.muted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Compare with HEAD · $relPath',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: DiffView(
                    files: files,
                    editRoot: project.path,
                    onChanged: _refreshGit,
                    onReloadContext: (ctx) async => parseUnifiedDiff(
                      await gitDiffFileWorking(
                        project.path,
                        relPath,
                        context: ctx,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _snack(errorText(e));
    }
  }

  Widget _ideToolbar() {
    final projects = _cfg.workspaces.fold<int>(
      0,
      (sum, ws) => sum + ws.projects.length,
    );
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: CcColors.toolbar,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: scrollableBar(
        scrolling: [
          _vcsOperationsMenu(),
          const VerticalDivider(width: 14),
          _toolButton(
            icon: Icons.arrow_back_rounded,
            tooltip: '代码导航后退',
            selected: false,
            onPressed: _codeBackStack.isEmpty ? null : _navigateBack,
          ),
          _toolButton(
            icon: Icons.arrow_forward_rounded,
            tooltip: '代码导航前进',
            selected: false,
            onPressed: _codeForwardStack.isEmpty ? null : _navigateForward,
          ),
          _toolButton(
            icon: Icons.file_open_outlined,
            tooltip: '快速打开文件',
            selected: false,
            onPressed: _showQuickOpen,
          ),
          _toolButton(
            icon: Icons.manage_search_rounded,
            tooltip: '全文搜索',
            selected: false,
            onPressed: _showFindInFiles,
          ),
          _toolButton(
            icon: Icons.data_object_rounded,
            tooltip: '跳转符号',
            selected: false,
            onPressed: _showGoToSymbol,
          ),
          _toolButton(
            icon: Icons.history_rounded,
            tooltip: '最近文件',
            selected: false,
            onPressed: _showRecentFiles,
          ),
          _toolButton(
            icon: Icons.location_history_rounded,
            tooltip: '最近位置',
            selected: false,
            onPressed: _showRecentLocations,
          ),
          _toolButton(
            icon: Icons.keyboard_command_key_rounded,
            tooltip: '快捷键',
            selected: false,
            onPressed: _showShortcuts,
          ),
          _toolButton(
            icon: Icons.extension_rounded,
            tooltip: '格式化插件',
            selected: false,
            onPressed: () => showPluginsDialog(context),
          ),
          _toolButton(
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            selected: false,
            onPressed: _busy ? null : _refresh,
          ),
          _toolButton(
            icon: _remoteHost.sharing
                ? (_remoteHost.clientCount > 0
                      ? Icons.cast_connected_rounded
                      : Icons.cast_rounded)
                : Icons.cast_outlined,
            tooltip: _remoteHost.sharing
                ? '手机远程：${_remoteHost.connected ? (_remoteHost.clientCount > 0 ? '${_remoteHost.clientCount} 台已连' : '等待手机') : '连接中…'}（点击关闭共享）'
                : '把工作区共享给手机（远程办公）',
            selected: _remoteHost.sharing,
            activeColor: _remoteActiveColor(),
            onPressed: () {
              if (_remoteHost.sharing) {
                _remoteHost.disable();
                _remoteSnack('已停止共享');
              } else if (!_relayConfigured) {
                _remoteSnack('请先登录 relay 后再共享给手机', error: true);
              } else {
                _remoteHost.enable();
                _remoteSnack('已开启共享 · 正在连接 relay…');
              }
            },
          ),
          _toolButton(
            icon: Icons.upload_file_outlined,
            tooltip: _remoteHost.clientCount > 0
                ? '发送文件到手机'
                : '发送文件到手机（需先有手机连接）',
            selected: false,
            onPressed: (_remoteHost.sharing && _remoteHost.clientCount > 0)
                ? _sendFileToPhone
                : null,
          ),
          _runChip('Claude', Icons.play_arrow_rounded, _launchDefaultClaude),
          _runChip('Codex', Icons.smart_toy_outlined, _launchDefaultCodex),
          _runChip('总管', Icons.account_tree_outlined, _launchDefaultSupervisor),
          const VerticalDivider(width: 14),
          _toolButton(
            icon: Icons.inbox_rounded,
            tooltip: '收件箱',
            selected: !_inboxSidebarCollapsed,
            onPressed: () => _setInboxSidebarCollapsed(!_inboxSidebarCollapsed),
          ),
          _toolButton(
            icon: Icons.checklist_rounded,
            tooltip: '待办',
            selected: !_todosSidebarCollapsed,
            onPressed: () => _setTodosSidebarCollapsed(!_todosSidebarCollapsed),
          ),
        ],
        pinnedTrailing: [
          if (_busy)
            const SizedBox(
              width: 130,
              child: LinearProgressIndicator(minHeight: 2),
            )
          else ...[
            Icon(Icons.folder_copy_outlined, size: 15, color: CcColors.muted),
            const SizedBox(width: 6),
            Text(
              '$projects projects',
              style: CcType.code(size: 11.5, color: CcColors.muted),
            ),
          ],
          const SizedBox(width: 12),
          Text(
            '${terms.length} sessions',
            style: CcType.code(size: 11.5, color: CcColors.subtle),
          ),
          if (_parked.isNotEmpty) ...[const SizedBox(width: 4), _parkedBadge()],
          const SizedBox(width: 4),
          _transcriptToggle(),
          _ttsToggle(),
          _micButton(),
        ],
      ),
    );
  }

  // _transcriptToggle switches how `msg read` reads a peer's output: structured
  // transcript (on) vs screen-scrape (off). Persisted; LocalBus reads the same
  // Pref. `msg read --transcript` overrides it per-call.
  Widget _transcriptToggle() => IconButton(
    tooltip: _readTranscript
        ? '读对方输出: transcript 结构化 (点击切回截屏)'
        : '读对方输出: 截屏 (点击切到 transcript 结构化)',
    visualDensity: VisualDensity.compact,
    onPressed: () {
      final on = !_readTranscript;
      setState(() => _readTranscript = on);
      Prefs.setBool('ws.read_transcript', on);
      _snack(on ? 'msg read 改用 transcript(结构化)' : 'msg read 改回截屏');
    },
    icon: Icon(
      _readTranscript ? Icons.article_rounded : Icons.article_outlined,
      size: 18,
      color: _readTranscript ? CcColors.accent : CcColors.muted,
    ),
  );

  // _ttsToggle turns reading-agent-replies-aloud on/off (persisted). Enabling it
  // arms the baseline on the active session so only future turns are read.
  Widget _ttsToggle() => IconButton(
    tooltip: _ttsOn ? '朗读已开启 (点击关闭)' : '朗读 AI 回复',
    visualDensity: VisualDensity.compact,
    onPressed: () {
      final on = !_ttsOn;
      setState(() => _ttsOn = on);
      Prefs.setBool('ws.tts', on);
      if (on) {
        onActiveTermChanged?.call(); // arm the active session (reads _ttsOn)
        _snack('已开启朗读 AI 回复');
      } else {
        _voice.stopSpeaking();
        _snack('已关闭朗读');
      }
    },
    icon: Icon(
      _ttsOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
      size: 18,
      color: _ttsOn ? CcColors.accent : CcColors.muted,
    ),
  );

  // _micButton is push-to-talk for the active terminal: tap to dictate, the
  // recognized text is injected into that session's input (not auto-submitted).
  Widget _micButton() => IconButton(
    tooltip: _listening ? '正在听… (点击停止)' : '语音输入到当前会话',
    visualDensity: VisualDensity.compact,
    onPressed: _toggleMic,
    icon: Icon(
      _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
      size: 18,
      color: _listening ? CcColors.danger : CcColors.muted,
    ),
  );

  Future<void> _toggleMic() async {
    if (_listening) {
      await _voice.stopListening();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (terms.isEmpty) {
      _snack('没有可输入的会话');
      return;
    }
    final target = terms[activeTerm];
    final ok = await _voice.startListening(
      onFinal: (text) {
        if (!mounted) return;
        setState(() => _listening = false);
        final t = text.trim();
        if (t.isEmpty) return;
        target.pasteText(t, submit: false); // user reviews, then hits enter
        _snack('🎤 $t');
      },
    );
    if (!mounted) return;
    if (ok) {
      setState(() => _listening = true);
    } else {
      _snack('语音识别不可用:${_voice.sttError ?? "检查麦克风/语音识别权限"}');
    }
  }

  // _parkedBadge is the toolbar "待处理 (N)" inbox button with a count pill.
  Widget _parkedBadge() => IconButton(
    tooltip: '待处理消息 (${_parked.length})',
    visualDensity: VisualDensity.compact,
    onPressed: _showParkedList,
    icon: Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.inbox_rounded, size: 18),
        Positioned(
          right: -4,
          top: -4,
          child: Container(
            constraints: const BoxConstraints(minWidth: 15),
            height: 15,
            padding: const EdgeInsets.symmetric(horizontal: 3),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: CcColors.accent,
              borderRadius: BorderRadius.circular(CcRadius.pill),
            ),
            child: Text(
              '${_parked.length}',
              style: CcType.code(
                size: 8.5,
                color: CcColors.bg,
                weight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  void _setProjectCollapsed(bool v) {
    setState(() => _projectCollapsed = v);
    Prefs.setBool('ws.projectCollapsed', v);
  }

  void _openLeftTool(_LeftToolView view) {
    setState(() {
      _leftToolView = view;
      _projectCollapsed = false;
    });
    Prefs.setString('ws.leftTool', _leftToolPref(view));
    Prefs.setBool('ws.projectCollapsed', false);
    if (_gitViewForLeftTool(view) != null) _refreshGit();
  }

  // The Handoff detail panel, the 待办 sidebar, and the 收件箱 sidebar share the
  // same right-hand slot — opening one collapses the other two rather than
  // the three competing for width side by side.
  void _setDetailCollapsed(bool v) {
    setState(() {
      _detailCollapsed = v;
      if (!v) {
        _todosSidebarCollapsed = true;
        _inboxSidebarCollapsed = true;
      }
    });
    Prefs.setBool('ws.detailCollapsed', v);
    if (!v) {
      Prefs.setBool('ws.todosSidebarCollapsed', true);
      Prefs.setBool('ws.inboxSidebarCollapsed', true);
    }
  }

  void _setTodosSidebarCollapsed(bool v) {
    setState(() {
      _todosSidebarCollapsed = v;
      if (!v) {
        _detailCollapsed = true;
        _inboxSidebarCollapsed = true;
      }
    });
    Prefs.setBool('ws.todosSidebarCollapsed', v);
    if (!v) {
      Prefs.setBool('ws.detailCollapsed', true);
      Prefs.setBool('ws.inboxSidebarCollapsed', true);
    }
  }

  void _setInboxSidebarCollapsed(bool v) {
    setState(() {
      _inboxSidebarCollapsed = v;
      if (!v) {
        _detailCollapsed = true;
        _todosSidebarCollapsed = true;
      }
    });
    Prefs.setBool('ws.inboxSidebarCollapsed', v);
    if (!v) {
      Prefs.setBool('ws.detailCollapsed', true);
      Prefs.setBool('ws.todosSidebarCollapsed', true);
    }
  }

  void _setTerminalCollapsed(bool v) {
    setState(() => _terminalCollapsed = v);
    Prefs.setBool('ws.terminalCollapsed', v);
  }

  @override
  ({WorkspaceCfg ws, ProjectCfg project})? _defaultProject() {
    for (final ws in _cfg.workspaces) {
      if (ws.projects.isNotEmpty) return (ws: ws, project: ws.projects.first);
    }
    return null;
  }

  void _launchDefaultClaude() {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可启动的项目');
      return;
    }
    _openAgent(d.project, d.project.path, 'claude', d.ws.preLaunch);
  }

  void _launchDefaultCodex() {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可启动的项目');
      return;
    }
    _openAgent(d.project, d.project.path, 'codex', d.ws.preLaunch);
  }

  void _launchDefaultSupervisor() {
    unawaited(_launchDefaultSupervisorFlow());
  }

  Future<void> _launchDefaultSupervisorFlow() async {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可启动的项目');
      return;
    }
    await _supervisorFlow(d.project, d.project.path, d.ws.preLaunch);
  }

  // _supervisorFlow shows the 总管 picker (Claude / Codex / 编辑知识库) scoped to
  // [dir], then either launches a supervisor session (supervisor: true) in that
  // project context or opens its knowledge-base editor. Shared by the toolbar 总管
  // chip (_launchDefaultSupervisorFlow) and the project right-click menu (起总管)
  // so both behave identically.
  Future<void> _supervisorFlow(
    ProjectCfg p,
    String dir,
    String preLaunch,
  ) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('总管'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Claude 总管'),
              onTap: () => Navigator.of(ctx).pop('claude'),
            ),
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: const Text('Codex 总管'),
              onTap: () => Navigator.of(ctx).pop('codex'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('编辑知识库'),
              subtitle: const Text('.cc-handoff/supervisor'),
              onTap: () => Navigator.of(ctx).pop('edit'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'edit') {
      // The knowledge files live on this machine, so edit them directly with
      // the local file browser + editor (no relay). Ensure the dir + template
      // files exist first (cc-handoff supervisor init).
      await _ensureSupervisorDocs(dir);
      if (!mounted) return;
      _openFileBrowser('$dir/.cc-handoff/supervisor', '总管知识库');
      return;
    }
    _openAgent(p, dir, choice, preLaunch, supervisor: true);
  }

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required bool selected,
    required VoidCallback? onPressed,
    Color? activeColor,
  }) => Padding(
    padding: const EdgeInsets.only(right: 2),
    child: Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18),
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: selected
              ? (activeColor ?? CcColors.text)
              : CcColors.muted,
          backgroundColor: selected
              ? (activeColor ?? CcColors.accent).withValues(alpha: 0.16)
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
    ),
  );

  PopupMenuButton<String> _vcsOperationsMenu() {
    final p = _currentGitProject;
    final status = p == null ? null : _gitStatus;
    final dirtyTotal = status == null
        ? 0
        : status.staged +
              status.modified +
              status.untracked +
              status.conflicted;
    final canStageAll = status?.hasStageableChanges ?? false;
    final canUnstageAll = status?.hasStagedChanges ?? false;
    final canRollbackAll = status?.hasAnyChanges ?? false;
    final mod = _shortcutModLabel();
    return PopupMenuButton<String>(
      tooltip: p == null ? 'VCS Operations · 没有项目' : 'VCS Operations',
      enabled: p != null,
      padding: EdgeInsets.zero,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.hub_rounded, size: 18),
          if (dirtyTotal > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                constraints: const BoxConstraints(minWidth: 15),
                height: 15,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: status?.conflicted == 0
                      ? CcColors.warning
                      : CcColors.danger,
                  borderRadius: BorderRadius.circular(CcRadius.pill),
                ),
                child: Text(
                  '$dirtyTotal',
                  style: CcType.code(
                    size: 8.5,
                    color: CcColors.bg,
                    weight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
      onOpened: () {
        if (p != null) _selectGitProject(p);
      },
      onSelected: (v) {
        if (p == null) return;
        _handleGitMenuAction(p, v);
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Row(
            children: [
              const Icon(
                Icons.account_tree_rounded,
                size: 16,
                color: CcColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status == null
                      ? p?.name ?? 'No Git project'
                      : '${status.branch} · ${status.clean ? 'clean' : '$dirtyTotal changes'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 12, color: CcColors.text),
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'changes',
          icon: Icons.list_alt_rounded,
          label: 'Open Changes',
          shortcut: '$mod+9',
        ),
        ccMenuItem(
          value: 'workingDiff',
          icon: Icons.difference_rounded,
          label: 'Show Working Tree Diff',
        ),
        ccMenuItem(
          value: 'commit',
          icon: Icons.check_circle_outline_rounded,
          label: 'Commit...',
          shortcut: '$mod+K',
        ),
        ccMenuItem(
          value: 'log',
          icon: Icons.history_rounded,
          label: 'Open Git Log',
          shortcut: '$mod+Alt+9',
        ),
        ccMenuItem(
          value: 'branches',
          icon: Icons.account_tree_rounded,
          label: 'Open Branches',
          shortcut: '$mod+Shift+9',
        ),
        ccMenuItem(
          value: 'stash',
          icon: Icons.inventory_2_outlined,
          label: 'Open Stash',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'branchPopup',
          icon: Icons.call_split_rounded,
          label: 'Branches Popup...',
        ),
        ccMenuItem(
          value: 'newBranch',
          icon: Icons.add_rounded,
          label: 'New Branch...',
        ),
        const PopupMenuDivider(),
        ccMenuItem(value: 'fetch', icon: Icons.sync_rounded, label: 'Fetch'),
        ccMenuItem(
          value: 'fetchPrune',
          icon: Icons.cleaning_services_outlined,
          label: 'Fetch --prune',
        ),
        ccMenuItem(
          value: 'pull',
          icon: Icons.call_received_rounded,
          label: 'Pull --ff-only',
        ),
        ccMenuItem(
          value: 'pullRebase',
          icon: Icons.vertical_align_top_rounded,
          label: 'Pull --rebase',
        ),
        ccMenuItem(
          value: 'push',
          icon: Icons.upload_rounded,
          label: 'Push',
          shortcut: '$mod+Shift+K',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: canStageAll ? 'stageAll' : null,
          icon: Icons.add_task_rounded,
          label: 'Stage All',
        ),
        ccMenuItem(
          value: canUnstageAll ? 'unstageAll' : null,
          icon: Icons.remove_done_rounded,
          label: 'Unstage All',
        ),
        ccMenuItem(
          value: 'stashPush',
          icon: Icons.archive_outlined,
          label: 'Stash Changes...',
        ),
        ccMenuItem(
          value: canRollbackAll ? 'rollbackAll' : null,
          icon: Icons.restore_rounded,
          label: 'Rollback All...',
          danger: true,
        ),
      ],
    );
  }

  Widget _runChip(String label, IconData icon, VoidCallback onPressed) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 15),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            foregroundColor: CcColors.text,
            side: const BorderSide(color: CcColors.borderSoft),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );

  Widget _toolStripe({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool right = false,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      width: 32,
      decoration: BoxDecoration(
        color: CcColors.panel,
        border: Border(
          left: right
              ? const BorderSide(color: CcColors.border)
              : BorderSide.none,
          right: right
              ? BorderSide.none
              : const BorderSide(color: CcColors.border),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Icon(icon, size: 17, color: CcColors.muted),
          const SizedBox(height: 8),
          Expanded(
            child: RotatedBox(
              quarterTurns: right ? 1 : 3,
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CcColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _ideBody() {
    final terminalOpen = !_terminalCollapsed;
    // When the AI chat is focused into the editor area, the bottom collapses to
    // the status strip — the terminal can't render in two places at once.
    final dockTerminal = terminalOpen && !_aiChatFocused;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Clamp the bottom tool window to the height actually available so it can
        // never shrink the editor below zero and overflow the column (the
        // "BOTTOM OVERFLOWED BY N PIXELS" hazard stripe on short windows / when a
        // large persisted _terminalHeight exceeds the current viewport).
        const minEditor = 120.0;
        const handle = 7.0;
        final maxTerm = (constraints.maxHeight - handle - minEditor).clamp(
          120.0,
          double.infinity,
        );
        final termHeight = _terminalHeight.clamp(120.0, maxTerm);
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  _leftToolWindowBar(),
                  if (!_projectCollapsed) ...[
                    SizedBox(width: _treeWidth, child: _leftToolPanel()),
                    resizeHandle(
                      prefKey: 'ws.treeWidth',
                      get: () => _treeWidth,
                      set: (v) => setState(() => _treeWidth = v),
                      min: 260,
                      max: 520,
                    ),
                  ],
                  Expanded(child: _editorArea()),
                  if (!_todosSidebarCollapsed) ...[
                    resizeHandle(
                      prefKey: 'ws.todosSidebarWidth',
                      get: () => _todosSidebarWidth,
                      set: (v) => setState(() => _todosSidebarWidth = v),
                      min: 360,
                      max: 820,
                      invert: true,
                    ),
                    SizedBox(
                      width: _todosSidebarWidth,
                      child: _todosSidebarPanel(),
                    ),
                  ],
                  if (!_inboxSidebarCollapsed) ...[
                    resizeHandle(
                      prefKey: 'ws.inboxSidebarWidth',
                      get: () => _inboxSidebarWidth,
                      set: (v) => setState(() => _inboxSidebarWidth = v),
                      min: 360,
                      max: 820,
                      invert: true,
                    ),
                    SizedBox(
                      width: _inboxSidebarWidth,
                      child: _inboxSidebarPanel(),
                    ),
                  ],
                  if (_detailItem != null) ...[
                    if (!_detailCollapsed) ...[
                      resizeHandle(
                        prefKey: 'ws.detailWidth',
                        get: () => _detailWidth,
                        set: (v) => setState(() => _detailWidth = v),
                        min: 360,
                        max: 820,
                        invert: true,
                      ),
                      SizedBox(
                        width: _detailWidth,
                        child: _detailPanel(_detailItem!),
                      ),
                    ] else
                      _toolStripe(
                        icon: Icons.description_outlined,
                        label: 'Handoff',
                        right: true,
                        onTap: () => _setDetailCollapsed(false),
                      ),
                  ],
                ],
              ),
            ),
            if (dockTerminal) ...[
              _horizontalResizeHandle(maxTerm),
              SizedBox(height: termHeight, child: _terminalToolWindow()),
            ] else
              _bottomStripe(),
          ],
        );
      },
    );
  }

  Widget _leftToolWindowBar() {
    final mod = _shortcutModLabel();
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    return Container(
      width: 46,
      decoration: const BoxDecoration(
        color: CcColors.toolbar,
        border: Border(right: BorderSide(color: CcColors.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                children: [
                  _leftToolButton(
                    icon: Icons.account_tree_outlined,
                    tooltip: 'Project · $mod+1',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.project,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.project) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.project);
                      }
                    },
                  ),
                  _leftToolButton(
                    icon: Icons.schema_rounded,
                    tooltip: hasActiveFile
                        ? 'Structure · $mod+7'
                        : 'Structure · 打开文件后可用',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.structure,
                    enabled: hasActiveFile,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.structure) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.structure);
                      }
                    },
                  ),
                  _leftToolButton(
                    icon: Icons.alt_route_rounded,
                    tooltip: 'Commit · $mod+K / $mod+9',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.changes,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.changes) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.changes);
                      }
                    },
                  ),
                  _leftToolButton(
                    icon: Icons.account_tree_rounded,
                    tooltip: 'Branches 弹窗 · $mod+Shift+9',
                    selected: false,
                    onTap: _openBranchesShortcut,
                  ),
                  _leftToolButton(
                    icon: Icons.history_rounded,
                    tooltip: 'Git Log · $mod+Alt+9（底部）',
                    selected:
                        !_terminalCollapsed && _bottomTool == _BottomTool.git,
                    onTap: _openLogShortcut,
                  ),
                  _leftToolButton(
                    icon: Icons.inventory_2_outlined,
                    tooltip: 'Stash',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.stash,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.stash) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.stash);
                      }
                    },
                  ),
                  _leftToolButton(
                    icon: Icons.terminal_rounded,
                    tooltip:
                        'Terminal · ${Platform.isMacOS ? 'Option' : 'Alt'}+F12',
                    selected:
                        !_terminalCollapsed &&
                        _bottomTool == _BottomTool.terminal,
                    onTap: () => _setBottomTool(_BottomTool.terminal),
                  ),
                  _leftToolButton(
                    icon: Icons.description_outlined,
                    tooltip: _detailItem == null
                        ? 'Handoff · 选择任务后可用'
                        : 'Handoff',
                    selected: _detailItem != null && !_detailCollapsed,
                    enabled: _detailItem != null,
                    onTap: () => _setDetailCollapsed(!_detailCollapsed),
                  ),
                  _leftToolButton(
                    icon: Icons.checklist_rounded,
                    tooltip: '待办',
                    selected: !_todosSidebarCollapsed,
                    onTap: () =>
                        _setTodosSidebarCollapsed(!_todosSidebarCollapsed),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _leftToolButton({
    required IconData icon,
    required String tooltip,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) => Tooltip(
    message: tooltip,
    preferBelow: false,
    child: InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 46,
        height: 44,
        decoration: BoxDecoration(
          color: selected
              ? CcColors.accent.withValues(alpha: 0.14)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? CcColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Center(
          child: Icon(
            icon,
            size: 18,
            color: !enabled
                ? CcColors.subtle.withValues(alpha: 0.55)
                : selected
                ? CcColors.accentBright
                : CcColors.muted,
          ),
        ),
      ),
    ),
  );

  Widget _editorArea() {
    // Not split (the overwhelmingly common case, and the only case before
    // this feature existed): render exactly as before, byte-for-byte — the
    // split-pane machinery below is never even consulted.
    if (_filePaneTree is! PaneSplit) {
      return Column(
        children: [
          _editorTabs(),
          _editorHeader(),
          Expanded(child: _editorCanvas()),
        ],
      );
    }
    return SplitPaneView(
      tree: _filePaneTree,
      paneBuilder: (context, paneId) => _buildFilePane(paneId),
      onWeightsChanged: (target, weights) => setState(() {
        _filePaneTree = updateWeights(_filePaneTree, target, weights);
      }),
    );
  }

  // One pane of a split file editor: its own filtered tab strip, header and
  // canvas, all driven by that pane's own active file rather than the
  // global _activeFile. Tapping anywhere in the pane focuses it (so the
  // existing pane-unaware toolbar actions — save, go-to-def, structure —
  // apply to the right file); Listener (not GestureDetector) so it never
  // competes with the tab/button taps inside for the gesture arena.
  Widget _buildFilePane(String paneId) {
    final indices = _paneFileIndices(paneId);
    final activePath = _paneActivePath[paneId];
    final activeIndex = activePath == null
        ? -1
        : _codeFiles.indexWhere((f) => f.path == activePath);
    final file = activeIndex >= 0 ? _codeFiles[activeIndex] : null;
    final focused = paneId == _focusedPaneId;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!focused) setState(() => _focusPane(paneId));
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: focused ? CcColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Column(
          children: [
            _paneTabStrip(paneId, indices, activeIndex),
            _editorHeaderFor(file),
            Expanded(child: _editorCanvasFor(file)),
          ],
        ),
      ),
    );
  }

  // Filtered tab strip for one pane in split mode — reuses the same
  // single-tab widget (_editorTab) and menus as the unsplit tab bar, just
  // scoped to indices belonging to this pane.
  Widget _paneTabStrip(String paneId, List<int> indices, int activeIndex) {
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: CcColors.editorTabBar,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: indices.length,
              itemBuilder: (_, j) {
                final i = indices[j];
                final file = _codeFiles[i];
                return _editorTab(
                  icon: file.isDiff
                      ? Icons.difference_rounded
                      : _iconForFile(file.path),
                  label: '${file.dirty ? '● ' : ''}${file.name}',
                  active: i == activeIndex,
                  change: _fileGitChange(file.path),
                  onTap: () => _activatePaneTab(paneId, file.path),
                  onClose: () => _closeCodeFile(i),
                  tabMenu: _editorFileTabMenu(i),
                  onSecondaryTapDown: (d) =>
                      _showEditorTabMenu(d.globalPosition, i),
                );
              },
            ),
          ),
          // "关闭此分屏": non-root panes only — 'root' is the primary editor
          // pane, not a closeable split. Closes every file in this pane (with
          // the usual dirty-file confirm inside _closePaneFiles) and folds the
          // split back into its sibling.
          if (paneId != 'root')
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 16),
              tooltip: '关闭此分屏',
              visualDensity: VisualDensity.compact,
              onPressed: () => _closePaneFiles(paneId),
            ),
        ],
      ),
    );
  }

  Widget _editorHeader() {
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    return _editorHeaderFor(hasActiveFile ? _codeFiles[_activeFile] : null);
  }

  // Parameterized so a split pane's own header can drive off that pane's
  // active file instead of the global _activeFile.
  Widget _editorHeaderFor(_OpenFile? file) {
    if (file == null) return const SizedBox.shrink();
    final state = file.key.currentState;
    final hit = _projectForFile(file.path);
    final rel = hit?.rel.isNotEmpty == true ? hit!.rel : file.path;
    final parts = rel.split('/').where((p) => p.isNotEmpty).toList();
    final bytes = state?.fileBytes;
    final byteText = bytes == null ? '' : _formatBytes(bytes);
    final change = _fileGitChange(file.path);
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 10, right: 8),
      decoration: const BoxDecoration(
        color: CcColors.editor,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          Icon(_iconForFile(file.path), size: 15, color: CcColors.muted),
          const SizedBox(width: 8),
          if (hit != null) ...[
            _breadcrumbPart(
              label: hit.project.name,
              selected: parts.isEmpty,
              accent: true,
              onTap: () => _revealBreadcrumbTarget(hit, file.path, -1, parts),
            ),
            if (parts.isNotEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: CcColors.subtle,
                ),
              ),
          ],
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < parts.length; i++) ...[
                    _breadcrumbPart(
                      label: parts[i],
                      selected: i == parts.length - 1,
                      onTap: () =>
                          _revealBreadcrumbTarget(hit, file.path, i, parts),
                    ),
                    if (i != parts.length - 1)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 5),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          size: 13,
                          color: CcColors.subtle,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (change != null) ...[
            tag(_gitChangeLongLabel(change), _changeColor(change), bold: true),
            const SizedBox(width: 6),
          ],
          if (file.dirty) tag('modified', CcColors.warning),
          if (file.line != null)
            tag('line ${file.line}', CcColors.accentBright),
          TextButton.icon(
            onPressed: _showGoToLine,
            icon: const Icon(Icons.format_list_numbered_rounded, size: 14),
            label: const Text('Go To'),
          ),
          TextButton.icon(
            onPressed: () => _revealFileInProject(file.path),
            icon: const Icon(Icons.my_location_rounded, size: 14),
            label: const Text('Reveal'),
          ),
          if (state?.saving == true) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
          const SizedBox(width: 10),
          _editorMetaChip(
            Icons.notes_rounded,
            '${state?.lineCount ?? 0} lines',
          ),
          _editorMetaChip(Icons.code_rounded, state?.languageLabel ?? 'Text'),
          _editorMetaChip(Icons.keyboard_return_rounded, state?.eol ?? 'LF'),
          if (byteText.isNotEmpty)
            _editorMetaChip(Icons.data_object_rounded, byteText),
        ],
      ),
    );
  }

  Widget _breadcrumbPart({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    final color = accent
        ? CcColors.accentBright
        : selected
        ? CcColors.text
        : CcColors.muted;
    return Tooltip(
      message: 'Reveal $label in Project',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(
              size: 11.5,
              color: color,
              weight: selected || accent ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _editorMetaChip(IconData icon, String label) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: CcColors.subtle),
        const SizedBox(width: 4),
        Text(label, style: CcType.code(size: 10.5, color: CcColors.subtle)),
      ],
    ),
  );

  Widget _editorTabs() {
    final title = _detailItem?.headline.isNotEmpty == true
        ? _detailItem!.headline
        : _detailItem?.id ?? 'Workspace';
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: CcColors.editorTabBar,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          _editorTab(
            icon: Icons.home_work_outlined,
            label: 'Workspace',
            active: !hasActiveFile && _detailItem == null,
            onTap: () => setState(() => _activeFile = -1),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _codeFiles.length,
              itemBuilder: (_, i) {
                final file = _codeFiles[i];
                return _editorTab(
                  icon: file.isDiff
                      ? Icons.difference_rounded
                      : _iconForFile(file.path),
                  label: '${file.dirty ? '● ' : ''}${file.name}',
                  active: i == _activeFile,
                  change: _fileGitChange(file.path),
                  onTap: () => _activateCodeTab(i),
                  onClose: () => _closeCodeFile(i),
                  tabMenu: _editorFileTabMenu(i),
                  onSecondaryTapDown: (d) =>
                      _showEditorTabMenu(d.globalPosition, i),
                );
              },
            ),
          ),
          if (_detailItem != null)
            _editorTab(
              icon: Icons.description_outlined,
              label: title,
              active: !hasActiveFile,
              onTap: () {
                setState(() => _activeFile = -1);
                _setDetailCollapsed(false);
              },
              onClose: () => setState(() => _detailItem = null),
            ),
          if (hasActiveFile) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 17),
              tooltip: 'Back',
              visualDensity: VisualDensity.compact,
              onPressed: _codeBackStack.isEmpty ? null : _navigateBack,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded, size: 17),
              tooltip: 'Forward',
              visualDensity: VisualDensity.compact,
              onPressed: _codeForwardStack.isEmpty ? null : _navigateForward,
            ),
            if (!_codeFiles[_activeFile].isDiff) ...[
              IconButton(
                icon: const Icon(Icons.account_tree_rounded, size: 17),
                tooltip: 'File Structure',
                visualDensity: VisualDensity.compact,
                onPressed: _showFileStructure,
              ),
              IconButton(
                icon: const Icon(Icons.search_rounded, size: 17),
                tooltip: 'Find in File',
                visualDensity: VisualDensity.compact,
                onPressed: _showFindInCurrentFile,
              ),
              _activeFileActionsMenu(_codeFiles[_activeFile]),
              _previewTabButton(),
              _formatTabButton(),
              IconButton(
                icon: const Icon(Icons.save_rounded, size: 17),
                tooltip: '保存',
                visualDensity: VisualDensity.compact,
                onPressed: _codeFiles[_activeFile].dirty
                    ? _codeFiles[_activeFile].key.currentState?.save
                    : null,
              ),
            ],
          ],
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 17),
            tooltip: '刷新',
            visualDensity: VisualDensity.compact,
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
    );
  }

  Widget _editorTab({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
    VoidCallback? onClose,
    PopupMenuButton<String>? tabMenu,
    GestureTapDownCallback? onSecondaryTapDown,
    GitChange? change,
  }) => InkWell(
    onTap: onTap,
    onSecondaryTapDown: onSecondaryTapDown,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 260),
      height: 36,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: active ? CcColors.editor : CcColors.editorTabBar,
        border: Border(
          right: const BorderSide(color: CcColors.border),
          top: BorderSide(
            color: active ? CcColors.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: active ? CcColors.accentBright : CcColors.muted,
          ),
          const SizedBox(width: 7),
          if (change != null) ...[
            Tooltip(
              message: _gitChangeLongLabel(change),
              child: Container(
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _changeColor(change).withValues(alpha: 0.14),
                  border: Border.all(
                    color: _changeColor(change).withValues(alpha: 0.45),
                  ),
                  borderRadius: BorderRadius.circular(CcRadius.pill),
                ),
                child: Text(
                  _gitChangeShortLabel(change),
                  style: CcType.code(
                    size: 9.5,
                    color: _changeColor(change),
                    weight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: active ? CcColors.text : CcColors.muted,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          if (tabMenu != null) ...[const SizedBox(width: 3), tabMenu],
          if (onClose != null) ...[
            const SizedBox(width: 2),
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: CcColors.muted,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  PopupMenuButton<String> _activeFileActionsMenu(_OpenFile file) {
    final mod = _shortcutModLabel();
    return PopupMenuButton<String>(
      tooltip: 'Code Actions',
      icon: const Icon(Icons.bolt_rounded, size: 17),
      padding: EdgeInsets.zero,
      onSelected: (v) {
        if (v == 'structure') _showFileStructure();
        if (v == 'find') _showFindInCurrentFile();
        if (v == 'usages') _showFindUsagesForActiveFile();
        if (v == 'reveal') _revealFileInProject(file.path);
        if (v == 'copyPath') _copyFilePath(file.path);
        if (v == 'workingDiff') _openActiveFileWorkingTreeDiff();
        if (v == 'compareHead') _compareActiveFileWithHead();
        if (v == 'fileLog') _openActiveFileGitLog();
        if (v == 'history') _showFileHistoryForActiveFile();
        if (v == 'annotate') _showBlameForActiveFile();
        if (v == 'save') _saveActiveFile();
        if (v == 'close') _closeActiveCodeFile();
        if (v == 'closeOthers') _closeOtherCodeFiles(_activeFile);
        if (v == 'closeUnmodified') _closeUnmodifiedCodeFiles();
      },
      itemBuilder: (_) => [
        ccMenuItem(
          value: 'structure',
          icon: Icons.account_tree_rounded,
          label: 'File Structure',
          shortcut: '$mod+F12',
        ),
        ccMenuItem(
          value: 'find',
          icon: Icons.search_rounded,
          label: 'Find in File',
          shortcut: '$mod+F',
        ),
        ccMenuItem(
          value: 'usages',
          icon: Icons.travel_explore_rounded,
          label: 'Find Usages',
          shortcut: '$mod+Alt+F7',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'workingDiff',
          icon: Icons.difference_rounded,
          label: 'Working Tree Diff',
          shortcut: '$mod+Alt+D',
        ),
        ccMenuItem(
          value: 'compareHead',
          icon: Icons.compare_arrows_rounded,
          label: 'Compare with HEAD',
          shortcut: '$mod+Shift+D',
        ),
        ccMenuItem(
          value: 'fileLog',
          icon: Icons.manage_history_rounded,
          label: 'Open File Git Log',
          shortcut: '$mod+Alt+H',
        ),
        ccMenuItem(
          value: 'history',
          icon: Icons.history_rounded,
          label: 'File History',
        ),
        ccMenuItem(
          value: 'annotate',
          icon: Icons.person_search_rounded,
          label: 'Annotate / Blame',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'reveal',
          icon: Icons.my_location_rounded,
          label: 'Reveal in Project',
          shortcut: '$mod+Shift+1',
        ),
        ccMenuItem(
          value: 'copyPath',
          icon: Icons.copy_rounded,
          label: 'Copy Path',
        ),
        ccMenuItem(
          value: 'save',
          icon: Icons.save_rounded,
          label: 'Save',
          shortcut: '$mod+S',
          enabled: file.dirty,
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'close',
          icon: Icons.close_rounded,
          label: 'Close',
          shortcut: '$mod+W',
        ),
        ccMenuItem(
          value: 'closeOthers',
          icon: Icons.filter_none_rounded,
          label: 'Close Others',
          enabled: _codeFiles.length > 1,
        ),
        ccMenuItem(
          value: 'closeUnmodified',
          icon: Icons.rule_rounded,
          label: 'Close Unmodified',
        ),
      ],
    );
  }

  // 文件标签页右键/⋮菜单共用的 item 列表 + 派发逻辑，两个触发方式(showMenu 右键、
  // PopupMenuButton 左键小图标)都喂同一份，不在两处各写一份。closeOthers/Left/Right
  // 的 enabled/显示条件按 [index] 所在 pane 的范围算（未分屏时 scope 就是全部文件，
  // 跟以前完全一样），保证菜单里"能不能点/有没有这一行"跟 _closeOtherCodeFiles 等
  // 实际生效范围一致。
  List<PopupMenuEntry<String>> _editorFileTabMenuItems(int index) {
    final scope = index >= 0 && index < _codeFiles.length
        ? _paneFileIndices(_paneOfPath(_codeFiles[index].path))
        : const <int>[];
    final pos = scope.indexOf(index);
    return [
      ccMenuItem(
        value: 'copyPath',
        icon: Icons.content_copy_rounded,
        label: 'Copy Path',
      ),
      ccMenuItem(
        value: 'reveal',
        icon: Icons.my_location_rounded,
        label: 'Reveal in Project',
      ),
      const PopupMenuDivider(),
      ccMenuItem(
        value: 'workingDiff',
        icon: Icons.difference_rounded,
        label: 'Open File Working Tree Diff',
      ),
      ccMenuItem(
        value: 'fileLog',
        icon: Icons.list_alt_rounded,
        label: 'Open File Git Log',
      ),
      ccMenuItem(
        value: 'history',
        icon: Icons.history_rounded,
        label: 'File History',
      ),
      ccMenuItem(
        value: 'annotate',
        icon: Icons.format_align_left_rounded,
        label: 'Annotate / Blame',
      ),
      const PopupMenuDivider(),
      ccMenuItem(
        value: 'splitRight',
        icon: Icons.vertical_split_rounded,
        label: '向右分屏',
      ),
      ccMenuItem(
        value: 'splitDown',
        icon: Icons.horizontal_split_rounded,
        label: '向下分屏',
      ),
      const PopupMenuDivider(),
      ccMenuItem(value: 'close', icon: Icons.close_rounded, label: 'Close'),
      ccMenuItem(
        value: 'closeOthers',
        icon: Icons.clear_rounded,
        label: 'Close Others',
        enabled: scope.length > 1,
      ),
      if (pos > 0)
        ccMenuItem(
          value: 'closeLeft',
          icon: Icons.first_page_rounded,
          label: 'Close Tabs to the Left',
        ),
      if (pos >= 0 && pos < scope.length - 1)
        ccMenuItem(
          value: 'closeRight',
          icon: Icons.keyboard_tab_rounded,
          label: 'Close Tabs to the Right',
        ),
      ccMenuItem(
        value: 'closeUnmodified',
        icon: Icons.cleaning_services_rounded,
        label: 'Close Unmodified',
      ),
      ccMenuItem(
        value: 'closeAll',
        icon: Icons.clear_all_rounded,
        label: 'Close All',
      ),
    ];
  }

  void _handleEditorFileTabMenuSelect(String v, int index) {
    if (index < 0 || index >= _codeFiles.length) return;
    final file = _codeFiles[index];
    if (v == 'copyPath') _copyFilePath(file.path);
    if (v == 'reveal') _revealFileInProject(file.path);
    if (v == 'workingDiff') _openFileWorkingTreeDiff(file.path);
    if (v == 'fileLog') _openFileGitLog(file.path);
    if (v == 'history') {
      final hit = _projectForFile(file.path);
      if (hit == null || hit.rel.isEmpty) {
        _snack('找不到文件所属项目');
      } else {
        _showFileHistoryForProjectFile(hit.project, hit.rel);
      }
    }
    if (v == 'annotate') {
      final hit = _projectForFile(file.path);
      if (hit == null || hit.rel.isEmpty) {
        _snack('找不到文件所属项目');
      } else {
        _showBlameForProjectFile(hit.project, hit.rel);
      }
    }
    if (v == 'splitRight') _splitEditorPane(index, SplitAxis.horizontal);
    if (v == 'splitDown') _splitEditorPane(index, SplitAxis.vertical);
    if (v == 'close') _closeCodeFile(index);
    if (v == 'closeOthers') _closeOtherCodeFiles(index);
    if (v == 'closeLeft') _closeCodeFilesToLeft(index);
    if (v == 'closeRight') _closeCodeFilesToRight(index);
    if (v == 'closeUnmodified') _closeUnmodifiedCodeFiles();
    if (v == 'closeAll') _closeAllCodeFiles();
  }

  // 右键在光标处弹出，跟 commit_changes_menu.dart 的 showMenu+menuPosAt 同一套路。
  Future<void> _showEditorTabMenu(Offset pos, int index) async {
    setState(() => _activateMenuTarget(index));
    final v = await showMenu<String>(
      context: context,
      position: menuPosAt(context, pos),
      items: _editorFileTabMenuItems(index),
    );
    if (v == null || !mounted) return;
    _handleEditorFileTabMenuSelect(v, index);
  }

  // ⋮ 图标左键触发，跟右键共用同一份 item 列表 + 派发逻辑。
  PopupMenuButton<String> _editorFileTabMenu(int index) {
    return PopupMenuButton<String>(
      tooltip: 'Tab actions',
      icon: const Icon(Icons.more_vert_rounded, size: 15),
      padding: EdgeInsets.zero,
      onOpened: () => setState(() => _activateMenuTarget(index)),
      onSelected: (v) => _handleEditorFileTabMenuSelect(v, index),
      itemBuilder: (_) => _editorFileTabMenuItems(index),
    );
  }

  // 编辑区没开文件、且当前底部工具是终端并有会话时，AI 终端占满编辑区（专注对话）。
  bool get _aiChatFocused =>
      (_activeFile < 0 || _activeFile >= _codeFiles.length) &&
      hasVisibleTab &&
      _bottomTool == _BottomTool.terminal;

  Widget _editorCanvas() {
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    if (hasActiveFile) return _editorCanvasFor(_codeFiles[_activeFile]);
    if (_aiChatFocused) {
      return terminalDeck(
        hideClosedTabs: true,
        enableSplit: true,
        onNewShell: _newShellTerminal,
      );
    }
    return _workspaceWelcome();
  }

  // Parameterized so a split pane's own canvas can render that pane's active
  // file. [f] == null (an emptied-out pane, transient before it collapses)
  // falls back to the welcome screen — never the AI-chat terminal fallback,
  // which stays exclusive to the unsplit _editorCanvas() path above.
  Widget _editorCanvasFor(_OpenFile? f) {
    if (f != null) {
      if (f.isDiff) {
        return ColoredBox(
          color: CcColors.bg,
          child: DiffView(
            key: ValueKey(f.path),
            files: f.diffs!,
            initialPath: f.diffInitialPath,
            showTree: f.diffShowTree,
            onReloadContext: f.diffReload,
          ),
        );
      }
      // Listener (not GestureDetector) so the right-click reaches us even though
      // re_editor handles pointers itself — lets you forward a code selection to
      // a session. onPointerDown reads the selection synchronously, before the
      // editor can clear it.
      return Listener(
        onPointerDown: (e) {
          if (e.buttons == kSecondaryButton) {
            _showEditorSendMenu(e.position);
            return;
          }
          // Cmd/Ctrl + left-click = go to definition. re_editor's own inner
          // pointer handler (deeper in the hit-test path) has already moved the
          // caret to the click point; defer to a microtask so we read the settled
          // caret regardless of handler order, then resolve the identifier under it.
          if (e.buttons == kPrimaryButton &&
              (HardwareKeyboard.instance.isMetaPressed ||
                  HardwareKeyboard.instance.isControlPressed)) {
            scheduleMicrotask(_goToDefinition);
          }
        },
        child: PreviewableEditor(
          path: f.path,
          editorKey: f.key,
          initialLine: f.line,
          previewMode: f.previewMode,
          onDirtyChanged: (v) {
            if (!mounted) return;
            setState(() => f.dirty = v);
          },
          onLoaded: () {
            if (!mounted) return;
            setState(() {});
          },
        ),
      );
    }
    return _workspaceWelcome();
  }

  IconData _iconForFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'go' => Icons.data_object_rounded,
      'dart' || 'ts' || 'tsx' || 'js' || 'jsx' => Icons.code_rounded,
      'md' || 'markdown' => Icons.article_outlined,
      'json' || 'yaml' || 'yml' || 'toml' => Icons.tune_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  Widget _workspaceWelcome() {
    final ws =
        _cfg.workspaces.isNotEmpty && _cfg.workspaces.first.name.isNotEmpty
        ? _cfg.workspaces.first.name
        : 'workspace';
    final taskCount = _tasksByRepo.values.fold<int>(
      0,
      (sum, items) => sum + items.length,
    );
    return DecoratedBox(
      decoration: appGradient,
      // Scroll when the canvas is too short for the content; otherwise the
      // min-height keeps it vertically centered as before.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: CcColors.panelHigh,
                              border: Border.all(color: CcColors.borderSoft),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.terminal_rounded,
                              color: CcColors.accentBright,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  ws,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  'Project tool window · Terminal · Handoff',
                                  style: CcType.code(
                                    size: 12,
                                    color: CcColors.subtle,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _welcomeAction(
                            'New Workspace',
                            Icons.add_rounded,
                            _busy ? null : _newWorkspace,
                          ),
                          _welcomeAction(
                            'Refresh',
                            Icons.refresh_rounded,
                            _busy ? null : _refresh,
                          ),
                          _welcomeAction(
                            'Open Project',
                            Icons.account_tree_outlined,
                            // With nothing configured yet, revealing the tree
                            // sidebar just shows a one-line "no workspace"
                            // hint — indistinguishable from "the button did
                            // nothing" to a first-time user expecting a
                            // folder picker (like every other "Open
                            // Project"). Go straight to the same
                            // pick-a-folder-and-import flow the sidebar's
                            // import icon already uses; once at least one
                            // workspace exists, fall back to just focusing
                            // the (now non-empty, actually useful) sidebar.
                            _busy
                                ? null
                                : (_cfg.workspaces.isEmpty
                                      ? _importWorkspace
                                      : () => _openLeftTool(
                                          _LeftToolView.project,
                                        )),
                          ),
                          _welcomeAction(
                            'Show Terminal',
                            Icons.terminal_rounded,
                            () => _setTerminalCollapsed(false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          _metric('tasks', '$taskCount', CcColors.warning),
                          const SizedBox(width: 10),
                          _metric('sessions', '${terms.length}', CcColors.ok),
                          const SizedBox(width: 10),
                          _metric(
                            'workspaces',
                            '${_cfg.workspaces.length}',
                            CcColors.accent,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _welcomeAction(String label, IconData icon, VoidCallback? onTap) =>
      OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
        ),
      );

  Widget _metric(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: CcColors.panel,
      border: Border.all(color: CcColors.border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        statusDot(color, size: 7, glow: true),
        const SizedBox(width: 7),
        Text(value, style: CcType.code(size: 12.5, color: CcColors.text)),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(color: CcColors.muted, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _horizontalResizeHandle(double maxTerm) => MouseRegion(
    cursor: SystemMouseCursors.resizeRow,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (d) {
        setState(() {
          // Upper bound is the space actually available (not a fixed 620), so
          // dragging can't push the panel past the viewport and overflow.
          _terminalHeight = (_terminalHeight - d.delta.dy).clamp(
            120.0,
            maxTerm,
          );
        });
      },
      onVerticalDragEnd: (_) =>
          Prefs.setDouble('ws.terminalHeight', _terminalHeight),
      child: Container(
        height: 7,
        color: CcColors.bg,
        alignment: Alignment.center,
        child: Container(height: 1, color: CcColors.border),
      ),
    ),
  );

  Widget _bottomStripe() {
    final p = _currentGitProject;
    final status = _gitStatus;
    return Container(
      height: 28,
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(top: BorderSide(color: CcColors.border)),
      ),
      child: scrollableBar(
        scrolling: [
          _statusBarToolSegment(
            icon: Icons.terminal_rounded,
            label: 'Terminal',
            detail: '${terms.length}',
            selected:
                !_terminalCollapsed && _bottomTool == _BottomTool.terminal,
            onTap: () => _setBottomTool(_BottomTool.terminal),
          ),
          _statusBarToolSegment(
            icon: Icons.alt_route_rounded,
            label: 'Commit',
            detail: status == null ? '' : _gitDirtyLabel(status),
            selected: !_terminalCollapsed && _bottomTool == _BottomTool.git,
            color: status == null || status.clean
                ? CcColors.muted
                : CcColors.warning,
            onTap: () => _openGitView(_GitView.changes),
          ),
        ],
        pinnedTrailing: [
          if (p != null) ...[
            _statusGitBranchSegment(status, p),
            _statusSyncSegment(status, p),
            _statusIconAction(
              icon: Icons.sync_rounded,
              tooltip: 'Fetch',
              onTap: _gitLoading ? null : () => _gitFetchCurrent(p),
            ),
            _statusIconAction(
              icon: Icons.call_received_rounded,
              tooltip: 'Pull --ff-only',
              onTap: _gitLoading ? null : () => _gitPullCurrent(p),
            ),
            _statusIconAction(
              icon: Icons.upload_rounded,
              tooltip: 'Push',
              onTap: _gitLoading ? null : () => _gitPushCurrent(p),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusBarToolSegment({
    required IconData icon,
    required String label,
    required String detail,
    required bool selected,
    required VoidCallback onTap,
    Color? color,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: selected ? CcColors.editorTabBar : Colors.transparent,
        border: const Border(right: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color ?? CcColors.muted),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: selected ? CcColors.text : CcColors.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 10.8, color: CcColors.subtle),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _statusGitBranchSegment(GitStatusSummary? status, ProjectCfg p) {
    final branch = status?.branch ?? p.name;
    return InkWell(
      onTap: _gitLoading ? null : () => _showBranchDialog(),
      onSecondaryTap: () => _openGitView(_GitView.log),
      child: Tooltip(
        message: 'Branches 弹窗 · 右键打开底部 Git Log',
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.account_tree_rounded,
                size: 14,
                color: CcColors.accentBright,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  branch,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(
                    size: 11.2,
                    color: CcColors.text,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              const Icon(Icons.arrow_drop_down_rounded, size: 15),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusSyncSegment(GitStatusSummary? status, ProjectCfg p) {
    if (status == null) return const SizedBox.shrink();
    final dirty = status.staged + status.modified + status.untracked;
    final hasSync = status.ahead > 0 || status.behind > 0;
    final hasConflicts = status.conflicted > 0;
    if (dirty == 0 && !hasSync && !hasConflicts) {
      return _statusTextAction(
        icon: Icons.check_circle_rounded,
        label: 'clean',
        color: CcColors.ok,
        tooltip: 'Working tree clean · Open Git Log',
        onTap: () => _openGitView(_GitView.log),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dirty > 0 || hasConflicts)
          _statusTextAction(
            icon: hasConflicts
                ? Icons.report_problem_rounded
                : Icons.edit_note_rounded,
            label: hasConflicts
                ? '${status.conflicted} conflicts'
                : '$dirty changes',
            color: hasConflicts ? CcColors.danger : CcColors.warning,
            tooltip: 'Open Commit changes',
            onTap: () => _openGitView(_GitView.changes),
          ),
        if (status.ahead > 0)
          _statusTextAction(
            icon: Icons.north_rounded,
            label: '${status.ahead}',
            color: CcColors.warning,
            tooltip: 'Push ${status.ahead} outgoing commit(s)',
            onTap: _gitLoading ? null : () => _gitPushCurrent(p),
          ),
        if (status.behind > 0)
          _statusTextAction(
            icon: Icons.south_rounded,
            label: '${status.behind}',
            color: CcColors.accentBright,
            tooltip: 'Pull ${status.behind} incoming commit(s)',
            onTap: _gitLoading ? null : () => _gitPullCurrent(p),
          ),
      ],
    );
  }

  Widget _statusTextAction({
    required IconData icon,
    required String label,
    required Color color,
    required String tooltip,
    required VoidCallback? onTap,
  }) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: CcType.code(
                size: 10.8,
                color: color,
                weight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _statusIconAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Icon(
          icon,
          size: 14,
          color: onTap == null ? CcColors.subtle : CcColors.muted,
        ),
      ),
    ),
  );

  String _gitDirtyLabel(GitStatusSummary status) {
    if (status.clean) return 'clean';
    final total =
        status.staged + status.modified + status.untracked + status.conflicted;
    return '$total changes';
  }

  // _panelHeader is the shared tool-window header chrome.
  // _panelHeader is the standard 34px panel title bar. [leading] (title/tabs)
  // scrolls horizontally when the panel is too narrow to fit it; [trailing]
  // (action icons) stays pinned at the right and never scrolls — so the header
  // can never overflow (the yellow/black hazard stripe). Keep [leading] free of
  // Expanded/Spacer (unbounded width inside the scroll would throw).
  Widget _panelHeader({
    required EdgeInsetsGeometry padding,
    bool gradient = false,
    double height = 34,
    required List<Widget> leading,
    List<Widget> trailing = const [],
  }) => Container(
    height: height,
    padding: padding,
    decoration: BoxDecoration(
      color: gradient ? null : CcColors.panel,
      gradient: gradient ? panelGradient.gradient : null,
      border: const Border(bottom: BorderSide(color: CcColors.border)),
    ),
    child: scrollableBar(scrolling: leading, pinnedTrailing: trailing),
  );

  // _detailPanel hosts a task's 对接文档 inside the right tool window.
  Widget _detailPanel(ListItem it) => Column(
    children: [
      _panelHeader(
        padding: const EdgeInsets.only(left: 10, right: 4),
        leading: const [
          Icon(Icons.description_outlined, size: 16, color: CcColors.muted),
          SizedBox(width: 8),
          Text(
            'Handoff',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
        ],
        trailing: [
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded, size: 17),
            tooltip: '收起',
            visualDensity: VisualDensity.compact,
            onPressed: () => _setDetailCollapsed(true),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 17),
            tooltip: '关闭文档',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _detailItem = null),
          ),
        ],
      ),
      Expanded(
        child: HandoffDetailView(
          client: widget.client!,
          config: _cfg,
          me: widget.me,
          item: it,
          onOpenTerminal: (wt, cmd) {
            addTerm(wt, cmd);
            _setTerminalCollapsed(false);
          },
          onSendToTerminal: sendToTerminal,
          onChanged: _loadTasks,
        ),
      ),
    ],
  );

  // _todosSidebarPanel hosts a 待办 list (list ↔ detail swap in place via
  // _todosSidebarSelected, no Navigator) inside the right tool window — lets
  // the user triage todos without leaving the workspace. Mutually exclusive
  // with _detailPanel (see _setTodosSidebarCollapsed/_setDetailCollapsed).
  Widget _todosSidebarPanel() {
    final sel = _todosSidebarSelected;
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          leading: [
            if (sel != null)
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, size: 17),
                tooltip: '返回列表',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _todosSidebarSelected = null),
              )
            else
              const Icon(
                Icons.checklist_rounded,
                size: 16,
                color: CcColors.muted,
              ),
            const SizedBox(width: 8),
            Text(
              sel == null ? '待办' : '待办详情',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          trailing: [
            IconButton(
              icon: const Icon(Icons.more_horiz_rounded, size: 17),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              onPressed: () => _setTodosSidebarCollapsed(true),
            ),
          ],
        ),
        Expanded(
          child: sel == null ? _todosSidebarList() : _todosSidebarDetail(sel),
        ),
      ],
    );
  }

  // _todosSidebarItems: personal todos always show; team todos show when they
  // are bound to this exact workspace/project, or when the current project name
  // resolves to one unambiguous relay project id. Duplicate project names across
  // teams are deliberately not guessed — SaaS teams can share names.
  List<Todo> get _todosSidebarItems {
    if (widget.client == null || widget.me == null) return const [];
    final currentProject = _currentGitProject;
    final currentWorkspaceName = _currentGitWorkspaceName;
    final items = widget.store.all.where((t) {
      return todoInWorkspaceScope(
        t,
        projectRoles: widget.me!.projects,
        workspaceName: currentWorkspaceName,
        projectName: currentProject?.name,
      );
    }).toList();
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return items;
  }

  String? get _currentGitWorkspaceName {
    final current = _currentGitProject;
    if (current == null) return null;
    for (final ws in _cfg.workspaces) {
      for (final p in ws.projects) {
        if (p.path == current.path && p.name == current.name) return ws.name;
      }
    }
    return null;
  }

  String? _todoProjectName(Todo t) {
    if (t.projectId == null) return null;
    for (final p in widget.me?.projects ?? const []) {
      if (p.id == t.projectId) return p.name;
    }
    return null;
  }

  Widget _todosSidebarList() => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final store = widget.store;
      return asyncBody(
        loading: store.loading && store.all.isEmpty,
        error: store.error,
        onRetry: store.refresh,
        child: () {
          final items = _todosSidebarItems;
          if (widget.client == null || widget.me == null) {
            return centerMsg('登录后使用待办');
          }
          if (items.isEmpty) return centerMsg('暂无待办');
          return RefreshIndicator(
            onRefresh: store.refresh,
            child: ListView.separated(
              padding: const EdgeInsets.all(10),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final t = items[i];
                return TodoCard(
                  todo: t,
                  projectName: _todoProjectName(t),
                  onTap: () => setState(() => _todosSidebarSelected = t),
                );
              },
            ),
          );
        },
      );
    },
  );

  Widget _todosSidebarDetail(Todo t) => TodoDetailView(
    client: widget.client!,
    todo: t,
    overviewStore: widget.overviewStore,
    config: _cfg,
    access: widget.me == null ? TodoAccess.none : todoAccessFor(t, widget.me!),
    // No onOpenSession: this panel lives inside WorkspacePage itself, so
    // overviewStore.requestOpen (TodoDetailView's fallback) is already
    // enough — there's no separate top-level tab to switch away from.
    onChanged: (updated) {
      if (mounted) setState(() => _todosSidebarSelected = updated);
    },
    onDeleted: () {
      if (!mounted) return;
      setState(() => _todosSidebarSelected = null);
      widget.store.refresh();
    },
  );

  // _inboxSidebarPanel hosts a flattened Handoff inbox (list ↔ detail swap in
  // place via _inboxSidebarSelected, no Navigator) inside the right tool
  // window — lets the user triage handoffs without leaving the workspace.
  // Mutually exclusive with _detailPanel/_todosSidebarPanel (see
  // _setInboxSidebarCollapsed/_setDetailCollapsed/_setTodosSidebarCollapsed).
  Widget _inboxSidebarPanel() {
    final sel = _inboxSidebarSelected;
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          leading: [
            if (sel != null)
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, size: 17),
                tooltip: '返回列表',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _inboxSidebarSelected = null),
              )
            else
              const Icon(Icons.inbox_rounded, size: 16, color: CcColors.muted),
            const SizedBox(width: 8),
            Text(
              sel == null ? '收件箱' : 'Handoff',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          trailing: [
            IconButton(
              icon: const Icon(Icons.more_horiz_rounded, size: 17),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              onPressed: () => _setInboxSidebarCollapsed(true),
            ),
          ],
        ),
        Expanded(
          child: sel == null ? _inboxSidebarList() : _inboxSidebarDetail(sel),
        ),
      ],
    );
  }

  // _inboxSidebarItems flattens the already-loaded _tasksByRepo (no separate
  // fetch — same data backing the file tree's repo badges) and sorts newest
  // first.
  List<ListItem> get _inboxSidebarItems {
    final items = _tasksByRepo.values.expand((l) => l).toList();
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }

  Widget _inboxSidebarList() {
    final items = _inboxSidebarItems;
    if (items.isEmpty) return centerMsg('收件箱为空');
    return ListView.separated(
      padding: const EdgeInsets.all(10),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final it = items[i];
        return InboxItemCard(
          item: it,
          onTap: () => setState(() => _inboxSidebarSelected = it),
        );
      },
    );
  }

  Widget _inboxSidebarDetail(ListItem it) => HandoffDetailView(
    client: widget.client!,
    config: _cfg,
    me: widget.me,
    item: it,
    onOpenTerminal: (wt, cmd) {
      addTerm(wt, cmd);
      _setTerminalCollapsed(false);
    },
    onSendToTerminal: sendToTerminal,
    onChanged: _loadTasks,
  );

  void _setBottomTool(_BottomTool tool) {
    setState(() {
      _bottomTool = tool;
      _terminalCollapsed = false;
    });
    Prefs.setString(
      'ws.bottomTool',
      tool == _BottomTool.git ? 'git' : 'terminal',
    );
    Prefs.setBool('ws.terminalCollapsed', false);
    if (tool == _BottomTool.git) _refreshGit();
  }

  // Routes a git view to its home: changes/stash operate in the LEFT tool
  // window; log/branches browse in the BOTTOM panel.
  void _openGitView(_GitView view) {
    switch (view) {
      case _GitView.changes:
        _openLeftTool(_LeftToolView.changes);
      case _GitView.stash:
        _openLeftTool(_LeftToolView.stash);
      case _GitView.log:
        _setBottomTool(_BottomTool.git);
    }
  }

  void _openCommitFlow(ProjectCfg project) {
    _selectGitProject(project);
    _openLeftTool(_LeftToolView.changes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _commitFocus.requestFocus();
    });
  }

  Future<void> _showWorkingTreeDiff(ProjectCfg project) async {
    _selectGitProject(project);
    _openGitView(_GitView.changes);
    await _refreshGit();
    if (!mounted) return;
    if (_gitFiles.isEmpty && _gitChanges.isEmpty) {
      _snack('Working tree clean');
      return;
    }
    setState(() => _selectedGitPath = _workingTreeDiffSelection);
  }

  @override
  Future<void> _selectCommit(ProjectCfg p, GitCommit c) async {
    setState(() {
      _selectedCommit = c.hash;
      _compareTitle = null;
      _compareFiles = const [];
      _gitLoading = true;
    });
    try {
      final diff = await gitShowCommit(p.path, c.hash);
      if (!mounted) return;
      setState(() {
        _commitFiles = parseUnifiedDiff(diff);
        _logDiffReload = (ctx) async =>
            parseUnifiedDiff(await gitShowCommit(p.path, c.hash, context: ctx));
        _gitLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  @override
  Future<void> _compareBranch(ProjectCfg p, GitBranch b) async {
    final right = _gitStatus?.branch ?? 'HEAD';
    setState(() {
      _bottomTool = _BottomTool.git;
      _terminalCollapsed = false;
      _compareTitle = '${b.name}...$right';
      _gitLoading = true;
    });
    try {
      final diff = await gitDiffRefs(p.path, b.name, right);
      if (!mounted) return;
      setState(() {
        _compareFiles = parseUnifiedDiff(diff);
        _logDiffReload = (ctx) async => parseUnifiedDiff(
          await gitDiffRefs(p.path, b.name, right, context: ctx),
        );
        _commitFiles = const [];
        _gitLoading = false;
      });
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  @override
  Future<void> _compareCommitWithWorking(ProjectCfg p, GitCommit c) async {
    setState(() {
      _bottomTool = _BottomTool.git;
      _terminalCollapsed = false;
      _selectedCommit = c.hash;
      _compareTitle = '${c.shortHash}..Working Tree';
      _gitLoading = true;
    });
    try {
      final diff = await gitDiffRefToWorking(p.path, c.hash);
      if (!mounted) return;
      setState(() {
        _compareFiles = parseUnifiedDiff(diff);
        _logDiffReload = (ctx) async => parseUnifiedDiff(
          await gitDiffRefToWorking(p.path, c.hash, context: ctx),
        );
        _commitFiles = const [];
        _gitLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  @override
  void _copyCommitHash(GitCommit c) {
    Clipboard.setData(ClipboardData(text: c.hash));
    _snack('已复制 ${c.shortHash}');
  }

  @override
  Future<void> _createBranchFromCommit(ProjectCfg p, GitCommit c) async {
    final safeSubject = c.subject
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final initialBranch = safeSubject.isEmpty
        ? 'branch-${c.shortHash}'
        : '${safeSubject.length > 32 ? safeSubject.substring(0, 32) : safeSubject}-${c.shortHash}';
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => WorkspaceCommitBranchDialog(
        initialBranch: initialBranch,
        shortHash: c.shortHash,
        subject: c.subject,
      ),
    );
    if (raw == null) return;
    final branch = raw.trim();
    if (branch.isEmpty) {
      _snack('分支名不能为空');
      return;
    }
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitCreateBranch(p.path, branch, start: c.hash);
      await _refreshGit();
      _snack('已从 ${c.shortHash} 创建分支');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  @override
  Future<void> _cherryPickCommit(ProjectCfg p, GitCommit c) async {
    final ok = await _confirm(
      'Cherry-pick commit?',
      '${c.shortHash} · ${c.subject}\n\n这会把该提交应用到当前分支。',
    );
    if (!ok) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitCherryPick(p.path, c.hash);
      await _refreshGit();
      _snack('Cherry-pick 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  @override
  Future<void> _revertCommit(ProjectCfg p, GitCommit c) async {
    final ok = await _confirm(
      'Revert commit?',
      '${c.shortHash} · ${c.subject}\n\n这会创建一个反向提交。',
    );
    if (!ok) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitRevertCommit(p.path, c.hash);
      await _refreshGit();
      _snack('Revert 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _selectStash(ProjectCfg p, GitStash s) async {
    setState(() {
      _selectedStash = s.ref;
      _gitLoading = true;
    });
    try {
      final diff = await gitStashShow(p.path, s.ref);
      if (!mounted) return;
      setState(() => _gitLoading = false);
      final files = parseUnifiedDiff(diff);
      if (files.isNotEmpty) {
        _openDiffTab(
          files,
          'Stash · ${s.ref}',
          reload: (ctx) async =>
              parseUnifiedDiff(await gitStashShow(p.path, s.ref, context: ctx)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Widget _terminalToolWindow() {
    if (_bottomTool == _BottomTool.git) return _gitToolWindow();
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          leading: [
            _bottomTab(
              icon: Icons.terminal_rounded,
              label: 'Terminal',
              selected: true,
              onTap: () => _setBottomTool(_BottomTool.terminal),
            ),
            _bottomTab(
              icon: Icons.alt_route_rounded,
              label: 'Git',
              selected: false,
              onTap: () => _setBottomTool(_BottomTool.git),
            ),
            const SizedBox(width: 10),
            Text(
              '${terms.length}',
              style: CcType.code(size: 11.5, color: CcColors.subtle),
            ),
          ],
          trailing: [
            IconButton(
              icon: const Icon(Icons.add_rounded, size: 18),
              tooltip: '新建终端（普通 shell）',
              visualDensity: VisualDensity.compact,
              onPressed: _newShellTerminal,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              tooltip: '收起 Terminal',
              visualDensity: VisualDensity.compact,
              onPressed: () => _setTerminalCollapsed(true),
            ),
          ],
        ),
        Expanded(child: _termArea()),
      ],
    );
  }

  Widget _bottomTab({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(4),
    child: Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: selected
            ? CcColors.accent.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 15,
            color: selected ? CcColors.accentBright : CcColors.muted,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? CcColors.text : CcColors.muted,
            ),
          ),
        ],
      ),
    ),
  );

  // The bottom panel is browse-only: Terminal + commit Log + Branches. All git
  // OPERATE (commit / stage / push / pull) lives in the left tool window.
  // Clicking a commit's file opens its diff as a tab in the center editor.
  Widget _gitToolWindow() {
    final p = _currentGitProject;
    final status = _gitStatus;
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          leading: [
            _bottomTab(
              icon: Icons.terminal_rounded,
              label: 'Terminal',
              selected: false,
              onTap: () => _setBottomTool(_BottomTool.terminal),
            ),
            _bottomTab(
              icon: Icons.history_rounded,
              label: 'Log',
              selected: true,
              onTap: () => _setBottomTool(_BottomTool.git),
            ),
            const SizedBox(width: 10),
            if (p != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _repoSwitcher(p),
                  const SizedBox(width: 8),
                  _branchButton(status?.branch ?? 'branch'),
                  if (status != null &&
                      (status.ahead > 0 || status.behind > 0)) ...[
                    const SizedBox(width: 8),
                    tag('↑${status.ahead} ↓${status.behind}', CcColors.warning),
                  ],
                ],
              )
            else
              const Text('Git'),
          ],
          trailing: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 17),
              tooltip: '刷新 Git',
              visualDensity: VisualDensity.compact,
              onPressed: _refreshGit,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              onPressed: () => _setTerminalCollapsed(true),
            ),
          ],
        ),
        if (_gitLoading) const LinearProgressIndicator(minHeight: 2),
        if (p == null)
          Expanded(child: centerMsg('没有可用项目'))
        else if (_gitError != null)
          Expanded(child: centerMsg(_gitError!, onRetry: _refreshGit))
        else
          Expanded(
            child: Column(
              children: [
                if (_gitOperation != null) _gitOperationBar(p, _gitOperation!),
                Expanded(child: _gitLogView(p)),
              ],
            ),
          ),
      ],
    );
  }

  // The Commit tool window's change list — two JetBrains-style collapsible
  // groups ("Changes N files" for tracked edits, "Unversioned Files N files"
  // for untracked paths), each with its own tristate group checkbox + indented
  // file rows. Repo-level actions (Stage All / Push / Pull / Fetch / Branches)
  // live in _leftGitActionBar above; per-file actions are on the row's ⋮ /
  // right-click menu; a shared toolbar row above both groups carries the
  // contextual Stage/Unstage/Rollback/Stash cluster + the filter funnel.
  Widget _localChangesList(ProjectCfg p) {
    final visible = _filteredGitChanges;
    final tracked = <GitChange>[];
    final untracked = <GitChange>[];
    for (final c in visible) {
      (c.untracked ? untracked : tracked).add(c);
    }
    return DecoratedBox(
      decoration: const BoxDecoration(color: CcColors.panel),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          _changesToolbarRow(p, visible),
          if (tracked.isEmpty && untracked.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 12, 8, 12),
              child: Text(
                _changesFilter == _ChangeFilter.all ? '没有变更' : '没有匹配的变更',
                style: CcType.code(size: 11.5, color: CcColors.subtle),
              ),
            )
          else ...[
            ..._changesGroup(
              p: p,
              title: 'Changes',
              items: tracked,
              collapsed: _changesTreeCollapsed,
              onToggleCollapse: () => setState(
                () => _changesTreeCollapsed = !_changesTreeCollapsed,
              ),
            ),
            ..._changesGroup(
              p: p,
              title: 'Unversioned Files',
              items: untracked,
              collapsed: _untrackedTreeCollapsed,
              onToggleCollapse: () => setState(
                () => _untrackedTreeCollapsed = !_untrackedTreeCollapsed,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // _changesGroup renders one collapsible tree group (its header + indented
  // file rows), or nothing when [items] is empty — shared by the "Changes"
  // and "Unversioned Files" call sites in _localChangesList so the two don't
  // drift as separate copy-pasted blocks.
  List<Widget> _changesGroup({
    required ProjectCfg p,
    required String title,
    required List<GitChange> items,
    required bool collapsed,
    required VoidCallback onToggleCollapse,
  }) {
    if (items.isEmpty) return const [];
    return [
      _changesGroupHeader(
        title: title,
        items: items,
        collapsed: collapsed,
        onToggleCollapse: onToggleCollapse,
      ),
      if (!collapsed)
        for (final c in items) _changeTile(p, c),
    ];
  }

  // _changesToolBtn is one compact icon action (Stage / Unstage / Rollback /
  // Stash the checked rows) shown in the toolbar row when a selection exists.
  // Icon-only + tooltip; greys out when [onTap] is null.
  Widget _changesToolBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool danger = false,
  }) => IconButton(
    icon: Icon(icon, size: 16),
    tooltip: tooltip,
    onPressed: onTap,
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    color: onTap == null ? null : (danger ? CcColors.danger : CcColors.muted),
  );

  // _changesToolbarRow sits above both tree groups: a contextual
  // Stage/Unstage/Rollback/Stash cluster appears while a selection exists
  // (counts span the full change set, like before the split), and the funnel
  // filters by kind. Chevron/checkbox/title moved down into each group's own
  // _changesGroupHeader.
  Widget _changesToolbarRow(ProjectCfg p, List<GitChange> visible) {
    final someSel = visible.any((c) => _selectedChangePaths.contains(c.path));
    final stageable = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && c.unstaged)
        .length;
    final unstageable = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && c.staged)
        .length;
    final rollbackable = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && !c.conflicted)
        .length;
    return Container(
      height: 28,
      color: CcColors.editorTabBar,
      padding: const EdgeInsets.only(left: 4, right: 4),
      child: Row(
        children: [
          const Spacer(),
          if (someSel) ...[
            _changesToolBtn(
              icon: Icons.add_rounded,
              tooltip: 'Stage 选中',
              onTap: _gitLoading || stageable == 0
                  ? null
                  : () => _gitStageSelectedCurrent(p),
            ),
            _changesToolBtn(
              icon: Icons.remove_rounded,
              tooltip: 'Unstage 选中',
              onTap: _gitLoading || unstageable == 0
                  ? null
                  : () => _gitUnstageSelectedCurrent(p),
            ),
            _changesToolBtn(
              icon: Icons.inventory_2_outlined,
              tooltip: 'Stash 选中',
              onTap: _gitLoading || rollbackable == 0
                  ? null
                  : () => _stashSelectedCurrent(p),
            ),
            _changesToolBtn(
              icon: Icons.undo_rounded,
              tooltip: 'Rollback 选中',
              danger: true,
              onTap: _gitLoading || rollbackable == 0
                  ? null
                  : () => _gitDiscardSelectedCurrent(p),
            ),
            Container(
              width: 1,
              height: 15,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              color: CcColors.border,
            ),
          ],
          _changesFilterButton(),
        ],
      ),
    );
  }

  // _changesGroupHeader is one "▾ ☐ <title>  N files" tree-root row: the
  // chevron collapses that group's rows, the tristate checkbox selects/clears
  // every row in [items] (which drives "Commit Selected") — mirrors the
  // JetBrains "Changes" / "Unversioned Files" section headers. [items] is
  // always non-empty — the only caller, _changesGroup, filters empty groups
  // out before reaching here.
  Widget _changesGroupHeader({
    required String title,
    required List<GitChange> items,
    required bool collapsed,
    required VoidCallback onToggleCollapse,
  }) {
    final allSel = items.every((c) => _selectedChangePaths.contains(c.path));
    final someSel = items.any((c) => _selectedChangePaths.contains(c.path));
    return Container(
      height: 28,
      color: CcColors.editorTabBar,
      padding: const EdgeInsets.only(left: 4, right: 4),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(CcRadius.sm),
            onTap: onToggleCollapse,
            child: Icon(
              collapsed
                  ? Icons.chevron_right_rounded
                  : Icons.expand_more_rounded,
              size: 18,
              color: CcColors.muted,
            ),
          ),
          SizedBox(
            width: 22,
            height: 22,
            child: Checkbox(
              tristate: true,
              value: allSel ? true : (someSel ? null : false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (_) => setState(() {
                if (allSel) {
                  _selectedChangePaths.removeAll(items.map((c) => c.path));
                } else {
                  _selectedChangePaths.addAll(items.map((c) => c.path));
                }
              }),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            title,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 6),
          Text(
            '${items.length} files',
            style: CcType.code(size: 11, color: CcColors.subtle),
          ),
        ],
      ),
    );
  }

  // _changesFilterButton is the tree header's funnel: a popup that filters the
  // change list by kind (All / Staged / Unstaged / Untracked / Conflicts, each
  // with a live count). Tinted when a non-"All" filter is active.
  Widget _changesFilterButton() {
    int countOf(_ChangeFilter f) => _gitChanges
        .where(
          (c) => switch (f) {
            _ChangeFilter.all => true,
            _ChangeFilter.staged => c.staged && !c.conflicted,
            _ChangeFilter.unstaged =>
              c.unstaged && !c.untracked && !c.conflicted,
            _ChangeFilter.untracked => c.untracked,
            _ChangeFilter.conflicts => c.conflicted,
          },
        )
        .length;
    const labels = {
      _ChangeFilter.all: 'All',
      _ChangeFilter.staged: 'Staged',
      _ChangeFilter.unstaged: 'Unstaged',
      _ChangeFilter.untracked: 'Untracked',
      _ChangeFilter.conflicts: 'Conflicts',
    };
    return Builder(
      builder: (ctx) => IconButton(
        icon: Icon(
          Icons.filter_list_rounded,
          size: 16,
          color: _changesFilter != _ChangeFilter.all
              ? CcColors.accentBright
              : CcColors.muted,
        ),
        tooltip: '过滤变更',
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        onPressed: () async {
          final box = ctx.findRenderObject() as RenderBox;
          final pos = box.localToGlobal(box.size.bottomLeft(Offset.zero));
          final v = await showMenu<_ChangeFilter>(
            context: context,
            position: menuPosAt(context, pos),
            items: [
              for (final e in labels.entries)
                PopupMenuItem<_ChangeFilter>(
                  value: e.key,
                  height: 34,
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: _changesFilter == e.key
                            ? CcColors.accentBright
                            : Colors.transparent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          e.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${countOf(e.key)}',
                        style: CcType.code(size: 11, color: CcColors.subtle),
                      ),
                    ],
                  ),
                ),
            ],
          );
          if (v != null && mounted) setState(() => _changesFilter = v);
        },
      ),
    );
  }

  // _fileTypeIcon picks a small glyph for a path by extension, matching the
  // JetBrains change-tree rows (data braces for json/yaml, code for source, …).
  IconData _fileTypeIcon(String path) {
    final name = path.split('/').last.toLowerCase();
    final ext = name.contains('.') ? name.split('.').last : '';
    return switch (ext) {
      'json' || 'yaml' || 'yml' => Icons.data_object_rounded,
      'dart' ||
      'go' ||
      'js' ||
      'ts' ||
      'tsx' ||
      'jsx' ||
      'py' ||
      'java' ||
      'kt' ||
      'swift' ||
      'c' ||
      'cc' ||
      'cpp' ||
      'h' ||
      'rs' => Icons.code_rounded,
      'md' || 'txt' || 'plist' || 'xml' || 'html' => Icons.description_outlined,
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'svg' ||
      'webp' => Icons.image_outlined,
      'gradle' ||
      'lock' ||
      'toml' ||
      'ini' ||
      'cfg' ||
      'properties' => Icons.settings_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  List<GitChange> get _filteredGitChanges {
    final q = _changesQuery.trim().toLowerCase();
    return _gitChanges.where((c) {
      final matchesKind = switch (_changesFilter) {
        _ChangeFilter.all => true,
        _ChangeFilter.staged => c.staged && !c.conflicted,
        _ChangeFilter.unstaged => c.unstaged && !c.untracked && !c.conflicted,
        _ChangeFilter.untracked => c.untracked,
        _ChangeFilter.conflicts => c.conflicted,
      };
      if (!matchesKind) return false;
      if (q.isEmpty) return true;
      return c.path.toLowerCase().contains(q) ||
          (c.oldPath ?? '').toLowerCase().contains(q) ||
          c.status.toLowerCase().contains(q) ||
          (c.staged ? 'staged' : '').contains(q) ||
          (c.unstaged ? 'unstaged modified' : '').contains(q) ||
          (c.untracked ? 'untracked new' : '').contains(q) ||
          (c.conflicted ? 'conflict conflicted' : '').contains(q);
    }).toList();
  }

  Widget _changeTile(ProjectCfg p, GitChange c) {
    final sel = c.path == _selectedGitPath;
    final checked = _selectedChangePaths.contains(c.path);
    final changeColor = _changeColor(c);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Right-click anywhere on the row opens the same JetBrains-style menu as ⋮.
      onSecondaryTapDown: (d) => _showCommitFileMenu(d.globalPosition, p, c),
      child: Container(
        // Full-width selection highlight for the focused row + a left accent
        // rail, like the JetBrains change tree.
        decoration: BoxDecoration(
          color: sel
              ? CcColors.accent.withValues(alpha: 0.22)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: sel ? CcColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: InkWell(
          onTap: () => _openWorkingTreeDiffTab(c.path),
          onDoubleTap: () => _openCodeFile('${p.path}/${c.path}'),
          child: Padding(
            // Indent as a child of its "Changes" / "Unversioned Files" group.
            padding: const EdgeInsets.only(left: 24, right: 2),
            child: SizedBox(
              height: 26,
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: Transform.scale(
                      scale: 0.8,
                      child: Checkbox(
                        value: checked,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selectedChangePaths.add(c.path);
                          } else {
                            _selectedChangePaths.remove(c.path);
                          }
                        }),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Same per-language file-type glyphs as the project file
                  // tree (file_icons.dart), like the JetBrains change tree.
                  fileSvg(fileIconAsset(pathBaseName(c.path)), size: 15),
                  const SizedBox(width: 7),
                  // Filename coloured by change kind + a small grey directory.
                  Expanded(
                    child: fileNameDirLabel(c.path, nameColor: changeColor),
                  ),
                  const SizedBox(width: 4),
                  Builder(
                    builder: (btnCtx) => IconButton(
                      icon: const Icon(Icons.more_vert_rounded, size: 16),
                      tooltip: '文件操作',
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      onPressed: () {
                        final box = btnCtx.findRenderObject() as RenderBox;
                        final pos = box.localToGlobal(
                          box.size.bottomLeft(Offset.zero),
                        );
                        _showCommitFileMenu(pos, p, c);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Opens a changed file's working-tree diff as a center editor tab (the left
  // panel is too narrow for an inline diff). Untracked files aren't in
  // `git diff HEAD`, so they're shown as a whole-file addition. [newTab] opens a
  // per-file tab showing only this file's diff (the menu's "Show Diff in a New
  // Tab"), instead of the shared 'Working Tree' tab reused by single-click.
  @override
  Future<void> _openWorkingTreeDiffTab(
    String path, {
    bool newTab = false,
  }) async {
    setState(() => _selectedGitPath = path);
    final p = _currentGitProject;
    if (newTab && p != null && _gitFiles.any((f) => f.path == path)) {
      _openDiffTab(
        _gitFiles.where((f) => f.path == path).toList(),
        'Diff · ${path.split('/').last}',
        initialPath: path,
        showTree: false,
        reload: (ctx) async => parseUnifiedDiff(
          await gitDiffFileWorking(p.path, path, context: ctx),
        ),
      );
      return;
    }
    if (_gitFiles.any((f) => f.path == path)) {
      _openDiffTab(
        _gitFiles,
        'Working Tree',
        initialPath: path,
        showTree: false,
        reload: p == null
            ? null
            : (ctx) async =>
                  parseUnifiedDiff(await gitDiffWorking(p.path, context: ctx)),
      );
      return;
    }
    if (p == null) return;
    try {
      final files = parseUnifiedDiff(await gitDiffUntracked(p.path, path));
      if (!mounted) return;
      if (files.isEmpty) {
        _openCodeFile('${p.path}/$path'); // binary/empty — fall back to source
        return;
      }
      _openDiffTab(
        files,
        'Working Tree · ${path.split('/').last}',
        initialPath: files.first.path,
        showTree: false,
        reload: (ctx) async => parseUnifiedDiff(
          await gitDiffUntracked(p.path, path, context: ctx),
        ),
      );
    } catch (e) {
      if (mounted) _snack(errorText(e));
    }
  }

  Color _changeColor(GitChange c) {
    if (c.conflicted) return CcColors.danger;
    if (c.untracked) return CcColors.accentBright;
    if (c.staged) return CcColors.ok;
    return CcColors.warning;
  }

  GitChange? _fileGitChange(String path) {
    final hit = _projectForFile(path);
    if (hit == null || hit.rel.isEmpty) return null;
    return _gitChanges
        .where((c) => c.path == hit.rel || c.oldPath == hit.rel)
        .firstOrNull;
  }

  String _gitChangeShortLabel(GitChange c) {
    if (c.conflicted) return '!';
    if (c.untracked) return 'A';
    if (c.staged) return 'S';
    return 'M';
  }

  String _gitChangeLongLabel(GitChange c) {
    if (c.conflicted) return 'conflict ${c.status}';
    if (c.untracked) return 'untracked';
    if (c.staged && c.unstaged) return 'staged + modified';
    if (c.staged) return 'staged ${c.status}';
    return 'modified ${c.status}';
  }

  List<GitCommit> get _filteredGitLog {
    final q = _logQuery.trim().toLowerCase();
    final authors = _gitLog.map((c) => c.author).toSet();
    final effectiveAuthor = authors.contains(_logAuthorFilter)
        ? _logAuthorFilter
        : '';
    return _gitLog.where((c) {
      final matchesQuery =
          q.isEmpty ||
          c.subject.toLowerCase().contains(q) ||
          c.author.toLowerCase().contains(q) ||
          c.hash.toLowerCase().contains(q) ||
          c.shortHash.toLowerCase().contains(q) ||
          c.refs.toLowerCase().contains(q);
      final matchesAuthor =
          effectiveAuthor.isEmpty || c.author == effectiveAuthor;
      return matchesQuery && matchesAuthor;
    }).toList();
  }

  // _repoSwitcher turns the git-panel repo name into a dropdown that switches the
  // active git project/repo (every project across all workspaces).
  Widget _repoSwitcher(ProjectCfg current) {
    final projects = [
      for (final ws in _cfg.workspaces)
        for (final proj in ws.projects) proj,
    ];
    return PopupMenuButton<String>(
      tooltip: '切换仓库',
      position: PopupMenuPosition.under,
      onSelected: (path) {
        if (path == current.path) return;
        final proj = projects.where((p) => p.path == path).firstOrNull;
        if (proj != null) _selectGitProject(proj);
      },
      itemBuilder: (_) => [
        for (final proj in projects)
          ccMenuItem(
            value: proj.path,
            icon: proj.path == current.path
                ? Icons.check_rounded
                : Icons.folder_outlined,
            label: proj.name,
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            current.name,
            style: CcType.code(size: 11.5, color: CcColors.muted),
          ),
          const Icon(
            Icons.arrow_drop_down_rounded,
            size: 16,
            color: CcColors.subtle,
          ),
        ],
      ),
    );
  }

  Widget _gitLogView(ProjectCfg p) {
    if (_gitLog.isEmpty) return centerMsg('没有 commit');
    final authors = _gitLog.map((c) => c.author).toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final logRefs = _gitBranches.map((b) => b.name).toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final effectiveRef = logRefs.contains(_gitLogRefFilter)
        ? _gitLogRefFilter
        : '';
    final effectiveAuthor = authors.contains(_logAuthorFilter)
        ? _logAuthorFilter
        : '';
    final commits = _filteredGitLog;
    final selected = _compareTitle != null
        ? _compareFiles
        : _commitFiles.isNotEmpty
        ? _commitFiles
        : const <FileDiff>[];
    final selectedCommit = _compareTitle == null && _selectedCommit != null
        ? _gitLog.where((c) => c.hash == _selectedCommit).firstOrNull
        : null;
    _ensureGraph(commits);
    return Row(
      children: [
        _logBranchPane(p),
        resizeHandle(
          prefKey: 'ws.logBranchWidth',
          get: () => _logBranchWidth,
          set: (v) => setState(() => _logBranchWidth = v),
          min: 180,
          max: 360,
        ),
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(color: CcColors.panel),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 32,
                        child: TextField(
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: 'Filter by message, author or hash',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            prefixIcon: Icon(Icons.search_rounded, size: 17),
                          ),
                          onChanged: (v) => setState(() => _logQuery = v),
                        ),
                      ),
                      const SizedBox(height: 7),
                      scrollableBar(
                        scrolling: [
                          _logBranchFilter(logRefs, effectiveRef),
                          const SizedBox(width: 6),
                          _logUserFilter(authors, effectiveAuthor),
                          const SizedBox(width: 6),
                          _logPathFilterChip(),
                        ],
                        pinnedTrailing: [
                          const SizedBox(width: 8),
                          Text(
                            '${commits.length}/${_gitLog.length}',
                            style: CcType.code(
                              size: 11,
                              color: CcColors.subtle,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: commits.isEmpty
                      ? centerMsg('没有匹配 commit')
                      : ListView.builder(
                          itemCount: commits.length,
                          itemExtent: _logRowHeight,
                          itemBuilder: (_, i) => _commitRow(
                            p,
                            commits[i],
                            i < _graphRows.length ? _graphRows[i] : null,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        resizeHandle(
          prefKey: 'ws.logDiffWidth',
          get: () => _logDiffWidth,
          set: (v) => setState(() => _logDiffWidth = v),
          min: 240,
          max: 640,
          invert: true,
        ),
        SizedBox(
          width: _logDiffWidth,
          child: Column(
            children: [
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(
                  color: CcColors.editorTabBar,
                  border: Border(bottom: BorderSide(color: CcColors.border)),
                ),
                child: Row(
                  children: [
                    Icon(
                      _compareTitle == null
                          ? Icons.commit_rounded
                          : Icons.compare_arrows_rounded,
                      size: 16,
                      color: CcColors.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _compareTitle ?? (_selectedCommit ?? 'Commit diff'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.code(size: 12, color: CcColors.muted),
                      ),
                    ),
                    scrollableActions([
                      if (_compareTitle != null)
                        TextButton(
                          onPressed: () => setState(() {
                            _compareTitle = null;
                            _compareFiles = const [];
                          }),
                          child: const Text('Commit Log'),
                        ),
                      if (selectedCommit != null)
                        _commitActionsMenu(p, selectedCommit),
                    ]),
                  ],
                ),
              ),
              Expanded(
                child: selected.isEmpty
                    ? centerMsg('选择 commit 查看改动文件')
                    : _commitFilesTree(
                        selected,
                        _compareTitle ?? selectedCommit?.shortHash ?? 'diff',
                        reload: _logDiffReload,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // _logFilterShell wraps a filter control (dropdown/button) in a compact pill
  // with a leading icon, matching the GoLand-style toolbar. [active] tints it.
  Widget _logFilterShell({
    required IconData icon,
    required bool active,
    required Widget child,
    VoidCallback? onTap,
  }) {
    final content = Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: active
            ? CcColors.accent.withValues(alpha: 0.12)
            : CcColors.panelHigh,
        border: Border.all(
          color: active
              ? CcColors.accent.withValues(alpha: 0.5)
              : CcColors.border,
        ),
        borderRadius: BorderRadius.circular(CcRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: active ? CcColors.accentBright : CcColors.muted,
          ),
          const SizedBox(width: 5),
          child,
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(CcRadius.sm),
      child: content,
    );
  }

  // _logFilterDropdown is the underline-less, width-capped dropdown shared by the
  // Branch and User toolbar filters.
  Widget _logFilterDropdown({
    required double maxWidth,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        isDense: true,
        isExpanded: true,
        value: value,
        iconSize: 16,
        menuMaxHeight: 320,
        style: CcType.code(size: 11.5, color: CcColors.text),
        items: items,
        onChanged: onChanged,
      ),
    ),
  );

  // _logBranchFilter merges the "all branches" toggle and the ref picker into a
  // single GoLand-style "Branch ▾" dropdown.
  static const _logAllSentinel = '\x00ALL';
  Widget _logBranchFilter(List<String> logRefs, String effectiveRef) {
    final scoped = _gitLogAllBranches || effectiveRef.isNotEmpty;
    return _logFilterShell(
      icon: Icons.account_tree_rounded,
      active: scoped,
      child: _logFilterDropdown(
        maxWidth: 150,
        value: _gitLogAllBranches ? _logAllSentinel : effectiveRef,
        items: [
          const DropdownMenuItem(
            value: _logAllSentinel,
            child: Text('All branches'),
          ),
          const DropdownMenuItem(value: '', child: Text('Current branch')),
          for (final r in logRefs)
            DropdownMenuItem(
              value: r,
              child: Text(r, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          setState(() {
            if (v == _logAllSentinel) {
              _gitLogAllBranches = true;
              _gitLogRefFilter = '';
            } else {
              _gitLogAllBranches = false;
              _gitLogRefFilter = v ?? '';
            }
          });
          Prefs.setBool('ws.gitLogAllBranches', _gitLogAllBranches);
          _refreshGit();
        },
      ),
    );
  }

  // _logUserFilter is the "User" author dropdown.
  Widget _logUserFilter(List<String> authors, String effectiveAuthor) {
    return _logFilterShell(
      icon: Icons.person_outline_rounded,
      active: effectiveAuthor.isNotEmpty,
      child: _logFilterDropdown(
        maxWidth: 120,
        value: effectiveAuthor,
        items: [
          const DropdownMenuItem(value: '', child: Text('All users')),
          for (final a in authors)
            DropdownMenuItem(
              value: a,
              child: Text(a, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() => _logAuthorFilter = v ?? ''),
      ),
    );
  }

  // _logPathFilterChip is the "Paths" filter button (opens a path picker).
  Widget _logPathFilterChip() {
    final active = _logPathFilter.isNotEmpty;
    return _logFilterShell(
      icon: Icons.folder_open_rounded,
      active: active,
      onTap: _setGitLogPathFilter,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              active ? _logPathFilter : 'Paths',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CcType.code(size: 11.5, color: CcColors.text),
            ),
          ),
          if (active) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: () {
                setState(() => _logPathFilter = '');
                _refreshGit();
              },
              child: const Icon(
                Icons.close_rounded,
                size: 13,
                color: CcColors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // _commitRefBadges renders up to two ref pills (branch = bright blue,
  // tag = amber) on a single line, with a "+N" overflow marker. Replaces the old
  // wrapping multi-line refs block.
  Widget _commitRefBadges(String refs) {
    final parts = refs
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != 'HEAD')
        .toList();
    if (parts.isEmpty) return const SizedBox.shrink();
    final chips = <Widget>[];
    for (final raw in parts.take(2)) {
      var label = raw;
      var isTag = false;
      if (label.startsWith('HEAD -> ')) label = label.substring(8);
      if (label.startsWith('tag: ')) {
        label = label.substring(5);
        isTag = true;
      }
      chips.add(
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: tag(label, isTag ? CcColors.warning : CcColors.accentBright),
        ),
      );
    }
    if (parts.length > 2) {
      chips.add(
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '+${parts.length - 2}',
            style: CcType.code(size: 11, color: CcColors.subtle),
          ),
        ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: chips);
  }

  // _commitRow renders one GoLand-style commit row: 作者 | 日期 | 图形轨道 |
  // 信息 | refs 胶囊 | 操作菜单。[gr] 是该行预算好的图形切片(可为 null)。
  Widget _commitRow(ProjectCfg p, GitCommit c, GraphRow? gr) {
    final sel = c.hash == _selectedCommit && _compareTitle == null;
    final isMerge = c.parents.length >= 2;
    final rowBg = sel
        ? Color.alphaBlend(
            CcColors.accent.withValues(alpha: 0.12),
            CcColors.panel,
          )
        : CcColors.panel;
    return Material(
      color: rowBg,
      child: InkWell(
        onTap: () => _selectCommit(p, c),
        onSecondaryTapDown: (d) => _showCommitMenu(d.globalPosition, p, c),
        child: Stack(
          children: [
            if (sel)
              const Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: SizedBox(
                  width: 2,
                  child: ColoredBox(color: CcColors.accent),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 58,
                    child: Text(
                      c.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.code(
                        size: 11.5,
                        color: isMerge ? CcColors.subtle : CcColors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 92,
                    child: Text(
                      commitDate(c.date),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.code(size: 11.5, color: CcColors.subtle),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (gr != null)
                    GraphRail(
                      row: gr,
                      laneCount: _graphLaneCount,
                      laneWidth: kLaneWidth,
                      rowHeight: _logRowHeight,
                    ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 13,
                        color: isMerge ? CcColors.subtle : CcColors.text,
                      ),
                    ),
                  ),
                  if (c.refs.trim().isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      fit: FlexFit.loose,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        physics: const NeverScrollableScrollPhysics(),
                        child: _commitRefBadges(c.refs),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 3-pane Log: left branch tree ----

  // _logBranchPane is the GoLand-style branch sidebar: Local / Remote groups;
  // clicking a branch scopes the commit list to it, right-click reuses the
  // existing branch operations.
  Widget _logBranchPane(ProjectCfg p) {
    final locals = _gitBranches.where((b) => !b.remote).toList();
    final remotes = _gitBranches.where((b) => b.remote).toList();
    final localRoot = _buildLogBranchTree(locals, 'local');
    final remoteRoot = _buildLogBranchTree(remotes, 'remote');
    final current = _gitBranches.where((b) => b.current).firstOrNull;
    final localCollapsed = _logBranchGroupsCollapsed.contains('local');
    final remoteCollapsed = _logBranchGroupsCollapsed.contains('remote');
    final tagsCollapsed = _logBranchGroupsCollapsed.contains('tags');
    return SizedBox(
      width: _logBranchWidth,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: CcColors.panel,
          border: Border(right: BorderSide(color: CcColors.border)),
        ),
        child: _gitBranches.isEmpty
            ? centerMsg('没有分支')
            : ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  _logHeadRow(p, current),
                  _branchGroupHeader('Local', 'local', localCollapsed),
                  if (!localCollapsed)
                    ..._logBranchNodeWidgets(p, localRoot, 'local', 0),
                  if (remotes.isNotEmpty) ...[
                    _branchGroupHeader('Remote', 'remote', remoteCollapsed),
                    if (!remoteCollapsed)
                      ..._logBranchNodeWidgets(p, remoteRoot, 'remote', 0),
                  ],
                  _logTagsRow(tagsCollapsed),
                  if (!tagsCollapsed)
                    if (_gitTags.isEmpty)
                      _logEmptyTagRow()
                    else
                      for (final t in _gitTags) _logTagTile(p, t),
                ],
              ),
      ),
    );
  }

  Widget _logHeadRow(ProjectCfg p, GitBranch? current) {
    final active =
        current != null &&
        !_gitLogAllBranches &&
        (_gitLogRefFilter.isEmpty || _gitLogRefFilter == current.name);
    return InkWell(
      onTap: current == null ? null : () => _filterLogByBranch(current),
      onSecondaryTapDown: current == null
          ? null
          : (d) => _showLogBranchMenu(p, current, d.globalPosition),
      child: Container(
        height: 30,
        color: active ? CcColors.accent.withValues(alpha: 0.10) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerLeft,
        child: Text(
          'HEAD (Current Branch)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12.5,
            color: CcColors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _branchGroupHeader(String label, String key, bool collapsed) =>
      InkWell(
        onTap: () => setState(() {
          if (collapsed) {
            _logBranchGroupsCollapsed.remove(key);
          } else {
            _logBranchGroupsCollapsed.add(key);
          }
        }),
        child: Container(
          height: 24,
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: Row(
            children: [
              Icon(
                collapsed
                    ? Icons.chevron_right_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 15,
                color: CcColors.subtle,
              ),
              const SizedBox(width: 3),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: CcColors.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _logTagsRow(bool collapsed) => InkWell(
    onTap: () => setState(() {
      if (collapsed) {
        _logBranchGroupsCollapsed.remove('tags');
      } else {
        _logBranchGroupsCollapsed.add('tags');
      }
    }),
    child: Container(
      height: 26,
      margin: const EdgeInsets.only(left: 8, right: 8, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: CcColors.panelHigh,
        borderRadius: BorderRadius.circular(CcRadius.sm),
      ),
      child: Row(
        children: [
          Icon(
            collapsed
                ? Icons.chevron_right_rounded
                : Icons.keyboard_arrow_down_rounded,
            size: 15,
            color: _activeLogTagName == null
                ? CcColors.subtle
                : CcColors.accentBright,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              'Tags',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CcType.code(size: 12, color: CcColors.muted),
            ),
          ),
          if (_gitTags.isNotEmpty)
            Text(
              '${_gitTags.length}',
              style: CcType.code(size: 11, color: CcColors.subtle),
            ),
        ],
      ),
    ),
  );

  Widget _logEmptyTagRow() => Container(
    height: 24,
    padding: const EdgeInsets.only(left: 30, right: 8),
    alignment: Alignment.centerLeft,
    child: Text(
      '没有标签',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: CcType.code(size: 12, color: CcColors.subtle),
    ),
  );

  Widget _logTagTile(ProjectCfg p, GitTag t) {
    final active = _activeLogTagName == t.name;
    return InkWell(
      onTap: () => _filterLogByTag(t),
      onSecondaryTapDown: (d) => _showLogTagMenu(p, t, d.globalPosition),
      child: Container(
        height: 26,
        color: active ? CcColors.warning.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.only(left: 24, right: 8),
        child: Row(
          children: [
            Icon(
              Icons.sell_outlined,
              size: 14,
              color: active ? CcColors.warning : CcColors.subtle,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                t.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(
                  size: 12,
                  color: active ? CcColors.text : CcColors.muted,
                  weight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _LogBranchNode _buildLogBranchTree(List<GitBranch> branches, String scope) {
    final root = _LogBranchNode(scope, scope);
    for (final b in branches) {
      final parts = b.name.split('/').where((s) => s.isNotEmpty).toList();
      var node = root;
      var path = scope;
      for (final part in parts) {
        path = '$path/$part';
        node = node.children.putIfAbsent(
          part,
          () => _LogBranchNode(part, path),
        );
      }
      node.branch = b;
    }
    return root;
  }

  List<Widget> _logBranchNodeWidgets(
    ProjectCfg p,
    _LogBranchNode node,
    String scope,
    int depth,
  ) {
    final children = node.children.values.toList()
      ..sort((a, b) {
        final af = a.children.isNotEmpty && a.branch == null;
        final bf = b.children.isNotEmpty && b.branch == null;
        if (af != bf) return af ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return [
      for (final child in children) ...[
        if (child.children.isEmpty && child.branch != null)
          _logBranchTile(p, child.branch!, child.name, depth)
        else
          _logBranchFolderTile(child, scope, depth),
        if (child.children.isNotEmpty &&
            _logBranchNodeOpen(child, scope, depth))
          ..._logBranchNodeWidgets(p, child, scope, depth + 1),
      ],
    ];
  }

  bool _logBranchNodeOpen(_LogBranchNode node, String scope, int depth) {
    if (_logBranchExpanded.contains(node.path)) return true;
    if (_logBranchExpanded.contains('-${node.path}')) return false;
    if (_logBranchNodeHasActiveBranch(node)) return true;
    return scope == 'remote' && depth == 0;
  }

  bool _logBranchNodeHasActiveBranch(_LogBranchNode node) {
    final activeName = _activeLogBranchName;
    final b = node.branch;
    if (b != null && activeName == b.name) {
      return true;
    }
    return node.children.values.any(_logBranchNodeHasActiveBranch);
  }

  String? get _activeLogBranchName {
    if (_gitLogAllBranches) return null;
    if (_gitLogRefFilter.isNotEmpty) {
      return _gitBranches.any((b) => b.name == _gitLogRefFilter)
          ? _gitLogRefFilter
          : null;
    }
    return _gitBranches.where((b) => b.current).firstOrNull?.name;
  }

  String? get _activeLogTagName {
    if (_gitLogAllBranches || _gitLogRefFilter.isEmpty) return null;
    return _gitTags.where((t) => t.ref == _gitLogRefFilter).firstOrNull?.name;
  }

  Widget _logBranchFolderTile(_LogBranchNode node, String scope, int depth) {
    final open = _logBranchNodeOpen(node, scope, depth);
    final active = _logBranchNodeHasActiveBranch(node);
    return InkWell(
      onTap: () => setState(() {
        if (open) {
          _logBranchExpanded
            ..remove(node.path)
            ..add('-${node.path}');
        } else {
          _logBranchExpanded
            ..remove('-${node.path}')
            ..add(node.path);
        }
      }),
      child: Container(
        height: 26,
        color: active ? CcColors.accent.withValues(alpha: 0.08) : null,
        padding: EdgeInsets.only(left: 8 + depth * 16, right: 8),
        child: Row(
          children: [
            Icon(
              open
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.chevron_right_rounded,
              size: 15,
              color: active ? CcColors.accentBright : CcColors.subtle,
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.folder_outlined,
              size: 15,
              color: active ? CcColors.text : CcColors.muted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(
                  size: 12,
                  color: active ? CcColors.text : CcColors.muted,
                  weight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logBranchTile(
    ProjectCfg p,
    GitBranch b,
    String label, [
    int depth = 0,
  ]) {
    final active = _activeLogBranchName == b.name;
    return InkWell(
      onTap: () => _filterLogByBranch(b),
      onSecondaryTapDown: (d) => _showLogBranchMenu(p, b, d.globalPosition),
      child: Container(
        height: 26,
        color: active ? CcColors.accent.withValues(alpha: 0.10) : null,
        padding: EdgeInsets.only(left: 12 + depth * 16, right: 8),
        child: Row(
          children: [
            Icon(
              b.current
                  ? Icons.star_rounded
                  : b.remote
                  ? Icons.cloud_outlined
                  : Icons.call_split_rounded,
              size: 14,
              color: b.current ? CcColors.warning : CcColors.subtle,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(
                  size: 12,
                  color: active || b.current ? CcColors.text : CcColors.muted,
                  weight: b.current ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            if (b.ahead > 0 || b.behind > 0) ...[
              const SizedBox(width: 4),
              tag('↑${b.ahead} ↓${b.behind}', CcColors.warning),
            ],
          ],
        ),
      ),
    );
  }

  void _filterLogByBranch(GitBranch b) {
    setState(() {
      _gitLogRefFilter = b.name;
      _gitLogAllBranches = false;
    });
    Prefs.setBool('ws.gitLogAllBranches', false);
    _refreshGit();
  }

  void _filterLogByTag(GitTag t) {
    setState(() {
      _gitLogRefFilter = t.ref;
      _gitLogAllBranches = false;
    });
    Prefs.setBool('ws.gitLogAllBranches', false);
    _refreshGit();
  }

  // ---- 3-pane Log: right changed-files tree ----

  // _commitFilesTree shows a commit's / compare's changed files as a directory
  // tree (single-child dir chains compacted); clicking a file opens its diff as
  // a tab in the center editor.
  Widget _commitFilesTree(
    List<FileDiff> files,
    String title, {
    Future<List<FileDiff>> Function(int context)? reload,
  }) {
    final root = _DiffTreeNode('');
    for (final f in files) {
      final parts = f.path.split('/');
      var node = root;
      for (var i = 0; i < parts.length - 1; i++) {
        node = node.children.putIfAbsent(
          parts[i],
          () => _DiffTreeNode(parts[i]),
        );
      }
      node.files.add(f);
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: _diffTreeRows(root, files, title, 0, reload),
    );
  }

  List<Widget> _diffTreeRows(
    _DiffTreeNode node,
    List<FileDiff> all,
    String title,
    int depth,
    Future<List<FileDiff>> Function(int context)? reload,
  ) {
    final out = <Widget>[];
    final dirNames = node.children.keys.toList()..sort();
    for (final name in dirNames) {
      var child = node.children[name]!;
      var label = name;
      // Compact single-child directory chains (a/b/c → one node).
      while (child.files.isEmpty && child.children.length == 1) {
        final only = child.children.values.first;
        label = '$label/${only.name}';
        child = only;
      }
      out.add(
        Padding(
          padding: EdgeInsets.only(left: 12.0 + depth * 14, top: 3, bottom: 3),
          child: Row(
            children: [
              const Icon(
                Icons.folder_rounded,
                size: 15,
                color: CcColors.subtle,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 12, color: CcColors.muted),
                ),
              ),
            ],
          ),
        ),
      );
      out.addAll(_diffTreeRows(child, all, title, depth + 1, reload));
    }
    final files = [...node.files]..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = f.path.split('/').last;
      out.add(
        InkWell(
          onTap: () =>
              _openDiffTab(all, title, initialPath: f.path, reload: reload),
          onSecondaryTapDown: (d) =>
              _showDiffTreeMenu(d.globalPosition, f, all, title, reload),
          child: Padding(
            padding: EdgeInsets.only(
              left: 12.0 + (depth + 1) * 14,
              right: 8,
              top: 3,
              bottom: 3,
            ),
            child: Row(
              children: [
                Icon(
                  _fileTypeIcon(f.path),
                  size: 15,
                  color: _diffStatusColor(f.status),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.code(size: 12.5),
                  ),
                ),
                const SizedBox(width: 6),
                fileDiffBadges(f),
              ],
            ),
          ),
        ),
      );
    }
    return out;
  }

  Color _diffStatusColor(String status) => switch (status) {
    'added' => CcColors.ok,
    'deleted' => CcColors.danger,
    'renamed' => CcColors.accent,
    'modified' => CcColors.warning,
    _ => CcColors.warning,
  };

  Widget _commitActionsMenu(
    ProjectCfg p,
    GitCommit c, {
    bool compact = false,
  }) => PopupMenuButton<String>(
    icon: Icon(
      compact ? Icons.more_vert_rounded : Icons.more_horiz_rounded,
      size: compact ? 16 : 17,
    ),
    iconSize: compact ? 16 : 17,
    padding: compact ? EdgeInsets.zero : const EdgeInsets.all(8),
    splashRadius: compact ? 14 : null,
    tooltip: 'Commit actions',
    enabled: !_gitLoading,
    onSelected: (v) {
      if (v == 'copy') _copyCommitHash(c);
      if (v == 'branch') _createBranchFromCommit(p, c);
      if (v == 'cherryPick') _cherryPickCommit(p, c);
      if (v == 'revert') _revertCommit(p, c);
      if (v == 'compare') _selectCommit(p, c);
      if (v == 'compareWorking') _compareCommitWithWorking(p, c);
    },
    itemBuilder: (_) => [
      ccMenuItem(
        value: 'copy',
        icon: Icons.content_copy_rounded,
        label: 'Copy Hash',
      ),
      ccMenuItem(
        value: 'branch',
        icon: Icons.add_rounded,
        label: 'New Branch from Here',
      ),
      ccMenuItem(
        value: 'compare',
        icon: Icons.difference_rounded,
        label: 'Show Commit Diff',
      ),
      ccMenuItem(
        value: 'compareWorking',
        icon: Icons.compare_arrows_rounded,
        label: 'Compare with Working Tree',
      ),
      const PopupMenuDivider(),
      ccMenuItem(
        value: 'cherryPick',
        icon: Icons.content_paste_rounded,
        label: 'Cherry-pick',
      ),
      ccMenuItem(value: 'revert', icon: Icons.undo_rounded, label: 'Revert'),
    ],
  );

  Widget _compactStashView(ProjectCfg p) {
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(
            color: CcColors.panel,
            border: Border(bottom: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_gitStashes.length} stashes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 11.5, color: CcColors.subtle),
                ),
              ),
              // Stash creation now lives in the bottom composer (_stashBox); the
              // header just counts + refreshes.
              IconButton(
                onPressed: _refreshGit,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: _gitStashes.isEmpty
              ? centerMsg('没有 stash')
              : ListView.separated(
                  itemCount: _gitStashes.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: CcColors.border),
                  itemBuilder: (_, i) {
                    final s = _gitStashes[i];
                    final isSelected = s.ref == _selectedStash;
                    return Material(
                      color: isSelected
                          ? CcColors.accent.withValues(alpha: 0.10)
                          : Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          _selectStash(p, s);
                          _openGitView(_GitView.stash);
                        },
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.inventory_2_outlined,
                                    size: 17,
                                    color: isSelected
                                        ? CcColors.accentBright
                                        : CcColors.muted,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      s.subject.isEmpty ? s.ref : s.subject,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: isSelected
                                            ? CcColors.text
                                            : CcColors.muted,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                s.branch.isEmpty
                                    ? s.ref
                                    : '${s.ref} · ${s.branch}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CcType.code(
                                  size: 10.8,
                                  color: CcColors.subtle,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 4,
                                runSpacing: 2,
                                children: [
                                  TextButton(
                                    onPressed: _gitLoading
                                        ? null
                                        : () => _stashApplyCurrent(p, s),
                                    child: const Text('Apply'),
                                  ),
                                  TextButton(
                                    onPressed: _gitLoading
                                        ? null
                                        : () => _stashPopCurrent(p, s),
                                    child: const Text('Pop'),
                                  ),
                                  TextButton(
                                    onPressed: _gitLoading
                                        ? null
                                        : () => _stashDropCurrent(p, s),
                                    style: TextButton.styleFrom(
                                      foregroundColor: CcColors.danger,
                                    ),
                                    child: const Text('Drop'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _branchButton(String branch) {
    final p = _gitProject;
    final locals = _gitBranches.where((b) => !b.remote && !b.current).toList();
    return PopupMenuButton<String>(
      tooltip: 'Git Branches',
      enabled: p != null,
      onSelected: (v) {
        if (p == null) return;
        if (v == 'branches') _openGitView(_GitView.log);
        if (v == 'dialog') _showBranchDialog();
        if (v == 'new') _showCreateBranchQuick(p);
        if (v == 'fetch') _gitFetchCurrent(p);
        if (v == 'prune') _gitFetchCurrent(p, prune: true);
        if (v == 'pull') _gitPullCurrent(p);
        if (v == 'pullRebase') _gitPullRebaseCurrent(p);
        if (v == 'push') _gitPushCurrent(p);
        if (v.startsWith('checkout:')) {
          final name = v.substring('checkout:'.length);
          final target = _gitBranches
              .where((b) => !b.remote && b.name == name)
              .firstOrNull;
          if (target != null) _checkoutBranchCurrent(p, target);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Row(
            children: [
              const Icon(
                Icons.account_tree_rounded,
                size: 16,
                color: CcColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  branch,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 12.5, color: CcColors.text),
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'branches',
          icon: Icons.history_rounded,
          label: 'Open Git Log',
        ),
        ccMenuItem(
          value: 'dialog',
          icon: Icons.account_tree_rounded,
          label: 'Branches Popup...',
        ),
        ccMenuItem(
          value: 'new',
          icon: Icons.add_rounded,
          label: 'New Branch...',
        ),
        const PopupMenuDivider(),
        ccMenuItem(value: 'fetch', icon: Icons.sync_rounded, label: 'Fetch'),
        ccMenuItem(
          value: 'prune',
          icon: Icons.sync_problem_rounded,
          label: 'Fetch --prune',
        ),
        ccMenuItem(
          value: 'pull',
          icon: Icons.download_rounded,
          label: 'Pull --ff-only',
        ),
        ccMenuItem(
          value: 'pullRebase',
          icon: Icons.download_rounded,
          label: 'Pull --rebase',
        ),
        ccMenuItem(value: 'push', icon: Icons.upload_rounded, label: 'Push'),
        if (locals.isNotEmpty) const PopupMenuDivider(),
        for (final b in locals.take(8))
          ccMenuItem(
            value: 'checkout:${b.name}',
            icon: Icons.call_split_rounded,
            label: 'Checkout ${b.name}',
            shortcut: (b.ahead > 0 || b.behind > 0)
                ? '↑${b.ahead} ↓${b.behind}'
                : null,
          ),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          border: Border.all(color: CcColors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.account_tree_rounded, size: 15),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                branch,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 12),
              ),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.arrow_drop_down_rounded, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _gitOperationBar(ProjectCfg p, GitOperationState op) => Container(
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: CcColors.warning.withValues(alpha: 0.10),
      border: Border(
        bottom: const BorderSide(color: CcColors.border),
        left: BorderSide(
          color: CcColors.warning.withValues(alpha: 0.65),
          width: 3,
        ),
      ),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          size: 17,
          color: CcColors.warning,
        ),
        const SizedBox(width: 8),
        Text(
          op.label,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Resolve conflicts, stage files, then continue or abort.',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 11, color: CcColors.subtle),
          ),
        ),
        TextButton.icon(
          onPressed: !_gitLoading && op.canContinue
              ? () => _gitContinueCurrentOperation(p, op)
              : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 15),
          label: const Text('Continue'),
        ),
        TextButton.icon(
          onPressed: !_gitLoading && op.canAbort
              ? () => _gitAbortCurrentOperation(p, op)
              : null,
          icon: const Icon(Icons.stop_circle_outlined, size: 15),
          label: const Text('Abort'),
          style: TextButton.styleFrom(foregroundColor: CcColors.danger),
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 17),
          tooltip: '刷新 Git',
          visualDensity: VisualDensity.compact,
          onPressed: _refreshGit,
        ),
      ],
    ),
  );

  Widget _commitBox(ProjectCfg p, GitStatusSummary? status) {
    final selected = _selectedChangePaths.length;
    // One "Commit" flow: commit the checked files if any are checked, otherwise
    // the already-staged ones — enabled whenever there's something to commit, so
    // there are no permanently-greyed staged-only buttons.
    final commitChecked = selected > 0;
    final hasCommitText = _commitCtl.text.trim().isNotEmpty;
    final canCommitAny = workspaceCommitActionEnabled(
      hasCommitTarget: commitChecked || (status?.hasStagedChanges ?? false),
      message: _commitCtl.text,
      loading: _gitLoading,
    );
    final canAmend =
        !_gitLoading && ((status?.hasStagedChanges ?? false) || hasCommitText);
    // Small, dense commit-action buttons (24px tall, 11.5 label, 13px icon) —
    // sizing only, so each button keeps its native colours (filled / tonal /
    // outlined).
    const compactBtn = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: WidgetStatePropertyAll(Size(0, 24)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(top: BorderSide(color: CcColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A roomy multi-line message editor (4–10 rows) instead of the old
          // single-line field.
          TextField(
            controller: _commitCtl,
            focusNode: _commitFocus,
            minLines: 4,
            maxLines: 10,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Commit message',
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          // Buttons scroll horizontally when the panel is too narrow to fit
          // them, instead of overflowing to the right.
          scrollableBar(
            alignScrollEnd: true,
            scrolling: [
              FilledButton.icon(
                style: compactBtn,
                onPressed: canCommitAny
                    ? () => commitChecked
                          ? _gitCommitSelected(p)
                          : _gitCommitCurrent(p)
                    : null,
                icon: const Icon(Icons.check_rounded, size: 13),
                label: Text(commitChecked ? 'Commit $selected' : 'Commit'),
              ),
              const SizedBox(width: 5),
              FilledButton.tonalIcon(
                style: compactBtn,
                onPressed: canCommitAny
                    ? () => commitChecked
                          ? _gitCommitSelectedAndPush(p)
                          : _gitCommitAndPushCurrent(p)
                    : null,
                icon: const Icon(Icons.upload_rounded, size: 13),
                label: const Text('Commit & Push'),
              ),
              const SizedBox(width: 5),
              OutlinedButton.icon(
                style: compactBtn,
                onPressed: canAmend ? () => _gitCommitAmendCurrent(p) : null,
                icon: const Icon(Icons.edit_note_rounded, size: 13),
                label: const Text('Amend'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // _stashBox is the inline Stash composer — the Stash view's counterpart to
  // _commitBox: name the stash (optional) and one-click "Stash All" (stashes every
  // change, untracked included per the toggle). Mirrors _commitBox's chrome (compact
  // 24px buttons, panel footer, scrollableBar) so the two git surfaces read the same.
  Widget _stashBox(ProjectCfg p) {
    final dirty = _gitChanges.isNotEmpty || _gitFiles.isNotEmpty;
    final canStash = dirty && !_gitLoading;
    const compactBtn = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: WidgetStatePropertyAll(Size(0, 24)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(top: BorderSide(color: CcColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _stashCtl,
            focusNode: _stashFocus,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Stash 名称(可选)',
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            onSubmitted: canStash ? (_) => _stashAllCurrent(p) : null,
          ),
          const SizedBox(height: 8),
          scrollableBar(
            alignScrollEnd: true,
            scrolling: [
              FilledButton.icon(
                style: compactBtn,
                onPressed: canStash ? () => _stashAllCurrent(p) : null,
                icon: const Icon(Icons.archive_rounded, size: 13),
                label: const Text('Stash All'),
              ),
              const SizedBox(width: 5),
              // Toggle whether untracked files are swept in too (git stash -u).
              OutlinedButton.icon(
                style: compactBtn,
                onPressed: _gitLoading
                    ? null
                    : () => setState(
                        () => _stashIncludeUntracked = !_stashIncludeUntracked,
                      ),
                icon: Icon(
                  _stashIncludeUntracked
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  size: 13,
                ),
                label: const Text('含未跟踪'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _termArea() {
    if (terms.isEmpty) {
      final ws =
          _cfg.workspaces.isNotEmpty && _cfg.workspaces.first.name.isNotEmpty
          ? _cfg.workspaces.first.name
          : 'workspace';
      return DecoratedBox(
        decoration: appGradient,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '~/$ws',
                    style: CcType.code(size: 14.5, color: CcColors.ok),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '❯',
                    style: CcType.code(
                      size: 14.5,
                      color: CcColors.accentBright,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const BlinkingCaret(),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                '在左侧 Project 的项目 / worktree 上起会话',
                style: TextStyle(color: CcColors.muted),
              ),
              const SizedBox(height: 8),
              Text(
                '# claude · codex',
                style: CcType.code(size: 12.5, color: CcColors.subtle),
              ),
            ],
          ),
        ),
      );
    }
    return terminalBody();
  }

  Widget _leftToolPanel() {
    if (_leftToolView == _LeftToolView.structure) return _structureSidebar();
    if (_gitViewForLeftTool(_leftToolView) != null) return _leftGitPanel();
    return _sidebar();
  }

  // The left tool window is the git OPERATE surface: Commit (changes) + Stash.
  // Branches/Log moved to the bottom browse panel. Renders by _leftToolView,
  // independent of the bottom's _gitView.
  Widget _leftGitPanel() {
    final p = _currentGitProject;
    final status = _gitStatus;
    final stash = _leftToolView == _LeftToolView.stash;
    final viewLabel = stash ? 'Stash' : 'Commit';
    final viewIcon = stash
        ? Icons.inventory_2_outlined
        : Icons.alt_route_rounded;
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          gradient: true,
          leading: [
            Icon(viewIcon, size: 16, color: CcColors.muted),
            const SizedBox(width: 8),
            Text(
              viewLabel,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: CcColors.text,
              ),
            ),
            if (p != null) ...[
              const SizedBox(width: 4),
              // The repo name is a dropdown that switches the active project —
              // reuses ts88's _repoSwitcher (also used in the Git Log header).
              _repoSwitcher(p),
              _branchButton(status?.branch ?? 'branch'),
              const SizedBox(width: 4),
            ],
          ],
          trailing: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 17),
              tooltip: '刷新 Git',
              visualDensity: VisualDensity.compact,
              onPressed: _refreshGit,
            ),
            IconButton(
              onPressed: () => _setProjectCollapsed(true),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left_rounded, size: 17),
            ),
          ],
        ),
        if (p != null) _leftGitActionBar(p, status),
        if (_gitLoading) const LinearProgressIndicator(minHeight: 2),
        if (p == null)
          Expanded(child: centerMsg('没有可用项目'))
        else if (_gitError != null)
          Expanded(child: centerMsg(_gitError!, onRetry: _refreshGit))
        else
          Expanded(
            child: Column(
              children: [
                if (_gitOperation != null) _gitOperationBar(p, _gitOperation!),
                Expanded(
                  child: stash
                      ? _compactStashView(p)
                      : (_gitFiles.isEmpty && _gitChanges.isEmpty
                            ? centerMsg('Working tree clean')
                            : _localChangesList(p)),
                ),
                if (!stash) _commitBox(p, status),
                if (stash) _stashBox(p),
              ],
            ),
          ),
      ],
    );
  }

  Widget _leftGitActionBar(ProjectCfg p, GitStatusSummary? status) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: const BoxDecoration(
      color: CcColors.editor,
      border: Border(bottom: BorderSide(color: CcColors.border)),
    ),
    child: scrollableBar(
      scrolling: [
        // Stage/Unstage only matter in the Changes view; Push/Pull/Fetch are
        // repo-wide so they stay across all left-panel git views.
        if (_leftToolView == _LeftToolView.changes) ...[
          IconButton(
            icon: const Icon(Icons.add_task_rounded, size: 16),
            tooltip: 'Stage All',
            visualDensity: VisualDensity.compact,
            onPressed: _gitLoading || !(status?.hasStageableChanges ?? false)
                ? null
                : () => _gitStageAllCurrent(p),
          ),
          IconButton(
            icon: const Icon(Icons.remove_done_rounded, size: 16),
            tooltip: 'Unstage All',
            visualDensity: VisualDensity.compact,
            onPressed: _gitLoading || !(status?.hasStagedChanges ?? false)
                ? null
                : () => _gitUnstageAllCurrent(p),
          ),
        ],
        IconButton(
          icon: const Icon(Icons.upload_rounded, size: 16),
          tooltip: 'Push',
          visualDensity: VisualDensity.compact,
          onPressed: _gitLoading ? null : () => _gitPushCurrent(p),
        ),
        IconButton(
          icon: const Icon(Icons.call_received_rounded, size: 16),
          tooltip: 'Pull --ff-only',
          visualDensity: VisualDensity.compact,
          onPressed: _gitLoading ? null : () => _gitPullCurrent(p),
        ),
        IconButton(
          icon: const Icon(Icons.sync_rounded, size: 16),
          tooltip: 'Fetch',
          visualDensity: VisualDensity.compact,
          onPressed: _gitLoading ? null : () => _gitFetchCurrent(p),
        ),
      ],
      pinnedTrailing: [
        TextButton.icon(
          onPressed: _gitLoading ? null : () => _showBranchDialog(),
          icon: const Icon(Icons.account_tree_rounded, size: 14),
          label: const Text('Branches'),
        ),
      ],
    ),
  );

  Widget _structureSidebar() {
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    final file = hasActiveFile ? _codeFiles[_activeFile] : null;
    final text = file?.key.currentState?.text;
    final symbols = file == null || text == null
        ? const <_CodeSymbol>[]
        : _extractCodeSymbols(file.path, text);
    final query = _structureQuery.trim().toLowerCase();
    final filteredSymbols = query.isEmpty
        ? symbols
        : symbols
              .where(
                (s) =>
                    s.name.toLowerCase().contains(query) ||
                    s.kind.toLowerCase().contains(query),
              )
              .toList();
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          gradient: true,
          leading: [
            const Icon(Icons.schema_rounded, size: 16, color: CcColors.muted),
            const SizedBox(width: 8),
            Text(
              file?.name ?? 'Structure',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: CcColors.text,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              query.isEmpty
                  ? '${symbols.length}'
                  : '${filteredSymbols.length}/${symbols.length}',
              style: CcType.code(size: 11.5, color: CcColors.subtle),
            ),
          ],
          trailing: [
            IconButton(
              onPressed: _showFileStructure,
              tooltip: '结构弹窗',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_full_rounded, size: 16),
            ),
            IconButton(
              onPressed: () => _setProjectCollapsed(true),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left_rounded, size: 17),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
          child: TextField(
            controller: _structureQueryCtl,
            enabled: file != null && text != null && symbols.isNotEmpty,
            decoration: InputDecoration(
              hintText: 'Filter symbols',
              isDense: true,
              prefixIcon: const Icon(Icons.filter_list_rounded, size: 17),
              suffixIcon: _structureQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      tooltip: '清空过滤',
                      onPressed: () => setState(() {
                        _structureQueryCtl.clear();
                        _structureQuery = '';
                      }),
                    ),
            ),
            onChanged: (v) => setState(() => _structureQuery = v),
            onSubmitted: (_) {
              if (file != null && filteredSymbols.isNotEmpty) {
                _openCodeFile(file.path, line: filteredSymbols.first.line);
              }
            },
          ),
        ),
        Expanded(
          child: file == null
              ? centerMsg('打开代码文件后显示结构')
              : text == null
              ? centerMsg('文件仍在加载')
              : symbols.isEmpty
              ? centerMsg('没有可跳转的结构符号')
              : filteredSymbols.isEmpty
              ? centerMsg('没有匹配符号')
              : ListView.separated(
                  itemCount: filteredSymbols.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: CcColors.border),
                  itemBuilder: (_, i) {
                    final s = filteredSymbols[i];
                    final level = (s.indent ~/ 2).clamp(0, 8).toDouble();
                    return ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -2),
                      contentPadding: EdgeInsets.only(
                        left: 10 + level * 12,
                        right: 8,
                      ),
                      leading: Icon(
                        s.icon,
                        size: 16,
                        color: CcColors.accentBright,
                      ),
                      title: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.code(size: 12),
                      ),
                      subtitle: Text(
                        '${s.kind} · line ${s.line}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.code(size: 10.5, color: CcColors.subtle),
                      ),
                      onTap: () => _openCodeFile(file.path, line: s.line),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _sidebar() {
    final wss = _cfg.workspaces;
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          gradient: true,
          leading: [
            const Icon(
              Icons.account_tree_outlined,
              size: 16,
              color: CcColors.muted,
            ),
            const SizedBox(width: 8),
            Text(
              'Project',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ).copyWith(color: CcColors.text),
            ),
            const SizedBox(width: 8),
            Text(
              '${wss.length}',
              style: CcType.code(size: 11.5, color: CcColors.subtle),
            ),
          ],
          trailing: [
            IconButton(
              onPressed: _activeFile >= 0 && _activeFile < _codeFiles.length
                  ? _selectOpenedFileInProject
                  : null,
              tooltip: 'Select Opened File',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.my_location_rounded, size: 17),
            ),
            IconButton(
              onPressed: () {
                setState(
                  () => _projectAutoscrollFromSource =
                      !_projectAutoscrollFromSource,
                );
                Prefs.setBool(
                  'ws.projectAutoscrollFromSource',
                  _projectAutoscrollFromSource,
                );
                if (_projectAutoscrollFromSource) _selectOpenedFileInProject();
              },
              tooltip: _projectAutoscrollFromSource
                  ? 'Autoscroll from Source: On'
                  : 'Autoscroll from Source: Off',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _projectAutoscrollFromSource
                    ? Icons.sync_alt_rounded
                    : Icons.sync_disabled_rounded,
                size: 17,
                color: _projectAutoscrollFromSource
                    ? CcColors.accentBright
                    : null,
              ),
            ),
            IconButton(
              onPressed: _busy ? null : _newWorkspace,
              tooltip: '新建工作区',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_rounded, size: 17),
            ),
            IconButton(
              onPressed: _busy ? null : _importWorkspace,
              tooltip: '从文件夹导入工作区(扫描其中的 git 仓库)',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.drive_folder_upload_rounded, size: 17),
            ),
            IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: '刷新',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, size: 17),
            ),
            IconButton(
              onPressed: () => _setProjectCollapsed(true),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left_rounded, size: 17),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: wss.isEmpty
              ? centerMsg(
                  'config.toml 里没有 workspace —— 点右上 + 新建,或 `cc-handoff workspace create`',
                )
              : ListView(
                  children: wss
                      .map(
                        (ws) => ExpansionTile(
                          // Stable identity so the tile's expansion State isn't
                          // reassigned if workspaces reorder.
                          key: ValueKey('ws:${ws.name}'),
                          title: _ctxMenu(
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                ws.name.isEmpty ? '(默认)' : ws.name,
                                style: const TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            _workspaceMenu(ws),
                          ),
                          leading: const Icon(
                            Icons.workspaces_rounded,
                            size: 20,
                          ),
                          // Persist collapse across rebuilds: switching the left
                          // panel to git/another view disposes this tree, and it
                          // used to come back all-expanded (initiallyExpanded:true).
                          // Mirror the section-collapse pattern (_secCollapsed) so a
                          // collapsed workspace stays collapsed. Default expanded.
                          initiallyExpanded: !Prefs.getBool(
                            'ws.wsCollapsed.${ws.name}',
                          ),
                          onExpansionChanged: (open) =>
                              Prefs.setBool('ws.wsCollapsed.${ws.name}', !open),
                          shape: const Border(),
                          children: applyOrder(
                            ws.projects,
                            loadOrder(desktopProjectOrderKey(ws.name)),
                            (p) => p.name,
                          ).map((p) => _projectTile(ws, p)).toList(),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }

  Widget _projectTile(WorkspaceCfg ws, ProjectCfg p) {
    return ExpansionTile(
      title: _ctxMenu(
        _HoverZone(
          builder: (h) => Row(
            children: [
              Expanded(
                child: Text(
                  p.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _rowActions(
                h,
                onClaude: () => _openAgent(p, p.path, 'claude', ws.preLaunch),
                onCodex: () => _openAgent(p, p.path, 'codex', ws.preLaunch),
              ),
            ],
          ),
        ),
        _projectMenu(ws, p),
      ),
      leading: const Icon(Icons.folder_rounded, size: 19),
      controller: _ctlFor(p.path),
      tilePadding: const EdgeInsets.only(left: 16, right: 8),
      childrenPadding: const EdgeInsets.only(left: 14),
      shape: const Border(),
      onExpansionChanged: (open) {
        if (open) {
          _ensureWorktrees(p.path);
          _selectGitProject(p);
        }
      },
      children: [
        ..._sessionNodesForDir(p.path, project: p, preLaunch: ws.preLaunch),
        _filesNode(
          p.path,
          p.name,
          selectedPath: _revealedProjectFilePath,
          fileMenuBuilder: (path) => _projectFileMenu(p, path, isDir: false),
          directoryMenuBuilder: (path) =>
              _projectFileMenu(p, path, isDir: true),
          pathStatusBuilder: (path) =>
              _pathStatus(p.path, p.name, _gitChanges, path),
        ),
        ..._worktreeNodes(ws, p),
        ..._taskNodes(p),
        if (_projectEmpty(p))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '无 worktree / 任务',
              style: TextStyle(color: CcColors.muted, fontSize: 12),
            ),
          ),
      ],
    );
  }

  // 统一处理 VCS 下拉菜单的动作分发(被多处 PopupMenuButton 复用)。
  // 并发保护已下沉到各 _gitXCurrent 方法,这里不再重复 _gitLoading 判断。
  void _handleGitMenuAction(ProjectCfg p, String v) {
    _selectGitProject(p);
    switch (v) {
      case 'changes':
        _openLeftTool(_LeftToolView.changes);
      case 'workingDiff':
        _showWorkingTreeDiff(p);
      case 'commit':
        _openCommitFlow(p);
      case 'log':
        _openLogShortcut();
      case 'branches':
        _openBranchesShortcut();
      case 'stash':
        _openLeftTool(_LeftToolView.stash);
      case 'branchPopup':
        _showBranchDialog();
      case 'newBranch':
        _showCreateBranchQuick(p);
      case 'fetch':
        _gitFetchCurrent(p);
      case 'fetchPrune':
        _gitFetchCurrent(p, prune: true);
      case 'pull':
        _gitPullCurrent(p);
      case 'pullRebase':
        _gitPullRebaseCurrent(p);
      case 'push':
        _gitPushCurrent(p);
      case 'stageAll':
        _gitStageAllCurrent(p);
      case 'unstageAll':
        _gitUnstageAllCurrent(p);
      case 'stashPush':
        _stashPushCurrent(p);
      case 'rollbackAll':
        _gitDiscardAllCurrent(p);
    }
  }

  // _filesNode 渲染一个可折叠的 FILES 区:项目根或某个 worktree 路径各用一份。
  // fileMenuBuilder/pathStatusBuilder 由调用方注入(worktree 可传 null/轻量版)。
  Widget _filesNode(
    String dir,
    String label, {
    String? selectedPath,
    PopupMenuButton<String>? Function(String path)? fileMenuBuilder,
    PopupMenuButton<String>? Function(String path)? directoryMenuBuilder,
    Widget Function(String path)? pathStatusBuilder,
  }) {
    final header = _sectionHeader(dir, 'files', 'FILES');
    if (_secCollapsed(dir, 'files')) return header;
    final focus = _fileTreeFocus.putIfAbsent(
      dir,
      () => FocusNode(debugLabel: 'fileTree:$dir'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.only(left: 4),
          // CallbackShortcuts 在外、聚焦节点在内：只有点进这棵树使其聚焦时，
          // Cmd/Ctrl+C/X/V 才会命中；焦点在终端/编辑器时不触发，互不抢键。
          child: CallbackShortcuts(
            bindings: fsShortcuts,
            child: Focus(
              focusNode: focus,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => focus.requestFocus(),
                child: DirTile(
                  dir: dir,
                  label: label,
                  depth: 0,
                  initiallyExpanded: false,
                  onOpenFile: _openCodeFile,
                  selectedPath: selectedPath,
                  onSelectPath: (p) =>
                      setState(() => _revealedProjectFilePath = p),
                  onDropPaths: fsDrop,
                  onMenuPosition: (pos) => _lastContextMenuPosition = pos,
                  fileMenuBuilder: fileMenuBuilder,
                  directoryMenuBuilder: directoryMenuBuilder,
                  pathStatusBuilder: pathStatusBuilder,
                  refreshToken: _fileTreeRefreshToken,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // _pathStatus 计算文件/目录的 git 改动角标。rootPath/rootLabel 是该文件树的根
  // (项目根或 worktree);allChanges 是相对 rootPath 的改动列表(项目用 _gitChanges,
  // worktree 用 _worktreeChanges[wtPath])。
  Widget _pathStatus(
    String rootPath,
    String rootLabel,
    List<GitChange> allChanges,
    String path,
  ) {
    final rel = path == rootPath ? '' : path.substring(rootPath.length + 1);
    final isDir = FileSystemEntity.isDirectorySync(path);
    final changes = isDir
        ? allChanges
              .where(
                (c) =>
                    rel.isEmpty ||
                    c.path.startsWith('$rel/') ||
                    (c.oldPath?.startsWith('$rel/') ?? false),
              )
              .toList()
        : allChanges.where((c) => c.path == rel || c.oldPath == rel).toList();
    if (changes.isEmpty) return const SizedBox.shrink();
    final severity = changes.firstWhere(
      (c) => c.conflicted,
      orElse: () => changes.firstWhere(
        (c) => c.untracked,
        orElse: () =>
            changes.firstWhere((c) => c.staged, orElse: () => changes.first),
      ),
    );
    final label = isDir ? '${changes.length}' : _gitChangeShortLabel(severity);
    final target = rel.isEmpty ? rootLabel : rel;
    return Tooltip(
      message: isDir
          ? '$target · ${changes.length} changed files'
          : '${severity.status} · $target',
      child: tag(label, _changeColor(severity), bold: true),
    );
  }

  void _handleFsMenu(
    String value,
    String path, {
    required String rootPath,
    required bool isDir,
    ProjectCfg? project,
  }) {
    setState(() => _revealedProjectFilePath = path);
    final parent = isDir ? path : _pathParent(path);
    final rel = project == null || path == project.path
        ? ''
        : path.substring(project.path.length + 1);
    switch (value) {
      case 'open':
        if (isDir) {
          _refreshFileTrees(path);
        } else {
          _openCodeFile(path);
        }
      case 'newFile':
        _newFileInDir(parent);
      case 'newDir':
        _newDirectoryInDir(parent);
      case 'rename':
        _renameFsPath(path, isDir, rootPath);
      case 'delete':
        _deleteFsPath(path, isDir, rootPath);
      case 'copyPath':
        _copyFilePath(path);
      case 'copy':
        fsCopy([path]);
      case 'cut':
        fsCut([path]);
      case 'paste':
        fsPaste(parent);
      case 'revealProject':
        _revealFileInProject(path);
      case 'revealSystem':
        _revealInSystem(path);
      case 'openExternal':
        _openExternally(path);
      case 'terminal':
        _openShellAt(path);
      case 'refresh':
        _refreshFileTrees(path);
      case 'compare':
        if (project != null && !isDir && rel.isNotEmpty) {
          _compareProjectFileWithHead(project, rel);
        }
      case 'history':
        if (project != null && !isDir && rel.isNotEmpty) {
          _showFileHistoryForProjectFile(project, rel);
        }
      case 'annotate':
        if (project != null && !isDir && rel.isNotEmpty) {
          _showBlameForProjectFile(project, rel);
        }
    }
  }

  Future<void> _selectFsMenu(
    String value,
    String path, {
    required String rootPath,
    required bool isDir,
    ProjectCfg? project,
  }) async {
    if (value == fileMenuEdit ||
        value == fileMenuLocate ||
        value == fileMenuVersion) {
      final pick = await showMenu<String>(
        context: context,
        position: menuPosAt(
          context,
          _lastContextMenuPosition ?? _fallbackMenuPosition(),
        ),
        items: fileActionSubmenuEntries(
          value,
          atRoot: path == rootPath,
          includeProjectReveal: project != null,
        ),
      );
      if (pick == null || !mounted) return;
      _handleFsMenu(
        pick,
        path,
        rootPath: rootPath,
        isDir: isDir,
        project: project,
      );
      return;
    }
    _handleFsMenu(
      value,
      path,
      rootPath: rootPath,
      isDir: isDir,
      project: project,
    );
  }

  PopupMenuButton<String> _projectFileMenu(
    ProjectCfg project,
    String path, {
    required bool isDir,
  }) {
    final rel = path == project.path
        ? ''
        : path.substring(project.path.length + 1);
    return PopupMenuButton<String>(
      tooltip: 'File actions',
      icon: const Icon(Icons.more_vert_rounded, size: 16),
      padding: EdgeInsets.zero,
      onOpened: () {
        _lastContextMenuPosition = null;
        setState(() => _revealedProjectFilePath = path);
      },
      onSelected: (v) => unawaited(
        _selectFsMenu(
          v,
          path,
          rootPath: project.path,
          isDir: isDir,
          project: project,
        ),
      ),
      itemBuilder: (_) => fileActionMenuEntries(
        isDir: isDir,
        includeVersionControl: !isDir && rel.isNotEmpty,
      ),
    );
  }

  // The empty hint shows only once worktrees have LOADED empty and there are no
  // tasks — not while still loading or before the tile is expanded.
  bool _projectEmpty(ProjectCfg p) {
    final wts = _worktrees[p.path];
    if (wts == null) return false; // 未加载或加载中,先不显示空提示
    // 主工作树(path == 项目根)不算附加 worktree;只有附加 worktree 全无时才算空。
    final noLinked = wts.where((w) => w.path != p.path).isEmpty;
    return noLinked &&
        (_tasksByRepo[p.name]?.isEmpty ?? true) &&
        _sessionsFor(p).isEmpty;
  }

  // _sessionsFor returns the open terminal sessions whose workdir is this
  // project's root or one of its worktrees, paired with their index in `terms`.
  List<({int idx, TerminalSession s})> _sessionsFor(ProjectCfg p) {
    final out = <({int idx, TerminalSession s})>[];
    for (var i = 0; i < terms.length; i++) {
      final wd = terms[i].workdir;
      if (wd == p.path || wd.startsWith('${p.path}/.worktrees/')) {
        out.add((idx: i, s: terms[i]));
      }
    }
    return out;
  }

  // _sessionsForDir returns the open terminal sessions launched in EXACTLY [dir]
  // (a project root OR a worktree path), paired with their index in `terms`.
  // Exact match is correct: _openAgent always launches at p.path or w.path.
  List<({int idx, TerminalSession s})> _sessionsForDir(String dir) {
    final out = <({int idx, TerminalSession s})>[];
    for (var i = 0; i < terms.length; i++) {
      if (terms[i].workdir == dir) out.add((idx: i, s: terms[i]));
    }
    return out;
  }

  // [project]/[preLaunch] (the owning project + its workspace pre-launch) let the
  // per-session menu offer 起总管 in that session's context; null project hides it.
  List<Widget> _sessionNodesForDir(
    String dir, {
    ProjectCfg? project,
    String preLaunch = '',
  }) {
    final ss = _sessionsForDir(dir);
    if (ss.isEmpty) return const [];
    final header = _sectionHeader(dir, 'sessions', '会话 (${ss.length})');
    if (_secCollapsed(dir, 'sessions')) return [header];
    return [
      header,
      ...ss.map((e) {
        final active = e.idx == activeTerm;
        // hidden = the session keeps running but its tab was closed ("close
        // view"); tapping the node reopens the tab (reopenTermView).
        final hidden = isTabHidden(e.s.id);
        // notLoaded = restored lazily (a closed-to-tree tab) and not yet started —
        // shown dimmed with a 休眠 glyph; tapping it spawns the agent. Distinct from
        // a still-running session whose tab was merely closed (hidden but started).
        final notLoaded = e.s.deferred && !e.s.started;
        final agent = e.s.agentKind;
        final display = (e.s.name?.isNotEmpty ?? false)
            ? e.s.name!
            : '$agent · ${e.s.title}';
        // Other live sessions this node can forward its selection to. This menu
        // lives in the tree (not the terminal surface), so a full-screen TUI
        // can't grab the click the way it intercepts an in-terminal right-click.
        final sendGroups = _sendGroupsFor(e.s.workdir, excludeId: e.s.id);
        final hasSendTargets =
            sendGroups.same.isNotEmpty || sendGroups.others.isNotEmpty;
        final sessionMenu = PopupMenuButton<String>(
          tooltip: '会话操作',
          onOpened: () => _lastContextMenuPosition = null,
          onSelected: (v) async {
            if (v == 'supervisor') {
              if (project != null) {
                unawaited(_supervisorFlow(project, dir, preLaunch));
              }
            } else if (v == 'rename') {
              _renameSession(e.s);
            } else if (v == 'close') {
              closeTerm(e.idx);
            } else if (v == 'send-online') {
              _showSendToOnlineUser(
                e.s.selectedText ?? e.s.renderSnapshot(_kForwardLines),
                sourcePath: e.s.workdir,
              );
            } else if (v == 'send-session') {
              final pick = await showGroupedSendMenu(
                context,
                _lastContextMenuPosition ?? _fallbackMenuPosition(),
                same: sendGroups.same,
                others: sendGroups.others,
              );
              if (pick == null || !mounted || !pick.startsWith('send:')) {
                return;
              }
              final to = sessionById(pick.substring('send:'.length));
              if (to != null) _forwardSelection(e.s, to);
            } else if (v.startsWith('send:')) {
              final to = sessionById(v.substring(5));
              if (to != null) _forwardSelection(e.s, to);
            }
          },
          itemBuilder: (_) {
            return [
              if (project != null) ...[
                ccMenuItem(
                  value: 'supervisor',
                  icon: Icons.account_tree_outlined,
                  label: '起总管',
                ),
                const PopupMenuDivider(),
              ],
              ccMenuItem(
                value: 'rename',
                icon: Icons.edit_rounded,
                label: '重命名',
              ),
              ccMenuItem(
                value: 'close',
                icon: Icons.power_settings_new_rounded,
                label: '结束会话',
              ),
              const PopupMenuDivider(),
              // Always enabled — sends the selection if there is one, else this
              // session's recent output (renderSnapshot). No need to first make a
              // mouse selection inside a TUI.
              if (hasSendTargets)
                ccMenuItem(
                  value: 'send-session',
                  icon: Icons.send_rounded,
                  label: '发送到会话…',
                ),
              if (_canSendToOnline)
                ccMenuItem(
                  value: 'send-online',
                  icon: Icons.cloud_upload_rounded,
                  label: '发送到在线用户…',
                ),
            ];
          },
        );
        return _ctxMenu(
          Material(
            color: active
                ? CcColors.accent.withValues(alpha: 0.08)
                : Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: active ? CcColors.accent : Colors.transparent,
                    width: 2.5,
                  ),
                ),
              ),
              child: ListTile(
                visualDensity: _tileDensity,
                contentPadding: const EdgeInsets.only(left: 12, right: 2),
                horizontalTitleGap: 8,
                selected: active,
                // Live status avatar: rebuilds on the session's activity transitions
                // (busy / needs-review, via activityRev) so it pulses while working
                // and shows a status-coloured badge (working / done / idle) at rest.
                // Coarse status is derived from the session's own in-memory flags —
                // NOT _statusFor(_latestHookActivity(...)): that reads the hook-event
                // dir off disk on every rebuild, and its fine-grained sub-states only
                // refresh on the busy/needs-review flips activityRev fires on (so a
                // 12-colour badge would go stale mid-turn). The coarse set is exactly
                // what the trigger reliably covers; the 会话总览 keeps the rich status.
                leading: ValueListenableBuilder<int>(
                  valueListenable: e.s.activityRev,
                  builder: (_, _, _) => SessionActivityAvatar(
                    seed: e.s.id,
                    isAgent: e.s.isAgent,
                    status: !e.s.isAgent
                        ? SessionStatus.shell
                        : e.s.needsReview
                        ? SessionStatus.needsReview
                        : e.s.busy
                        ? SessionStatus.working
                        : SessionStatus.idle,
                    size: 20,
                  ),
                ),
                title: Text(
                  display,
                  style: TextStyle(
                    fontFamily: CcType.mono,
                    fontSize: 13.5,
                    color: active
                        ? CcColors.text
                        : (notLoaded ? CcColors.subtle : CcColors.muted),
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  // Reopen the session's tab (un-hide it if its view was closed)
                  // and make it active, then surface the terminal panel so the
                  // reopened session is visible. reopenTermView re-arms TTS.
                  reopenTermView(e.idx);
                  _setBottomTool(_BottomTool.terminal);
                },
                trailing: active
                    ? Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: statusDot(CcColors.ok, size: 7, glow: true),
                      )
                    : notLoaded
                    ? Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Tooltip(
                          message: '未加载 · 点击启动',
                          child: Icon(
                            Icons.bedtime_outlined,
                            size: 13,
                            color: CcColors.subtle,
                          ),
                        ),
                      )
                    : (hidden
                          ? Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                Icons.visibility_off_outlined,
                                size: 13,
                                color: CcColors.muted,
                              ),
                            )
                          : null),
              ),
            ),
          ),
          sessionMenu,
        );
      }),
    ];
  }

  // Recent-output fallback size when forwarding a session with no active
  // selection (a TUI you can't easily mouse-select in). One screenful-ish.
  static const int _kForwardLines = 40;

  // _forwardSelection forwards [from]'s content into [to]'s input via the local
  // bus (submit:false — fills the target's input for you to confirm). Sends the
  // current selection if there is one, else [from]'s recent output snapshot, so
  // the menu works even when you can't make a selection inside a TUI.
  void _forwardSelection(TerminalSession from, TerminalSession to) {
    final sel = from.selectedText;
    final body = sel ?? from.renderSnapshot(_kForwardLines);
    if (body.trim().isEmpty) {
      _snack('「${from.label}」暂无可发送内容');
      return;
    }
    final err = deliverLocalMessage(LocalMsg(from.id, to.id, body, false));
    _snack(
      err ?? (sel != null ? '已发送选区到 ${to.label}' : '已发送最近输出到 ${to.label}'),
    );
  }

  Future<void> _renameSession(TerminalSession s) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => WorkspaceSessionRenameDialog(
        initialName: s.name ?? '',
        hint: s.title,
      ),
    );
    if (raw == null) return;
    final v = raw.trim();
    if (!mounted) return;
    setState(() => s.name = v.isEmpty ? null : v);
    persistTerms();
  }

  List<Widget> _worktreeNodes(WorkspaceCfg ws, ProjectCfg p) {
    if (!_worktrees.containsKey(p.path)) return const [];
    final wts = _worktrees[p.path];
    if (wts == null) {
      return const [
        ListTile(
          dense: true,
          title: Text(
            'worktrees 加载中…',
            style: TextStyle(color: CcColors.muted, fontSize: 12),
          ),
        ),
      ];
    }
    // 主工作树的 path == 项目根,已由项目节点自身表示,这里只列附加 worktree。
    final linked = wts.where((w) => w.path != p.path).toList();
    if (linked.isEmpty) return const [];
    final header = _sectionHeader(
      p.path,
      'worktrees',
      'WORKTREES (${linked.length})',
    );
    if (_secCollapsed(p.path, 'worktrees')) return [header];
    return [
      header,
      ...linked.map((w) {
        final title = w.branch.isEmpty ? w.name : w.branch;
        return ExpansionTile(
          leading: Icon(
            Icons.account_tree_rounded,
            size: 18,
            color: w.isHandoff ? CcColors.accent : CcColors.muted,
          ),
          controller: _ctlFor(w.path),
          tilePadding: const EdgeInsets.only(left: 10, right: 2),
          childrenPadding: const EdgeInsets.only(left: 12),
          shape: const Border(),
          onExpansionChanged: (open) {
            if (open) _ensureWorktreeChanges(w.path);
          },
          title: _ctxMenu(
            _HoverZone(
              builder: (h) => Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontFamily: CcType.mono,
                            fontSize: 13.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (w.isHandoff)
                          const Text(
                            'handoff',
                            style: TextStyle(
                              color: CcColors.accent,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  _rowActions(
                    h,
                    onClaude: () =>
                        _openAgent(p, w.path, 'claude', ws.preLaunch),
                    onCodex: () => _openAgent(p, w.path, 'codex', ws.preLaunch),
                  ),
                ],
              ),
            ),
            _worktreeMenu(ws, p, w),
          ),
          children: [
            ..._sessionNodesForDir(w.path, project: p, preLaunch: ws.preLaunch),
            _filesNode(
              w.path,
              title,
              fileMenuBuilder: (path) =>
                  _worktreeFileMenu(w.path, path, isDir: false),
              directoryMenuBuilder: (path) =>
                  _worktreeFileMenu(w.path, path, isDir: true),
              pathStatusBuilder: (path) => _pathStatus(
                w.path,
                title,
                _worktreeChanges[w.path] ?? const [],
                path,
              ),
            ),
          ],
        );
      }),
    ];
  }

  // worktree 文件树的轻量菜单。compare/history/blame 依赖项目 git 根,对 worktree
  // 不直接成立(各自是独立工作树),留作后续。
  PopupMenuButton<String> _worktreeFileMenu(
    String rootPath,
    String path, {
    required bool isDir,
  }) => PopupMenuButton<String>(
    tooltip: 'File actions',
    icon: const Icon(Icons.more_vert_rounded, size: 16),
    padding: EdgeInsets.zero,
    onOpened: () {
      _lastContextMenuPosition = null;
      setState(() => _revealedProjectFilePath = path);
    },
    onSelected: (v) =>
        unawaited(_selectFsMenu(v, path, rootPath: rootPath, isDir: isDir)),
    itemBuilder: (_) =>
        fileActionMenuEntries(isDir: isDir, includeVersionControl: false),
  );

  List<Widget> _taskNodes(ProjectCfg p) {
    final ts = _tasksByRepo[p.name] ?? const [];
    if (ts.isEmpty) return const [];
    final header = _sectionHeader(p.path, 'tasks', '任务 (${ts.length})');
    if (_secCollapsed(p.path, 'tasks')) return [header];
    return [
      header,
      ...ts.map(
        (it) => ListTile(
          visualDensity: _tileDensity,
          contentPadding: const EdgeInsets.only(left: 12, right: 8),
          leading: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: statusDot(
              it.urgency == 'urgent' ? CcColors.danger : CcColors.muted,
              size: 9,
              glow: it.urgency == 'urgent',
            ),
          ),
          title: Text(
            it.headline.isNotEmpty ? it.headline : it.sender,
            style: const TextStyle(fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${it.sender} · ${it.state}',
            style: const TextStyle(color: CcColors.muted, fontSize: 11.5),
          ),
          onTap: () => _openTask(it),
        ),
      ),
    ];
  }

  // ------------------------------------------------------------- menus ----

  List<PopupMenuEntry<String>> _agentItems(String def) => [
    ccMenuItem(
      value: 'claude',
      icon: Icons.play_arrow_rounded,
      label: '起 claude${def == 'claude' ? '  (默认)' : ''}',
    ),
    ccMenuItem(
      value: 'codex',
      icon: Icons.smart_toy_outlined,
      label: '起 codex${def == 'codex' ? '  (默认)' : ''}',
    ),
  ];

  PopupMenuButton<String> _workspaceMenu(WorkspaceCfg ws) =>
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded, size: 18),
        tooltip: '工作区操作',
        onSelected: (v) {
          switch (v) {
            case 'new':
              _newEmptyProject(ws);
            case 'add':
              _addProject(ws);
            case 'reorder':
              _openProjectOrderSheet(ws);
            case 'settings':
              _workspaceSettings(ws);
            case 'remove':
              _removeWorkspace(ws);
          }
        },
        itemBuilder: (_) => [
          ccMenuItem(
            value: 'new',
            icon: Icons.create_new_folder_rounded,
            label: 'New Empty Project',
          ),
          ccMenuItem(
            value: 'add',
            icon: Icons.create_new_folder_outlined,
            label: 'Add Existing / Clone Project',
          ),
          ccMenuItem(
            value: ws.projects.length > 1 ? 'reorder' : null,
            icon: Icons.swap_vert_rounded,
            label: '排序项目',
          ),
          const PopupMenuDivider(),
          ccMenuItem(
            value: 'settings',
            icon: Icons.settings_rounded,
            label: '工作区设置',
          ),
          ccMenuItem(
            value: 'remove',
            icon: Icons.delete_outline_rounded,
            label: '删除工作区',
            danger: true,
          ),
        ],
      );

  // 拖拽给某工作区的项目排序。顺序是本设备的表现层偏好，存进 Prefs（不改 config.toml），
  // 侧栏与会话总览都读同一份覆盖。镜像 remote_workspace_page 的 _openKeyBarEditor。
  void _openProjectOrderSheet(WorkspaceCfg ws) {
    final key = desktopProjectOrderKey(ws.name);
    final items = List<ProjectCfg>.of(
      applyOrder(ws.projects, loadOrder(key), (p) => p.name),
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          void apply(VoidCallback change) {
            change();
            saveOrder(key, [for (final p in items) p.name]);
            setSheet(() {});
            setState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '排序项目 · ${ws.name.isEmpty ? '默认' : ws.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Flexible(
                    child: ReorderableListView(
                      shrinkWrap: true,
                      // onReorderItem already adjusts newIndex for the removed item.
                      onReorderItem: (oldI, newI) =>
                          apply(() => items.insert(newI, items.removeAt(oldI))),
                      children: [
                        for (final p in items)
                          ListTile(
                            key: ObjectKey(p),
                            dense: true,
                            leading: const Icon(Icons.drag_handle, size: 20),
                            title: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              p.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: CcColors.subtle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _workspaceSettings(WorkspaceCfg ws) async {
    final draft = await showDialog<WorkspaceSettingsDraft>(
      context: context,
      builder: (_) => WorkspaceSettingsDialog(
        workspaceName: ws.name,
        initialPreLaunch: ws.preLaunch,
        initialEditor: ws.editor,
        initialAgent: ws.agent,
      ),
    );
    if (draft == null) return;
    if (!mounted) return;
    await _runCli(
      () => Cli.workspaceSet(
        ws.name,
        preLaunch: draft.preLaunch.trim(),
        editor: draft.editor.trim(),
        agent: draft.agent,
      ),
      '已保存',
      after: _reloadConfig,
    );
  }

  PopupMenuButton<String> _projectMenu(
    WorkspaceCfg ws,
    ProjectCfg p,
  ) => PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert_rounded, size: 18),
    tooltip: '项目操作',
    onSelected: (v) {
      switch (v) {
        case 'claude':
        case 'codex':
          _openAgent(p, p.path, v, ws.preLaunch);
        case 'supervisor':
          unawaited(_supervisorFlow(p, p.path, ws.preLaunch));
        case 'worktree':
          _newWorktree(ws, p);
        case 'diff':
          _openDiff(p.path, p.name);
        case 'files':
          _openFileBrowser(p.path, p.name);
        case 'pr':
          _openPrs(p);
        case 'config':
          _openRepoConfig(p);
        case 'remove':
          _removeProject(ws, p);
      }
    },
    itemBuilder: (_) => [
      ..._agentItems(ws.agent),
      ccMenuItem(
        value: 'supervisor',
        icon: Icons.account_tree_outlined,
        label: '起总管',
      ),
      const PopupMenuDivider(),
      ccMenuItem(value: 'diff', icon: Icons.difference_rounded, label: '看变动'),
      ccMenuItem(value: 'files', icon: Icons.folder_open_rounded, label: '文件'),
      if (p.github.isNotEmpty)
        ccMenuItem(value: 'pr', icon: Icons.merge_rounded, label: 'GitHub PR'),
      ccMenuItem(
        value: 'worktree',
        icon: Icons.account_tree_rounded,
        label: '新建 worktree',
      ),
      ccMenuItem(value: 'config', icon: Icons.settings_rounded, label: '项目配置'),
      ccMenuItem(
        value: 'remove',
        icon: Icons.delete_outline_rounded,
        label: '移除项目',
        danger: true,
      ),
    ],
  );

  void _openRepoConfig(ProjectCfg p) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            RepoConfigPage(projectPath: p.path, projectName: p.name),
      ),
    );
  }

  void _openDiff(String path, String name) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiffPage(path: path, name: name),
      ),
    );
  }

  void _openFileBrowser(String path, String name) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileBrowserPage(root: path, name: name),
      ),
    );
  }

  void _openPrs(ProjectCfg p) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GitHubPrPage(githubUrl: p.github, name: p.name),
      ),
    );
  }

  PopupMenuButton<String> _worktreeMenu(
    WorkspaceCfg ws,
    ProjectCfg p,
    Worktree w,
  ) => PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert_rounded, size: 18),
    tooltip: 'worktree 操作',
    onSelected: (v) {
      switch (v) {
        case 'claude':
        case 'codex':
          _openAgent(p, w.path, v, ws.preLaunch);
        case 'supervisor':
          // dir = the worktree path so 总管 runs inside this worktree workspace;
          // project [p] is its owning project (for tree expansion).
          unawaited(_supervisorFlow(p, w.path, ws.preLaunch));
        case 'diff':
          _openDiff(w.path, w.branch.isEmpty ? w.name : w.branch);
        case 'files':
          _openFileBrowser(w.path, w.branch.isEmpty ? w.name : w.branch);
        case 'delete':
          _deleteWorktree(ws, p, w);
      }
    },
    itemBuilder: (_) => [
      ..._agentItems(ws.agent),
      ccMenuItem(
        value: 'supervisor',
        icon: Icons.account_tree_outlined,
        label: '起总管',
      ),
      const PopupMenuDivider(),
      ccMenuItem(value: 'diff', icon: Icons.difference_rounded, label: '看变动'),
      ccMenuItem(value: 'files', icon: Icons.folder_open_rounded, label: '文件'),
      ccMenuItem(
        value: 'delete',
        icon: Icons.delete_outline_rounded,
        label: '删除 worktree',
        danger: true,
      ),
    ],
  );

  bool _secCollapsed(String path, String kind) =>
      Prefs.getBool('ws.sec.$path.$kind');

  void _toggleSec(String path, String kind) {
    final k = 'ws.sec.$path.$kind';
    Prefs.setBool(k, !Prefs.getBool(k));
    setState(() {});
  }

  // _sectionHeader is a collapsible group header (会话 / WORKTREES / 任务) — tap
  // to fold/unfold; state remembered via Prefs.
  Widget _sectionHeader(String path, String kind, String label) {
    final collapsed = _secCollapsed(path, kind);
    return InkWell(
      onTap: () => _toggleSec(path, kind),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 0, 5),
        child: Row(
          children: [
            Icon(
              collapsed
                  ? Icons.chevron_right_rounded
                  : Icons.expand_more_rounded,
              size: 16,
              color: CcColors.muted,
            ),
            const SizedBox(width: 2),
            Icon(_sectionIcon(kind), size: 13, color: CcColors.muted),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontFamily: CcType.mono,
                color: CcColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 各分组(会话 / FILES / WORKTREES / 任务)的代表图标。
  IconData _sectionIcon(String kind) => switch (kind) {
    'sessions' => Icons.terminal_rounded,
    'files' => Icons.folder_outlined,
    'worktrees' => Icons.account_tree_rounded,
    'tasks' => Icons.assignment_outlined,
    _ => Icons.label_outline_rounded,
  };

  Widget _quickBtn(String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 3),
    child: Tooltip(
      message: '起 $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: CcColors.accent.withValues(alpha: 0.14),
            border: Border.all(color: CcColors.accent.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: CcType.mono,
              fontSize: 11.5,
              color: CcColors.accentBright,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );

  // _rowActions surfaces the common 起 claude/codex buttons on hover, keeping the
  // ⋮ menu for everything else.
  Widget _rowActions(
    bool hovered, {
    required VoidCallback onClaude,
    required VoidCallback onCodex,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (hovered) ...[
        _quickBtn('claude', onClaude),
        _quickBtn('codex', onCodex),
      ],
    ],
  );

  // _ctxMenu wraps a row so right-clicking it pops [menu]'s items at the cursor
  // — reusing the PopupMenuButton's itemBuilder/onSelected/onOpened — instead of
  // hanging a ⋮ button on the row. The [menu] widget itself is never rendered.
  Widget _ctxMenu(Widget child, PopupMenuButton<String> menu) =>
      GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (d) async {
          menu.onOpened?.call();
          _lastContextMenuPosition = d.globalPosition;
          final overlay =
              Overlay.of(context).context.findRenderObject() as RenderBox;
          final value = await showMenu<String>(
            context: context,
            position: RelativeRect.fromRect(
              d.globalPosition & const Size(1, 1),
              Offset.zero & overlay.size,
            ),
            items: menu.itemBuilder(context),
          );
          if (value != null && mounted) menu.onSelected?.call(value);
        },
        child: child,
      );

  Offset _fallbackMenuPosition() {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return overlay.localToGlobal(overlay.size.center(Offset.zero));
  }
}

// _DialogHeader is the shared 42px title bar used by the workspace dialogs:
// leading icon + title, optional trailing widgets (refresh button / result
// count), and an always-present close button.
class _DialogHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> trailing;
  const _DialogHeader({
    required this.icon,
    required this.title,
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) => Container(
    height: 42,
    padding: const EdgeInsets.only(left: 14, right: 6),
    decoration: const BoxDecoration(
      color: CcColors.panel,
      border: Border(bottom: BorderSide(color: CcColors.border)),
    ),
    child: Row(
      children: [
        Icon(icon, size: 17, color: CcColors.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        ...trailing,
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    ),
  );
}

// _HoverZone exposes hover state to its builder — used to reveal a row's quick
// actions only while the pointer is over it.
class _HoverZone extends StatefulWidget {
  final Widget Function(bool hovered) builder;
  const _HoverZone({required this.builder});

  @override
  State<_HoverZone> createState() => _HoverZoneState();
}

class _HoverZoneState extends State<_HoverZone> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _h = true),
    onExit: (_) => setState(() => _h = false),
    child: widget.builder(_h),
  );
}
