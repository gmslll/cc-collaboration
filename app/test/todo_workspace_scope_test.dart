import 'package:app/api/models.dart';
import 'package:app/api/todo_models.dart';
import 'package:app/local/todo_workspace_scope.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectRole _project(String id, String orgId, String name) =>
    ProjectRole.fromJson({
      'id': id,
      'org_id': orgId,
      'name': name,
      'role': 'member',
    });

Todo _todo({
  required String id,
  String? projectId,
  String? workspaceName,
  String? repoName,
}) => Todo.fromJson({
  'id': id,
  'project_id': projectId,
  'owner_identity': 'alice',
  'title': 'Todo',
  'body_md': '',
  'status': 'todo',
  'priority': 'normal',
  'workspace_name': workspaceName,
  'repo_name': repoName,
  'recurrence': '',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'comment_count': 0,
  'attachment_count': 0,
});

void main() {
  test('uniqueProjectIdByName refuses duplicate team project names', () {
    expect(
      uniqueProjectIdByName([
        _project('p1', 'org-a', 'app'),
        _project('p2', 'org-b', 'app'),
      ], 'app'),
      isNull,
    );
    expect(
      uniqueProjectIdByName([
        _project('p1', 'org-a', 'app'),
        _project('p2', 'org-b', 'api'),
      ], 'app'),
      'p1',
    );
  });

  test('workspace scope includes personal and uniquely mapped team todos', () {
    final roles = [_project('p1', 'org-a', 'app')];

    expect(
      todoInWorkspaceScope(
        _todo(id: 'personal'),
        projectRoles: roles,
        workspaceName: 'team-a',
        projectName: 'app',
      ),
      isTrue,
    );
    expect(
      todoInWorkspaceScope(
        _todo(id: 'team', projectId: 'p1'),
        projectRoles: roles,
        workspaceName: 'team-a',
        projectName: 'app',
      ),
      isTrue,
    );
  });

  test('workspace scope does not guess duplicate team project names', () {
    final roles = [
      _project('p1', 'org-a', 'app'),
      _project('p2', 'org-b', 'app'),
    ];

    expect(
      todoInWorkspaceScope(
        _todo(id: 'unbound', projectId: 'p1'),
        projectRoles: roles,
        workspaceName: 'team-a',
        projectName: 'app',
      ),
      isFalse,
    );
    expect(
      todoInWorkspaceScope(
        _todo(
          id: 'bound',
          projectId: 'p1',
          workspaceName: 'team-a',
          repoName: 'app',
        ),
        projectRoles: roles,
        workspaceName: 'team-a',
        projectName: 'app',
      ),
      isTrue,
    );
  });
}
