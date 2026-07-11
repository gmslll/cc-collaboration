import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../api/models.dart';
import 'platform.dart';

// Shared knowledge of the local skill library + capsule "skill packs" — kept in
// local/ (no screens/ imports) like agent_transcript.dart, so the capture and
// load surfaces don't each re-encode where skills live / the pack format.
// The suffix mirrors the Go handoffschema.CapsuleSkillPackSuffix — keep in sync.
const String capsuleSkillPackSuffix = '.skillpack.zip';
const int _maxSkillPackEntries = 512;
const int _maxSkillPackBytes = 64 << 20;
const int _maxSkillPackDepth = 32;

class _BoundedFileOutput extends OutputStream {
  final OutputFileStream _delegate;
  final int maxLength;
  int _length = 0;

  _BoundedFileOutput(String path, this.maxLength)
    : _delegate = OutputFileStream(path),
      super(byteOrder: ByteOrder.littleEndian);

  void _reserve(int count) {
    if (count < 0 || _length + count > maxLength) {
      throw ArchiveException('skill pack entry exceeds declared size');
    }
    _length += count;
  }

  @override
  int get length => _length;

  @override
  bool get isOpen => _delegate.isOpen;

  @override
  void writeByte(int value) {
    _reserve(1);
    _delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    _delegate.writeBytes(bytes, length: count);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    _delegate.writeStream(stream);
  }

  @override
  void flush() => _delegate.flush();

  @override
  Future<void> clear() => _delegate.clear();

  @override
  Future<void> close() => _delegate.close();

  @override
  void closeSync() => _delegate.closeSync();

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('file-backed output has no byte subset');
}

// skillsDir is where Claude Code keeps user-level skills: ~/.claude/skills.
String skillsDir() => '${homeDir()}/.claude/skills';

// skillsDirFor returns the user-level skills dir for a target tool. Claude and
// Codex both use the SKILL.md open standard but scan different dirs:
// Claude → ~/.claude/skills, Codex → ~/.codex/skills. A capsule's bundled skill
// must land in the dir the LOADED tool actually reads, not always Claude's.
String skillsDirFor(String tool) =>
    tool == 'codex' ? '${homeDir()}/.codex/skills' : skillsDir();

// skillsDirLabel is the tilde-form of skillsDirFor for display / prompts.
String skillsDirLabel(String tool) =>
    tool == 'codex' ? '~/.codex/skills' : '~/.claude/skills';

// listInstalledSkills returns the absolute paths of the user's installed skill
// dirs (~/.claude/skills/*), sorted — so the capture UI can always offer a
// "bundle a skill" picker even when distill produced no deps.txt.
Future<List<String>> listInstalledSkills() async {
  final root = Directory(skillsDir());
  if (!await root.exists()) return const [];
  final dirs = <String>[];
  await for (final e in root.list(followLinks: false)) {
    if (e is Directory) dirs.add(e.path);
  }
  dirs.sort();
  return dirs;
}

// skillNameFromPack strips the pack suffix to the bare skill name.
String skillNameFromPack(String attachmentName) =>
    attachmentName.endsWith(capsuleSkillPackSuffix)
    ? attachmentName.substring(
        0,
        attachmentName.length - capsuleSkillPackSuffix.length,
      )
    : attachmentName;

// isCapsuleSkillPack mirrors Go handoffschema.IsCapsuleSkillPack: is this
// attachment a bundled skill pack? The one predicate the read side uses.
bool isCapsuleSkillPack(String attachmentName) =>
    attachmentName.endsWith(capsuleSkillPackSuffix);

String? _safeSkillName(String attachmentName) {
  if (!isCapsuleSkillPack(attachmentName)) return null;
  final name = skillNameFromPack(attachmentName);
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.length > 128 ||
      name.contains(RegExp(r'[/\\\x00-\x1f\x7f]'))) {
    return null;
  }
  return name;
}

// skillPackNames is the single place the read side enumerates a capsule's
// bundled skills: the sorted bare names of its .skillpack.zip attachments.
List<String> skillPackNames(Iterable<Attachment> attachments) {
  final out = <String>[
    for (final a in attachments)
      if (isCapsuleSkillPack(a.name)) skillNameFromPack(a.name),
  ];
  out.sort();
  return out;
}

// packSkillDir zips a skill/script dir into [destDir]/<name>.skillpack.zip via
// an absolute /usr/bin/ditto (same tool + abs-path approach as update_service —
// a GUI's minimal PATH can't resolve a bare command). Returns the pack path, or
// null on failure / non-macOS.
Future<String?> packSkillDir(String dir, String destDir) async {
  final name = dir.replaceAll(RegExp(r'/+$'), '').split('/').last;
  if (_safeSkillName('$name$capsuleSkillPackSuffix') == null) return null;
  final out = '$destDir/$name$capsuleSkillPackSuffix';
  try {
    await File(out).delete();
  } catch (_) {}
  try {
    final r = await Process.run('/usr/bin/ditto', [
      '-c',
      '-k',
      '--keepParent',
      dir,
      out,
    ]);
    return r.exitCode == 0 ? out : null;
  } catch (_) {
    return null;
  }
}

// installSkillPack validates and extracts a pack into a private staging dir,
// then atomically installs its single top-level skill directory. It rejects
// traversal, links, devices, zip bombs and replacement of an existing skill.
Future<String?> installSkillPack(
  List<int> bytes,
  String attachmentName, {
  String tool = 'claude',
  String? destinationRoot,
}) async {
  final skillName = _safeSkillName(attachmentName);
  if (skillName == null || bytes.isEmpty) return null;
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } catch (_) {
    return null;
  }

  if (archive.isEmpty || archive.length > _maxSkillPackEntries) return null;
  final entries = <(ArchiveFile, List<String>)>[];
  var totalBytes = 0;
  var hasFile = false;
  for (final entry in archive) {
    final raw = entry.name.replaceAll('\\', '/');
    if (raw.isEmpty ||
        raw.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(raw) ||
        raw.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return null;
    }
    final parts = raw.split('/');
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    if (parts.isEmpty ||
        parts.length > _maxSkillPackDepth ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      return null;
    }
    // macOS zip metadata is never part of the installed skill.
    if (parts.first == '__MACOSX') continue;
    if (parts.first != skillName || entry.isSymbolicLink) return null;
    if (entry.isFile) {
      if (entry.size < 0 || entry.size > _maxSkillPackBytes - totalBytes) {
        return null;
      }
      totalBytes += entry.size;
      hasFile = true;
    } else if (!entry.isDirectory) {
      return null;
    }
    entries.add((entry, parts));
  }
  if (!hasFile || entries.isEmpty) return null;

  Directory? staging;
  try {
    final root = Directory(destinationRoot ?? skillsDirFor(tool));
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final target = Directory('${root.path}/$skillName');
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.directory) return skillName;
    if (targetType != FileSystemEntityType.notFound) return null;

    staging = await root.createTemp('.capsule-install-');
    for (final (entry, parts) in entries) {
      final path = '${staging.path}/${parts.join('/')}';
      if (entry.isDirectory) {
        await Directory(path).create(recursive: true);
        continue;
      }
      await File(path).parent.create(recursive: true);
      final output = _BoundedFileOutput(path, entry.size);
      try {
        entry.writeContent(output);
        output.closeSync();
      } catch (_) {
        output.closeSync();
        return null;
      }
      if (output.length != entry.size) return null;
      if (!Platform.isWindows && entry.unixPermissions & 0x49 != 0) {
        await Process.run('/bin/chmod', ['700', path]);
      }
    }
    final stagedSkill = Directory('${staging.path}/$skillName');
    if (!await stagedSkill.exists()) return null;
    try {
      await stagedSkill.rename(target.path);
    } on FileSystemException {
      if (await FileSystemEntity.type(target.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        return skillName;
      }
      return null;
    }
    return skillName;
  } catch (_) {
    return null;
  } finally {
    if (staging != null) {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
    }
  }
}
