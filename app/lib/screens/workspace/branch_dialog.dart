part of '../workspace_page.dart';

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
  _BranchFilter _filter = _BranchFilter.all;

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

  int _countBranches(_BranchFilter filter) {
    return widget.branches.where((b) {
      return switch (filter) {
        _BranchFilter.all => true,
        _BranchFilter.local => !b.remote,
        _BranchFilter.remote => b.remote,
        _BranchFilter.current => b.current,
        _BranchFilter.unpublished => !b.remote && b.upstream.isEmpty,
        _BranchFilter.diverged => b.ahead > 0 || b.behind > 0,
      };
    }).length;
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
    final ctl = TextEditingController(text: _query.trim());
    final current = widget.branches
        .where((b) => b.current)
        .map((b) => b.name)
        .firstOrNull;
    final startCtl = TextEditingController(text: current ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分支'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '分支名'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: startCtl,
              decoration: const InputDecoration(labelText: '起点 ref(可选)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建并切换'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final branch = ctl.text.trim();
    if (branch.isEmpty) {
      if (mounted) snack(context, '分支名不能为空');
      return;
    }
    await _run(
      () => widget.onCreate(
        branch,
        startCtl.text.trim().isEmpty ? null : startCtl.text.trim(),
      ),
    );
  }

  Future<void> _renameBranch(GitBranch b) async {
    if (b.remote) return;
    final ctl = TextEditingController(text: b.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分支'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新分支名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重命名'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final next = ctl.text.trim();
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

  Widget _branchScopeChip(_BranchFilter filter, String label) {
    final selected = _filter == filter;
    final count = _countBranches(filter);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        label: Text('$label $count'),
        onSelected: (_) => setState(() => _filter = filter),
      ),
    );
  }

  Widget _branchesSummary() {
    final current = widget.branches.where((b) => b.current).firstOrNull;
    final localCount = _countBranches(_BranchFilter.local);
    final remoteCount = _countBranches(_BranchFilter.remote);
    final unpublishedCount = _countBranches(_BranchFilter.unpublished);
    final divergedCount = _countBranches(_BranchFilter.diverged);
    final currentLabel = current == null
        ? 'No current branch'
        : [
            current.name,
            if (current.upstream.isNotEmpty) current.upstream,
            if (current.ahead > 0 || current.behind > 0)
              '↑${current.ahead} ↓${current.behind}',
          ].join(' · ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
      decoration: const BoxDecoration(
        color: CcColors.editor,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Wrap(
        spacing: 7,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          tag(currentLabel, current == null ? CcColors.muted : CcColors.ok),
          tag('$localCount local', CcColors.muted),
          tag('$remoteCount remote', CcColors.muted),
          if (unpublishedCount > 0)
            tag('$unpublishedCount unpublished', CcColors.warning),
          if (divergedCount > 0)
            tag('$divergedCount ahead/behind', CcColors.warning),
        ],
      ),
    );
  }

  Widget _branchScopeBar() {
    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            _branchScopeChip(_BranchFilter.all, 'All'),
            _branchScopeChip(_BranchFilter.local, 'Local'),
            _branchScopeChip(_BranchFilter.remote, 'Remote'),
            _branchScopeChip(_BranchFilter.current, 'Current'),
            _branchScopeChip(_BranchFilter.unpublished, 'Unpublished'),
            _branchScopeChip(_BranchFilter.diverged, 'Ahead/Behind'),
          ],
        ),
      ),
    );
  }

  Widget _branchSection(String label, List<GitBranch> branches, IconData icon) {
    if (branches.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: CcColors.editorTabBar,
            border: Border(
              top: BorderSide(color: CcColors.border),
              bottom: BorderSide(color: CcColors.border),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: CcColors.muted),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '${branches.length}',
                style: CcType.code(size: 11, color: CcColors.subtle),
              ),
            ],
          ),
        ),
        for (final b in branches) _branchRow(b),
      ],
    );
  }

  Widget _branchRow(GitBranch b) {
    final kindText = b.current
        ? 'current branch'
        : b.remote
        ? 'remote · checkout creates ${b.localName ?? b.name}'
        : 'local branch';
    final age = b.lastDate == null ? '' : relativeTime(b.lastDate!);
    final meta = [
      kindText,
      if (b.upstream.isNotEmpty) 'tracks ${b.upstream}',
      if (b.lastHash.isNotEmpty)
        [
          b.lastHash,
          if (age.isNotEmpty) age,
          b.lastSubject,
        ].where((s) => s.isNotEmpty).join(' · '),
    ].join(' · ');
    final compact = widget.embedded;
    return Material(
      color: b.current
          ? CcColors.accent.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: b.current ? null : () => _checkout(b),
        onDoubleTap: b.current ? null : () => _checkout(b),
        child: Container(
          constraints: BoxConstraints(minHeight: compact ? 44 : 50),
          padding: const EdgeInsets.only(left: 12, right: 6),
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
                size: 17,
                color: b.current ? CcColors.accentBright : CcColors.muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            b.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CcType.code(
                              size: compact ? 12.5 : 13,
                              color: b.current ? CcColors.text : CcColors.muted,
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
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: CcColors.subtle),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (compact && !b.current)
                IconButton(
                  onPressed: () => _checkout(b),
                  icon: const Icon(Icons.login_rounded, size: 17),
                  tooltip: 'Checkout',
                  visualDensity: VisualDensity.compact,
                ),
              if (!compact && !b.current)
                TextButton(
                  onPressed: () => _checkout(b),
                  child: const Text('Checkout'),
                ),
              if (!compact && !b.remote && b.upstream.isEmpty)
                TextButton(
                  onPressed: () => _pushBranch(b, publish: true),
                  child: const Text('Publish'),
                ),
              if (!compact && !b.remote && b.upstream.isNotEmpty && b.ahead > 0)
                TextButton(
                  onPressed: () => _pushBranch(b),
                  child: const Text('Push'),
                ),
              if (!b.current && !compact)
                TextButton(
                  onPressed: () => _mergeBranch(b),
                  child: const Text('Merge'),
                ),
              if (!compact)
                TextButton(
                  onPressed: () => _run(() => widget.onCompare(b)),
                  child: const Text('Compare'),
                ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, size: 18),
                tooltip: '分支操作',
                onSelected: (v) {
                  if (v == 'checkout') _checkout(b);
                  if (v == 'compare') _run(() => widget.onCompare(b));
                  if (v == 'merge') _mergeBranch(b);
                  if (v == 'rebase') _rebaseBranch(b);
                  if (v == 'rename') _renameBranch(b);
                  if (v == 'delete') _deleteBranch(b);
                  if (v == 'forceDelete') _deleteBranch(b, force: true);
                  if (v == 'deleteRemote') _deleteRemoteBranch(b);
                  if (v == 'publish') _pushBranch(b, publish: true);
                  if (v == 'push') _pushBranch(b);
                },
                itemBuilder: (_) => [
                  if (!b.current)
                    const PopupMenuItem(
                      value: 'checkout',
                      child: Text('Checkout'),
                    ),
                  const PopupMenuItem(
                    value: 'compare',
                    child: Text('Compare with Current'),
                  ),
                  if (!b.current) ...[
                    const PopupMenuItem(
                      value: 'merge',
                      child: Text('Merge into Current'),
                    ),
                    const PopupMenuItem(
                      value: 'rebase',
                      child: Text('Rebase Current onto Selected'),
                    ),
                  ],
                  if (!b.remote) ...[
                    const PopupMenuDivider(),
                    if (b.upstream.isEmpty)
                      const PopupMenuItem(
                        value: 'publish',
                        child: Text('Publish Branch'),
                      ),
                    if (b.upstream.isNotEmpty)
                      const PopupMenuItem(
                        value: 'push',
                        child: Text('Push Branch'),
                      ),
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    if (!b.current)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    if (!b.current)
                      const PopupMenuItem(
                        value: 'forceDelete',
                        child: Text('Force Delete'),
                      ),
                  ],
                  if (b.remote) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'deleteRemote',
                      child: Text('Delete Remote Branch'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branches = _filteredBranches;
    final locals = branches.where((b) => !b.remote).toList();
    final remotes = branches.where((b) => b.remote).toList();
    return Column(
      children: [
        _branchesHeader(branches),
        _currentBranchHero(),
        _branchesSummary(),
        _branchScopeBar(),
        Expanded(
          child: widget.loading
              ? const Center(child: CircularProgressIndicator())
              : widget.error != null
              ? centerMsg(widget.error!, onRetry: widget.onRefresh)
              : branches.isEmpty
              ? centerMsg(widget.branches.isEmpty ? '没有分支' : '没有匹配分支')
              : ListView(
                  children: [
                    _branchSection(
                      'Local Branches',
                      locals,
                      Icons.account_tree_rounded,
                    ),
                    _branchSection(
                      'Remote Branches',
                      remotes,
                      Icons.cloud_queue_rounded,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
