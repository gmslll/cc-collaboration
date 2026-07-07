import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_resolver.dart';

// Capsule "distill": turn a working session into two reusable artifacts —
//   persona.md : a distilled role (② the durable, reusable job definition)
//   seed.md    : a compacted context summary (opening prompt for "continue this")
// The hybrid policy (user's decision): when the source session is IDLE and the
// user opted in, ask the LIVE session to distill itself (it knows its own
// context best); otherwise run a HEADLESS one-shot agent over the neutral
// transcript. Either way the drafts land in a dir the user reviews/edits before
// the capsule is submitted.
//
// Process spawning and live-session delivery are injected (ProcRunner /
// deliverToSession) so the orchestration is unit-testable; the real adapters
// (systemProcRunner + the bus delivery) live in the wiring layer and get
// validated by running the app. File names match the Go reserved capsule
// constants (handoffschema.CapsulePersonaName / CapsuleSeedName).

const String _personaFileName = 'persona.md';
const String _seedFileName = 'seed.md';
const String depsFileName = 'deps.txt';
const String _doneMarker = 'CAPSULE_DISTILL_DONE';
const String _skillListDoneMarker = 'CAPSULE_SKILLS_DONE';

/// How a capsule's persona/seed get produced.
enum DistillStrategy { selfDistill, offline }

/// chooseDistillStrategy implements the hybrid policy: self-distill only when
/// the source session is idle AND the user opted into it; otherwise headless.
DistillStrategy chooseDistillStrategy({
  required bool sessionIdle,
  required bool userWantsSelf,
}) => (sessionIdle && userWantsSelf)
    ? DistillStrategy.selfDistill
    : DistillStrategy.offline;

/// ProcOutcome is the injected process runner's result.
class ProcOutcome {
  final int exitCode;
  final String stdout;
  final String stderr;
  const ProcOutcome(this.exitCode, this.stdout, this.stderr);
}

typedef ProcRunner =
    Future<ProcOutcome> Function(
      String exe,
      List<String> args, {
      String? stdin,
    });

/// systemProcRunner is the real ProcRunner (used by the wiring layer). Spawns
/// [exe] with [args], optionally piping [stdin], and collects stdout/stderr.
Future<ProcOutcome> systemProcRunner(
  String exe,
  List<String> args, {
  String? stdin,
}) async {
  // Inject a login-shell PATH so a node-shim agent (codex is `#!/usr/bin/env
  // node`) can find `node` — a GUI app's minimal PATH omits nvm/etc, which made
  // codex die instantly. Empty on Windows / probe failure → inherit parent env.
  final pathEnv = await AgentResolver.loginPath();
  // runInShell on Windows so a `.cmd`/`.bat` agent shim (what npm installs) can
  // actually launch — Process.start can't exec those directly. The prompt rides
  // on stdin (not argv), so cmd.exe never sees it to mangle. POSIX: no shell.
  final p = await Process.start(
    exe,
    args,
    runInShell: Platform.isWindows,
    environment: pathEnv.isEmpty ? null : {'PATH': pathEnv},
  );
  // Always close stdin (with EOF): `codex exec` peeks stdin and would otherwise
  // block waiting for it. Guarded — a fast-exiting proc may already be gone.
  try {
    if (stdin != null) p.stdin.write(stdin);
    await p.stdin.close();
  } catch (_) {}
  final out = await p.stdout.transform(utf8.decoder).join();
  final err = await p.stderr.transform(utf8.decoder).join();
  final code = await p.exitCode;
  return ProcOutcome(code, out, err);
}

/// DistillOutcome reports what happened so the caller can tell the user which
/// path ran and which artifacts to open for review.
class DistillOutcome {
  final DistillStrategy strategy;
  final bool personaWritten;
  final bool seedWritten;

  /// fellBack is true when self-distill was attempted but the live session
  /// didn't deliver in time, so we fell back to the headless path.
  final bool fellBack;

  const DistillOutcome({
    required this.strategy,
    required this.personaWritten,
    required this.seedWritten,
    this.fellBack = false,
  });
}

/// selfDistillPrompt asks the LIVE source session to distill itself into the two
/// draft files then print [_doneMarker]. It has repo + tool access, so it writes
/// the files directly.
String selfDistillPrompt({
  required String personaPath,
  required String seedPath,
}) =>
    '''你正在被「打成一个专职会话胶囊」。请把【当前这个会话】蒸馏成两份可复用的资产,用你的文件写入工具写出来:

1. 写 `$personaPath` —— 一个「专职角色」定义(给未来一个干净的新会话当 system 指令):
   - 这个会话专门在干的那类活是什么(一句话职责)
   - 必须遵守的规矩 / 约束 / 踩过的坑(要点列表)
   - 可复用的领域知识 / 约定 / 会用到的技能·脚本·命令
   不要写某次对话的流水账,要写「下次干这类活的人需要知道的、稳定可复用的东西」。
   **可移植性(重要)**:这份角色**可能在别人的机器上加载**,所以引用技能 / 脚本 / 工具时用**名字 + 用途**(如「用 `kunlun-customer-import` 技能导客户」),**不要写死某台机器的绝对路径**;确需路径时用相对仓库根的相对路径,并注明「按名字在本机环境里找」。

2. 写 `$seedPath` —— 一段压缩的上下文摘要(有人想「接着这个会话继续干」时当开场白):
   - 目标 / 已完成 / 待办 / 当前状态
   - 关键决策及其原因
   比 persona 更贴当前进度,但仍是摘要不是逐字。

两个文件都写完后,**只输出一行**:$_doneMarker''';

/// skillListPrompt is the SECOND self-distill step, delivered only after the
/// conversation is already saved (persona/seed written). It asks the same live
/// session to list the local skill/script dirs the work depends on, so they can
/// be bundled into the capsule for teammates who don't have them.
String skillListPrompt(String depsPath) =>
    '''刚才你已经把这个会话蒸馏成了角色(persona/seed 已保存)。现在**只做一件事**:把这活**依赖的、不在当前仓库里的本地技能/脚本目录**(比如 `~/.claude/skills/<某技能>`)的**绝对路径每行一个**写到 `$depsPath`;没有就写**空文件**。只列真正必需、且不在共享仓库里的——它们会被打包进胶囊,让没装该技能的队友也能直接用。写完后**只输出一行**:$_skillListDoneMarker''';

/// offlinePersonaPrompt drives a HEADLESS agent over [transcript]: distill the
/// conversation into the reusable role, emitting ONLY the persona markdown.
String offlinePersonaPrompt(String transcript) =>
    '''下面是一段会话的完整转录。把它蒸馏成一个可复用的「专职角色」定义(markdown),给未来一个干净的新会话当 system 指令:一句话职责 + 必须遵守的规矩/坑 + 可复用的领域知识/约定/会用到的技能·脚本·命令。**可移植性**:这份角色可能在别人的机器上加载,引用技能/脚本/工具时用**名字 + 用途**(如「用 kunlun-customer-import 技能」),**不要写死某台机器的绝对路径**。不要流水账,只要下次干这类活的人需要的、稳定可复用的东西。**只输出 persona 的 markdown 正文,不要任何前后缀说明。**

转录:
---
$transcript''';

/// offlineSeedPrompt drives a HEADLESS agent over [transcript]: compress it into
/// a context seed, emitting ONLY the summary markdown.
String offlineSeedPrompt(String transcript) =>
    '''下面是一段会话的完整转录。压缩成一段「上下文摘要」(markdown),当有人想接着这个会话继续干时当开场白:目标/已完成/待办/当前状态 + 关键决策及原因。是摘要不是逐字。**只输出摘要正文,不要任何前后缀说明。**

转录:
---
$transcript''';

/// distillCapsule runs the hybrid policy and writes persona.md / seed.md into
/// [draftDir] for the user to review before submit.
Future<DistillOutcome> distillCapsule({
  required String agentKind,
  required String headlessExe,
  required String draftDir,
  required String transcriptText,
  required bool sessionIdle,
  required bool userWantsSelf,
  required Future<bool> Function(String prompt) deliverToSession,
  required ProcRunner runProc,
  Duration selfTimeout = const Duration(minutes: 3),
  Duration selfPoll = const Duration(seconds: 2),
}) async {
  await Directory(draftDir).create(recursive: true);
  final personaFile = File('$draftDir/$_personaFileName');
  final seedFile = File('$draftDir/$_seedFileName');

  final strategy = chooseDistillStrategy(
    sessionIdle: sessionIdle,
    userWantsSelf: userWantsSelf,
  );

  if (strategy == DistillStrategy.selfDistill) {
    final ok = await _runSelfDistill(
      personaFile: personaFile,
      seedPath: seedFile.path,
      deliverToSession: deliverToSession,
      timeout: selfTimeout,
      poll: selfPoll,
    );
    if (ok) {
      // Conversation saved (persona/seed written) — now a focused SECOND ask:
      // have the same session list its skill/script deps into deps.txt.
      await _runSkillList(
        depsFile: File('$draftDir/$depsFileName'),
        deliverToSession: deliverToSession,
        poll: selfPoll,
      );
      return DistillOutcome(
        strategy: DistillStrategy.selfDistill,
        personaWritten: personaFile.existsSync(),
        seedWritten: seedFile.existsSync(),
      );
    }
    // The live session didn't deliver in time — fall through to headless so the
    // user still gets drafts to review.
  }

  await runOfflineDistill(
    agentKind: agentKind,
    headlessExe: headlessExe,
    draftDir: draftDir,
    transcriptText: transcriptText,
    runProc: runProc,
  );
  return DistillOutcome(
    strategy: DistillStrategy.offline,
    personaWritten: personaFile.existsSync(),
    seedWritten: seedFile.existsSync(),
    fellBack: strategy == DistillStrategy.selfDistill,
  );
}

// _runSelfDistill delivers the distill prompt to the live session, then polls
// for persona.md to appear (non-empty) within [timeout]. persona is the ②
// must-have; seed is best-effort and may or may not land.
// _deliverAndAwaitFile delivers [prompt] to the live session, then polls [ready]
// until true or [timeout]. The shared body of both self-distill steps. Returns
// false when delivery failed or the expected file never landed.
Future<bool> _deliverAndAwaitFile({
  required String prompt,
  required Future<bool> Function(String prompt) deliverToSession,
  required Future<bool> Function() ready,
  required Duration timeout,
  required Duration poll,
}) async {
  if (!await deliverToSession(prompt)) return false;
  final start = DateTime.now();
  while (DateTime.now().difference(start) < timeout) {
    if (await ready()) return true;
    await Future<void>.delayed(poll);
  }
  return false;
}

Future<bool> _runSelfDistill({
  required File personaFile,
  required String seedPath,
  required Future<bool> Function(String prompt) deliverToSession,
  required Duration timeout,
  required Duration poll,
}) => _deliverAndAwaitFile(
  prompt: selfDistillPrompt(personaPath: personaFile.path, seedPath: seedPath),
  deliverToSession: deliverToSession,
  ready: () async =>
      await personaFile.exists() && (await personaFile.length()) > 0,
  timeout: timeout,
  poll: poll,
);

// _runSkillList is the SECOND self-distill step, run only after the conversation
// is already saved: it asks the (now-idle) source session to list its skill /
// script deps into deps.txt, then waits briefly. Best-effort — a miss just
// means no skills are bundled.
Future<void> _runSkillList({
  required File depsFile,
  required Future<bool> Function(String prompt) deliverToSession,
  required Duration poll,
  Duration timeout = const Duration(seconds: 90),
}) async {
  await _deliverAndAwaitFile(
    prompt: skillListPrompt(depsFile.path),
    deliverToSession: deliverToSession,
    ready: depsFile.exists,
    timeout: timeout,
    poll: poll,
  );
}

/// runOfflineDistill produces the drafts with two headless one-shot calls (one
/// per artifact, so each output stays clean and bounded) over the neutral
/// transcript. The two calls are independent, so they run concurrently — the
/// interactive path's biggest wall-clock cost is these LLM round-trips. persona
/// is required; seed is best-effort. [headlessExe] is the resolved agent
/// executable (see AgentResolver — a bare name is unreliable under a GUI's
/// minimal PATH). Returns true when at least the persona was written.
Future<bool> runOfflineDistill({
  required String agentKind,
  required String headlessExe,
  required String draftDir,
  required String transcriptText,
  required ProcRunner runProc,
}) async {
  final results = await Future.wait([
    _oneShot(
      headlessExe,
      agentKind,
      offlinePersonaPrompt(transcriptText),
      runProc,
    ),
    _oneShot(
      headlessExe,
      agentKind,
      offlineSeedPrompt(transcriptText),
      runProc,
    ),
  ]);
  final persona = results[0];
  final seed = results[1];
  if (persona != null) {
    await File('$draftDir/$_personaFileName').writeAsString(persona);
  }
  if (seed != null) {
    await File('$draftDir/$_seedFileName').writeAsString(seed);
  }
  return persona != null;
}

// _oneShot runs a single headless prompt and returns trimmed stdout, or null on
// non-zero exit / empty output. The prompt (with the embedded transcript) is fed
// on STDIN, not as a CLI arg — so there's no ARG_MAX ceiling on big transcripts,
// and nothing for a Windows cmd.exe shim wrapper to mangle.
Future<String?> _oneShot(
  String exe,
  String agentKind,
  String prompt,
  ProcRunner runProc,
) async {
  final r = await runProc(exe, _headlessArgs(agentKind), stdin: prompt);
  if (r.exitCode != 0) return null;
  final out = r.stdout.trim();
  return out.isEmpty ? null : out;
}

// _headlessArgs is the non-interactive one-shot argument list for an agent kind
// (the executable is resolved by the caller via AgentResolver). The prompt is
// fed on STDIN, so it isn't in the args: `claude -p` reads stdin when given no
// prompt; `codex exec -` means read the prompt from stdin.
List<String> _headlessArgs(String agentKind) => agentKind == 'codex'
    // exec = non-interactive; read-only sandbox (distill only reads/answers, no
    // tool use); skip the git-repo check (draft dir may not be one); no color so
    // stdout stays clean markdown; `-` = read the prompt from stdin. codex prints
    // the final message to stdout, its session log to stderr.
    ? [
        'exec',
        '--skip-git-repo-check',
        '-s',
        'read-only',
        '--color',
        'never',
        '-',
      ]
    : ['-p'];
