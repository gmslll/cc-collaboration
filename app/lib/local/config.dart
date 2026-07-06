import 'dart:io';

import 'package:toml/toml.dart';

import 'platform.dart';

// A project inside a workspace: a name + its absolute local path + the GitHub
// URL it was cloned from (empty if added by local path), used for the PR view.
class ProjectCfg {
  final String name;
  final String path; // absolute
  final String github;
  const ProjectCfg(this.name, this.path, [this.github = '']);
}

// A workspace from config.toml [[workspace]]: its projects + the resolved agent
// and optional pre_launch snippet. Agent precedence (workspace.agent →
// user.agent → claude) mirrors Go's internal/config/workspace.go
// BuildLaunchCommand — keep the two in sync.
class WorkspaceCfg {
  final String name;
  final String path; // absolute (may be empty)
  final String agent;
  final String editor;
  final String preLaunch;
  final List<ProjectCfg> projects;
  const WorkspaceCfg(this.name, this.path, this.agent, this.editor,
      this.preLaunch, this.projects);
}

// projectsOf returns [workspace]'s projects (empty when the workspace is null /
// unknown). Shared by every workspace→project cascade picker.
List<ProjectCfg> projectsOf(AppConfig cfg, String? workspace) {
  final m = cfg.workspaces.where((w) => w.name == workspace);
  return m.isEmpty ? const [] : m.first.projects;
}

// AppConfig reads the same ~/.config/cc-handoff/config.toml the CLI uses, so the
// desktop app is auto-authenticated and can resolve a handoff's repo name to a
// local clone for pickup, and render the Workspace→Project tree.
class AppConfig {
  final String relayUrl;
  final String token;
  final String identity;

  /// repo name -> absolute local path (flattened from all workspace projects).
  final Map<String, String> repos;

  /// the full workspace → project tree (for the workspace cockpit).
  final List<WorkspaceCfg> workspaces;

  // user-level settings (for the in-app config editor).
  final String agent;
  final String workspaceRoot;
  final String gradeCommand;
  final String linearToken;
  final String githubToken;

  /// user-level default external terminal app (terminal/iterm2/ghostty/...),
  /// used when a repo's .cc-handoff.toml doesn't set its own terminal_app.
  final String terminalApp;

  /// per-agent launch overrides (absolute path or full command/script); empty =
  /// auto-resolve. Read by AgentResolver so the PTY launcher works without a
  /// PATH-resolvable `claude`/`codex`.
  final String claudeCommand;
  final String codexCommand;

  AppConfig(this.relayUrl, this.token, this.identity, this.repos,
      [this.workspaces = const [],
      this.agent = '',
      this.workspaceRoot = '',
      this.gradeCommand = '',
      this.linearToken = '',
      this.githubToken = '',
      this.terminalApp = '',
      this.claudeCommand = '',
      this.codexCommand = '']);

  String? repoPath(String name) => repos[name];

  static String configPath() => '${ccConfigDir()}/config.toml';

  // saveAuth writes/merges the auth keys (relay_url/token/identity) into the same
  // config.toml the CLI reads, so the bundled/installed cc-handoff CLI the app
  // shells out to (workspace/worktree/pickup ops) is authenticated. A
  // freshly-registered user has no config.toml, so without this the embedded CLI
  // is unauthenticated and nothing works. Existing keys — notably [[workspace]] —
  // are preserved; only the three auth keys are (re)written (also refreshes an
  // expired token on re-login). Mirrors the Go side's config.SaveUser.
  static Future<void> saveAuth(
      String relayUrl, String token, String identity) async {
    final f = File(configPath());
    Map<String, dynamic> map = {};
    if (await f.exists()) {
      try {
        map = Map<String, dynamic>.from(
            TomlDocument.parse(await f.readAsString()).toMap());
      } catch (_) {
        map = {}; // unparseable — rebuild rather than block login
      }
    }
    map['relay_url'] = relayUrl;
    map['token'] = token;
    map['identity'] = identity;
    await f.parent.create(recursive: true);
    await f.writeAsString(TomlDocument.fromMap(map).toString());
    // The token is sensitive; tighten perms to match the CLI's 0600 (posix only).
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {}
    }
  }

  static Future<AppConfig?> load() async {
    final f = File(configPath());
    if (!await f.exists()) return null;
    final map = TomlDocument.parse(await f.readAsString()).toMap();

    final relay = (map['relay_url'] ?? '').toString();
    final token = (map['token'] ?? '').toString();
    final identity = (map['identity'] ?? '').toString();
    if (relay.isEmpty || token.isEmpty) return null;

    final userAgent = (map['agent'] ?? '').toString();
    final wsRoot = (map['workspace_root'] ?? '').toString();
    final grade = (map['grade_command'] ?? '').toString();
    final linear = (map['linear_personal_token'] ?? '').toString();
    final githubToken = (map['github_token'] ?? '').toString();
    final terminalApp = (map['terminal_app'] ?? '').toString();
    final claudeCommand = (map['claude_command'] ?? '').toString();
    final codexCommand = (map['codex_command'] ?? '').toString();
    final repos = <String, String>{};
    final wsList = <WorkspaceCfg>[];

    final workspaces = (map['workspace'] as List?) ?? const [];
    for (final ws in workspaces.whereType<Map>()) {
      final wsName = (ws['name'] ?? '').toString();
      final wsPath = _expand((ws['path'] ?? '').toString());
      final wsAgent = (ws['agent'] ?? '').toString();
      final agent = wsAgent.isNotEmpty
          ? wsAgent
          : (userAgent.isNotEmpty ? userAgent : 'claude');
      final editor = (ws['editor'] ?? '').toString();
      final preLaunch = (ws['pre_launch'] ?? '').toString();
      final base = wsPath.isNotEmpty
          ? wsPath
          : '${_home()}/cc-handoff-workspaces/${wsName.isEmpty ? 'default' : wsName}';

      final projCfgs = <ProjectCfg>[];
      final seenProjects = <String>{};
      final projects = (ws['project'] as List?) ?? const [];
      for (final p in projects.whereType<Map>()) {
        final name = (p['name'] ?? '').toString();
        if (name.isEmpty) continue;
        var path = _expand((p['path'] ?? '').toString());
        if (path.isNotEmpty && !_isAbsolutePath(path)) path = '$base/$path';
        if (path.isEmpty) continue;
        // A project name is its identity within a workspace (repos map, CLI
        // remove, worktree lookup all key by it). Skip duplicate [[project]]
        // entries so a doubled config row doesn't show the project twice.
        if (!seenProjects.add(name)) continue;
        final github = (p['github'] ?? '').toString();
        repos.putIfAbsent(name, () => path);
        projCfgs.add(ProjectCfg(name, path, github));
      }
      wsList.add(
          WorkspaceCfg(wsName, wsPath, agent, editor, preLaunch, projCfgs));
    }

    return AppConfig(relay, token, identity, repos, wsList, userAgent, wsRoot,
        grade, linear, githubToken, terminalApp, claudeCommand, codexCommand);
  }
}

String _home() => homeDir();

// _isAbsolutePath accepts POSIX (/…) and Windows (C:\…, C:/…, \\unc) roots so a
// project's absolute path in config.toml isn't mistaken for relative and
// prefixed with the workspace base dir on Windows.
final _driveLetter = RegExp(r'^[A-Za-z]:'); // Windows C:\ / C:/ root
bool _isAbsolutePath(String p) =>
    p.startsWith('/') || p.startsWith(r'\') || _driveLetter.hasMatch(p);

String _expand(String p) => expandHome(p);
