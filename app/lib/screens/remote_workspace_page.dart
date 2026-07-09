import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xterm/xterm.dart';

import '../live_activity/live_activity.dart';
import '../local/diff_parse.dart';
import '../local/hook_activity.dart';
import '../local/path_utils.dart';
import '../local/prefs.dart';
import '../local/project_order.dart';
import '../local/remote_prefs.dart';
import '../local/session_overview.dart';
import '../remote/file_fs.dart';
import '../remote/file_transfer.dart';
import '../remote/remote_client.dart';
import '../screen_share/models.dart';
import '../syntax.dart';
import '../terminal_mouse.dart' show terminalWheel;
import '../terminal_snapshot_formatter.dart';
import '../theme.dart';
import '../voice/speaker.dart';
import '../voice/stt.dart';
import '../widgets.dart';
import '../widgets/session_snapshot_view.dart';
import 'diff_split.dart';
import '../terminal_theme.dart';

// RemoteWorkspacePage is the phone's view of a desktop workspace shared over the
// relay: pick a terminal session to drive, or browse/read project code. The
// desktop must have "cast to phone" enabled (workspace toolbar).
class RemoteWorkspacePage extends StatefulWidget {
  final String relayUrl;
  final String token;
  // onLogout/onSwitchAccount, when set, add account actions to the AppBar. The
  // phone leaves them null (account actions live in its 账号 tab); the web client
  // passes them since this is the whole app there.
  final Future<void> Function()? onLogout;
  final Future<void> Function()? onSwitchAccount;
  const RemoteWorkspacePage({
    super.key,
    required this.relayUrl,
    required this.token,
    this.onLogout,
    this.onSwitchAccount,
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
  // Project focus mode: when non-null, the sessions tab shows only this
  // project's sessions (tap a project name to enter, the top chip's ✕ to exit).
  // Persisted so the focus survives an app restart; '' in Prefs means no focus.
  String? _focusedProjectPath;
  DateTime? _pausedAt; // when the app last backgrounded (for resume reconnect)
  final List<String> _dirStack =
      []; // breadcrumb of opened dirs (empty = roots)
  String? _gitRepo; // selected repo in the Git tab (null = repo list)
  bool _offerDialogOpen = false; // guards against stacked accept/reject dialogs

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final focus = Prefs.getString('remote.focusProject', def: '');
    if (focus.isNotEmpty) _focusedProjectPath = focus;
    _c.addListener(_onClientChange);
    _c.onFileReceived = (name, path) {
      if (!mounted) return;
      snack(context, '📁 收到文件：$name（在「⇅」里打开）', background: CcColors.ok);
    };
    // A desktop file offer → prompt 接受/拒绝 (one dialog at a time).
    _c.onIncomingOffer = (_) => _pumpOffers();
    _c.connect();
    // Publish this connection so TodosPage's 一键指派 can reach the paired
    // desktop's sessions/roots + send a remote assign (see phoneRemoteClient).
    phoneRemoteClient = _c;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onClientChange);
    if (identical(phoneRemoteClient, _c)) phoneRemoteClient = null;
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

  void _setShowSessionContent(bool v) {
    Prefs.setBool(kRemoteShowSessionContentPref, v);
    setState(() {});
  }

  // _pumpOffers shows the accept/reject dialog for the next waiting incoming
  // offer, one at a time. Re-runs itself after each decision so a burst of
  // offers (or a second phone-less desktop send) queues instead of stacking.
  void _pumpOffers() {
    if (_offerDialogOpen || !mounted) return;
    FileXfer? offer;
    for (final x in _c.transfers) {
      if (x.dir == XferDir.recv && x.status == XferStatus.waiting) {
        offer = x;
        break;
      }
    }
    if (offer == null) return;
    _offerDialogOpen = true;
    final o = offer;
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: CcColors.panel,
        title: const Text('收到文件', style: TextStyle(color: CcColors.text)),
        content: Text(
          '${o.peerName ?? '电脑'} 想发送\n${o.name}（${_fmtBytes(o.size)}）',
          style: const TextStyle(color: CcColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒绝', style: TextStyle(color: CcColors.danger)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('接受'),
          ),
        ],
      ),
    ).then((accepted) {
      _offerDialogOpen = false;
      if (!mounted) return;
      // The sender may have cancelled while the dialog was up — only answer if
      // it's still pending.
      if (o.status == XferStatus.waiting) {
        if (accepted == true) {
          _c.acceptOffer(o.xid);
        } else {
          _c.rejectOffer(o.xid);
        }
      }
      _pumpOffers(); // next queued offer, if any
    });
  }

  // _showFileTransfer is the phone's file hub: send a file up to the desktop,
  // watch in-flight transfers, list files just sent, and open / share files the
  // desktop has sent down (landed in Documents/cc-recv).
  void _showFileTransfer() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CcColors.panel,
      // Rebuild on every client change so in-flight progress updates live.
      builder: (_) => ListenableBuilder(
        listenable: _c,
        builder: (context, _) {
          final active = _c.transfers.where((x) => x.inFlight).toList();
          return SafeArea(
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
                if (active.isNotEmpty) ...[
                  const Divider(height: 1),
                  _fileSectionHeader('传输中'),
                  for (final x in active) _xferTile(x),
                ],
                const Divider(height: 1),
                _fileSectionHeader('已发送'),
                if (_c.sentFiles.isEmpty) _fileSectionEmpty(),
                for (final f in _c.sentFiles) _fileTile(f.name, f.at, f.path),
                const Divider(height: 1),
                _fileSectionHeader('已收文件'),
                if (_c.receivedFiles.isEmpty) _fileSectionEmpty(),
                for (final f in _c.receivedFiles)
                  _fileTile(f.name, f.at, f.path),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showScreenShare() {
    _c.requestShareSources();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CcColors.panel,
      builder: (_) => SafeArea(
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            final sources = _c.shareSources;
            return ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    '屏幕共享',
                    style: TextStyle(
                      color: CcColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_c.shareLoading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_c.shareError != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '无法获取共享源：${_c.shareError}',
                      style: const TextStyle(color: CcColors.danger),
                    ),
                  )
                else if (sources.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '电脑端没有返回可共享的屏幕或窗口。请确认电脑端已开启「共享工作区」，并已授予屏幕录制权限。',
                      style: TextStyle(color: CcColors.muted),
                    ),
                  )
                else
                  for (final source in sources)
                    ListTile(
                      leading: Icon(
                        source.type.contains('window')
                            ? Icons.web_asset_rounded
                            : Icons.monitor_rounded,
                        color: CcColors.accentBright,
                      ),
                      title: Text(
                        source.name,
                        style: const TextStyle(color: CcColors.text),
                      ),
                      subtitle: Text(
                        source.type,
                        style: const TextStyle(color: CcColors.muted),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _openScreenShare(source);
                      },
                    ),
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('刷新列表'),
                  onTap: _c.requestShareSources,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _openScreenShare(ShareSource source) async {
    await _c.shareViewer.init();
    _c.startShare(source);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ScreenShareViewerPage(client: _c, source: source),
      ),
    );
  }

  // _xferTile renders one in-flight transfer: a direction icon, the file name,
  // a progress bar (indeterminate while still 等待接受) and a status line.
  Widget _xferTile(FileXfer x) {
    final sending = x.dir == XferDir.send;
    return ListTile(
      leading: Icon(
        sending ? Icons.upload_rounded : Icons.download_rounded,
        color: CcColors.accentBright,
      ),
      title: Text(x.name, style: const TextStyle(color: CcColors.text)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: x.status == XferStatus.waiting ? null : x.fraction,
                minHeight: 4,
                backgroundColor: CcColors.panel,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _xferStatusText(x),
              style: const TextStyle(color: CcColors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  String _xferStatusText(FileXfer x) {
    switch (x.status) {
      case XferStatus.waiting:
        return x.dir == XferDir.send ? '等待对方接受…' : '等待接受…';
      case XferStatus.active:
        return '${(x.fraction * 100).round()}% · '
            '${_fmtBytes(x.sent)} / ${_fmtBytes(x.size)}';
      case XferStatus.done:
        return '已完成';
      case XferStatus.rejected:
        return '已拒绝';
      case XferStatus.failed:
        return '失败';
      case XferStatus.cancelled:
        return '已取消';
    }
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
    child: Center(
      child: Text('暂无', style: TextStyle(color: CcColors.muted)),
    ),
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
    final name = pathBaseName(path);
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
      builder: (context, _) {
        final showSessionContent = Prefs.getBool(
          kRemoteShowSessionContentPref,
          def: kRemoteShowSessionContentDefault,
        );
        return Scaffold(
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
                tooltip: '屏幕共享',
                icon: const Icon(Icons.desktop_windows_rounded),
                onPressed: _c.connected ? _showScreenShare : null,
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
              if (_c.connected && _c.roots.length > 1)
                IconButton(
                  tooltip: '排序项目',
                  icon: const Icon(Icons.swap_vert_rounded),
                  onPressed: _openProjectOrderSheet,
                ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _c.connected ? _c.refresh : null,
              ),
              PopupMenuButton<String>(
                tooltip: '显示设置',
                icon: const Icon(Icons.tune_rounded),
                onSelected: (v) {
                  if (v == 'content') {
                    _setShowSessionContent(!showSessionContent);
                  }
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem<String>(
                    value: 'content',
                    checked: showSessionContent,
                    child: const Text('显示会话内容'),
                  ),
                ],
              ),
              if (widget.onLogout != null || widget.onSwitchAccount != null)
                PopupMenuButton<String>(
                  tooltip: '账号',
                  icon: const Icon(Icons.account_circle_rounded),
                  onSelected: (v) {
                    if (v == 'switch') widget.onSwitchAccount?.call();
                    if (v == 'logout') widget.onLogout?.call();
                  },
                  itemBuilder: (_) => [
                    if (widget.onSwitchAccount != null)
                      ccMenuItem(
                        value: 'switch',
                        icon: Icons.switch_account_rounded,
                        label: '切换账号',
                      ),
                    if (widget.onLogout != null)
                      ccMenuItem(
                        value: 'logout',
                        icon: Icons.logout_rounded,
                        label: '登出',
                      ),
                  ],
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
                    ? _sessionsTab(showSessionContent: showSessionContent)
                    : _tab == 1
                    ? _codeTab()
                    : _tab == 2
                    ? _gitTab()
                    : _manageTab(),
              ),
            ],
          ),
        );
      },
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
      if (pathWithin(s.workdir, r.path)) {
        if (best == null || r.path.length > best.path.length) best = r;
      }
    }
    return best;
  }

  // _orderedRoots applies this phone's local project-order overlay (by absolute
  // path) over the host-config-ordered _c.roots. Independent of the desktop's
  // order — each device keeps its own in its own Prefs.
  List<RemoteRootInfo> _orderedRoots() =>
      applyOrder(_c.roots, loadOrder(kPhoneProjectOrderKey), (r) => r.path);

  // _rootsByWorkspace groups the shared projects by their workspace name.
  Map<String, List<RemoteRootInfo>> _rootsByWorkspace() {
    final byWs = <String, List<RemoteRootInfo>>{};
    for (final r in _orderedRoots()) {
      (byWs[r.workspace] ??= []).add(r);
    }
    return byWs;
  }

  // _manageWorkspaces is _rootsByWorkspace seeded with ALL workspace names, so a
  // workspace with no projects yet still shows (with an empty list) — the manage
  // view needs it to add the first project / delete the workspace.
  Map<String, List<RemoteRootInfo>> _manageWorkspaces() {
    final byWs = <String, List<RemoteRootInfo>>{};
    for (final name in _c.workspaceNames) {
      byWs.putIfAbsent(name, () => []);
    }
    for (final r in _orderedRoots()) {
      (byWs[r.workspace] ??= []).add(r);
    }
    return byWs;
  }

  // 拖拽给项目排序——本机偏好（按 path 存进 Prefs），与桌面互相独立。
  // 镜像 _openKeyBarEditor。
  void _openProjectOrderSheet() {
    final items = List<RemoteRootInfo>.of(_orderedRoots());
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          void apply(VoidCallback change) {
            change();
            saveOrder(kPhoneProjectOrderKey, [for (final r in items) r.path]);
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
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '排序项目（本机）',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Flexible(
                    child: ReorderableListView(
                      shrinkWrap: true,
                      onReorderItem: (oldI, newI) =>
                          apply(() => items.insert(newI, items.removeAt(oldI))),
                      children: [
                        for (final r in items)
                          ListTile(
                            key: ObjectKey(r),
                            dense: true,
                            leading: const Icon(Icons.drag_handle, size: 20),
                            title: Text(
                              r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              r.workspace.isEmpty
                                  ? r.path
                                  : '${r.workspace} · ${r.path}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CcType.code(
                                size: 11,
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

  Widget _sessionsTab({required bool showSessionContent}) {
    if (_c.sessions.isEmpty) {
      return centerMsg('没有会话。\n点右下角 + 可新建 Shell / Claude / Codex / 总管会话。');
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

    // Project focus: show only the focused project's sessions, headed by a chip
    // that exits focus. If the focused project isn't currently shared, fall
    // through to the normal grouped view (focus self-heals if it reappears).
    final focusPath = _focusedProjectPath;
    if (focusPath != null) {
      final fp = _c.roots.where((r) => r.path == focusPath).firstOrNull;
      if (fp != null) {
        final ss = byProject[focusPath] ?? const <RemoteSession>[];
        return ListView(
          children: [
            _focusChip(fp),
            if (ss.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    '该项目暂无会话',
                    style: TextStyle(color: CcColors.muted),
                  ),
                ),
              )
            else
              _sessionCardWrap(
                ss,
                root: fp,
                showSessionContent: showSessionContent,
              ),
          ],
        );
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
            onToggle: () => setState(() {
              if (collapsed) {
                _collapsedProjects.remove(p.path);
              } else {
                _collapsedProjects.add(p.path);
              }
            }),
            onFocus: () => _enterFocus(p.path),
          ),
        );
        if (!collapsed) {
          children.add(
            _sessionCardWrap(
              ss,
              root: p,
              showSessionContent: showSessionContent,
            ),
          );
        }
      }
    }
    if (orphans.isNotEmpty) {
      children.add(_gitSection('其他'));
      children.add(
        _sessionCardWrap(
          orphans,
          root: null,
          showSessionContent: showSessionContent,
        ),
      );
    }
    return ListView(children: children);
  }

  void _enterFocus(String path) {
    setState(() => _focusedProjectPath = path);
    Prefs.setString('remote.focusProject', path);
  }

  void _exitFocus() {
    setState(() => _focusedProjectPath = null);
    Prefs.setString('remote.focusProject', '');
  }

  // _focusChip is the top-of-list banner shown while a project is focused: the
  // project name plus a ✕ to leave focus mode.
  Widget _focusChip(RemoteRootInfo p) => Container(
    margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
    padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
    decoration: BoxDecoration(
      color: CcColors.accent.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.center_focus_strong_rounded,
          size: 15,
          color: CcColors.accentBright,
        ),
        const SizedBox(width: 6),
        const Text(
          '专注：',
          style: TextStyle(fontSize: 12.5, color: CcColors.subtle),
        ),
        Expanded(
          child: Text(
            p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: CcColors.text,
            ),
          ),
        ),
        InkWell(
          onTap: _exitFocus,
          borderRadius: BorderRadius.circular(20),
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.close_rounded, size: 16, color: CcColors.muted),
          ),
        ),
      ],
    ),
  );

  // _projectSubHeader is a project group header: a chevron that toggles whether
  // its session rows show (onToggle), the folder + name (tapping the name enters
  // project focus — onFocus), and the session count.
  Widget _projectSubHeader(
    String name, {
    required int count,
    required bool collapsed,
    required VoidCallback onToggle,
    required VoidCallback onFocus,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 6, 14, 2),
    child: Row(
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(4),
          child: Icon(
            collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded,
            size: 18,
            color: CcColors.muted,
          ),
        ),
        const SizedBox(width: 2),
        const Icon(Icons.folder_rounded, size: 14, color: CcColors.muted),
        const SizedBox(width: 6),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onFocus,
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
        ),
        Text('$count', style: CcType.code(size: 11, color: CcColors.subtle)),
      ],
    ),
  );

  // _openTerminal pushes the full-screen mirrored terminal for a session.
  void _openTerminal(RemoteSession s) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _RemoteTerminalScreen(client: _c, session: s),
    ),
  );

  // _tapSession routes a card tap by the user's preference: straight into the
  // terminal by default, or the quick-reply preview popup when enabled (账号 ·
  // 点击会话先弹快捷预览). Read live so toggling it takes effect immediately.
  void _tapSession(RemoteSession s) {
    if (Prefs.getBool('remote.tapPreview')) {
      _openQuickReply(s);
    } else {
      _openTerminal(s);
    }
  }

  // _openQuickReply pops a preview + quick-reply sheet for a session so the user
  // can read its live screen and confirm/reply in place; "打开终端" still opens
  // the full mirror when more is needed.
  void _openQuickReply(RemoteSession s) {
    showDialog<void>(
      context: context,
      builder: (_) => _QuickReplyDialog(
        client: _c,
        session: s,
        onOpenTerminal: () {
          Navigator.of(context).pop();
          _openTerminal(s);
        },
      ),
    );
  }

  // _sessionCardWrap lays a project/worktree group's sessions out as a flowing
  // grid of glanceable cards (1 col on a phone, 2 on a wider tablet/landscape).
  Widget _sessionCardWrap(
    List<RemoteSession> ss, {
    RemoteRootInfo? root,
    required bool showSessionContent,
  }) {
    final w = MediaQuery.of(context).size.width;
    final cols = w >= 720 ? 2 : 1;
    final cardW = (w - 12 * 2 - (cols - 1) * 10) / cols;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final s in ss)
            _sessionCard(
              s,
              cardW,
              root: root,
              showSessionContent: showSessionContent,
            ),
        ],
      ),
    );
  }

  // _sessionCard renders one session: title + path + (when the desktop has
  // pushed an overview snapshot) status dot + token usage + a preview of the
  // agent's latest reply. Tapping opens the full-screen mirrored terminal, same
  // as before. Degrades gracefully (title + path only) until overview arrives.
  Widget _sessionCard(
    RemoteSession s,
    double width, {
    RemoteRootInfo? root,
    required bool showSessionContent,
  }) {
    final ov = _c.overview[s.sid];
    final inWorktree = root != null && s.workdir != root.path;
    String? sub;
    if (root == null) {
      sub = s.workdir; // orphan — show the full path
    } else if (inWorktree) {
      final rel = pathRelativeTo(root.path, s.workdir);
      sub = rel.startsWith('.worktrees/')
          ? rel.substring('.worktrees/'.length)
          : rel;
    }
    final status =
        ov?.status ??
        (s.agent.isNotEmpty ? SessionStatus.idle : SessionStatus.shell);
    return SizedBox(
      width: width,
      child: BreathingGlow(
        active: ov == null ? false : sessionStatusIsActive(ov.status),
        child: HoverLift(
          onTap: () => _tapSession(s),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SessionActivityAvatar(
                    seed: s.sid,
                    isAgent: s.agent.isNotEmpty,
                    status: status,
                    size: 26,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  SizedBox(
                    height: 26,
                    width: 26,
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_vert_rounded, size: 18),
                      onSelected: (v) {
                        if (v == 'rename') _renameSessionDialog(s);
                        if (v == 'close') _c.closeSession(s.sid);
                      },
                      itemBuilder: (_) => [
                        ccMenuItem(
                          value: 'rename',
                          icon: Icons.edit_rounded,
                          label: '重命名',
                        ),
                        ccMenuItem(
                          value: 'close',
                          icon: Icons.close_rounded,
                          label: '关闭',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (sub != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (inWorktree) ...[
                      const Icon(
                        Icons.account_tree_rounded,
                        size: 12,
                        color: CcColors.subtle,
                      ),
                      const SizedBox(width: 3),
                    ],
                    Expanded(
                      child: Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.code(size: 11, color: CcColors.subtle),
                      ),
                    ),
                  ],
                ),
              ],
              if (ov != null) ...[
                const SizedBox(height: 8),
                sessionStatusRow(
                  ov.status,
                  ov.usageLabel,
                  statusDetail: showSessionContent ? ov.statusDetail : '',
                ),
                if (showSessionContent && ov.recentActivity.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  sessionActivityList(ov.recentActivity),
                ],
              ],
              if (showSessionContent) ...[
                const SizedBox(height: 8),
                sessionPreviewBox(ov?.preview ?? ''),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _newSessionDialog() async {
    if (_c.roots.isEmpty) {
      snack(context, '没有可用项目');
      return;
    }
    // Default to the focused project when one is active.
    var project = _c.roots.firstWhere(
      (r) => r.path == _focusedProjectPath,
      orElse: () => _c.roots.first,
    );
    var agent = 'claude';
    var supervisorAgent = 'claude';
    var workdir = project.path; // '主仓' by default; a worktree path otherwise
    _c.loadWorktrees(project.path); // populate the worktree dropdown
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('新建会话'),
          // Rebuild on _c changes so the worktree list appears when wt.list.ok
          // lands; local state (project/agent/workdir) lives in the StatefulBuilder.
          content: ListenableBuilder(
            listenable: _c,
            builder: (ctx, _) {
              // Worktrees for THIS project only (the list is trusted once
              // wtProject matches); drop the main checkout — it's the '主仓' item.
              final wts = _c.wtProject == project.path
                  ? _c.worktrees.where((w) => w.path != project.path).toList()
                  : const <RemoteWorktree>[];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButton<RemoteRootInfo>(
                    isExpanded: true,
                    value: project,
                    items: [
                      for (final r in _orderedRoots())
                        DropdownMenuItem(
                          value: r,
                          child: Text(
                            r.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setLocal(() {
                      if (v == null || v == project) return;
                      project = v;
                      workdir = v.path; // reset to 主仓 for the new project
                      _c.loadWorktrees(v.path);
                    }),
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: workdir,
                    items: [
                      DropdownMenuItem(
                        value: project.path,
                        child: Text(
                          '主仓 (${project.name})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final w in wts)
                        DropdownMenuItem(
                          value: w.path,
                          child: Text(
                            w.branch.isEmpty ? pathBaseName(w.path) : w.branch,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setLocal(() => workdir = v ?? workdir),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: '',
                        icon: Icon(Icons.terminal_rounded, size: 16),
                        label: Text('Shell'),
                      ),
                      ButtonSegment(value: 'claude', label: Text('Claude')),
                      ButtonSegment(value: 'codex', label: Text('Codex')),
                      ButtonSegment(
                        value: 'supervisor',
                        icon: Icon(Icons.account_tree_outlined, size: 16),
                        label: Text('总管'),
                      ),
                    ],
                    selected: {agent},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setLocal(() => agent = s.first),
                  ),
                  if (agent == 'supervisor') ...[
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'claude', label: Text('Claude')),
                        ButtonSegment(value: 'codex', label: Text('Codex')),
                      ],
                      selected: {supervisorAgent},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) =>
                          setLocal(() => supervisorAgent = s.first),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _editSupervisorKnowledge(workdir),
                        icon: const Icon(Icons.menu_book_outlined, size: 18),
                        label: const Text('编辑知识库'),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final selectedAgent = agent == 'supervisor'
                    ? 'supervisor:$supervisorAgent'
                    : agent;
                _c.newSession(project.path, selectedAgent, workdir: workdir);
                Navigator.pop(ctx);
              },
              child: const Text('启动'),
            ),
          ],
        ),
      ),
    );
  }

  // Open the supervisor knowledge-base editor scoped to a workdir. Targets
  // <workdir>/.cc-handoff/supervisor — the same path `cc-handoff supervisor
  // context` reads relative to the launched session's CWD.
  Future<void> _editSupervisorKnowledge(String workdir) async {
    final dir = pathJoin(pathJoin(workdir, '.cc-handoff'), 'supervisor');
    await showDialog<void>(
      context: context,
      builder: (_) => _SupervisorKnowledgeDialog(client: _c, dir: dir),
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
          for (final r in _orderedRoots())
            ListTile(
              leading: const Icon(Icons.folder_rounded),
              title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
              pathBaseName(dir),
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
          for (final r in _orderedRoots())
            ListTile(
              leading: const Icon(Icons.source_rounded),
              title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
              pathBaseName(_gitRepo!),
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
                                () => _c.requestWorkingDiff(
                                  _gitRepo!,
                                  c.path,
                                  full: Prefs.getBool(
                                    'diff.fullContext',
                                    def: false,
                                  ),
                                ),
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
                          _c.requestCommitDiff(
                            _gitRepo!,
                            c.hash,
                            c.subject,
                            full: Prefs.getBool('diff.fullContext', def: false),
                          );
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
    final draft = await showDialog<RemoteCommitDraft>(
      context: context,
      builder: (_) => const RemoteCommitDialog(),
    );
    if (draft != null) {
      _c.gitCommit(_gitRepo!, draft.message, push: draft.push);
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
    final byWs = _manageWorkspaces();
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
            child: Text('电脑端未共享工作区', style: TextStyle(color: CcColors.muted)),
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
    final draft = await showDialog<RemoteWorkspaceDraft>(
      context: context,
      builder: (_) => const RemoteWorkspaceCreateDialog(),
    );
    if (draft != null) {
      _c.newWorkspace(draft.name, draft.path);
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

class ScreenShareViewerPage extends StatefulWidget {
  final RemoteClient client;
  final ShareSource source;

  const ScreenShareViewerPage({
    super.key,
    required this.client,
    required this.source,
  });

  @override
  State<ScreenShareViewerPage> createState() => _ScreenShareViewerPageState();
}

class _ScreenShareViewerPageState extends State<ScreenShareViewerPage> {
  RemoteClient get _c => widget.client;

  @override
  void dispose() {
    unawaited(_c.stopShare());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(widget.source.name),
          actions: [
            IconButton(
              tooltip: '停止共享',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        body: DecoratedBox(
          decoration: appGradient,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                color: CcColors.panel,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    statusDot(
                      _c.shareError == null ? CcColors.ok : CcColors.danger,
                      size: 7,
                      glow: true,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _c.shareError ?? _c.shareStatus,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _c.shareError == null
                              ? CcColors.muted
                              : CcColors.danger,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: Colors.black,
                  child: _c.shareViewer.initialized
                      ? RTCVideoView(
                          _c.shareViewer.renderer,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain,
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RemoteCommitDraft {
  final String message;
  final bool push;

  const RemoteCommitDraft({required this.message, required this.push});
}

class RemoteCommitDialog extends StatefulWidget {
  const RemoteCommitDialog({super.key});

  @override
  State<RemoteCommitDialog> createState() => _RemoteCommitDialogState();
}

class _RemoteCommitDialogState extends State<RemoteCommitDialog> {
  final _messageCtl = TextEditingController();
  bool _push = false;

  @override
  void dispose() {
    _messageCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final message = _messageCtl.text.trim();
    Navigator.pop(
      context,
      message.isEmpty ? null : RemoteCommitDraft(message: message, push: _push),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('提交'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _messageCtl,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(hintText: '提交信息'),
          ),
          CheckboxListTile(
            value: _push,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('提交后 Push'),
            onChanged: (v) => setState(() => _push = v ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('提交')),
      ],
    );
  }
}

class RemoteWorkspaceDraft {
  final String name;
  final String path;

  const RemoteWorkspaceDraft({required this.name, required this.path});
}

class RemoteWorkspaceCreateDialog extends StatefulWidget {
  const RemoteWorkspaceCreateDialog({super.key});

  @override
  State<RemoteWorkspaceCreateDialog> createState() =>
      _RemoteWorkspaceCreateDialogState();
}

class _RemoteWorkspaceCreateDialogState
    extends State<RemoteWorkspaceCreateDialog> {
  final _nameCtl = TextEditingController();
  final _pathCtl = TextEditingController();

  @override
  void dispose() {
    _nameCtl.dispose();
    _pathCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtl.text.trim();
    Navigator.pop(
      context,
      name.isEmpty
          ? null
          : RemoteWorkspaceDraft(name: name, path: _pathCtl.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建工作区'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '名称'),
          ),
          TextField(
            controller: _pathCtl,
            decoration: const InputDecoration(hintText: '目录（可选，绝对路径）'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}

class RemoteWorktreeDraft {
  final String branch;
  final String startPoint;

  const RemoteWorktreeDraft({required this.branch, required this.startPoint});
}

class RemoteWorktreeCreateDialog extends StatefulWidget {
  const RemoteWorktreeCreateDialog({super.key});

  @override
  State<RemoteWorktreeCreateDialog> createState() =>
      _RemoteWorktreeCreateDialogState();
}

class _RemoteWorktreeCreateDialogState
    extends State<RemoteWorktreeCreateDialog> {
  final _branchCtl = TextEditingController();
  final _startCtl = TextEditingController();

  @override
  void dispose() {
    _branchCtl.dispose();
    _startCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final branch = _branchCtl.text.trim();
    Navigator.pop(
      context,
      branch.isEmpty
          ? null
          : RemoteWorktreeDraft(
              branch: branch,
              startPoint: _startCtl.text.trim(),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建 worktree'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _branchCtl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '分支名'),
          ),
          TextField(
            controller: _startCtl,
            decoration: const InputDecoration(hintText: '起点（可选，如 main）'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
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
  // Match the desktop terminal: keep taps GUI-side so full-screen TUIs don't
  // consume selection gestures. Wheel/host scrolling is handled separately.
  final TerminalController _controller = TerminalController(
    pointerInputs: const PointerInputs.none(),
  );

  // Drives the TerminalView's inner Scrollable so we can force it to the bottom
  // after the host replays history on entry/reload — otherwise the view can land
  // at the TOP of the backlog (xterm disables stick-to-bottom when the Scrollable
  // attaches at offset 0 with content already present) and the user must scroll
  // down to reach the latest output. _stickTimer re-asserts bottom for a short
  // window to catch the async replay chunks; once at the bottom xterm sticks.
  final ScrollController _termScroll = ScrollController();
  Timer? _stickTimer;
  Timer? _wheelFlushTimer;
  int _pendingWheelTicks = 0;
  bool _localReviewScroll = Prefs.getBool('remote.localReviewScroll');

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

  // Latest usage label pushed alongside the agent status (model · context% ·
  // tokens · est. cost); null until the first status carries one. Shown as a
  // small chip over the mirrored terminal and folded into the Live Activity text.
  String? _usageLabel;

  // Terminal font size (phone). Smaller = more columns, so a wide full-screen
  // TUI like codex lays out properly instead of cramming into too few columns.
  // Persisted; changing it re-measures the view → term.resize → host repaints.
  double _fontSize = Prefs.getDouble('remote.termFontSize', def: 12.5);
  static const double _fontMin = 7.0;
  static const double _fontMax = 18.0;

  ({int cols, int rows}) _preferredViewport(BuildContext context) {
    final userCols = Prefs.getDouble('remote.defaultCols', def: 0).round();
    final userRows = Prefs.getDouble('remote.defaultRows', def: 0).round();
    if (userCols >= 2 && userRows >= 2) {
      return (cols: userCols, rows: userRows);
    }
    final mq = MediaQuery.of(context);
    final width = mq.size.width - 16; // TerminalView horizontal padding.
    final height =
        mq.size.height -
        mq.padding.top -
        kToolbarHeight -
        44 - // key bar
        mq.padding.bottom -
        16; // TerminalView vertical padding.
    final cellW = _fontSize * 0.62;
    final cellH = _fontSize * 1.38;
    return (
      cols: (width / cellW).floor().clamp(2, 500),
      rows: (height / cellH).floor().clamp(2, 500),
    );
  }

  void _updateDefaultViewport(BuildContext context) {
    widget.client.defaultViewport = _preferredViewport(context);
  }

  void _bumpFont(double delta) {
    final v = (_fontSize + delta).clamp(_fontMin, _fontMax);
    if (v == _fontSize) return;
    setState(() => _fontSize = v);
    Prefs.setDouble('remote.termFontSize', v);
    _updateDefaultViewport(context);
  }

  @override
  void initState() {
    super.initState();
    // History replay mode ('text'/'ansi') lives on the client and rides every
    // term.open; load the saved pref before the first _term access (build →
    // terminalFor → term.open) so the initial replay uses it.
    widget.client.historyMode = Prefs.getString(
      'remote.historyMode',
      def: 'text',
    );
    widget.client.onReplyText = _onReplyText;
    widget.client.onAgentStatus = _onAgentStatus;
    widget.client.onTerminalReset = _onTerminalReset;
    widget.client.addListener(_onClientChange);
    // Mark this session as the one being viewed (guards it from idle eviction).
    // If its local history went stale while we were away, it's dropped here and
    // re-pulled fresh from the desktop before the first build binds the view.
    final refreshed = widget.client.setViewedSession(widget.session.sid);
    _stickToBottomSoon(); // land at the latest output once the replay arrives
    // Whoever's watching redraws: once this screen has laid out, push THIS
    // device's viewport size to the host so the PTY follows the device that's
    // actually looking now — even if the cached Terminal's size didn't change
    // (so onResize wouldn't fire) and the PTY was left at another device's width.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.client.adoptSize(widget.session.sid);
    });
    if (refreshed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          snack(context, '已从电脑拉取最新（本地旧历史已清理）', clearPrevious: true);
        }
      });
    }
  }

  // After a reconnect-driven resync the client recreates this session's Terminal
  // (reloadTerminal); rebuild so the TerminalView rebinds to the fresh object and
  // shows the host's replayed latest screen — no manual 刷新 needed.
  void _onTerminalReset() {
    if (mounted) setState(() {});
    _stickToBottomSoon(); // the re-pull replays fresh content — re-anchor to bottom
    // The reconnect rebuilt the Terminal at the default 80x24; re-assert this
    // device's size once the rebound view lays out so the PTY follows it again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.client.adoptSize(widget.session.sid);
    });
  }

  // _stickToBottomSoon nudges the terminal to its bottom a few times over the
  // next ~750ms, so the host's async (chunked) history replay lands at the latest
  // output instead of the top. Once it's at the bottom xterm keeps sticking, so
  // this stops; it only runs on entry/reset, never fighting a mid-session scroll.
  void _stickToBottomSoon() {
    _stickTimer?.cancel();
    var ticks = 0;
    _scrollTermToBottom();
    _stickTimer = Timer.periodic(const Duration(milliseconds: 150), (t) {
      _scrollTermToBottom();
      if (++ticks >= 5 || !mounted) t.cancel();
    });
  }

  void _scrollTermToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_termScroll.hasClients) return;
      _termScroll.jumpTo(_termScroll.position.maxScrollExtent);
    });
  }

  void _onAgentStatus(String sid, bool working, String text, String? usage) {
    if (sid != widget.session.sid) return;
    if (usage != null && usage != _usageLabel && mounted) {
      setState(() => _usageLabel = usage); // refresh the on-terminal chip
    }
    // Fold the usage label into the Live Activity / Dynamic Island text so the
    // 灵动岛 shows "思考中…  ·  opus 4.8 · ctx 45% · 1.2M tok · ~$3.40".
    final laText = (usage != null && usage.isNotEmpty)
        ? '$text  ·  $usage'
        : text;
    if (working && !_laStarted) {
      _laStarted = true;
      final title = widget.session.title.isNotEmpty
          ? widget.session.title
          : widget.session.agent;
      LiveActivity.start(
        title: title,
        sessionId: sid,
      ).then((_) => LiveActivity.update(working: working, text: laText));
    } else if (_laStarted) {
      LiveActivity.update(working: working, text: laText);
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
    if (widget.client.onTerminalReset == _onTerminalReset) {
      widget.client.onTerminalReset = null;
    }
    widget.client.removeListener(_onClientChange);
    // Stop guarding this session from eviction; its idle TTL counts from now.
    widget.client.leaveViewedSession(widget.session.sid);
    if (_laStarted) LiveActivity.end();
    _stopScroll();
    _wheelFlushTimer?.cancel();
    _wheelFlushTimer = null;
    _pendingWheelTicks = 0;
    _stickTimer?.cancel();
    _termScroll.dispose();
    _speaker.stop();
    _voice.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onClientChange() {
    if (mounted) setState(() {});
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
    final text = XtermSnapshotFormatter(
      _term,
    ).plain(range: sel, trimTrailingBlankLines: false);
    Clipboard.setData(ClipboardData(text: text));
    _controller.clearSelection();
    snack(context, '已复制');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    // term.paste routes through term.onOutput → term.input, so it reaches the host.
    if (text != null && text.isNotEmpty) _term.paste(text);
  }

  // _sendImage picks an image and streams it up to the computer tagged with this
  // session's sid. The host saves it and pastes the saved path into this
  // session's terminal — same as the desktop paste-image flow, so the agent can
  // read the picture from disk.
  Future<void> _sendImage() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = res?.files.single.path;
    if (path == null || !mounted) return; // cancelled
    final name = pathBaseName(path);
    snack(context, '正在发送图片 $name…', clearPrevious: true);
    widget.client.sendFile(
      path,
      sid: widget.session.sid,
      onDone: (ok, msg) {
        if (!mounted) return;
        snack(
          context,
          ok ? '🖼️ 已发送，已贴到会话' : '发送失败：$msg',
          background: ok ? CcColors.ok : CcColors.danger,
          clearPrevious: true,
        );
      },
    );
  }

  // Recreate the session's terminal (empty buffer) and re-open it; the host
  // replays its current backlog so the phone re-pulls the computer's latest
  // screen/history instead of staying on a stale or out-of-sync mirror.
  void _reload() {
    widget.client.reloadTerminal(widget.session.sid);
    setState(() {}); // rebind TerminalView to the fresh _term
    snack(context, '正在从电脑刷新…');
  }

  // Claude runs as a full-screen TUI, so the phone scrolls it by sending wheel
  // reports to the host like a Mac wheel would. Codex keeps its transcript in
  // the main buffer with real scrollback; even when it enables mouse reporting,
  // the phone must keep native scrollback enabled so swipe-up can read history.
  bool get _canUseHostWheelScroll =>
      widget.session.agent.trim().toLowerCase() != 'codex' &&
      _term.mouseMode.reportScroll;

  bool get _usesHostWheelScroll =>
      _canUseHostWheelScroll && !_localReviewScroll;

  void _scrollLocal(bool up, {int ticks = 1}) {
    if (!_termScroll.hasClients) return;
    final pos = _termScroll.position;
    final delta = _linePx * ticks * (up ? -1 : 1);
    final next = (pos.pixels + delta)
        .clamp(0.0, pos.maxScrollExtent)
        .toDouble();
    _termScroll.jumpTo(next);
  }

  void _wheel(bool up, {int ticks = 1}) {
    if (!_usesHostWheelScroll) {
      _scrollLocal(up, ticks: ticks);
      return;
    }
    _pendingWheelTicks += up ? -ticks : ticks;
    _wheelFlushTimer ??= Timer(const Duration(milliseconds: 16), () {
      _wheelFlushTimer = null;
      final pending = _pendingWheelTicks;
      _pendingWheelTicks = 0;
      if (pending == 0 || !mounted) return;
      final seq = terminalWheel(_term, up: pending < 0);
      if (seq == null) return;
      widget.client.sendKeys(widget.session.sid, seq * pending.abs());
    });
  }

  // Hold-to-scroll: pressing 滚↑/滚↓ nudges once, then holding repeats the wheel
  // until release (see _scrollBtn). A quick tap = one nudge.
  Timer? _scrollHold;
  void _startScroll(bool up) {
    _wheel(up);
    _scrollHold?.cancel();
    _scrollHold = Timer.periodic(
      const Duration(milliseconds: 80),
      (_) => _wheel(up),
    );
  }

  void _stopScroll() {
    _scrollHold?.cancel();
    _scrollHold = null;
    _flushPendingWheel();
  }

  void _flushPendingWheel() {
    _wheelFlushTimer?.cancel();
    _wheelFlushTimer = null;
    final pending = _pendingWheelTicks;
    _pendingWheelTicks = 0;
    if (pending == 0 || !mounted) return;
    final seq = terminalWheel(_term, up: pending < 0);
    if (seq != null) {
      widget.client.sendKeys(widget.session.sid, seq * pending.abs());
    }
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

  // _toggleHistoryMode flips how pre-connect history is replayed: 文本(纯文本,
  // 默认)↔ 彩色(带颜色重排)。Persisted, then reload re-pulls history in the new
  // mode (term.open carries client.historyMode).
  void _toggleHistoryMode() {
    final c = widget.client;
    c.historyMode = c.historyMode == 'ansi' ? 'text' : 'ansi';
    Prefs.setString('remote.historyMode', c.historyMode);
    _reload(); // re-pulls history in the new mode + rebuilds the label (its snack)
  }

  void _toggleLocalReviewScroll() {
    setState(() => _localReviewScroll = !_localReviewScroll);
    Prefs.setBool('remote.localReviewScroll', _localReviewScroll);
    _flushPendingWheel();
    snack(
      context,
      _localReviewScroll ? '已切到本地查看滚动' : '已切到远程控制滚动',
      clearPrevious: true,
    );
  }

  Future<void> _setDefaultViewport() async {
    final current = _preferredViewport(context);
    final raw = await textPrompt(
      context,
      title: '默认终端尺寸',
      hint: '例如 ${current.cols}x${current.rows}',
      initial: '${current.cols}x${current.rows}',
      okLabel: '保存',
    );
    if (!mounted) return;
    if (raw == null) return;
    final m = RegExp(r'^\s*(\d+)\s*[xX*×,， ]\s*(\d+)\s*$').firstMatch(raw);
    if (m == null) {
      if (mounted) snack(context, '格式应为 列x行，例如 42x50');
      return;
    }
    final cols = int.parse(m.group(1)!);
    final rows = int.parse(m.group(2)!);
    if (cols < 2 || rows < 2) {
      if (mounted) snack(context, '尺寸太小，至少 2x2');
      return;
    }
    Prefs.setDouble('remote.defaultCols', cols.toDouble());
    Prefs.setDouble('remote.defaultRows', rows.toDouble());
    widget.client.defaultViewport = (cols: cols, rows: rows);
    if (mounted) snack(context, '默认尺寸已设为 ${cols}x$rows');
  }

  void _clearDefaultViewport() {
    Prefs.setDouble('remote.defaultCols', 0);
    Prefs.setDouble('remote.defaultRows', 0);
    _updateDefaultViewport(context);
    snack(context, '已改回自动估算尺寸');
  }

  void _showActivitySheet() {
    final items =
        widget.client.activities[widget.session.sid] ?? const <HookActivity>[];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CcColors.panel,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: SizedBox(
          height: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  '活动',
                  style: TextStyle(
                    color: CcColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无活动',
                          style: TextStyle(color: CcColors.muted),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        children: [
                          for (final a in items.take(40))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _activityRow(a, expanded: true),
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

  // Accumulated vertical drag distance, converted to wheel ticks once it
  // crosses a line-height threshold (swipe-to-scroll).
  double _scrollAccum = 0;
  static const double _linePx = 22;

  void _onPointerMove(PointerMoveEvent e) {
    // Only synthesize wheel for host-scrolled TUIs. Codex and plain shells keep
    // native touch scrollback (and selection) untouched since Listener doesn't
    // claim the gesture.
    if (!_usesHostWheelScroll) return;
    // Don't scroll while a long-press selection is in progress, or the screen
    // would scroll out from under the selection (selectWord sets the selection
    // on long-press start; cleared on the next pointer-down — see the Listener).
    if (_controller.selection != null) return;
    _scrollAccum += e.delta.dy;
    while (_scrollAccum.abs() >= _linePx) {
      final up = _scrollAccum > 0; // finger down → reveal earlier output
      _wheel(up);
      _scrollAccum += up ? -_linePx : _linePx;
    }
  }

  // _wrapScroll disables the TerminalView's OWN inner Scrollable only for
  // host-scrolled TUIs. Codex must keep native scrollback because its transcript
  // lives in the main buffer; otherwise swipe-up cannot reveal past output.
  // The inner Scrollable sets no explicit physics, so a ScrollConfiguration
  // override takes effect.
  Widget _wrapScroll(Widget child) => _usesHostWheelScroll
      ? ScrollConfiguration(behavior: const _NoUserScroll(), child: child)
      : child;

  @override
  Widget build(BuildContext context) {
    final ov = widget.client.overview[widget.session.sid];
    final status =
        ov?.status ??
        (widget.session.agent.isNotEmpty
            ? SessionStatus.idle
            : SessionStatus.shell);
    _updateDefaultViewport(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            SessionActivityAvatar(
              seed: widget.session.sid,
              isAgent: widget.session.agent.isNotEmpty,
              status: status,
              size: 24,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
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
          IconButton(
            icon: const Icon(Icons.fit_screen_rounded),
            tooltip: '适配当前屏幕(按本设备重画)',
            onPressed: () {
              final sent = widget.client.adoptSize(widget.session.sid);
              snack(context, '已适配 → 发送尺寸 $sent');
            },
          ),
          IconButton(
            icon: const Icon(Icons.text_decrease_rounded),
            tooltip: '字号−(更多列，适配 codex 等宽布局)',
            onPressed: () => _bumpFont(-1),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase_rounded),
            tooltip: '字号+',
            onPressed: () => _bumpFont(1),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onSelected: (v) {
              if (v == 'activity') _showActivitySheet();
              if (v == 'default_size') unawaited(_setDefaultViewport());
              if (v == 'clear_default_size') _clearDefaultViewport();
              if (v == 'clear') _clearScrollback();
              if (v == 'histmode') _toggleHistoryMode();
              if (v == 'review_scroll') _toggleLocalReviewScroll();
            },
            itemBuilder: (_) => [
              ccMenuItem(
                value: 'activity',
                icon: Icons.bolt_rounded,
                label:
                    '活动${(widget.client.activities[widget.session.sid] ?? const <HookActivity>[]).isEmpty ? "" : " (${(widget.client.activities[widget.session.sid] ?? const <HookActivity>[]).length})"}',
              ),
              ccMenuItem(
                value: 'default_size',
                icon: Icons.aspect_ratio_rounded,
                label: '设置默认尺寸',
              ),
              ccMenuItem(
                value: 'clear_default_size',
                icon: Icons.settings_backup_restore_rounded,
                label: '默认尺寸改回自动',
              ),
              const PopupMenuDivider(),
              ccMenuItem(
                value: 'clear',
                icon: Icons.cleaning_services_outlined,
                label: '清空本地历史(消除上滑乱码)',
              ),
              ccMenuItem(
                value: 'histmode',
                icon: Icons.palette_outlined,
                label: widget.client.historyMode == 'ansi'
                    ? '历史:彩色 → 切到文本'
                    : '历史:文本 → 切到彩色',
              ),
              if (_canUseHostWheelScroll)
                ccMenuItem(
                  value: 'review_scroll',
                  icon: Icons.swap_vert_rounded,
                  label: _localReviewScroll
                      ? '滚动:本地查看 → 远程控制'
                      : '滚动:远程控制 → 本地查看',
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerDown: (_) {
                      _scrollAccum = 0;
                      // Touching the terminal cancels the brief auto-stick-to-bottom
                      // so the user can scroll back through history right after
                      // entering — we only land at the bottom when they DON'T touch.
                      _stickTimer?.cancel();
                      // A new touch clears any prior selection: a plain drag then
                      // scrolls (no selection to gate it), a long-press re-selects,
                      // and a tap acts as "deselect". Tapping 复制 is on the key bar
                      // (outside this Listener) so it keeps the selection.
                      if (_controller.selection != null) {
                        _controller.clearSelection();
                      }
                    },
                    onPointerMove: _onPointerMove,
                    child: _wrapScroll(
                      TerminalView(
                        _term,
                        controller: _controller,
                        scrollController: _termScroll,
                        theme: ccTerminalTheme,
                        // Only raise the keyboard when tapping the agent's input line
                        // (cursor row and below) — tapping output to read/scroll
                        // won't pop the IME, avoiding accidental taps on the phone.
                        keyboardOnInputLineOnly: true,
                        textStyle: TerminalStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: _fontSize,
                        ),
                        padding: const EdgeInsets.all(8),
                      ),
                    ),
                  ),
                ),
                if (_usageLabel != null)
                  Positioned(
                    top: 4,
                    right: 8,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC1E1E1E),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                        child: Text(
                          _usageLabel!,
                          style: const TextStyle(
                            color: Color(0xFFD7DAE0),
                            fontSize: 10.5,
                            fontFamily: 'JetBrainsMono',
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_canUseHostWheelScroll && _localReviewScroll)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC1E1E1E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                        child: const Text(
                          '本地查看',
                          style: TextStyle(
                            color: Color(0xFFD7DAE0),
                            fontSize: 10.5,
                            fontFamily: 'JetBrainsMono',
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
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
  Widget _activityRow(HookActivity a, {bool expanded = false}) {
    final detail = a.detail;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _clock(a.at),
            style: const TextStyle(
              color: CcColors.subtle,
              fontSize: 10,
              fontFamily: CcType.mono,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: CcColors.text, fontSize: 11),
                ),
                if (expanded && detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CcColors.muted,
                      fontSize: 10.5,
                      fontFamily: CcType.mono,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _clock(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }

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
    // scrollBtn is like btn but hold-to-repeat: Listener (passive) drives the
    // press/hold/release; the OutlinedButton is just the visual + ripple.
    Widget scrollBtn(String label, bool up) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Listener(
        onPointerDown: (_) => _startScroll(up),
        onPointerUp: (_) => _stopScroll(),
        onPointerCancel: (_) => _stopScroll(),
        child: OutlinedButton(
          onPressed: () {}, // press/hold handled by the Listener above
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(label),
        ),
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
                  btn('图片', _sendImage),
                  btn(switch (_vmode) {
                    _VoiceMode.off => '🎙️ 听写',
                    _VoiceMode.dictating => '🔴 听写中',
                  }, _toggleDictation),
                  scrollBtn('滚↑', true),
                  scrollBtn('滚↓', false),
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
  // When non-null and the file does not yet exist (fs.read errors), seed the
  // editor with this content so the user can save to create it — the host
  // auto-mkdirs the parent dir on write.
  final String? initialContent;
  const _RemoteFileViewer({
    required this.client,
    required this.path,
    this.initialContent,
  });

  @override
  State<_RemoteFileViewer> createState() => _RemoteFileViewerState();
}

class _RemoteFileViewerState extends State<_RemoteFileViewer> {
  final _ctl = TextEditingController();
  bool _loaded = false;
  bool _dirty = false;
  bool _wasSaving = false;
  bool _editing = false; // false = read-only syntax-highlighted view

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
    } else if (!_loaded &&
        widget.initialContent != null &&
        c.filePath == widget.path &&
        c.fileError == '文件不存在' &&
        !c.fileLoading) {
      // File is missing: seed from the template so saving creates it. Other
      // errors (forbidden, permission, too large) fall through to the error
      // view below instead of being masked as "create new file".
      _ctl.text = widget.initialContent!;
      _loaded = true;
      _editing = true;
      _dirty = true;
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
          '${pathBaseName(widget.path)}${_dirty ? ' •' : ''}',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: _editing ? '查看' : '编辑',
            icon: Icon(
              _editing ? Icons.visibility_rounded : Icons.edit_rounded,
            ),
            onPressed: _loaded
                ? () => setState(() => _editing = !_editing)
                : null,
          ),
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
          : _editing
          // edit mode: plain editable text box (re_editor is desktop-only).
          ? Padding(
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
            )
          // view mode: read-only syntax-highlighted (parity with the mac).
          : ColoredBox(
              color: CcColors.bg,
              child: highlightedCode(_ctl.text, langIdForPath(widget.path)),
            ),
    );
  }
}

// Default bodies for the supervisor knowledge files — mirror
// `cc-handoff supervisor init` (cmd/cc-handoff/supervisor.go) so the UI seeds
// the same content the CLI would write. Keep in sync with that map.
const String kSupProfileMd = '''# Supervisor Profile

你是这个工作区的总管理 AI。你的职责是观察其它 AI 会话、读取 PRD/知识库、处理待确认事项、协调分歧，并在需要时向用户请求确认。

默认原则:
- 先读取上下文，再裁决。
- 高风险操作必须让用户确认。
- 有产品/架构决策时写入 decisions.md。
- 开子会话前按分档策略判断隔离档:默认共享 Tier1;重活/并行改同模块/破坏性 git/要 build-run → spawn --worktree(Tier2);只读 → Tier0。多会话共享同一工作树/.git 时,Tier1 会话提交须走共享 .git 提交协议(提交前 git fetch && git reset --mixed origin/main 对齐 → 提交锁串行 → 只 hunk 级 add 自己文件、绝不 add -A → 原子 git commit && git push origin HEAD:main;若有 cc-handoff commit 则优先用)。详见 principles.md。
''';

const String kSupPrdMd = '''# PRD

在这里放需求文档。
''';

const String kSupPrinciplesMd = '''# Principles

在这里放你的思考方式、产品原则、工程偏好和验收标准。

## 开子会话的分档策略(spawn tiers)—— 每次开子会话前先判断

若多会话【共享同一工作树 / .git / index】,并发写 git 会互相踩(共享 index 被 restore 干扰、HEAD 一度 detached、提交被并发移走)。每次 supervisor spawn 前按任务性质选隔离档:

- Tier0 · 只读/答疑:不写 git、不改文件 → 原地开,无需隔离。
- Tier1 · 默认(共享工作树):普通改代码任务 → 原地开(不加 --worktree),遵守下面的共享 .git 提交协议。
- Tier2 · 独立 worktree(spawn --worktree):命中任一即隔离 → ① 会在其中 build/run App;② 长任务/跨多文件/epic;③ 预期与别的会话并行改同一模块;④ 破坏性 git(rebase/改史/大重构);⑤ pickup 物化量大。代价:Flutter 每 worktree 重生 .dart_tool/build,故只在命中时才上。

口诀:默认 Tier1;重活/并行同模块/破坏性 git/要 build-run → Tier2;只读 → Tier0。

## 共享 .git 提交协议(所有 Tier1 会话必须遵守)

1. 提交前对齐本地:git fetch && git reset --mixed origin/main(只移分支指针+刷新 index,不动工作树、保留未提交改动),确认 HEAD == origin/main。
2. 提交锁串行:总线播「提交锁·<id>·开始」→ 他人暂停一切 git 写 → push 完播「完成」。同一时刻只一个会话动 git。
3. 只 hunk 级 add 自己的文件/行,git diff --cached --stat 自查;绝不 git add -A / commit -a。
4. 原子提交推送:git commit -m '..' && git push origin HEAD:main;non-ff 就再 fetch,绝不 force、绝不在 dirty 共享树 rebase。
5. 若有 cc-handoff commit 子命令,优先用:cc-handoff commit -m '..' -- <只你自己的路径>(独立 GIT_INDEX_FILE + flock + commit-tree 直建于 origin/main + 原子 FF 推,免 index/HEAD 竞态)。
''';

const String kSupDecisionsMd = '# Decisions\n\n';

// Compact B/KB/MB formatter shared by the transfer hub and the dialogs below.
String _fmtBytes(int n) {
  if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '$n B';
}

// A seedable knowledge file: the default body to write when it doesn't exist
// yet, plus a one-line caption for its list row.
class _Seed {
  const _Seed(this.template, this.caption);
  final String template;
  final String caption;
}

// Mini file browser scoped to <workdir>/.cc-handoff/supervisor. Pins the four
// canonical files `cc-handoff supervisor context` reads at the root and seeds
// them from the templates above when they don't exist yet (saving creates the
// file; the host mkdir -p's the parent dir on write).
class _SupervisorKnowledgeDialog extends StatefulWidget {
  final RemoteClient client;
  final String dir;
  const _SupervisorKnowledgeDialog({required this.client, required this.dir});

  @override
  State<_SupervisorKnowledgeDialog> createState() =>
      _SupervisorKnowledgeDialogState();
}

class _SupervisorKnowledgeDialogState
    extends State<_SupervisorKnowledgeDialog> {
  late String _cwd = widget.dir;

  // Pinned seedable files shown at the supervisor root even before the
  // directory exists. Mirrors `cc-handoff supervisor init`.
  static const _seeds = <String, _Seed>{
    'profile.md': _Seed(kSupProfileMd, '角色与默认原则'),
    'prd.md': _Seed(kSupPrdMd, '需求文档'),
    'principles.md': _Seed(kSupPrinciplesMd, '工程原则与验收标准'),
    'decisions.md': _Seed(kSupDecisionsMd, '已记录的决策'),
  };

  @override
  void initState() {
    super.initState();
    widget.client.openDir(_cwd);
  }

  Future<void> _openFile(String name, {String? initial}) async {
    final path = pathJoin(_cwd, name);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _RemoteFileViewer(
          client: widget.client,
          path: path,
          initialContent: initial,
        ),
      ),
    );
    // Refresh so "已存在" reflects files just created/saved.
    widget.client.openDir(_cwd);
  }

  Future<void> _newFile() async {
    final name = await textPrompt(context, title: '新建文件', hint: '文件名.md');
    if (name == null || name.trim().isEmpty) return;
    final n = name.trim();
    _openFile(n.endsWith('.md') ? n : '$n.md', initial: '');
  }

  void _descend(String name) {
    setState(() {
      _cwd = pathJoin(_cwd, name);
      widget.client.openDir(_cwd);
    });
  }

  void _up() {
    if (pathEquals(_cwd, widget.dir)) return;
    final (_, parent) = splitFileNameDir(_cwd);
    // Never ascend above the supervisor root.
    final next = !pathWithin(parent, widget.dir) ? widget.dir : parent;
    if (pathEquals(next, _cwd)) return;
    setState(() {
      _cwd = next;
      widget.client.openDir(_cwd);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: CcColors.panel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: ListenableBuilder(
          listenable: widget.client,
          builder: (BuildContext context, Widget? _) {
            final c = widget.client;
            final atRoot = _cwd == widget.dir;
            final loading = c.fsLoading;
            // fs.err doesn't carry the path, so treat any error as "ours" —
            // it means this dir failed to list (usually missing).
            final mine = !loading && (c.fsPath == _cwd || c.fsError != null);
            final entries = (mine && c.fsError == null && c.fsPath == _cwd)
                ? c.fsEntries
                : const <RemoteEntry>[];
            final dirMissing = mine && c.fsError != null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(atRoot),
                const Divider(height: 1),
                Flexible(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : _body(entries, atRoot, dirMissing),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(bool atRoot) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          if (!atRoot)
            IconButton(
              tooltip: '返回上级',
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              onPressed: _up,
            ),
          const Icon(Icons.menu_book_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              atRoot ? '总管知识库' : pathBaseName(_cwd),
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '新建文件',
            icon: const Icon(Icons.add_rounded, size: 20),
            onPressed: _newFile,
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _body(List<RemoteEntry> entries, bool atRoot, bool dirMissing) {
    final existing = {for (final e in entries) e.name};
    final rows = <Widget>[];

    if (atRoot) {
      for (final s in _seeds.entries) {
        rows.add(
          _row(
            Icons.article_outlined,
            s.key,
            s.value.caption,
            existing.contains(s.key),
            () => _openFile(s.key, initial: s.value.template),
          ),
        );
      }
    }

    final listed = atRoot
        ? entries.where((e) => !_seeds.containsKey(e.name))
        : entries;
    if (atRoot && listed.isNotEmpty) rows.add(const Divider(height: 1));
    for (final e in listed) {
      rows.add(_entryRow(e));
    }

    if (rows.isEmpty) {
      return centerMsg(dirMissing ? '目录尚不存在，保存首个文件后将自动创建。' : '（空）点右上 + 新建文件。');
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      separatorBuilder: (BuildContext _, int _) =>
          const Divider(height: 1, indent: 12),
      itemBuilder: (BuildContext _, int i) => rows[i],
    );
  }

  Widget _entryRow(RemoteEntry e) => _row(
    e.dir ? Icons.folder_outlined : Icons.article_outlined,
    e.name,
    e.dir ? '文件夹' : _fmtBytes(e.size),
    false,
    e.dir ? () => _descend(e.name) : () => _openFile(e.name),
  );

  Widget _row(
    IconData icon,
    String name,
    String desc,
    bool exists,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Icon(icon, size: 20, color: CcColors.muted),
      minLeadingWidth: 24,
      title: Text(name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        desc,
        style: TextStyle(fontSize: 12, color: CcColors.muted),
      ),
      trailing: exists
          ? Text('已存在', style: TextStyle(fontSize: 11, color: CcColors.subtle))
          : null,
      onTap: onTap,
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
  // 全部/相关: shares the 'diff.fullContext' pref with the desktop.
  bool _full = Prefs.getBool('diff.fullContext', def: false);

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          actions: [
            _diffContextAction(_full, (v) {
              Prefs.setBool('diff.fullContext', v);
              setState(() => _full = v);
              client.reloadDiff(v); // re-fetch the same diff at new context
            }),
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

// _diffContextAction is the compact 全部/相关 toggle for a diff screen's AppBar.
Widget _diffContextAction(bool full, ValueChanged<bool> onChanged) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
  child: diffContextToggle(
    full,
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
  bool _full = Prefs.getBool('diff.fullContext', def: false);

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
            actions: [
              _diffContextAction(_full, (v) {
                Prefs.setBool('diff.fullContext', v);
                setState(() => _full = v);
                client.reloadDiff(v); // re-fetch this commit at new context
              }),
            ],
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
    final draft = await showDialog<RemoteWorktreeDraft>(
      context: context,
      builder: (_) => const RemoteWorktreeCreateDialog(),
    );
    if (draft != null) {
      widget.client.addWorktree(
        widget.project.workspace,
        widget.project.name,
        draft.branch,
        draft.startPoint,
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

// _QuickReplyDialog previews a remote session's live screen and lets the user
// confirm/reply in place — no full-screen mirror. It pulls a one-shot screen
// snapshot (requestScreen) on open and on a short timer so a running agent's
// output and any permission prompt stay current; sends go via term.input.
class _QuickReplyDialog extends StatefulWidget {
  final RemoteClient client;
  final RemoteSession session;
  final VoidCallback onOpenTerminal;
  const _QuickReplyDialog({
    required this.client,
    required this.session,
    required this.onOpenTerminal,
  });

  @override
  State<_QuickReplyDialog> createState() => _QuickReplyDialogState();
}

class _QuickReplyDialogState extends State<_QuickReplyDialog> {
  final _ctl = TextEditingController();
  Timer? _timer;
  // Last values build() actually consumes, so unrelated client notifications
  // (other sessions, mirror output, heartbeats) don't re-lay-out the preview —
  // mirrors the desktop popup's snap-equality guard.
  ScreenSnapshot? _lastScreen;
  SessionCard? _lastOverview;

  String get _sid => widget.session.sid;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onChange);
    widget.client.requestScreen(_sid);
    _timer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => widget.client.requestScreen(_sid),
    );
  }

  @override
  void dispose() {
    widget.client.removeListener(_onChange);
    _timer?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  // Rebuild only when one of the two things build() reads actually changed:
  // the screen snapshot (SessionSnapshotView) or this session's overview card
  // (status/usage row). overview is replaced wholesale per frame, so identity
  // is enough; screens are ScreenSnapshot records (structural equality).
  void _onChange() {
    if (!mounted) return;
    final screen = widget.client.screens[_sid];
    final overview = widget.client.overview[_sid];
    if (screen == _lastScreen && identical(overview, _lastOverview)) return;
    _lastScreen = screen;
    _lastOverview = overview;
    setState(() {});
  }

  // _bump re-reads the screen shortly after a send so the reaction shows without
  // waiting for the next timer tick.
  void _bump() => Future.delayed(
    const Duration(milliseconds: 350),
    () => widget.client.requestScreen(_sid),
  );

  void _keys(String keys) {
    widget.client.sendKeys(_sid, keys);
    _bump();
  }

  void _confirm() => _keys('\r');

  void _sendText() {
    final t = _ctl.text;
    if (t.trim().isEmpty) return;
    widget.client.sendKeys(_sid, t);
    widget.client.sendKeys(_sid, '\r');
    _ctl.clear();
    _bump();
  }

  Widget _quick(String label, VoidCallback onTap) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      minimumSize: const Size(0, 32),
    ),
    child: Text(label, style: CcType.code(size: 12.5)),
  );

  @override
  Widget build(BuildContext context) {
    final ov = widget.client.overview[_sid];
    final status =
        ov?.status ??
        (widget.session.agent.isNotEmpty
            ? SessionStatus.idle
            : SessionStatus.shell);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SessionActivityAvatar(
                  seed: _sid,
                  isAgent: widget.session.agent.isNotEmpty,
                  status: status,
                  size: 24,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    widget.session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            if (ov != null) ...[
              const SizedBox(height: 4),
              sessionStatusRow(
                ov.status,
                ov.usageLabel,
                statusDetail: ov.statusDetail,
              ),
            ],
            const SizedBox(height: 10),
            SizedBox(
              height: 220,
              child: SessionSnapshotView(
                snapshot: widget.client.screens[_sid],
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _quick('↵ 确认', _confirm),
                _quick('1', () => _keys('1')),
                _quick('2', () => _keys('2')),
                _quick('3', () => _keys('3')),
                _quick('y', () => _keys('y')),
                _quick('n', () => _keys('n')),
                _quick('Esc', () => _keys('\x1b')),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctl,
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendText(),
                    decoration: const InputDecoration(
                      hintText: '快捷回复…',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _sendText, child: const Text('发送')),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.onOpenTerminal,
                icon: const Icon(Icons.open_in_full_rounded, size: 16),
                label: const Text('打开终端'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
