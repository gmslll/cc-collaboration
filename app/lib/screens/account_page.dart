import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../theme.dart';
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

  @override
  void initState() {
    super.initState();
    _loadTokens();
  }

  @override
  void dispose() {
    _oldPw.dispose();
    _newPw.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _loadTokens() async {
    try {
      final t = await widget.client.tokens();
      if (mounted) setState(() => _tokens = t);
    } catch (e) {
      if (mounted) snack(context, '$e');
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
      if (mounted) snack(context, '改密码失败: $e');
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
      if (mounted) snack(context, '生成失败: $e');
    }
  }

  void _showToken(String raw) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('机器 token(只显示一次)'),
        content: SelectableText(raw, style: const TextStyle(fontFamily: 'monospace')),
        actions: [
          TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: raw)),
              child: const Text('复制')),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('账号 · ${widget.identity}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('改密码', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
                controller: _oldPw,
                obscureText: true,
                decoration: const InputDecoration(labelText: '当前密码', isDense: true)),
            const SizedBox(height: 8),
            TextField(
                controller: _newPw,
                obscureText: true,
                decoration:
                    const InputDecoration(labelText: '新密码(≥8 位)', isDense: true)),
            const SizedBox(height: 12),
            Align(
                alignment: Alignment.centerRight,
                child: FilledButton(onPressed: _changePw, child: const Text('更新密码'))),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('机器 token(给 CLI / watch / MCP)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _label,
                      decoration: const InputDecoration(
                          hintText: '标签(如 laptop)', isDense: true))),
              TextButton(onPressed: _createToken, child: const Text('生成')),
            ]),
            const Divider(),
            if (_tokens == null)
              const Padding(
                  padding: EdgeInsets.all(8), child: LinearProgressIndicator())
            else if (_tokens!.isEmpty)
              const Text('暂无', style: TextStyle(color: CcColors.muted))
            else
              ..._tokens!.map((t) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.label.isEmpty ? '(无标签)' : t.label),
                    subtitle: Text(t.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: CcColors.muted, fontSize: 11)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () async {
                        try {
                          await widget.client.deleteToken(t.id);
                          await _loadTokens();
                        } catch (e) {
                          if (context.mounted) snack(context, '$e');
                        }
                      },
                    ),
                  )),
          ]),
        ),
      ),
    ]);
  }
}
