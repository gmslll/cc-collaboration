import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../local/session_manager.dart';
import '../local/session_overview.dart';
import '../theme.dart';
import '../widgets.dart';

double sessionManagerDialogWidth(Size viewport, {double preferred = 480}) {
  final available = viewport.width - 24;
  if (!available.isFinite || available <= 0) return preferred;
  return viewport.width < 720 ? available : preferred.clamp(420.0, 520.0);
}

double sessionManagerDialogHeight(Size viewport, {double preferred = 680}) {
  final available = viewport.height - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

class WorkspaceFocusSurface extends StatelessWidget {
  final bool focused;
  final VoidCallback onExit;
  final Widget child;

  const WorkspaceFocusSurface({
    super.key,
    required this.focused,
    required this.onExit,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      if (focused) const SingleActivator(LogicalKeyboardKey.escape): onExit,
    },
    child: Focus(autofocus: focused, canRequestFocus: focused, child: child),
  );
}

class WorkspaceFocusTitle extends StatelessWidget {
  final bool enabled;
  final VoidCallback onToggle;
  final Widget child;

  const WorkspaceFocusTitle({
    super.key,
    required this.enabled,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onDoubleTap: enabled ? onToggle : null,
    child: child,
  );
}

class SessionManagerEntry extends StatelessWidget {
  final int count;
  final VoidCallback onPressed;

  const SessionManagerEntry({
    super.key,
    required this.count,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '打开全局会话管理器',
    child: InkWell(
      key: const ValueKey('session-manager-entry'),
      onTap: onPressed,
      borderRadius: BorderRadius.circular(CcRadius.sm),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: CcColors.borderSoft),
          borderRadius: BorderRadius.circular(CcRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.view_list_rounded,
              size: 14,
              color: CcColors.muted,
            ),
            const SizedBox(width: 6),
            Text(
              '$count sessions',
              style: CcType.code(size: 11.5, color: CcColors.subtle),
            ),
          ],
        ),
      ),
    ),
  );
}

class SessionManagerDialog extends StatefulWidget {
  final List<ManagedSession> sessions;
  final List<ManagedSession> Function()? sessionProvider;
  final String? activeId;
  final Set<String> pinnedIds;
  final Set<String> collapsedKeys;
  final ValueChanged<String> onOpen;
  final void Function(String id, bool pinned) onPinnedChanged;
  final Future<String?> Function(String id) onRename;
  final Future<bool> Function(String id) onClose;
  final Future<Set<String>> Function(Set<String> ids) onCloseCompleted;
  final void Function(String key, bool collapsed) onCollapsedChanged;

  const SessionManagerDialog({
    super.key,
    required this.sessions,
    this.sessionProvider,
    required this.activeId,
    required this.pinnedIds,
    required this.collapsedKeys,
    required this.onOpen,
    required this.onPinnedChanged,
    required this.onRename,
    required this.onClose,
    required this.onCloseCompleted,
    required this.onCollapsedChanged,
  });

  @override
  State<SessionManagerDialog> createState() => _SessionManagerDialogState();
}

class _SessionManagerDialogState extends State<SessionManagerDialog> {
  late final List<ManagedSession> _sessions = List.of(widget.sessions);
  late final Set<String> _pinned = Set.of(widget.pinnedIds);
  late final Set<String> _collapsed = Set.of(widget.collapsedKeys);
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'session-manager-search');
  SessionManagerFilter _filter = SessionManagerFilter.all;
  final Set<String> _closing = {};
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    if (widget.sessionProvider != null) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshSessions(),
      );
    }
  }

  void _refreshSessions() {
    final provider = widget.sessionProvider;
    if (provider == null || !mounted) return;
    final latest = provider();
    setState(() {
      _sessions
        ..clear()
        ..addAll(latest);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleCollapsed(String key) {
    final collapsed = !_collapsed.contains(key);
    setState(() {
      if (collapsed) {
        _collapsed.add(key);
      } else {
        _collapsed.remove(key);
      }
    });
    widget.onCollapsedChanged(key, collapsed);
  }

  void _togglePinned(String id) {
    final pinned = !_pinned.contains(id);
    setState(() {
      if (pinned) {
        _pinned.add(id);
      } else {
        _pinned.remove(id);
      }
    });
    widget.onPinnedChanged(id, pinned);
  }

  Future<void> _rename(String id) async {
    final name = await widget.onRename(id);
    if (name == null || !mounted) return;
    setState(() {
      final index = _sessions.indexWhere((session) => session.id == id);
      if (index >= 0) _sessions[index] = _sessions[index].copyWith(name: name);
    });
  }

  Future<void> _close(String id) async {
    if (!_closing.add(id)) return;
    setState(() {});
    final closed = await widget.onClose(id);
    if (!mounted) return;
    setState(() {
      _closing.remove(id);
      if (closed) {
        _sessions.removeWhere((session) => session.id == id);
        _pinned.remove(id);
      }
    });
  }

  Future<void> _closeCompleted(Iterable<ManagedSession> sessions) async {
    final ids = {
      for (final session in sessions)
        if (session.recentlyCompleted && !_closing.contains(session.id))
          session.id,
    };
    if (ids.isEmpty) return;
    setState(() => _closing.addAll(ids));
    final closed = await widget.onCloseCompleted(ids);
    if (!mounted) return;
    setState(() {
      _closing.removeAll(ids);
      _sessions.removeWhere((session) => closed.contains(session.id));
      _pinned.removeAll(closed);
    });
  }

  void _open(String id) {
    widget.onOpen(id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final filtered = filterManagedSessions(
      _sessions,
      query: _search.text,
      filter: _filter,
    );
    final groups = groupManagedSessions(filtered);
    final names = disambiguatedSessionNames(_sessions);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CcRadius.md),
        side: const BorderSide(color: CcColors.borderSoft),
      ),
      child: SizedBox(
        key: const ValueKey('session-manager-dialog'),
        width: sessionManagerDialogWidth(viewport),
        height: sessionManagerDialogHeight(viewport),
        child: ColoredBox(
          color: CcColors.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              _searchAndFilter(),
              const Divider(height: 1),
              Expanded(
                child: groups.isEmpty
                    ? _emptyState()
                    : ListView(
                        key: const ValueKey('session-manager-tree'),
                        padding: const EdgeInsets.only(bottom: 10),
                        children: [
                          for (final group in groups)
                            _workspaceGroup(group, names),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Container(
    height: 46,
    padding: const EdgeInsets.only(left: 14, right: 4),
    decoration: const BoxDecoration(
      color: CcColors.toolbar,
      border: Border(bottom: BorderSide(color: CcColors.border)),
    ),
    child: Row(
      children: [
        const Icon(Icons.view_list_rounded, size: 18, color: CcColors.muted),
        const SizedBox(width: 9),
        const Expanded(
          child: Text(
            '会话管理器',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          '${_sessions.length}',
          style: CcType.code(size: 11.5, color: CcColors.subtle),
        ),
        IconButton(
          key: const ValueKey('session-manager-close'),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: '关闭',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    ),
  );

  Widget _searchAndFilter() => Padding(
    padding: const EdgeInsets.fromLTRB(10, 10, 10, 9),
    child: Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 34,
            child: TextField(
              key: const ValueKey('session-manager-search'),
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                hintText: '搜索会话、项目、分支或预览',
                prefixIcon: const Icon(Icons.search_rounded, size: 17),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                          _searchFocus.requestFocus();
                        },
                        tooltip: '清空',
                        icon: const Icon(Icons.close_rounded, size: 15),
                      ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          height: 34,
          constraints: const BoxConstraints(maxWidth: 128),
          padding: const EdgeInsets.only(left: 9, right: 5),
          decoration: BoxDecoration(
            color: CcColors.bg.withValues(alpha: 0.35),
            border: Border.all(color: CcColors.border),
            borderRadius: BorderRadius.circular(CcRadius.sm),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<SessionManagerFilter>(
              key: const ValueKey('session-manager-filter'),
              value: _filter,
              isExpanded: true,
              borderRadius: BorderRadius.circular(CcRadius.md),
              style: const TextStyle(color: CcColors.muted, fontSize: 11.5),
              icon: const Icon(Icons.filter_list_rounded, size: 16),
              items: [
                for (final filter in SessionManagerFilter.values)
                  DropdownMenuItem(
                    value: filter,
                    child: Text(
                      sessionManagerFilterLabel(filter),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _filter = value);
              },
            ),
          ),
        ),
      ],
    ),
  );

  Widget _emptyState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.search_off_rounded, size: 24, color: CcColors.subtle),
        const SizedBox(height: 8),
        Text(
          _sessions.isEmpty ? '暂无会话' : '没有匹配的会话',
          style: const TextStyle(color: CcColors.muted, fontSize: 12.5),
        ),
      ],
    ),
  );

  Widget _workspaceGroup(
    SessionWorkspaceGroup group,
    Map<String, String> names,
  ) {
    final key = 'workspace:${group.key}';
    final collapsed = _collapsed.contains(key);
    final allSessions = [
      for (final project in group.projects) ...project.sessions,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupHeader(
          key: ValueKey('session-workspace-${group.key}'),
          depth: 0,
          icon: group.isOther
              ? Icons.help_outline_rounded
              : Icons.workspaces_outline,
          label: group.name,
          count: allSessions.length,
          collapsed: collapsed,
          onTap: () => _toggleCollapsed(key),
          onCloseCompleted:
              allSessions.any((session) => session.recentlyCompleted)
              ? () => unawaited(_closeCompleted(allSessions))
              : null,
        ),
        if (!collapsed)
          for (final project in group.projects) _projectGroup(project, names),
      ],
    );
  }

  Widget _projectGroup(SessionProjectGroup group, Map<String, String> names) {
    final key = 'project:${group.key}';
    final collapsed = _collapsed.contains(key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupHeader(
          key: ValueKey('session-project-${group.key}'),
          depth: 1,
          icon: Icons.folder_outlined,
          label: group.name,
          tooltip: group.path.isEmpty ? group.name : group.path,
          count: group.sessions.length,
          collapsed: collapsed,
          onTap: () => _toggleCollapsed(key),
          onCloseCompleted:
              group.sessions.any((session) => session.recentlyCompleted)
              ? () => unawaited(_closeCompleted(group.sessions))
              : null,
        ),
        if (!collapsed)
          for (final session in group.sessions)
            _sessionRow(session, names[session.id] ?? session.name),
      ],
    );
  }

  Widget _groupHeader({
    required Key key,
    required int depth,
    required IconData icon,
    required String label,
    String? tooltip,
    required int count,
    required bool collapsed,
    required VoidCallback onTap,
    VoidCallback? onCloseCompleted,
  }) => Material(
    key: key,
    color: depth == 0
        ? CcColors.panelHigh.withValues(alpha: 0.45)
        : CcColors.panel,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        height: depth == 0 ? 36 : 32,
        child: Row(
          children: [
            SizedBox(width: depth == 0 ? 8 : 24),
            Icon(
              collapsed
                  ? Icons.chevron_right_rounded
                  : Icons.expand_more_rounded,
              size: 17,
              color: CcColors.subtle,
            ),
            const SizedBox(width: 3),
            Icon(icon, size: depth == 0 ? 16 : 14, color: CcColors.muted),
            const SizedBox(width: 7),
            Expanded(
              child: Tooltip(
                message: tooltip ?? label,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: depth == 0 ? 12.5 : 12,
                    fontWeight: depth == 0 ? FontWeight.w700 : FontWeight.w600,
                    color: depth == 0 ? CcColors.text : CcColors.muted,
                  ),
                ),
              ),
            ),
            Text(
              '$count',
              style: CcType.code(size: 10.5, color: CcColors.subtle),
            ),
            if (onCloseCompleted != null)
              PopupMenuButton<String>(
                key: ValueKey('session-group-menu-$label'),
                tooltip: '组操作',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_horiz_rounded, size: 16),
                onSelected: (value) {
                  if (value == 'close-completed') onCloseCompleted();
                },
                itemBuilder: (_) => [
                  ccMenuItem(
                    value: 'close-completed',
                    icon: Icons.done_all_rounded,
                    label: '关闭已完成',
                  ),
                ],
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    ),
  );

  Widget _sessionRow(ManagedSession session, String displayName) {
    final pinned = _pinned.contains(session.id);
    final closing = _closing.contains(session.id);
    final statusStyle = sessionStatusStyle(session.status);
    return Material(
      key: ValueKey('session-row-${session.id}'),
      color: session.id == widget.activeId
          ? CcColors.accent.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: closing ? null : () => _open(session.id),
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.only(left: 42, right: 3, top: 7, bottom: 7),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: session.id == widget.activeId
                    ? CcColors.accent
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              SessionActivityAvatar(
                seed: session.id,
                isAgent: session.agent.isNotEmpty && session.agent != 'shell',
                status: session.status,
                size: 20,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 130;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Tooltip(
                                message: displayName,
                                child: Text(
                                  displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: CcColors.text,
                                  ),
                                ),
                              ),
                            ),
                            if (!compact && session.agent.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Text(
                                session.agent,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CcType.code(
                                  size: 10.5,
                                  color: CcColors.subtle,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Expanded(
                              child: Tooltip(
                                message: session.subtitle,
                                child: Text(
                                  session.subtitle.isEmpty
                                      ? '项目根目录'
                                      : session.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CcType.code(
                                    size: 10.5,
                                    color: CcColors.muted,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            statusDot(
                              statusStyle.color,
                              size: 6,
                              glow: statusStyle.glow,
                            ),
                            if (!compact) ...[
                              const SizedBox(width: 5),
                              Text(
                                statusLabel(session.status),
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: statusStyle.color,
                                ),
                              ),
                            ],
                            if (!compact && session.lastActivity != null) ...[
                              const SizedBox(width: 7),
                              Text(
                                relativeTime(session.lastActivity!),
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: CcColors.subtle,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (!compact && session.preview.trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            session.preview.trim().replaceAll('\n', ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: CcColors.subtle,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
              IconButton(
                key: ValueKey('session-pin-${session.id}'),
                onPressed: closing ? null : () => _togglePinned(session.id),
                tooltip: pinned ? '取消固定' : '固定到顶部',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                  size: 15,
                  color: pinned ? CcColors.accentBright : CcColors.subtle,
                ),
              ),
              if (closing)
                const SizedBox(
                  width: 34,
                  height: 34,
                  child: Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                )
              else
                PopupMenuButton<String>(
                  key: ValueKey('session-menu-${session.id}'),
                  tooltip: '会话操作',
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_vert_rounded, size: 16),
                  onSelected: (value) {
                    if (value == 'rename') unawaited(_rename(session.id));
                    if (value == 'close') unawaited(_close(session.id));
                  },
                  itemBuilder: (_) => [
                    ccMenuItem(
                      value: 'rename',
                      icon: Icons.edit_rounded,
                      label: '重命名',
                    ),
                    ccMenuItem(
                      value: 'close',
                      icon: Icons.power_settings_new_rounded,
                      label: '结束会话',
                      danger: true,
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
