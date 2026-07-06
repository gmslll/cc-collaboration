import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

import '../local/agent_resolver.dart';
import '../local/agent_transcript.dart';
import '../local/agent_usage.dart';
import '../local/cli.dart';
import '../local/crash_log.dart';
import '../local/local_bus.dart';
import '../local/path_utils.dart';
import '../local/platform.dart';
import '../local/shell.dart';
import '../ghostty_shadow.dart';
import '../terminal_snapshot_formatter.dart';
import '../terminal_theme.dart';
import '../terminal_mouse.dart';
import '../widgets.dart';

// TerminalSession owns a PTY + xterm Terminal model. The cockpit keeps a list of
// these (one per pickup/worktree) for multi-session tabs and can sendText into
// the active one (e.g. paste the materialized prompt).
class TerminalSession {
  static const String _startupMsgInstructions =
      'When the user asks you to coordinate with another local project/session '
      'or another AI agent, use the local cc-handoff message bus: run '
      '`cc-handoff msg list` to find sessions, `cc-handoff msg send <target> '
      '<message>` to talk to one, and `cc-handoff msg read <target>` to read '
      'its terminal. Prefer session IDs like ts2 when names are ambiguous.';

  static const String _supervisorInstructions =
      'You are the supervisor AI for this workspace. Your job is to oversee '
      'the other local AI sessions, review sessions that need confirmation, '
      'resolve disagreements using the PRD and project knowledge, and ask the '
      'user before high-risk actions. Use `cc-handoff supervisor overview` to '
      'inspect sessions, `cc-handoff supervisor queue` to find sessions needing '
      'attention, `cc-handoff supervisor read <target>` to read a structured '
      'transcript, `cc-handoff supervisor send <target> <message>` to respond, '
      '`cc-handoff supervisor context` to read .cc-handoff/supervisor docs, '
      '`cc-handoff supervisor spawn <project> [--worktree PATH] [--agent '
      'claude|codex|shell] [--supervisor]` to open a managed child session '
      '(it joins the session tree and the bus, equivalent to right-clicking a '
      'project to launch it — do NOT use `open --window`, which spawns a '
      'detached terminal outside the app that never registers on the bus), '
      '`cc-handoff supervisor kill <target>` to close a session, '
      'and `cc-handoff supervisor decide <title> <decision>` to record product '
      'or architecture decisions.';

  static const String _todoInstructions =
      'You are the 待办助手 (todo assistant) for this workspace. Help the user '
      'turn ideas, requirements and conversations into todo cards, and keep the '
      'board tidy — set status, assign, comment, group, and split work into '
      'subtasks. Operate on the shared todo relay with the `cc-handoff todo` CLI; '
      'changes sync live to the desktop board and the user\'s phone. Commands: '
      '`cc-handoff todo list [--scope personal|project|assigned|all] [--project '
      'ID] [--status S] [--json]` to inspect the board, `cc-handoff todo create '
      '<title> [--body TEXT] [--project ID] [--priority low|normal|high] [--due '
      'RFC3339] [--assignee IDENTITY] [--group NAME]` to add one (omit --project '
      'for a personal todo, or pass the team Project ID so the whole team and '
      'their phones can see it), `cc-handoff todo get <id> [--json]`, '
      '`cc-handoff todo status <id> <triage|backlog|todo|in_progress|in_review|'
      'done|canceled|duplicate>`, `cc-handoff todo assign <id> <identity>` (or '
      '`--unassign`), and `cc-handoff todo comment <id> <body>`. Pass --json when '
      'you need to read fields back. Confirm with the user before bulk changes or '
      'before canceling/deleting existing work.';

  static String _argQuote(String value) =>
      Platform.isWindows ? '"${value.replaceAll('"', r'\"')}"' : shQuote(value);

  String _startupInstructions() {
    if (supervisor) return '$_startupMsgInstructions $_supervisorInstructions';
    if (todoAssistant) return '$_startupMsgInstructions $_todoInstructions';
    return _startupMsgInstructions;
  }

  String _codexDeveloperInstructionsConfig() =>
      'developer_instructions=${_startupInstructions()}';

  static int _seq = 0;
  // Stable id used for remote addressing (the phone's term.open/input target) and
  // the local bus. PERSISTED + restored so it survives a desktop restart —
  // otherwise a restart re-mints ids and a phone holding the old id mirrors a
  // blank terminal forever (its term.open targets a session that no longer
  // exists). New sessions mint 'ts<N>'; restored ones pass their saved id.
  final String id;
  // reserveId advances the mint counter past a restored id so a freshly minted
  // 'ts<N>' never collides with a persisted one within the same run.
  static void reserveId(String id) {
    if (!id.startsWith('ts')) return;
    final n = int.tryParse(id.substring(2));
    if (n != null && n >= _seq) _seq = n + 1;
  }

  final String workdir;
  final String command;
  final String title;
  String? name; // user-given label; overrides the derived title when set
  // --- AI-session binding (resume the same conversation after an app restart) -
  // agent is the explicit kind ('claude'/'codex'/'' for shell/raw) — set by the
  // launcher, not sniffed. preLaunch is the shell run before the agent (e.g.
  // 'clset 6'). For claude we mint a fixed [agentSessionId] (uuid) at first
  // launch and pass it via --session-id, then --resume it next time so the tab
  // reopens the exact same conversation. codex can't pre-assign an id, so it
  // resumes the cwd's most-recent rollout instead (see _resolvedCommand). resume
  // is true only when this session is being reopened from persistence.
  final String agent;
  final String preLaunch;
  final bool supervisor;
  // todoAssistant injects the 待办助手 persona (see _todoInstructions) the same
  // way [supervisor] injects the supervisor one — a session spawned from the
  // Todo page to generate/manage todos via the `cc-handoff todo` CLI.
  final bool todoAssistant;
  // Mutable: claude gets a fixed id at construction; codex can't be given one at
  // launch, so it's captured from codex's rollout file after start (see
  // _maybeCaptureCodexId) and then persisted.
  String? agentSessionId;
  final bool resume;
  final Terminal terminal = ccTerminal(maxLines: 10000);
  final GhosttyShadowTerminal? ghostty;
  // The selection/copy controller lives on the session (not the pane) so the
  // host can read the current selection — e.g. to forward it to another session.
  //
  // pointerInputs: none() stops the controller forwarding mouse clicks into the
  // PTY. A full-screen TUI (claude/codex) otherwise eats left/right clicks, so
  // GUI text selection never registers (the "发送选区" menu stays grey), the
  // right-click context menu never opens, and a press-without-release wedges the
  // TUI ("卡死"). With clicks kept GUI-side, drag = pure selection and right-tap
  // = our menu — and wheel scroll is unaffected (it goes through a separate path
  // that doesn't consult pointerInputs). Focus-on-click still works (onTapDown
  // fires regardless). Trade-off: clicks no longer reach the TUI (keyboard- and
  // wheel-driven, so fine for claude/codex; shells never had mouse mode anyway).
  final TerminalController controller = TerminalController(
    pointerInputs: const PointerInputs.none(),
  );
  Pty? _pty;
  bool _started = false;
  bool _disposed = false;
  // deferred = restored but its PTY must NOT auto-start when its pane mounts — it
  // starts only once the session becomes active (the user opens its tab/tree node).
  // Set by restoreTerms for hidden (closed-to-tree) sessions and cleared on
  // activation, so a restart brings sessions back without spawning every agent at
  // once. New sessions (addTerm) leave this false and start eagerly as before.
  bool deferred = false;
  // started exposes _started so the tree can dim a not-yet-loaded (deferred) session.
  bool get started => _started;
  @visibleForTesting
  ({int rows, int cols})? get debugRemoteSize => _remoteSize;
  // Resolved agent launch token (abs path / user override / bare name), set in
  // _startAsync before the PTY spawns. Null until resolved (non-agent sessions
  // leave it null and _resolvedCommand ignores it).
  String? _invocation;

  // remoteSink, when set, also receives this terminal's (utf8-decoded) PTY
  // output so a remote phone client can mirror it. Null when nobody's watching.
  void Function(String chunk)? remoteSink;
  ({int rows, int cols})? _remoteSize;

  // --- "agent finished a turn" detection (bell-only) ----------------------
  //
  // claude/codex ring the terminal bell (BEL \x07) exactly when they stop and
  // wait for you — finished a turn, or blocked on a permission/input prompt —
  // and NOT while working. So a bell, confirmed by output then going quiet, is
  // what we fire [onDone] on (→ a "会话完成" notification). There is no idle/
  // timeout heuristic: mid-turn pauses (between streamed chunks, tool calls,
  // thinking) don't bell, so they never notify. Only for isAgent sessions, and
  // only after the user has actually given the agent something to do (_sawInput)
  // so the initial idle prompt doesn't ping. Trade-off: an agent with the
  // terminal bell disabled won't notify.
  void Function(TerminalSession session)? onDone;
  // onPersist asks the host to re-save the session list — fired after a codex
  // session id is captured so a reopened tab can resume the exact conversation.
  void Function()? onPersist;
  // onBusyChanged fires whenever the agent's busy state flips (turn start /
  // finish) — a host with a session-overview projection (the workspace) sets it
  // to republish the snapshot so "思考中"/"待 review" stay live. Routed through
  // _setBusy so every busy transition (local input, remote input, finishing
  // bell) emits exactly once.
  void Function(TerminalSession session)? onBusyChanged;
  // activityRev bumps on every activity-state transition (busy start/finish,
  // needsReview set/clear) so a lightweight ValueListenableBuilder — the workspace
  // session-tree avatar — can rebuild its live status glyph without the whole
  // workspace calling setState per turn. It's a revision counter, not the state
  // itself: the listener re-reads busy/needsReview/status on each bump.
  final ValueNotifier<int> activityRev = ValueNotifier(0);
  void _bumpActivity() {
    if (!_disposed) activityRev.value++;
  }

  // needsReview = this agent finished a user-kicked turn and hasn't been opened
  // since (set in _fireDone, cleared by the workspace when the session is made
  // active / watched remotely / previewed in the overview). Drives the overview's
  // and the tree avatar's "待 review" highlight — a notifying setter so those
  // views update the instant it flips.
  bool _needsReview = false;
  bool get needsReview => _needsReview;
  set needsReview(bool v) {
    if (_needsReview == v) return;
    _needsReview = v;
    _bumpActivity();
  }

  // overviewPreview caches the last computed glance preview (agent transcript
  // tail / terminal tail) so each overview broadcast reuses it instead of
  // re-reading the log. Refreshed by the workspace on turn boundaries.
  String? overviewPreview;
  Timer? _belTimer;
  // Ticks refreshUsage() every few seconds while the agent is mid-turn so the
  // usage chip climbs as tool-round messages land in the transcript, not just at
  // turn start/finish. Lives only for the busy window (started/stopped in
  // _setBusy); incremental scan keeps each tick cheap.
  Timer? _usageTicker;
  bool _belArmed =
      false; // a bell rang; waiting for output to settle to confirm
  bool _sawInput = false; // user has typed/sent into this session at least once
  // _busy = this agent is mid-turn (we submitted input; no finishing bell yet).
  // Read via [busy], which ANDs isAgent so it's only ever meaningful for agent
  // sessions. Drives local-bus delivery: a busy agent's incoming peer message is
  // parked in its bus inbox for its Stop hook to inject as a continuation turn,
  // instead of pasting (which would just queue behind the running turn). Set
  // when a turn starts (a submit \r reaches an agent), cleared on the finishing
  // bell (_fireDone).
  bool _busy = false;
  bool get busy => isAgent && _busy;

  // _inputDirty = the user has typed into this session's input row since their
  // last submit (Enter). Read via [inputDirty] (ANDs isAgent, like busy). Drives
  // local-bus delivery: when an idle agent's input row is dirty, an incoming peer
  // message is parked in its bus inbox (hook-injected as a clean turn) instead of
  // pasted — so it can't overwrite what the user is mid-typing (the paste and the
  // user's keystrokes would otherwise race on the same input line, and the user's
  // Enter submits whichever text won, dropping the other). Set by markUserInput on
  // real keyboard/IME input; cleared when that input is a submit (CR). App-driven
  // pasteText/sendText bypass markUserInput, so a delivery never self-dirties.
  bool _inputDirty = false;
  bool get inputDirty => isAgent && _inputDirty;

  // --- delivery readiness: dispatch a bus message to ANY target session -------
  //
  // A bus delivery must land + auto-submit + start a turn on the target regardless
  // of whether its tab is visible, focused, or freshly launched — dispatch is
  // decoupled from the UI, no manual Enter. The hazard is the target's PTY:
  // pasteText writes into _pty, which is (a) null before start() — a dormant /
  // deferred / never-mounted tab, so the message silently vanishes — and (b) not
  // yet accepting input for ~1s while the agent boots, so a paste+Enter races the
  // launch and is lost or mangled. So "started" is NOT "ready": readiness is
  // _started AND _bootSettled, where _bootSettled flips true once the launch output
  // goes quiet (agent sitting at its prompt). deliverLocalMessage routes any
  // NOT-ready target through wakeAndDeliver, which ensures it's started and queues
  // the message; the boot-ready watch (armed in start() for EVERY session) flushes
  // the queue with paste+submit the instant the agent settles. A ready target
  // pastes+submits immediately, exactly as the active tab always did.
  final List<({String text, bool submit})> _pendingWake = [];
  // _bootSettled: the PTY's launch/redraw output has gone quiet at least once → the
  // agent is up and accepting input. Set once by _markBootSettled (settle timer or
  // hard cap) and stays true for the session's life.
  bool _bootSettled = false;
  // ready = has a live, input-accepting PTY. The single gate deliverLocalMessage
  // uses to choose "paste now" vs "queue until the agent boots".
  bool get ready => _started && _bootSettled;
  // pendingWakeCount exposes how many messages are held for a not-yet-ready target
  // — for tests to assert a delivery in the boot window is queued (not dropped,
  // not doubled, not pasted into a not-ready PTY).
  int get pendingWakeCount => _pendingWake.length;
  Timer? _bootSettleTimer;
  Timer? _bootCapTimer;
  // Quiet-after-launch gap that reads as "agent ready for input", and a hard cap
  // so a pathologically chatty startup still marks ready instead of hanging.
  static const Duration _bootSettle = Duration(milliseconds: 1500);
  static const Duration _bootCap = Duration(seconds: 30);

  // wakeAndDeliver queues [text] for a NOT-ready target and ensures it's started.
  // It never pastes directly — the boot-ready watch armed in start() drains
  // _pendingWake (paste+submit) once the agent settles. Safe across a burst: a
  // second delivery during the boot window just appends (order preserved) and the
  // still-pending flush delivers them all. Only called for a !ready target.
  void wakeAndDeliver(String text, {required bool submit}) {
    _pendingWake.add((text: text, submit: submit));
    deferred = false; // opening for delivery clears lazy-defer, like activation
    start(); // idempotent; arms the boot-ready watch if it wasn't already running
  }

  // _armBootReady starts the readiness watch: the cap is an unconditional backstop
  // armed at launch; the settle timer is armed per PTY chunk (see _noteBootOutput)
  // so ready lands ~_bootSettle after the launch output goes quiet, not mid-boot.
  void _armBootReady() {
    if (_bootSettled) return;
    _bootCapTimer?.cancel();
    _bootCapTimer = Timer(_bootCap, _markBootSettled);
  }

  // _noteBootOutput pushes the settle timer on each PTY chunk until the launch
  // output goes quiet. No-op once ready — a cheap guard on the output hot path.
  void _noteBootOutput() {
    if (_bootSettled) return;
    _bootSettleTimer?.cancel();
    _bootSettleTimer = Timer(_bootSettle, _markBootSettled);
  }

  // _markBootSettled flips the session to ready (once) and flushes any messages
  // queued while it booted, as paste+submit — so a task dispatched to a dormant or
  // still-booting session runs a turn with no manual Enter.
  void _markBootSettled() {
    if (_bootSettled) return;
    _bootSettled = true;
    _bootSettleTimer?.cancel();
    _bootSettleTimer = null;
    _bootCapTimer?.cancel();
    _bootCapTimer = null;
    if (_disposed) return;
    _flushPending();
  }

  void _flushPending() {
    if (_pendingWake.isEmpty) return;
    final pending = List.of(_pendingWake);
    _pendingWake.clear();
    // pasteText's delayed-Enter + _ensureSubmitted backstop drive the submit — the
    // same path the active tab uses — so a held message auto-runs on flush.
    for (final d in pending) {
      pasteText(d.text, submit: d.submit);
    }
  }

  // debugMarkBootSettled forces the ready transition (as the settle timer would)
  // so tests can exercise ready-target routing / queue-flush without a live agent
  // boot. Test-only; never called in production.
  void debugMarkBootSettled() => _markBootSettled();

  static final RegExp _terminalProtocolReply = RegExp(
    r'^(?:(?:'
    r'\x1b\](?:10|11);rgb:[0-9a-fA-F]{4}/[0-9a-fA-F]{4}/[0-9a-fA-F]{4}\x1b\\'
    r'|\x1b\[\?1;2c'
    r'|\x1b\[>0;0;0c'
    r'|\x1bP!\|00000000\x1b\\'
    r'|\x1b\[0n'
    r'|\x1b\[\d+;\d+R'
    r'|\x1b\[8;\d+;\d+t'
    r'))+$',
  );

  // _setBusy is the single chokepoint for the busy flag: it fires onBusyChanged
  // only on an actual transition so the overview projection updates once per
  // turn boundary (not per keystroke).
  void _setBusy(bool v) {
    if (_busy == v) return;
    _busy = v;
    if (v) {
      _usageTicker ??= Timer.periodic(const Duration(seconds: 3), (_) {
        if (_busy && !_disposed) unawaited(refreshUsage());
      });
    } else {
      _usageTicker?.cancel();
      _usageTicker = null;
    }
    _bumpActivity(); // working↔idle transition → refresh the tree avatar's glyph
    onBusyChanged?.call(this);
  }

  void _writeInputBytes(Uint8List bytes, {required bool allowProtocolReply}) {
    final data = utf8.decode(bytes, allowMalformed: true);
    final protocolReply = _terminalProtocolReply.hasMatch(data);
    if (protocolReply && !allowProtocolReply) return;
    if (!protocolReply) {
      _sawInput = true; // local keystrokes count as "the user gave it work"
      markUserInput(data); // track the unsubmitted input row (CR clears it)
      // A local Enter into an agent starts a turn → mark busy so a peer message
      // arriving now routes to the bus inbox (hook injection) not a paste queue.
      if (isAgent && data.contains('\r')) {
        _setBusy(true);
        unawaited(
          refreshUsage(),
        ); // turn starting → reflect busy + any new usage
      }
    }
    _pty?.write(bytes);
  }

  // markUserInput records that real user keyboard/IME text reached the input row,
  // so a delivered message enqueues instead of overwriting it. A submit (CR) means
  // the row was sent → clean again. Called ONLY from the genuine user-input funnels
  // (the hardware-key path here in _writeInputBytes and the EditableText commit in
  // _onChanged) — never from pasteText/sendText, so app delivery can't self-dirty
  // (that would wrongly divert every subsequent paste to the inbox). See [inputDirty].
  void markUserInput(String data) {
    if (data.isEmpty) return;
    _inputDirty = !data.contains('\r');
  }

  static const Duration _belSettle = Duration(
    milliseconds: 1200,
  ); // quiet-after-bell → done

  // Rolling buffer of recent raw PTY output so a phone connecting mid-session
  // can replay it and see the current screen / scrollback instead of a blank
  // terminal until the next redraw. Kept always (even with no watcher) and
  // bounded by char count; whole chunks go in/out to avoid splitting an escape
  // sequence mid-stream.
  final Queue<String> _backlog = Queue<String>();
  int _backlogLen = 0;
  static const int _backlogCap = 256 * 1024;

  // Trailing-whitespace matcher for renderSnapshot; compiled once, not per call.

  void _appendBacklog(String chunk) {
    _backlog.add(chunk);
    _backlogLen += chunk.length;
    while (_backlogLen > _backlogCap && _backlog.length > 1) {
      _backlogLen -= _backlog.removeFirst().length;
    }
  }

  String get backlog => _backlog.join();

  // --- token usage / cost (claude+codex) ----------------------------------
  //
  // usage publishes the latest per-session token/cost snapshot (null until first
  // computed / for non-agent sessions); the pane watches it for the overlay chip
  // and the local-bus `usage` channel serialises it for peers. Incremental: the
  // resolved transcript path and a running accumulator are cached so each refresh
  // only parses the bytes appended since the previous one. See agent_usage.dart.
  final ValueNotifier<SessionUsage?> usage = ValueNotifier(null);
  final UsageAccumulator _usageAcc = UsageAccumulator();
  String? _usagePath; // cached transcript path once resolved

  // transcriptPath lazily resolves and caches this agent session's on-disk log
  // path, shared by usage scanning and the overview preview so it's resolved
  // once (not per refresh/tick). Null for non-agent sessions / before the log
  // exists (left uncached so it keeps retrying until it appears).
  //
  // Only cached once [agentSessionId] is known: before then (codex capture
  // still in flight), resolveTranscriptPath falls back to a cwd/mtime guess
  // that can land on a sibling session's rollout — caching that guess would
  // pin the wrong transcript for this session's whole lifetime even after
  // _captureAgentId later lands the real id. So while agentSessionId is null,
  // every call re-resolves (cheap: a directory scan) instead of trusting the
  // first guess forever.
  Future<String?> transcriptPath() async {
    if (!isAgent) return null;
    if (agentSessionId != null) {
      return _usagePath ??= await resolveTranscriptPath(
        agentKind: agentKind,
        agentSessionId: agentSessionId,
        workdir: workdir,
      );
    }
    return resolveTranscriptPath(
      agentKind: agentKind,
      agentSessionId: agentSessionId,
      workdir: workdir,
    );
  }

  // refreshUsage folds any newly-appended transcript bytes into the accumulator
  // and republishes [usage]. Called on each turn boundary (start + finish) so the
  // numbers and the busy flag track the live session; also safe to call ad-hoc
  // (the bus `usage` read does). Returns the fresh snapshot, or null when this
  // session isn't an agent / has no transcript yet.
  Future<SessionUsage?> refreshUsage() async {
    final path = await transcriptPath();
    if (path == null) return null;
    try {
      await scanUsageInto(_usageAcc, path: path, agentKind: agentKind);
    } catch (_) {
      return usage.value;
    }
    final u = SessionUsage.fromAccumulator(
      _usageAcc,
      agentKind: agentKind,
      busy: busy,
    );
    if (!_disposed) usage.value = u;
    return u;
  }

  TerminalSession(
    this.workdir,
    this.command, {
    String? id,
    this.agent = '',
    this.preLaunch = '',
    this.supervisor = false,
    this.todoAssistant = false,
    this.agentSessionId,
    this.resume = false,
  }) : id = id ?? 'ts${_seq++}',
       ghostty = GhosttyShadowTerminal.create(cols: 80, rows: 24),
       title = pathBaseName(workdir).isNotEmpty
           ? pathBaseName(workdir)
           : workdir {
    // Codex is launched with --no-alt-screen (inline mode), but it still uses a
    // top scroll region with reserved composer rows. Opt this session into the
    // compatibility path that copies outgoing transcript rows into native
    // scrollback. Keep Claude/full-screen TUIs on the vendored xterm defaults.
    if (agent == 'codex') {
      terminal.inlineScrollRegionScrollback = true;
    }
    // claude AND codex are full-screen TUIs that enable mouse reporting and
    // scroll their OWN view in response to wheel reports (cmux scrolls codex
    // fine this way). Forward the wheel with the correct X11 codes for every
    // agent; the scroll_handler routes the wheel into mouseInput whenever the
    // app reports scroll — for both alt and main buffer — so codex (main buffer)
    // now scrolls too instead of its wheel being eaten by a local Scrollable.
    terminal.mouseHandler = const WheelMouseHandler();
  }

  // label is what the UI shows: the user-given name, else the derived title.
  String get label => (name != null && name!.isNotEmpty) ? name! : title;

  // asTarget is this session as a send-menu target (id + label).
  SendTarget get asTarget => (id: id, label: label);

  // isAgent reports whether this session runs an AI agent TUI (claude/codex),
  // sniffed from the launch command — the same convention used in
  // workspace_page.dart and remote_host.dart. The local bus reads it to decide
  // whether to attach a reply cheat-sheet to a delivered message.
  bool get isAgent => command.contains('claude') || command.contains('codex');

  // agentKind is the authoritative agent name ('claude'/'codex') for labels and
  // notifications: the explicit field when the launcher set it, else the legacy
  // command sniff (pickup / pre-upgrade sessions that carry no agent field).
  String get agentKind {
    if (agent.isNotEmpty) return agent;
    if (command.contains('codex')) return 'codex';
    if (command.contains('claude')) return 'claude';
    return '';
  }

  // selectedText is the current selection's text, or null when nothing is
  // selected. The host reads it to forward a selection to another session.
  String? get selectedText {
    final sel = controller.selection;
    if (sel == null) return null;
    final t = XtermSnapshotFormatter(
      terminal,
    ).plain(range: sel, trimTrailingBlankLines: false);
    return t.isEmpty ? null : t;
  }

  // renderSnapshot returns the last [lines] lines of this session's terminal as
  // plain text — the rendered screen + scrollback with ANSI stripped, which is
  // what `cc-handoff msg read` hands a sibling session. We render the whole
  // xterm buffer (getText with no range; bounded by maxLines=10000) and tail it
  // so a full-screen TUI (claude/codex) reads as the visible screen rather than
  // a stream of redraw escape codes. [lines] <= 0 returns the whole buffer.
  String renderSnapshot(int lines) {
    final all = XtermSnapshotFormatter(terminal).plain();
    if (lines <= 0) return all;
    final ls = all.split('\n');
    return ls.length <= lines ? all : ls.sublist(ls.length - lines).join('\n');
  }

  // historyText is the session's buffer (scrollback + screen) as plain text with
  // CRLF endings — for replaying READABLE history to a phone whose width differs
  // from this terminal's. The raw byte backlog bakes in THIS width's layout and
  // renders mis-wrapped at another width; this strips ANSI/colour so the phone's
  // terminal re-wraps each line at its own width. getText joins rows with '\n';
  // a terminal needs '\r\n' to also return to column 0, so normalise.
  String historyText() {
    return XtermSnapshotFormatter(terminal).plain(lineEnding: '\r\n');
  }

  // historyAnsi is historyText with COLOUR: it walks the buffer's cells and
  // re-emits them as a logical-line stream with inline SGR escapes, so a phone
  // re-wraps it at its own width AND keeps fg/bg/bold/etc. Soft-wrapped rows
  // carry no line break (isWrapped) so the phone re-flows them. Encoding per
  // xterm core/cell.dart (CellColor packs type<<25 | 0xRRGGBB-or-index; CellAttr
  // bit flags). Absolute-positioned TUI chrome flattens, same as historyText.
  String historyAnsi() => XtermSnapshotFormatter(terminal).ansi();

  // snapshotAnsi is historyAnsi limited to the last [rows] non-blank rows — a
  // bounded coloured tail for a small live preview (so a popup doesn't re-emit a
  // multi-thousand-line buffer each refresh).
  String snapshotAnsi(int rows) {
    return XtermSnapshotFormatter(terminal).ansiTail(rows);
  }

  // _resolvedCommand is the shell command actually run for this session. For a
  // plain shell / arbitrary command it's [command] unchanged. For an agent it's
  // rebuilt from agent + preLaunch + session binding so a reopened tab resumes
  // its prior conversation: claude binds a fixed --session-id on first launch
  // and --resume's it thereafter; codex has no pre-assignable id so it resumes
  // the cwd's most-recent rollout (--last). preLaunch (if any) is prepended.
  String _resolvedCommand() {
    if (agent != 'claude' && agent != 'codex') return command;
    final pre = preLaunch.trim();
    final prefix = pre.isEmpty ? '' : '$pre && ';
    // The agent invocation: a resolved absolute path / user override (set in
    // _startAsync via AgentResolver), else the bare agent name as a last resort.
    final inv = (_invocation != null && _invocation!.isNotEmpty)
        ? _invocation!
        : agent;
    if (agent == 'claude') {
      final c =
          '$inv --append-system-prompt ${_argQuote(_startupInstructions())}';
      if (!resume) {
        return agentSessionId == null
            ? '$prefix$c'
            : '$prefix$c --session-id $agentSessionId';
      }
      // Reopen: resume the exact id; fall back to most-recent if we never minted
      // one (e.g. a pre-upgrade persisted session).
      return agentSessionId == null
          ? '$prefix$c --continue'
          : '$prefix$c --resume $agentSessionId';
    }
    // codex can't be given a session id at launch; we capture the one it mints
    // (see _maybeCaptureAgentId) and resume that EXACT session on reopen, falling
    // back to the cwd's most-recent rollout if we never captured one.
    //
    // --no-alt-screen: run codex in INLINE mode so it commits its transcript to
    // the terminal's native scrollback instead of repainting a fixed full-screen
    // view in place. Verified (codex 0.142.4): the default full-screen view keeps
    // NO scrollback and ignores the mouse — its conversation can't be scrolled by
    // wheel/PageUp/arrows (history is only reachable via a pop-up transcript
    // pager). Inline mode makes the wheel scroll native scrollback AND makes the
    // scrolled-up history selectable/copyable, with no per-surface key synthesis.
    //
    // --dangerously-bypass-hook-trust: codex shows a blocking "trust hooks"
    // dialog whenever a hook config is new/changed (we install the bus hook into
    // ~/.codex/hooks.json). For the app's own env-guarded hook that dialog is
    // just friction — and it would stall non-interactive launches — so we vouch
    // for our own hook here (global flag, before the subcommand).
    final cdx =
        '$inv --no-alt-screen --dangerously-bypass-hook-trust '
        '-c ${_argQuote(_codexDeveloperInstructionsConfig())}';
    if (!resume) return '$prefix$cdx';
    return agentSessionId == null
        ? '$prefix$cdx resume --last'
        : '$prefix$cdx resume ${agentSessionId!}';
  }

  void start() {
    if (_started) return;
    _started = true;
    _armBootReady(); // watch launch output → mark ready + flush any queued delivery
    unawaited(_startAsync());
  }

  Future<void> _startAsync() async {
    // Resolve how to launch the agent (user override / discovered absolute path /
    // bare name) BEFORE spawning, so a claude/codex that isn't on the GUI's PATH
    // still starts. Cheap and cached after the first session (see AgentResolver).
    if (agent == 'claude' || agent == 'codex') {
      _invocation = await AgentResolver.resolve(agent);
    }
    if (_disposed) return; // closed during the async resolve
    // codex restore with no captured id: rather than the blind `resume --last`
    // (which resumes whatever codex ran most recently — possibly a DIFFERENT
    // folder's session), resolve THIS workdir's newest rollout and resume that
    // exact one. Persist it so the next restart is instant. Falls back to --last
    // only when no rollout for this folder is found (see _resolvedCommand).
    if (agent == 'codex' && resume && agentSessionId == null) {
      final id = await _newestCodexIdForWorkdir();
      if (_disposed) return;
      if (id != null) {
        agentSessionId = id;
        onPersist?.call();
      }
    }
    // Empty command = a plain interactive shell (typeable + scrollable);
    // otherwise run the (resolved) agent command and let the shell exit with it.
    final cmd = _resolvedCommand();
    final String shell;
    final List<String> args;
    if (Platform.isWindows) {
      // Windows has no /bin/sh and no SHELL; use the command processor. A bare
      // cmd.exe gives an interactive prompt; `/c <cmd>` runs the agent and exits
      // with it. (POSIX `-i -l` flags would make cmd.exe error out.)
      shell = Platform.environment['COMSPEC'] ?? 'cmd.exe';
      args = cmd.isEmpty ? const [] : ['/c', cmd];
    } else {
      shell = Platform.environment['SHELL'] ?? '/bin/sh';
      args = cmd.isEmpty ? const ['-i', '-l'] : ['-i', '-c', cmd];
    }
    // Resolve the working directory: expand a leading ~ and fall back to the home
    // dir if it doesn't exist, so a stale or Unix-style path can't make the spawn
    // throw (Pty.start hands workingDirectory straight to the OS).
    var wd = expandHome(workdir);
    if (wd.isEmpty || !Directory(wd).existsSync()) wd = homeDir();

    final Pty pty;
    try {
      final remoteSize = _remoteSize;
      // Breadcrumb: the last line in crash.log before a silent Windows 闪退
      // localizes the crash to the native ConPTY spawn (see crash_log.dart).
      logBreadcrumb('pty.spawn $id agent="$agent" shell="$shell"');
      pty = Pty.start(
        shell,
        arguments: args,
        // Declare a real terminal type so full-screen TUIs (claude/codex) enable
        // mouse reporting → wheel scroll reaches them. The CC_* vars wire this
        // session into the local message bus: the agent inside calls
        // `"$CC_HANDOFF_BIN" msg send <peer> …` (or bare `cc-handoff` — its dir is
        // prepended to PATH) to reach a sibling session. NOTE: flutter_pty forwards
        // only a fixed env allowlist plus this map — NOT the full parent env — so
        // _sessionEnv() seeds the full environment on Windows itself (without it
        // cmd.exe has no SystemRoot and the terminal spawns blank).
        environment: _sessionEnv(),
        workingDirectory: wd,
        rows: remoteSize?.rows ?? terminal.viewHeight,
        columns: remoteSize?.cols ?? terminal.viewWidth,
      );
    } catch (e) {
      // A spawn failure used to leave a silent blank terminal — surface it.
      terminal.write('\r\n\x1b[31m[启动失败] 无法启动 $shell:\r\n$e\x1b[0m\r\n');
      return;
    }
    _pty = pty;
    terminal.onOutput = (data) {
      _writeInputBytes(
        Uint8List.fromList(const Utf8Encoder().convert(data)),
        allowProtocolReply: true,
      );
    };
    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          terminal.write(chunk);
          ghostty?.writeString(chunk);
          _appendBacklog(chunk);
          remoteSink?.call(chunk);
          if (isAgent) _markActivity(chunk);
          _noteBootOutput(); // launch-settle detector → flips the session to ready
        });
    pty.exitCode.then((code) {
      logBreadcrumb('pty.exit $id code=$code');
      // Non-zero exits in red so a process that dies on startup isn't mistaken
      // for an empty terminal.
      final exitMessage =
          '\r\n\x1b[${code == 0 ? '90' : '31'}m[已退出: $code]\x1b[0m\r\n';
      terminal.write(exitMessage);
      // 127 = command not found: the agent binary couldn't be launched. Point
      // the user at the per-agent override so they can fix it.
      if (code == 127 && (agent == 'claude' || agent == 'codex')) {
        final notFoundMessage =
            '\x1b[33m未找到 $agent。可在「账号 · config.toml」设置 '
            '${agent}_command(绝对路径或启动命令)后重开。\x1b[0m\r\n';
        terminal.write(notFoundMessage);
      }
    });
    // A phone mirroring this session (remoteSink set) owns the PTY size; don't
    // let local (Mac window) resizes fight it — last-writer-wins between the
    // wide Mac and the narrow phone is what garbles the mirror.
    terminal.onResize = (w, h, pw, ph) {
      ghostty?.resize(w, h);
      if (remoteSink == null) pty.resize(h, w);
    };
    _maybeCaptureAgentId();
  }

  // --- agent session-id capture -------------------------------------------
  //
  // We only run this when we DON'T already know the agent's session id: codex
  // (which can't be told an id at launch) always, and a restored legacy claude
  // tab with no stored id (fresh claude is launched with a minted --session-id,
  // so it's known up front). Three exact sources, in order of immediacy:
  //   1. lsof — the rollout codex currently holds open (codex only; instant).
  //   2. the bus hook — `cc-handoff bus-hook` records CC_SESSION_ID -> the
  //      session_id every Claude/Codex hook payload carries (event-driven, the
  //      only path on Windows); see _hookAgentId.
  //   3. directory scan — newest rollout in today's bucket whose cwd matches
  //      (codex only; fragile mtime/cwd fallback).
  // On capture we persist so a reopened tab resumes that EXACT conversation; a
  // total miss degrades codex to `resume --last` (claude to `--continue`).
  bool _agentCaptureStarted = false;

  void _maybeCaptureAgentId() {
    if (_agentCaptureStarted) return;
    if (agentSessionId != null) return; // already minted (claude) / resolved
    if (agent != 'codex' && agent != 'claude') return;
    _agentCaptureStarted = true;
    unawaited(_captureAgentId(DateTime.now()));
  }

  Future<void> _captureAgentId(DateTime since) async {
    final home = Platform.environment['CODEX_HOME'] ?? '${homeDir()}/.codex';
    final sessions = Directory('$home/sessions');
    final isCodex = agent == 'codex';
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (_disposed) return;
      // claude: the hook is the only thing that can tell us a session id we
      // didn't mint ourselves (legacy --continue restore). codex: lsof (exact,
      // earliest) → hook → the newest rollout written since launch in this cwd.
      final id = isCodex
          ? await _codexRolloutViaLsof() ??
                localBusAgentSessionId(this.id) ??
                await _scanCodexRolloutId({
                  _codexBucket(sessions, since),
                  _codexBucket(
                    sessions,
                    since.subtract(const Duration(hours: 6)),
                  ),
                }, floor: since.subtract(const Duration(seconds: 5)))
          : localBusAgentSessionId(this.id);
      if (id != null) {
        agentSessionId = id;
        onPersist?.call();
        return;
      }
    }
  }

  String _codexBucket(Directory sessions, DateTime d) =>
      '${sessions.path}/${d.year.toString().padLeft(4, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.day.toString().padLeft(2, '0')}';

  // _newestCodexIdForWorkdir returns the id of the newest rollout whose cwd
  // matches this session's workdir, scanning the last few day-buckets with no
  // time floor — used to turn a captured-id-less codex *resume* into an exact
  // `codex resume <id>` for THIS folder instead of the blind `resume --last`.
  Future<String?> _newestCodexIdForWorkdir() async {
    final home = Platform.environment['CODEX_HOME'] ?? '${homeDir()}/.codex';
    final sessions = Directory('$home/sessions');
    final now = DateTime.now();
    return _scanCodexRolloutId({
      for (var d = 0; d < 3; d++)
        _codexBucket(sessions, now.subtract(Duration(days: d))),
    });
  }

  // _scanCodexRolloutId returns a rollout id under [dirs] whose cwd matches
  // this session. [floor], when set, stops the scan once files predate it and
  // requires the match to be UNIQUE (see below); left null, it accepts any
  // age and returns the first (newest) match. One statSync per file.
  Future<String?> _scanCodexRolloutId(
    Set<String> dirs, {
    DateTime? floor,
  }) async {
    final dated = [
      for (final f in await _rolloutFilesIn(dirs)) (f, f.statSync().modified),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    if (floor == null) {
      // Resume-resolver (_newestCodexIdForWorkdir): no time bound, so many
      // historical rollouts for this cwd are normal and the newest cwd match
      // is deliberately the answer — keep "first hit wins".
      for (final (f, _) in dated) {
        final id = await _rolloutId(f);
        if (id != null) return id;
      }
      return null;
    }
    // Post-launch capture polling (_captureAgentId): candidates are only
    // rollouts written since this session started, so more than one cwd match
    // means a sibling session launched in the same window and we can't yet
    // tell them apart — pickUniqueRolloutId returns null (still-unknown)
    // rather than guessing which one is ours (串味); the 30x600ms retry loop
    // tries again next tick.
    final inWindow = <File>[];
    for (final (f, mtime) in dated) {
      if (mtime.isBefore(floor)) break;
      inWindow.add(f);
    }
    return pickUniqueRolloutId(inWindow, workdir);
  }

  Future<List<File>> _rolloutFilesIn(Set<String> dirs) async {
    final files = <File>[];
    for (final p in dirs) {
      final d = Directory(p);
      if (!await d.exists()) continue;
      try {
        await for (final e in d.list(followLinks: false)) {
          if (e is File &&
              e.path.contains('rollout-') &&
              e.path.endsWith('.jsonl')) {
            files.add(e);
          }
        }
      } catch (_) {}
    }
    return files;
  }

  // _codexRolloutViaLsof asks the OS which rollout-*.jsonl the codex process
  // under our PTY currently holds open, and returns its session id. Exact: it's
  // the file codex is literally writing, so it needs no mtime/cwd guesswork. The
  // PTY child is a shell — codex may BE it (sh -c can exec the command) or a
  // descendant — so we check the whole subtree. macOS/Linux only; null on miss.
  Future<String?> _codexRolloutViaLsof() async {
    if (Platform.isWindows) return null;
    final root = _pty?.pid;
    if (root == null) return null;
    for (final pid in await _descendantPids(root)) {
      try {
        final r = await Process.run('lsof', ['-p', '$pid', '-Fn']);
        if (r.exitCode != 0) continue;
        for (final line in (r.stdout as String).split('\n')) {
          if (!line.startsWith('n')) {
            continue; // -Fn: name records start with 'n'
          }
          final path = line.substring(1);
          if (path.contains('rollout-') && path.endsWith('.jsonl')) {
            // The process identity already pins this to our session, so read the
            // id regardless of the recorded cwd (which can differ by symlink).
            final id = await _rolloutId(File(path), checkCwd: false);
            if (id != null) return id;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  // _descendantPids returns [root] plus its descendant pids, from one `ps`
  // snapshot. Best-effort: at minimum [root].
  Future<List<int>> _descendantPids(int root) async {
    final out = <int>[root];
    try {
      final r = await Process.run('ps', ['-axo', 'pid=,ppid=']);
      if (r.exitCode != 0) return out;
      final kids = <int, List<int>>{};
      for (final line in (r.stdout as String).split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final pid = int.tryParse(parts[0]);
        final ppid = int.tryParse(parts[1]);
        if (pid == null || ppid == null) continue;
        (kids[ppid] ??= <int>[]).add(pid);
      }
      final stack = <int>[root];
      while (stack.isNotEmpty) {
        for (final c in kids[stack.removeLast()] ?? const <int>[]) {
          if (!out.contains(c)) {
            out.add(c);
            stack.add(c);
          }
        }
      }
    } catch (_) {}
    return out;
  }

  // _rolloutId returns a rollout's session id, or null. With checkCwd (the
  // directory scan, where the file is only a candidate) it must also match this
  // session's workdir; the lsof path passes checkCwd:false since the open file
  // already belongs to this session's process (and its recorded cwd may differ
  // by symlink).
  Future<String?> _rolloutId(File f, {bool checkCwd = true}) async {
    final meta = await readRolloutMeta(f);
    if (meta == null) return null;
    if (checkCwd && !cwdMatches(meta['cwd']?.toString(), workdir)) return null;
    final id = meta['id']?.toString();
    return (id != null && id.isNotEmpty) ? id : null;
  }

  int? get pid => _pty?.pid;

  // _sessionEnv builds the PTY environment: the terminal type (so TUIs report
  // mouse) plus the local-bus wiring (CC_SESSION_ID/NAME for identity, CC_BUS_DIR
  // + CC_HANDOFF_BIN for the `msg` CLI). The cc-handoff dir is prepended to PATH
  // so a bundled (non-system) binary is still callable by bare name.
  //
  // flutter_pty 0.4.2 does NOT forward the full parent environment — it copies
  // only a fixed POSIX allowlist (HOME/PATH/USER/LOGNAME/DISPLAY/LC_TYPE) plus
  // whatever we pass here. That's enough for /bin/sh on macOS, but cmd.exe can't
  // even start without SystemRoot (and needs ComSpec/PATHEXT/TEMP/…), so on
  // Windows we must seed the full Platform.environment ourselves — otherwise the
  // terminal spawns blank. macOS keeps the lean map (don't change what works).
  Map<String, String> _sessionEnv() {
    final bin = Cli.binPath();
    final env = <String, String>{
      if (Platform.isWindows) ...Platform.environment,
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'CC_SESSION_ID': id,
      'CC_SESSION_NAME': label,
      'CC_BUS_DIR': localBusDir(),
      'CC_HANDOFF_BIN': bin,
      if (supervisor) 'CC_SUPERVISOR': '1',
    };
    if (bin.contains(Platform.pathSeparator)) {
      final binDir = File(bin).parent.path;
      final sep = Platform.isWindows ? ';' : ':';
      final base = Platform.environment['PATH'] ?? '';
      env['PATH'] = base.isEmpty ? binDir : '$binDir$sep$base';
    }
    return env;
  }

  void sendText(String s) {
    _sawInput = true; // remote keys / delivered messages also arm the detector
    // A lone CR submitting to an agent starts a turn (remote Enter, or the
    // submit \r pasteText sends after a delivered message) → mark busy.
    if (isAgent && s == '\r') {
      _setBusy(true);
      unawaited(refreshUsage());
    }
    _pty?.write(const Utf8Encoder().convert(s));
  }

  // _markActivity feeds the turn detector one output chunk. A BEL arms it; while
  // armed, every chunk (re)starts the settle timer so _fireDone runs only once
  // output goes quiet AFTER the bell — the final redraw doesn't fire it early,
  // and a bell whose work then resumes keeps pushing the timer out. Output with
  // no bell since the last fire does nothing: no idle/timeout path, so a mid-turn
  // pause never reads as "done".
  void _markActivity(String chunk) {
    if (!_belArmed && chunk.contains('\x07')) _belArmed = true;
    if (!_belArmed) return;
    _belTimer?.cancel();
    _belTimer = Timer(_belSettle, _fireDone);
  }

  // _fireDone announces a finished turn. It only runs while armed by a bell;
  // it skips turns the user never kicked off (_sawInput) — e.g. the initial idle
  // prompt — and disarms so the next turn needs a fresh bell.
  void _fireDone() {
    _belArmed = false;
    unawaited(refreshUsage()); // turn ended → fold the new assistant message in
    if (!_sawInput) {
      _setBusy(false); // disarm-only (user never kicked it) → just clear busy
      return;
    }
    // A user-kicked turn finished → flag for review BEFORE clearing busy so the
    // onBusyChanged-driven overview republish already reflects "待 review".
    needsReview = true;
    _setBusy(false); // bell settled → agent is idle/waiting again
    onDone?.call(this);
  }

  // pasteText injects [s] as one bracketed-paste block (ESC[200~ … ESC[201~) so
  // a full-screen TUI inserts it atomically — no per-newline submit, no control-
  // char interpretation — even mid-stream. Use this (not sendText) for any
  // programmatically delivered message; sendText stays raw for keystrokes.
  void pasteText(String s, {bool submit = false}) {
    sendText('\x1b[200~$s\x1b[201~');
    if (!submit) return;
    // Send Enter after a short delay (a \r in the same instant as ESC[201~ lands
    // before the TUI has committed the paste and gets swallowed → text sits in
    // the input box unsent). The delay alone is a guess, so [_ensureSubmitted] is
    // the backstop: it verifies the box actually cleared and re-sends Enter if not.
    Future.delayed(_submitDelay, () {
      if (_disposed) return;
      final before = renderSnapshot(_submitCheckLines);
      sendText('\r');
      _ensureSubmitted(before, 0);
    });
  }

  // _ensureSubmitted is the auto-submit backstop. [before] is the bottom input
  // region snapshotted with our text sitting in it, right before the \r. Shortly
  // after, we snapshot again: if it's UNCHANGED the \r was swallowed (text still
  // parked unsent) → resend Enter, up to [_submitRetries] times. Any change
  // (input cleared, message echoed back, agent started) means it submitted →
  // stop checking. Comparing before/after (not text-matching our message) avoids
  // a false hit from the just-submitted message echoing near the bottom; a stray
  // resend (if it had already submitted) is a harmless Enter on an empty prompt.
  void _ensureSubmitted(String before, int attempt) {
    if (attempt >= _submitRetries) return;
    Future.delayed(_submitCheckDelay, () {
      if (_disposed) return;
      if (renderSnapshot(_submitCheckLines) != before) return; // cleared → sent
      sendText('\r'); // unchanged → \r was swallowed → resend
      _ensureSubmitted(before, attempt + 1);
    });
  }

  // Auto-submit timing/backstop knobs. _submitDelay: human-scale gap after the
  // paste before the first Enter. The backstop re-checks after _submitCheckDelay,
  // up to _submitRetries times, over the bottom _submitCheckLines lines (the
  // input-box region). Only gates programmatic delivery, never typing.
  static const Duration _submitDelay = Duration(milliseconds: 300);
  static const Duration _submitCheckDelay = Duration(milliseconds: 350);
  static const int _submitRetries = 2;
  static const int _submitCheckLines = 8;

  // resizeFromRemote lets a connected client (phone / web) size the PTY to its
  // viewport — whoever's watching redraws. Only reject a truly degenerate
  // sliver (<2 col/row, which would collapse the agent's UI into 竖排); a large
  // font makes a legit phone viewport narrow (well under 20 cols), so don't
  // reject that — it must reach the PTY or the phone overflows.
  void resizeFromRemote(int rows, int cols) {
    if (rows >= 2 && cols >= 2) {
      _remoteSize = (rows: rows, cols: cols);
      ghostty?.resize(cols, rows);
      _pty?.resize(rows, cols);
    }
  }

  // restoreLocalSize: the last phone detached — resize the PTY back to the
  // desktop's own viewport so the Mac returns to full width. Call right after
  // clearing remoteSink (which hands size authority back to local resizes).
  // terminal.viewWidth/Height track the Mac's xterm fit (decoupled from the
  // PTY), so they hold the desktop's current size even after the phone shrank it.
  void restoreLocalSize() {
    _remoteSize = null;
    final r = terminal.viewHeight, c = terminal.viewWidth;
    if (r > 0 && c > 0) {
      ghostty?.resize(c, r);
      _pty?.resize(r, c);
    }
  }

  void dispose() {
    _disposed = true; // stops the codex id-capture poll
    _belTimer?.cancel();
    _usageTicker?.cancel();
    _bootSettleTimer?.cancel();
    _bootCapTimer?.cancel();
    activityRev.dispose();
    usage.dispose();
    controller.dispose();
    ghostty?.dispose();
    _pty?.kill();
  }
}

// TerminalPane renders one session and starts it on first build.
class TerminalPane extends StatefulWidget {
  final TerminalSession session;
  // Forwarding targets for the in-terminal "发送到会话" menu, grouped: [same]
  // (same project) inline, [others] (other projects) under a 其他会话 submenu.
  // Both empty hides the entries.
  final List<SendTarget> same;
  final List<SendTarget> others;
  // onSendToPeer(fromId, targetId, text): route the selection into a sibling
  // session's input box (fill, no submit). Null hides the menu entries.
  final void Function(String fromId, String targetId, String text)?
  onSendToPeer;
  // onInterjectToPeer(fromId, targetId, text): same targets as onSendToPeer but
  // submit:true — interjects into a busy peer's running turn (via its bus hook),
  // or runs the selection immediately when the peer is idle. Null hides it.
  final void Function(String fromId, String targetId, String text)?
  onInterjectToPeer;
  // onSendToOnline(text): hand the selection to the host's "发送到在线用户" flow
  // (pick a remote user + their session). Null hides that menu entry.
  final void Function(String text)? onSendToOnline;
  // active = this pane is the one currently shown by its IndexedStack (vs an
  // offstage sibling kept alive but not drawn). Only consumed on Windows, where
  // it drives the IME layer to drop its text-input connection when offstage —
  // see _WindowsImeInputLayer. Defaults true so non-IndexedStack callers behave
  // as before.
  final bool active;
  const TerminalPane({
    super.key,
    required this.session,
    this.same = const [],
    this.others = const [],
    this.onSendToPeer,
    this.onInterjectToPeer,
    this.onSendToOnline,
    this.active = true,
  });

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  // The selection/copy controller now lives on the session (so the host can
  // read the current selection to forward it); the pane just references it. Its
  // lifecycle is the session's, so the pane doesn't dispose it.
  TerminalController get _controller => widget.session.controller;

  Terminal get _terminal => widget.session.terminal;

  String? get _currentSelectionText {
    final sel = _controller.selection;
    if (sel == null) return null;
    final text = XtermSnapshotFormatter(
      _terminal,
    ).plain(range: sel, trimTrailingBlankLines: false);
    return text.isEmpty ? null : text;
  }

  bool get _hasSelection => _currentSelectionText != null;

  void _clearSelection() {
    _controller.clearSelection();
  }

  @override
  void initState() {
    super.initState();
    // A deferred (restored-but-hidden) session waits for activation to spawn its
    // PTY — its pane still mounts in the IndexedStack, it just doesn't start the
    // agent until the user opens it (see TerminalSession.deferred / _activeChanged).
    if (!widget.session.deferred) widget.session.start();
    // Populate the usage chip immediately for a resumed session (whose transcript
    // already exists on disk); a fresh session fills in on its first turn.
    unawaited(widget.session.refreshUsage());
  }

  void _copy() {
    final text = _currentSelectionText;
    if (text == null) return;
    Clipboard.setData(ClipboardData(text: text));
    _clearSelection();
    snack(context, '已复制');
  }

  // _paste is the single paste entry (right-click 粘贴 and Cmd/Ctrl+V, both
  // routed here). Text wins; if the clipboard holds no text but an image (e.g. a
  // screenshot), it's written to a temp PNG and the file path is pasted instead
  // — claude/codex read the image from that path. Flutter's Clipboard is
  // text-only, so the image goes through `pasteboard`.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _terminal.paste(text);
      _clearSelection();
      return;
    }
    await _pasteImage();
  }

  // _pasteImage drops a clipboard image to a temp PNG and pastes its path so the
  // agent can read it. No-op when the clipboard has no image.
  Future<void> _pasteImage() async {
    Uint8List? bytes;
    try {
      bytes = await Pasteboard.image;
    } catch (_) {}
    if (bytes == null || bytes.isEmpty) return;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/cc-paste');
      await dir.create(recursive: true);
      final path =
          '${dir.path}/img-${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes, flush: true);
      _terminal.paste(path);
      if (mounted) snack(context, '已粘贴图片路径(回车让 agent 读取)');
    } catch (_) {
      if (mounted) snack(context, '粘贴图片失败');
    }
  }

  // Mirrors xterm's SelectAllTextIntent so the menu item matches Cmd/Ctrl+A.
  void _selectAll() {
    final b = _terminal.buffer;
    _controller.setSelection(
      b.createAnchor(0, b.height - _terminal.viewHeight),
      b.createAnchor(_terminal.viewWidth, b.height - 1),
      mode: SelectionMode.line,
    );
  }

  // _sendSelectionTo fills the current selection into peer [targetId]'s input
  // (no submit). _interjectSelectionTo routes it submit:true instead, so a busy
  // peer's running turn gets it via its bus hook (or it runs immediately when
  // the peer is idle). Both no-op without a selection or the matching callback.
  void _sendSelectionTo(String targetId) =>
      _forwardSelectionTo(targetId, widget.onSendToPeer, '已发送');
  void _interjectSelectionTo(String targetId) =>
      _forwardSelectionTo(targetId, widget.onInterjectToPeer, '已插话');

  void _forwardSelectionTo(
    String targetId,
    void Function(String fromId, String targetId, String text)? cb,
    String done,
  ) {
    final text = _currentSelectionText;
    if (text == null || cb == null) return;
    cb(widget.session.id, targetId, text);
    _clearSelection();
    final label = _peerLabel(targetId);
    snack(context, label != null ? '$done到 $label' : done);
  }

  // _peerLabel resolves a forwarding target id to its display label, or null.
  String? _peerLabel(String targetId) {
    for (final t in [...widget.same, ...widget.others]) {
      if (t.id == targetId) return t.label;
    }
    return null;
  }

  // _sendSelectionToOnline hands the current selection to the host's
  // "发送到在线用户" picker (a remote user + their session). No-op without one.
  void _sendSelectionToOnline() {
    final text = _currentSelectionText;
    final cb = widget.onSendToOnline;
    if (text == null || cb == null) return;
    cb(text);
    _clearSelection();
  }

  Future<void> _showMenu(Offset globalPos) async {
    final hasSelection = _hasSelection;
    final hasTargets = widget.same.isNotEmpty || widget.others.isNotEmpty;
    final canSend = widget.onSendToPeer != null && hasTargets;
    final canInterject = widget.onInterjectToPeer != null && hasTargets;
    // Send targets only when there's a selection to send (else just the editing
    // rows). 复制/粘贴/全选 sit above the send section via extraTop; 发送到在线
    // 用户 sits below via extraBottom (also selection-gated).
    final v = await showGroupedSendMenu(
      context,
      globalPos,
      same: hasSelection && canSend ? widget.same : const [],
      others: hasSelection && canSend ? widget.others : const [],
      extraTop: [
        ccMenuItem(
          value: 'copy',
          icon: Icons.content_copy_rounded,
          label: '复制',
          enabled: hasSelection,
        ),
        ccMenuItem(
          value: 'paste',
          icon: Icons.content_paste_rounded,
          label: '粘贴',
        ),
        ccMenuItem(
          value: 'selectAll',
          icon: Icons.select_all_rounded,
          label: '全选',
        ),
      ],
      extraBottom: [
        if (hasSelection && canInterject)
          ccMenuItem(
            value: 'interject',
            icon: Icons.bolt_rounded,
            label: '插话到会话…',
          ),
        if (hasSelection && widget.onSendToOnline != null)
          ccMenuItem(
            value: 'online',
            icon: Icons.cloud_upload_rounded,
            label: '发送到在线用户…',
          ),
      ],
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'copy':
        _copy();
      case 'paste':
        _paste();
      case 'selectAll':
        _selectAll();
      case 'online':
        _sendSelectionToOnline();
      case 'interject':
        // Flutter showMenu has no submenu: reopen a target picker, then route
        // the selection submit:true so a busy peer receives it via its Stop hook.
        final pick = await showPeerPicker(
          context,
          globalPos,
          [...widget.same, ...widget.others],
          'interject',
          icon: Icons.bolt_rounded,
          label: (t) => '插话到「${t.label}」',
        );
        if (pick != null && mounted && pick.startsWith('interject:')) {
          _interjectSelectionTo(pick.substring('interject:'.length));
        }
      default:
        if (v.startsWith('send:')) {
          _sendSelectionTo(v.substring('send:'.length));
        }
    }
  }

  // _onKeyEvent intercepts the paste shortcut (Cmd+V on macOS, Ctrl+V elsewhere —
  // matching xterm's defaultTerminalShortcuts) so paste routes through our
  // image-aware _paste() instead of xterm's text-only handler. Returning handled
  // short-circuits xterm's shortcut manager (see TerminalView._handleKeyEvent);
  // every other key falls through unchanged.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final pasteMod = Platform.isMacOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    if (pasteMod && event.logicalKey == LogicalKeyboardKey.keyV) {
      unawaited(_paste());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final view = TerminalView(
      _terminal,
      controller: _controller,
      // Windows drives all input through the _WindowsImeInputLayer overlay below
      // (a real EditableText), so the TerminalView itself takes no keyboard there.
      hardwareKeyboardOnly: Platform.isWindows,
      onSecondaryTapDown: (details, _) => _showMenu(details.globalPosition),
      onKeyEvent: _onKeyEvent,
      theme: ccTerminalTheme,
      textStyle: const TerminalStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
      backgroundOpacity: 1,
      padding: const EdgeInsets.all(10),
    );
    // The Flutter Windows engine never delivers text-input/IME (updateEditingValue)
    // to xterm's custom text client (proven by on-screen diagnostics), so Chinese
    // can't reach the terminal through it. On Windows we overlay a REAL EditableText
    // — which the engine DOES feed IME — to capture typing + composition and forward
    // it to the PTY, while the TerminalView underneath keeps display/scroll/selection.
    final base = Platform.isWindows
        ? _WindowsImeInputLayer(
            session: widget.session,
            active: widget.active,
            child: view,
          )
        : view;
    // Agent sessions get a compact usage chip in the top-right corner (model ·
    // context% · tokens · est. cost). IgnorePointer so it never steals selection.
    if (!widget.session.isAgent) return base;
    return Stack(
      children: [
        Positioned.fill(child: base),
        Positioned(
          top: 4,
          right: 8,
          child: ValueListenableBuilder<SessionUsage?>(
            valueListenable: widget.session.usage,
            builder: (_, u, _) =>
                u == null ? const SizedBox.shrink() : _UsageChip(u),
          ),
        ),
      ],
    );
  }
}

// _UsageChip is the small overlay showing a session's token usage / est. cost.
// Dot = idle (green) / busy (amber); text = SessionUsage.shortLabel().
class _UsageChip extends StatelessWidget {
  final SessionUsage usage;
  const _UsageChip(this.usage);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xCC1E1E1E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: usage.busy
                    ? const Color(0xFFE5C07B)
                    : const Color(0xFF98C379),
              ),
            ),
            Text(
              usage.shortLabel(),
              style: const TextStyle(
                color: Color(0xFFD7DAE0),
                fontSize: 10.5,
                fontFamily: 'JetBrainsMono',
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// _WindowsImeInputLayer overlays a real (invisible) EditableText over the terminal
// to capture keyboard + IME input on Windows. Committed text (ASCII and composed
// CJK) is forwarded to the PTY and the field reset to empty; control keys
// (Enter/Backspace/Tab/Esc/arrows/Ctrl-*) are turned into terminal sequences via
// the terminal's keyInput. The TerminalView is wrapped in ExcludeFocus so it can't
// steal keyboard focus from the input; a Listener focuses the input on any tap.
class _WindowsImeInputLayer extends StatefulWidget {
  final TerminalSession session;
  final Widget child;
  // active = this pane is the currently-focused one. When it goes false the
  // hidden EditableText releases its Windows TSF/IME connection (see
  // didUpdateWidget) so at most one live text-input connection exists at a time
  // — an offstage-but-still-connected EditableText is the Flutter Windows
  // engine's most crash-prone state and the suspected 开会话闪退 trigger.
  final bool active;
  const _WindowsImeInputLayer({
    required this.session,
    required this.child,
    required this.active,
  });

  @override
  State<_WindowsImeInputLayer> createState() => _WindowsImeInputLayerState();
}

class _WindowsImeInputLayerState extends State<_WindowsImeInputLayer> {
  final TextEditingController _ctrl = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);

  // Named keys that must become terminal control sequences rather than text.
  static final _special = <LogicalKeyboardKey>{
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
  };

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
    logBreadcrumb('ime.init ${widget.session.id} active=${widget.active}');
  }

  // When this pane stops being the active one, drop the EditableText's TSF/IME
  // connection (unfocus) so no offstage input stays connected; refocus when it
  // becomes active again so the user can type immediately (post-frame — the
  // pane isn't laid out yet at didUpdateWidget time). This keeps exactly one
  // live text-input connection across all open sessions.
  @override
  void didUpdateWidget(_WindowsImeInputLayer old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active) return;
    if (widget.active) {
      logBreadcrumb('ime.activate ${widget.session.id}');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focus.requestFocus();
      });
    } else {
      logBreadcrumb('ime.deactivate ${widget.session.id}');
      _focus.unfocus();
    }
  }

  @override
  void dispose() {
    logBreadcrumb('ime.dispose ${widget.session.id}');
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // Forward committed (non-composing) text to the PTY, then reset to empty so the
  // field is a pure input funnel. While the IME is composing we wait for commit.
  void _onChanged() {
    final v = _ctrl.value;
    if (v.composing.isValid || v.text.isEmpty) return;
    // Committed keyboard/IME text is real user input → mark the input row dirty so
    // a peer message arriving now parks in the bus inbox instead of pasting over it.
    widget.session.markUserInput(v.text);
    widget.session.sendText(v.text);
    _ctrl.clear();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // During IME composition every key belongs to the input method.
    if (_ctrl.value.composing.isValid) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed;
    final alt = hw.isAltPressed;
    final shift = hw.isShiftPressed;
    // Let Ctrl+V paste through the field (-> _onChanged -> PTY); let plain
    // printable keys flow to the field/IME as text.
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyV) {
      return KeyEventResult.ignored;
    }
    final isControl = _special.contains(event.logicalKey) || ctrl || alt;
    if (!isControl) return KeyEventResult.ignored;
    final tk = keyToTerminalKey(event.logicalKey);
    if (tk == null) return KeyEventResult.ignored;
    final handled = widget.session.terminal.keyInput(
      tk,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
    );
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _focus.requestFocus(),
      child: Stack(
        children: [
          ExcludeFocus(child: widget.child),
          Positioned.fill(
            child: IgnorePointer(
              child: EditableText(
                controller: _ctrl,
                focusNode: _focus,
                maxLines: 1,
                style: const TextStyle(color: Color(0x00000000), fontSize: 1),
                cursorColor: const Color(0x00000000),
                backgroundCursorColor: const Color(0x00000000),
                keyboardType: TextInputType.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
