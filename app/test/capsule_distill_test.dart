import 'dart:io';

import 'package:app/local/capsule_distill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A fake headless runner: routes by a keyword in the prompt so the persona
  // and seed one-shots return distinct bodies.
  ProcRunner fakeRunner({int exit = 0, bool emptyPersona = false}) =>
      (exe, args, {stdin}) async {
        final prompt = args.join(' ');
        if (prompt.contains('专职角色')) {
          return ProcOutcome(exit, emptyPersona ? '' : 'PERSONA-BODY', '');
        }
        if (prompt.contains('上下文摘要')) {
          return ProcOutcome(exit, 'SEED-BODY', '');
        }
        return ProcOutcome(exit, '', '');
      };

  String draft() => Directory.systemTemp.createTempSync('distill_').path;

  test('chooseDistillStrategy: self only when idle AND user opted in', () {
    expect(chooseDistillStrategy(sessionIdle: true, userWantsSelf: true),
        DistillStrategy.selfDistill);
    expect(chooseDistillStrategy(sessionIdle: false, userWantsSelf: true),
        DistillStrategy.offline);
    expect(chooseDistillStrategy(sessionIdle: true, userWantsSelf: false),
        DistillStrategy.offline);
  });

  test('prompts name both draft files + marker (self) and ask stdout-only (offline)',
      () {
    final self =
        selfDistillPrompt(personaPath: '/d/persona.md', seedPath: '/d/seed.md');
    expect(self, contains('/d/persona.md'));
    expect(self, contains('/d/seed.md'));
    expect(self, contains('CAPSULE_DISTILL_DONE'));
    // Skill listing is a SEPARATE second step, not baked into the distill prompt.
    expect(self, isNot(contains('deps.txt')));
    expect(skillListPrompt('/d/deps.txt'), contains('/d/deps.txt'));

    final p = offlinePersonaPrompt('TRANSCRIPT-XYZ');
    expect(p, contains('TRANSCRIPT-XYZ'));
    expect(p, contains('只输出'));
  });

  test('runOfflineDistill writes persona.md + seed.md from headless stdout',
      () async {
    final dir = draft();
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    final ok = await runOfflineDistill(
      agentKind: 'claude',
      headlessExe: 'claude',
      draftDir: dir,
      transcriptText: 't',
      runProc: fakeRunner(),
    );
    expect(ok, isTrue);
    expect(File('$dir/persona.md').readAsStringSync(), 'PERSONA-BODY');
    expect(File('$dir/seed.md').readAsStringSync(), 'SEED-BODY');
  });

  test('runOfflineDistill returns false when the persona one-shot yields nothing',
      () async {
    final dir = draft();
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    final ok = await runOfflineDistill(
      agentKind: 'claude',
      headlessExe: 'claude',
      draftDir: dir,
      transcriptText: 't',
      runProc: fakeRunner(emptyPersona: true),
    );
    expect(ok, isFalse);
    expect(File('$dir/persona.md').existsSync(), isFalse);
  });

  test('distillCapsule offline path runs headless and reports offline', () async {
    final dir = draft();
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    final out = await distillCapsule(
      agentKind: 'claude',
      headlessExe: 'claude',
      draftDir: dir,
      transcriptText: 't',
      sessionIdle: false, // busy → offline
      userWantsSelf: true,
      deliverToSession: (_) async => fail('must not touch a busy session'),
      runProc: fakeRunner(),
    );
    expect(out.strategy, DistillStrategy.offline);
    expect(out.fellBack, isFalse);
    expect(out.personaWritten, isTrue);
    expect(out.seedWritten, isTrue);
  });

  test('distillCapsule self path: idle+opt-in delivers to the live session',
      () async {
    final dir = draft();
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    var delivered = false;
    final out = await distillCapsule(
      agentKind: 'claude',
      headlessExe: 'claude',
      draftDir: dir,
      transcriptText: 't',
      sessionIdle: true,
      userWantsSelf: true,
      deliverToSession: (prompt) async {
        // Simulate the live session: step 1 writes persona, step 2 writes deps.
        delivered = true;
        File('$dir/persona.md').writeAsStringSync('SELF-PERSONA');
        File('$dir/deps.txt').writeAsStringSync('');
        return true;
      },
      runProc: (_, _, {stdin}) async => fail('self path must not go headless'),
      selfPoll: const Duration(milliseconds: 1),
      selfTimeout: const Duration(seconds: 2),
    );
    expect(delivered, isTrue);
    expect(out.strategy, DistillStrategy.selfDistill);
    expect(out.fellBack, isFalse);
    expect(File('$dir/persona.md').readAsStringSync(), 'SELF-PERSONA');
  });

  test('distillCapsule self timeout → falls back to headless offline', () async {
    final dir = draft();
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    final out = await distillCapsule(
      agentKind: 'claude',
      headlessExe: 'claude',
      draftDir: dir,
      transcriptText: 't',
      sessionIdle: true,
      userWantsSelf: true,
      // Delivered, but the session never writes the file → poll times out.
      deliverToSession: (_) async => true,
      runProc: fakeRunner(),
      selfPoll: const Duration(milliseconds: 2),
      selfTimeout: const Duration(milliseconds: 20),
    );
    expect(out.strategy, DistillStrategy.offline);
    expect(out.fellBack, isTrue);
    expect(File('$dir/persona.md').readAsStringSync(), 'PERSONA-BODY');
  });
}
