import 'package:app/api/models.dart';
import 'package:app/theme.dart';
import 'package:app/widgets/inbox_item_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('inbox item tags stay bounded on narrow cards', (tester) async {
    final item = ListItem.fromJson({
      'id': 'h-long',
      'kind': 'delivery',
      'sender': 'sender-with-an-extremely-long-team-identity@example.test',
      'recipient':
          'recipient-with-an-extremely-long-team-identity@example.test',
      'urgency': 'normal',
      'state': 'pending',
      'repo_name': 'repo-name-with-an-extremely-long-team-workspace-label',
      'headline': 'Review a narrow handoff card',
      'created_at': '2026-01-01T00:00:00Z',
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 180, child: InboxItemCard(item: item)),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(InboxItemCard), findsOneWidget);
  });
}
