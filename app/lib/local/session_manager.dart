import 'dart:convert';

import 'config.dart';
import 'path_utils.dart';
import 'session_overview.dart';
import 'worktrees.dart';

const otherSessionsKey = '__other_sessions__';
const defaultWorkspaceKey = '__default_workspace__';

enum SessionManagerFilter { all, attention, running, idle, completed }

class SessionProjectMembership {
  final WorkspaceCfg workspace;
  final ProjectCfg project;
  final String relativePath;

  const SessionProjectMembership({
    required this.workspace,
    required this.project,
    required this.relativePath,
  });
}

SessionProjectMembership? resolveSessionProject(
  String path,
  Iterable<WorkspaceCfg> workspaces,
) {
  WorkspaceCfg? bestWorkspace;
  ProjectCfg? bestProject;
  for (final workspace in workspaces) {
    for (final project in workspace.projects) {
      if (!pathWithin(path, project.path)) continue;
      if (bestProject == null ||
          project.path.length > bestProject.path.length) {
        bestWorkspace = workspace;
        bestProject = project;
      }
    }
  }
  if (bestWorkspace == null || bestProject == null) return null;
  return SessionProjectMembership(
    workspace: bestWorkspace,
    project: bestProject,
    relativePath: pathRelativeTo(bestProject.path, path),
  );
}

Worktree? resolveSessionWorktree(String path, Iterable<Worktree> worktrees) {
  Worktree? best;
  for (final worktree in worktrees) {
    if (!pathWithin(path, worktree.path)) continue;
    if (best == null || worktree.path.length > best.path.length) {
      best = worktree;
    }
  }
  return best;
}

List<String> visibleWorkspaceNames(
  Iterable<String> workspaceNames,
  String? focusedWorkspace,
) {
  final names = workspaceNames.toList();
  if (names.length <= 1 || focusedWorkspace == null) return names;
  return names.where((name) => name == focusedWorkspace).toList();
}

String? workspaceFocusAfterDoubleClick({
  required Iterable<String> workspaceNames,
  required String? currentFocus,
  required String tappedWorkspace,
}) {
  final names = workspaceNames.toList();
  if (names.length <= 1 || !names.contains(tappedWorkspace)) return null;
  return currentFocus == tappedWorkspace ? null : tappedWorkspace;
}

String sessionManagerFilterLabel(SessionManagerFilter filter) =>
    switch (filter) {
      SessionManagerFilter.all => '全部状态',
      SessionManagerFilter.attention => '需要处理',
      SessionManagerFilter.running => '运行中',
      SessionManagerFilter.idle => '等待 / 空闲',
      SessionManagerFilter.completed => '最近完成',
    };

class ManagedSession {
  final String id;
  final String name;
  final String agent;
  final String workspace;
  final String project;
  final String projectPath;
  final String worktree;
  final String branch;
  final SessionStatus status;
  final String statusDetail;
  final DateTime? lastActivity;
  final String preview;
  final bool recentlyCompleted;

  const ManagedSession({
    required this.id,
    required this.name,
    required this.agent,
    required this.workspace,
    required this.project,
    required this.projectPath,
    required this.worktree,
    required this.branch,
    required this.status,
    required this.statusDetail,
    required this.lastActivity,
    required this.preview,
    this.recentlyCompleted = false,
  });

  bool get isUnknown => project.trim().isEmpty;

  String get workspaceKey {
    if (isUnknown) return otherSessionsKey;
    return workspace.trim().isEmpty ? defaultWorkspaceKey : workspace.trim();
  }

  String get projectKey {
    if (isUnknown) return otherSessionsKey;
    final path = projectPath.trim();
    if (path.isNotEmpty) return '$workspaceKey::$path';
    return '$workspaceKey::${project.trim()}';
  }

  String get subtitle {
    final b = branch.trim();
    final wt = worktree.trim();
    if (b.isNotEmpty && wt.isNotEmpty && b != wt) return '$b · $wt';
    if (b.isNotEmpty) return b;
    if (wt.isNotEmpty) return wt;
    return project.trim();
  }

  ManagedSession copyWith({String? name}) => ManagedSession(
    id: id,
    name: name ?? this.name,
    agent: agent,
    workspace: workspace,
    project: project,
    projectPath: projectPath,
    worktree: worktree,
    branch: branch,
    status: status,
    statusDetail: statusDetail,
    lastActivity: lastActivity,
    preview: preview,
    recentlyCompleted: recentlyCompleted,
  );
}

class SessionProjectGroup {
  final String key;
  final String name;
  final String path;
  final List<ManagedSession> sessions;

  const SessionProjectGroup({
    required this.key,
    required this.name,
    required this.path,
    required this.sessions,
  });
}

class SessionWorkspaceGroup {
  final String key;
  final String name;
  final bool isOther;
  final List<SessionProjectGroup> projects;

  const SessionWorkspaceGroup({
    required this.key,
    required this.name,
    required this.isOther,
    required this.projects,
  });
}

class TopSessionWorkset {
  final List<String> projectIds;
  final List<String> pinnedIds;
  final List<String> attentionIds;

  const TopSessionWorkset({
    required this.projectIds,
    required this.pinnedIds,
    required this.attentionIds,
  });

  List<String> get allIds => [...projectIds, ...pinnedIds, ...attentionIds];
}

bool sessionNeedsAttention(ManagedSession session) => switch (session.status) {
  SessionStatus.needsReview ||
  SessionStatus.waitingPermission ||
  SessionStatus.toolFailed => true,
  _ => false,
};

bool sessionIsRunning(ManagedSession session) => switch (session.status) {
  SessionStatus.working ||
  SessionStatus.runningTool ||
  SessionStatus.toolDone ||
  SessionStatus.compacting ||
  SessionStatus.subagent => true,
  _ => false,
};

int sessionStatusPriority(ManagedSession session) {
  if (sessionNeedsAttention(session)) return 0;
  if (sessionIsRunning(session)) return 1;
  if (!session.recentlyCompleted) return 2;
  return 3;
}

int compareManagedSessions(ManagedSession a, ManagedSession b) {
  final status = sessionStatusPriority(a).compareTo(sessionStatusPriority(b));
  if (status != 0) return status;
  final activity = (b.lastActivity?.microsecondsSinceEpoch ?? 0).compareTo(
    a.lastActivity?.microsecondsSinceEpoch ?? 0,
  );
  if (activity != 0) return activity;
  return a.id.compareTo(b.id);
}

List<SessionWorkspaceGroup> groupManagedSessions(
  Iterable<ManagedSession> sessions,
) {
  final byWorkspace = <String, List<ManagedSession>>{};
  for (final session in sessions) {
    (byWorkspace[session.workspaceKey] ??= []).add(session);
  }

  final groups = <SessionWorkspaceGroup>[];
  for (final entry in byWorkspace.entries) {
    final byProject = <String, List<ManagedSession>>{};
    for (final session in entry.value) {
      (byProject[session.projectKey] ??= []).add(session);
    }
    final projects = <SessionProjectGroup>[
      for (final projectEntry in byProject.entries)
        SessionProjectGroup(
          key: projectEntry.key,
          name: projectEntry.key == otherSessionsKey
              ? '未归属'
              : projectEntry.value.first.project,
          path: projectEntry.value.first.projectPath,
          sessions: List<ManagedSession>.of(projectEntry.value)
            ..sort(compareManagedSessions),
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    groups.add(
      SessionWorkspaceGroup(
        key: entry.key,
        name: entry.key == otherSessionsKey
            ? '其他会话'
            : entry.key == defaultWorkspaceKey
            ? '(默认)'
            : entry.value.first.workspace,
        isOther: entry.key == otherSessionsKey,
        projects: projects,
      ),
    );
  }
  groups.sort((a, b) {
    if (a.isOther != b.isOther) return a.isOther ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return groups;
}

bool managedSessionMatches(ManagedSession session, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return [
    session.name,
    session.project,
    session.workspace,
    session.branch,
    session.worktree,
    session.agent,
    session.preview,
  ].any((value) => value.toLowerCase().contains(q));
}

bool managedSessionMatchesFilter(
  ManagedSession session,
  SessionManagerFilter filter,
) => switch (filter) {
  SessionManagerFilter.all => true,
  SessionManagerFilter.attention => sessionNeedsAttention(session),
  SessionManagerFilter.running => sessionIsRunning(session),
  SessionManagerFilter.idle =>
    !sessionNeedsAttention(session) &&
        !sessionIsRunning(session) &&
        !session.recentlyCompleted,
  SessionManagerFilter.completed => session.recentlyCompleted,
};

List<ManagedSession> filterManagedSessions(
  Iterable<ManagedSession> sessions, {
  String query = '',
  SessionManagerFilter filter = SessionManagerFilter.all,
}) => [
  for (final session in sessions)
    if (managedSessionMatches(session, query) &&
        managedSessionMatchesFilter(session, filter))
      session,
]..sort(compareManagedSessions);

Map<String, String> disambiguatedSessionNames(
  Iterable<ManagedSession> sessions,
) {
  final all = sessions.toList();
  final rawCounts = <String, int>{};
  for (final session in all) {
    final key = session.name.trim().toLowerCase();
    rawCounts[key] = (rawCounts[key] ?? 0) + 1;
  }

  final candidates = <String, String>{};
  final candidateCounts = <String, int>{};
  for (final session in all) {
    final name = session.name.trim().isEmpty ? session.id : session.name.trim();
    final duplicate = (rawCounts[name.toLowerCase()] ?? 0) > 1;
    final project = session.project.trim().isEmpty
        ? '其他会话'
        : session.project.trim();
    final candidate = duplicate ? '$project · $name' : name;
    candidates[session.id] = candidate;
    final key = candidate.toLowerCase();
    candidateCounts[key] = (candidateCounts[key] ?? 0) + 1;
  }

  final result = <String, String>{};
  final expandedCounts = <String, int>{};
  for (final session in all) {
    var label = candidates[session.id]!;
    if ((candidateCounts[label.toLowerCase()] ?? 0) > 1) {
      final qualifier = session.subtitle.isNotEmpty
          ? session.subtitle
          : (session.agent.trim().isNotEmpty
                ? session.agent.trim()
                : session.id);
      label = '$label · $qualifier';
    }
    final key = label.toLowerCase();
    expandedCounts[key] = (expandedCounts[key] ?? 0) + 1;
    result[session.id] = label;
  }
  for (final session in all) {
    final label = result[session.id]!;
    if ((expandedCounts[label.toLowerCase()] ?? 0) > 1) {
      result[session.id] = '$label · ${session.id}';
    }
  }
  return result;
}

Set<String> togglePinnedSession(Set<String> pinned, String id) {
  final next = Set<String>.of(pinned);
  if (!next.add(id)) next.remove(id);
  return next;
}

Set<String> sessionManagerSetFromPref(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return {for (final value in decoded) value.toString()};
    }
  } catch (_) {}
  return {};
}

String sessionManagerSetPrefValue(Set<String> values) {
  final sorted = values.toList()..sort();
  return jsonEncode(sorted);
}

TopSessionWorkset topSessionWorkset({
  required List<ManagedSession> sessions,
  required String? activeId,
  required Set<String> pinnedIds,
  Set<String> explicitlyHiddenIds = const {},
}) {
  final active = sessions
      .where((session) => session.id == activeId)
      .firstOrNull;
  final currentProjectKey = active?.projectKey;
  bool visible(ManagedSession session) =>
      !explicitlyHiddenIds.contains(session.id);
  final projectIds = [
    for (final session in sessions)
      if (visible(session) &&
          (session.id == activeId ||
              (currentProjectKey != null &&
                  session.projectKey == currentProjectKey)))
        session.id,
  ];
  final projectIdSet = projectIds.toSet();
  final crossPinnedIds = [
    for (final session in sessions)
      if (visible(session) &&
          !projectIdSet.contains(session.id) &&
          pinnedIds.contains(session.id))
        session.id,
  ];
  final pinnedIdSet = crossPinnedIds.toSet();
  final attentionIds = [
    for (final session in sessions)
      if (visible(session) &&
          !projectIdSet.contains(session.id) &&
          !pinnedIdSet.contains(session.id) &&
          sessionNeedsAttention(session))
        session.id,
  ];
  return TopSessionWorkset(
    projectIds: projectIds,
    pinnedIds: crossPinnedIds,
    attentionIds: attentionIds,
  );
}
