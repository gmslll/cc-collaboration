part of '../workspace_page.dart';

// A node in the branch path-tree: children keyed by path segment, plus an
// optional branch that lives at exactly this path. The optional branch lets a
// branch named like a folder prefix (local "origin" alongside remote
// "origin/main") coexist with the folder instead of overwriting it.
class _BranchNode {
  final Map<String, _BranchNode> children = {};
  GitBranch? branch;
}

class WorkspaceBranchCreateDraft {
  final String branch;
  final String startRef;

  const WorkspaceBranchCreateDraft({
    required this.branch,
    required this.startRef,
  });
}

class WorkspaceBranchCreateDialog extends StatefulWidget {
  final String initialBranch;
  final String initialStartRef;

  const WorkspaceBranchCreateDialog({
    super.key,
    this.initialBranch = '',
    this.initialStartRef = '',
  });

  @override
  State<WorkspaceBranchCreateDialog> createState() =>
      _WorkspaceBranchCreateDialogState();
}

class _WorkspaceBranchCreateDialogState
    extends State<WorkspaceBranchCreateDialog> {
  late final TextEditingController _branchCtl = TextEditingController(
    text: widget.initialBranch,
  );
  late final TextEditingController _startCtl = TextEditingController(
    text: widget.initialStartRef,
  );

  @override
  void dispose() {
    _branchCtl.dispose();
    _startCtl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(
    context,
    WorkspaceBranchCreateDraft(
      branch: _branchCtl.text,
      startRef: _startCtl.text,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建分支'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _branchCtl,
            autofocus: true,
            decoration: const InputDecoration(labelText: '分支名'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _startCtl,
            decoration: const InputDecoration(labelText: '起点 ref(可选)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建并切换')),
      ],
    );
  }
}

class WorkspaceBranchRenameDialog extends StatefulWidget {
  final String initialName;

  const WorkspaceBranchRenameDialog({super.key, required this.initialName});

  @override
  State<WorkspaceBranchRenameDialog> createState() =>
      _WorkspaceBranchRenameDialogState();
}

class _WorkspaceBranchRenameDialogState
    extends State<WorkspaceBranchRenameDialog> {
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
      title: const Text('重命名分支'),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        decoration: const InputDecoration(labelText: '新分支名'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('重命名')),
      ],
    );
  }
}

class _BranchDialog extends StatefulWidget {
  final ProjectCfg project;
  final Future<void> Function(GitBranch branch) onCheckout;
  final Future<void> Function(String branch, String? start) onCreate;
  final Future<void> Function(String oldName, String newName) onRename;
  final Future<void> Function(String branch, bool force) onDelete;
  final Future<void> Function(GitBranch branch) onDeleteRemote;
  final Future<void> Function(GitBranch branch, {bool publish}) onPushBranch;
  final Future<void> Function(GitBranch branch) onCompare;
  final Future<void> Function(GitBranch branch) onMerge;
  final Future<void> Function(GitBranch branch) onRebase;
  final Future<void> Function({bool prune}) onFetch;
  final Future<void> Function()? onPull;
  final Future<void> Function()? onPush;
  const _BranchDialog({
    required this.project,
    required this.onCheckout,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    required this.onDeleteRemote,
    required this.onPushBranch,
    required this.onCompare,
    required this.onMerge,
    required this.onRebase,
    required this.onFetch,
    this.onPull,
    this.onPush,
  });

  @override
  State<_BranchDialog> createState() => _BranchDialogState();
}

class _BranchDialogState extends State<_BranchDialog> {
  List<GitBranch> _branches = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final branches = await gitBranches(widget.project.path);
      if (!mounted) return;
      setState(() {
        _branches = branches;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 660,
        child: Column(
          children: [
            _DialogHeader(
              icon: Icons.account_tree_rounded,
              title: 'Branches · ${widget.project.name}',
              trailing: [
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: '刷新分支',
                  onPressed: _load,
                ),
              ],
            ),
            Expanded(
              child: _BranchListPane(
                project: widget.project,
                branches: _branches,
                loading: _loading,
                error: _error,
                embedded: false,
                onRefresh: _load,
                onCheckout: (branch) async {
                  await widget.onCheckout(branch);
                  if (context.mounted) Navigator.pop(context);
                },
                onCreate: widget.onCreate,
                onRename: widget.onRename,
                onDelete: widget.onDelete,
                onDeleteRemote: widget.onDeleteRemote,
                onPushBranch: widget.onPushBranch,
                onCompare: widget.onCompare,
                onMerge: (branch) async {
                  await widget.onMerge(branch);
                  if (context.mounted) Navigator.pop(context);
                },
                onRebase: (branch) async {
                  await widget.onRebase(branch);
                  if (context.mounted) Navigator.pop(context);
                },
                onFetch: widget.onFetch,
                onPull: widget.onPull,
                onPush: widget.onPush,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchListPane extends StatefulWidget {
  final ProjectCfg project;
  final List<GitBranch> branches;
  final bool loading;
  final String? error;
  final bool embedded;
  final Future<void> Function() onRefresh;
  final Future<void> Function(GitBranch branch) onCheckout;
  final Future<void> Function(String branch, String? start) onCreate;
  final Future<void> Function(String oldName, String newName) onRename;
  final Future<void> Function(String branch, bool force) onDelete;
  final Future<void> Function(GitBranch branch) onDeleteRemote;
  final Future<void> Function(GitBranch branch, {bool publish}) onPushBranch;
  final Future<void> Function(GitBranch branch) onCompare;
  final Future<void> Function(GitBranch branch) onMerge;
  final Future<void> Function(GitBranch branch) onRebase;
  final Future<void> Function({bool prune}) onFetch;
  final Future<void> Function()? onPull;
  final Future<void> Function()? onPush;

  const _BranchListPane({
    required this.project,
    required this.branches,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onCheckout,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    required this.onDeleteRemote,
    required this.onPushBranch,
    required this.onCompare,
    required this.onMerge,
    required this.onRebase,
    required this.onFetch,
    this.onPull,
    this.onPush,
    this.embedded = false,
  });

  @override
  State<_BranchListPane> createState() => _BranchListPaneState();
}

class _BranchListPaneState extends State<_BranchListPane> {
  final _queryCtl = TextEditingController();
  String _query = '';
  // Scope chips were dropped (per design); the filter stays fixed to "all" and
  // the search box does the narrowing. Kept so search still shares one pipeline.
  final _BranchFilter _filter = _BranchFilter.all;
  // Collapsed folder paths in the branch path-tree, e.g. 'origin/', 'origin/feature/'.
  final Set<String> _collapsedFolders = {};

  @override
  void dispose() {
    _queryCtl.dispose();
    super.dispose();
  }

  List<GitBranch> get _filteredBranches {
    final q = _query.trim().toLowerCase();
    return widget.branches.where((b) {
      final matchesFilter = switch (_filter) {
        _BranchFilter.all => true,
        _BranchFilter.local => !b.remote,
        _BranchFilter.remote => b.remote,
        _BranchFilter.current => b.current,
        _BranchFilter.unpublished => !b.remote && b.upstream.isEmpty,
        _BranchFilter.diverged => b.ahead > 0 || b.behind > 0,
      };
      if (!matchesFilter) return false;
      if (q.isEmpty) return true;
      final fields = [
        b.name,
        b.remoteName ?? '',
        b.localName ?? '',
        b.upstream,
        b.lastHash,
        b.lastSubject,
        b.remote ? 'remote' : 'local',
        if (b.current) 'current',
        if (!b.remote && b.upstream.isEmpty) 'unpublished',
        if (b.ahead > 0 || b.behind > 0) 'diverged ahead behind',
      ];
      return fields.any((f) => f.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) await widget.onRefresh();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _checkout(GitBranch b) async {
    if (b.current) return;
    await _run(() => widget.onCheckout(b));
  }

  Future<void> _createBranch() async {
    final current = widget.branches
        .where((b) => b.current)
        .map((b) => b.name)
        .firstOrNull;
    final draft = await showDialog<WorkspaceBranchCreateDraft>(
      context: context,
      builder: (_) => WorkspaceBranchCreateDialog(
        initialBranch: _query.trim(),
        initialStartRef: current ?? '',
      ),
    );
    if (draft == null) return;
    final branch = draft.branch.trim();
    if (branch.isEmpty) {
      if (mounted) snack(context, '分支名不能为空');
      return;
    }
    await _run(
      () => widget.onCreate(
        branch,
        draft.startRef.trim().isEmpty ? null : draft.startRef.trim(),
      ),
    );
  }

  Future<void> _renameBranch(GitBranch b) async {
    if (b.remote) return;
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => WorkspaceBranchRenameDialog(initialName: b.name),
    );
    if (raw == null) return;
    final next = raw.trim();
    if (next.isEmpty || next == b.name) return;
    await _run(() => widget.onRename(b.name, next));
  }

  Future<void> _deleteBranch(GitBranch b, {bool force = false}) async {
    if (b.remote || b.current) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(force ? '强制删除分支?' : '删除分支?'),
        content: Text(
          '${b.name}\n\n${force ? 'git branch -D' : 'git branch -d'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.onDelete(b.name, force));
  }

  Future<void> _deleteRemoteBranch(GitBranch b) async {
    if (!b.remote) return;
    final remote = b.remoteName ?? 'origin';
    final local = b.localName ?? b.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除远端分支?'),
        content: Text(
          '$remote/$local\n\n会执行 `git push $remote --delete $local`。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Remote'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.onDeleteRemote(b));
  }

  Future<void> _pushBranch(GitBranch b, {bool publish = false}) async {
    if (b.remote) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(publish ? 'Publish branch?' : 'Push branch?'),
        content: Text(
          publish
              ? '${b.name}\n\n会执行 `git push -u origin ${b.name}`。'
              : '${b.name}\n\n会执行 `git push origin ${b.name}`。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(publish ? 'Publish' : 'Push'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.onPushBranch(b, publish: publish));
  }

  Future<void> _mergeBranch(GitBranch b) async {
    if (b.current) return;
    await _run(() => widget.onMerge(b));
  }

  Future<void> _rebaseBranch(GitBranch b) async {
    if (b.current) return;
    await _run(() => widget.onRebase(b));
  }

  Widget _branchToolbarButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) => IconButton(
    icon: Icon(icon, size: 18),
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
  );

  Widget _branchesHeader(List<GitBranch> branches) {
    final compact = widget.embedded;
    return Container(
      padding: EdgeInsets.fromLTRB(12, 8, 8, compact ? 6 : 8),
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryCtl,
                  autofocus: !widget.embedded,
                  decoration: const InputDecoration(
                    hintText: '搜索或输入新分支名',
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                  onSubmitted: (_) {
                    final q = _query.trim();
                    final exact = branches
                        .where((b) => b.name == q || b.localName == q)
                        .firstOrNull;
                    if (exact != null) {
                      _checkout(exact);
                    } else {
                      _createBranch();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              if (!compact)
                FilledButton.icon(
                  onPressed: _createBranch,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('New Branch'),
                )
              else
                _branchToolbarButton(
                  icon: Icons.add_rounded,
                  tooltip: 'New Branch',
                  onPressed: _createBranch,
                ),
            ],
          ),
          SizedBox(height: compact ? 5 : 6),
          Row(
            children: [
              // In the embedded left panel, Fetch/Pull/Push already live in
              // _leftGitActionBar above — keep only branch-specific actions here.
              if (!widget.embedded)
                _branchToolbarButton(
                  icon: Icons.sync_rounded,
                  tooltip: 'Fetch',
                  onPressed: widget.loading
                      ? null
                      : () => _run(() => widget.onFetch()),
                ),
              _branchToolbarButton(
                icon: Icons.cleaning_services_outlined,
                tooltip: 'Fetch --prune',
                onPressed: widget.loading
                    ? null
                    : () => _run(() => widget.onFetch(prune: true)),
              ),
              if (!widget.embedded) ...[
                _branchToolbarButton(
                  icon: Icons.call_received_rounded,
                  tooltip: 'Pull --ff-only',
                  onPressed: widget.loading || widget.onPull == null
                      ? null
                      : () => _run(widget.onPull!),
                ),
                _branchToolbarButton(
                  icon: Icons.upload_rounded,
                  tooltip: 'Push',
                  onPressed: widget.loading || widget.onPush == null
                      ? null
                      : () => _run(widget.onPush!),
                ),
              ],
              const Spacer(),
              if (compact)
                Text(
                  '${branches.length}/${widget.branches.length}',
                  style: CcType.code(size: 10.8, color: CcColors.subtle),
                ),
              _branchToolbarButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新分支',
                onPressed: widget.onRefresh,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _currentBranchHero() {
    if (widget.embedded) return const SizedBox.shrink();
    final current = widget.branches.where((b) => b.current).firstOrNull;
    final currentName = current?.name ?? 'No current branch';
    final upstream = current?.upstream ?? '';
    final unpublished = current != null && !current.remote && upstream.isEmpty;
    final hasSync =
        current != null && (current.ahead > 0 || current.behind > 0);
    final meta = [
      widget.project.name,
      if (upstream.isNotEmpty) 'tracks $upstream',
      if (unpublished) 'unpublished',
      if (hasSync) '↑${current.ahead} ↓${current.behind}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: const BoxDecoration(
        color: CcColors.editor,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: CcColors.panelHigh,
              border: Border.all(color: CcColors.borderSoft),
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Icon(
              Icons.account_tree_rounded,
              size: 18,
              color: CcColors.accentBright,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  currentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(
                    size: 13,
                    color: CcColors.text,
                    weight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 11, color: CcColors.subtle),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (current != null && unpublished)
            _branchHeroButton(
              icon: Icons.publish_rounded,
              label: 'Publish',
              onPressed: widget.loading
                  ? null
                  : () =>
                        _run(() => widget.onPushBranch(current, publish: true)),
            )
          else if (current != null && current.ahead > 0)
            _branchHeroButton(
              icon: Icons.upload_rounded,
              label: 'Push ${current.ahead}',
              onPressed: widget.loading || widget.onPush == null
                  ? null
                  : () => _run(widget.onPush!),
            ),
          if (current != null && current.behind > 0)
            _branchHeroButton(
              icon: Icons.call_received_rounded,
              label: 'Pull ${current.behind}',
              onPressed: widget.loading || widget.onPull == null
                  ? null
                  : () => _run(widget.onPull!),
            ),
          _branchHeroButton(
            icon: Icons.add_rounded,
            label: 'New',
            onPressed: widget.loading ? null : _createBranch,
          ),
          _branchHeroButton(
            icon: Icons.sync_rounded,
            label: 'Fetch',
            onPressed: widget.loading
                ? null
                : () => _run(() => widget.onFetch()),
          ),
        ],
      ),
    );
  }

  Widget _branchHeroButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        visualDensity: VisualDensity.compact,
      ),
    ),
  );

  // _branchTree groups the visible branches into a path tree (names split on
  // '/') and renders collapsible folder rows + indented leaf branch rows —
  // "open it like a file tree", as requested.
  List<Widget> _branchTree(List<GitBranch> branches) {
    final root = _BranchNode();
    for (final b in branches) {
      var node = root;
      for (final seg in b.name.split('/')) {
        node = node.children.putIfAbsent(seg, () => _BranchNode());
      }
      node.branch = b; // a branch lives exactly at this path
    }
    return _branchNodes(root, 0, '');
  }

  List<Widget> _branchNodes(_BranchNode node, int depth, String prefix) {
    final entries = node.children.entries.toList()
      ..sort((a, b) {
        // folders (have children) first, then alphabetical
        final af = a.value.children.isNotEmpty;
        final bf = b.value.children.isNotEmpty;
        if (af != bf) return af ? -1 : 1;
        return a.key.compareTo(b.key);
      });
    final out = <Widget>[];
    for (final e in entries) {
      final n = e.value;
      if (n.children.isEmpty) {
        out.add(_branchLeafRow(n.branch!, depth, e.key)); // pure leaf
        continue;
      }
      // Folder node. A branch may ALSO live here (e.g. a local branch named
      // "origin" next to remote "origin/main") — render it as the folder's
      // first leaf child instead of colliding with the folder.
      final path = '$prefix${e.key}/';
      final collapsed = _collapsedFolders.contains(path);
      out.add(_branchFolderRow(e.key, path, depth, collapsed, _leafCount(n)));
      if (!collapsed) {
        if (n.branch != null) {
          out.add(_branchLeafRow(n.branch!, depth + 1, e.key));
        }
        out.addAll(_branchNodes(n, depth + 1, path));
      }
    }
    return out;
  }

  int _leafCount(_BranchNode node) {
    var n = node.branch != null ? 1 : 0;
    for (final c in node.children.values) {
      n += _leafCount(c);
    }
    return n;
  }

  Widget _branchFolderRow(
    String name,
    String path,
    int depth,
    bool collapsed,
    int count,
  ) => InkWell(
    onTap: () => setState(() {
      if (!_collapsedFolders.remove(path)) _collapsedFolders.add(path);
    }),
    child: Container(
      height: 30,
      padding: EdgeInsets.only(left: 8 + depth * 14.0, right: 10),
      color: CcColors.editorTabBar,
      child: Row(
        children: [
          Icon(
            collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded,
            size: 18,
            color: CcColors.muted,
          ),
          const SizedBox(width: 2),
          const Icon(Icons.folder_outlined, size: 15, color: CcColors.subtle),
          const SizedBox(width: 7),
          Text(
            name,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 7),
          Text('$count', style: CcType.code(size: 11, color: CcColors.subtle)),
        ],
      ),
    ),
  );

  // A leaf branch row: indented by tree [depth], labelled with the last path
  // segment. Left-click / double-click checks it out; every action lives on the
  // ⋮ button and the right-click menu (the inline Checkout/Publish/Merge/Compare
  // buttons were moved into that menu, per request).
  Widget _branchLeafRow(GitBranch b, int depth, String leafName) {
    final age = b.lastDate == null ? '' : relativeTime(b.lastDate!);
    final meta = [
      if (b.upstream.isNotEmpty) 'tracks ${b.upstream}',
      if (b.lastHash.isNotEmpty)
        [
          b.lastHash,
          if (age.isNotEmpty) age,
          b.lastSubject,
        ].where((s) => s.isNotEmpty).join(' · '),
    ].join(' · ');
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) async {
        final v = await showMenu<String>(
          context: context,
          position: menuPosAt(context, d.globalPosition),
          items: _branchMenuItems(b),
        );
        if (v != null && mounted) _onBranchMenu(v, b);
      },
      child: Material(
        color: b.current
            ? CcColors.accent.withValues(alpha: 0.08)
            : Colors.transparent,
        child: InkWell(
          onTap: b.current ? null : () => _checkout(b),
          onDoubleTap: b.current ? null : () => _checkout(b),
          child: Container(
            constraints: const BoxConstraints(minHeight: 42),
            padding: EdgeInsets.only(left: 8 + depth * 14.0, right: 4),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: b.current ? CcColors.accent : Colors.transparent,
                  width: 2,
                ),
                bottom: const BorderSide(color: CcColors.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  b.remote
                      ? Icons.cloud_queue_rounded
                      : Icons.account_tree_rounded,
                  size: 16,
                  color: b.current ? CcColors.accentBright : CcColors.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              leafName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CcType.code(
                                size: 12.5,
                                color: b.current
                                    ? CcColors.text
                                    : CcColors.muted,
                                weight: b.current
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (b.current) ...[
                            const SizedBox(width: 8),
                            tag('current', CcColors.ok),
                          ],
                          if (b.ahead > 0 || b.behind > 0) ...[
                            const SizedBox(width: 6),
                            tag('↑${b.ahead} ↓${b.behind}', CcColors.warning),
                          ],
                        ],
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: CcColors.subtle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 17),
                  tooltip: '分支操作',
                  onSelected: (v) => _onBranchMenu(v, b),
                  itemBuilder: (_) => _branchMenuItems(b),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onBranchMenu(String v, GitBranch b) {
    switch (v) {
      case 'checkout':
        _checkout(b);
      case 'compare':
        _run(() => widget.onCompare(b));
      case 'merge':
        _mergeBranch(b);
      case 'rebase':
        _rebaseBranch(b);
      case 'rename':
        _renameBranch(b);
      case 'delete':
        _deleteBranch(b);
      case 'forceDelete':
        _deleteBranch(b, force: true);
      case 'deleteRemote':
        _deleteRemoteBranch(b);
      case 'publish':
        _pushBranch(b, publish: true);
      case 'push':
        _pushBranch(b);
    }
  }

  List<PopupMenuEntry<String>> _branchMenuItems(GitBranch b) => [
    if (!b.current)
      ccMenuItem(
        value: 'checkout',
        icon: Icons.call_split_rounded,
        label: 'Checkout',
      ),
    ccMenuItem(
      value: 'compare',
      icon: Icons.difference_rounded,
      label: 'Compare with Current',
    ),
    if (!b.current) ...[
      ccMenuItem(
        value: 'merge',
        icon: Icons.merge_type_rounded,
        label: 'Merge into Current',
      ),
      ccMenuItem(
        value: 'rebase',
        icon: Icons.merge_type_rounded,
        label: 'Rebase Current onto Selected',
      ),
    ],
    if (!b.remote) ...[
      const PopupMenuDivider(),
      if (b.upstream.isEmpty)
        ccMenuItem(
          value: 'publish',
          icon: Icons.cloud_upload_rounded,
          label: 'Publish Branch',
        ),
      if (b.upstream.isNotEmpty)
        ccMenuItem(
          value: 'push',
          icon: Icons.upload_rounded,
          label: 'Push Branch',
        ),
      ccMenuItem(value: 'rename', icon: Icons.edit_rounded, label: 'Rename'),
      if (!b.current)
        ccMenuItem(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: 'Delete',
          danger: true,
        ),
      if (!b.current)
        ccMenuItem(
          value: 'forceDelete',
          icon: Icons.delete_outline_rounded,
          label: 'Force Delete',
          danger: true,
        ),
    ],
    if (b.remote) ...[
      const PopupMenuDivider(),
      ccMenuItem(
        value: 'deleteRemote',
        icon: Icons.delete_outline_rounded,
        label: 'Delete Remote Branch',
        danger: true,
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final branches = _filteredBranches;
    return Column(
      children: [
        _branchesHeader(branches),
        _currentBranchHero(),
        Expanded(
          child: widget.loading
              ? const Center(child: CircularProgressIndicator())
              : widget.error != null
              ? centerMsg(widget.error!, onRetry: widget.onRefresh)
              : branches.isEmpty
              ? centerMsg(widget.branches.isEmpty ? '没有分支' : '没有匹配分支')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: _branchTree(branches),
                ),
        ),
      ],
    );
  }
}
