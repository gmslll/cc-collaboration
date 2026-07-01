import 'dart:convert';
import 'dart:io';

import 'package:app/local/local_bus.dart';
import 'package:flutter_test/flutter_test.dart';

// Isolation: LocalBus derives its dir from HOME (ccConfigDir → ~/.config/cc-handoff).
// Run this test with a temp HOME so it never touches the real/live bus:
//   HOME=$(mktemp -d) flutter test test/local_bus_spawn_test.dart
// The test skips itself if HOME still points at a real config to avoid clobbering
// a running app's outbox.
void main() {
  test('LocalBus routes kind:"spawn" to the spawn callback and returns id as .ok',
      () async {
    final home = Platform.environment['HOME'] ?? '';
    final busDir = Directory('$home/.config/cc-handoff/local-bus');
    // Guard: only run against a throwaway HOME (temp dir), never a real profile.
    if (!home.startsWith('/tmp') &&
        !home.startsWith('/private/') &&
        !home.startsWith('/var/folders/')) {
      return; // not an isolated HOME — skip (see header)
    }
    final outbox = Directory('${busDir.path}/outbox');
    await outbox.create(recursive: true);

    String? gotProject, gotWorkspace, gotAgent, gotWorkdir;
    bool? gotSupervisor;
    final bus = LocalBus(
      registry: () => const [],
      deliver: (_) => 'unexpected deliver',
      readOutput: (_, _, _, _) async => 'unexpected read',
      readUsage: (_, _) async => 'unexpected usage',
      spawn: (project, workspace, agent, supervisor, workdir, out) async {
        gotProject = project;
        gotWorkspace = workspace;
        gotAgent = agent;
        gotSupervisor = supervisor;
        gotWorkdir = workdir;
        out.write('ts42'); // the new session id the app would mint
        return null; // success
      },
    );
    await bus.start();
    addTearDown(bus.dispose);

    // Drop a spawn request the way `cc-handoff supervisor spawn` does.
    final req = {
      'from': 'ts0',
      'kind': 'spawn',
      'project': 'cc-collaboration',
      'workspace': 'kunlun',
      'agent': 'codex',
      'supervisor': true,
      'workdir': '/w/cc/.worktrees/x',
    };
    final id = 'req1';
    await File('${outbox.path}/$id.json').writeAsString(jsonEncode(req));

    // Poll for the .ok receipt (mirrors publishAndAwait on the CLI side).
    final okFile = File('${outbox.path}/$id.ok');
    for (var i = 0; i < 200 && !okFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(okFile.existsSync(), isTrue, reason: 'no .ok receipt written');
    expect(await okFile.readAsString(), 'ts42');
    expect(gotProject, 'cc-collaboration');
    expect(gotWorkspace, 'kunlun');
    expect(gotAgent, 'codex');
    expect(gotSupervisor, true);
    expect(gotWorkdir, '/w/cc/.worktrees/x');
  });
}
