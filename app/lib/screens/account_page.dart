import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../theme.dart';
import '../ui_scale.dart';
import '../widgets.dart';

class AccountPage extends StatefulWidget {
  final RelayClient client;
  final String identity;
  const AccountPage({super.key, required this.client, required this.identity});

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
  final _wsRoot = TextEditingController();
  final _grade = TextEditingController();
  final _linear = TextEditingController();
  final _github = TextEditingController();
  bool _savingCfg = false;

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _loadTokens();
    _loadLocalConfig();
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
      _wsRoot.text = c.workspaceRoot;
      _grade.text = c.gradeCommand;
      _linear.text = c.linearToken;
      _github.text = c.githubToken;
    });
  }

  Future<void> _saveLocalConfig() async {
    setState(() => _savingCfg = true);
    try {
      await Cli.configSet(
        relayUrl: _relay.text.trim(),
        identity: _cfgIdentity.text.trim(),
        token: _token.text.trim(),
        agent: _agent,
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
        if (_isDesktop && _cfg != null) ...[
          const SizedBox(height: 16),
          _localConfigCard(),
        ],
      ],
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
