import 'package:app/screens/workspace_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'row secondary tap does not also open workspace background menu',
    (tester) async {
      var rowMenus = 0;
      var backgroundMenus = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 420,
              child: WorkspaceTreeScrollSurface(
                empty: const SizedBox.shrink(),
                onBackgroundSecondaryTapDown: (_) => backgroundMenus++,
                children: [
                  GestureDetector(
                    key: const ValueKey('session-row'),
                    behavior: HitTestBehavior.opaque,
                    onSecondaryTapDown: (_) => rowMenus++,
                    child: const SizedBox(height: 48, width: double.infinity),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('session-row')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();

      expect(rowMenus, 1);
      expect(backgroundMenus, 0);

      await tester.tap(
        find.byKey(const ValueKey('workspace-tree-blank-context-region')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();

      expect(rowMenus, 1);
      expect(backgroundMenus, 1);
    },
  );

  testWidgets('long workspace tree does not append extra blank space', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 420,
            child: WorkspaceTreeScrollSurface(
              empty: const SizedBox.shrink(),
              onBackgroundSecondaryTapDown: (_) {},
              children: List.generate(
                20,
                (index) => SizedBox(
                  key: ValueKey('row-$index'),
                  height: 48,
                  child: Text('row $index'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, closeTo(540, 1));

    await tester.drag(
      find.byKey(const ValueKey('workspace-project-tree')),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('row-19')), findsOneWidget);
  });
}
