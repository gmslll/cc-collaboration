import 'dart:convert';
import 'dart:io';

import 'package:app/local/local_bus.dart';
import 'package:flutter_test/flutter_test.dart';

// Isolation: LocalBus derives its dir from HOME (ccConfigDir → ~/.config/cc-handoff).
// Run this test with a temp HOME so it never touches the real/live bus:
//   HOME=$(mktemp -d) flutter test test/local_bus_kill_test.dart
// The test skips itself if HOME still points at a real config to avoid clobbering
// a running app's outbox. Mirrors local_bus_spawn_test.dart.
void main() {
  bool isIsolatedHome(String home) =>
      home.startsWith('/tmp') ||
      home.startsWith('/private/') ||
      home.startsWith('/var/folders/');

  test('LocalBus routes kind:"kill" to the kill callback and returns ok',
      () async {
    final home = Platform.environment['HOME'] ?? '';
    final busDir = Directory('$home/.config/cc-handoff/local-bus');
    if (!isIsolatedHome(home)) return; // not an isolated HOME — skip (see header)

    final outbox = Directory('${busDir.path}/outbox');
    await outbox.create(recursive: true);

    String? gotFrom, gotTo;
    final bus = LocalBus(
      registry: () => const [],
      deliver: (_) => 'unexpected deliver',
      readOutput: (_, _, _, _) async => 'unexpected read',
      readUsage: (_, _) async => 'unexpected usage',
      spawn: (_, _, _, _, _, _) async => 'unexpected spawn',
      kill: (from, to) {
        gotFrom = from;
        gotTo = to;
        return null; // success
      },
    );
    await bus.start();
    addTearDown(bus.dispose);

    final req = {'from': 'ts0', 'to': 'ts1', 'kind': 'kill'};
    const id = 'req-kill-1';
    await File('${outbox.path}/$id.json').writeAsString(jsonEncode(req));

    final okFile = File('${outbox.path}/$id.ok');
    for (var i = 0; i < 200 && !okFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(okFile.existsSync(), isTrue, reason: 'no .ok receipt written');
    expect(gotFrom, 'ts0');
    expect(gotTo, 'ts1');
  });

  test('LocalBus surfaces the kill callback error as .err', () async {
    final home = Platform.environment['HOME'] ?? '';
    final busDir = Directory('$home/.config/cc-handoff/local-bus');
    if (!isIsolatedHome(home)) return;

    final outbox = Directory('${busDir.path}/outbox');
    await outbox.create(recursive: true);

    final bus = LocalBus(
      registry: () => const [],
      deliver: (_) => 'unexpected deliver',
      readOutput: (_, _, _, _) async => 'unexpected read',
      readUsage: (_, _) async => 'unexpected usage',
      spawn: (_, _, _, _, _, _) async => 'unexpected spawn',
      kill: (from, to) => '不能通过总线关闭总管会话「总管」',
    );
    await bus.start();
    addTearDown(bus.dispose);

    final req = {'from': 'ts0', 'to': 'ts-supervisor', 'kind': 'kill'};
    const id = 'req-kill-2';
    await File('${outbox.path}/$id.json').writeAsString(jsonEncode(req));

    final errFile = File('${outbox.path}/$id.err');
    for (var i = 0; i < 200 && !errFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(errFile.existsSync(), isTrue, reason: 'no .err receipt written');
    expect(await errFile.readAsString(), contains('总管'));
  });
}
