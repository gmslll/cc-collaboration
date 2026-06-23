import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../remote/remote_client.dart';
import '../theme.dart';
import '../widgets.dart';
import 'terminal_pane.dart' show ccTerminalTheme;

// RemoteWorkspacePage is the phone's view of a desktop workspace shared over the
// relay: pick a terminal session to drive, or browse/read project code. The
// desktop must have "cast to phone" enabled (workspace toolbar).
class RemoteWorkspacePage extends StatefulWidget {
  final String relayUrl;
  final String token;
  const RemoteWorkspacePage({
    super.key,
    required this.relayUrl,
    required this.token,
  });

  @override
  State<RemoteWorkspacePage> createState() => _RemoteWorkspacePageState();
}

class _RemoteWorkspacePageState extends State<RemoteWorkspacePage> {
  late final RemoteClient _c = RemoteClient(
    relayUrl: widget.relayUrl,
    token: widget.token,
  );
  int _tab = 0; // 0 = 会话, 1 = 代码
  final List<String> _dirStack =
      []; // breadcrumb of opened dirs (empty = roots)

  @override
  void initState() {
    super.initState();
    _c.connect();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('远程工作区'),
          actions: [
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _c.connected ? _c.refresh : null,
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(0),
            child: _statusBanner(),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('会话')),
                  ButtonSegment(value: 1, label: Text('代码')),
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
            ),
            Expanded(child: _tab == 0 ? _sessionsTab() : _codeTab()),
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
            child: Text(text, style: TextStyle(color: color, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _sessionsTab() {
    if (_c.sessions.isEmpty) {
      return centerMsg('没有会话。\n在电脑端起一个 Claude/Codex 会话，并打开工具栏的「共享给手机」。');
    }
    return ListView.separated(
      itemCount: _c.sessions.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: CcColors.border),
      itemBuilder: (_, i) {
        final s = _c.sessions[i];
        return ListTile(
          leading: Icon(
            s.agent == 'codex'
                ? Icons.smart_toy_outlined
                : Icons.play_arrow_rounded,
            color: CcColors.accentBright,
          ),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            s.workdir,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 11.5, color: CcColors.subtle),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _RemoteTerminalScreen(client: _c, session: s),
            ),
          ),
        );
      },
    );
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
}

// _RemoteTerminalScreen renders one remote session full-screen, with an on-screen
// key bar for the keys phone keyboards lack (agent TUIs need Esc/arrows/Ctrl-C).
class _RemoteTerminalScreen extends StatelessWidget {
  final RemoteClient client;
  final RemoteSession session;
  const _RemoteTerminalScreen({required this.client, required this.session});

  @override
  Widget build(BuildContext context) {
    final term = client.terminalFor(session.sid);
    return Scaffold(
      appBar: AppBar(title: Text(session.title)),
      body: Column(
        children: [
          Expanded(
            child: TerminalView(
              term,
              theme: ccTerminalTheme,
              textStyle: const TerminalStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12.5,
              ),
              padding: const EdgeInsets.all(8),
            ),
          ),
          _keyBar(term),
        ],
      ),
    );
  }

  Widget _keyBar(Terminal term) {
    Widget k(String label, String data) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: OutlinedButton(
        onPressed: () => client.sendKeys(session.sid, data),
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
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          children: [
            k('Esc', '\x1b'),
            k('Tab', '\t'),
            k('Ctrl-C', '\x03'),
            k('Ctrl-D', '\x04'),
            k('↑', '\x1b[A'),
            k('↓', '\x1b[B'),
            k('←', '\x1b[D'),
            k('→', '\x1b[C'),
            k('Enter', '\r'),
            k('/', '/'),
          ],
        ),
      ),
    );
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
  @override
  void initState() {
    super.initState();
    widget.client.openFile(widget.path);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.client,
      builder: (context, _) {
        final c = widget.client;
        final showing = c.filePath == widget.path;
        return Scaffold(
          appBar: AppBar(title: Text(widget.path.split('/').last)),
          body: !showing || c.fileLoading
              ? const Center(child: CircularProgressIndicator())
              : c.fileError != null
              ? centerMsg(c.fileError!)
              : SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        c.fileContent ?? '',
                        style: CcType.code(size: 12.5),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
