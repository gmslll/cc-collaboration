import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../theme.dart';
import '../widgets.dart';

class AdminPage extends StatefulWidget {
  final RelayClient client;
  const AdminPage({super.key, required this.client});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  List<User>? _users;
  String? _error;
  final _identity = TextEditingController();
  final _password = TextEditingController();
  bool _newAdmin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _identity.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final u = await widget.client.users();
      if (mounted) {
        setState(() {
          _users = u;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _create() async {
    final id = _identity.text.trim();
    if (id.isEmpty) return;
    try {
      final pw = await widget.client.createUser(
        id,
        password: _password.text.trim(),
        isAdmin: _newAdmin,
      );
      _identity.clear();
      _password.clear();
      setState(() => _newAdmin = false);
      await _load();
      if (pw != null && pw.isNotEmpty && mounted) {
        _showSecret('账号 $id 的初始密码', pw);
      }
    } catch (e) {
      if (mounted) snack(context, '创建失败: ${errorText(e)}');
    }
  }

  Future<void> _act(Future<void> Function() f) async {
    try {
      await f();
      await _load();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  void _showSecret(String title, String secret) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SelectableText(
          secret,
          style: const TextStyle(fontFamily: CcType.mono),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
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
        const Text(
          '管理员 · 身份与访问',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '创建内部账号',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _identity,
                  decoration: const InputDecoration(
                    labelText: 'identity(如 alex@frontend)',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _password,
                  decoration: const InputDecoration(
                    labelText: '初始密码(留空自动生成)',
                    isDense: true,
                  ),
                ),
                Row(
                  children: [
                    Checkbox(
                      value: _newAdmin,
                      onChanged: (v) => setState(() => _newAdmin = v ?? false),
                    ),
                    const Text('admin'),
                    const Spacer(),
                    FilledButton(onPressed: _create, child: const Text('创建账号')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: CcColors.danger))
        else if (_users == null)
          const Center(child: CircularProgressIndicator())
        else
          ..._users!.map(
            (u) => Card(
              child: ListTile(
                title: Row(
                  children: [
                    Text(
                      u.identity,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    if (u.isAdmin) tag('admin', CcColors.accent),
                    if (u.disabled) tag('disabled', CcColors.danger),
                  ],
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'admin':
                        _act(
                          () => widget.client.setUserAdmin(
                            u.identity,
                            !u.isAdmin,
                          ),
                        );
                      case 'disable':
                        _act(
                          () => widget.client.setUserDisabled(
                            u.identity,
                            !u.disabled,
                          ),
                        );
                      case 'reset':
                        _act(() async {
                          final pw = await widget.client.resetPassword(
                            u.identity,
                          );
                          if (mounted) _showSecret('${u.identity} 的新密码', pw);
                        });
                    }
                  },
                  itemBuilder: (_) => [
                    ccMenuItem(
                      value: 'admin',
                      icon: Icons.shield_rounded,
                      label: u.isAdmin ? '取消 admin' : '设为 admin',
                    ),
                    ccMenuItem(
                      value: 'disable',
                      icon: u.disabled
                          ? Icons.check_circle_outline_rounded
                          : Icons.block_rounded,
                      label: u.disabled ? '启用' : '停用',
                    ),
                    ccMenuItem(
                      value: 'reset',
                      icon: Icons.password_rounded,
                      label: '重置密码',
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
