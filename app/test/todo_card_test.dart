import 'package:app/api/todo_models.dart';
import 'package:app/theme.dart';
import 'package:app/widgets/todo_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('todo card tags stay bounded on narrow team cards', (
    tester,
  ) async {
    const longProject =
        'team-project-with-a-very-long-name-that-would-overflow-the-card';
    const longRepo =
        'repo-with-a-very-long-name-that-belongs-to-a-shared-team-workspace';
    const longGroup =
        'group-with-a-very-long-name-for-cross-functional-team-work';
    final todo = Todo.fromJson({
      'id': 'td-long-tags',
      'project_id': 'proj1',
      'owner_identity': 'owner@x',
      'title': 'Review the team task card layout',
      'body_md': '',
      'status': 'todo',
      'priority': 'normal',
      'repo_name': longRepo,
      'group_name': longGroup,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
      'comment_count': 0,
      'attachment_count': 0,
      'attachments': <Map<String, dynamic>>[],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 150,
              child: TodoCard(todo: todo, projectName: longProject),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in [longProject, longRepo, longGroup]) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    }
    expect(tester.takeException(), isNull);
  });
}
