import 'package:app/theme.dart';
import 'package:app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Finder constrainedTitle(String title) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == title &&
        widget.maxLines == 1 &&
        widget.overflow == TextOverflow.ellipsis,
  );

  testWidgets('textPrompt returns trimmed confirmed input', (tester) async {
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await textPrompt(
                  context,
                  title: 'Rename',
                  initial: '  old  ',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  new name  ');
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(result, 'new name');
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('textPrompt returns null when cancelled', (tester) async {
    String? result = 'unchanged';

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await textPrompt(
                  context,
                  title: 'Rename',
                  initial: 'value',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('textPrompt title is width constrained', (tester) async {
    const title = 'Rename a workspace with a very long generated team name';

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () {
                textPrompt(context, title: title, initial: 'value');
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(constrainedTitle(title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirm title is width constrained', (tester) async {
    const title = 'Delete a shared workspace owned by a very long team name';

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () {
                confirm(context, 'This cannot be undone.', title: title);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(constrainedTitle(title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
