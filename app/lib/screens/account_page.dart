import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../build_info.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../local/prefs.dart';
import '../local/remote_prefs.dart';
import '../local/update_service.dart';
import '../theme.dart';
import '../ui_scale.dart';
import '../widgets.dart';

typedef HookInstallStatus = ({
  String name,
  String path,
  bool ok,
  List<String> availableEvents,
  List<String> installedEvents,
  List<String> missingEvents,
});

double accountMenuMaxHeight(
  Size screenSize, {
  double preferred = 320,
  double minHeight = 160,
  double maxFraction = 0.58,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

double accountDialogWidth(
  Size screenSize, {
  double preferred = 420,
  double horizontalInset = 16,
}) {
  final available = screenSize.width - horizontalInset * 2;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

double accountHookEventListMaxHeight(
  Size screenSize, {
  double preferred = 460,
  double minHeight = 160,
  double maxFraction = 0.62,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

class AccountPage extends StatefulWidget {
  final RelayClient client;
  final String identity;
  final VoidCallback? onSwitchAccount;
  final VoidCallback? onConfigSaved;
  const AccountPage({
    super.key,
    required this.client,
    required this.identity,
    this.onSwitchAccount,
    this.onConfigSaved,
  });

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _oldPw = TextEditingController();
  final _newPw = TextEditingController();
  final _label = TextEditingController();
  List<MachineToken>? _tokens;
  bool _changingPw = false;
  bool _creatingToken = false;
  final Set<String> _deletingTokenIds = {};
  int _tokenLoadGeneration = 0;

  // local config.toml editor (desktop only).
  AppConfig? _cfg;
  final _relay = TextEditingController();
  final _cfgIdentity = TextEditingController();
  final _token = TextEditingController();
  String _agent = 'claude';
  String _terminalApp = ''; // '' = platform default
  bool _publishSessions = false;
  final _wsRoot = TextEditingController();
  final _grade = TextEditingController();
  final _linear = TextEditingController();
  final _github = TextEditingController();
  final _claudeCmd = TextEditingController();
  final _codexCmd = TextEditingController();
  bool _savingCfg = false;

  // Phone: tap a session card → open the full terminal (default) or first show
  // the quick-reply preview popup. Persisted; read live by the remote workspace.
  bool _tapPreview = Prefs.getBool('remote.tapPreview');
  bool _showRemoteSessionContent = Prefs.getBool(
    kRemoteShowSessionContentPref,
    def: kRemoteShowSessionContentDefault,
  );

  // Local-bus / session-id hooks self-check (desktop only). The app auto-installs
  // the lifecycle bus hook into ~/.claude/settings.json + ~/.codex/hooks.json
  // on start; this shows whether they're actually present (e.g. on a fresh
  // machine) and offers a manual reinstall.
  List<HookInstallStatus>? _hooks;
  bool _reinstalling = false;
  final Set<String> _reinstallingAgents = {};

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _loadTokens();
    _loadLocalConfig();
    _loadHookStatus();
  }

  @override
  void didUpdateWidget(covariant AccountPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.client, widget.client) &&
        oldWidget.identity == widget.identity) {
      return;
    }
    _tokenLoadGeneration++;
    _oldPw.clear();
    _newPw.clear();
    _label.clear();
    setState(() {
      _tokens = null;
      _changingPw = false;
      _creatingToken = false;
      _deletingTokenIds.clear();
    });
    _loadTokens();
  }

  @override
  void dispose() {
    _oldPw.dispose();
    _newPw.dispose();
    _label.dispose();
    _relay.dispose();
    _cfgIdentity.dispose();
    _token.dispose();
    _wsRoot.dispose();
    _grade.dispose();
    _linear.dispose();
    _github.dispose();
    _claudeCmd.dispose();
    _codexCmd.dispose();
    super.dispose();
  }

  Future<void> _loadLocalConfig() async {
    if (!_isDesktop) return;
    final c = await AppConfig.load();
    if (c == null || !mounted) return;
    setState(() {
      _cfg = c;
      _relay.text = c.relayUrl;
      _cfgIdentity.text = c.identity;
      _token.text = c.token;
      _agent = c.agent.isEmpty ? 'claude' : c.agent;
      _terminalApp = c.terminalApp;
      _publishSessions = c.publishSessions;
      _wsRoot.text = c.workspaceRoot;
      _grade.text = c.gradeCommand;
      _linear.text = c.linearToken;
      _github.text = c.githubToken;
      _claudeCmd.text = c.claudeCommand;
      _codexCmd.text = c.codexCommand;
    });
  }

  // _loadHookStatus asks the cc-handoff CLI which agents have the bus/session-id
  // hook installed (`bus-hook status`), so the config paths + "installed"
  // criterion stay owned by Go (the installer) and can't drift from this UI.
  Future<void> _loadHookStatus() async {
    if (!_isDesktop) return;
    try {
      final out = await Cli.run(['bus-hook', 'status']);
      final list = (jsonDecode(out) as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(
        () => _hooks = [
          for (final h in list)
            (
              name: (h['agent'] ?? '').toString(),
              path: (h['path'] ?? '').toString(),
              ok: h['installed'] == true,
              availableEvents: _stringList(h['available_events']),
              installedEvents: _stringList(h['installed_events']),
              missingEvents: _stringList(h['missing_events']),
            ),
        ],
      );
    } catch (_) {
      if (mounted) setState(() => _hooks = const []);
    }
  }

  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    return [for (final x in v) x.toString()];
  }

  Future<bool> _reinstallHooks({String? agent, List<String>? events}) async {
    setState(() {
      if (agent == null) {
        _reinstalling = true;
      } else {
        _reinstallingAgents.add(agent);
      }
    });
    Object? installError;
    try {
      await Cli.installBusHooks(
        agents: agent == null ? const [] : [agent],
        events: events,
        throwOnError: true,
      );
    } catch (e) {
      installError = e;
    }
    await _loadHookStatus();
    if (!mounted) return false;
    setState(() {
      if (agent == null) {
        _reinstalling = false;
      } else {
        _reinstallingAgents.remove(agent);
      }
    });
    final ok = agent == null
        ? (_hooks?.every((h) => h.ok) ?? false)
        : (_hooks?.any((h) {
                if (h.name != agent) return false;
                if (events == null) return h.ok;
                final installed = h.installedEvents.toSet();
                final selected = events.toSet();
                return installed.length == selected.length &&
                    selected.every(installed.contains);
              }) ??
              false);
    snack(
      context,
      ok
          ? 'hook 已安装'
          : installError == null
          ? 'hook 安装未成功,请检查 agent 是否已安装'
          : errorText(installError),
    );
    return ok;
  }

  Future<void> _chooseHookEvents(HookInstallStatus h) async {
    final available = h.availableEvents;
    if (available.isEmpty) {
      snack(context, '${h.name} 没有可选择的 hook 列表');
      return;
    }
    final selected = <String>{
      ...(h.installedEvents.isEmpty ? available : h.installedEvents),
    };
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Text(
              '选择 ${h.name} hook',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            content: SizedBox(
              width: accountDialogWidth(MediaQuery.sizeOf(ctx)),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: accountHookEventListMaxHeight(
                    MediaQuery.sizeOf(ctx),
                  ),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const Text(
                      '只会安装勾选的 cc-handoff hook；未勾选项里的 cc-handoff hook 会移除，用户自己的其它 hook 不会动。',
                      style: TextStyle(color: CcColors.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    for (final ev in available)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: selected.contains(ev),
                        title: Text(
                          ev,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(size: 12.5),
                        ),
                        onChanged: (v) => setDialogState(() {
                          if (v == true) {
                            selected.add(ev);
                          } else {
                            selected.remove(ev);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  final stopOnly = available.contains('Stop')
                      ? const ['Stop']
                      : [available.first];
                  Navigator.pop(ctx, stopOnly);
                },
                child: const Text('只装 Stop'),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, selected.toList()),
                child: const Text('安装所选'),
              ),
            ],
          );
        },
      ),
    );
    if (picked == null || picked.isEmpty) return;
    if (!mounted) return;
    final ok = await _reinstallHooks(agent: h.name, events: picked);
    if (ok) {
      Prefs.setString('busHook.events.${h.name}', jsonEncode(picked));
    }
  }

  Future<void> _saveLocalConfig() async {
    if (_savingCfg) return;
    setState(() => _savingCfg = true);
    try {
      await Cli.configSet(
        relayUrl: _relay.text.trim(),
        identity: _cfgIdentity.text.trim(),
        token: _token.text.trim(),
        agent: _agent,
        claudeCommand: _claudeCmd.text.trim(),
        codexCommand: _codexCmd.text.trim(),
        terminalApp: _terminalApp,
        workspaceRoot: _wsRoot.text.trim(),
        gradeCommand: _grade.text.trim(),
        linearToken: _linear.text.trim(),
        githubToken: _github.text.trim(),
        publishSessions: _publishSessions,
      );
      await _loadLocalConfig();
      if (!mounted) return;
      widget.onConfigSaved?.call();
      snack(context, '已保存到 config.toml');
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _savingCfg = false);
    }
  }

  bool _isCurrentClient(RelayClient client) =>
      mounted && identical(client, widget.client);

  bool _isCurrentTokenLoad(int generation, RelayClient client) =>
      _isCurrentClient(client) && generation == _tokenLoadGeneration;

  Future<void> _loadTokens([RelayClient? capturedClient]) async {
    final generation = ++_tokenLoadGeneration;
    final client = capturedClient ?? widget.client;
    try {
      final t = await client.tokens();
      if (_isCurrentTokenLoad(generation, client)) {
        setState(() => _tokens = t);
      }
    } catch (e) {
      if (!mounted ||
          !identical(client, widget.client) ||
          generation != _tokenLoadGeneration) {
        return;
      }
      snack(context, errorText(e));
    }
  }

  Future<void> _changePw() async {
    if (_changingPw) return;
    if (_newPw.text.length < 8) {
      snack(context, '新密码至少 8 位');
      return;
    }
    final client = widget.client;
    final oldPw = _oldPw.text;
    final newPw = _newPw.text;
    setState(() => _changingPw = true);
    try {
      await client.changePassword(oldPw, newPw);
      if (!mounted || !identical(client, widget.client)) return;
      _oldPw.clear();
      _newPw.clear();
      snack(context, '密码已更新');
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, '改密码失败: ${errorText(e)}');
    } finally {
      if (_isCurrentClient(client)) {
        setState(() => _changingPw = false);
      }
    }
  }

  Future<void> _createToken() async {
    final label = _label.text.trim();
    if (label.isEmpty || _creatingToken) return;
    final client = widget.client;
    setState(() => _creatingToken = true);
    try {
      final raw = await client.createToken(label);
      if (!_isCurrentClient(client)) return;
      _label.clear();
      await _loadTokens(client);
      if (!mounted || !identical(client, widget.client)) return;
      _showToken(raw);
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, '生成失败: ${errorText(e)}');
    } finally {
      if (_isCurrentClient(client)) {
        setState(() => _creatingToken = false);
      }
    }
  }

  Future<void> _deleteToken(MachineToken token) async {
    if (_deletingTokenIds.contains(token.id)) return;
    final client = widget.client;
    final tokenId = token.id;
    setState(() => _deletingTokenIds.add(token.id));
    final label = token.label.trim().isEmpty ? token.id : token.label.trim();
    final ok = await confirm(
      context,
      '删除机器 token $label？已部署到 CLI / watch / MCP 的机器会失去访问权限。',
      title: '删除机器 token',
      okLabel: '删除',
    );
    if (!_isCurrentClient(client)) return;
    if (!ok) {
      setState(() => _deletingTokenIds.remove(tokenId));
      return;
    }
    try {
      await client.deleteToken(tokenId);
      if (!_isCurrentClient(client)) return;
      await _loadTokens(client);
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, '$e');
    } finally {
      if (_isCurrentClient(client)) {
        setState(() => _deletingTokenIds.remove(tokenId));
      }
    }
  }

  void _showToken(String raw) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('机器 token(只显示一次)'),
        content: SelectableText(
          raw,
          style: const TextStyle(fontFamily: CcType.mono),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: raw)),
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '账号 · ${widget.identity}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: widget.onSwitchAccount,
            icon: const Icon(Icons.switch_account_rounded, size: 18),
            label: const Text('切换账号'),
          ),
        ),
        const SizedBox(height: 4),
        // Apps ship via GitHub Releases, so update is in-app, not store.
        Row(
          children: [
            Expanded(
              child: Text(
                '版本 $kAppVersion',
                style: const TextStyle(color: CcColors.subtle, fontSize: 11),
              ),
            ),
            TextButton.icon(
              onPressed: () => checkForUpdatesUi(context, silent: false),
              icon: const Icon(Icons.system_update_alt_rounded, size: 16),
              label: const Text('检查更新'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '界面缩放(整体大小)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '调小可不全屏看全 UI · 快捷键 ⌘+ / ⌘- / ⌘0',
                  style: TextStyle(color: CcColors.muted, fontSize: 12),
                ),
                ValueListenableBuilder<double>(
                  valueListenable: uiScale,
                  builder: (_, s, _) => Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: s,
                          min: uiScaleMin,
                          max: uiScaleMax,
                          divisions: ((uiScaleMax - uiScaleMin) / 0.05).round(),
                          label: '${(s * 100).round()}%',
                          onChanged: setUiScale,
                        ),
                      ),
                      SizedBox(width: 44, child: Text('${(s * 100).round()}%')),
                      TextButton(
                        onPressed: resetUiScale,
                        child: const Text('复位'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '改密码',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _oldPw,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '当前密码',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _newPw,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '新密码(≥8 位)',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _changingPw ? null : _changePw,
                    child: Text(_changingPw ? '更新中' : '更新密码'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '机器 token(给 CLI / watch / MCP)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _label,
                        decoration: const InputDecoration(
                          hintText: '标签(如 laptop)',
                          isDense: true,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _creatingToken ? null : _createToken,
                      child: Text(_creatingToken ? '生成中' : '生成'),
                    ),
                  ],
                ),
                const Divider(),
                if (_tokens == null)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: LinearProgressIndicator(),
                  )
                else if (_tokens!.isEmpty)
                  const Text('暂无', style: TextStyle(color: CcColors.muted))
                else
                  ..._tokens!.map((t) {
                    final deleting = _deletingTokenIds.contains(t.id);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        t.label.isEmpty ? '(无标签)' : t.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        t.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CcColors.muted,
                          fontSize: 11,
                        ),
                      ),
                      trailing: IconButton(
                        icon: deleting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.delete_rounded, size: 20),
                        tooltip: '删除机器 token',
                        onPressed: deleting ? null : () => _deleteToken(t),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        if (!_isDesktop) ...[
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _showRemoteSessionContent,
                  onChanged: (v) {
                    Prefs.setBool(kRemoteShowSessionContentPref, v);
                    setState(() => _showRemoteSessionContent = v);
                  },
                  title: const Text('显示会话内容'),
                  subtitle: const Text(
                    '关闭后远程会话页只显示概况，不展示最近输出内容。',
                    style: TextStyle(color: CcColors.muted, fontSize: 12),
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: _tapPreview,
                  onChanged: (v) {
                    Prefs.setBool('remote.tapPreview', v);
                    setState(() => _tapPreview = v);
                  },
                  title: const Text('点击会话先弹快捷预览'),
                  subtitle: const Text(
                    '默认点击会话直接进终端；开启后先弹快捷预览/回复，弹窗里再「打开终端」',
                    style: TextStyle(color: CcColors.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_isDesktop) ...[const SizedBox(height: 16), _hookStatusCard()],
        if (_isDesktop && _cfg != null) ...[
          const SizedBox(height: 16),
          _localConfigCard(),
        ],
      ],
    );
  }

  Widget _hookStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '会话 hook(精准恢复会话 id)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton.icon(
                  onPressed: _reinstalling || _reinstallingAgents.isNotEmpty
                      ? null
                      : _reinstallAllHooks,
                  icon: _reinstalling
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('全量重装'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              '装进 claude/codex 配置,会话一开始就记录其 agent 会话 id,重启或换机后能精准恢复。'
              'macOS/Linux 另有 lsof 兜底;Windows 上的 codex 全靠它。开 app 会自动装,这里可手动补装;每行可选择只安装部分 hook。',
              style: TextStyle(color: CcColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            if (_hooks == null)
              const Padding(
                padding: EdgeInsets.all(4),
                child: LinearProgressIndicator(),
              )
            else
              ..._hooks!.map(_hookRow),
          ],
        ),
      ),
    );
  }

  Future<void> _reinstallAllHooks() async {
    final ok = await _reinstallHooks();
    if (!ok) return;
    Prefs.removeAll(const ['busHook.events.claude', 'busHook.events.codex']);
  }

  Widget _hookRow(HookInstallStatus h) {
    final installedCount = h.installedEvents.length;
    final totalCount = h.availableEvents.length;
    final partial = installedCount > 0 && !h.ok;
    final color = h.ok
        ? CcColors.ok
        : partial
        ? CcColors.warning
        : CcColors.danger;
    final installing = _reinstallingAgents.contains(h.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            h.ok
                ? Icons.check_circle_rounded
                : partial
                ? Icons.adjust_rounded
                : Icons.cancel_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 52,
            child: Text(
              h.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              h.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: CcColors.subtle,
                fontSize: 11,
                fontFamily: CcType.mono,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            totalCount == 0
                ? (h.ok ? '已安装' : '未安装')
                : h.ok
                ? '已安装 $installedCount/$totalCount'
                : installedCount == 0
                ? '未安装'
                : '部分 $installedCount/$totalCount',
            style: TextStyle(fontSize: 11, color: color),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: _reinstalling || installing
                ? null
                : () => _chooseHookEvents(h),
            child: installing
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('选择安装'),
          ),
        ],
      ),
    );
  }

  Widget _settingDropdownRow({
    required String label,
    required Widget child,
    double maxWidth = 150,
  }) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(color: CcColors.muted, fontSize: 13),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: child,
            ),
          ),
        ),
      ],
    );
  }

  Widget _dropdownText(String text) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);

  DropdownMenuItem<String> _dropdownItem(String value, String label) =>
      DropdownMenuItem(value: value, child: _dropdownText(label));

  Widget _localConfigCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '本地配置 · config.toml',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _settingDropdownRow(
              label: '默认 agent',
              child: DropdownButton<String>(
                isExpanded: true,
                value: _agent,
                menuMaxHeight: accountMenuMaxHeight(MediaQuery.sizeOf(context)),
                selectedItemBuilder: (_) => [
                  _dropdownText('claude'),
                  _dropdownText('codex'),
                  _dropdownText('manual'),
                ],
                items: [
                  _dropdownItem('claude', 'claude'),
                  _dropdownItem('codex', 'codex'),
                  _dropdownItem('manual', 'manual'),
                ],
                onChanged: (v) => setState(() => _agent = v ?? 'claude'),
              ),
            ),
            const SizedBox(height: 10),
            _cfgField(_claudeCmd, 'claude 启动命令(留空=自动找;绝对路径或命令)'),
            const SizedBox(height: 10),
            _cfgField(_codexCmd, 'codex 启动命令(留空=自动找;绝对路径或命令)'),
            const SizedBox(height: 8),
            _settingDropdownRow(
              label: '默认终端 App',
              maxWidth: 190,
              child: DropdownButton<String>(
                isExpanded: true,
                value: _terminalApp,
                menuMaxHeight: accountMenuMaxHeight(MediaQuery.sizeOf(context)),
                selectedItemBuilder: (_) => [
                  _dropdownText('(默认)'),
                  _dropdownText('terminal'),
                  _dropdownText('iterm2'),
                  _dropdownText('ghostty'),
                  _dropdownText('windows-terminal'),
                  _dropdownText('powershell'),
                ],
                items: [
                  _dropdownItem('', '(默认)'),
                  _dropdownItem('terminal', 'terminal'),
                  _dropdownItem('iterm2', 'iterm2'),
                  _dropdownItem('ghostty', 'ghostty'),
                  _dropdownItem('windows-terminal', 'windows-terminal'),
                  _dropdownItem('powershell', 'powershell'),
                ],
                onChanged: (v) => setState(() => _terminalApp = v ?? ''),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _publishSessions,
              onChanged: (v) => setState(() => _publishSessions = v),
              title: const Text('公开在线会话'),
              subtitle: const Text(
                '关闭时其他在线用户只能看到你在线，不能看到或选择你的本机会话。',
                style: TextStyle(color: CcColors.muted, fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            _cfgField(_wsRoot, 'workspace_root(工作区根目录)'),
            const SizedBox(height: 10),
            _cfgField(_grade, 'grade_command(日志分级命令)'),
            const Divider(height: 26),
            const Text(
              '连接',
              style: TextStyle(
                color: CcColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _cfgField(_relay, 'relay_url'),
            const SizedBox(height: 10),
            _cfgField(_cfgIdentity, 'identity'),
            const SizedBox(height: 10),
            _cfgField(_token, 'token', obscure: true),
            const SizedBox(height: 6),
            const Text(
              '改连接只写进 config.toml;当前会话需登出重登才生效。',
              style: TextStyle(color: CcColors.subtle, fontSize: 11),
            ),
            const Divider(height: 26),
            const Text(
              '集成',
              style: TextStyle(
                color: CcColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _cfgField(_linear, 'linear_personal_token', obscure: true),
            const SizedBox(height: 10),
            _cfgField(_github, 'github_token(看 PR / diff)', obscure: true),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _savingCfg ? null : _saveLocalConfig,
                child: _savingCfg
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存到 config.toml'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cfgField(
    TextEditingController c,
    String label, {
    bool obscure = false,
  }) => TextField(
    controller: c,
    obscureText: obscure,
    autocorrect: false,
    style: const TextStyle(fontFamily: CcType.mono, fontSize: 14),
    decoration: InputDecoration(labelText: label),
  );
}
