import 'package:app/local/session_overview.dart';
import 'package:app/widgets/session_snapshot_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// SessionSnapshotView renders the quick-reply preview at the SOURCE terminal's
// width (no reflow) and scales the whole grid to fit via FittedBox. These guard:
//  - the FittedBox-over-a-Scrollable(TerminalView) layout never throws (the one
//    runtime risk the analyzer can't catch), and
//  - the throwaway terminal is resized to the source geometry rather than the
//    popup's narrow width — which is exactly what used to shatter the box art /
//    separators / agent prompt into a wrapped mess.
void main() {
  Future<void> pump(WidgetTester tester, ScreenSnapshot? snap) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300, // narrower than a 120-col source on purpose
              child: SessionSnapshotView(
                snapshot: snap,
                height: 280,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  int previewCols(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal.viewWidth;

  testWidgets('renders a wide TUI snapshot without a layout exception', (
    tester,
  ) async {
    final ansi = [
      '── Worked for 1m 05s ${'─' * 100}',
      '› Implement {feature}',
      '· gpt-5.5 medium · ~/cc-handoff-workspaces/kunlun/kunlun-frontend',
    ].join('\r\n');
    await pump(tester, (ansi: ansi, cols: 120, rows: 20));

    expect(tester.takeException(), isNull);
    expect(find.byType(SessionSnapshotView), findsOneWidget);
    // Rendered at the SOURCE width, not reflowed to the ~40-col popup box.
    expect(previewCols(tester), 120);
  });

  testWidgets('a null snapshot lays out at a default geometry', (tester) async {
    await pump(tester, null);
    expect(tester.takeException(), isNull);
    expect(previewCols(tester), 80);
  });

  testWidgets('a new snapshot re-sizes the preview terminal', (tester) async {
    await pump(tester, (ansi: 'hello\r\nworld', cols: 120, rows: 12));
    expect(previewCols(tester), 120);

    await pump(tester, (ansi: 'narrow now', cols: 48, rows: 12));
    expect(previewCols(tester), 48);
    expect(tester.takeException(), isNull);
  });
}
