import '../api/models.dart';
import '../api/todo_models.dart';
import 'identity.dart';

class TodoAccess {
  final bool canComment;
  final bool canEdit;
  final bool canDelete;

  const TodoAccess({
    required this.canComment,
    required this.canEdit,
    required this.canDelete,
  });

  bool get canAssign => canEdit;
  bool get canUploadAttachment => canEdit;

  static const none = TodoAccess(
    canComment: false,
    canEdit: false,
    canDelete: false,
  );

  static const editable = TodoAccess(
    canComment: true,
    canEdit: true,
    canDelete: false,
  );

  static const full = TodoAccess(
    canComment: true,
    canEdit: true,
    canDelete: true,
  );
}

TodoAccess todoAccessFor(Todo todo, Me me) {
  if (me.isAdmin) return TodoAccess.full;
  if (todo.isPersonal) {
    return sameIdentity(todo.ownerIdentity, me.identity)
        ? TodoAccess.full
        : TodoAccess.none;
  }
  final role = projectRoleForTodo(todo, me);
  return todoAccessForProjectRole(role);
}

String? projectRoleForTodo(Todo todo, Me me) {
  final projectId = todo.projectId;
  if (projectId == null || projectId.isEmpty) return null;
  for (final project in me.projects) {
    if (project.id == projectId) return project.role.trim().toLowerCase();
  }
  return null;
}

TodoAccess todoAccessForProjectRole(String? role) {
  switch ((role ?? '').trim().toLowerCase()) {
    case 'owner':
    case 'admin':
      return TodoAccess.full;
    case 'member':
      return TodoAccess.editable;
    case 'viewer':
    default:
      return TodoAccess.none;
  }
}

bool canCreateProjectTodo(ProjectRole project, Me me) {
  if (me.isAdmin) return true;
  return todoAccessForProjectRole(project.role).canEdit;
}
