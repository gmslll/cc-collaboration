import 'dart:io';

import '../api/models.dart';
import 'platform.dart';

// Shared knowledge of the local skill library + capsule "skill packs" — kept in
// local/ (no screens/ imports) like agent_transcript.dart, so the capture and
// load surfaces don't each re-encode where skills live / the pack format.
// The suffix mirrors the Go handoffschema.CapsuleSkillPackSuffix — keep in sync.
const String capsuleSkillPackSuffix = '.skillpack.zip';

// skillsDir is where Claude Code keeps user-level skills: ~/.claude/skills.
String skillsDir() => '${homeDir()}/.claude/skills';

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

// installSkillPack extracts a pack's [bytes] into the local skills dir and
// returns the installed skill name, or null on failure / non-macOS.
Future<String?> installSkillPack(List<int> bytes, String attachmentName) async {
  try {
    final root = await Directory(skillsDir()).create(recursive: true);
    final tmp = await Directory.systemTemp.createTemp('cap-skill-');
    final zip = File('${tmp.path}/$attachmentName');
    await zip.writeAsBytes(bytes);
    final r = await Process.run('/usr/bin/ditto', [
      '-x',
      '-k',
      zip.path,
      root.path,
    ]);
    return r.exitCode == 0 ? skillNameFromPack(attachmentName) : null;
  } catch (_) {
    return null;
  }
}
