import 'package:app/screens/terminal_deck.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:app/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TerminalSession session(String id, String name) =>
    TerminalSession('/repo/$id', '', id: id, agent: '')..name = name;

void main() {
  test(
    'restore duplicate guard prefers stable id and covers legacy entries',
    () {
      final existing = TerminalSession(
        '/repo',
        'codex',
        id: 'ts200',
        agent: 'codex',
        agentSessionId: 'agent-1',
      );
      addTearDown(existing.dispose);

      expect(
        restoredSessionDuplicates(
          existing: [existing],
          id: 'ts200',
          workdir: '/elsewhere',
          command: 'different',
          agent: 'claude',
          agentSessionId: '',
        ),
        isTrue,
      );
      expect(
        restoredSessionDuplicates(
          existing: [existing],
          id: '',
          workdir: '/repo',
          command: 'codex',
          agent: 'codex',
          agentSessionId: 'agent-1',
        ),
        isTrue,
      );
      expect(
        restoredSessionDuplicates(
          existing: [existing],
          id: 'ts201',
          workdir: '/repo',
          command: 'codex',
          agent: 'codex',
          agentSessionId: 'agent-1',
        ),
        isFalse,
      );
    },
  );

  testWidgets('tab bar stays one line, separates pinned, and collapses to +N', (
    tester,
  ) async {
    final sessions = [
      session('ts100', 'current one'),
      session('ts101', 'current two'),
      session('ts102', 'current three'),
      session('ts103', 'pinned other project'),
      session('ts104', 'needs permission'),
      session('ts105', 'current four'),
    ];
    addTearDown(() {
      for (final item in sessions) {
        item.dispose();
      }
    });
    var overflowTaps = 0;

    await tester.binding.setSurfaceSize(const Size(430, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 430,
              child: TerminalTabBar(
                terms: sessions,
                active: 0,
                displayOrderIds: [for (final item in sessions) item.id],
                pinnedIds: const {'ts103'},
                attentionIds: const {'ts104'},
                onShowAllSessions: () => overflowTaps++,
                onSwitch: (_) {},
                onClose: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(TerminalTabBar)).height, 38);
    expect(
      find.byKey(const ValueKey('terminal-tabs-overflow')),
      findsOneWidget,
    );
    expect(find.textContaining('+'), findsOneWidget);
    expect(find.text('pinned other project'), findsOneWidget);
    expect(find.text('needs permission'), findsOneWidget);
    expect(find.text('固定'), findsOneWidget);
    expect(find.text('需处理'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('terminal-tabs-overflow')));
    expect(overflowTaps, 1);
  });

  testWidgets('pinned cross-project tabs render under a distinct section', (
    tester,
  ) async {
    final sessions = [session('ts110', 'current'), session('ts111', 'pinned')];
    addTearDown(() {
      for (final item in sessions) {
        item.dispose();
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: TerminalTabBar(
              terms: sessions,
              active: 0,
              displayOrderIds: const ['ts110', 'ts111'],
              pinnedIds: const {'ts111'},
              onSwitch: (_) {},
              onClose: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('固定'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
  });

  testWidgets(
    'hidden cross-project sessions are absent from the normal strip',
    (tester) async {
      final sessions = [
        session('ts120', 'current'),
        session('ts121', 'same project'),
        session('ts122', 'other project'),
      ];
      addTearDown(() {
        for (final item in sessions) {
          item.dispose();
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: TerminalTabBar(
              terms: sessions,
              active: 0,
              hiddenIds: const {'ts122'},
              onSwitch: (_) {},
              onClose: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('current'), findsOneWidget);
      expect(find.text('same project'), findsOneWidget);
      expect(find.text('other project'), findsNothing);
    },
  );

  testWidgets('close affordance becomes significant on hover', (tester) async {
    final item = session('ts130', 'hover me');
    addTearDown(item.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TerminalTabBar(
            terms: [item],
            active: 0,
            onSwitch: (_) {},
            onClose: (_) {},
          ),
        ),
      ),
    );

    final close = find.byKey(const ValueKey('terminal-tab-close-ts130'));
    AnimatedOpacity opacity() => tester.widget<AnimatedOpacity>(
      find.ancestor(of: close, matching: find.byType(AnimatedOpacity)),
    );

    expect(opacity().opacity, lessThan(0.3));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.text('hover me')));
    await tester.pumpAndSettle();
    expect(opacity().opacity, 1);
  });

  testWidgets('tab tap switches the existing session index', (tester) async {
    final sessions = [session('ts140', 'one'), session('ts141', 'two')];
    addTearDown(() {
      for (final item in sessions) {
        item.dispose();
      }
    });
    int? switched;
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TerminalTabBar(
            terms: sessions,
            active: 0,
            onSwitch: (index) => switched = index,
            onClose: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('two'));
    expect(switched, 1);
  });
}
