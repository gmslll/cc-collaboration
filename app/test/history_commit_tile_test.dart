import 'package:app/local/git.dart';
import 'package:app/theme.dart';
import 'package:app/widgets/history_commit_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'selected history commit tile renders without ListTile assertion',
    (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: HistoryCommitTile(
                commit: _commit(refs: 'HEAD -> main, origin/main'),
                selected: true,
                onTap: () => tapped = true,
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Improve history rendering'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);

      await tester.tap(find.byType(ListTile));
      expect(tapped, isTrue);
    },
  );

  testWidgets('disabled history commit tile ignores taps', (tester) async {
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: HistoryCommitTile(
              commit: _commit(),
              selected: true,
              disabled: true,
              onTap: () => tapped = true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ListTile));
    expect(tapped, isFalse);
  });
}

GitCommit _commit({String refs = ''}) => GitCommit(
  hash: '1234567890abcdef',
  shortHash: '1234567',
  author: 'dev@example.com',
  date: DateTime.fromMillisecondsSinceEpoch(0),
  subject: 'Improve history rendering',
  refs: refs,
);
