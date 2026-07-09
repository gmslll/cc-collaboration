import '../api/models.dart';
import '../api/todo_models.dart';

String? uniqueProjectIdByName(Iterable<ProjectRole> projects, String? name) {
  final target = (name ?? '').trim();
  if (target.isEmpty) return null;
  final ids = <String>{};
  for (final p in projects) {
    if (p.name.trim() == target && p.id.trim().isNotEmpty) {
      ids.add(p.id.trim());
    }
  }
  return ids.length == 1 ? ids.single : null;
}

bool todoBoundToWorkspaceProject(
  Todo todo, {
  required String? workspaceName,
  required String? projectName,
}) {
  final ws = (workspaceName ?? '').trim();
  final project = (projectName ?? '').trim();
  if (ws.isEmpty || project.isEmpty) return false;
  return (todo.workspaceName ?? '').trim() == ws &&
      (todo.repoName ?? '').trim() == project;
}

bool todoInWorkspaceScope(
  Todo todo, {
  required Iterable<ProjectRole> projectRoles,
  required String? workspaceName,
  required String? projectName,
}) {
  if (todo.isPersonal) return true;
  if (todoBoundToWorkspaceProject(
    todo,
    workspaceName: workspaceName,
    projectName: projectName,
  )) {
    return true;
  }
  final projectId = uniqueProjectIdByName(projectRoles, projectName);
  return projectId != null && todo.projectId == projectId;
}
