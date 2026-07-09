import 'package:app/api/models.dart';
import 'package:app/api/todo_models.dart';
import 'package:app/local/todo_assignment_candidates.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectMember _projectMember(String identity, String role) =>
    ProjectMember.fromJson({'identity': identity, 'role': role});

OrganizationMember _orgMember(String identity, String role) =>
    OrganizationMember.fromJson({'identity': identity, 'role': role});

Todo _todo({String? assigneeIdentity, String? assigneeDisplayName}) =>
    Todo.fromJson({
      'id': 't1',
      'project_id': 'p1',
      'owner_identity': 'owner@x',
      'title': 'Task',
      'body_md': '',
      'status': 'todo',
      'priority': 'normal',
      'assignee_identity': assigneeIdentity,
      'assignee_display_name': assigneeDisplayName,
      'assignee_session_id': null,
      'assignee_session_label': null,
      'recurrence': '',
      'due_at': null,
      'next_occurrence_at': null,
      'completed_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
      'comment_count': 0,
      'attachment_count': 0,
    });

void main() {
  test('includes direct project members and team managers only', () {
    final ids = assignableTodoMemberIds(
      selfIdentity: 'owner@x',
      currentAssignee: 'former@x',
      projectMembers: [
        _projectMember('member@x', 'member'),
        _projectMember('viewer@x', 'viewer'),
        _projectMember('org-admin@x', 'member'),
      ],
      organizationMembers: [
        _orgMember('org-owner@x', 'owner'),
        _orgMember('org-admin@x', 'admin'),
        _orgMember('plain-member@x', 'member'),
        _orgMember('guest@x', 'guest'),
      ],
    );

    expect(ids, [
      'owner@x',
      'former@x',
      'member@x',
      'viewer@x',
      'org-admin@x',
      'org-owner@x',
    ]);
  });

  test('trims and deduplicates identities while preserving priority order', () {
    final ids = assignableTodoMemberIds(
      selfIdentity: ' owner@x ',
      currentAssignee: 'owner@x',
      projectMembers: [
        _projectMember(' member@x ', 'member'),
        _projectMember('member@x', 'viewer'),
      ],
      organizationMembers: [
        _orgMember('owner@x', 'admin'),
        _orgMember(' admin@x ', 'admin'),
      ],
    );

    expect(ids, ['owner@x', 'member@x', 'admin@x']);
  });

  test(
    'current assignee candidate name uses display overlay only when useful',
    () {
      expect(
        currentAssigneeCandidateName(
          _todo(assigneeIdentity: 'dev@x', assigneeDisplayName: 'Dev'),
        ),
        'Dev',
      );
      expect(
        currentAssigneeCandidateName(
          _todo(assigneeIdentity: 'dev@x', assigneeDisplayName: 'dev@x'),
        ),
        isEmpty,
      );
      expect(
        currentAssigneeCandidateName(_todo(assigneeIdentity: 'dev@x')),
        isEmpty,
      );
    },
  );
}
