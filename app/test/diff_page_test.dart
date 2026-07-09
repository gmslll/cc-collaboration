import 'dart:async';

import 'package:app/screens/diff_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stale diff load cannot overwrite the selected mode', (
    tester,
  ) async {
    final loader = _DelayedDiffLoader();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: DiffPage(
          path: '/repo',
          name: 'repo',
          loadBaseRef: (_) async => 'origin/main',
          loadWorkingDiff: loader.working,
          loadBaseDiff: loader.base,
        ),
      ),
    );
    await tester.pump();
    expect(loader.workingStarted, isTrue);

    await tester.tap(find.text('vs origin/main'));
    await tester.pump();
    expect(loader.baseStarted, isTrue);

    loader.completeBase(
      _diff('new.txt', before: 'old base', after: 'new base'),
    );
    await tester.pumpAndSettle();
    expect(find.text('new.txt'), findsWidgets);
    expect(find.text('old.txt'), findsNothing);

    loader.completeWorking(
      _diff('old.txt', before: 'old working', after: 'new working'),
    );
    await tester.pumpAndSettle();
    expect(find.text('new.txt'), findsWidgets);
    expect(find.text('old.txt'), findsNothing);
  });
}

String _diff(String path, {required String before, required String after}) =>
    '''
diff --git a/$path b/$path
index 1111111..2222222 100644
--- a/$path
+++ b/$path
@@ -1 +1 @@
-$before
+$after
''';

class _DelayedDiffLoader {
  final _working = Completer<String>();
  final _base = Completer<String>();
  bool workingStarted = false;
  bool baseStarted = false;

  Future<String> working(String path, {int context = 3}) {
    workingStarted = true;
    return _working.future;
  }

  Future<String> base(String path, String base, {int context = 3}) {
    baseStarted = true;
    return _base.future;
  }

  void completeWorking(String diff) {
    if (!_working.isCompleted) _working.complete(diff);
  }

  void completeBase(String diff) {
    if (!_base.isCompleted) _base.complete(diff);
  }
}
