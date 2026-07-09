import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/agent_transcript.dart';
import '../local/config.dart';
import '../local/identity.dart';
import '../local/local_bus.dart';
import '../local/session_overview.dart';
import '../local/skill_pack.dart';
import '../theme.dart';
import '../widgets.dart';

// CapsulePlazaPage is the 胶囊广场: a browsable gallery of session capsules the
// caller can see — every 公开 (public) capsule plus their own 个人 (private)
// ones. Fed by GET /v1/capsules. On desktop each capsule can be 载入 into a
// fresh specialized session (① full-context snapshot / ② distilled role).
class CapsulePlazaPage extends StatefulWidget {
  final RelayClient client;
  final String identity;
  // overviewStore + config drive 载入 (spawn a session + dispatch an opening
  // message). isDesktop gates it: spawn is only wired when a WorkspacePage is
  // mounted (desktop), so mobile just browses.
  final SessionOverviewStore overviewStore;
  final AppConfig config;
  final bool isDesktop;
  const CapsulePlazaPage({
    super.key,
    required this.client,
    required this.identity,
    required this.overviewStore,
    required this.config,
    required this.isDesktop,
  });

  @override
  State<CapsulePlazaPage> createState() => _CapsulePlazaPageState();
}

bool capsuleOwnedBy(CapsuleListItem capsule, String identity) =>
    sameIdentity(capsule.owner, identity);

class _CapsulePlazaPageState extends State<CapsulePlazaPage> {
  List<CapsuleListItem>? _items;
  String? _error;
  bool _loading = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.client.capsules();
      if (!_isCurrentLoad(generation)) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!_isCurrentLoad(generation)) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  bool _isCurrentLoad(int generation) =>
      mounted && generation == _loadGeneration;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
          child: Row(
            children: [
              const Icon(
                Icons.storefront_rounded,
                size: 20,
                color: CcColors.accent,
              ),
              const SizedBox(width: 10),
              const Text(
                '胶囊广场',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              if (_items != null)
                Text(
                  '${_items!.length} 个',
                  style: CcType.code(size: 12.5, color: CcColors.muted),
                ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_rounded, size: 18),
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() => asyncBody(
    loading: _loading && _items == null,
    error: _error,
    onRetry: _load,
    child: () {
      final items = _items ?? const <CapsuleListItem>[];
      if (items.isEmpty) {
        return centerMsg('广场还没有胶囊。\n在「会话总览」把一个会话「打成胶囊」并设为公开,就会出现在这里。');
      }
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _capsuleCard(items[i]),
        ),
      );
    },
  );

  Widget _capsuleCard(CapsuleListItem c) {
    final mine = capsuleOwnedBy(c, widget.identity);
    final isPublic = c.visibility == 'public';
    Text meta(String s) =>
        Text(s, style: CcType.code(size: 11.5, color: CcColors.subtle));
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CcColors.panel,
        borderRadius: BorderRadius.circular(CcRadius.md),
        border: Border.all(color: CcColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                c.sourceAgent == 'codex'
                    ? Icons.terminal_rounded
                    : Icons.smart_toy_rounded,
                size: 16,
                color: CcColors.subtle,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  c.headline.isEmpty ? '(无说明)' : c.headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              tag(
                isPublic ? '公开' : '个人',
                isPublic ? CcColors.accent : CcColors.muted,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              meta(mine ? '我的' : c.owner),
              meta('源 ${c.sourceAgent}'),
              meta(
                '①${c.hasTranscript ? "有" : "无"}  ②${c.hasPersona ? "有" : "无"}',
              ),
              if (c.repoName.isNotEmpty) meta(c.repoName),
            ],
          ),
          if (mine ||
              (widget.isDesktop && (c.hasTranscript || c.hasPersona))) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                // Owner-only edit/delete.
                if (mine) ...[
                  _cardAction(Icons.edit_rounded, '编辑', () => _editCapsule(c)),
                  const SizedBox(width: 2),
                  _cardAction(
                    Icons.delete_outline_rounded,
                    '删除',
                    () => _deleteCapsule(c),
                    color: CcColors.danger,
                  ),
                ],
                const Spacer(),
                if (widget.isDesktop && (c.hasTranscript || c.hasPersona))
                  OutlinedButton.icon(
                    onPressed: () => _loadCapsule(c),
                    icon: const Icon(Icons.download_rounded, size: 15),
                    label: const Text('载入'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 30),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _cardAction(
    IconData icon,
    String label,
    VoidCallback onPressed, {
    Color? color,
  }) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 15, color: color),
    label: Text(label, style: color == null ? null : TextStyle(color: color)),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      minimumSize: const Size(0, 30),
    ),
  );

  Future<void> _deleteCapsule(CapsuleListItem c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除胶囊?'),
        content: Text(
          '「${c.headline.isEmpty ? c.id : c.headline}」将从广场移除,不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.client.deleteCapsule(c.id);
      if (!mounted) return;
      snack(context, '胶囊已删除');
      _load();
    } catch (e) {
      if (mounted) snack(context, '删除失败: ${errorText(e)}');
    }
  }

  Future<void> _editCapsule(CapsuleListItem c) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _CapsuleEditDialog(client: widget.client, capsule: c),
    );
    if (!mounted) return;
    if (changed == true) _load();
  }

  Future<void> _loadCapsule(CapsuleListItem c) => showDialog(
    context: context,
    builder: (_) => _CapsuleLoadDialog(
      client: widget.client,
      overviewStore: widget.overviewStore,
      config: widget.config,
      capsule: c,
    ),
  );
}

// _crossMachineNote is appended to a loaded capsule's opening prompt. A capsule
// usually comes from another machine, so absolute paths / local scripts / skill
// locations baked into its context may not exist here — tell the session to
// resolve tools by name in the local env instead of assuming paths, and not to
// burn turns re-scanning the whole disk when something isn't where it expected.
const _crossMachineNote =
    '\n\n⚠️ 注意:此上下文可能来自**另一台机器**——里面提到的绝对路径 / 本地脚本 / 技能位置,'
    '在本机可能不存在或位置不同。遇到时**按名字与用途在本机环境(技能、当前仓库、PATH)里找**'
    '对应的技能/脚本/工具,不要假设路径一致;找不到时先在当前仓库定位,别反复全盘搜索。';

// _CapsuleLoadDialog spins up a fresh specialized session from a plaza capsule:
// the receiver picks a form (② distilled role / ① full-context snapshot), a
// target tool (claude/codex — cross-tool works because ① rides as a text seed),
// and a target workspace/project. On confirm it fetches the payload, spawns the
// session, and dispatches an opening message (the ready-gate auto-runs it).
class _CapsuleLoadDialog extends StatefulWidget {
  final RelayClient client;
  final SessionOverviewStore overviewStore;
  final AppConfig config;
  final CapsuleListItem capsule;
  const _CapsuleLoadDialog({
    required this.client,
    required this.overviewStore,
    required this.config,
    required this.capsule,
  });

  @override
  State<_CapsuleLoadDialog> createState() => _CapsuleLoadDialogState();
}

class _CapsuleLoadDialogState extends State<_CapsuleLoadDialog> {
  late String _form; // 'role' (②) | 'snapshot' (①)
  late String _tool; // claude | codex
  String? _workspace;
  String? _project;
  final _branchCtl = TextEditingController();
  bool _submitting = false;
  Package? _pkg; // fetched once on open, reused by _extractSkillPacks at load
  List<String>? _bundledSkills; // null = still loading

  @override
  void initState() {
    super.initState();
    // Prefer ② role when available (self-contained); else ① snapshot.
    _form = widget.capsule.hasPersona ? 'role' : 'snapshot';
    // Default target tool = the capsule's source tool (native side).
    _tool = widget.capsule.sourceAgent == 'codex' ? 'codex' : 'claude';
    final ws = widget.config.workspaces;
    if (ws.isNotEmpty) {
      _workspace = ws.first.name;
      _project = ws.first.projects.isEmpty
          ? null
          : ws.first.projects.first.name;
    }
    _loadPackage();
  }

  // _loadPackage fetches the capsule package once: it drives the bundled-skill
  // display now and is reused by _extractSkillPacks at load time (no 2nd get).
  Future<void> _loadPackage() async {
    try {
      final pkg = await widget.client.get(widget.capsule.id);
      if (mounted) {
        setState(() {
          _pkg = pkg;
          _bundledSkills = skillPackNames(pkg.attachments);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _bundledSkills = const []);
    }
  }

  @override
  void dispose() {
    _branchCtl.dispose();
    super.dispose();
  }

  List<ProjectCfg> get _projects => projectsOf(widget.config, _workspace);

  String? get _projectPath {
    final m = _projects.where((p) => p.name == _project);
    return m.isEmpty ? null : m.first.path;
  }

  // _wouldNativeResume is true for ① when the target tool matches the source:
  // the raw transcript can be imported locally and byte-exact `--resume`d.
  bool get _wouldNativeResume =>
      _form == 'snapshot' && _tool == widget.capsule.sourceAgent;

  void _fail(String msg) {
    if (mounted) setState(() => _submitting = false);
    snack(context, msg);
  }

  Future<void> _submit() async {
    final ws = _workspace, proj = _project;
    final projPath = _projectPath;
    if (ws == null || proj == null || projPath == null) {
      snack(context, '请选择目标工作区 / 项目');
      return;
    }
    setState(() => _submitting = true);
    try {
      // Place any bundled skill packs into the local skills dir first, so the
      // session (resumed or seeded) can use them immediately.
      final skills = await _extractSkillPacks();
      if (!mounted) return;

      // ① same-tool: import the raw log locally → native `--resume` (highest
      // fidelity). Falls through to the seed path if it can't be set up.
      if (_wouldNativeResume) {
        final resumeId = await _importForResume(projPath);
        if (!mounted) return;
        if (resumeId != null) {
          final (sid, err) = await widget.overviewStore.spawn(
            workspace: ws,
            project: proj,
            kind: _tool,
            resumeAgentSessionId: resumeId,
            workdir: projPath,
          );
          if (!mounted) return;
          if (sid == null) {
            _fail('起会话失败: ${err ?? "未知错误"}');
            return;
          }
          Navigator.of(context).pop();
          snack(context, '已原样恢复(--resume)新会话到工作区');
          return;
        }
      }

      // Seed path: ② role, ① cross-tool, or native import unavailable.
      final prompt = await _buildOpeningPrompt(skills);
      if (!mounted) return;
      if (prompt == null) {
        _fail('拉取胶囊内容失败');
        return;
      }
      final branch = _branchCtl.text.trim();
      final (sid, err) = await widget.overviewStore.spawn(
        workspace: ws,
        project: proj,
        kind: _tool,
        newWorktreeBranch: branch.isEmpty ? null : branch,
      );
      if (!mounted) return;
      if (sid == null) {
        _fail('起会话失败: ${err ?? "未知错误"}');
        return;
      }
      // Dispatch immediately after spawn, like 待办指派→新建会话. The live
      // WorkspacePage owns the TerminalSession and deliverLocalMessage will see
      // the fresh session as !ready, then queue through wakeAndDeliver until the
      // boot-ready watch flushes it. Waiting on the overview card's workdir is
      // only a metadata poll; it can move this first prompt out of the protected
      // queue path and back into a paste-vs-boot timing window.
      final dispErr = widget.overviewStore.dispatch(
        LocalMsg('', sid, prompt, true),
      );
      Navigator.of(context).pop();
      snack(
        context,
        dispErr == null ? '已载入胶囊,新会话开跑' : '会话已起,但投递开场失败: $dispErr',
      );
    } catch (e) {
      if (!mounted) return;
      _fail('载入失败: ${errorText(e)}');
    }
  }

  // _importForResume downloads transcript.jsonl and writes it into the local
  // agent store, returning the id to `--resume`, or null to fall back to seed.
  Future<String?> _importForResume(String projPath) async {
    // claude needs the origin id as the local filename — skip the (multi-MB)
    // download when we don't have it and let the caller fall back to seed.
    if (_tool != 'codex' && widget.capsule.originSessionId.isEmpty) return null;
    final bytes = await _fetchBytes('transcript.jsonl');
    if (bytes == null) return null;
    return importCapsuleTranscriptForResume(
      agentKind: _tool,
      bytes: bytes,
      workdir: projPath,
      originId: widget.capsule.originSessionId,
      now: DateTime.now(),
    );
  }

  Future<List<int>?> _fetchBytes(String name) async {
    try {
      return await widget.client.attachment(widget.capsule.id, name);
    } catch (_) {
      return null;
    }
  }

  // _buildOpeningPrompt fetches the chosen form's payload and wraps it into the
  // new session's first turn. Returns null if the payload can't be fetched.
  Future<String?> _buildOpeningPrompt(List<String> skills) async {
    final c = widget.capsule;
    final skillsNote = skills.isEmpty
        ? ''
        : '\n\n胶囊自带的技能已落到本机 `${skillsDirLabel(_tool)}/`:${skills.join('、')} —— 需要时直接用 `/<名字>` 调用,不用再去别处找。';
    if (_form == 'role') {
      final body = await _fetchText('persona.md');
      if (body == null) return null;
      return '你现在是一个「专职会话」。下面是你的角色定义(来自胶囊 ${c.id}),'
          '请把它作为工作准则严格遵守,不要复述它。读完后用一两句话说明你将专注做什么,然后待命。\n\n'
          '---\n$body\n---$_crossMachineNote$skillsNote';
    }
    // ① snapshot: prefer the compact seed, else the full neutral transcript.
    // Try seed.md directly (returns null when absent) rather than a get(c.id)
    // round-trip just to enumerate attachment names.
    final body =
        await _fetchText('seed.md') ?? await _fetchText('transcript.txt');
    if (body == null) return null;
    return '下面是另一个会话冻结下来的上下文(来自胶囊 ${c.id},源工具 ${c.sourceAgent})。'
        '请把它当作你自己的前情:先读完,用一两句话复述「目标 / 已完成 / 当前进度 / 待办」,'
        '确认理解后无缝接着干。\n\n---\n$body\n---$_crossMachineNote$skillsNote';
  }

  // _extractSkillPacks downloads the capsule's bundled skill packs (attachments
  // ending in .skillpack.zip) and unzips each into the LOADED tool's skills dir
  // (Claude ~/.claude/skills, Codex ~/.codex/skills) — SKILL.md is the shared
  // open standard, so the same pack works in either. Returns the installed
  // skill names (for the opening prompt), so the session has them even on a
  // machine that never installed the skill.
  Future<List<String>> _extractSkillPacks() async {
    final pkg = _pkg ?? await widget.client.get(widget.capsule.id);
    final names = <String>[];
    for (final a in pkg.attachments) {
      if (!isCapsuleSkillPack(a.name)) continue;
      final bytes = await _fetchBytes(a.name);
      if (bytes == null) continue;
      final name = await installSkillPack(bytes, a.name, tool: _tool);
      if (name != null) names.add(name);
    }
    return names;
  }

  Future<String?> _fetchText(String name) async {
    final bytes = await _fetchBytes(name);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  List<DropdownMenuItem<String>> _nameItems(Iterable<dynamic> xs) => [
    for (final x in xs)
      DropdownMenuItem(
        value: x.name as String,
        child: Text(
          x.name as String,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final c = widget.capsule;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.download_rounded,
                    size: 20,
                    color: CcColors.accent,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '载入胶囊',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                c.headline.isEmpty ? '(无说明)' : c.headline,
                style: CcType.code(size: 12, color: CcColors.subtle),
              ),
              if (_bundledSkills != null && _bundledSkills!.isNotEmpty) ...[
                const SizedBox(height: 12),
                _sectionLabel('自带技能'),
                _skillWrap(_bundledSkills!),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '起会话时自动装到本机 ${skillsDirLabel(_tool)}/',
                    style: CcType.code(size: 11, color: CcColors.subtle),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _sectionLabel('形态'),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'role',
                    enabled: c.hasPersona,
                    label: const Text('② 蒸馏角色'),
                  ),
                  ButtonSegment(
                    value: 'snapshot',
                    enabled: c.hasTranscript,
                    label: const Text('① 完整快照'),
                  ),
                ],
                selected: {_form},
                onSelectionChanged: (s) => setState(() => _form = s.first),
              ),
              if (_form == 'snapshot')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _wouldNativeResume
                        ? '同工具:拉原始日志到本地,原样 --resume(项目根,忽略 worktree 分支)'
                        : '跨工具:以中性转录作上下文 seed 起新会话',
                    style: CcType.code(size: 11, color: CcColors.subtle),
                  ),
                ),
              const SizedBox(height: 12),
              _sectionLabel('目标工具'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'claude', label: Text('Claude')),
                  ButtonSegment(value: 'codex', label: Text('Codex')),
                ],
                selected: {_tool},
                onSelectionChanged: (s) => setState(() => _tool = s.first),
              ),
              const SizedBox(height: 12),
              _sectionLabel('目标位置'),
              DropdownButton<String>(
                isExpanded: true,
                menuMaxHeight: 320,
                hint: const Text('workspace'),
                value: _workspace,
                items: _nameItems(widget.config.workspaces),
                onChanged: (v) => setState(() {
                  _workspace = v;
                  final p = _projects;
                  _project = p.isEmpty ? null : p.first.name;
                }),
              ),
              const SizedBox(height: 8),
              DropdownButton<String>(
                isExpanded: true,
                menuMaxHeight: 320,
                hint: const Text('project'),
                value: _project,
                items: _nameItems(_projects),
                onChanged: (v) => setState(() => _project = v),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _branchCtl,
                decoration: const InputDecoration(
                  labelText: '新建 worktree 分支名(可选)',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.rocket_launch_rounded, size: 16),
                    label: const Text('起会话'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// bundledSkillNames lists the skill names a capsule carries (its
// .skillpack.zip attachments) — for display in the load / edit dialogs so both
// sides can see what rides along. Best-effort: [] on any fetch error.
Future<List<String>> bundledSkillNames(RelayClient client, String id) async {
  try {
    final pkg = await client.get(id);
    return skillPackNames(pkg.attachments);
  } catch (_) {
    return const [];
  }
}

// fetchCapsuleText downloads one capsule attachment and utf8-decodes it, or
// null if absent/unfetchable — shared by the load / edit dialogs.
Future<String?> fetchCapsuleText(
  RelayClient client,
  String id,
  String name,
) async {
  try {
    final b = await client.attachment(id, name);
    return utf8.decode(b, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

// _skillChip is the shared little pill used to show a bundled skill name.
Widget _skillChip(String name) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  decoration: BoxDecoration(
    border: Border.all(color: CcColors.accent, width: 1),
    borderRadius: BorderRadius.circular(6),
  ),
  child: Text('/$name', style: CcType.code(size: 11.5, color: CcColors.accent)),
);

// _skillWrap lays out bundled-skill chips (shared by the load / edit dialogs).
Widget _skillWrap(List<String> names) => Wrap(
  spacing: 6,
  runSpacing: 6,
  children: [for (final s in names) _skillChip(s)],
);

// _sectionLabel is the shared bold section header used across the dialogs.
Widget _sectionLabel(String s) => Padding(
  padding: const EdgeInsets.only(bottom: 4),
  child: Text(s, style: const TextStyle(fontWeight: FontWeight.w600)),
);

// _CapsuleEditDialog lets an owner edit their plaza capsule's visibility and
// description (summary), and view its distilled content (persona / seed) plus
// the skills it bundles. Persona/seed content editing is a separate step.
class _CapsuleEditDialog extends StatefulWidget {
  final RelayClient client;
  final CapsuleListItem capsule;
  const _CapsuleEditDialog({required this.client, required this.capsule});

  @override
  State<_CapsuleEditDialog> createState() => _CapsuleEditDialogState();
}

class _CapsuleEditDialogState extends State<_CapsuleEditDialog> {
  late bool _public;
  late final TextEditingController _summary;
  bool _saving = false;
  List<String>? _skills; // null until the content fetch completes (loading)
  String _persona = '';
  String _seed = '';

  @override
  void initState() {
    super.initState();
    _public = widget.capsule.visibility == 'public';
    _summary = TextEditingController(text: widget.capsule.headline);
    _load();
  }

  Future<void> _load() async {
    // Kick all three fetches off before awaiting so they run concurrently.
    final id = widget.capsule.id;
    final skillsF = bundledSkillNames(widget.client, id);
    final personaF = fetchCapsuleText(widget.client, id, 'persona.md');
    final seedF = fetchCapsuleText(widget.client, id, 'seed.md');
    final skills = await skillsF;
    final persona = await personaF;
    final seed = await seedF;
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _persona = persona ?? '';
      _seed = seed ?? '';
    });
  }

  // _readonlyBox renders a labeled, scrollable, selectable preview of capsule
  // content (persona / seed). Content editing is a separate step.
  Widget _readonlyBox(String label, String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionLabel(label),
      Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 130),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: CcColors.subtle),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SingleChildScrollView(
          child: SelectableText(
            text.trim().isEmpty ? '(空)' : text.trim(),
            style: const TextStyle(fontSize: 11.5, height: 1.4),
          ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _summary.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.client.patchCapsule(
        widget.capsule.id,
        visibility: _public ? 'public' : 'private',
        summary: _summary.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      snack(context, '已保存');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      snack(context, '保存失败: ${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.edit_rounded,
                      size: 20,
                      color: CcColors.accent,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '编辑胶囊',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _summary,
                  decoration: const InputDecoration(
                    labelText: '说明',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('个人'),
                      icon: Icon(Icons.lock_outline_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('公开'),
                      icon: Icon(Icons.public_rounded, size: 16),
                    ),
                  ],
                  selected: {_public},
                  onSelectionChanged: (s) => setState(() => _public = s.first),
                ),
                const SizedBox(height: 6),
                Text(
                  _public ? '团队所有人能在广场看到' : '只有你自己能在广场看到',
                  style: CcType.code(size: 11.5, color: CcColors.subtle),
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 12),
                if (_skills == null)
                  const Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('读取胶囊内容…', style: TextStyle(fontSize: 12)),
                    ],
                  )
                else ...[
                  _sectionLabel('自带技能'),
                  if (_skills!.isEmpty)
                    Text(
                      '(无)',
                      style: CcType.code(size: 11.5, color: CcColors.subtle),
                    )
                  else
                    _skillWrap(_skills!),
                  const SizedBox(height: 12),
                  _readonlyBox('专职角色 (persona)', _persona),
                  const SizedBox(height: 12),
                  _readonlyBox('上下文摘要 (seed)', _seed),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_rounded, size: 16),
                      label: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
