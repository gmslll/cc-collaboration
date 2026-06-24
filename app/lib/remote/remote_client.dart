import 'package:xterm/xterm.dart';

import '../terminal_mouse.dart';
import 'remote_channel.dart';

// Client-side models of what the desktop host advertises.
class RemoteSession {
  final String sid;
  final String title;
  final String workdir;
  final String agent;
  RemoteSession(this.sid, this.title, this.workdir, this.agent);
}

class RemoteRootInfo {
  final String name;
  final String path;
  final String workspace;
  RemoteRootInfo(this.name, this.path, this.workspace);
}

class RemoteWorktree {
  final String path;
  final String branch;
  RemoteWorktree(this.path, this.branch);
  String get name =>
      path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => path);
}

class RemoteEntry {
  final String name;
  final bool dir;
  final int size;
  RemoteEntry(this.name, this.dir, this.size);
}

class RemoteGitChange {
  final String path;
  final String status;
  final bool staged;
  final bool untracked;
  final bool conflicted;
  RemoteGitChange(
    this.path,
    this.status,
    this.staged,
    this.untracked,
    this.conflicted,
  );
}

class RemoteGitCommit {
  final String hash;
  final String short;
  final String author;
  final String date;
  final String subject;
  RemoteGitCommit(this.hash, this.short, this.author, this.date, this.subject);
}

class RemoteBranch {
  final String name;
  final bool current;
  final bool remote;
  final int ahead;
  final int behind;
  RemoteBranch(this.name, this.current, this.remote, this.ahead, this.behind);
}

// RemoteClient is the phone side of the remote workspace: over the relay (see
// RemoteChannel for transport) it discovers the desktop host's terminal sessions
// and project roots, drives terminals (xterm fed by network bytes, keystrokes
// sent back), and browses/reads files. Read-only files for now (editing later).
class RemoteClient extends RemoteChannel {
  RemoteClient({required super.relayUrl, required super.token})
    : super(role: 'client');

  bool _hostOnline = false;

  List<RemoteSession> sessions = [];
  List<RemoteRootInfo> roots = [];

  // File browser (single current directory, mobile-friendly).
  String? fsPath;
  List<RemoteEntry> fsEntries = [];
  bool fsLoading = false;
  String? fsError;

  // File viewer + editor.
  String? filePath;
  String? fileContent;
  bool fileLoading = false;
  String? fileError;
  bool fileSaving = false;
  String? fileSaveError;

  // Git view: working-tree changes + recent commits for the selected repo.
  String? gitRepo;
  List<RemoteGitChange> gitChanges = [];
  List<RemoteGitCommit> gitCommits = [];
  bool gitLoading = false;
  String? gitError;
  List<RemoteBranch> branches = [];
  String? gitOpError; // last failed git operation (for a transient toast)

  // Project management: worktrees of the project being managed (wtProject=path).
  String? wtProject;
  List<RemoteWorktree> worktrees = [];
  String? cfgError; // last failed config op (for a transient toast)

  // Diff viewer (a file's working diff, or a commit's full diff).
  String? diffTitle;
  String? diffContent;
  bool diffLoading = false;
  String? diffError;

  final Map<String, Terminal> _terminals = {};

  bool get hostOnline => _hostOnline;
  String? get error => lastError;

  void connect() => start();

  @override
  void onConnected() => send({'t': 'list'}); // discover host on connect

  @override
  void onDisconnected() => _hostOnline = false;

  @override
  void onPeer(int connId, String role, bool connected) {
    if (role != 'host') return;
    _hostOnline = connected;
    if (connected) send({'t': 'list'});
    notifyListeners();
  }

  @override
  void onFrame(Map<String, dynamic> f) {
    switch (f['t']) {
      case 'sessions':
        sessions = [
          for (final s in (f['items'] as List? ?? []))
            RemoteSession(
              s['sid'] as String,
              (s['title'] as String?) ?? '',
              (s['workdir'] as String?) ?? '',
              (s['agent'] as String?) ?? 'claude',
            ),
        ];
        _hostOnline = true;
        notifyListeners();
      case 'roots':
        roots = [
          for (final r in (f['items'] as List? ?? []))
            RemoteRootInfo(
              r['name'] as String,
              r['path'] as String,
              (r['workspace'] as String?) ?? '',
            ),
        ];
        notifyListeners();
      case 'term.output':
        final sid = f['sid'] as String?;
        final d = f['d'] as String?;
        if (sid != null && d != null) _terminals[sid]?.write(d);
      case 'fs.list.ok':
        fsPath = f['path'] as String?;
        fsEntries = [
          for (final e in (f['entries'] as List? ?? []))
            RemoteEntry(
              e['name'] as String,
              (e['dir'] as bool?) ?? false,
              (e['size'] as num?)?.toInt() ?? 0,
            ),
        ];
        fsLoading = false;
        fsError = null;
        notifyListeners();
      case 'fs.read.ok':
        filePath = f['path'] as String?;
        fileContent = f['content'] as String?;
        fileLoading = false;
        fileError = null;
        notifyListeners();
      case 'fs.write.ok':
        fileSaving = false;
        fileSaveError = null;
        notifyListeners();
      case 'fs.write.err':
        fileSaving = false;
        fileSaveError = (f['msg'] as String?) ?? '失败';
        notifyListeners();
      case 'fs.err':
        if (fileLoading) {
          fileLoading = false;
          fileError = (f['msg'] as String?) ?? '失败';
        }
        if (fsLoading) {
          fsLoading = false;
          fsError = (f['msg'] as String?) ?? '失败';
        }
        notifyListeners();
      case 'git.status.ok':
        gitRepo = f['path'] as String?;
        gitChanges = [
          for (final c in (f['changes'] as List? ?? []))
            RemoteGitChange(
              c['path'] as String,
              (c['status'] as String?) ?? 'M',
              (c['staged'] as bool?) ?? false,
              (c['untracked'] as bool?) ?? false,
              (c['conflicted'] as bool?) ?? false,
            ),
        ];
        gitCommits = [
          for (final c in (f['commits'] as List? ?? []))
            RemoteGitCommit(
              c['hash'] as String,
              (c['short'] as String?) ?? '',
              (c['author'] as String?) ?? '',
              (c['date'] as String?) ?? '',
              (c['subject'] as String?) ?? '',
            ),
        ];
        gitLoading = false;
        gitError = null;
        notifyListeners();
      case 'git.diff.ok':
      case 'git.show.ok':
        diffContent = (f['diff'] as String?) ?? '';
        diffLoading = false;
        diffError = null;
        notifyListeners();
      case 'git.err':
        if (diffLoading) {
          diffLoading = false;
          diffError = (f['msg'] as String?) ?? '失败';
        } else {
          gitLoading = false;
          gitError = (f['msg'] as String?) ?? '失败';
        }
        notifyListeners();
      case 'git.op.ok':
        gitOpError = null;
        if (gitRepo != null) refreshGit();
      case 'git.op.err':
        gitOpError = (f['msg'] as String?) ?? '失败';
        notifyListeners();
      case 'git.branches.ok':
        branches = [
          for (final b in (f['branches'] as List? ?? []))
            RemoteBranch(
              b['name'] as String,
              (b['current'] as bool?) ?? false,
              (b['remote'] as bool?) ?? false,
              (b['ahead'] as num?)?.toInt() ?? 0,
              (b['behind'] as num?)?.toInt() ?? 0,
            ),
        ];
        notifyListeners();
      case 'wt.list.ok':
        wtProject = f['path'] as String?;
        worktrees = [
          for (final w in (f['worktrees'] as List? ?? []))
            RemoteWorktree(w['path'] as String, (w['branch'] as String?) ?? ''),
        ];
        notifyListeners();
      case 'cfg.ok':
        cfgError = null;
        if (wtProject != null) loadWorktrees(wtProject!);
      case 'cfg.err':
        cfgError = (f['msg'] as String?) ?? '失败';
        notifyListeners();
    }
  }

  void refresh() => send({'t': 'list'});

  // sendKeys injects raw bytes into a session (for an on-screen key bar — phone
  // soft keyboards lack Esc / Ctrl / arrows that agent TUIs need).
  void sendKeys(String sid, String data) =>
      send({'t': 'term.input', 'sid': sid, 'd': data});

  // terminalFor returns (creating on first use) the xterm Terminal for a session,
  // wired so host output is written in and local keystrokes/resizes go back.
  Terminal terminalFor(String sid) {
    final existing = _terminals[sid];
    if (existing != null) return existing;
    final term = Terminal(maxLines: 5000);
    _terminals[sid] = term;
    // Same wheel fix as the desktop so touch-scroll reaches full-screen TUIs;
    // without it xterm's default handler drops the wheel while the app tracks.
    term.mouseHandler = const WheelMouseHandler();
    term.onOutput = (d) => send({'t': 'term.input', 'sid': sid, 'd': d});
    term.onResize = (w, h, pw, ph) =>
        send({'t': 'term.resize', 'sid': sid, 'rows': h, 'cols': w});
    send({'t': 'term.open', 'sid': sid});
    return term;
  }

  // reloadTerminal drops the cached Terminal and recreates it, so the phone's
  // buffer starts empty and the host's term.open reply (backlog replay) shows
  // the computer's current screen/history instead of appending to stale
  // content. The caller rebuilds so the TerminalView rebinds to the new term.
  void reloadTerminal(String sid) {
    _terminals.remove(sid);
    terminalFor(sid); // recreate + send term.open now → host replays backlog
  }

  // Session write actions (the host re-broadcasts `sessions` after each).
  void newSession(String projectPath, String agent) =>
      send({'t': 'session.new', 'project': projectPath, 'agent': agent});
  void closeSession(String sid) => send({'t': 'session.close', 'sid': sid});
  void renameSession(String sid, String name) =>
      send({'t': 'session.rename', 'sid': sid, 'name': name});

  void openDir(String path) {
    fsLoading = true;
    fsError = null;
    notifyListeners();
    send({'t': 'fs.list', 'path': path});
  }

  void openFile(String path) {
    fileLoading = true;
    fileError = null;
    filePath = path;
    fileContent = null;
    notifyListeners();
    send({'t': 'fs.read', 'path': path});
  }

  void saveFile(String path, String content) {
    fileSaving = true;
    fileSaveError = null;
    notifyListeners();
    send({'t': 'fs.write', 'path': path, 'content': content});
  }

  void openGit(String repo) {
    gitRepo = repo;
    gitChanges = [];
    gitCommits = [];
    gitLoading = true;
    gitError = null;
    notifyListeners();
    send({'t': 'git.status', 'path': repo});
  }

  void refreshGit() {
    final r = gitRepo;
    if (r != null) openGit(r);
  }

  void requestWorkingDiff(String repo, String file) {
    diffTitle = file;
    diffContent = null;
    diffLoading = true;
    diffError = null;
    notifyListeners();
    send({'t': 'git.diff', 'path': repo, 'file': file});
  }

  void requestCommitDiff(String repo, String hash, String title) {
    diffTitle = title;
    diffContent = null;
    diffLoading = true;
    diffError = null;
    notifyListeners();
    send({'t': 'git.show', 'path': repo, 'hash': hash});
  }

  // Git write ops — host replies git.op.ok (→ auto refresh) or git.op.err.
  void gitStage(String repo, String file) =>
      send({'t': 'git.stage', 'path': repo, 'file': file});
  void gitUnstage(String repo, String file) =>
      send({'t': 'git.unstage', 'path': repo, 'file': file});
  void gitStageAll(String repo) => send({'t': 'git.stageAll', 'path': repo});
  void gitUnstageAll(String repo) =>
      send({'t': 'git.unstageAll', 'path': repo});
  void gitDiscard(String repo, String file) =>
      send({'t': 'git.discard', 'path': repo, 'file': file});
  void gitDiscardAll(String repo) =>
      send({'t': 'git.discardAll', 'path': repo});
  void gitCommit(String repo, String message, {bool push = false}) =>
      send({'t': 'git.commit', 'path': repo, 'message': message, 'push': push});
  void gitPush(String repo) => send({'t': 'git.push', 'path': repo});
  void gitPull(String repo) => send({'t': 'git.pull', 'path': repo});
  void gitFetch(String repo) => send({'t': 'git.fetch', 'path': repo});
  void loadBranches(String repo) => send({'t': 'git.branches', 'path': repo});
  void gitCheckout(String repo, String branch) =>
      send({'t': 'git.checkout', 'path': repo, 'branch': branch});
  void gitCreateBranch(String repo, String branch) =>
      send({'t': 'git.createBranch', 'path': repo, 'branch': branch});
  void gitStash(String repo, String message) =>
      send({'t': 'git.stash', 'path': repo, 'message': message});
  void gitStashPop(String repo, String ref) =>
      send({'t': 'git.stashPop', 'path': repo, 'ref': ref});

  // Project management — host replies cfg.ok (→ rebroadcast roots) or cfg.err.
  void loadWorktrees(String projectPath) =>
      send({'t': 'wt.list', 'path': projectPath});
  void newWorkspace(String name, String path) =>
      send({'t': 'ws.new', 'name': name, if (path.isNotEmpty) 'path': path});
  void removeWorkspace(String name) => send({'t': 'ws.remove', 'name': name});
  void addProject(String workspace, String source) =>
      send({'t': 'proj.add', 'workspace': workspace, 'source': source});
  void removeProject(String workspace, String project) =>
      send({'t': 'proj.remove', 'workspace': workspace, 'project': project});
  void addWorktree(
    String workspace,
    String project,
    String branch,
    String start,
  ) => send({
    't': 'wt.add',
    'workspace': workspace,
    'project': project,
    'branch': branch,
    if (start.isNotEmpty) 'start': start,
  });
  void removeWorktree(String workspace, String project, String branch) => send({
    't': 'wt.remove',
    'workspace': workspace,
    'project': project,
    'branch': branch,
    'force': true,
  });
}
