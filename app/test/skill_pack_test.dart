import 'dart:io';

import 'package:app/local/skill_pack.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _zip(Iterable<ArchiveFile> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.addFile(entry);
  }
  return ZipEncoder().encode(archive);
}

List<int> _symlinkZip() {
  final link = ArchiveFile.string('review/link', '../../outside')
    ..mode = 0xa1ff;
  final bytes = _zip([link]);
  for (var i = 0; i + 5 < bytes.length; i++) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4b &&
        bytes[i + 2] == 0x01 &&
        bytes[i + 3] == 0x02) {
      bytes[i + 5] = 3; // UNIX creator: decoder honors the symlink mode bits.
      return bytes;
    }
  }
  throw StateError('zip central directory not found');
}

List<int> _zipWithFalseSmallSize() {
  final bytes = _zip([
    ArchiveFile.bytes('review/large.bin', List<int>.filled(1 << 20, 7)),
  ]);
  for (var i = 0; i + 27 < bytes.length; i++) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4b &&
        bytes[i + 2] == 0x01 &&
        bytes[i + 3] == 0x02) {
      bytes
        ..[i + 24] = 1
        ..[i + 25] = 0
        ..[i + 26] = 0
        ..[i + 27] = 0;
      return bytes;
    }
  }
  throw StateError('zip central directory not found');
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('skill-pack-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('installs one validated top-level skill without replacing it', () async {
    final first = _zip([
      ArchiveFile.string('review/SKILL.md', 'first'),
      ArchiveFile.string('review/scripts/run.sh', '#!/bin/sh\n'),
    ]);
    expect(
      await installSkillPack(
        first,
        'review.skillpack.zip',
        destinationRoot: root.path,
      ),
      'review',
    );
    expect(await File('${root.path}/review/SKILL.md').readAsString(), 'first');

    final replacement = _zip([
      ArchiveFile.string('review/SKILL.md', 'replaced'),
    ]);
    expect(
      await installSkillPack(
        replacement,
        'review.skillpack.zip',
        destinationRoot: root.path,
      ),
      'review',
    );
    expect(await File('${root.path}/review/SKILL.md').readAsString(), 'first');
  });

  test(
    'rejects traversal, extra roots, links and unsafe attachment names',
    () async {
      final cases = <(String, List<int>)>[
        (
          'review.skillpack.zip',
          _zip([ArchiveFile.string('../outside.txt', 'escape')]),
        ),
        (
          'review.skillpack.zip',
          _zip([ArchiveFile.string('other/SKILL.md', 'wrong root')]),
        ),
        ('review.skillpack.zip', _symlinkZip()),
        (
          '../review.skillpack.zip',
          _zip([ArchiveFile.string('review/SKILL.md', 'unsafe name')]),
        ),
        ('review.skillpack.zip', _zipWithFalseSmallSize()),
      ];
      for (final (name, bytes) in cases) {
        expect(
          await installSkillPack(bytes, name, destinationRoot: root.path),
          isNull,
          reason: name,
        );
      }
      expect(await File('${root.parent.path}/outside.txt').exists(), isFalse);
      expect(
        await root
            .list(followLinks: false)
            .where((entry) => entry.path.contains('.capsule-install-'))
            .isEmpty,
        isTrue,
      );
    },
  );
}
