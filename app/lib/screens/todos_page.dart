import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/todo_models.dart';
import '../local/cli_stub.dart' if (dart.library.io) '../local/cli.dart';
import '../local/config.dart';
import '../local/identity.dart';
import '../local/local_bus.dart';
import '../local/prefs.dart';
import '../local/session_overview.dart';
import '../local/todo_assignment_candidates.dart';
import '../local/todo_materialize.dart';
import '../local/todo_permissions.dart';
import '../local/todo_store.dart';
import '../local/todo_workspace_scope.dart';
import '../remote/remote_client.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/markdown_lite_editor.dart';
import '../widgets/todo_attachment_thumb.dart';
import '../widgets/todo_card.dart';
import '../widgets/todo_property_controls.dart';
import 'todo_detail_view.dart';

// The desktop/wide breakpoint (matches RemoteWorkspacePage's dual-pane vs
// single-column threshold) — below this, TodosPage drops the board/list
// split entirely and switches to a full-screen mobile card stream.
const double _wideBreakpoint = 720;

double todoMemberRolePillMaxWidth(
  BoxConstraints constraints, {
  double preferred = 128,
  double maxFraction = 1,
}) {
  final maxWidth = constraints.maxWidth;
  if (!maxWidth.isFinite || maxWidth <= 0) return preferred;
  final available = maxWidth * maxFraction.clamp(0, 1);
  return available < preferred ? available : preferred;
}

String todoMemberPrimaryLabel({
  required String identity,
  required String displayName,
  required String selfIdentity,
}) {
  final id = cleanedIdentity(identity);
  final name = displayName.trim();
  final label = name.isEmpty ? id : name;
  if (label.isEmpty) return '';
  return sameIdentity(id, selfIdentity) ? '$label（我）' : label;
}

Set<String> normalizedOnlineTodoMemberIds(Iterable<OnlineUser> users) => {
  for (final user in users)
    if (user.online && identityLookupKey(user.identity).isNotEmpty)
      identityLookupKey(user.identity),
};

Map<String, String> todoMemberDisplayNames({
  required Iterable<ProjectMember> projectMembers,
  required Iterable<OrganizationMember> organizationMembers,
}) {
  final names = <String, String>{};

  void rememberFallback(String raw, String name) {
    final id = identityLookupKey(raw);
    final label = name.trim();
    if (id.isEmpty || label.isEmpty) return;
    names.putIfAbsent(id, () => label);
  }

  void rememberPreferred(String raw, String name) {
    final id = identityLookupKey(raw);
    final label = name.trim();
    if (id.isEmpty || label.isEmpty) return;
    names[id] = label;
  }

  for (final member in organizationMembers) {
    rememberFallback(member.identity, member.displayName);
  }
  for (final member in projectMembers) {
    rememberPreferred(member.identity, member.displayName);
  }
  return names;
}

double todoDialogWidth(
  Size screenSize, {
  double preferred = 440,
  double horizontalInset = 16,
}) {
  final available = screenSize.width - horizontalInset * 2;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

double todoMenuMaxHeight(
  Size screenSize, {
  double preferred = 320,
  double minHeight = 160,
  double maxFraction = 0.58,
}) {
  final available = screenSize.height * maxFraction.clamp(0, 1);
  if (!available.isFinite || available <= 0) return preferred;
  final capped = available < preferred ? available : preferred;
  return capped < minHeight ? minHeight : capped;
}

String initialTodoAssignMode({
  required bool hasSessionCards,
  required bool remoteReady,
}) {
  if (hasSessionCards) return 'existing';
  if (remoteReady) return 'new';
  return 'member';
}

bool todoAssignNewSelectionValid({
  required String? workspace,
  required String? project,
  required Iterable<String> workspaceNames,
  required Iterable<String> projectNames,
}) =>
    workspace != null &&
    project != null &&
    workspaceNames.contains(workspace) &&
    projectNames.contains(project);

// _BoardColumnDef drives both the kanban board's columns and the mobile
// card stream's collapsible groups, so they always agree on column meaning.
// One status = one column now (the real Linear layout this board was always
// modeled on) — statuses is a singleton set purely so the rest of the board
// code (DragTarget.onWillAcceptWithDetails, the mobile grouping filter) can
// stay written against "does this column contain status X" without special-
// casing the 1:1 case.
typedef _BoardColumnDef = ({
  String title,
  Set<TodoStatus> statuses,
  TodoStatus dropStatus,
});

// Column headers stay in Linear's own English names (matching this board's
// pre-existing convention — the filter chips above it use todoStatusLabel's
// Chinese instead). Order mirrors TodoStatus.values' declaration order in
// todo_models.dart (Triage first as the "待分诊" inbox, per Linear's real
// board layout) so there's one source of truth for "what order do the 8
// statuses go in".
const Map<TodoStatus, String> _boardColumnTitles = {
  TodoStatus.triage: 'Triage',
  TodoStatus.backlog: 'Backlog',
  TodoStatus.todo: 'Todo',
  TodoStatus.inProgress: 'In Progress',
  TodoStatus.inReview: 'In Review',
  TodoStatus.done: 'Done',
  TodoStatus.canceled: 'Canceled',
  TodoStatus.duplicate: 'Duplicate',
};

final List<_BoardColumnDef> _boardColumnDefs = [
  for (final s in TodoStatus.values)
    (title: _boardColumnTitles[s]!, statuses: {s}, dropStatus: s),
];

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

// TodosPage is the top-level 待办 destination: a filterable list (left) + the
// selected todo's detail/edit panel (right), mirroring HandoffsPage's split
// layout. All scope/status/project filtering happens in memory over
// TodoStore.all — no extra network requests fire on filter changes.
class TodosPage extends StatefulWidget {
  final RelayClient client;
  final AppConfig config;
  final Me me;
  final TodoStore store;
  final SessionOverviewStore overviewStore;
  // onOpenSession backs the detail view's "打开/恢复会话" button: switches
  // the host's top-level nav to the 工作区 tab before focusing the session
  // (mirrors main.dart's _openSessionInWorkspace, already used the same way
  // by SessionOverviewPage) — TodosPage is a nav sibling of 工作区, not
  // inside it, so opening a session here needs that extra tab switch.
  final void Function(String sid)? onOpenSession;

  const TodosPage({
    super.key,
    required this.client,
    required this.config,
    required this.me,
    required this.store,
    required this.overviewStore,
    this.onOpenSession,
  });

  @override
  State<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends State<TodosPage> {
  String _scope = 'personal'; // personal | team | all
  String _teamSource = 'relay'; // relay | linear
  final Set<TodoStatus> _statusFilter = {};
  String? _projectFilter; // project id, only meaningful when _scope == 'team'
  // _groupFilter/_groups back the 分组 dropdown next to 项目: null = 全部.
  // _groups is only populated when the current scope has a well-defined
  // single group-listing scope (personal, or team with one project picked —
  // see ListTodoGroups' scoping) since there's no "union of every project"
  // group listing on the relay; scope=team with no project picked, or
  // scope=all, just show no group filter at all rather than a misleading one.
  String? _groupFilter;
  List<String> _groups = [];
  int _groupsLoadSeq = 0;
  Todo? _selected;
  final Set<String> _selectedTodoIds = {};
  bool _deletingSelectedTodos = false;
  bool _boardView = true; // board is the default, Linear-flavored view
  final Set<String> _collapsedMobileGroups = {};
  final _detailKey = GlobalKey<TodoDetailViewState>();
  String _linearTeamKey = '';
  String _linearProjectId = '';
  // Relay project to import Linear todos INTO — they become team todos, visible
  // under the relay team「全部项目」view and assignable to members. Empty = import
  // as personal todos (owner-only, invisible in the team view — the reason
  // Linear imports "disappeared" from a relay team before this option existed).
  String _linearImportProjectId = '';
  String? _linearTokenOverride;
  bool _importingLinear = false;
  int _accountGeneration = 0;

  RelayClient get _client => widget.client;
  AppConfig get _cfg => widget.config;
  Me get _me => widget.me;
  // widget.me is fetched once at login; _myProjects is a live copy re-pulled on
  // refresh so a relay project created after launch (via the 项目 page) appears
  // in the project filter + the Linear import target without an app restart.
  late List<ProjectRole> _myProjects = widget.me.projects;
  TodoStore get _store => widget.store;
  bool get _canUseLocalCli =>
      !kIsWeb &&
      {
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform);
  SessionOverviewStore get _overview => widget.overviewStore;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    // onComment fires on todo.comment_created — reload the detail view's
    // comment list if that's the todo currently open (TodoStore itself
    // doesn't model comments, it just flags which todo needs a reload).
    _store.onComment = _onComment;
    _loadLinearImportPrefs();
    _loadGroups();
    _refreshMyProjects();
    // Local Prefs render instantly above; then pull the identity's synced view
    // so this device shows the same board as the user's other devices (手机=电脑).
    _pullTodoView();
  }

  // --- board view config sync (手机=电脑) ---------------------------------
  //
  // The board-defining view state — scope, team source (relay/linear), the
  // Linear team/project keys, and the picked relay project — has always lived in
  // local Prefs (per-device, unsynced). That's why the desktop's Linear board
  // never appeared on the phone: same identity + same todos on the relay, but
  // the phone had no copy of "which board" to reconstruct. _pushTodoView mirrors
  // the current selection to a per-identity relay setting so this user's other
  // devices open the identical board; _pullTodoView applies it on load. Local
  // Prefs stay the instant-render cache; the cloud value is the cross-device
  // source of truth (last write wins, stamped server-side).
  static const _todoViewKey = 'todo.view';
  // Signature of the last snapshot pushed to the relay, so re-selecting the
  // current tab (or applying what we just pulled) skips the PUT instead of
  // firing one per SegmentedButton tap.
  String? _lastPushedView;

  Map<String, dynamic> _todoViewToMap() => {
    'scope': _scope,
    'teamSource': _teamSource,
    'linearTeamKey': _linearTeamKey,
    'linearProjectId': _linearProjectId,
    if (_projectFilter != null) 'projectFilter': _projectFilter,
  };

  String get _viewSignature =>
      '$_scope|$_teamSource|$_linearTeamKey|$_linearProjectId|$_projectFilter';

  // _mirrorViewToPrefs keeps the local Prefs cache in lockstep with the current
  // view so a cold start (or offline) renders the last-known board instantly,
  // before the synced cloud value arrives.
  void _mirrorViewToPrefs() {
    Prefs.setString('todo.team.source', _teamSource);
    Prefs.setString('todo.linear.teamKey', _linearTeamKey);
    Prefs.setString('todo.linear.projectId', _linearProjectId);
  }

  void _pushTodoView() {
    _mirrorViewToPrefs();
    final sig = _viewSignature;
    if (sig == _lastPushedView) return; // nothing actually changed → no PUT
    _lastPushedView = sig;
    _client.putSetting(_todoViewKey, _todoViewToMap()).catchError((_) {});
  }

  Future<void> _pullTodoView() async {
    final generation = _accountGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    Map<String, dynamic>? m;
    try {
      m = await client.getSetting(_todoViewKey);
    } catch (_) {
      return; // best-effort: keep the local view
    }
    if (m == null ||
        !_isCurrentAccountContext(
          generation,
          client,
          relayUrl,
          token,
          identity,
        )) {
      return;
    }
    final before = _viewSignature;
    final scope = m['scope'];
    final source = m['teamSource'];
    final teamKey = m['linearTeamKey'];
    final projectId = m['linearProjectId'];
    final projectFilter = m['projectFilter'];
    setState(() {
      if (scope is String &&
          const {'personal', 'team', 'all'}.contains(scope)) {
        _scope = scope;
      }
      if (source is String && const {'relay', 'linear'}.contains(source)) {
        _teamSource = source;
      }
      if (teamKey is String) _linearTeamKey = teamKey;
      if (projectId is String) _linearProjectId = projectId;
      _projectFilter = projectFilter is String
          ? activeTodoProjectFilter(projectFilter, _myProjects)
          : null;
      _groupFilter = null;
    });
    _mirrorViewToPrefs();
    _lastPushedView = _viewSignature; // don't PUT back what we just pulled
    // Only the group list depends on scope/source/project — reload it only when
    // the pulled view actually differs from what initState already loaded.
    if (_viewSignature != before) _loadGroups();
  }

  // _loadGroups refreshes the 分组 filter's option list for the current
  // scope/project — see the _groups field doc for which scopes actually get
  // one. Best-effort: a failed fetch just leaves the filter empty rather than
  // surfacing an error, since it's a secondary affordance.
  Future<void> _loadGroups() async {
    final seq = ++_groupsLoadSeq;
    final generation = _accountGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    String? projectId;
    if (_scope == 'personal') {
      projectId = null;
    } else if (_scope == 'team' &&
        _teamSource == 'relay' &&
        _projectFilter != null) {
      projectId = _projectFilter;
    } else {
      if (_isCurrentAccountContext(
            generation,
            client,
            relayUrl,
            token,
            identity,
          ) &&
          seq == _groupsLoadSeq) {
        setState(() {
          _groups = [];
          _groupFilter = null;
        });
      }
      return;
    }
    try {
      final groups = await client.todoGroups(projectId: projectId);
      if (_isCurrentAccountContext(
            generation,
            client,
            relayUrl,
            token,
            identity,
          ) &&
          seq == _groupsLoadSeq) {
        setState(() {
          _groups = groups;
          _groupFilter = activeTodoGroupFilter(_groupFilter, groups);
        });
      }
    } catch (_) {
      if (_isCurrentAccountContext(
            generation,
            client,
            relayUrl,
            token,
            identity,
          ) &&
          seq == _groupsLoadSeq) {
        setState(() {
          _groups = [];
          _groupFilter = null;
        });
      }
    }
  }

  void _loadLinearImportPrefs() {
    _linearTeamKey = Prefs.getString('todo.linear.teamKey', def: '');
    _linearProjectId = Prefs.getString('todo.linear.projectId', def: '');
    _linearImportProjectId = Prefs.getString(
      'todo.linear.importProjectId',
      def: '',
    );
    _teamSource = Prefs.getString('todo.team.source', def: 'relay') == 'linear'
        ? 'linear'
        : 'relay';
  }

  void _refresh() {
    _store.refresh();
    _loadGroups();
    _refreshMyProjects();
  }

  // Best-effort re-pull of /v1/me so newly-created relay projects show up in the
  // project filter + the Linear import target. Keeps the old list on error.
  Future<void> _refreshMyProjects() async {
    final generation = _accountGeneration;
    final client = widget.client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    try {
      final m = await client.me();
      if (mounted &&
          _isCurrentAccountContext(
            generation,
            client,
            relayUrl,
            token,
            identity,
          )) {
        var projectFilterChanged = false;
        setState(() {
          _myProjects = m.projects;
          final activeProjectFilter = activeTodoProjectFilter(
            _projectFilter,
            _myProjects,
          );
          projectFilterChanged = activeProjectFilter != _projectFilter;
          if (projectFilterChanged) {
            _projectFilter = activeProjectFilter;
            _groupFilter = null;
          }
        });
        if (projectFilterChanged) {
          _loadGroups();
          _pushTodoView();
        }
      }
    } catch (_) {
      /* keep the login-time list */
    }
  }

  // _summonTodoAssistant spawns a dedicated 待办助手 session (claude/codex) in a
  // chosen project. It boots with the todoAssistant persona injected
  // (TerminalSession._todoInstructions via kind 'todo:<agent>'), so it can
  // generate/manage todos with the `cc-handoff todo` CLI against the same relay
  // this board reads — changes then sync live back here and to the phone.
  // Desktop-only: spawning needs the host app that owns the local bus
  // (overviewStore.spawn errors out when no spawnHandler is registered).
  Future<void> _summonTodoAssistant() async {
    final workspaces = _cfg.workspaces;
    if (workspaces.isEmpty) {
      snack(context, '没有可用的 workspace/项目');
      return;
    }
    List<ProjectCfg> projsFor(String w) {
      final m = workspaces.where((e) => e.name == w);
      return m.isEmpty ? const [] : m.first.projects;
    }

    var ws = workspaces.first.name;
    String? proj = projsFor(ws).isNotEmpty ? projsFor(ws).first.name : null;
    var agent = 'claude';
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('召唤待办助手'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '起一个专门帮你生成/管理待办的会话,已注入待办助手人格,可直接用 '
                  'cc-handoff todo 在同一 relay 上增删改;改动会同步回看板和手机。',
                  style: TextStyle(
                    color: CcColors.muted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButton<String>(
                  isExpanded: true,
                  menuMaxHeight: todoMenuMaxHeight(MediaQuery.sizeOf(ctx)),
                  value: ws,
                  items: workspaces
                      .map(
                        (w) => DropdownMenuItem(
                          value: w.name,
                          child: Text(
                            w.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setLocal(() {
                    ws = v ?? ws;
                    final ps = projsFor(ws);
                    proj = ps.isNotEmpty ? ps.first.name : null;
                  }),
                ),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  isExpanded: true,
                  menuMaxHeight: todoMenuMaxHeight(MediaQuery.sizeOf(ctx)),
                  hint: const Text('project'),
                  value: proj,
                  items: projsFor(ws)
                      .map(
                        (p) => DropdownMenuItem(
                          value: p.name,
                          child: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setLocal(() => proj = v),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'claude', label: Text('Claude')),
                    ButtonSegment(value: 'codex', label: Text('Codex')),
                  ],
                  selected: {agent},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setLocal(() => agent = s.first),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: proj == null ? null : () => Navigator.pop(ctx, true),
              child: const Text('召唤'),
            ),
          ],
        ),
      ),
    );
    if (go != true || proj == null) return;
    if (!mounted) return;
    final selectedProject = projsFor(
      ws,
    ).where((p) => p.name == proj).firstOrNull;
    final (sid, err) = await _overview.spawn(
      workspace: ws,
      project: proj!,
      kind: 'todo:$agent',
      projectId: selectedProject?.projectId,
    );
    if (!mounted) return;
    if (sid == null) {
      snack(context, '召唤失败: ${err ?? "未知错误"}');
      return;
    }
    _overview.dispatch(
      LocalMsg(
        '',
        sid,
        '你是这个看板的待办助手。请先运行 `cc-handoff todo list` 查看当前待办并简要汇报,'
            '然后等我的指示。',
        true,
      ),
    );
    snack(context, '已召唤待办助手');
    widget.onOpenSession?.call(sid);
  }

  // _importFromLinear shells `cc-handoff todo import-linear` using the Todo
  // page's own Linear source settings. Linear team/project is a remote source
  // scope, mutually exclusive with relay Project filtering; local workspace
  // binding remains per-todo and is not changed by import.
  Future<void> _importFromLinear() async {
    if (_importingLinear) return;
    final teamKey = _linearTeamKey.trim();
    if (teamKey.isEmpty) {
      if (mounted) snack(context, '先配置 Linear team_key');
      return;
    }
    final linearProjectId = _linearProjectId.trim();
    if (linearProjectId.isNotEmpty && !_uuidPattern.hasMatch(linearProjectId)) {
      if (mounted) snack(context, 'Linear project_id 必须是完整 UUID，当前值可能少了一位');
      return;
    }
    setState(() => _importingLinear = true);
    try {
      final out = await Cli.todoImportLinear(
        teamKey: teamKey,
        linearProjectId: linearProjectId,
        // Relay project to land the todos in (empty = personal). This is what
        // makes imported Linear todos show up under 团队 / Relay instead of
        // silently becoming personal (owner-only) todos.
        projectId: _linearImportProjectId,
      );
      if (mounted) snack(context, out.isNotEmpty ? out : '已从 Linear 导入');
      await _store.refresh();
      if (mounted) {
        setState(() {
          _scope = 'team';
          if (_linearImportProjectId.isNotEmpty) {
            // Imported into a relay team project → show the team/relay view
            // filtered to it (where these todos now live).
            _teamSource = 'relay';
            _projectFilter = _linearImportProjectId;
          } else {
            // Personal import → the Linear-source view (team/relay hides them).
            _teamSource = 'linear';
            _projectFilter = null;
          }
          _groupFilter = null;
          _statusFilter.clear();
        });
        _loadGroups();
        _pushTodoView();
      }
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _importingLinear = false);
    }
  }

  Future<void> _linearHelpDialog() {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Linear 导入配置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_canUseLocalCli)
                const _HelpText('1. 在用户配置里设置 linear_personal_token。')
              else
                const _HelpText('1. 手机/Web 端只切换查看来源；导入需在桌面端执行。'),
              const _HelpText('2. 在待办页的 Linear 配置里填 team_key 和 project_id。'),
              const _HelpText('3. team_key 填 issue 编号前缀，例如 INF-502 填 INF。'),
              const _HelpText(
                '4. project_id 是 Linear Project UUID；不填会看整个 team。',
              ),
              const _HelpText(
                '5. Web 版 Linear 里打开项目，按 Cmd/Ctrl+K，搜索 Copy model UUID。',
              ),
              const _HelpText('6. 团队视图可在 Relay 项目和 Linear 项目之间切换；两者互斥。'),
              const SizedBox(height: 10),
              Text(
                '导入时会按 source_ref(linear:<编号>) 幂等更新；Linear project 只作为远程来源筛选，不会覆盖每条 todo 的本地 workspace/repo 绑定。',
                style: TextStyle(color: CcColors.muted, height: 1.35),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _linearConfigDialog() async {
    final tokenCtl = TextEditingController(
      text: _linearTokenOverride ?? _cfg.linearToken,
    );
    final teamCtl = TextEditingController(text: _linearTeamKey);
    final projectCtl = TextEditingController(text: _linearProjectId);
    var importPid = _linearImportProjectId;
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final dialogWidth = todoDialogWidth(MediaQuery.sizeOf(ctx));
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            title: const Text('Linear 团队 / 项目'),
            content: SizedBox(
              width: dialogWidth,
              child: StatefulBuilder(
                builder: (ctx, setLocal) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_canUseLocalCli) ...[
                      TextField(
                        controller: tokenCtl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'linear_personal_token',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    TextField(
                      controller: teamCtl,
                      decoration: const InputDecoration(
                        labelText: '团队 team_key',
                        hintText: '例如 INF',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: projectCtl,
                      decoration: const InputDecoration(
                        labelText: '项目 project_id（Linear Project UUID，可选）',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Relay project to import INTO. Empty = 个人待办 (owner-only, hidden
                    // in the team view); picking a team project makes the imported
                    // Linear todos show under 团队 / 全部项目 and be assignable.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '导入到 relay 项目',
                        style: TextStyle(color: CcColors.muted, fontSize: 12),
                      ),
                    ),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: _myProjects.any((p) => p.id == importPid)
                          ? importPid
                          : '',
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('个人待办（仅自己可见）'),
                        ),
                        for (final p in _myProjects)
                          DropdownMenuItem(
                            value: p.id,
                            child: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => importPid = v ?? ''),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
      if (saved != true) return;
      if (!mounted) return;
      final token = tokenCtl.text.trim();
      final team = teamCtl.text.trim();
      final project = projectCtl.text.trim();
      if (project.isNotEmpty && !_uuidPattern.hasMatch(project)) {
        snack(context, 'Linear project_id 必须是完整 UUID，当前值可能少了一位');
        return;
      }
      if (_canUseLocalCli) {
        await Cli.configSet(linearToken: token);
      }
      _linearTeamKey = team;
      _linearProjectId = project;
      _linearTokenOverride = token;
      _linearImportProjectId = importPid;
      Prefs.setString('todo.linear.importProjectId', importPid);
      // Persists teamKey/projectId to local Prefs AND syncs the view to the
      // relay so the phone reproduces this exact Linear board.
      _pushTodoView();
      if (mounted) {
        setState(() {});
        snack(context, 'Linear 导入配置已保存');
      }
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    } finally {
      tokenCtl.dispose();
      teamCtl.dispose();
      projectCtl.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant TodosPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      if (identical(oldWidget.store.onComment, _onComment)) {
        oldWidget.store.onComment = null;
      }
      widget.store.addListener(_onStoreChanged);
      widget.store.onComment = _onComment;
    }
    if (_todoAccountContextChanged(oldWidget)) {
      _resetForAccountContext();
      _loadGroups();
      _refreshMyProjects();
      _pullTodoView();
    }
  }

  bool _todoAccountContextChanged(TodosPage oldWidget) =>
      oldWidget.client != widget.client ||
      oldWidget.store != widget.store ||
      oldWidget.config.relayUrl != _cfg.relayUrl ||
      oldWidget.config.token != _cfg.token ||
      oldWidget.config.identity != _cfg.identity ||
      oldWidget.me.identity != _me.identity;

  bool _isCurrentAccountContext(
    int generation,
    RelayClient client,
    String relayUrl,
    String token,
    String identity,
  ) =>
      mounted &&
      generation == _accountGeneration &&
      identical(client, _client) &&
      _cfg.relayUrl == relayUrl &&
      _cfg.token == token &&
      _cfg.identity == identity;

  void _resetForAccountContext() {
    _accountGeneration++;
    _groupsLoadSeq++;
    setState(() {
      _scope = 'personal';
      _teamSource = 'relay';
      _statusFilter.clear();
      _projectFilter = null;
      _groupFilter = null;
      _groups = const [];
      _selected = null;
      _selectedTodoIds.clear();
      _deletingSelectedTodos = false;
      _myProjects = widget.me.projects;
      _linearTeamKey = '';
      _linearProjectId = '';
      _linearImportProjectId = '';
      _linearTokenOverride = null;
      _importingLinear = false;
      _lastPushedView = null;
    });
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    if (identical(_store.onComment, _onComment)) _store.onComment = null;
    super.dispose();
  }

  void _onComment(String todoId) {
    if (_selected?.id == todoId) _detailKey.currentState?.reloadComments();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {
      final sel = _selected;
      if (sel != null) {
        final match = _store.all.where((t) => t.id == sel.id);
        _selected = match.isEmpty ? null : match.first;
      }
      _selectedTodoIds.removeWhere((id) => !_store.all.any((t) => t.id == id));
    });
  }

  bool get _selectingTodos => _selectedTodoIds.isNotEmpty;
  List<ProjectRole> get _editableProjects =>
      _myProjects.where((p) => canCreateProjectTodo(p, _me)).toList();

  TodoAccess _accessFor(Todo t) => todoAccessFor(t, _me);
  bool get _hasDeletableFilteredTodo =>
      _filtered.any((t) => _accessFor(t).canDelete);

  void _toggleTodoSelection(Todo t) {
    if (!_accessFor(t).canDelete) {
      snack(context, '你对这条待办没有删除权限');
      return;
    }
    setState(() {
      if (!_selectedTodoIds.add(t.id)) {
        _selectedTodoIds.remove(t.id);
      }
    });
  }

  Future<void> _deleteSelectedTodos() async {
    if (_deletingSelectedTodos) return;
    final generation = _accountGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final ids = _selectedTodoIds.where((id) {
      final matches = _store.all.where((t) => t.id == id);
      return matches.isNotEmpty && _accessFor(matches.first).canDelete;
    }).toList();
    if (ids.isEmpty) return;
    setState(() => _deletingSelectedTodos = true);
    try {
      final ok = await confirm(
        context,
        '删除后不可恢复，附件和评论也会一起删除。',
        title: '删除 ${ids.length} 个待办？',
        okLabel: '删除',
      );
      if (ok != true ||
          !_isCurrentAccountContext(
            generation,
            client,
            relayUrl,
            token,
            identity,
          )) {
        return;
      }
      var failed = 0;
      for (final id in ids) {
        if (!_isCurrentAccountContext(
          generation,
          client,
          relayUrl,
          token,
          identity,
        )) {
          return;
        }
        try {
          await client.deleteTodo(id);
        } catch (_) {
          failed++;
        }
      }
      if (!_isCurrentAccountContext(
        generation,
        client,
        relayUrl,
        token,
        identity,
      )) {
        return;
      }
      setState(() {
        _selectedTodoIds.clear();
        if (_selected != null && ids.contains(_selected!.id)) _selected = null;
      });
      await _store.refresh();
      if (!mounted) return;
      if (_isCurrentAccountContext(
        generation,
        client,
        relayUrl,
        token,
        identity,
      )) {
        snack(
          context,
          failed == 0
              ? '已删除 ${ids.length} 个待办'
              : '已删除 ${ids.length - failed} 个，失败 $failed 个',
        );
      }
    } finally {
      if (_isCurrentAccountContext(
        generation,
        client,
        relayUrl,
        token,
        identity,
      )) {
        setState(() => _deletingSelectedTodos = false);
      }
    }
  }

  List<Todo> get _filtered {
    final items = _store.all.where((t) {
      if (!_matchesCurrentScope(t)) return false;
      if (_statusFilter.isNotEmpty && !_statusFilter.contains(t.status)) {
        return false;
      }
      if (_groupFilter != null && t.groupName != _groupFilter) return false;
      return true;
    }).toList();
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return items;
  }

  bool _matchesCurrentScope(Todo t) {
    if (_scope == 'personal') return t.isPersonal;
    if (_scope != 'team') return true;
    if (_teamSource == 'linear') return _matchesLinearSource(t);
    if (t.isPersonal) return false;
    return _projectFilter == null || t.projectId == _projectFilter;
  }

  bool _matchesLinearSource(Todo t) {
    if (!t.isLinear) return false;
    final team = _linearTeamKey.trim();
    final project = _linearProjectId.trim();
    if (team.isEmpty) return false;
    final sourceTeam = (t.sourceTeamKey ?? '').trim();
    final ref = (t.sourceRef ?? '').trim();
    if (sourceTeam.isNotEmpty) {
      if (sourceTeam.toLowerCase() != team.toLowerCase()) {
        return false;
      }
    } else if (!ref.toLowerCase().startsWith('linear:${team.toLowerCase()}-')) {
      return false;
    }
    if (project.isNotEmpty && (t.sourceProjectId ?? '').trim() != project) {
      return false;
    }
    return true;
  }

  bool get _hasTodosInCurrentScope => _store.all.any(_matchesCurrentScope);

  bool get _hasActiveTodoFilters =>
      _statusFilter.isNotEmpty || _groupFilter != null;

  String get _currentProjectFilterName {
    final id = activeTodoProjectFilter(_projectFilter, _myProjects);
    if (id == null) return '';
    for (final project in _myProjects) {
      if (project.id == id) return project.name.trim();
    }
    return '';
  }

  // _projectName resolves a team todo's project id to its display name for
  // TodoCard's tag row — TodoCard itself stays decoupled from Me so it's
  // reusable from contexts (e.g. a future workspace sidebar) that don't
  // necessarily have the full Me/projects list in scope.
  String? _projectName(Todo t) {
    if (t.projectId == null) return null;
    for (final p in _myProjects) {
      if (p.id == t.projectId) return p.name;
    }
    return null;
  }

  Color _statusColor(TodoStatus s) => todoStatusColor(s);

  Future<void> _createDialog() async {
    final generation = _accountGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    bool isCurrentContext() =>
        _isCurrentAccountContext(generation, client, relayUrl, token, identity);
    final editableProjects = _editableProjects;
    final initialProjectId = editableProjects.any((p) => p.id == _projectFilter)
        ? _projectFilter
        : null;
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _QuickCreateDialog(
        client: client,
        me: _me,
        projects: editableProjects,
        isCurrentContext: isCurrentContext,
        initialScope:
            _scope == 'team' &&
                _teamSource == 'relay' &&
                editableProjects.isNotEmpty
            ? 'team'
            : 'personal',
        initialProjectId: _scope == 'team' && _teamSource == 'relay'
            ? initialProjectId
            : null,
        groups: _groups,
      ),
    );
    if (created == true) {
      if (!mounted) return;
      if (!isCurrentContext()) return;
      await _store.refresh();
      if (!isCurrentContext()) return;
      await _loadGroups();
    }
  }

  // _dropStatus is the board's drag-to-change-status action. The relay
  // broadcasts the update over SSE, which TodoStore already listens to, so
  // there's no local optimistic-update bookkeeping to do here beyond
  // surfacing a failure.
  Future<void> _dropStatus(Todo t, TodoStatus status) async {
    if (t.status == status) return;
    if (!_accessFor(t).canEdit) {
      snack(context, '你对这条待办只有只读权限');
      return;
    }
    try {
      await _client.setTodoStatus(t.id, status);
    } catch (e) {
      if (mounted) snack(context, '更新状态失败: ${errorText(e)}');
    }
  }

  Future<void> _assignDialog(Todo t) async {
    if (!_accessFor(t).canAssign) {
      snack(context, '你对这条待办没有指派权限');
      return;
    }
    final generation = _accountGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    bool isCurrentContext() =>
        _isCurrentAccountContext(generation, client, relayUrl, token, identity);
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _AssignTodoDialog(
        todo: t,
        client: client,
        overviewStore: _overview,
        config: _cfg,
        isCurrentContext: isCurrentContext,
      ),
    );
    if (changed == true) {
      if (!mounted) return;
      if (!isCurrentContext()) return;
      await _store.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= _wideBreakpoint;
    if (!wide) return _mobileBody();

    final contentPane = Column(
      children: [
        _filterHeader(wide: true),
        Expanded(child: _boardView ? _boardPane() : _buildList()),
      ],
    );

    if (_boardView) {
      return Row(
        children: [
          Expanded(child: contentPane),
          if (_selected != null) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: 380, child: _rightPane()),
          ],
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 360, child: contentPane),
        const VerticalDivider(width: 1),
        Expanded(child: _rightPane()),
      ],
    );
  }

  // _filterHeader is the title/scope/project/status filter chrome shared by
  // the board view, the list view, and the mobile card stream — only the
  // board/list toggle button is conditional (there's no board on a phone).
  Widget _filterHeader({required bool wide}) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
        child: Row(
          children: [
            const Icon(
              Icons.checklist_rounded,
              size: 20,
              color: CcColors.accent,
            ),
            const SizedBox(width: 8),
            const Text(
              '待办',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (_selectingTodos) ...[
              Text(
                '已选 ${_selectedTodoIds.length}',
                style: const TextStyle(
                  color: CcColors.muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              IconButton(
                icon: _deletingSelectedTodos
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline_rounded, size: 18),
                tooltip: '删除选中待办',
                onPressed: _deletingSelectedTodos ? null : _deleteSelectedTodos,
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: '取消选择',
                onPressed: _deletingSelectedTodos
                    ? null
                    : () => setState(_selectedTodoIds.clear),
              ),
            ] else
              IconButton(
                icon: const Icon(Icons.checklist_rtl_rounded, size: 18),
                tooltip: '选择当前筛选结果',
                onPressed: !_hasDeletableFilteredTodo
                    ? null
                    : () => setState(
                        () => _selectedTodoIds.addAll(
                          _filtered
                              .where((t) => _accessFor(t).canDelete)
                              .map((t) => t.id),
                        ),
                      ),
              ),
            if (wide)
              IconButton(
                icon: Icon(
                  _boardView
                      ? Icons.view_list_rounded
                      : Icons.view_kanban_rounded,
                  size: 18,
                ),
                tooltip: _boardView ? '切换到列表视图' : '切换到看板视图',
                onPressed: () => setState(() => _boardView = !_boardView),
              ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              tooltip: '刷新',
              onPressed: _refresh,
            ),
            if (_canUseLocalCli)
              IconButton(
                icon: const Icon(Icons.smart_toy_outlined, size: 18),
                tooltip: '召唤待办助手',
                onPressed: _summonTodoAssistant,
              ),
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: '新建待办',
              onPressed: _createDialog,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'personal', label: Text('个人')),
            ButtonSegment(value: 'team', label: Text('团队')),
            ButtonSegment(value: 'all', label: Text('全部')),
          ],
          selected: {_scope},
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onSelectionChanged: (s) {
            final nextScope = s.first;
            setState(() {
              _scope = nextScope;
              if (_scope != 'team') _projectFilter = null;
              _groupFilter = null;
            });
            _loadGroups();
            _pushTodoView();
          },
        ),
      ),
      if (_scope == 'team')
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: _teamSourceControls(wide: wide),
        ),
      if (_groups.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: _groupControls(wide: wide),
        ),
      if (_scope == 'team' && _teamSource == 'linear')
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: _linearImportControls(wide: wide),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        child: scrollableBar(
          scrolling: [
            for (final s in TodoStatus.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _statusChip(s),
              ),
          ],
        ),
      ),
      const Divider(height: 12),
    ],
  );

  Widget _teamSourceControls({required bool wide}) {
    final projectFilterValue = activeTodoProjectFilter(
      _projectFilter,
      _myProjects,
    );
    final controls = <Widget>[
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'relay', label: Text('Relay')),
          ButtonSegment(value: 'linear', label: Text('Linear')),
        ],
        selected: {_teamSource},
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onSelectionChanged: (s) {
          final source = s.first;
          setState(() {
            _teamSource = source;
            _projectFilter = null;
            _groupFilter = null;
          });
          _loadGroups();
          _pushTodoView();
        },
      ),
      const SizedBox(width: 14),
      if (_teamSource == 'relay') ...[
        const Text(
          '项目',
          style: TextStyle(color: CcColors.muted, fontSize: 12.5),
        ),
        const SizedBox(width: 8),
        DropdownButton<String?>(
          value: projectFilterValue,
          hint: const Text('全部项目'),
          menuMaxHeight: todoMenuMaxHeight(MediaQuery.sizeOf(context)),
          underline: const SizedBox(),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('全部项目')),
            ..._myProjects.map(
              (p) => DropdownMenuItem<String?>(
                value: p.id,
                child: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          onChanged: (v) {
            setState(() {
              _projectFilter = v;
              _groupFilter = null;
            });
            _loadGroups();
            _pushTodoView();
          },
        ),
      ] else ...[
        const Text(
          'Linear',
          style: TextStyle(color: CcColors.muted, fontSize: 12.5),
        ),
        const SizedBox(width: 10),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 420 : 220),
          child: Text(
            _linearTeamKey.trim().isEmpty
                ? '未配置团队'
                : _linearProjectId.trim().isEmpty
                ? '${_linearTeamKey.trim()} / 全部项目'
                : '${_linearTeamKey.trim()} / ${_linearProjectId.trim()}',
            style: const TextStyle(color: CcColors.subtle, fontSize: 12.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: _linearConfigDialog,
          icon: const Icon(Icons.tune_rounded, size: 16),
          label: const Text('切换团队/项目'),
        ),
        if (_linearProjectId.trim().isNotEmpty) ...[
          const SizedBox(width: 4),
          TextButton(
            onPressed: () {
              setState(() {
                _linearProjectId = '';
                _groupFilter = null;
              });
              _loadGroups();
              _pushTodoView();
            },
            child: const Text('全部 Linear'),
          ),
        ],
      ],
    ];
    if (!wide) {
      return scrollableBar(scrolling: controls);
    }
    return Row(children: [...controls, const Spacer()]);
  }

  Widget _linearImportControls({required bool wide}) {
    final importTooltip = !_canUseLocalCli
        ? '桌面端可从 Linear 导入'
        : _linearTeamKey.trim().isEmpty
        ? '先配置 Linear 团队'
        : '从 Linear 导入';
    final importButton = Tooltip(
      message: importTooltip,
      child: TextButton.icon(
        onPressed:
            !_canUseLocalCli ||
                _importingLinear ||
                _linearTeamKey.trim().isEmpty
            ? null
            : _importFromLinear,
        icon: _importingLinear
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.sync_alt_rounded, size: 16),
        label: const Text('从 Linear 导入'),
      ),
    );
    final helpButton = IconButton(
      tooltip: 'Linear 导入配置',
      onPressed: _linearHelpDialog,
      icon: const Icon(Icons.help_outline_rounded, size: 18),
    );
    if (!wide) {
      return scrollableBar(scrolling: [importButton, helpButton]);
    }
    return Row(children: [importButton, const Spacer(), helpButton]);
  }

  Widget _groupControls({required bool wide}) {
    final groupFilterValue = activeTodoGroupFilter(_groupFilter, _groups);
    final label = const Text(
      '分组',
      style: TextStyle(color: CcColors.muted, fontSize: 12.5),
    );
    final dropdown = DropdownButton<String?>(
      value: groupFilterValue,
      hint: const Text('全部分组'),
      menuMaxHeight: todoMenuMaxHeight(MediaQuery.sizeOf(context)),
      underline: const SizedBox(),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('全部分组')),
        ..._groups.map(
          (g) => DropdownMenuItem<String?>(
            value: g,
            child: Text(g, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: (v) => setState(() => _groupFilter = v),
    );
    if (!wide) {
      return scrollableBar(
        scrolling: [label, const SizedBox(width: 10), dropdown],
      );
    }
    return Row(children: [label, const Spacer(), dropdown]);
  }

  Widget _statusChip(TodoStatus s) {
    final selected = _statusFilter.contains(s);
    final color = _statusColor(s);
    return InkWell(
      borderRadius: BorderRadius.circular(CcRadius.pill),
      onTap: () => setState(() {
        if (selected) {
          _statusFilter.remove(s);
        } else {
          _statusFilter.add(s);
        }
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.5) : CcColors.border,
          ),
          borderRadius: BorderRadius.circular(CcRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            statusDot(color, size: 6),
            const SizedBox(width: 5),
            Text(
              todoStatusLabel(s),
              style: TextStyle(
                fontSize: 11.5,
                color: selected ? CcColors.text : CcColors.muted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyTodoState() {
    final noMatches = _hasTodosInCurrentScope && _hasActiveTodoFilters;
    final projectName = _currentProjectFilterName;
    final linearTeam = _linearTeamKey.trim();
    final linearProject = _linearProjectId.trim();

    late final IconData icon;
    late final String title;
    late final String detail;
    Widget? action;

    if (noMatches) {
      icon = Icons.filter_alt_off_rounded;
      title = '没有匹配的待办';
      detail = '当前状态或分组筛选下没有待办。';
      action = OutlinedButton.icon(
        onPressed: () => setState(() {
          _statusFilter.clear();
          _groupFilter = null;
        }),
        icon: const Icon(Icons.close_rounded, size: 16),
        label: const Text('清除筛选'),
      );
    } else if (_scope == 'team' && _teamSource == 'linear') {
      icon = Icons.account_tree_outlined;
      if (linearTeam.isEmpty) {
        title = 'Linear 团队未配置';
        detail = '未选择 team_key，当前没有可显示的 Linear 待办。';
        action = OutlinedButton.icon(
          onPressed: _linearConfigDialog,
          icon: const Icon(Icons.tune_rounded, size: 16),
          label: const Text('配置 Linear'),
        );
      } else if (linearProject.isEmpty) {
        title = '$linearTeam 没有 Linear 待办';
        detail = '当前 Linear 团队视图暂时为空。';
      } else {
        title = '该 Linear 项目没有待办';
        detail = '$linearProject 暂时为空。';
      }
    } else if (_scope == 'team') {
      icon = Icons.groups_2_outlined;
      if (projectName.isEmpty) {
        title = '还没有团队待办';
        detail = 'Relay 团队视图暂时为空。';
      } else {
        title = '$projectName 没有团队待办';
        detail = '该项目暂时没有团队待办。';
      }
      action = FilledButton.icon(
        onPressed: _createDialog,
        icon: const Icon(Icons.add_rounded, size: 16),
        label: const Text('新建待办'),
      );
    } else if (_scope == 'personal') {
      icon = Icons.person_outline_rounded;
      title = '还没有个人待办';
      detail = '个人视图暂时为空。';
      action = FilledButton.icon(
        onPressed: _createDialog,
        icon: const Icon(Icons.add_rounded, size: 16),
        label: const Text('新建待办'),
      );
    } else {
      icon = Icons.checklist_rtl_rounded;
      title = '还没有待办';
      detail = '全部视图暂时为空。';
      action = FilledButton.icon(
        onPressed: _createDialog,
        icon: const Icon(Icons.add_rounded, size: 16),
        label: const Text('新建待办'),
      );
    }

    return _TodoEmptyState(
      icon: icon,
      title: title,
      detail: detail,
      action: action,
    );
  }

  Widget _buildList() => asyncBody(
    loading: _store.loading && _store.all.isEmpty,
    error: _store.error,
    onRetry: _store.refresh,
    child: () {
      final items = _filtered;
      if (items.isEmpty) {
        return _emptyTodoState();
      }
      return RefreshIndicator(
        onRefresh: () async {
          await _store.refresh();
          await _refreshMyProjects();
        },
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) => _row(items[i]),
        ),
      );
    },
  );

  Widget _row(Todo t) {
    final sel = _selected?.id == t.id;
    final checked = _selectedTodoIds.contains(t.id);
    final access = _accessFor(t);
    final color = _statusColor(t.status);
    final overdue =
        t.dueAt != null &&
        t.dueAt!.isBefore(DateTime.now()) &&
        t.status != TodoStatus.done &&
        t.status != TodoStatus.canceled;
    return Material(
      color: sel ? CcColors.accent.withValues(alpha: 0.07) : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (_selectingTodos) {
            _toggleTodoSelection(t);
          } else {
            setState(() => _selected = t);
          }
        },
        onLongPress: () => _toggleTodoSelection(t),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: sel ? CcColors.accent : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              if (_selectingTodos) ...[
                Checkbox(
                  value: checked,
                  onChanged: (_) => _toggleTodoSelection(t),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
              ],
              Tooltip(
                message: todoStatusLabel(t.status),
                child: statusDot(
                  color,
                  size: 8,
                  glow: t.status == TodoStatus.inProgress,
                ),
              ),
              const SizedBox(width: 10),
              if (t.attachmentCount > 0) ...[
                _RowThumb(client: _client, todo: t),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              priorityBars(t.priority, maxHeight: 10),
              if (t.dueAt != null) ...[
                const SizedBox(width: 10),
                Text(
                  commitDate(t.dueAt!),
                  style: TextStyle(
                    fontFamily: CcType.mono,
                    fontSize: 10.5,
                    color: overdue ? CcColors.danger : CcColors.subtle,
                  ),
                ),
              ],
              const SizedBox(width: 10),
              SizedBox(
                width: 30,
                child: Text(
                  relativeTime(t.updatedAt),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontFamily: CcType.mono,
                    color: CcColors.subtle,
                    fontSize: 10.5,
                  ),
                ),
              ),
              if (access.canAssign)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    icon: const Icon(Icons.send_rounded, size: 15),
                    tooltip: '一键指派',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _assignDialog(t),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rightPane() {
    final sel = _selected;
    if (sel == null) return centerMsg('从左侧选择一个待办，或点右上角 + 新建');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              Text(
                sel.isPersonal ? '个人待办' : '团队待办',
                style: const TextStyle(color: CcColors.muted, fontSize: 12),
              ),
              const Spacer(),
              if (_accessFor(sel).canAssign)
                OutlinedButton.icon(
                  onPressed: () => _assignDialog(sel),
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('指派'),
                ),
              // The board view only shows this panel when something's selected
              // (columns reflow to use the freed width otherwise), so it needs
              // its own way to deselect — list view just shows the placeholder
              // message again, which is harmless.
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: '关闭',
                onPressed: () => setState(() => _selected = null),
              ),
            ],
          ),
        ),
        Expanded(
          child: TodoDetailView(
            key: _detailKey,
            client: _client,
            todo: sel,
            overviewStore: _overview,
            config: _cfg,
            groups: _groups,
            onOpenSession: widget.onOpenSession,
            access: _accessFor(sel),
            onChanged: (updated) {
              if (mounted) setState(() => _selected = updated);
              _loadGroups();
            },
            onDeleted: () {
              if (!mounted) return;
              setState(() => _selected = null);
              _store.refresh();
            },
          ),
        ),
      ],
    );
  }

  // --- board view --------------------------------------------------------

  // _boardPane is the Linear-style kanban board: fixed-width columns laid
  // out in a horizontally-scrolling row (the reference layout doesn't flex
  // column width to the viewport), each a DragTarget<Todo> that maps a drop
  // to its dropStatus via _dropStatus.
  Widget _boardPane() => asyncBody(
    loading: _store.loading && _store.all.isEmpty,
    error: _store.error,
    onRetry: _store.refresh,
    child: () {
      final items = _filtered;
      if (items.isEmpty) {
        return _emptyTodoState();
      }
      final columns = [
        for (final def in _boardColumnDefs)
          (
            def: def,
            items: items.where((t) => def.statuses.contains(t.status)).toList(),
          ),
      ].where((c) => c.items.isNotEmpty).toList();
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final c in columns) _boardColumn(c.def, c.items)],
          ),
        ),
      );
    },
  );

  Widget _boardColumn(_BoardColumnDef def, List<Todo> items) => Container(
    width: 272,
    margin: const EdgeInsets.only(right: 10),
    decoration: BoxDecoration(
      color: CcColors.panel.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(CcRadius.md),
      border: Border.all(color: CcColors.border),
    ),
    child: Column(
      children: [
        _columnHeader(def.title, items.length, _createDialog),
        Expanded(
          child: DragTarget<Todo>(
            onWillAcceptWithDetails: (details) =>
                details.data.status != def.dropStatus &&
                _accessFor(details.data).canEdit,
            onAcceptWithDetails: (details) =>
                _dropStatus(details.data, def.dropStatus),
            builder: (context, candidate, rejected) {
              final highlight = candidate.isNotEmpty;
              return Container(
                decoration: BoxDecoration(
                  color: highlight
                      ? CcColors.accent.withValues(alpha: 0.07)
                      : null,
                  borderRadius: BorderRadius.circular(CcRadius.md),
                ),
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          '无',
                          style: TextStyle(
                            color: CcColors.subtle.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _draggableCard(items[i]),
                      ),
              );
            },
          ),
        ),
      ],
    ),
  );

  Widget _columnHeader(String title, int count, VoidCallback onAdd) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 10, 4, 8),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: CcColors.muted,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: CcColors.panelHigh,
            borderRadius: BorderRadius.circular(CcRadius.pill),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              fontSize: 11,
              color: CcColors.subtle,
              fontFamily: CcType.mono,
            ),
          ),
        ),
        const Spacer(),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            icon: const Icon(Icons.add_rounded, size: 16),
            tooltip: '新建待办',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: onAdd,
          ),
        ),
      ],
    ),
  );

  Widget _draggableCard(Todo t) {
    final card = _todoCardSelectable(
      t,
      onOpen: () => setState(() => _selected = t),
    );
    if (_selectingTodos) return card;
    if (!_accessFor(t).canEdit) return card;
    return Draggable<Todo>(
      data: t,
      feedback: Opacity(
        opacity: 0.85,
        child: SizedBox(
          width: 252,
          child: Material(color: Colors.transparent, child: card),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }

  Widget _todoCardSelectable(Todo t, {required VoidCallback onOpen}) {
    final checked = _selectedTodoIds.contains(t.id);
    return GestureDetector(
      onLongPress: () => _toggleTodoSelection(t),
      child: Stack(
        children: [
          TodoCard(
            todo: t,
            projectName: _projectName(t),
            onTap: _selectingTodos ? () => _toggleTodoSelection(t) : onOpen,
          ),
          if (_selectingTodos)
            Positioned(
              top: 4,
              right: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CcColors.panel.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                child: Checkbox(
                  value: checked,
                  onChanged: (_) => _toggleTodoSelection(t),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          if (checked)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(CcRadius.md),
                    border: Border.all(
                      color: CcColors.accent.withValues(alpha: 0.72),
                      width: 1.2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --- mobile view ---------------------------------------------------------

  // _mobileBody drops the board/split-pane layout entirely for a single
  // scrolling column of cards, grouped under the same status buckets as the
  // board's columns (so the group headings read the same either way), with
  // tapping a card pushing a full-screen detail route instead of opening a
  // side panel there's no room for.
  Widget _mobileBody() => Column(
    children: [
      _filterHeader(wide: false),
      Expanded(child: _mobileList()),
    ],
  );

  Widget _mobileList() => asyncBody(
    loading: _store.loading && _store.all.isEmpty,
    error: _store.error,
    onRetry: _store.refresh,
    child: () {
      final items = _filtered;
      if (items.isEmpty) {
        return _emptyTodoState();
      }
      final width = MediaQuery.of(context).size.width;
      final cols = width >= 480 ? 2 : 1;
      final groups = [
        for (final def in _boardColumnDefs)
          (
            def.title,
            items.where((t) => def.statuses.contains(t.status)).toList(),
          ),
      ].where((g) => g.$2.isNotEmpty).toList();
      return RefreshIndicator(
        onRefresh: () async {
          await _store.refresh();
          await _refreshMyProjects();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          children: [
            for (final g in groups) _mobileGroup(g.$1, g.$2, cols, width),
          ],
        ),
      );
    },
  );

  Widget _mobileGroup(
    String title,
    List<Todo> items,
    int cols,
    double totalWidth,
  ) {
    final collapsed = _collapsedMobileGroups.contains(title);
    final cardW = (totalWidth - 12 * 2 - (cols - 1) * 10) / cols;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (collapsed) {
              _collapsedMobileGroups.remove(title);
            } else {
              _collapsedMobileGroups.add(title);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: CcColors.muted,
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: CcColors.muted,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: CcColors.panelHigh,
                    borderRadius: BorderRadius.circular(CcRadius.pill),
                  ),
                  child: Text(
                    '${items.length}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: CcColors.subtle,
                      fontFamily: CcType.mono,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final t in items)
                SizedBox(
                  width: cardW,
                  child: _todoCardSelectable(
                    t,
                    onOpen: () => _openMobileDetail(t),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  void _openMobileDetail(Todo t) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('待办详情'),
            actions: [
              if (_accessFor(t).canAssign)
                IconButton(
                  icon: const Icon(Icons.send_rounded),
                  tooltip: '指派',
                  onPressed: () => _assignDialog(t),
                ),
            ],
          ),
          body: TodoDetailView(
            client: _client,
            todo: t,
            overviewStore: _overview,
            config: _cfg,
            groups: _groups,
            onOpenSession: widget.onOpenSession,
            access: _accessFor(t),
            onChanged: (_) => _loadGroups(),
            onDeleted: () {
              if (Navigator.of(context).canPop()) Navigator.of(context).pop();
              _store.refresh();
            },
          ),
        ),
      ),
    );
  }
}

class _TodoEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  const _TodoEmptyState({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: CcColors.accent.withValues(alpha: 0.12),
                border: Border.all(
                  color: CcColors.accent.withValues(alpha: 0.34),
                ),
                borderRadius: BorderRadius.circular(CcRadius.md),
              ),
              child: Icon(icon, color: CcColors.accentBright, size: 22),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: CcColors.muted,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      ),
    ),
  );
}

// _RowThumb lazily fetches the full Todo (GET /v1/todos/{id}) to find its
// first image attachment for a list-row thumbnail — ListTodos deliberately
// omits `attachments` (avoids an N+1 join server-side), so this is the only
// way to know whether an attachment is an image. Only fires for rows with
// attachmentCount > 0, cached per (id, updatedAt) so it never refetches an
// unchanged todo, and only for rows a lazy ListView actually builds.
class _RowThumb extends StatefulWidget {
  final RelayClient client;
  final Todo todo;
  const _RowThumb({required this.client, required this.todo});

  @override
  State<_RowThumb> createState() => _RowThumbState();
}

class _RowThumbState extends State<_RowThumb> {
  static final Map<String, TodoAttachment?> _cache = {};
  TodoAttachment? _att;
  bool _ready = false;

  String get _cacheKey =>
      '${widget.todo.id}:${widget.todo.updatedAt.millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    if (_cache.containsKey(_cacheKey)) {
      _att = _cache[_cacheKey];
      _ready = true;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final full = await widget.client.todo(widget.todo.id);
      final images = full.attachments.where(
        (a) => isImageAttachmentName(a.name),
      );
      final found = images.isEmpty ? null : images.first;
      _cache[_cacheKey] = found;
      if (mounted) {
        setState(() {
          _att = found;
          _ready = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _ready = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final att = _att;
    if (!_ready || att == null) return const SizedBox(width: 22, height: 22);
    return TodoAttachmentThumb(
      client: widget.client,
      todoId: widget.todo.id,
      attachment: att,
      size: 22,
    );
  }
}

// _QuickCreateDialog is Linear's Cmd+I "quick add" panel, not a stack of
// labeled dropdowns: a focused title input, an optional description (the
// same live markdown editor as the detail view), and a compact icon row for
// priority/recurrence/due-date/attachments. Creates the todo, then uploads
// each attachment in turn (attachments need the todo's id, so they can only
// go up after creation succeeds).
class _QuickCreateDialog extends StatefulWidget {
  final RelayClient client;
  final Me me;
  final String initialScope;
  final String? initialProjectId;
  // groups seeds the create dialog's GroupControl picker with the current
  // filter's known group names — this is a snapshot from TodosPage, not a
  // live query, so a name typed here that isn't in the list yet still works
  // (it's created on first use, same "输入即创建" contract as everywhere
  // else GroupControl appears).
  final List<String> groups;

  // projects is TodosPage's live (refreshed) project list, passed in rather than
  // read off `me` so a relay project created after login is selectable here too.
  final List<ProjectRole> projects;
  final bool Function() isCurrentContext;

  const _QuickCreateDialog({
    required this.client,
    required this.me,
    required this.projects,
    required this.isCurrentContext,
    this.initialScope = 'personal',
    this.initialProjectId,
    this.groups = const [],
  });

  @override
  State<_QuickCreateDialog> createState() => _QuickCreateDialogState();
}

class _QuickCreateDialogState extends State<_QuickCreateDialog> {
  final _titleCtl = TextEditingController();
  final _bodyCtl = MarkdownLiteController();
  late String _scope = widget.initialScope;
  String? _projectId;
  String _priority = 'normal';
  String _recurrence = '';
  DateTime? _dueAt;
  String? _groupName;
  final List<PlatformFile> _files = [];
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _projectId = widget.initialProjectId;
    if (_scope == 'team' && _projectId == null && widget.projects.isNotEmpty) {
      _projectId = widget.projects.first.id;
    }
  }

  @override
  void dispose() {
    _titleCtl.dispose();
    _bodyCtl.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (res == null || !mounted) return;
    setState(() => _files.addAll(res.files));
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueAt ?? now),
    );
    if (time == null || !mounted) return;
    setState(
      () => _dueAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  bool _closeIfStaleContext() {
    if (widget.isCurrentContext()) return false;
    Navigator.pop(context, false);
    return true;
  }

  Future<void> _submit() async {
    final title = _titleCtl.text.trim();
    if (title.isEmpty) {
      snack(context, '请输入标题');
      return;
    }
    if (_scope == 'team' && _projectId == null) {
      snack(context, '请选择项目');
      return;
    }
    if (_closeIfStaleContext()) return;
    setState(() => _submitting = true);
    try {
      final created = await widget.client.createTodo(
        title: title,
        bodyMd: _bodyCtl.text,
        priority: _priority,
        projectId: _scope == 'team' ? _projectId : null,
        recurrence: _recurrence,
        dueAt: _dueAt,
        groupName: _groupName,
      );
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      for (final f in _files) {
        if (!mounted) return;
        if (_closeIfStaleContext()) return;
        try {
          Uint8List? bytes = f.bytes;
          bytes ??= f.path != null ? await File(f.path!).readAsBytes() : null;
          if (!mounted) return;
          if (_closeIfStaleContext()) return;
          if (bytes == null) continue;
          await widget.client.uploadTodoAttachment(created.id, f.name, bytes);
          if (!mounted) return;
          if (_closeIfStaleContext()) return;
        } catch (e) {
          if (!mounted) return;
          if (_closeIfStaleContext()) return;
          snack(context, '附件 ${f.name} 上传失败: ${errorText(e)}');
        }
      }
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      setState(() => _submitting = false);
      snack(context, '创建失败: ${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (widget.projects.isNotEmpty)
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'personal', label: Text('个人')),
                        ButtonSegment(value: 'team', label: Text('团队')),
                      ],
                      selected: {_scope},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onSelectionChanged: (s) => setState(() {
                        _scope = s.first;
                        if (_scope == 'team' &&
                            _projectId == null &&
                            widget.projects.isNotEmpty) {
                          _projectId = widget.projects.first.id;
                        }
                      }),
                    ),
                  const Spacer(),
                  if (_scope == 'team' && widget.projects.isNotEmpty)
                    DropdownButton<String>(
                      isDense: true,
                      underline: const SizedBox(),
                      menuMaxHeight: todoMenuMaxHeight(
                        MediaQuery.sizeOf(context),
                      ),
                      value: _projectId,
                      items: widget.projects
                          .map(
                            (p) => DropdownMenuItem(
                              value: p.id,
                              child: Text(
                                p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _projectId = v),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _titleCtl,
                autofocus: true,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '待办标题',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 6),
              MarkdownLiteEditor(
                controller: _bodyCtl,
                hintText: '添加描述…（可选，支持 Markdown）',
                minLines: 2,
                maxLines: 6,
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Row(
                children: [
                  PriorityControl(
                    priority: _priority,
                    onChanged: (v) => setState(() => _priority = v),
                  ),
                  const SizedBox(width: 6),
                  RecurrenceControl(
                    recurrence: _recurrence,
                    onChanged: (v) => setState(() => _recurrence = v),
                  ),
                  const SizedBox(width: 6),
                  DueDatePill(
                    dueAt: _dueAt,
                    onTap: _pickDueDate,
                    onClear: () => setState(() => _dueAt = null),
                  ),
                  const SizedBox(width: 6),
                  GroupControl(
                    groupName: _groupName,
                    existingGroups: widget.groups,
                    onSelect: (v) => setState(() => _groupName = v),
                    onClear: () => setState(() => _groupName = null),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded, size: 18),
                    tooltip: _files.isEmpty
                        ? '添加附件'
                        : '已选 ${_files.length} 个文件',
                    visualDensity: VisualDensity.compact,
                    onPressed: _pickFiles,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('创建'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberRolePill extends StatelessWidget {
  final String label;
  final bool selected;

  const _MemberRolePill({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    final color = selected ? CcColors.accentBright : CcColors.muted;
    return Container(
      constraints: const BoxConstraints(minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: CcColors.accent.withValues(alpha: selected ? 0.16 : 0.08),
        border: Border.all(
          color: selected ? CcColors.accent : CcColors.borderSoft,
        ),
        borderRadius: BorderRadius.circular(CcRadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.2,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// _AssignPrep is what _prepareAssignment resolves to just before dispatch:
// the exact text to paste into the terminal (either the "go read this file"
// pointer when materialization succeeded, or the raw title+body fallback), plus
// the todo's status as freshly re-fetched at prep time — _maybeBumpToInProgress
// decides the triage/backlog/todo → in_progress transition off that, not off
// the possibly-stale widget.todo.status from the list row.
typedef _AssignPrep = ({String taskText, TodoStatus statusAtPrep});

String? todoProjectNameForAssignment({
  required String? todoProjectId,
  required Iterable<ProjectCfg> localProjects,
  Iterable<RemoteRootInfo> remoteRoots = const [],
}) {
  final pid = (todoProjectId ?? '').trim();
  if (pid.isEmpty) return null;
  for (final root in remoteRoots) {
    if (root.projectId.trim() == pid) return root.name;
  }
  for (final project in localProjects) {
    if (project.projectId.trim() == pid) return project.name;
  }
  return null;
}

bool sessionCardMatchesTodoProject(
  SessionCard card, {
  required String? todoProjectId,
  required String? todoProjectName,
}) {
  final pid = (todoProjectId ?? '').trim();
  return todoProjectTargetMatches(
    todoProjectId: pid.isEmpty ? null : pid,
    todoProjectName: todoProjectName,
    targetProjectId: card.projectId,
    targetProjectName: card.project,
  );
}

List<SessionCard> assignableSessionCardsForTodoProject(
  Iterable<SessionCard> cards, {
  required String? todoProjectId,
  required String? todoProjectName,
}) => [
  for (final card in cards)
    if (sessionCardMatchesTodoProject(
      card,
      todoProjectId: todoProjectId,
      todoProjectName: todoProjectName,
    ))
      card,
];

String? activeTodoProjectFilter(
  String? projectFilter,
  Iterable<ProjectRole> projects,
) {
  final filter = (projectFilter ?? '').trim();
  if (filter.isEmpty) return null;
  return projects.any((p) => p.id.trim() == filter) ? filter : null;
}

String? activeTodoGroupFilter(String? groupFilter, Iterable<String> groups) {
  final filter = (groupFilter ?? '').trim();
  if (filter.isEmpty) return null;
  return groups.any((g) => g.trim() == filter) ? filter : null;
}

// _AssignTodoDialog is the "一键指派" flow: dispatch to an existing local
// session, or spawn a brand-new one first (optionally in a fresh worktree
// branch) and then dispatch. Both branches deliver through
// SessionOverviewStore (the only channel a top-level sibling page has into
// WorkspacePage's live sessions), then best-effort sync assignee visibility
// to the relay so other project members see who picked it up — that sync
// never blocks or fails the "start working now" outcome.
class _AssignTodoDialog extends StatefulWidget {
  final Todo todo;
  final RelayClient client;
  final SessionOverviewStore overviewStore;
  final AppConfig config;
  final bool Function() isCurrentContext;

  const _AssignTodoDialog({
    required this.todo,
    required this.client,
    required this.overviewStore,
    required this.config,
    required this.isCurrentContext,
  });

  @override
  State<_AssignTodoDialog> createState() => _AssignTodoDialogState();
}

class _AssignTodoDialogState extends State<_AssignTodoDialog> {
  String _mode = 'existing'; // existing | new
  String? _targetSid;
  // "已有会话" tab 的三级级联选择状态，跟 "新建会话" tab 的 _workspace/_project
  // 完全分开：这边筛的是已有 SessionCard，那边选的是 config 里可新建的
  // workspace/project，两套语义不同，各自维护。空字符串代表未绑定的孤儿会话。
  String? _existingWorkspace;
  String? _existingProject;
  String? _workspace;
  String? _project;
  String _kind = 'claude';
  final _branchCtl = TextEditingController();
  bool _submitting = false;

  // --- "指派给成员" mode: assign the todo to a real teammate by identity,
  // leaving the session-binding trio empty (same shape as a Linear import's
  // assignee). This is the only assign path on mobile, where there are no
  // local agent sessions to dispatch to. Candidates follow the relay gate:
  // personal todos may pick self; team todos may pick project members and team
  // owner/admin effective managers. Display names come from project/team member
  // payloads and degrade to the raw identity. Loaded lazily: eagerly when there
  // are no local sessions (member mode is forced), otherwise on first switch to
  // the tab.
  bool _membersRequested = false;
  bool _loadingMembers = false;
  String? _membersError;
  List<String> _memberIds = const [];
  Map<String, String> _memberNames = const {};
  Map<String, String> _memberRoles = const {};
  Set<String> _onlineIds = const {};
  String? _pickedIdentity;
  int _memberLoadGeneration = 0;
  String get _selfIdentity => cleanedIdentity(widget.config.identity);

  // On mobile there are no local sessions (overviewStore is desktop-only), so
  // 已有会话/新建会话 instead drive the paired desktop's sessions over the WS
  // channel. _remote is that connection (null on desktop, or before the phone's
  // RemoteWorkspacePage published it); when present, session/project data comes
  // from its pushed overview/roots (not the local overviewStore/config) and the
  // two session modes dispatch via requestAssign (see _remoteAssign*).
  RemoteClient? get _remote =>
      widget.overviewStore.cards.isEmpty ? phoneRemoteClient : null;
  bool get _remoteReady => _remote?.hostOnline ?? false;
  // Offer the 已有会话/新建会话 segments when local sessions exist, or the paired
  // desktop is online (new-session works even with zero existing sessions).
  bool get _showSessionModes =>
      widget.overviewStore.cards.isNotEmpty || _remoteReady;

  Iterable<ProjectCfg> get _localProjects sync* {
    for (final workspace in widget.config.workspaces) {
      yield* workspace.projects;
    }
  }

  String? get _todoProjectId {
    final id = widget.todo.projectId?.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  String? get _todoProjectName => todoProjectNameForAssignment(
    todoProjectId: _todoProjectId,
    localProjects: _localProjects,
    remoteRoots: _remote?.roots ?? const [],
  );

  bool _projectAllowedForTodo({
    required String projectId,
    required String projectName,
  }) {
    return todoProjectTargetMatches(
      todoProjectId: _todoProjectId,
      todoProjectName: _todoProjectName,
      targetProjectId: projectId,
      targetProjectName: projectName,
    );
  }

  bool _closeIfStaleContext() {
    if (widget.isCurrentContext()) return false;
    Navigator.pop(context, false);
    return true;
  }

  List<SessionCard> get _cards => assignableSessionCardsForTodoProject(
    widget.overviewStore.cards.isNotEmpty
        ? widget.overviewStore.cards
        : (_remote?.overview.values.toList() ?? const []),
    todoProjectId: _todoProjectId,
    todoProjectName: _todoProjectName,
  );

  // workspace / project NAME lists for the 新建会话 form — from the paired
  // desktop's pushed roots when remote, else the local config.
  List<String> get _workspaceNames {
    final r = _remote;
    if (r != null) {
      final seen = <String>{};
      return [
        for (final root in r.roots)
          if (_projectAllowedForTodo(
                projectId: root.projectId,
                projectName: root.name,
              ) &&
              seen.add(root.workspace))
            root.workspace,
      ];
    }
    return [
      for (final w in widget.config.workspaces)
        if (w.projects.any(
          (project) => _projectAllowedForTodo(
            projectId: project.projectId,
            projectName: project.name,
          ),
        ))
          w.name,
    ];
  }

  List<String> _projectNamesFor(String? ws) {
    final r = _remote;
    if (r != null) {
      return [
        for (final root in r.roots)
          if (root.workspace == ws &&
              _projectAllowedForTodo(
                projectId: root.projectId,
                projectName: root.name,
              ))
            root.name,
      ];
    }
    return [
      for (final p in projectsOf(widget.config, ws))
        if (_projectAllowedForTodo(projectId: p.projectId, projectName: p.name))
          p.name,
    ];
  }

  // _prepareAssignment resolves the terminal text to paste for a dispatch to
  // session [sid]. It resolves the target session's workdir (polling briefly
  // since this runs earlier than _syncAssignVisibility and a just-spawned
  // session's card may not carry a workdir yet), then hands off to the shared
  // prepareTodoAssignmentText — which re-fetches the full todo+comments,
  // materializes the file under that workdir, and degrades to a raw paste on any
  // failure. statusAtPrep carries the freshly-fetched status so the caller can
  // decide the in_progress bump off current server state.
  Future<_AssignPrep> _prepareAssignment(String sid) async {
    String? workdir = _findCard(sid)?.workdir;
    for (var i = 0; i < 5 && (workdir == null || workdir.isEmpty); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) {
        return (taskText: widget.todo.title, statusAtPrep: widget.todo.status);
      }
      workdir = _findCard(sid)?.workdir;
    }
    if (!mounted) {
      return (taskText: widget.todo.title, statusAtPrep: widget.todo.status);
    }
    final prep = await prepareTodoAssignmentText(
      client: widget.client,
      todoId: widget.todo.id,
      fallbackTodo: widget.todo,
      workdir: workdir ?? '',
    );
    return (taskText: prep.taskText, statusAtPrep: prep.full.status);
  }

  // _maybeBumpToInProgress makes "指派" mean "开始处理": a todo still sitting in
  // an unstarted lane (triage/backlog/todo) jumps to 进行中. Anything already
  // past that (in_progress/in_review/done/canceled/duplicate) is left alone —
  // assignee and status are independent dimensions on the backend, this bump is
  // purely a UI-side convenience. Failure only snacks; it never blocks the
  // dialog from closing (same try/catch+snack shape as _dropStatus).
  Future<void> _maybeBumpToInProgress(TodoStatus current) async {
    const bumpable = {TodoStatus.triage, TodoStatus.backlog, TodoStatus.todo};
    if (!bumpable.contains(current)) return;
    try {
      await widget.client.setTodoStatus(widget.todo.id, TodoStatus.inProgress);
    } catch (e) {
      if (mounted) snack(context, '更新状态失败: ${errorText(e)}');
    }
  }

  // _loadMembers builds the candidate list for "指派给成员": personal todos can
  // assign to self; team todos can assign to direct project members and team
  // owner/admin effective project managers, matching the relay's assignee
  // validation. Display names come from project/team member payloads (degrades
  // to raw identity). The online set is best-effort and drives ONLY the green
  // dot; arbitrary online strangers are not added.
  Future<void> _loadMembers() async {
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    final generation = ++_memberLoadGeneration;
    final client = widget.client;
    final todo = widget.todo;
    setState(() {
      _loadingMembers = true;
      _membersError = null;
    });
    final self = _selfIdentity;
    final online = <String>{};

    final pid = todo.projectId ?? '';
    // onlineUsers is best-effort (dot only). project() is load-bearing for team
    // todos; organization() is best-effort so older relays still show direct
    // project members.
    final onlineF = client.onlineUsers().catchError((_) => <OnlineUser>[]);
    final detailF = pid.isEmpty ? Future.value(null) : client.project(pid);

    final ProjectDetail? detail;
    try {
      detail = await detailF;
    } catch (e) {
      if (_isCurrentMemberLoad(generation, client, todo, self)) {
        setState(() {
          _membersError = errorText(e);
          _loadingMembers = false;
        });
      }
      return;
    }
    if (!_isCurrentMemberLoad(generation, client, todo, self)) return;
    final projectMembers = detail?.members ?? const <ProjectMember>[];
    final orgMembers = detail?.project.orgId.isNotEmpty == true
        ? await client
              .organization(detail!.project.orgId)
              .then((d) => d.members)
              .catchError((_) => <OrganizationMember>[])
        : const <OrganizationMember>[];
    if (!_isCurrentMemberLoad(generation, client, todo, self)) return;

    final names = todoMemberDisplayNames(
      projectMembers: projectMembers,
      organizationMembers: orgMembers,
    );
    final candidates = assignableTodoMembers(
      selfIdentity: self,
      includeSelf: pid.isEmpty,
      projectMembers: projectMembers,
      organizationMembers: orgMembers,
    );
    final ids = [for (final c in candidates) c.identity];
    final roles = {
      for (final c in candidates) identityLookupKey(c.identity): c.roleLabel,
    };
    online.addAll(normalizedOnlineTodoMemberIds(await onlineF));
    if (!_isCurrentMemberLoad(generation, client, todo, self)) return;
    final selfCandidate = ids.firstWhere(
      (id) => sameIdentity(id, self),
      orElse: () => '',
    );
    setState(() {
      _memberIds = ids;
      _memberNames = names;
      _memberRoles = roles;
      _onlineIds = online;
      // Default to self, never the current assignee — pre-selecting the existing
      // assignee silently re-assigns to them if the user taps 指派 without
      // changing the radio (the "指派错了" report).
      _pickedIdentity = selfCandidate.isNotEmpty
          ? selfCandidate
          : (ids.isNotEmpty ? ids.first : null);
      _loadingMembers = false;
    });
  }

  bool _isCurrentMemberLoad(
    int generation,
    RelayClient client,
    Todo todo,
    String selfIdentity,
  ) {
    if (!mounted) return false;
    if (_closeIfStaleContext()) return false;
    return generation == _memberLoadGeneration &&
        identical(widget.client, client) &&
        widget.todo.id == todo.id &&
        widget.todo.projectId == todo.projectId &&
        sameIdentity(widget.config.identity, selfIdentity);
  }

  // _assignToMember writes assignee_identity only (session trio left empty),
  // the "pure human assignment" shape — matches internal/linear/import.go's
  // AssignTodo(id, identity, "", ...) so it doesn't collide with the
  // 打开/恢复会话 button (which keys off the resume trio, see todo_detail_view).
  Future<void> _assignToMember() async {
    if (_submitting) return;
    if (_closeIfStaleContext()) return;
    final picked = (_pickedIdentity ?? '').trim();
    if (picked.isEmpty) {
      snack(context, '请选择要指派的成员');
      return;
    }
    if (!_memberIds.any((id) => sameIdentity(id, picked))) {
      snack(context, '请选择有效的团队成员');
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.client.assignTodo(widget.todo.id, assigneeIdentity: picked);
    } catch (e) {
      if (mounted) {
        if (_closeIfStaleContext()) return;
        setState(() => _submitting = false);
        snack(context, '指派失败: ${errorText(e)}');
      }
      return;
    }
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    await _maybeBumpToInProgress(widget.todo.status);
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    if (mounted) Navigator.pop(context, true);
  }

  Widget _memberForm() {
    if (_loadingMembers) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_membersError != null) {
      return Text(
        '加载成员失败: $_membersError',
        style: TextStyle(color: CcColors.muted),
      );
    }
    if (_memberIds.isEmpty) {
      return Text(
        widget.todo.isPersonal ? '个人待办只能指派给自己。' : '该项目暂无可指派的成员。',
        style: TextStyle(color: CcColors.muted),
      );
    }
    // Hand-drawn radio rows — the project avoids the deprecated
    // RadioListTile.groupValue (see git_log_commit_menu._pickResetMode).
    final self = _selfIdentity;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _memberIds.map((id) {
            final key = identityLookupKey(id);
            final sel = sameIdentity(_pickedIdentity ?? '', id);
            final name = (_memberNames[key] ?? '').trim();
            final role = (_memberRoles[key] ?? '').trim();
            final primary = todoMemberPrimaryLabel(
              identity: id,
              displayName: name,
              selfIdentity: self,
            );
            return InkWell(
              onTap: () => setState(() => _pickedIdentity = id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      sel
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: sel ? CcColors.accent : CcColors.subtle,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            primary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: CcColors.text,
                            ),
                          ),
                          if (name.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  return Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          id,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: CcColors.muted,
                                          ),
                                        ),
                                      ),
                                      if (role.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxWidth:
                                                todoMemberRolePillMaxWidth(
                                                  constraints,
                                                  maxFraction: 0.45,
                                                ),
                                          ),
                                          child: _MemberRolePill(
                                            label: role,
                                            selected: sel,
                                          ),
                                        ),
                                      ],
                                    ],
                                  );
                                },
                              ),
                            ),
                          if (name.isEmpty && role.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  return ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: todoMemberRolePillMaxWidth(
                                        constraints,
                                      ),
                                    ),
                                    child: _MemberRolePill(
                                      label: role,
                                      selected: sel,
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_onlineIds.contains(key))
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(Icons.circle, size: 9, color: Colors.green),
                      ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    if (_cards.isNotEmpty) {
      final first = _cards.first;
      _existingWorkspace = first.workspace;
      _existingProject = first.project;
      _targetSid = first.sid;
    }
    _mode = initialTodoAssignMode(
      hasSessionCards: _cards.isNotEmpty,
      remoteReady: _remoteReady,
    );
    if (_mode == 'member') {
      // No sessions to dispatch to and no online desktop to drive → the only
      // assign path is 指派给成员, so force that mode and load candidates.
      _requestMembers();
    }
    final wss = _workspaceNames;
    if (wss.isNotEmpty) {
      _workspace = wss.first;
      final projs = _projectNamesFor(_workspace);
      if (projs.isNotEmpty) _project = projs.first;
    }
  }

  @override
  void dispose() {
    _branchCtl.dispose();
    super.dispose();
  }

  void _requestMembers() {
    if (_membersRequested) return;
    _membersRequested = true;
    Future.microtask(_loadMembers);
  }

  SessionCard? _findCard(String sid) {
    for (final c in _cards) {
      if (c.sid == sid) return c;
    }
    return null;
  }

  // _resumeKindFor encodes a SessionCard's kind the same way
  // workspace_page.dart's _supervisorAgentForKind expects to read it back
  // ('supervisor:claude'/'supervisor:codex') — SessionCard.agentKind alone
  // is always bare ('claude'/'codex'), so without this a todo bound to a 总管
  // session would resume as a plain agent session, silently losing its
  // supervisor identity.
  String? _resumeKindFor(SessionCard? card) {
    if (card == null || card.agentKind.isEmpty) return null;
    return card.isSupervisor ? 'supervisor:${card.agentKind}' : card.agentKind;
  }

  // _syncAssignVisibility is best-effort: local dispatch already delivered the
  // task, so a relay failure here only means other project members won't see
  // the assignee yet — never worth blocking or erroring the dialog over. Sets
  // identity + session id + session label per RelayClient.assignTodo's
  // "assign to a specific local session" contract, plus — when the target
  // session's card carries them — the permanent-resume trio
  // (agentSessionId/workdir/agentKind), read straight off the just-dispatched
  // TerminalSession's SessionCard, so "打开/恢复会话" can respawn the exact
  // same conversation long after this bus session id itself goes stale.
  //
  // waitForAgentId: codex doesn't mint its transcript id synchronously like
  // claude does (--session-id up front) — it's captured asynchronously from
  // its rollout file sometime after launch (TerminalSession._maybeCaptureAgentId).
  // A brand-new codex session's card usually has no agentSessionId yet the
  // instant it's dispatched, so _assignToNew asks this to poll briefly rather
  // than permanently missing the resume trio for that todo.
  //
  // workspaceName/repoName sync the todo's optional workspace/repo binding
  // (see WorkspaceRepoControl / pkg/todoschema.Todo field docs) to match the
  // session it's being dispatched to — always overwriting, even if the todo
  // was previously bound (manually) to a different repo: once a todo has a
  // live session, "which repo is it in" should follow the session, not stay
  // pinned to whatever was picked before. This lands as a second, separate
  // PATCH rather than growing RelayClient.assignTodo's already-wide parameter
  // list further.
  Future<void> _syncAssignVisibility(
    String sessionId,
    String label, {
    required String workspaceName,
    required String repoName,
    bool waitForAgentId = false,
  }) async {
    if (_closeIfStaleContext()) return;
    var card = _findCard(sessionId);
    if (waitForAgentId && (card?.agentSessionId ?? '').isEmpty) {
      for (var i = 0; i < 15 && (card?.agentSessionId ?? '').isEmpty; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
        if (_closeIfStaleContext()) return;
        card = _findCard(sessionId);
      }
    }
    try {
      await widget.client.assignTodo(
        widget.todo.id,
        assigneeIdentity: widget.config.identity,
        assigneeSessionId: sessionId,
        assigneeSessionLabel: label,
        assigneeAgentSessionId: card?.agentSessionId,
        assigneeWorkdir: card?.workdir,
        assigneeAgentKind: _resumeKindFor(card),
      );
    } catch (_) {}
    try {
      await widget.client.updateTodo(
        widget.todo.id,
        workspaceName: workspaceName,
        repoName: repoName,
      );
    } catch (e) {
      if (_closeIfStaleContext()) return;
      if (mounted) snack(context, '同步工作区/库绑定失败: ${errorText(e)}');
    }
  }

  Future<void> _assignToExisting() async {
    if (_submitting) return;
    if (_closeIfStaleContext()) return;
    final sid = _targetSid;
    if (sid == null) return;
    setState(() => _submitting = true);
    // Materialize the todo.md BEFORE dispatching: the pasted text points the
    // agent at that file, so the file must already be on disk when it lands.
    final prep = await _prepareAssignment(sid);
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    final err = widget.overviewStore.dispatch(
      LocalMsg('', sid, prep.taskText, true),
    );
    if (err != null) {
      if (mounted) {
        setState(() => _submitting = false);
        snack(context, '投递失败: $err');
      }
      return;
    }
    final card = _findCard(sid);
    await _syncAssignVisibility(
      sid,
      card?.label ?? '',
      workspaceName: card?.workspace ?? '',
      repoName: card?.project ?? '',
    );
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    await _maybeBumpToInProgress(prep.statusAtPrep);
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _assignToNew() async {
    if (_submitting) return;
    if (_closeIfStaleContext()) return;
    final ws = _workspace, proj = _project;
    if (!todoAssignNewSelectionValid(
      workspace: ws,
      project: proj,
      workspaceNames: _workspaceNames,
      projectNames: _projectNamesFor(ws),
    )) {
      snack(context, '请选择 workspace / project');
      return;
    }
    final validWorkspace = ws!;
    final validProject = proj!;
    setState(() => _submitting = true);
    final branch = _branchCtl.text.trim();
    final (sid, err) = await widget.overviewStore.spawn(
      workspace: validWorkspace,
      project: validProject,
      kind: _kind,
      projectId: _todoProjectId,
      newWorktreeBranch: branch.isEmpty ? null : branch,
    );
    if (sid == null) {
      if (mounted) {
        if (_closeIfStaleContext()) return;
        setState(() => _submitting = false);
        snack(context, '新建会话失败: ${err ?? "未知错误"}');
      }
      return;
    }
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    // Prep (materialize) AFTER the session exists but BEFORE dispatch — the
    // pointer text must reference an already-written file. _prepareAssignment
    // polls for the fresh card's workdir since it may not be populated the
    // instant spawn returns; it falls back to a raw paste if it never appears.
    final prep = await _prepareAssignment(sid);
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    final dispatchErr = widget.overviewStore.dispatch(
      LocalMsg('', sid, prep.taskText, true),
    );
    if (dispatchErr != null && mounted) {
      snack(context, '会话已创建，但投递失败: $dispatchErr');
    }
    await _syncAssignVisibility(
      sid,
      validProject,
      workspaceName: validWorkspace,
      repoName: validProject,
      waitForAgentId: true,
    );
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    await _maybeBumpToInProgress(prep.statusAtPrep);
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    if (mounted) Navigator.pop(context, true);
  }

  // Remote variants (mobile): instead of dispatching to a LOCAL session, ask the
  // paired desktop to do it — RemoteClient.requestAssign → RemoteHost.onAssignTodo
  // → workspace_page._remoteAssignTodo materializes/dispatches/spawns/binds on
  // its side. Returns null on success; on error keep the dialog open + snack.
  Future<void> _remoteAssignExisting() async {
    if (_submitting) return;
    if (_closeIfStaleContext()) return;
    final r = _remote;
    final sid = _targetSid;
    if (r == null || sid == null) {
      snack(context, '请选择会话');
      return;
    }
    setState(() => _submitting = true);
    final err = await r.requestAssign(
      todoId: widget.todo.id,
      mode: 'existing',
      sid: sid,
      projectId: _todoProjectId,
    );
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    if (err != null) {
      setState(() => _submitting = false);
      snack(context, err);
      return;
    }
    Navigator.pop(context, true);
  }

  Future<void> _remoteAssignNew() async {
    if (_submitting) return;
    if (_closeIfStaleContext()) return;
    final r = _remote;
    final ws = _workspace, proj = _project;
    if (r == null ||
        !todoAssignNewSelectionValid(
          workspace: ws,
          project: proj,
          workspaceNames: _workspaceNames,
          projectNames: _projectNamesFor(ws),
        )) {
      snack(context, '请选择 workspace / project');
      return;
    }
    final validWorkspace = ws!;
    final validProject = proj!;
    setState(() => _submitting = true);
    final branch = _branchCtl.text.trim();
    final err = await r.requestAssign(
      todoId: widget.todo.id,
      mode: 'new',
      workspace: validWorkspace,
      project: validProject,
      projectId: _todoProjectId,
      kind: _kind,
      branch: branch.isEmpty ? null : branch,
    );
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    if (err != null) {
      setState(() => _submitting = false);
      snack(context, err);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the paired desktop's session list / online state changes
    // (mobile remote mode) so the selectors + segments stay live while open.
    final r = _remote;
    return r == null
        ? _buildDialog()
        : ListenableBuilder(listenable: r, builder: (_, _) => _buildDialog());
  }

  Widget _buildDialog() {
    const spinner = SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    // Collapse to 指派给成员 whenever the session modes are unavailable (no local
    // sessions AND no online desktop), regardless of the last-selected _mode —
    // on mobile the desktop can go offline mid-dialog.
    final mode = _showSessionModes ? _mode : 'member';
    if (mode == 'member') _requestMembers();
    final newSelectionValid = todoAssignNewSelectionValid(
      workspace: _workspace,
      project: _project,
      workspaceNames: _workspaceNames,
      projectNames: _projectNamesFor(_workspace),
    );
    final VoidCallback? primaryAction = _submitting
        ? null
        : mode == 'existing'
        ? (_remote != null ? _remoteAssignExisting : _assignToExisting)
        : mode == 'new'
        ? (newSelectionValid
              ? (_remote != null ? _remoteAssignNew : _assignToNew)
              : null)
        : (_loadingMembers || _pickedIdentity == null)
        ? null
        : _assignToMember;
    final dialogWidth = todoDialogWidth(MediaQuery.sizeOf(context));
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(_showSessionModes ? '一键指派' : '指派给成员'),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (phoneRemoteClient != null && !_remoteReady)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '桌面离线:已有会话/新建会话需要桌面 App 在线并已配对',
                    style: TextStyle(color: CcColors.muted, fontSize: 12),
                  ),
                ),
              if (_showSessionModes) ...[
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'existing', label: Text('已有会话')),
                    ButtonSegment(value: 'new', label: Text('新建会话')),
                    ButtonSegment(value: 'member', label: Text('指派成员')),
                  ],
                  selected: {_mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() {
                    _mode = s.first;
                    if (_mode == 'member') _requestMembers();
                  }),
                ),
                const SizedBox(height: 12),
              ],
              if (mode == 'existing')
                _existingForm()
              else if (mode == 'new')
                _newForm()
              else
                _memberForm(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: primaryAction,
          child: _submitting
              ? spinner
              : Text(mode == 'member' ? '指派' : '指派并开始'),
        ),
      ],
    );
  }

  // 未绑定 workspace/project 的孤儿会话 (c.workspace/c.project == '') 在下拉里
  // 显示成 "（未分组）"，但保留空字符串作为筛选值，跟真实 workspace 一致。
  static String _groupLabel(String name) => name.isEmpty ? '（未分组）' : name;

  // 已有会话的 workspace→project→会话 三级级联，跟 _newForm() 一个体验。
  Widget _existingForm() {
    final workspaces = {for (final c in _cards) c.workspace}.toList()..sort();
    final projects =
        _cards
            .where((c) => c.workspace == _existingWorkspace)
            .map((c) => c.project)
            .toSet()
            .toList()
          ..sort();
    final sessions = _cards
        .where(
          (c) =>
              c.workspace == _existingWorkspace &&
              c.project == _existingProject,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButton<String>(
          isExpanded: true,
          hint: const Text('workspace'),
          // Guard against a value no longer in items — remote session lists
          // (mobile) can change under an open dialog and a stale value asserts.
          value: workspaces.contains(_existingWorkspace)
              ? _existingWorkspace
              : null,
          items: [
            for (final w in workspaces)
              DropdownMenuItem(
                value: w,
                child: Text(
                  _groupLabel(w),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() {
            _existingWorkspace = v;
            final projs =
                _cards
                    .where((c) => c.workspace == v)
                    .map((c) => c.project)
                    .toSet()
                    .toList()
                  ..sort();
            _existingProject = projs.isEmpty ? null : projs.first;
            final sess = _cards
                .where((c) => c.workspace == v && c.project == _existingProject)
                .toList();
            _targetSid = sess.isEmpty ? null : sess.first.sid;
          }),
        ),
        const SizedBox(height: 8),
        DropdownButton<String>(
          isExpanded: true,
          hint: const Text('project'),
          value: projects.contains(_existingProject) ? _existingProject : null,
          items: [
            for (final p in projects)
              DropdownMenuItem(
                value: p,
                child: Text(
                  _groupLabel(p),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() {
            _existingProject = v;
            final sess = _cards
                .where(
                  (c) => c.workspace == _existingWorkspace && c.project == v,
                )
                .toList();
            _targetSid = sess.isEmpty ? null : sess.first.sid;
          }),
        ),
        const SizedBox(height: 8),
        DropdownButton<String>(
          isExpanded: true,
          hint: const Text('会话'),
          value: sessions.any((c) => c.sid == _targetSid) ? _targetSid : null,
          items: [
            for (final c in sessions)
              DropdownMenuItem(
                value: c.sid,
                // 同一 workspace/project 下可能有多个同名 label（比如两个
                // "kunlun-frontend" tab），有 worktree 名时拼上去帮着区分。
                child: Text(
                  c.worktree == null || c.worktree!.isEmpty
                      ? c.label
                      : '${c.label} · ${c.worktree}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _targetSid = v),
        ),
      ],
    );
  }

  Widget _newForm() {
    // Names come from remote roots (mobile) or local config (desktop). Guard the
    // Dropdown value against its item list — remote roots can arrive/refresh
    // after initState set a default, and a value not in items would assert.
    final wss = _workspaceNames;
    final projs = _projectNamesFor(_workspace);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButton<String>(
          isExpanded: true,
          hint: const Text('workspace'),
          value: wss.contains(_workspace) ? _workspace : null,
          items: wss
              .map(
                (w) => DropdownMenuItem(
                  value: w,
                  child: Text(w, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() {
            _workspace = v;
            final ps = _projectNamesFor(_workspace);
            _project = ps.isEmpty ? null : ps.first;
          }),
        ),
        const SizedBox(height: 8),
        DropdownButton<String>(
          isExpanded: true,
          hint: const Text('project'),
          value: projs.contains(_project) ? _project : null,
          items: projs
              .map(
                (p) => DropdownMenuItem(
                  value: p,
                  child: Text(p, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() => _project = v),
        ),
        const SizedBox(height: 8),
        DropdownButton<String>(
          isExpanded: true,
          value: _kind,
          items: const [
            DropdownMenuItem(value: 'claude', child: Text('Claude')),
            DropdownMenuItem(value: 'codex', child: Text('Codex')),
            DropdownMenuItem(value: 'shell', child: Text('Shell')),
          ],
          onChanged: (v) => setState(() => _kind = v ?? 'claude'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _branchCtl,
          decoration: const InputDecoration(
            labelText: '新建 worktree 分支名（可选）',
            isDense: true,
          ),
        ),
      ],
    );
  }
}

class _HelpText extends StatelessWidget {
  final String text;
  const _HelpText(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(height: 1.35)),
  );
}
