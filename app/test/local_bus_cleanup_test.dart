import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/local/local_bus.dart';
import 'package:flutter_test/flutter_test.dart';

LocalBus _bus(Directory root, List<Map<String, dynamic>> Function() registry) =>
    LocalBus(
      busDirectory: root.path,
      registry: registry,
      deliver: (_) => 'unexpected deliver',
      readOutput: (_, _, _, _) async => 'unexpected read',
      readUsage: (_, _) async => 'unexpected usage',
      spawn: (_, _, _, _, _, _) async => 'unexpected spawn',
      kill: (_, _) => 'unexpected kill',
    );

Future<File> _writeAt(
  String path,
  DateTime modified, [
  String body = '{}',
]) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(body);
  await file.setLastModified(modified);
  return file;
}

Future<void> _writeSessionArtifacts(
  Directory root,
  String sid,
  DateTime modified,
) async {
  await _writeAt('${root.path}/events/$sid/0001-Hook.json', modified);
  await _writeAt('${root.path}/sessions/$sid.json', modified);
}

void main() {
  late Directory root;
  late List<Map<String, dynamic>> live;
  late LocalBus bus;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cc-local-bus-cleanup-');
    live = <Map<String, dynamic>>[];
    bus = _bus(root, () => live);
  });

  tearDown(() async {
    bus.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('active registry and sessions.json sids are always protected', () async {
    final old = DateTime(2026, 6, 1);
    await _writeSessionArtifacts(root, 'ts-live', old);
    await _writeSessionArtifacts(root, 'ts-disk', old);
    live.add({'id': 'ts-live'});
    await File('${root.path}/sessions.json').writeAsString(
      jsonEncode([
        {'id': 'ts-disk'},
      ]),
    );

    expect(await bus.cleanupSessionArtifacts('ts-live'), isFalse);
    expect(await bus.cleanupSessionArtifacts('ts-disk'), isFalse);
    expect(Directory('${root.path}/events/ts-live').existsSync(), isTrue);
    expect(Directory('${root.path}/events/ts-disk').existsSync(), isTrue);
    expect(File('${root.path}/sessions/ts-live.json').existsSync(), isTrue);
    expect(File('${root.path}/sessions/ts-disk.json').existsSync(), isTrue);
  });

  test('secondary TerminalHost registry also protects a live sid', () async {
    final now = DateTime(2026, 7, 10, 12);
    await _writeSessionArtifacts(
      root,
      'ts-secondary-live',
      now.subtract(const Duration(days: 30)),
    );
    final secondary = LocalBus.artifactCleanup(
      busDirectory: root.path,
      registry: () => [
        {'id': 'ts-secondary-live'},
      ],
    );
    addTearDown(secondary.dispose);

    await bus.pruneOrphanArtifacts(now: now);

    expect(
      Directory('${root.path}/events/ts-secondary-live').existsSync(),
      isTrue,
    );
    secondary.dispose();
    await bus.pruneOrphanArtifacts(now: now);
    expect(
      Directory('${root.path}/events/ts-secondary-live').existsSync(),
      isFalse,
    );
  });

  test('explicit close removes events, mapping, and an empty inbox', () async {
    final old = DateTime(2026, 6, 1);
    await _writeSessionArtifacts(root, 'ts-close', old);
    await Directory('${root.path}/inbox/ts-close').create(recursive: true);
    live.add({'id': 'ts-close'});
    await bus.start();

    live.clear(); // TerminalHost removed the session before firing onTermClosed.
    expect(await bus.cleanupSessionArtifacts('ts-close'), isTrue);

    expect(Directory('${root.path}/events/ts-close').existsSync(), isFalse);
    expect(File('${root.path}/sessions/ts-close.json').existsSync(), isFalse);
    expect(Directory('${root.path}/inbox/ts-close').existsSync(), isFalse);
    expect(
      jsonDecode(await File('${root.path}/sessions.json').readAsString()),
      [],
    );
  });

  test('explicit close preserves a non-empty inbox', () async {
    final old = DateTime(2026, 6, 1);
    await _writeSessionArtifacts(root, 'ts-close-pending', old);
    final message = await _writeAt(
      '${root.path}/inbox/ts-close-pending/0001.json',
      old,
      '{"body":"deliver me"}',
    );

    expect(await bus.cleanupSessionArtifacts('ts-close-pending'), isTrue);

    expect(
      Directory('${root.path}/events/ts-close-pending').existsSync(),
      isFalse,
    );
    expect(
      File('${root.path}/sessions/ts-close-pending.json').existsSync(),
      isFalse,
    );
    expect(message.existsSync(), isTrue);
  });

  test('a message racing empty-inbox cleanup is never deleted', () async {
    final inbox = await Directory(
      '${root.path}/inbox/ts-racing-message',
    ).create(recursive: true);
    final cleanup = bus.cleanupSessionArtifacts('ts-racing-message');
    // Mirror the production writer: ensure the directory, publish tmp, rename.
    final publish = () async {
      await inbox.create(recursive: true);
      final tmp = File('${inbox.path}/0001.json.tmp');
      await tmp.writeAsString('{"body":"do not lose"}');
      await tmp.rename('${inbox.path}/0001.json');
    }();

    await Future.wait([cleanup, publish]);

    expect(File('${inbox.path}/0001.json').existsSync(), isTrue);
  });

  test(
    'lock-only inbox is removed only after the drain lock is stale',
    () async {
      final freshDir = await Directory(
        '${root.path}/inbox/ts-fresh-lock',
      ).create(recursive: true);
      await File('${freshDir.path}/.lock').writeAsString('');
      final staleDir = await Directory(
        '${root.path}/inbox/ts-stale-lock',
      ).create(recursive: true);
      final staleLock = await File('${staleDir.path}/.lock').writeAsString('');
      await staleLock.setLastModified(
        DateTime.now().subtract(const Duration(minutes: 1)),
      );

      await bus.cleanupSessionArtifacts('ts-fresh-lock');
      await bus.cleanupSessionArtifacts('ts-stale-lock');

      expect(freshDir.existsSync(), isTrue);
      expect(staleDir.existsSync(), isFalse);
    },
  );

  test('an orphan exactly seven days old is retained', () async {
    final now = DateTime(2026, 7, 10, 12);
    await _writeSessionArtifacts(
      root,
      'ts-threshold',
      now.subtract(LocalBus.orphanTtl),
    );

    await bus.pruneOrphanArtifacts(now: now);

    expect(Directory('${root.path}/events/ts-threshold').existsSync(), isTrue);
    expect(
      File('${root.path}/sessions/ts-threshold.json').existsSync(),
      isTrue,
    );
  });

  test('a fresh orphan is retained', () async {
    final now = DateTime(2026, 7, 10, 12);
    await _writeSessionArtifacts(
      root,
      'ts-fresh',
      now.subtract(const Duration(days: 6)),
    );

    await bus.pruneOrphanArtifacts(now: now);

    expect(Directory('${root.path}/events/ts-fresh').existsSync(), isTrue);
    expect(File('${root.path}/sessions/ts-fresh.json').existsSync(), isTrue);
  });

  test('an orphan older than seven days is deleted', () async {
    final now = DateTime(2026, 7, 10, 12);
    await _writeSessionArtifacts(
      root,
      'ts-expired',
      now.subtract(const Duration(days: 8)),
    );

    await bus.pruneOrphanArtifacts(now: now);

    expect(Directory('${root.path}/events/ts-expired').existsSync(), isFalse);
    expect(File('${root.path}/sessions/ts-expired.json').existsSync(), isFalse);
  });

  test(
    'expired events and mapping are deleted but a non-empty inbox remains',
    () async {
      final now = DateTime(2026, 7, 10, 12);
      final old = now.subtract(const Duration(days: 8));
      await _writeSessionArtifacts(root, 'ts-pending', old);
      final message = await _writeAt(
        '${root.path}/inbox/ts-pending/0001.json',
        old,
        '{"body":"still pending"}',
      );

      await bus.pruneOrphanArtifacts(now: now);

      expect(Directory('${root.path}/events/ts-pending').existsSync(), isFalse);
      expect(
        File('${root.path}/sessions/ts-pending.json').existsSync(),
        isFalse,
      );
      expect(message.existsSync(), isTrue);
      expect(Directory('${root.path}/inbox/ts-pending').existsSync(), isTrue);
    },
  );

  test('an empty inbox is deleted with expired orphan cache', () async {
    final now = DateTime(2026, 7, 10, 12);
    await _writeSessionArtifacts(
      root,
      'ts-empty',
      now.subtract(const Duration(days: 8)),
    );
    await Directory('${root.path}/inbox/ts-empty').create(recursive: true);

    await bus.pruneOrphanArtifacts(now: now);

    expect(Directory('${root.path}/inbox/ts-empty').existsSync(), isFalse);
  });

  test('malicious sid is rejected before path construction', () async {
    final victim = await Directory('${root.path}-victim').create();
    final victimName = victim.path.split(Platform.pathSeparator).last;
    addTearDown(() async {
      if (await victim.exists()) await victim.delete(recursive: true);
    });
    final sentinel = await File(
      '${victim.path}/keep.txt',
    ).writeAsString('keep');

    expect(await bus.cleanupSessionArtifacts('../$victimName'), isFalse);
    expect(
      await bus.cleanupSessionArtifacts('ts1/../../victim-artifacts'),
      isFalse,
    );
    expect(await bus.cleanupSessionArtifacts(victim.path), isFalse);
    expect(sentinel.existsSync(), isTrue);
  });

  test('startup protects restored tabs before pruning old cache', () async {
    final old = DateTime.now().subtract(const Duration(days: 30));
    await _writeSessionArtifacts(root, 'ts-restored', old);
    // This models restoreTerms having rebuilt `terms` before LocalBus.start.
    live.add({'id': 'ts-restored', 'label': 'restored tab'});

    await bus.start();

    expect(Directory('${root.path}/events/ts-restored').existsSync(), isTrue);
    expect(File('${root.path}/sessions/ts-restored.json').existsSync(), isTrue);
    final registry =
        jsonDecode(await File('${root.path}/sessions.json').readAsString())
            as List<dynamic>;
    expect(registry.single['id'], 'ts-restored');
  });

  test('a sid restored while close cleanup waits is protected', () async {
    final old = DateTime.now().subtract(const Duration(days: 30));
    await _writeSessionArtifacts(root, 'ts-close-restore', old);
    live.add({'id': 'ts-close-restore'});
    await bus.start();

    live.clear();
    final cleanup = bus.cleanupSessionArtifacts('ts-close-restore');
    // restoreTerms/addTerm can reintroduce the stable sid while the close
    // callback is waiting for its queued registry write.
    live.add({'id': 'ts-close-restore'});
    await bus.syncRegistry();

    expect(await cleanup, isFalse);
    expect(
      Directory('${root.path}/events/ts-close-restore').existsSync(),
      isTrue,
    );
    expect(
      File('${root.path}/sessions/ts-close-restore.json').existsSync(),
      isTrue,
    );
  });

  test(
    'dispose cancels an in-flight maintenance pass before deletion',
    () async {
      final now = DateTime(2026, 7, 10, 12);
      final old = now.subtract(const Duration(days: 8));
      await _writeSessionArtifacts(root, 'ts-disposed-pass', old);
      live.add({'id': 'ts-disposed-pass'});
      await bus.start();
      live.clear();
      final receipt = await _writeAt('${root.path}/outbox/stale.ok', old);

      final maintenance = bus.runMaintenance(now: now);
      bus.dispose();
      await maintenance;

      expect(
        Directory('${root.path}/events/ts-disposed-pass').existsSync(),
        isTrue,
      );
      expect(
        File('${root.path}/sessions/ts-disposed-pass.json').existsSync(),
        isTrue,
      );
      expect(receipt.existsSync(), isTrue);
      final markers = await Directory(
        '${root.path}/instances',
      ).list(followLinks: false).where((entity) => entity is File).toList();
      expect(markers, isEmpty);
    },
  );

  test('dispose then restart keeps only the new lifecycle marker', () async {
    live.add({'id': 'ts-restarted-owner'});
    await bus.start();

    final oldPass = bus.runMaintenance();
    bus.dispose();
    await bus.start();
    await oldPass;

    final markers = await Directory(
      '${root.path}/instances',
    ).list(followLinks: false).where((entity) => entity is File).toList();
    expect(markers, hasLength(1));
    expect(await bus.cleanupSessionArtifacts('ts-restarted-owner'), isFalse);
    final registry =
        jsonDecode(await File('${root.path}/sessions.json').readAsString())
            as List<dynamic>;
    expect(registry.map((e) => e['id']), ['ts-restarted-owner']);
  });

  test('disposed registry writes cannot overwrite the next instance', () async {
    final firstLive = <Map<String, dynamic>>[
      {'id': 'ts-old-owner'},
    ];
    final first = _bus(root, () => firstLive);
    final secondLive = <Map<String, dynamic>>[
      {'id': 'ts-new-owner'},
    ];
    final second = _bus(root, () => secondLive);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.start();

    final staleWrites = <Future<void>>[];
    for (var i = 0; i < 100; i++) {
      firstLive.single['label'] = 'stale-$i';
      staleWrites.add(first.syncRegistry());
    }
    first.dispose();
    await second.start();
    await Future.wait(staleWrites);

    final registry =
        jsonDecode(await File('${root.path}/sessions.json').readAsString())
            as List<dynamic>;
    expect(registry.map((e) => e['id']), ['ts-new-owner']);
    final tempFiles = await root
        .list()
        .where(
          (e) => e.path.contains('sessions.json.') && e.path.endsWith('.tmp'),
        )
        .toList();
    expect(tempFiles, isEmpty);
  });

  test('a fresh competing-process marker disables artifact deletion', () async {
    final old = DateTime.now().subtract(const Duration(days: 8));
    await _writeSessionArtifacts(root, 'ts-peer-owned', old);
    final receipt = await _writeAt('${root.path}/outbox/peer.ok', old);
    final marker = await _writeAt(
      '${root.path}/instances/${pid + 1}-peer-instance',
      DateTime.now(),
      'peer',
    );
    await bus.start();

    expect(await bus.cleanupSessionArtifacts('ts-peer-owned'), isFalse);
    await bus.runMaintenance();

    expect(marker.existsSync(), isTrue);
    expect(Directory('${root.path}/events/ts-peer-owned').existsSync(), isTrue);
    expect(
      File('${root.path}/sessions/ts-peer-owned.json').existsSync(),
      isTrue,
    );
    expect(receipt.existsSync(), isTrue);
  });

  test('a crashed peer marker ages out after the safety window', () async {
    final old = DateTime.now().subtract(const Duration(days: 8));
    await _writeSessionArtifacts(root, 'ts-stale-peer', old);
    await _writeAt(
      '${root.path}/instances/${pid + 1}-stale-peer',
      old,
      'stale peer',
    );

    expect(await bus.cleanupSessionArtifacts('ts-stale-peer'), isTrue);
    expect(
      Directory('${root.path}/events/ts-stale-peer').existsSync(),
      isFalse,
    );
  });

  test('an untrusted instances symlink makes cleanup fail closed', () async {
    final old = DateTime.now().subtract(const Duration(days: 8));
    await _writeSessionArtifacts(root, 'ts-instance-link', old);
    final external = await Directory('${root.path}-instances').create();
    addTearDown(() async {
      if (await external.exists()) await external.delete(recursive: true);
    });
    await Link('${root.path}/instances').create(external.path);

    expect(await bus.cleanupSessionArtifacts('ts-instance-link'), isFalse);
    expect(
      Directory('${root.path}/events/ts-instance-link').existsSync(),
      isTrue,
    );
  });

  test(
    'session artifact symlinks never delete their external targets',
    () async {
      final victim = await Directory('${root.path}-symlink-victim').create();
      addTearDown(() async {
        if (await victim.exists()) await victim.delete(recursive: true);
      });
      final sentinel = await File(
        '${victim.path}/keep.txt',
      ).writeAsString('keep');
      await Directory('${root.path}/events').create(recursive: true);
      await Link('${root.path}/events/ts-linked-root').create(victim.path);
      final nested = await Directory(
        '${root.path}/events/ts-linked-child',
      ).create(recursive: true);
      await Link('${nested.path}/outside').create(victim.path);

      await bus.cleanupSessionArtifacts('ts-linked-root');
      await bus.cleanupSessionArtifacts('ts-linked-child');

      expect(sentinel.existsSync(), isTrue);
      expect(victim.existsSync(), isTrue);
    },
  );

  test('maintenance removes only stale inactive outbox receipts', () async {
    final now = DateTime(2026, 7, 10, 12);
    final old = now.subtract(const Duration(days: 8));
    final outbox = await Directory(
      '${root.path}/outbox',
    ).create(recursive: true);
    final stale = <File>[
      await _writeAt('${outbox.path}/done.ok', old),
      await _writeAt('${outbox.path}/failed.err', old),
      await _writeAt('${outbox.path}/claimed.taken', old),
      await _writeAt('${outbox.path}/.publish.tmp', old),
      await _writeAt('${outbox.path}/snapshot.ok.tmp', old),
    ];
    final fresh = await _writeAt(
      '${outbox.path}/fresh.ok',
      now.subtract(const Duration(days: 1)),
    );
    final threshold = await _writeAt(
      '${outbox.path}/threshold.ok',
      now.subtract(LocalBus.orphanTtl),
    );
    final activeReceipt = await _writeAt('${outbox.path}/active.ok', old);
    final activeRequest = await _writeAt('${outbox.path}/active.json', old);
    final staleRegistryTemp = await _writeAt(
      '${root.path}/sessions.json.999-old.tmp',
      old,
    );
    final thresholdRegistryTemp = await _writeAt(
      '${root.path}/sessions.json.threshold.tmp',
      now.subtract(LocalBus.orphanTtl),
    );

    await bus.runMaintenance(now: now);

    for (final file in stale) {
      expect(
        file.existsSync(),
        isFalse,
        reason: '${file.path} should be stale',
      );
    }
    expect(fresh.existsSync(), isTrue);
    expect(threshold.existsSync(), isTrue);
    expect(activeReceipt.existsSync(), isTrue);
    expect(activeRequest.existsSync(), isTrue);
    expect(staleRegistryTemp.existsSync(), isFalse);
    expect(thresholdRegistryTemp.existsSync(), isTrue);
  });

  test(
    'maintenance preserves an old .taken while its request is processing',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final processingBus = LocalBus(
        busDirectory: root.path,
        registry: () => const [],
        deliver: (_) => 'unexpected deliver',
        readOutput: (_, _, _, out) async {
          entered.complete();
          await release.future;
          out.write('done');
          return null;
        },
        readUsage: (_, _) async => 'unexpected usage',
        spawn: (_, _, _, _, _, _) async => 'unexpected spawn',
        kill: (_, _) => 'unexpected kill',
      );
      addTearDown(processingBus.dispose);
      await processingBus.start();
      final outbox = Directory('${root.path}/outbox');
      const requestId = 'processing-request';
      await File(
        '${outbox.path}/$requestId.json',
      ).writeAsString(jsonEncode({'kind': 'read', 'to': 'ts0'}));
      await entered.future;
      final taken = File('${outbox.path}/$requestId.taken');
      expect(taken.existsSync(), isTrue);
      final now = DateTime.now();
      await taken.setLastModified(now.subtract(const Duration(days: 8)));

      await processingBus.runMaintenance(now: now);

      expect(taken.existsSync(), isTrue);
      release.complete();
      final receipt = File('${outbox.path}/$requestId.ok');
      for (var i = 0; i < 100 && !receipt.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(receipt.existsSync(), isTrue);
    },
  );

  test('Workspace restores terms before starting LocalBus cleanup', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final helperStart = source.indexOf(
      'Future<void> _restoreTermsThenStartLocalBus()',
    );
    final helperEnd = source.indexOf('\n  @override', helperStart);
    final helper = source.substring(helperStart, helperEnd);

    expect(helperStart, greaterThanOrEqualTo(0));
    expect(helper.indexOf('await restoreTerms();'), greaterThanOrEqualTo(0));
    expect(
      helper.indexOf('await _localBus.start();'),
      greaterThan(helper.indexOf('await restoreTerms();')),
    );
    expect(source, contains('onTermClosed = (sid)'));
    expect(
      source,
      contains('unawaited(_localBus.cleanupSessionArtifacts(sid));'),
    );
    final handoffs = File('lib/screens/handoffs_page.dart').readAsStringSync();
    expect(handoffs, contains('LocalBus.artifactCleanup('));
    expect(
      handoffs,
      contains('unawaited(_localBusArtifacts.cleanupSessionArtifacts(sid));'),
    );
  });
}
