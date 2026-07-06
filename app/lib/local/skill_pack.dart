import 'dart:io';

import 'platform.dart';

// Shared knowledge of the local skill library + capsule "skill packs" — kept in
// local/ (no screens/ imports) like agent_transcript.dart, so the capture and
// load surfaces don't each re-encode where skills live / the pack format.
// The suffix mirrors the Go handoffschema.CapsuleSkillPackSuffix — keep in sync.
const String capsuleSkillPackSuffix = '.skillpack.zip';

// skillsDir is where Claude Code keeps user-level skills: ~/.claude/skills.
String skillsDir() => '${homeDir()}/.claude/skills';

// skillNameFromPack strips the pack suffix to the bare skill name.
String skillNameFromPack(String attachmentName) =>
    attachmentName.endsWith(capsuleSkillPackSuffix)
        ? attachmentName.substring(
            0, attachmentName.length - capsuleSkillPackSuffix.length)
        : attachmentName;

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
    final r = await Process.run(
        '/usr/bin/ditto', ['-c', '-k', '--keepParent', dir, out]);
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
    final r =
        await Process.run('/usr/bin/ditto', ['-x', '-k', zip.path, root.path]);
    return r.exitCode == 0 ? skillNameFromPack(attachmentName) : null;
  } catch (_) {
    return null;
  }
}
