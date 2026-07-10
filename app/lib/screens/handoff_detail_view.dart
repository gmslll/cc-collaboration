import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../local/identity.dart';
import '../local/repo_config.dart';
import '../theme.dart';
import '../widgets.dart';

// HandoffDetailView is the reusable 对接文档: a 5-tab view (文档 / Prompt / API /
// 文件 / 评论) + header + actions. Shared by the inbox cockpit (right pane) and
// the workspace cockpit (a dialog).
//
// Callbacks let the host wire local-only bits without owning detail state:
//  - onOpenTerminal(workdir, command): pickup → host adds a terminal session.
//    Null hides the pickup button (e.g. mobile / no terminal deck).
//  - onSendToTerminal(text): "发送到终端". Null hides the button.
//  - onChanged: after ack/retract/reassign, so the host can refresh its list.
class HandoffDetailView extends StatefulWidget {
  final RelayClient client;
  final AppConfig config;
  final Me? me;
  final ListItem item;
  final void Function(String workdir, String command)? onOpenTerminal;
  final void Function(String text)? onSendToTerminal;
  final VoidCallback? onChanged;
  final bool Function()? isCurrentContext;

  const HandoffDetailView({
    super.key,
    required this.client,
    required this.config,
    this.me,
    required this.item,
    this.onOpenTerminal,
    this.onSendToTerminal,
    this.onChanged,
    this.isCurrentContext,
  });

  @override
  State<HandoffDetailView> createState() => HandoffDetailViewState();
}

bool canCurrentIdentityReceiveHandoff({
  required Package package,
  required Status? status,
  required String identity,
}) {
  if (sameIdentity(package.recipient, identity)) return true;
  if (package.recipients.any(
    (recipient) => sameIdentity(recipient, identity),
  )) {
    return true;
  }
  if (status == null) return false;
  if (sameIdentity(status.recipient, identity)) return true;
  if (status.recipients.any((recipient) => sameIdentity(recipient, identity))) {
    return true;
  }
  return status.pickupBy.keys.any(
    (recipient) => sameIdentity(recipient, identity),
  );
}

bool canCurrentIdentityCommentOnHandoff({
  required Package package,
  required Status? status,
  required String identity,
  required Me? me,
}) {
  if (me?.isAdmin == true) return true;
  if (sameIdentity(package.sender, identity) ||
      (status != null && sameIdentity(status.sender, identity))) {
    return true;
  }
  if (canCurrentIdentityReceiveHandoff(
    package: package,
    status: status,
    identity: identity,
  )) {
    return true;
  }
  final projectId = package.deliveryTarget?.projectId ?? '';
  if (projectId.isEmpty || me == null) return false;
  for (final project in me.projects) {
    if (project.id.trim() == projectId.trim() &&
        project.role.trim().toLowerCase() != 'viewer') {
      return true;
    }
  }
  return false;
}

typedef HandoffReassignCandidate = ({String identity, String label});

List<HandoffReassignCandidate> handoffReassignCandidates({
  required Package package,
  required String currentIdentity,
  ProjectDetail? project,
  OrganizationDetail? organization,
}) {
  final candidates = <HandoffReassignCandidate>[];
  final seen = <String>{};
  final currentKey = identityLookupKey(currentIdentity);
  final senderKey = identityLookupKey(package.sender);

  void add(String raw, String displayName) {
    final identity = cleanedIdentity(raw);
    final key = identityLookupKey(identity);
    if (key.isEmpty || key == currentKey || key == senderKey) return;
    if (!seen.add(key)) return;
    final name = displayName.trim();
    candidates.add((
      identity: identity,
      label: name.isEmpty ? identity : '$name · $identity',
    ));
  }

  final projectDetail = project;
  if (projectDetail != null) {
    add(projectDetail.project.ownerIdentity, '');
    for (final member in projectDetail.members) {
      add(member.identity, member.displayName);
    }
  }

  final organizationDetail = organization;
  if (organizationDetail != null) {
    final hasProjectScope = projectDetail != null;
    add(organizationDetail.organization.ownerIdentity, '');
    for (final member in organizationDetail.members) {
      final role = member.role.trim().toLowerCase();
      if (!hasProjectScope || role == 'owner' || role == 'admin') {
        add(member.identity, member.displayName);
      }
    }
  }

  return candidates;
}

bool handoffReassignTargetAllowed(
  String target,
  List<HandoffReassignCandidate> candidates,
) {
  if (candidates.isEmpty) return true;
  final key = identityLookupKey(target);
  if (key.isEmpty) return false;
  return candidates.any((candidate) {
    return identityLookupKey(candidate.identity) == key;
  });
}

double handoffReassignCandidateListMaxHeight(
  Size screenSize, {
  double preferred = 112,
  double minHeight = 88,
  double maxFraction = 0.26,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

double handoffActionDialogWidth(Size size, {double preferred = 440}) {
  final available = size.width - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

String handoffAttachmentTempPath(String tempDirPath, String attachmentName) {
  final parts = attachmentName
      .split(RegExp(r'[\\/]+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty && part != '.' && part != '..')
      .map((part) => part.replaceAll(RegExp(r'[\x00-\x1F<>:"|?*]+'), '_'))
      .where((part) => part.isNotEmpty)
      .toList();
  final safeName = parts.isEmpty ? 'attachment' : parts.join('_');
  final sep = Platform.pathSeparator;
  final base = tempDirPath.endsWith('/') || tempDirPath.endsWith('\\')
      ? tempDirPath.substring(0, tempDirPath.length - 1)
      : tempDirPath;
  return base.isEmpty ? safeName : '$base$sep$safeName';
}

class HandoffDetailViewState extends State<HandoffDetailView> {
  Package? _pkg;
  Status? _status;
  String? _prompt;
  List<Comment> _comments = const [];
  bool _loading = true;
  bool _picking = false;
  bool _commenting = false;
  bool _acking = false;
  bool _retractDialogOpen = false;
  bool _retracting = false;
  bool _reassigning = false;
  int _loadGeneration = 0;
  final _commentCtl = TextEditingController();

  RelayClient get _client => widget.client;
  AppConfig get _cfg => widget.config;
  String get _id => widget.item.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HandoffDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_detailContextChanged(oldWidget)) {
      _loadGeneration++;
      _commentCtl.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _commentCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final id = _id;
    setState(() {
      _pkg = null;
      _status = null;
      _prompt = null;
      _comments = const [];
      _picking = false;
      _commenting = false;
      _acking = false;
      _retractDialogOpen = false;
      _retracting = false;
      _reassigning = false;
      _loading = true;
    });
    try {
      final pkg = await client.get(id);
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      setState(() {
        _pkg = pkg;
        _loading = false;
      });
      reloadComments(
        generation: generation,
        client: client,
        id: id,
        relayUrl: relayUrl,
        token: token,
        identity: identity,
      );
      _loadExtras(
        generation: generation,
        client: client,
        id: id,
        relayUrl: relayUrl,
        token: token,
        identity: identity,
      );
    } catch (e) {
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      setState(() => _loading = false);
      _snack(errorText(e));
    }
  }

  bool _detailContextChanged(HandoffDetailView oldWidget) =>
      oldWidget.item.id != widget.item.id ||
      !identical(oldWidget.client, widget.client) ||
      oldWidget.config.relayUrl != widget.config.relayUrl ||
      oldWidget.config.token != widget.config.token ||
      oldWidget.config.identity != widget.config.identity;

  bool _isHostContextCurrent() => widget.isCurrentContext?.call() ?? true;

  bool _isCurrentLoad(
    int generation,
    RelayClient client,
    String id,
    String relayUrl,
    String token,
    String identity,
  ) =>
      mounted &&
      generation == _loadGeneration &&
      identical(client, widget.client) &&
      id == _id &&
      relayUrl == _cfg.relayUrl &&
      token == _cfg.token &&
      identity == _cfg.identity &&
      _isHostContextCurrent();

  // reloadComments is public so the host's SSE can refresh on comment.created.
  Future<void> reloadComments({
    int? generation,
    RelayClient? client,
    String? id,
    String? relayUrl,
    String? token,
    String? identity,
  }) async {
    final loadGeneration = generation ?? _loadGeneration;
    final handoffClient = client ?? _client;
    final handoffId = id ?? _id;
    final handoffRelayUrl = relayUrl ?? _cfg.relayUrl;
    final handoffToken = token ?? _cfg.token;
    final handoffIdentity = identity ?? _cfg.identity;
    try {
      final cs = await handoffClient.comments(handoffId);
      if (_isCurrentLoad(
        loadGeneration,
        handoffClient,
        handoffId,
        handoffRelayUrl,
        handoffToken,
        handoffIdentity,
      )) {
        setState(() => _comments = cs);
      }
    } catch (_) {}
  }

  Future<void> _loadExtras({
    int? generation,
    RelayClient? client,
    String? id,
    String? relayUrl,
    String? token,
    String? identity,
  }) async {
    final loadGeneration = generation ?? _loadGeneration;
    final handoffClient = client ?? _client;
    final handoffId = id ?? _id;
    final handoffRelayUrl = relayUrl ?? _cfg.relayUrl;
    final handoffToken = token ?? _cfg.token;
    final handoffIdentity = identity ?? _cfg.identity;
    try {
      final p = await handoffClient.prompt(handoffId);
      if (_isCurrentLoad(
        loadGeneration,
        handoffClient,
        handoffId,
        handoffRelayUrl,
        handoffToken,
        handoffIdentity,
      )) {
        setState(() => _prompt = p);
      }
    } catch (_) {}
    try {
      final s = await handoffClient.status(handoffId);
      if (_isCurrentLoad(
        loadGeneration,
        handoffClient,
        handoffId,
        handoffRelayUrl,
        handoffToken,
        handoffIdentity,
      )) {
        setState(() => _status = s);
      }
    } catch (_) {}
  }

  void _snack(String s) {
    if (mounted) snack(context, s);
  }

  Future<void> _postComment() async {
    if (_commenting) return;
    final body = _commentCtl.text.trim();
    if (body.isEmpty) return;
    final generation = _loadGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final id = _id;
    setState(() => _commenting = true);
    try {
      await client.postComment(id, body);
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _commentCtl.clear();
      await reloadComments(
        generation: generation,
        client: client,
        id: id,
        relayUrl: relayUrl,
        token: token,
        identity: identity,
      );
    } catch (e) {
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _snack('评论失败: ${errorText(e)}');
    } finally {
      if (mounted &&
          _isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        setState(() => _commenting = false);
      }
    }
  }

  Future<void> _ack() async {
    if (_acking) return;
    final generation = _loadGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final id = _id;
    setState(() => _acking = true);
    try {
      await client.ack(id);
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _snack('已标记接收');
      _loadExtras(
        generation: generation,
        client: client,
        id: id,
        relayUrl: relayUrl,
        token: token,
        identity: identity,
      );
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _snack('ack 失败: ${errorText(e)}');
    } finally {
      if (mounted &&
          _isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        setState(() => _acking = false);
      }
    }
  }

  Future<void> _pickup(Package p) async {
    final generation = _loadGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final id = p.id;
    final path = _cfg.repoPath(p.repo.name);
    if (path == null) {
      _snack(
        '本地找不到 repo "${p.repo.name}" —— 在 config.toml 的 [[workspace]] 里把它加上',
      );
      return;
    }
    // If the repo has no .cc-handoff.toml, offer to initialize the minimal
    // per-repo context needed for pickup/worktrees. Team routing no longer
    // needs a legacy partner field.
    if (!File(RepoConfig.pathFor(path)).existsSync()) {
      if (!await _confirmInit(p, path)) return;
    }
    if (!mounted) return;
    if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
      return;
    }
    setState(() => _picking = true);
    try {
      final r = await Cli.pickup(p.id, path);
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      widget.onOpenTerminal?.call(r.worktreeDir, r.agentCmd);
      if (mounted) setState(() => _picking = false);
    } catch (e) {
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      if (mounted) setState(() => _picking = false);
      _snack('pickup 失败: ${errorText(e)}');
    }
  }

  // _confirmInit prompts to initialize an un-init'd repo, then writes a minimal
  // .cc-handoff.toml (repo + base only). Returns true when the repo is ready to
  // pick up (config written), false when the user cancels or the write fails.
  Future<bool> _confirmInit(Package p, String path) async {
    final generation = _loadGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final id = p.id;
    final repoName = p.repo.name.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: const Text(
            '初始化仓库',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: handoffActionDialogWidth(size),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('这个仓库还没初始化 cc-handoff。'),
                  const SizedBox(height: 8),
                  Text(
                    repoName.isEmpty ? p.repo.name : repoName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.code(size: 12),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '缺少 .cc-handoff.toml。要现在初始化并接收吗？',
                    style: TextStyle(color: CcColors.muted),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'repo = ${repoName.isEmpty ? p.repo.name : repoName}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.code(size: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.code(size: 11, color: CcColors.muted),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('初始化并接收'),
            ),
          ],
        );
      },
    );
    if (ok != true) return false;
    if (!mounted) return false;
    if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
      return false;
    }
    try {
      await RepoConfig(
        raw: {},
        repo: repoName.isEmpty ? p.repo.name : repoName,
        base: 'origin/main',
      ).save(path);
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return false;
      }
      return true;
    } catch (e) {
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return false;
      }
      _snack('初始化失败: ${errorText(e)}');
      return false;
    }
  }

  Future<void> _retract(Package p) async {
    if (_retracting || _retractDialogOpen) return;
    final generation = _loadGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final id = p.id;
    setState(() => _retractDialogOpen = true);
    try {
      final reason = await showDialog<String>(
        context: context,
        builder: (_) => const _RetractDialog(),
      );
      if (reason == null) return;
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      setState(() {
        _retractDialogOpen = false;
        _retracting = true;
      });
      await client.retract(id, reason.trim());
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _snack('已撤回');
      _loadExtras(
        generation: generation,
        client: client,
        id: id,
        relayUrl: relayUrl,
        token: token,
        identity: identity,
      );
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _snack('撤回失败: ${errorText(e)}');
    } finally {
      if (mounted &&
          _isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        setState(() {
          _retractDialogOpen = false;
          _retracting = false;
        });
      }
    }
  }

  Future<void> _reassign(Package p) async {
    if (_reassigning) return;
    final generation = _loadGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final id = p.id;
    setState(() => _reassigning = true);
    try {
      final candidates = await _loadReassignCandidates(
        p,
        generation: generation,
        client: client,
        id: id,
        relayUrl: relayUrl,
        token: token,
        identity: identity,
      );
      if (candidates == null) return;
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      setState(() => _reassigning = false);
      final result = await showDialog<_ReassignInput>(
        context: context,
        builder: (_) => _ReassignDialog(candidates: candidates),
      );
      if (result == null) return;
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      final to = result.to.trim();
      final reason = result.reason.trim();
      if (to.isEmpty || reason.isEmpty) {
        _snack('需填转交对象和原因');
        return;
      }
      setState(() => _reassigning = true);
      await client.reassign(id, to, reason);
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _snack('已转交');
      _loadExtras(
        generation: generation,
        client: client,
        id: id,
        relayUrl: relayUrl,
        token: token,
        identity: identity,
      );
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _snack('转交失败: ${errorText(e)}');
    } finally {
      if (mounted &&
          _isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        setState(() => _reassigning = false);
      }
    }
  }

  Future<List<HandoffReassignCandidate>?> _loadReassignCandidates(
    Package p, {
    required int generation,
    required RelayClient client,
    required String id,
    required String relayUrl,
    required String token,
    required String identity,
  }) async {
    final target = p.deliveryTarget;
    if (target == null || target.isEmpty) return const [];
    ProjectDetail? project;
    OrganizationDetail? organization;
    try {
      final projectId = target.projectId.trim();
      if (projectId.isNotEmpty) {
        project = await client.project(projectId);
        if (!_isCurrentLoad(
          generation,
          client,
          id,
          relayUrl,
          token,
          identity,
        )) {
          return null;
        }
      }
      final orgId = target.orgId.trim().isNotEmpty
          ? target.orgId.trim()
          : (project?.project.orgId ?? '');
      if (orgId.isNotEmpty) {
        organization = await client.organization(orgId);
        if (!_isCurrentLoad(
          generation,
          client,
          id,
          relayUrl,
          token,
          identity,
        )) {
          return null;
        }
      }
    } catch (_) {
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return null;
      }
    }
    return handoffReassignCandidates(
      package: p,
      currentIdentity: identity,
      project: project,
      organization: organization,
    );
  }

  Future<void> _downloadAttachment(String name) async {
    final generation = _loadGeneration;
    final client = _client;
    final relayUrl = _cfg.relayUrl;
    final token = _cfg.token;
    final identity = _cfg.identity;
    final id = _id;
    try {
      final bytes = await client.attachment(id, name);
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File(handoffAttachmentTempPath(dir.path, name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      final res = await OpenFilex.open(file.path);
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      if (res.type != ResultType.done) _snack('已保存到 ${file.path}');
    } catch (e) {
      if (!mounted) return;
      if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity)) {
        return;
      }
      _snack('附件失败: ${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _pkg == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final p = _pkg!;
    final canReceive = canCurrentIdentityReceiveHandoff(
      package: p,
      status: _status,
      identity: _cfg.identity,
    );
    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(p),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '交付文档'),
              Tab(text: 'Prompt'),
              Tab(text: 'API'),
              Tab(text: '文件'),
              Tab(text: '评论'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _mdScroll(
                  p.summaryMd.isNotEmpty ? p.summaryMd : '_(无 summary)_',
                  extras: _summaryExtras(p),
                ),
                _tabPrompt(canReceive: canReceive),
                _tabApi(p),
                _tabFiles(p),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _commentsSection(p),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(Package p) {
    final canReceive = canCurrentIdentityReceiveHandoff(
      package: p,
      status: _status,
      identity: _cfg.identity,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.routeLabel(fallbackRecipient: _cfg.identity),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                chip(
                  p.repo.branch.isNotEmpty
                      ? '${p.repo.name} @ ${p.repo.branch}'
                      : p.repo.name,
                ),
                kindBadge(p.kind),
                if (p.urgency == 'urgent')
                  tag('urgent', CcColors.danger, bold: true),
                if (_status != null)
                  tag(_status!.state, _stateColor(_status!.state)),
              ],
            ),
            if (p.deliveryTarget != null) ...[
              const SizedBox(height: 10),
              _deliveryTargetPanel(p.deliveryTarget!),
            ],
            if (_status?.hasRecipientSlots == true) ...[
              const SizedBox(height: 10),
              _pickupStatusPanel(_status!),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canReceive && widget.onOpenTerminal != null)
                  FilledButton.icon(
                    onPressed: _picking ? null : () => _pickup(p),
                    icon: _picking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded),
                    label: Text(_picking ? '接收中…' : '接收并开终端'),
                  ),
                if (canReceive)
                  OutlinedButton.icon(
                    onPressed: _acking ? null : _ack,
                    icon: _acking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded, size: 18),
                    label: Text(_acking ? '标记中…' : '标记接收'),
                  ),
                if (sameIdentity(p.sender, _cfg.identity) &&
                    _status?.state == 'pending')
                  OutlinedButton.icon(
                    onPressed: _retracting || _retractDialogOpen
                        ? null
                        : () => _retract(p),
                    icon: _retracting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.undo_rounded, size: 18),
                    label: Text(_retracting ? '撤回中…' : '撤回'),
                  ),
                if (canReceive &&
                    p.kind == 'bug' &&
                    _status?.state == 'pending')
                  OutlinedButton.icon(
                    onPressed: _reassigning ? null : () => _reassign(p),
                    icon: _reassigning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.swap_horiz_rounded, size: 18),
                    label: Text(_reassigning ? '准备转交…' : '转交'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _deliveryTargetPanel(DeliveryTarget target) {
    final tokens = <Widget>[
      if (target.projectId.isNotEmpty) _targetToken('项目', target.projectId),
      if (target.orgId.isNotEmpty) _targetToken('团队', target.orgId),
      if (target.member.isNotEmpty) _targetToken('指定成员', target.member),
    ];
    return Tooltip(
      message: deliveryTargetLabel(target),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: CcColors.accent.withValues(alpha: 0.08),
          border: Border.all(color: CcColors.accent.withValues(alpha: 0.32)),
          borderRadius: BorderRadius.circular(CcRadius.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(
                Icons.groups_2_rounded,
                size: 18,
                color: CcColors.accentBright,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '团队定向',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: tokens),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _targetToken(String label, String value) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 280),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: CcColors.panelHigh,
        border: Border.all(color: CcColors.border),
        borderRadius: BorderRadius.circular(CcRadius.sm),
      ),
      child: Text(
        '$label · $value',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: CcType.mono,
          fontSize: 12,
          color: CcColors.text,
        ),
      ),
    ),
  );

  Widget _pickupStatusPanel(Status status) {
    final slots = status.pickupSlots;
    if (slots.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: CcColors.panelHigh,
        border: Border.all(color: CcColors.border),
        borderRadius: BorderRadius.circular(CcRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.fact_check_rounded,
              size: 18,
              color: CcColors.info,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '团队接收状态',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: slots.map(_pickupToken).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickupToken(RecipientPickupStatus slot) {
    final color = _stateColor(slot.state);
    final pickedSuffix = slot.pickedAt == null
        ? ''
        : ' · ${relativeTime(slot.pickedAt!)}';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Tooltip(
        message: '${slot.identity} · ${slot.state}$pickedSuffix',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            border: Border.all(color: color.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(CcRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              statusDot(color, size: 6, glow: slot.state == 'picked'),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  '${slot.identity} · ${slot.state}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: CcType.mono,
                    fontSize: 11.5,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mdScroll(String md, {Widget? extras}) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MarkdownBody(data: md, selectable: true),
        ?extras,
      ],
    ),
  );

  Widget? _summaryExtras(Package p) {
    final parts = <Widget>[];
    if (p.prdMd.isNotEmpty) parts.add(_mdSection('PRD', p.prdMd));
    if (p.noteMd.isNotEmpty) parts.add(_mdSection('发送者备注', p.noteMd));
    return parts.isEmpty
        ? null
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: parts);
  }

  Widget _mdSection(String title, String md) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        MarkdownBody(data: md, selectable: true),
      ],
    ),
  );

  Widget _tabPrompt({required bool canReceive}) {
    if (_prompt == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Wrap(
            children: [
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _prompt!));
                  _snack('已复制 Prompt');
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制 Prompt'),
              ),
              if (canReceive)
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: 'cc-handoff pickup $_id --worktree'),
                    );
                    _snack('已复制 pickup 命令');
                  },
                  icon: const Icon(Icons.terminal_rounded, size: 16),
                  label: const Text('复制 pickup 命令'),
                ),
              if (widget.onSendToTerminal != null)
                TextButton.icon(
                  onPressed: () {
                    widget.onSendToTerminal!(_prompt!);
                    _snack('已发送到终端');
                  },
                  icon: const Icon(Icons.keyboard_return_rounded, size: 16),
                  label: const Text('发送到终端'),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              data: _prompt!.isNotEmpty ? _prompt! : '_(无 prompt)_',
              selectable: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tabApi(Package p) {
    final d = p.apiDelta;
    if (d == null || d.isEmpty) return centerMsg('无 API 变更');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ..._apiSection('新增', d.added, CcColors.ok),
        ..._apiSection('变更', d.changed, CcColors.warning),
        ..._apiSection('删除', d.removed, CcColors.danger),
      ],
    );
  }

  List<Widget> _apiSection(String title, List<ApiOp> ops, Color c) {
    if (ops.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(
          title,
          style: TextStyle(fontWeight: FontWeight.bold, color: c),
        ),
      ),
      ...ops.map(
        (op) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              tag(op.method, c, bold: true),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  op.summary.isNotEmpty
                      ? '${op.path}  ·  ${op.summary}'
                      : op.path,
                  style: const TextStyle(fontFamily: CcType.mono, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
    ];
  }

  Widget _tabFiles(Package p) {
    final children = <Widget>[];
    if (p.modulePaths.isNotEmpty) {
      children.add(_filesHeader('模块路径'));
      children.addAll(
        p.modulePaths.map((m) => _fileRow(m, Icons.folder_rounded)),
      );
    }
    if (p.attachments.isNotEmpty) {
      children.add(_filesHeader('附件'));
      children.addAll(
        p.attachments.map(
          (a) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.attach_file_rounded, size: 18),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              _fmtBytes(a.size),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: CcColors.muted, fontSize: 11),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.download_rounded, size: 20),
              onPressed: () => _downloadAttachment(a.name),
            ),
          ),
        ),
      );
    }
    final git = p.git;
    if (git != null && git.commits.isNotEmpty) {
      children.add(_filesHeader('提交 (${git.commits.length})'));
      children.addAll(
        git.commits.map(
          (c) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              c.subject,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              c.sha.length > 8 ? c.sha.substring(0, 8) : c.sha,
              style: const TextStyle(
                color: CcColors.muted,
                fontFamily: CcType.mono,
                fontSize: 11,
              ),
            ),
          ),
        ),
      );
    }
    if (git != null && git.changedPaths.isNotEmpty) {
      children.add(_filesHeader('变更文件 (${git.changedPaths.length})'));
      children.addAll(
        git.changedPaths.map((f) => _fileRow(f, Icons.description_rounded)),
      );
    }
    if (children.isEmpty) return centerMsg('无文件 / 模块信息');
    return ListView(padding: const EdgeInsets.all(16), children: children);
  }

  Widget _filesHeader(String s) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _fileRow(String s, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Icon(icon, size: 16, color: CcColors.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            s,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: CcType.mono, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Widget _commentsSection(Package p) {
    final canComment = canCurrentIdentityCommentOnHandoff(
      package: p,
      status: _status,
      identity: _cfg.identity,
      me: widget.me,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('评论', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  onPressed: reloadComments,
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
              ],
            ),
            if (_comments.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('暂无评论', style: TextStyle(color: CcColors.muted)),
              )
            else
              ..._comments.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.sender,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            relativeTime(c.createdAt),
                            style: const TextStyle(
                              color: CcColors.muted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      SelectableText(c.body),
                    ],
                  ),
                ),
              ),
            if (canComment) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentCtl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '写评论…',
                        isDense: true,
                      ),
                      enabled: !_commenting,
                      onSubmitted: (_) => _postComment(),
                    ),
                  ),
                  IconButton(
                    onPressed: _commenting ? null : _postComment,
                    icon: _commenting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Color _stateColor(String s) {
    switch (s) {
      case 'picked':
        return CcColors.ok;
      case 'retracted':
      case 'expired':
        return CcColors.danger;
      case 'reassigned':
        return CcColors.warning;
      default:
        return CcColors.accent;
    }
  }
}

class _RetractDialog extends StatefulWidget {
  const _RetractDialog();

  @override
  State<_RetractDialog> createState() => _RetractDialogState();
}

class _RetractDialogState extends State<_RetractDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _reason.text);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('撤回协作任务', maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: handoffActionDialogWidth(size),
        child: SingleChildScrollView(
          child: TextField(
            controller: _reason,
            decoration: const InputDecoration(hintText: '原因(可选)'),
            onSubmitted: (_) => _submit(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('撤回')),
      ],
    );
  }
}

class _ReassignInput {
  final String to;
  final String reason;

  const _ReassignInput({required this.to, required this.reason});
}

class _ReassignDialog extends StatefulWidget {
  final List<HandoffReassignCandidate> candidates;
  const _ReassignDialog({required this.candidates});

  @override
  State<_ReassignDialog> createState() => _ReassignDialogState();
}

class _ReassignDialogState extends State<_ReassignDialog> {
  final _to = TextEditingController();
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _to.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final to = _to.text.trim();
    final reason = _reason.text.trim();
    if (to.isEmpty || reason.isEmpty) {
      setState(() => _error = '需填转交对象和原因');
      return;
    }
    if (!handoffReassignTargetAllowed(to, widget.candidates)) {
      setState(() => _error = '请选择团队候选，或输入候选里的成员 identity');
      return;
    }
    Navigator.pop(context, _ReassignInput(to: to, reason: reason));
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  void _selectCandidate(HandoffReassignCandidate candidate) {
    setState(() {
      _to.text = candidate.identity;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('转交 bug', maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: handoffActionDialogWidth(size),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.candidates.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '团队候选',
                    style: TextStyle(fontSize: 12, color: CcColors.muted),
                  ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: handoffReassignCandidateListMaxHeight(size),
                  ),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final candidate in widget.candidates)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: ActionChip(
                              label: Text(
                                candidate.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onPressed: () => _selectCandidate(candidate),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _to,
                decoration: const InputDecoration(labelText: '转交给(identity)'),
                onChanged: (_) => _clearError(),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(labelText: '原因'),
                onChanged: (_) => _clearError(),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: CcColors.danger,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('转交')),
      ],
    );
  }
}
