import 'dart:io';

import 'package:toml/toml.dart';

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

  AppConfig(this.relayUrl, this.token, this.identity, this.repos,
      [this.workspaces = const [],
      this.agent = '',
      this.workspaceRoot = '',
      this.gradeCommand = '',
      this.linearToken = '',
      this.githubToken = '',
      this.terminalApp = '']);

  String? repoPath(String name) => repos[name];

  static String configPath() => '${_home()}/.config/cc-handoff/config.toml';

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
        if (path.isNotEmpty && !path.startsWith('/')) path = '$base/$path';
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
        grade, linear, githubToken, terminalApp);
  }
}

String _home() => Platform.environment['HOME'] ?? '';

String _expand(String p) {
  if (p == '~') return _home();
  if (p.startsWith('~/')) return '${_home()}/${p.substring(2)}';
  return p;
}
