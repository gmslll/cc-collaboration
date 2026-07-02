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

class AccountPage extends StatefulWidget {
  final RelayClient client;
  final String identity;
  final VoidCallback? onSwitchAccount;
  const AccountPage({
    super.key,
    required this.client,
    required this.identity,
    this.onSwitchAccount,
  });

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _oldPw = TextEditingController();
  final _newPw = TextEditingController();
  final _label = TextEditingController();
  List<MachineToken>? _tokens;

  // local config.toml editor (desktop only).
  AppConfig? _cfg;
  final _relay = TextEditingController();
  final _cfgIdentity = TextEditingController();
  final _token = TextEditingController();
  String _agent = 'claude';
  String _terminalApp = ''; // '' = platform default
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
    def: true,
  );

  // Local-bus / session-id hooks self-check (desktop only). The app auto-installs
  // the PostToolUse+Stop hook into ~/.claude/settings.json + ~/.codex/hooks.json
  // on start; this shows whether they're actually present (e.g. on a fresh
  // machine) and offers a manual reinstall.
  List<({String name, String path, bool ok})>? _hooks;
  bool _reinstalling = false;

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
            ),
        ],
      );
    } catch (_) {
      if (mounted) setState(() => _hooks = const []);
    }
  }

  Future<void> _reinstallHooks() async {
    setState(() => _reinstalling = true);
    await Cli.installBusHooks();
    await _loadHookStatus();
    if (!mounted) return;
    setState(() => _reinstalling = false);
    final all = _hooks?.every((h) => h.ok) ?? false;
    snack(context, all ? 'hook 已安装' : 'hook 安装未全部成功,请检查 agent 是否已安装');
  }

  Future<void> _saveLocalConfig() async {
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
      );
      await _loadLocalConfig();
      if (mounted) snack(context, '已保存到 config.toml');
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _savingCfg = false);
    }
  }

  Future<void> _loadTokens() async {
    try {
      final t = await widget.client.tokens();
      if (mounted) setState(() => _tokens = t);
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _changePw() async {
    if (_newPw.text.length < 8) {
      snack(context, '新密码至少 8 位');
      return;
    }
    try {
      await widget.client.changePassword(_oldPw.text, _newPw.text);
      _oldPw.clear();
      _newPw.clear();
      if (mounted) snack(context, '密码已更新');
    } catch (e) {
      if (mounted) snack(context, '改密码失败: ${errorText(e)}');
    }
  }

  Future<void> _createToken() async {
    final label = _label.text.trim();
    if (label.isEmpty) return;
    try {
      final raw = await widget.client.createToken(label);
      _label.clear();
      await _loadTokens();
      if (mounted) _showToken(raw);
    } catch (e) {
      if (mounted) snack(context, '生成失败: ${errorText(e)}');
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
        // Version + build marker (confirm this device is current) + manual update
        // check. Apps ship via GitHub Releases, so update is in-app, not store.
        Row(
          children: [
            Expanded(
              child: Text(
                '版本 $kAppVersion · 构建 $kBuildMarker',
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
                    onPressed: _changePw,
                    child: const Text('更新密码'),
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
                      onPressed: _createToken,
                      child: const Text('生成'),
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
                  ..._tokens!.map(
                    (t) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(t.label.isEmpty ? '(无标签)' : t.label),
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
                        icon: const Icon(Icons.delete_rounded, size: 20),
                        onPressed: () async {
                          try {
                            await widget.client.deleteToken(t.id);
                            await _loadTokens();
                          } catch (e) {
                            if (context.mounted) snack(context, '$e');
                          }
                        },
                      ),
                    ),
                  ),
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
                  onPressed: _reinstalling ? null : _reinstallHooks,
                  icon: _reinstalling
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重新安装'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              '装进 claude/codex 配置,会话一开始就记录其 agent 会话 id,重启或换机后能精准恢复。'
              'macOS/Linux 另有 lsof 兜底;Windows 上的 codex 全靠它。开 app 会自动装,这里可手动补装。',
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

  Widget _hookRow(({String name, String path, bool ok}) h) {
    final color = h.ok ? CcColors.ok : CcColors.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            h.ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 52,
            child: Text(
              h.name,
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
            h.ok ? '已安装' : '未安装',
            style: TextStyle(fontSize: 11, color: color),
          ),
        ],
      ),
    );
  }

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
            Row(
              children: [
                const Text(
                  '默认 agent',
                  style: TextStyle(color: CcColors.muted, fontSize: 13),
                ),
                const Spacer(),
                DropdownButton<String>(
                  value: _agent,
                  items: const [
                    DropdownMenuItem(value: 'claude', child: Text('claude')),
                    DropdownMenuItem(value: 'codex', child: Text('codex')),
                    DropdownMenuItem(value: 'manual', child: Text('manual')),
                  ],
                  onChanged: (v) => setState(() => _agent = v ?? 'claude'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _cfgField(_claudeCmd, 'claude 启动命令(留空=自动找;绝对路径或命令)'),
            const SizedBox(height: 10),
            _cfgField(_codexCmd, 'codex 启动命令(留空=自动找;绝对路径或命令)'),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text(
                  '默认终端 App',
                  style: TextStyle(color: CcColors.muted, fontSize: 13),
                ),
                const Spacer(),
                DropdownButton<String>(
                  value: _terminalApp,
                  items: const [
                    DropdownMenuItem(value: '', child: Text('(默认)')),
                    DropdownMenuItem(
                      value: 'terminal',
                      child: Text('terminal'),
                    ),
                    DropdownMenuItem(value: 'iterm2', child: Text('iterm2')),
                    DropdownMenuItem(value: 'ghostty', child: Text('ghostty')),
                    DropdownMenuItem(
                      value: 'windows-terminal',
                      child: Text('windows-terminal'),
                    ),
                    DropdownMenuItem(
                      value: 'powershell',
                      child: Text('powershell'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _terminalApp = v ?? ''),
                ),
              ],
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
