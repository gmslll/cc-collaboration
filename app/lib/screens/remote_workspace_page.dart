import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xterm/xterm.dart';

import '../live_activity/live_activity.dart';
import '../local/diff_parse.dart';
import '../local/prefs.dart';
import '../remote/file_fs.dart';
import '../remote/remote_client.dart';
import '../terminal_mouse.dart' show terminalWheel;
import '../theme.dart';
import '../voice/speaker.dart';
import '../voice/stt.dart';
import '../widgets.dart';
import 'diff_split.dart';
import '../terminal_theme.dart';

// RemoteWorkspacePage is the phone's view of a desktop workspace shared over the
// relay: pick a terminal session to drive, or browse/read project code. The
// desktop must have "cast to phone" enabled (workspace toolbar).
class RemoteWorkspacePage extends StatefulWidget {
  final String relayUrl;
  final String token;
  // onLogout, when set, adds a logout action to the AppBar. The phone leaves it
  // null (logout lives in its 账号 tab); the web client passes it since this is
  // the whole app there.
  final Future<void> Function()? onLogout;
  const RemoteWorkspacePage({
    super.key,
    required this.relayUrl,
    required this.token,
    this.onLogout,
  });

  @override
  State<RemoteWorkspacePage> createState() => _RemoteWorkspacePageState();
}

class _RemoteWorkspacePageState extends State<RemoteWorkspacePage>
    with WidgetsBindingObserver {
  late final RemoteClient _c = RemoteClient(
    relayUrl: widget.relayUrl,
    token: widget.token,
  );
  int _tab = 0; // 0 = 会话, 1 = 代码, 2 = Git
  // Collapsed project groups in the sessions tab, keyed by project path.
  final Set<String> _collapsedProjects = <String>{};
  DateTime? _pausedAt; // when the app last backgrounded (for resume reconnect)
  final List<String> _dirStack =
      []; // breadcrumb of opened dirs (empty = roots)
  String? _gitRepo; // selected repo in the Git tab (null = repo list)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_onClientChange);
    _c.onFileReceived = (name, path) {
      if (!mounted) return;
      snack(context, '📁 收到文件：$name（在「⇅」里打开）', background: CcColors.ok);
    };
    _c.connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onClientChange);
    _c.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      // A socket idle through minutes of OS suspension is usually dead, so force
      // a reconnect rather than wait out the ping timeout. But skip quick app
      // switches — dropping a healthy connection (3s reconnect) isn't worth it.
      final paused = _pausedAt;
      _pausedAt = null;
      if (paused != null &&
          DateTime.now().difference(paused) > const Duration(seconds: 10)) {
        _c.kick();
      }
    }
  }

  String? _lastGitOpErr;
  String? _lastCfgErr;
  DateTime? _lastNoticeAt; // newest notice already toasted (dedupes rebuilds)
  void _onClientChange() {
    if (!mounted) return;
    _lastGitOpErr = _toastIfNew(_c.gitOpError, _lastGitOpErr);
    _lastCfgErr = _toastIfNew(_c.cfgError, _lastCfgErr);
    final n = _c.notices.isNotEmpty ? _c.notices.first : null;
    if (n != null && n.at != _lastNoticeAt) {
      _lastNoticeAt = n.at;
      snack(context, '✅ ${n.title}：${n.body}', background: CcColors.ok);
    }
  }

  // _showNotices opens the in-app "任务通知" history and clears the unread badge.
  void _showNotices() {
    _c.markNoticesRead();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CcColors.panel,
      builder: (_) => SafeArea(
        child: _c.notices.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(28),
                child: Center(
                  child: Text('暂无通知', style: TextStyle(color: CcColors.muted)),
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      '通知',
                      style: TextStyle(
                        color: CcColors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final n in _c.notices)
                    ListTile(
                      leading: const Icon(
                        Icons.check_circle_outline_rounded,
                        color: CcColors.ok,
                      ),
                      title: Text(
                        n.title,
                        style: const TextStyle(color: CcColors.text),
                      ),
                      subtitle: Text(
                        '${n.body} · ${relativeTime(n.at)}',
                        style: const TextStyle(color: CcColors.muted),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  // Toast when an error field flips to a new value; returns the new "last seen".
  String? _toastIfNew(String? current, String? last) {
    if (current != null && current != last) snack(context, '操作失败：$current');
    return current;
  }

  // _showFileTransfer is the phone's file hub: send a file up to the desktop,
  // list files just sent (the picked local file), and open / share files the
  // desktop has sent down (landed in Documents/cc-recv).
  void _showFileTransfer() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CcColors.panel,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(
                Icons.upload_file_rounded,
                color: CcColors.accentBright,
              ),
              title: const Text(
                '发送文件到电脑',
                style: TextStyle(color: CcColors.text),
              ),
              subtitle: const Text(
                '落地到电脑 ~/Downloads/cc-recv',
                style: TextStyle(color: CcColors.muted),
              ),
              onTap: () {
                Navigator.pop(context);
                _sendFileToMac();
              },
            ),
            const Divider(height: 1),
            _fileSectionHeader('已发送'),
            if (_c.sentFiles.isEmpty) _fileSectionEmpty(),
            for (final f in _c.sentFiles) _fileTile(f.name, f.at, f.path),
            const Divider(height: 1),
            _fileSectionHeader('已收文件'),
            if (_c.receivedFiles.isEmpty) _fileSectionEmpty(),
            for (final f in _c.receivedFiles) _fileTile(f.name, f.at, f.path),
          ],
        ),
      ),
    );
  }

  // Shared bits for the transfer hub's "已发送" / "已收文件" sections.
  Widget _fileSectionHeader(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      label,
      style: const TextStyle(color: CcColors.subtle, fontSize: 12),
    ),
  );

  Widget _fileSectionEmpty() => const Padding(
    padding: EdgeInsets.all(20),
    child: Center(child: Text('暂无', style: TextStyle(color: CcColors.muted))),
  );

  Widget _fileTile(String name, DateTime at, String path) => ListTile(
    leading: const Icon(
      Icons.insert_drive_file_outlined,
      color: CcColors.muted,
    ),
    title: Text(name, style: const TextStyle(color: CcColors.text)),
    subtitle: Text(
      relativeTime(at),
      style: const TextStyle(color: CcColors.muted),
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.open_in_new_rounded, size: 20),
          tooltip: '打开',
          onPressed: () => OpenFilex.open(path),
        ),
        IconButton(
          icon: const Icon(Icons.ios_share_rounded, size: 20),
          tooltip: '分享 / 保存到「文件」',
          onPressed: () => Share.shareXFiles([XFile(path)]),
        ),
      ],
    ),
  );

  // _sendFileToMac picks a phone file and streams it up to the desktop host.
  Future<void> _sendFileToMac() async {
    final res = await FilePicker.platform.pickFiles();
    final path = res?.files.single.path;
    if (path == null || !mounted) return; // cancelled
    final name = path.split('/').last;
    snack(context, '正在发送 $name…');
    _c.sendFile(
      path,
      onDone: (ok, msg) {
        if (!mounted) return;
        snack(
          context,
          ok ? '已发送 $name' : '发送失败：$msg',
          background: ok ? CcColors.ok : CcColors.danger,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('远程工作区'),
          actions: [
            if (kFileTransferSupported)
              IconButton(
                tooltip: '文件传输',
                icon: Badge(
                  isLabelVisible: _c.receivedFiles.isNotEmpty,
                  label: Text('${_c.receivedFiles.length}'),
                  child: const Icon(Icons.swap_vert_rounded),
                ),
                onPressed: _c.connected ? _showFileTransfer : null,
              ),
            IconButton(
              tooltip: '通知',
              icon: Badge(
                isLabelVisible: _c.unreadNotices > 0,
                label: Text('${_c.unreadNotices}'),
                child: const Icon(Icons.notifications_none_rounded),
              ),
              onPressed: _showNotices,
            ),
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _c.connected ? _c.refresh : null,
            ),
            if (widget.onLogout != null)
              IconButton(
                tooltip: '登出',
                icon: const Icon(Icons.logout_rounded),
                onPressed: widget.onLogout,
              ),
          ],
        ),
        floatingActionButton: (_tab == 0 && _c.connected)
            ? FloatingActionButton.small(
                onPressed: _newSessionDialog,
                tooltip: '新建会话',
                child: const Icon(Icons.add),
              )
            : null,
        body: Column(
          children: [
            _statusBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('会话')),
                  ButtonSegment(value: 1, label: Text('代码')),
                  ButtonSegment(value: 2, label: Text('Git')),
                  ButtonSegment(value: 3, label: Text('管理')),
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
            ),
            Expanded(
              child: _tab == 0
                  ? _sessionsTab()
                  : _tab == 1
                  ? _codeTab()
                  : _tab == 2
                  ? _gitTab()
                  : _manageTab(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBanner() {
    final (color, text) = !_c.connected
        ? (CcColors.danger, _c.error == null ? '连接中…' : '未连接（${_c.error}）')
        : !_c.hostOnline && _c.sessions.isEmpty
        ? (CcColors.warning, '已连 relay · 等待电脑端开启「共享工作区」')
        : (CcColors.ok, '已连接电脑工作区');
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          statusDot(color, size: 7, glow: true),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // _rootForSession matches a session to its project by the longest root path
  // that is a prefix of the session's workdir (root itself or a subdir/worktree).
  RemoteRootInfo? _rootForSession(RemoteSession s) {
    RemoteRootInfo? best;
    for (final r in _c.roots) {
      if (s.workdir == r.path || s.workdir.startsWith('${r.path}/')) {
        if (best == null || r.path.length > best.path.length) best = r;
      }
    }
    return best;
  }

  // _rootsByWorkspace groups the shared projects by their workspace name.
  Map<String, List<RemoteRootInfo>> _rootsByWorkspace() {
    final byWs = <String, List<RemoteRootInfo>>{};
    for (final r in _c.roots) {
      (byWs[r.workspace] ??= []).add(r);
    }
    return byWs;
  }

  Widget _sessionsTab() {
    if (_c.sessions.isEmpty) {
      return centerMsg('没有会话。\n在电脑端起一个 Claude/Codex 会话，并打开工具栏的「共享给手机」。');
    }
    // Group sessions by workspace → project (matching workdir to a root); any
    // session not under a known root falls into "其他".
    final byWs = _rootsByWorkspace();
    final byProject = <String, List<RemoteSession>>{};
    final orphans = <RemoteSession>[];
    for (final s in _c.sessions) {
      final r = _rootForSession(s);
      if (r == null) {
        orphans.add(s);
      } else {
        (byProject[r.path] ??= []).add(s);
      }
    }

    final children = <Widget>[];
    for (final entry in byWs.entries) {
      final projects = entry.value
          .where((p) => byProject[p.path]?.isNotEmpty ?? false)
          .toList();
      if (projects.isEmpty) continue;
      children.add(_gitSection(entry.key.isEmpty ? '(默认工作区)' : entry.key));
      for (final p in projects) {
        final ss = byProject[p.path]!;
        final collapsed = _collapsedProjects.contains(p.path);
        children.add(
          _projectSubHeader(
            p.name,
            count: ss.length,
            collapsed: collapsed,
            onTap: () => setState(() {
              if (collapsed) {
                _collapsedProjects.remove(p.path);
              } else {
                _collapsedProjects.add(p.path);
              }
            }),
          ),
        );
        if (!collapsed) {
          for (final s in ss) {
            children.add(_sessionRow(s, root: p));
          }
        }
      }
    }
    if (orphans.isNotEmpty) {
      children.add(_gitSection('其他'));
      for (final s in orphans) {
        children.add(_sessionRow(s, root: null));
      }
    }
    return ListView(children: children);
  }

  // _projectSubHeader is a tappable project group header: a chevron (collapsed/
  // expanded), the folder + name, and the session count. Tapping toggles whether
  // its session rows are shown (see _collapsedProjects).
  Widget _projectSubHeader(
    String name, {
    required int count,
    required bool collapsed,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 14, 2),
      child: Row(
        children: [
          Icon(
            collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded,
            size: 18,
            color: CcColors.muted,
          ),
          const SizedBox(width: 2),
          const Icon(Icons.folder_rounded, size: 14, color: CcColors.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: CcColors.text,
              ),
            ),
          ),
          Text('$count', style: CcType.code(size: 11, color: CcColors.subtle)),
        ],
      ),
    ),
  );

  Widget _sessionRow(RemoteSession s, {RemoteRootInfo? root}) {
    // Worktree sessions live under <root>/.worktrees/<name>; show that name.
    final inWorktree = root != null && s.workdir != root.path;
    String? sub;
    if (root == null) {
      sub = s.workdir; // orphan — show the full path
    } else if (inWorktree) {
      final rel = s.workdir.substring(root.path.length + 1);
      sub = rel.startsWith('.worktrees/')
          ? rel.substring('.worktrees/'.length)
          : rel;
    }
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 22, right: 4),
      leading: Icon(
        s.agent == 'codex'
            ? Icons.smart_toy_outlined
            : Icons.play_arrow_rounded,
        color: CcColors.accentBright,
      ),
      title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: sub == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (inWorktree) ...[
                  const Icon(
                    Icons.account_tree_rounded,
                    size: 12,
                    color: CcColors.subtle,
                  ),
                  const SizedBox(width: 3),
                ],
                Flexible(
                  child: Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.code(size: 11.5, color: CcColors.subtle),
                  ),
                ),
              ],
            ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (v) {
          if (v == 'rename') _renameSessionDialog(s);
          if (v == 'close') _c.closeSession(s.sid);
        },
        itemBuilder: (_) => [
          ccMenuItem(value: 'rename', icon: Icons.edit_rounded, label: '重命名'),
          ccMenuItem(value: 'close', icon: Icons.close_rounded, label: '关闭'),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _RemoteTerminalScreen(client: _c, session: s),
        ),
      ),
    );
  }

  Future<void> _newSessionDialog() async {
    if (_c.roots.isEmpty) {
      snack(context, '没有可用项目');
      return;
    }
    var project = _c.roots.first;
    var agent = 'claude';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('新建会话'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<RemoteRootInfo>(
                isExpanded: true,
                value: project,
                items: [
                  for (final r in _c.roots)
                    DropdownMenuItem(value: r, child: Text(r.name)),
                ],
                onChanged: (v) => setLocal(() => project = v ?? project),
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                _c.newSession(project.path, agent);
                Navigator.pop(ctx);
              },
              child: const Text('启动'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameSessionDialog(RemoteSession s) async {
    final name = await textPrompt(
      context,
      title: '重命名会话',
      hint: '会话名称',
      initial: s.title,
      allowEmpty: true,
    );
    if (name != null) _c.renameSession(s.sid, name);
  }

  Widget _codeTab() {
    if (_dirStack.isEmpty) {
      if (_c.roots.isEmpty) return centerMsg('电脑端未共享项目');
      return ListView(
        children: [
          for (final r in _c.roots)
            ListTile(
              leading: const Icon(Icons.folder_rounded),
              title: Text(r.name),
              subtitle: Text(
                r.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 11, color: CcColors.subtle),
              ),
              onTap: () => _enterDir(r.path),
            ),
        ],
      );
    }
    final dir = _dirStack.last;
    return Column(
      children: [
        Material(
          color: CcColors.panel,
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_back_rounded, size: 20),
            title: Text(
              dir.split('/').last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            onTap: _leaveDir,
          ),
        ),
        const Divider(height: 1, color: CcColors.border),
        Expanded(
          child: _c.fsLoading
              ? const Center(child: CircularProgressIndicator())
              : _c.fsError != null
              ? centerMsg(_c.fsError!)
              : ListView.builder(
                  itemCount: _c.fsEntries.length,
                  itemBuilder: (_, i) {
                    final e = _c.fsEntries[i];
                    final child = '$dir/${e.name}';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        e.dir
                            ? Icons.folder_rounded
                            : Icons.description_outlined,
                        size: 18,
                        color: e.dir ? CcColors.accentBright : CcColors.muted,
                      ),
                      title: Text(
                        e.name,
                        style: CcType.code(size: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        if (e.dir) {
                          _enterDir(child);
                        } else {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  _RemoteFileViewer(client: _c, path: child),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _enterDir(String path) {
    setState(() => _dirStack.add(path));
    _c.openDir(path);
  }

  void _leaveDir() {
    setState(() => _dirStack.removeLast());
    if (_dirStack.isNotEmpty) _c.openDir(_dirStack.last);
  }

  Widget _gitTab() {
    if (_gitRepo == null) {
      if (_c.roots.isEmpty) return centerMsg('电脑端未共享项目');
      return ListView(
        children: [
          for (final r in _c.roots)
            ListTile(
              leading: const Icon(Icons.source_rounded),
              title: Text(r.name),
              subtitle: Text(
                r.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 11, color: CcColors.subtle),
              ),
              onTap: () {
                setState(() => _gitRepo = r.path);
                _c.openGit(r.path);
              },
            ),
        ],
      );
    }
    return Column(
      children: [
        Material(
          color: CcColors.panel,
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_back_rounded, size: 20),
            title: Text(
              _gitRepo!.split('/').last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              onPressed: _c.refreshGit,
            ),
            onTap: () => setState(() => _gitRepo = null),
          ),
        ),
        const Divider(height: 1, color: CcColors.border),
        _gitActions(),
        const Divider(height: 1, color: CcColors.border),
        Expanded(
          child: _c.gitLoading
              ? const Center(child: CircularProgressIndicator())
              : _c.gitError != null
              ? centerMsg(_c.gitError!)
              : ListView(
                  children: [
                    _gitSection('工作区改动 (${_c.gitChanges.length})'),
                    if (_c.gitChanges.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          '无改动',
                          style: TextStyle(color: CcColors.muted),
                        ),
                      ),
                    for (final c in _c.gitChanges)
                      ListTile(
                        dense: true,
                        leading: _gitBadge(c),
                        title: fileNameDirLabel(c.path),
                        trailing: _changeMenu(c),
                        onTap: c.untracked
                            ? null
                            : () => _openDiff(
                                () => _c.requestWorkingDiff(_gitRepo!, c.path),
                                c.path,
                              ),
                      ),
                    _gitSection('最近提交'),
                    for (final c in _c.gitCommits)
                      ListTile(
                        dense: true,
                        leading: Text(
                          c.short,
                          style: CcType.code(
                            size: 11,
                            color: CcColors.accentBright,
                          ),
                        ),
                        title: Text(
                          c.subject,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${c.author} · ${_shortDate(c.date)}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: CcColors.subtle,
                          ),
                        ),
                        onTap: () {
                          _c.requestCommitDiff(_gitRepo!, c.hash, c.subject);
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _RemoteCommitFiles(
                                client: _c,
                                title: '${c.short} ${c.subject}',
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _gitSection(String label) => Container(
    width: double.infinity,
    color: CcColors.bg,
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: CcColors.muted,
      ),
    ),
  );

  Widget _gitBadge(RemoteGitChange c) {
    final color = c.conflicted
        ? CcColors.danger
        : c.untracked
        ? CcColors.muted
        : c.staged
        ? CcColors.ok
        : CcColors.warning;
    return SizedBox(
      width: 22,
      child: Text(
        c.status,
        textAlign: TextAlign.center,
        style: CcType.code(size: 12, color: color),
      ),
    );
  }

  String _shortDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  void _openDiff(VoidCallback request, String title) {
    request();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _RemoteDiffViewer(client: _c, title: title),
      ),
    );
  }

  // --- Git operations UI ---

  Widget _gitActions() {
    final repo = _gitRepo!;
    Widget btn(IconData icon, String label, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
      ),
    );
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        children: [
          btn(Icons.add_task_rounded, '暂存全部', () => _c.gitStageAll(repo)),
          btn(Icons.check_circle_outline_rounded, '提交', _commitDialog),
          btn(
            Icons.arrow_upward_rounded,
            'Push',
            () => _confirmThen('确认 Push 到远程？', () => _c.gitPush(repo)),
          ),
          btn(Icons.arrow_downward_rounded, 'Pull', () => _c.gitPull(repo)),
          btn(Icons.sync_rounded, 'Fetch', () => _c.gitFetch(repo)),
          btn(Icons.account_tree_outlined, '分支', _branchSheet),
          btn(Icons.inventory_2_outlined, 'Stash', _stashDialog),
          btn(
            Icons.undo_rounded,
            '丢弃全部',
            () => _confirmThen('丢弃所有改动？不可恢复', () => _c.gitDiscardAll(repo)),
          ),
        ],
      ),
    );
  }

  Widget _changeMenu(RemoteGitChange c) => PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert_rounded, size: 18),
    onSelected: (v) {
      switch (v) {
        case 'stage':
          _c.gitStage(_gitRepo!, c.path);
        case 'unstage':
          _c.gitUnstage(_gitRepo!, c.path);
        case 'discard':
          _confirmThen(
            '丢弃 ${c.path} 的改动？不可恢复',
            () => _c.gitDiscard(_gitRepo!, c.path),
          );
      }
    },
    itemBuilder: (_) => [
      if (!c.staged)
        ccMenuItem(value: 'stage', icon: Icons.add_rounded, label: '暂存'),
      if (c.staged)
        ccMenuItem(value: 'unstage', icon: Icons.remove_rounded, label: '取消暂存'),
      if (!c.untracked)
        ccMenuItem(
          value: 'discard',
          icon: Icons.undo_rounded,
          label: '丢弃',
          danger: true,
        ),
    ],
  );

  Future<void> _confirmThen(String msg, VoidCallback action) async {
    if (await confirm(context, msg)) action();
  }

  Future<void> _commitDialog() async {
    final ctl = TextEditingController();
    var push = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('提交'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctl,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(hintText: '提交信息'),
              ),
              CheckboxListTile(
                value: push,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('提交后 Push'),
                onChanged: (v) => setLocal(() => push = v ?? false),
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
              child: const Text('提交'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      _c.gitCommit(_gitRepo!, ctl.text.trim(), push: push);
    }
  }

  Future<void> _stashDialog() async {
    final msg = await textPrompt(
      context,
      title: 'Stash',
      hint: '备注（可选）',
      okLabel: 'Stash',
      allowEmpty: true,
    );
    if (msg != null) _c.gitStash(_gitRepo!, msg);
  }

  Future<void> _branchSheet() async {
    _c.loadBranches(_gitRepo!);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: _c,
        builder: (ctx, _) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('分支'),
                trailing: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _newBranchDialog();
                  },
                ),
              ),
              const Divider(height: 1, color: CcColors.border),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final b in _c.branches.where((b) => !b.remote))
                      ListTile(
                        dense: true,
                        leading: Icon(
                          b.current
                              ? Icons.check_rounded
                              : Icons.account_tree_outlined,
                          size: 18,
                          color: b.current ? CcColors.ok : CcColors.muted,
                        ),
                        title: Text(b.name),
                        onTap: b.current
                            ? null
                            : () {
                                Navigator.pop(ctx);
                                _c.gitCheckout(_gitRepo!, b.name);
                              },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _newBranchDialog() async {
    final b = await textPrompt(
      context,
      title: '新建分支',
      hint: '分支名',
      okLabel: '创建',
    );
    if (b != null) _c.gitCreateBranch(_gitRepo!, b);
  }

  // --- 管理 (workspace / project / worktree) ---

  Widget _manageTab() {
    final byWs = _rootsByWorkspace();
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: OutlinedButton.icon(
            onPressed: _newWorkspaceDialog,
            icon: const Icon(Icons.create_new_folder_outlined, size: 16),
            label: const Text('新建工作区'),
          ),
        ),
        if (byWs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('电脑端未共享项目', style: TextStyle(color: CcColors.muted)),
          ),
        for (final entry in byWs.entries) ...[
          _gitSection(entry.key.isEmpty ? '(默认工作区)' : entry.key),
          for (final p in entry.value)
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.folder_rounded,
                size: 18,
                color: CcColors.accentBright,
              ),
              title: Text(p.name),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, size: 18),
                onSelected: (v) {
                  if (v == 'wt') _openWorktrees(p);
                  if (v == 'rm') {
                    _confirmThen(
                      '从「${entry.key}」移除项目 ${p.name}？（磁盘文件保留）',
                      () => _c.removeProject(p.workspace, p.name),
                    );
                  }
                },
                itemBuilder: (_) => [
                  ccMenuItem(
                    value: 'wt',
                    icon: Icons.account_tree_rounded,
                    label: 'Worktree…',
                  ),
                  ccMenuItem(
                    value: 'rm',
                    icon: Icons.delete_outline_rounded,
                    label: '移除项目',
                    danger: true,
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => _addProjectDialog(entry.key),
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('添加项目'),
                ),
                const Spacer(),
                if (entry.key.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _confirmThen(
                      '删除工作区「${entry.key}」？（磁盘文件保留）',
                      () => _c.removeWorkspace(entry.key),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text('删除工作区'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _openWorktrees(RemoteRootInfo p) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _WorktreeScreen(client: _c, project: p),
    ),
  );

  Future<void> _newWorkspaceDialog() async {
    final nameCtl = TextEditingController();
    final pathCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建工作区'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              autofocus: true,
              decoration: const InputDecoration(hintText: '名称'),
            ),
            TextField(
              controller: pathCtl,
              decoration: const InputDecoration(hintText: '目录（可选，绝对路径）'),
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
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok == true && nameCtl.text.trim().isNotEmpty) {
      _c.newWorkspace(nameCtl.text.trim(), pathCtl.text.trim());
    }
  }

  Future<void> _addProjectDialog(String ws) async {
    final src = await textPrompt(
      context,
      title: '添加项目到「${ws.isEmpty ? "默认" : ws}」',
      hint: 'GitHub URL 或本地路径',
      okLabel: '添加',
    );
    if (src != null) _c.addProject(ws, src);
  }
}

// _KeyButton is one user-customizable entry in the on-screen key bar: a label
// and the raw bytes it sends via sendKeys. The functional buttons (copy/paste/
// scroll) are pinned separately and are not part of this editable list.
class _KeyButton {
  String label;
  String data;
  _KeyButton(this.label, this.data);
  Map<String, String> toJson() => {'label': label, 'data': data};
}

const String _kKeyBarPref = 'remote.keybar.v1';

List<_KeyButton> _defaultKeyButtons() => [
  _KeyButton('Esc', '\x1b'),
  _KeyButton('Tab', '\t'),
  _KeyButton('Ctrl-C', '\x03'),
  _KeyButton('Ctrl-D', '\x04'),
  _KeyButton('↑', '\x1b[A'),
  _KeyButton('↓', '\x1b[B'),
  _KeyButton('←', '\x1b[D'),
  _KeyButton('→', '\x1b[C'),
  _KeyButton('Enter', '\r'),
  _KeyButton('/', '/'),
];

List<_KeyButton> _loadKeyButtons() {
  final raw = Prefs.getString(_kKeyBarPref, def: '');
  if (raw.isEmpty) return _defaultKeyButtons();
  try {
    final list = jsonDecode(raw);
    if (list is List) {
      final out = [
        for (final e in list)
          if (e is Map && e['label'] is String && e['data'] is String)
            _KeyButton(e['label'] as String, e['data'] as String),
      ];
      if (out.isNotEmpty) return out;
    }
  } catch (_) {}
  return _defaultKeyButtons();
}

void _saveKeyButtons(List<_KeyButton> keys) => Prefs.setString(
  _kKeyBarPref,
  jsonEncode([for (final k in keys) k.toJson()]),
);

// _decodeSeq turns a human-typed sequence (text + escapes) into the raw bytes
// to send: \e=Esc \t=Tab \r=Enter \n=newline \\=backslash, and ^X=Ctrl-X
// (^C→0x03, ^[→Esc). Unknown escapes pass the next char through literally.
String _decodeSeq(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length) {
      final n = s[++i];
      b.write(switch (n) {
        'e' => '\x1b',
        't' => '\t',
        'r' => '\r',
        'n' => '\n',
        _ => n,
      });
    } else if (c == '^' && i + 1 < s.length) {
      final code = s[++i].toUpperCase().codeUnitAt(0);
      if (code >= 64 && code <= 95) {
        b.writeCharCode(code & 0x1f);
      } else {
        b
          ..write('^')
          ..write(s[i]);
      }
    } else {
      b.write(c);
    }
  }
  return b.toString();
}

// _encodeSeq is the inverse, used to prefill the edit field from stored bytes.
String _encodeSeq(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    switch (r) {
      case 0x1b:
        b.write(r'\e');
      case 0x09:
        b.write(r'\t');
      case 0x0d:
        b.write(r'\r');
      case 0x0a:
        b.write(r'\n');
      case 0x5c:
        b.write(r'\\');
      default:
        if (r < 0x20) {
          b
            ..write('^')
            ..writeCharCode(r + 64);
        } else {
          b.writeCharCode(r);
        }
    }
  }
  return b.toString();
}

// Voice dictation mode for the phone terminal: off, or dictating (mic open,
// transcribing speech straight into the terminal until the user stops). No wake
// word — Android's recognizer can't reliably stay always-on, so the mic only
// runs during an explicit dictation session. See _RemoteTerminalScreenState.
enum _VoiceMode { off, dictating }

// _NoUserScroll forces inner Scrollables in its subtree to
// NeverScrollableScrollPhysics, so a finger drag can't scroll the phone's local
// terminal buffer. Used by _RemoteTerminalScreenState._wrapScroll for
// scroll-reporting TUIs, which scroll via host wheel reports instead.
class _NoUserScroll extends ScrollBehavior {
  const _NoUserScroll();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const NeverScrollableScrollPhysics();
}

// _RemoteTerminalScreen renders one remote session full-screen, with an on-screen
// key bar for the keys phone keyboards lack (agent TUIs need Esc/arrows/Ctrl-C).
class _RemoteTerminalScreen extends StatefulWidget {
  final RemoteClient client;
  final RemoteSession session;
  const _RemoteTerminalScreen({required this.client, required this.session});

  @override
  State<_RemoteTerminalScreen> createState() => _RemoteTerminalScreenState();
}

class _RemoteTerminalScreenState extends State<_RemoteTerminalScreen> {
  // Owned controller so the copy button can read the long-press selection.
  final TerminalController _controller = TerminalController();

  // Customizable on-screen key bar (shared across sessions via Prefs).
  late List<_KeyButton> _keys = _loadKeyButtons();

  // Voice dictation: tap to start a continuous recognizer; each finished
  // utterance is pasted into this session's input (reaches the host like _paste).
  // Control words: "停"/"停止" ends dictation, "发送"/"回车" presses Enter. Web-safe
  // (speech_to_text); on iOS Safari STT is unavailable and the button reports so.
  final SpeechInput _voice = SpeechInput();
  _VoiceMode _vmode = _VoiceMode.off;
  final List<String> _dbgLog = []; // recent voice events, shown above key bar
  // Spoken control words (matched on a full utterance for stop, as a substring
  // for send). _norm() normalizes case/spaces.
  static const List<String> _kStop = ['停', '停止', '结束', '停止听写', '关闭'];
  static const List<String> _kSend = ['发送', '回车'];

  // Read AI replies aloud on the phone. The desktop pushes the clean reply text
  // (RemoteClient.onReplyText); we speak it via the web-safe Speaker when the
  // toggle is on. Persisted per device.
  final Speaker _speaker = Speaker();
  bool _ttsOn = Prefs.getBool('remote.tts');

  // iOS Live Activity (Dynamic Island): started lazily the first time the agent
  // goes "working" so an idle island never lingers, updated on each status push,
  // and ended when leaving this session. No-op off iOS / when disabled.
  bool _laStarted = false;

  @override
  void initState() {
    super.initState();
    widget.client.onReplyText = _onReplyText;
    widget.client.onAgentStatus = _onAgentStatus;
  }

  void _onAgentStatus(String sid, bool working, String text) {
    if (sid != widget.session.sid) return;
    if (working && !_laStarted) {
      _laStarted = true;
      final title = widget.session.title.isNotEmpty
          ? widget.session.title
          : widget.session.agent;
      LiveActivity.start(title: title, sessionId: sid).then(
        (_) => LiveActivity.update(working: working, text: text),
      );
    } else if (_laStarted) {
      LiveActivity.update(working: working, text: text);
    }
  }

  Future<void> _onReplyText(String sid, String text) async {
    if (!_ttsOn || sid != widget.session.sid) return;
    // While dictating, pause the mic so it doesn't transcribe our own playback
    // and the two don't fight over the audio device. speak() returns when the
    // utterance finishes (Speaker uses awaitSpeakCompletion).
    if (_vmode == _VoiceMode.dictating) {
      await _voice.pause();
      await _speaker.speak(text);
      _voice.resume();
    } else {
      _speaker.speak(text);
    }
  }

  @override
  void dispose() {
    if (widget.client.onReplyText == _onReplyText) {
      widget.client.onReplyText = null;
    }
    if (widget.client.onAgentStatus == _onAgentStatus) {
      widget.client.onAgentStatus = null;
    }
    if (_laStarted) LiveActivity.end();
    _speaker.stop();
    _voice.dispose();
    _controller.dispose();
    super.dispose();
  }

  Terminal get _term => widget.client.terminalFor(widget.session.sid);

  // _setDbg keeps the last few recognizer events so a sequence (e.g. an error
  // immediately overwritten by a status change) stays visible, not just the last.
  void _setDbg(String s) {
    if (!mounted) return;
    setState(() {
      _dbgLog.add(s);
      if (_dbgLog.length > 4) _dbgLog.removeAt(0);
    });
  }

  // _toggleDictation turns dictation on/off. On: start the continuous recognizer
  // feeding _onUtterance. Off: stop it. A failure to start surfaces lastError so
  // the button never silently does nothing.
  Future<void> _toggleDictation() async {
    if (_vmode != _VoiceMode.off) {
      await _voice.stopContinuous();
      if (mounted) {
        setState(() {
          _vmode = _VoiceMode.off;
          _dbgLog.clear();
        });
        snack(context, '🎙️ 听写已关闭', clearPrevious: true);
      }
      return;
    }
    // Live diagnostics: surface every recognizer event so a silent failure is
    // visible in the HUD above the key bar.
    _voice.onListeningChange = (v) => _setDbg(v ? '🎙️ 监听中…' : '⏸️ 停(将重启)');
    _voice.onError = (e) => _setDbg('❌ $e');
    _voice.onDebug = _setDbg;
    final ok = await _voice.startContinuous(
      onFinal: _onUtterance,
      onPartial: (p) => _setDbg('👂 $p'),
    );
    if (!mounted) return;
    if (!ok) {
      snack(context, '语音不可用:${_voice.lastError ?? "检查麦克风/语音识别权限"}');
      return;
    }
    setState(() => _vmode = _VoiceMode.dictating);
    snack(context, '🔴 听写中,直接说话即可(说「停」或再点关闭)', clearPrevious: true);
  }

  // _onUtterance handles one finished transcript. A whole-utterance stop word
  // ends dictation; "发送"/"回车" presses Enter (words before it are injected,
  // words after are processed too); otherwise the text is pasted into the
  // terminal. Only FINAL results land here — partials would inject duplicates.
  void _onUtterance(String raw) {
    final t = raw.trim();
    _setDbg('✅ 终稿「$t」');
    if (t.isEmpty || !mounted) return;
    if (_kStop.contains(_norm(t))) {
      _toggleDictation(); // spoken stop = tapping the button off
      return;
    }
    for (final kw in _kSend) {
      final i = t.indexOf(kw);
      if (i >= 0) {
        final before = t.substring(0, i).trim();
        if (before.isNotEmpty) _inject(before);
        _sendEnter();
        final after = t.substring(i + kw.length).trim();
        if (after.isNotEmpty) _onUtterance(after);
        return;
      }
    }
    _inject(t);
  }

  void _inject(String text) {
    _term.paste(text); // routes through term.onOutput → host input
    snack(context, '🎤 $text', clearPrevious: true);
  }

  void _sendEnter() {
    widget.client.sendKeys(widget.session.sid, '\r');
    snack(context, '⏎ 已发送', clearPrevious: true);
  }

  // Normalizes case/spaces so a spoken control word matches regardless of the
  // recognizer's spacing.
  static String _norm(String s) =>
      s.toLowerCase().replaceAll(' ', '').replaceAll('　', '');

  void _copy() {
    final sel = _controller.selection;
    if (sel == null) {
      snack(context, '请先长按选择文本');
      return;
    }
    Clipboard.setData(ClipboardData(text: _term.buffer.getText(sel)));
    _controller.clearSelection();
    snack(context, '已复制');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    // term.paste routes through term.onOutput → term.input, so it reaches the host.
    if (text != null && text.isNotEmpty) _term.paste(text);
  }

  // Recreate the session's terminal (empty buffer) and re-open it; the host
  // replays its current backlog so the phone re-pulls the computer's latest
  // screen/history instead of staying on a stale or out-of-sync mirror.
  void _reload() {
    widget.client.reloadTerminal(widget.session.sid);
    setState(() {}); // rebind TerminalView to the fresh _term
    snack(context, '正在从电脑刷新…');
  }

  // Full-screen agents (claude/codex) run in the alternate screen (no
  // scrollback), so the phone scrolls them by sending wheel reports to the
  // host like a Mac wheel would. terminalWheel returns null when the app isn't
  // in a scroll-reporting mode (plain shell) — then we leave it to the
  // TerminalView's native touch scrollback.
  void _wheel(bool up, {int ticks = 1}) {
    final seq = terminalWheel(_term, up: up);
    if (seq != null) widget.client.sendKeys(widget.session.sid, seq * ticks);
  }

  // _clearScrollback wipes the phone's LOCAL scrollback (the history the host
  // replayed on connect, laid out at the COMPUTER's width — that's what looks
  // garbled when you swipe up). The current screen is kept (it's the latest,
  // already at the phone's width), and output from here on accumulates clean.
  // Trade-off: you can no longer scroll up to the pre-clear history — but that
  // part was unreadable anyway.
  void _clearScrollback() {
    _term.eraseScrollbackOnly();
    snack(context, '已清空本地历史(上滑乱码的来源)');
  }

  // Accumulated vertical drag distance, converted to wheel ticks once it
  // crosses a line-height threshold (swipe-to-scroll).
  double _scrollAccum = 0;
  static const double _linePx = 22;

  void _onPointerMove(PointerMoveEvent e) {
    // Only synthesize wheel for scroll-reporting TUIs; a plain shell keeps its
    // native touch scrollback (and selection) untouched since Listener doesn't
    // claim the gesture.
    if (!_term.mouseMode.reportScroll) return;
    _scrollAccum += e.delta.dy;
    while (_scrollAccum.abs() >= _linePx) {
      final up = _scrollAccum > 0; // finger down → reveal earlier output
      _wheel(up);
      _scrollAccum += up ? -_linePx : _linePx;
    }
  }

  // _wrapScroll disables the TerminalView's OWN inner Scrollable for
  // scroll-reporting TUIs (claude/codex). Those scroll by sending wheel reports
  // to the host (see _onPointerMove and the 滚↑/↓ buttons), and the host redraws
  // at the current width. If the local Scrollable also moved on a finger drag it
  // would expose the phone's local buffer — history laid out at the COMPUTER's
  // width — which renders mis-wrapped ("乱码"). Killing only user scrolling here
  // (programmatic stick-to-bottom still works) leaves the clean host-wheel path
  // as the sole scroll path. Plain shells (no reportScroll) keep native
  // scrollback. The inner Scrollable sets no explicit physics, so a
  // ScrollConfiguration override takes effect.
  Widget _wrapScroll(Widget child) => _term.mouseMode.reportScroll
      ? ScrollConfiguration(behavior: const _NoUserScroll(), child: child)
      : child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.title),
        actions: [
          IconButton(
            icon: Icon(
              _ttsOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            ),
            tooltip: _ttsOn ? '朗读已开启' : '朗读 AI 回复',
            onPressed: () {
              setState(() => _ttsOn = !_ttsOn);
              Prefs.setBool('remote.tts', _ttsOn);
              if (!_ttsOn) _speaker.stop();
              snack(context, _ttsOn ? '已开启朗读 AI 回复' : '已关闭朗读');
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新(拉取电脑最新)',
            onPressed: _reload,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Listener(
              onPointerDown: (_) => _scrollAccum = 0,
              onPointerMove: _onPointerMove,
              child: _wrapScroll(
                TerminalView(
                  _term,
                  controller: _controller,
                  theme: ccTerminalTheme,
                  textStyle: const TerminalStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12.5,
                  ),
                  padding: const EdgeInsets.all(8),
                ),
              ),
            ),
          ),
          if (_vmode != _VoiceMode.off) _voiceHud(),
          _keyBar(),
        ],
      ),
    );
  }

  // _voiceHud is a thin diagnostics line above the key bar (only while the voice
  // monitor is on) showing the recognizer's latest event — status / partial /
  // final / error — so a silent failure is visible at a glance.
  Widget _voiceHud() => Container(
    width: double.infinity,
    color: Colors.black87,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    child: Text(
      _dbgLog.isEmpty ? '🎙️ 等待识别…' : _dbgLog.join('  ·  '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.greenAccent, fontSize: 11),
    ),
  );

  Widget _keyBar() {
    Widget btn(String label, VoidCallback onPressed) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(label),
      ),
    );
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                children: [
                  // Functional buttons are pinned at the front (not reorderable).
                  btn('复制', _copy),
                  btn('粘贴', _paste),
                  btn(switch (_vmode) {
                    _VoiceMode.off => '🎙️ 听写',
                    _VoiceMode.dictating => '🔴 听写中',
                  }, _toggleDictation),
                  btn('滚↑', () => _wheel(true, ticks: 3)),
                  btn('滚↓', () => _wheel(false, ticks: 3)),
                  btn('清空', _clearScrollback),
                  for (final kb in _keys)
                    btn(
                      kb.label,
                      () => widget.client.sendKeys(widget.session.sid, kb.data),
                    ),
                ],
              ),
            ),
            // Pinned editor entry — always reachable regardless of scroll.
            IconButton(
              icon: const Icon(Icons.tune_rounded, size: 20),
              tooltip: '自定义按键',
              onPressed: _openKeyBarEditor,
            ),
          ],
        ),
      ),
    );
  }

  // _openKeyBarEditor lets the user add/edit/delete/reorder the key buttons and
  // restore defaults. Edits mutate _keys, persist to Prefs, and rebuild the bar.
  void _openKeyBarEditor() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          void apply(VoidCallback change) {
            change();
            _saveKeyButtons(_keys);
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
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '自定义按键',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => apply(() {
                          _keys = _defaultKeyButtons();
                        }),
                        child: const Text('恢复默认'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Flexible(
                    child: ReorderableListView(
                      shrinkWrap: true,
                      // onReorderItem already adjusts newIndex for the removed
                      // item, so no manual oldI/newI correction is needed.
                      onReorderItem: (oldI, newI) => apply(() {
                        _keys.insert(newI, _keys.removeAt(oldI));
                      }),
                      children: [
                        for (final kb in _keys)
                          ListTile(
                            key: ObjectKey(kb),
                            dense: true,
                            leading: const Icon(Icons.drag_handle, size: 20),
                            title: Text(kb.label),
                            subtitle: Text(
                              _encodeSeq(kb.data),
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 11,
                              ),
                            ),
                            onTap: () async {
                              final r = await _editKeyDialog(kb);
                              if (r != null) {
                                apply(() {
                                  kb.label = r.label;
                                  kb.data = r.data;
                                });
                              }
                            },
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              tooltip: '删除',
                              onPressed: () => apply(() => _keys.remove(kb)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () async {
                      final r = await _editKeyDialog(null);
                      if (r != null) apply(() => _keys.add(r));
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('添加按钮'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Common special keys (label → escaped form, standard xterm sequences). Picked
  // from a menu in the editor so users don't need to memorize escape codes.
  static const List<(String, String)> _specialKeys = [
    ('Shift+Tab', r'\e[Z'),
    ('Home', r'\e[H'),
    ('End', r'\e[F'),
    ('PgUp', r'\e[5~'),
    ('PgDn', r'\e[6~'),
    ('Insert', r'\e[2~'),
    ('Delete', r'\e[3~'),
    ('F1', r'\eOP'),
    ('F2', r'\eOQ'),
    ('F3', r'\eOR'),
    ('F4', r'\eOS'),
    ('F5', r'\e[15~'),
    ('F6', r'\e[17~'),
    ('F7', r'\e[18~'),
    ('F8', r'\e[19~'),
    ('F9', r'\e[20~'),
    ('F10', r'\e[21~'),
    ('F11', r'\e[23~'),
    ('F12', r'\e[24~'),
  ];

  // _editKeyDialog collects a label + send-sequence for a new/existing button.
  // It offers a combo builder (Ctrl/Alt/Shift + a base key), a special-keys
  // menu, and a free-text field (with \e/\r/^C escapes) as the source of truth.
  // Returns null on cancel / empty input.
  Future<_KeyButton?> _editKeyDialog(_KeyButton? existing) async {
    final labelCtl = TextEditingController(text: existing?.label ?? '');
    final seqCtl = TextEditingController(
      text: existing == null ? '' : _encodeSeq(existing.data),
    );
    final baseCtl = TextEditingController();
    var ctrl = false, alt = false, shift = false;

    final res = await showDialog<_KeyButton>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Compose modifiers + base key into the escaped sequence + a label.
          void recompose() {
            final base = baseCtl.text;
            if (base.isEmpty) return;
            final disp = base.substring(0, 1).toUpperCase();
            var b = shift ? disp : base.substring(0, 1);
            if (ctrl) b = '^${b.toUpperCase()}';
            if (alt) b = '\\e$b';
            seqCtl.text = b;
            final parts = [
              if (ctrl) 'Ctrl',
              if (alt) 'Alt',
              if (shift) 'Shift',
            ];
            labelCtl.text = parts.isEmpty ? disp : '${parts.join('-')}-$disp';
          }

          Widget modChip(String l, bool v, ValueChanged<bool> on) => FilterChip(
            label: Text(l),
            selected: v,
            visualDensity: VisualDensity.compact,
            onSelected: (s) => setLocal(() {
              on(s);
              recompose();
            }),
          );

          return AlertDialog(
            title: Text(existing == null ? '添加按钮' : '编辑按钮'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: labelCtl,
                    decoration: const InputDecoration(labelText: '按钮名称'),
                  ),
                  const SizedBox(height: 14),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '组合键',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      modChip('Ctrl', ctrl, (s) => ctrl = s),
                      modChip('Alt', alt, (s) => alt = s),
                      modChip('Shift', shift, (s) => shift = s),
                      SizedBox(
                        width: 56,
                        child: TextField(
                          controller: baseCtl,
                          decoration: const InputDecoration(
                            labelText: '键',
                            isDense: true,
                          ),
                          onChanged: (_) => setLocal(recompose),
                        ),
                      ),
                      PopupMenuButton<(String, String)>(
                        tooltip: '插入特殊键',
                        itemBuilder: (_) => [
                          for (final it in _specialKeys)
                            PopupMenuItem(value: it, child: Text(it.$1)),
                        ],
                        onSelected: (it) => setLocal(() {
                          seqCtl.text = it.$2;
                          labelCtl.text = it.$1;
                          ctrl = alt = shift = false;
                          baseCtl.clear();
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: CcColors.border),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.keyboard, size: 16),
                              SizedBox(width: 6),
                              Text('特殊键'),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: seqCtl,
                    decoration: const InputDecoration(
                      labelText: '发送内容',
                      helperText: r'\e=Esc  \r=回车  \t=Tab  ^C=Ctrl-C',
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
              FilledButton(
                onPressed: () {
                  final label = labelCtl.text.trim();
                  final seq = seqCtl.text;
                  if (label.isEmpty || seq.isEmpty) {
                    Navigator.pop(ctx);
                    return;
                  }
                  Navigator.pop(ctx, _KeyButton(label, _decodeSeq(seq)));
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    labelCtl.dispose();
    seqCtl.dispose();
    baseCtl.dispose();
    return res;
  }
}

// _RemoteFileViewer shows a read-only file's contents (mobile code viewing).
class _RemoteFileViewer extends StatefulWidget {
  final RemoteClient client;
  final String path;
  const _RemoteFileViewer({required this.client, required this.path});

  @override
  State<_RemoteFileViewer> createState() => _RemoteFileViewerState();
}

class _RemoteFileViewerState extends State<_RemoteFileViewer> {
  final _ctl = TextEditingController();
  bool _loaded = false;
  bool _dirty = false;
  bool _wasSaving = false;

  @override
  void initState() {
    super.initState();
    widget.client.openFile(widget.path);
    widget.client.addListener(_onChange);
    _ctl.addListener(() {
      if (_loaded && !_dirty) setState(() => _dirty = true);
    });
  }

  @override
  void dispose() {
    widget.client.removeListener(_onChange);
    _ctl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    final c = widget.client;
    // Populate the editor once the file content first arrives.
    if (!_loaded &&
        c.filePath == widget.path &&
        c.fileContent != null &&
        !c.fileLoading) {
      _ctl.text = c.fileContent!;
      _loaded = true;
    }
    // Save result feedback (saving true -> false).
    if (_wasSaving && !c.fileSaving) {
      if (c.fileSaveError != null) {
        snack(context, '保存失败：${c.fileSaveError}');
      } else {
        _dirty = false;
        snack(context, '已保存');
      }
    }
    _wasSaving = c.fileSaving;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.client;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.path.split('/').last}${_dirty ? ' •' : ''}',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '保存',
            icon: c.fileSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded),
            onPressed: (_dirty && !c.fileSaving)
                ? () => c.saveFile(widget.path, _ctl.text)
                : null,
          ),
        ],
      ),
      body: !_loaded
          ? (c.fileError != null
                ? centerMsg(c.fileError!)
                : const Center(child: CircularProgressIndicator()))
          : Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _ctl,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: CcType.code(size: 12.5),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
    );
  }
}

// _RemoteDiffViewer shows the diff the client just requested (a file's working
// diff or a commit's full diff), rendered with the shared colored diff widget.
class _RemoteDiffViewer extends StatefulWidget {
  final RemoteClient client;
  final String title;
  const _RemoteDiffViewer({required this.client, required this.title});

  @override
  State<_RemoteDiffViewer> createState() => _RemoteDiffViewerState();
}

class _RemoteDiffViewerState extends State<_RemoteDiffViewer> {
  // Side-by-side by default, matching the desktop (shares the 'diff.split' pref).
  bool _split = Prefs.getBool('diff.split', def: true);

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          actions: [
            _diffSplitAction(_split, (v) => setState(() => _split = v)),
          ],
        ),
        body: client.diffLoading
            ? const Center(child: CircularProgressIndicator())
            : client.diffError != null
            ? centerMsg(client.diffError!)
            : _zoomableDiff(client.diffContent ?? '', _split),
      ),
    );
  }
}

// _diffSplitAction is the compact 并排/统一 toggle for a diff screen's AppBar.
Widget _diffSplitAction(bool split, ValueChanged<bool> onChanged) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
  child: diffSplitToggle(
    split,
    onChanged,
    style: const ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  ),
);

// _zoomableDiff renders a raw unified diff at natural size inside an
// InteractiveViewer so the phone can pinch-zoom + pan (the diff is wider than
// the screen). constrained:false hands pan/zoom to the viewer instead of the
// diff's own scroll, avoiding a gesture conflict.
Widget _zoomableDiff(String raw, bool split) {
  if (raw.trim().isEmpty) return centerMsg('无差异');
  return ColoredBox(
    color: CcColors.bg,
    child: InteractiveViewer(
      constrained: false,
      minScale: 0.4,
      maxScale: 3.0,
      boundaryMargin: const EdgeInsets.all(80),
      child: split
          ? SplitDiff(raw, scroll: false)
          : IntrinsicWidth(
              child: diffText(raw, scrollable: false, highlight: true),
            ),
    ),
  );
}

// _RemoteCommitFiles shows a commit's file overview (parsed from its diff), then
// drills into a single file's diff on tap — like the desktop's changed-files
// tree → selected file.
class _RemoteCommitFiles extends StatefulWidget {
  final RemoteClient client;
  final String title;
  const _RemoteCommitFiles({required this.client, required this.title});

  @override
  State<_RemoteCommitFiles> createState() => _RemoteCommitFilesState();
}

class _RemoteCommitFilesState extends State<_RemoteCommitFiles> {
  String? _parsedFrom; // the diffContent we last parsed (skip re-parsing)
  List<FileDiff> _files = const [];

  List<FileDiff> _filesFor(String? content) {
    if (content == null) return const [];
    if (content != _parsedFrom) {
      _parsedFrom = content;
      _files = parseUnifiedDiff(content);
    }
    return _files;
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        Widget body;
        if (client.diffLoading) {
          body = const Center(child: CircularProgressIndicator());
        } else if (client.diffError != null) {
          body = centerMsg(client.diffError!);
        } else {
          final files = _filesFor(client.diffContent);
          body = files.isEmpty
              ? centerMsg('无差异')
              : ListView(
                  children: [
                    for (final f in files)
                      ListTile(
                        dense: true,
                        title: fileNameDirLabel(f.path),
                        trailing: fileDiffBadges(f),
                        onTap: () {
                          final (name, _) = splitFileNameDir(f.path);
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  _DiffScreen(title: name, raw: f.raw),
                            ),
                          );
                        },
                      ),
                  ],
                );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.title, overflow: TextOverflow.ellipsis),
          ),
          body: body,
        );
      },
    );
  }
}

// _DiffScreen renders one given unified-diff string (a single file from a
// commit) with the split/unified toggle + pinch-zoom.
class _DiffScreen extends StatefulWidget {
  final String title;
  final String raw;
  const _DiffScreen({required this.title, required this.raw});

  @override
  State<_DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<_DiffScreen> {
  bool _split = Prefs.getBool('diff.split', def: true);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title, overflow: TextOverflow.ellipsis),
      actions: [_diffSplitAction(_split, (v) => setState(() => _split = v))],
    ),
    body: _zoomableDiff(widget.raw, _split),
  );
}

// _WorktreeScreen lists a project's worktrees and lets the phone add/remove them.
class _WorktreeScreen extends StatefulWidget {
  final RemoteClient client;
  final RemoteRootInfo project;
  const _WorktreeScreen({required this.client, required this.project});

  @override
  State<_WorktreeScreen> createState() => _WorktreeScreenState();
}

class _WorktreeScreenState extends State<_WorktreeScreen> {
  @override
  void initState() {
    super.initState();
    widget.client.loadWorktrees(widget.project.path);
  }

  Future<void> _addDialog() async {
    final branchCtl = TextEditingController();
    final startCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建 worktree'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: branchCtl,
              autofocus: true,
              decoration: const InputDecoration(hintText: '分支名'),
            ),
            TextField(
              controller: startCtl,
              decoration: const InputDecoration(hintText: '起点（可选，如 main）'),
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
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok == true && branchCtl.text.trim().isNotEmpty) {
      widget.client.addWorktree(
        widget.project.workspace,
        widget.project.name,
        branchCtl.text.trim(),
        startCtl.text.trim(),
      );
    }
  }

  Future<void> _remove(RemoteWorktree w) async {
    final label = w.branch.isEmpty ? w.name : w.branch;
    if (await confirm(context, '删除 worktree $label？', okLabel: '删除')) {
      widget.client.removeWorktree(
        widget.project.workspace,
        widget.project.name,
        w.branch,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.client,
      builder: (context, _) {
        final wts = widget.client.worktrees;
        return Scaffold(
          appBar: AppBar(
            title: Text('${widget.project.name} · Worktrees'),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: '新建',
                onPressed: _addDialog,
              ),
            ],
          ),
          body: wts.isEmpty
              ? centerMsg('没有 worktree')
              : ListView(
                  children: [
                    for (final w in wts)
                      ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.account_tree_outlined,
                          size: 18,
                        ),
                        title: Text(
                          w.branch.isEmpty ? w.name : w.branch,
                          style: CcType.code(size: 13),
                        ),
                        subtitle: Text(
                          w.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(
                            size: 10.5,
                            color: CcColors.subtle,
                          ),
                        ),
                        trailing: w.path == widget.project.path
                            ? null
                            : IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                                onPressed: () => _remove(w),
                              ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
