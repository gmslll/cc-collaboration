import 'package:flutter/material.dart';

import '../local/repo_config.dart';
import '../theme.dart';
import '../widgets.dart';

// RepoConfigPage edits a project's repo-level `.cc-handoff.toml` (all fields).
// Pure Dart read/write via RepoConfig; opened from the workspace tree's project
// ⋮ menu. Form bindings write straight into the RepoConfig model (onChanged),
// so Save just persists it.
class RepoConfigPage extends StatefulWidget {
  final String projectPath;
  final String projectName;
  const RepoConfigPage(
      {super.key, required this.projectPath, required this.projectName});

  @override
  State<RepoConfigPage> createState() => _RepoConfigPageState();
}

class _RepoConfigPageState extends State<RepoConfigPage> {
  RepoConfig? _c;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await RepoConfig.load(widget.projectPath);
    if (mounted) setState(() => _c = c);
  }

  Future<void> _save() async {
    final c = _c;
    if (c == null) return;
    setState(() => _saving = true);
    try {
      await c.save(widget.projectPath);
      if (mounted) {
        snack(context, '已保存 .cc-handoff.toml');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: Text('项目配置 · ${widget.projectName}'),
        actions: [
          if (c != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_rounded, size: 18),
                label: const Text('保存'),
              ),
            ),
        ],
      ),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : DecoratedBox(
              decoration: appGradient,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  Text(RepoConfig.pathFor(widget.projectPath),
                      style: const TextStyle(
                          fontFamily: CcType.mono,
                          color: CcColors.subtle,
                          fontSize: 11)),
                  const SizedBox(height: 12),
                  _card('身份', [
                    _text('me(覆盖用户 identity,可空)', c.me, (v) => c.me = v),
                    _text('partner(主接收人)', c.partner, (v) => c.partner = v),
                    _text('partners(多接收人,逗号分隔)', c.partners,
                        (v) => c.partners = v),
                  ]),
                  _card('路径', [
                    _text('base(git base ref)', c.base, (v) => c.base = v,
                        hint: 'origin/main'),
                    _text('swagger(OpenAPI 路径)', c.swagger,
                        (v) => c.swagger = v, hint: 'docs/swagger.yaml'),
                    _text('repo(显示名)', c.repo, (v) => c.repo = v),
                  ]),
                  _rulesCard(c),
                  _triggersCard(c),
                  _card('收件箱', [
                    _text('inbox dir(物化输出目录,可空)', c.inboxDir,
                        (v) => c.inboxDir = v),
                  ]),
                  _linearCard(c),
                ],
              ),
            ),
    );
  }

  // ---- field helpers (bind directly into the model) ----

  Widget _card(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  ...children,
                ]),
          ),
        ),
      );

  Widget _text(String label, String initial, ValueChanged<String> onChanged,
          {String? hint}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          initialValue: initial,
          onChanged: onChanged,
          autocorrect: false,
          style: const TextStyle(fontFamily: CcType.mono, fontSize: 14),
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontSize: 13)),
        value: value,
        onChanged: onChanged,
      );

  Widget _dropdown(String label, String value, List<String> opts,
      ValueChanged<String> onChanged) {
    final all = ['', ...opts];
    final v = all.contains(value) ? value : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: CcColors.muted))),
        DropdownButton<String>(
          value: v,
          items: all
              .map((o) => DropdownMenuItem(
                  value: o, child: Text(o.isEmpty ? '(默认)' : o)))
              .toList(),
          onChanged: (x) => onChanged(x ?? ''),
        ),
      ]),
    );
  }

  Widget _triggersCard(RepoConfig c) => _card('触发(自动起 agent / 行为)', [
        _switch('auto_launch(收到自动起 agent)', c.autoLaunch,
            (v) => setState(() => c.autoLaunch = v)),
        _switch('auto_launch_normal(普通优先级也起)', c.autoLaunchNormal,
            (v) => setState(() => c.autoLaunchNormal = v)),
        _switch('auto_launch_on_alert(日志告警也起)', c.autoLaunchOnAlert,
            (v) => setState(() => c.autoLaunchOnAlert = v)),
        _switch('wake_on_comment(对方回复唤回会话)', c.wakeOnComment,
            (v) => setState(() => c.wakeOnComment = v)),
        _switch('launch_interactive(交互 REPL 而非一次性)', c.launchInteractive,
            (v) => setState(() => c.launchInteractive = v)),
        _switch('mute_user_presence(静音上下线通知)', c.muteUserPresence,
            (v) => setState(() => c.muteUserPresence = v)),
        const SizedBox(height: 6),
        _dropdown('terminal_app', c.terminalApp,
            const ['terminal', 'iterm2', 'windows-terminal', 'powershell'],
            (v) => setState(() => c.terminalApp = v)),
        _dropdown('launch_mode', c.launchMode, const ['window', 'split'],
            (v) => setState(() => c.launchMode = v)),
        _dropdown(
            'ack_on_launch',
            c.ackOnLaunch,
            const ['never', 'after_exit', 'on_launch', 'slash_pickup'],
            (v) => setState(() => c.ackOnLaunch = v)),
        const SizedBox(height: 8),
        _text('pre_launch(起 agent 前跑的 shell)', c.preLaunch,
            (v) => c.preLaunch = v, hint: 'nvm use 18'),
      ]);

  Widget _linearCard(RepoConfig c) => _card('Linear 集成', [
        _switch('enabled', c.linearEnabled,
            (v) => setState(() => c.linearEnabled = v)),
        _text('team_key', c.teamKey, (v) => c.teamKey = v),
        _text('default_labels(逗号分隔)', c.defaultLabels,
            (v) => c.defaultLabels = v),
        _text('mcp_prefix', c.mcpPrefix, (v) => c.mcpPrefix = v),
        _switch('sync_on_submit', c.syncOnSubmit,
            (v) => setState(() => c.syncOnSubmit = v)),
        _switch('sync_on_pickup', c.syncOnPickup,
            (v) => setState(() => c.syncOnPickup = v)),
        _switch('sync_on_comment', c.syncOnComment,
            (v) => setState(() => c.syncOnComment = v)),
        _switch('sync_on_retract', c.syncOnRetract,
            (v) => setState(() => c.syncOnRetract = v)),
        const SizedBox(height: 8),
        _text('notifications.poll_interval', c.pollInterval,
            (v) => c.pollInterval = v, hint: '5m'),
        _text('notifications.types(逗号分隔)', c.types, (v) => c.types = v),
      ]);

  Widget _rulesCard(RepoConfig c) => _card('partner_mapping 规则', [
        if (c.rules.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('无规则',
                style: TextStyle(color: CcColors.muted, fontSize: 12)),
          ),
        ...c.rules.map((r) => Padding(
              key: ObjectKey(r),
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                decoration: BoxDecoration(
                  border: Border.all(color: CcColors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Expanded(
                            child: Text('规则',
                                style: TextStyle(
                                    fontSize: 12, color: CcColors.muted))),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          tooltip: '删除规则',
                          onPressed: () => setState(
                              () => c.rules = c.rules.where((x) => x != r).toList()),
                        ),
                      ]),
                      TextFormField(
                        initialValue: r.whenPathMatches,
                        onChanged: (v) => r.whenPathMatches = v,
                        autocorrect: false,
                        style:
                            const TextStyle(fontFamily: CcType.mono, fontSize: 12),
                        decoration: const InputDecoration(
                            labelText: 'when_path_matches(正则)',
                            isDense: true),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: r.suggestEdit,
                        onChanged: (v) => r.suggestEdit = v,
                        autocorrect: false,
                        style:
                            const TextStyle(fontFamily: CcType.mono, fontSize: 12),
                        decoration: const InputDecoration(
                            labelText: 'suggest_edit(逗号分隔)', isDense: true),
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('suggest_create_if_missing',
                            style: TextStyle(fontSize: 13)),
                        value: r.suggestCreate,
                        onChanged: (v) => setState(() => r.suggestCreate = v),
                      ),
                    ]),
              ),
            )),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => c.rules = [...c.rules, RuleCfg()]),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('加规则'),
          ),
        ),
      ]);
}
