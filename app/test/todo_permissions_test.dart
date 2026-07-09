import 'package:app/api/models.dart';
import 'package:app/api/todo_models.dart';
import 'package:app/local/todo_permissions.dart';
import 'package:flutter_test/flutter_test.dart';

Me _me({
  String identity = 'alice@x',
  bool isAdmin = false,
  String? projectRole,
}) => Me.fromJson({
  'identity': identity,
  'is_admin': isAdmin,
  'projects': [
    if (projectRole != null) {'id': 'p1', 'name': 'P1', 'role': projectRole},
  ],
});

Todo _todo({String? projectId, String owner = 'alice@x'}) => Todo.fromJson({
  'id': 't1',
  'project_id': projectId,
  'owner_identity': owner,
  'title': 'Todo',
  'status': 'todo',
  'priority': 'normal',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
});

void main() {
  test('personal todo owner gets full access', () {
    final access = todoAccessFor(_todo(), _me());

    expect(access.canComment, isTrue);
    expect(access.canEdit, isTrue);
    expect(access.canDelete, isTrue);
  });

  test('personal todo non-owner is read-only/no access in UI', () {
    final access = todoAccessFor(_todo(owner: 'owner@x'), _me());

    expect(access.canComment, isFalse);
    expect(access.canEdit, isFalse);
    expect(access.canDelete, isFalse);
  });

  test('team viewer is read-only', () {
    final access = todoAccessFor(
      _todo(projectId: 'p1'),
      _me(projectRole: 'viewer'),
    );

    expect(access.canComment, isFalse);
    expect(access.canEdit, isFalse);
    expect(access.canDelete, isFalse);
    expect(access.canAssign, isFalse);
    expect(access.canUploadAttachment, isFalse);
  });

  test('team member can edit and comment but not delete', () {
    final access = todoAccessFor(
      _todo(projectId: 'p1'),
      _me(projectRole: 'member'),
    );

    expect(access.canComment, isTrue);
    expect(access.canEdit, isTrue);
    expect(access.canDelete, isFalse);
    expect(access.canAssign, isTrue);
    expect(access.canUploadAttachment, isTrue);
  });

  test('team owner admin and global admin get full access', () {
    for (final role in ['owner', 'admin']) {
      final access = todoAccessFor(
        _todo(projectId: 'p1'),
        _me(projectRole: role),
      );
      expect(access.canComment, isTrue, reason: role);
      expect(access.canEdit, isTrue, reason: role);
      expect(access.canDelete, isTrue, reason: role);
    }

    final global = todoAccessFor(
      _todo(projectId: 'missing'),
      _me(isAdmin: true),
    );
    expect(global.canDelete, isTrue);
  });

  test('only project editors can create team todos', () {
    expect(
      canCreateProjectTodo(
        ProjectRole.fromJson({'id': 'p1', 'name': 'P1', 'role': 'viewer'}),
        _me(projectRole: 'viewer'),
      ),
      isFalse,
    );
    expect(
      canCreateProjectTodo(
        ProjectRole.fromJson({'id': 'p1', 'name': 'P1', 'role': 'member'}),
        _me(projectRole: 'member'),
      ),
      isTrue,
    );
  });
}
