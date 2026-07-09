import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../theme.dart';
import '../widgets.dart';

String adminFlagLabel(bool isAdmin) => isAdmin ? '系统管理员' : '普通成员';
String disabledFlagLabel(bool disabled) => disabled ? '已停用' : '已启用';
String adminToggleLabel(bool isAdmin) => isAdmin ? '取消管理员' : '设为管理员';
String adminUserTitle(User user) =>
    user.displayName.isEmpty ? user.identity : user.displayName;
String? adminUserSubtitle(User user) =>
    user.displayName.isEmpty ? null : user.identity;
double adminCreateOptionWidth(BoxConstraints constraints, double preferred) {
  final maxWidth = constraints.maxWidth;
  if (!maxWidth.isFinite || maxWidth <= 0) return preferred;
  return maxWidth < preferred ? maxWidth : preferred;
}

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
  bool _creating = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _identity.addListener(_onCreateInputChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant AdminPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client == widget.client) return;
    _loadGeneration++;
    _identity.clear();
    _password.clear();
    setState(() {
      _users = null;
      _error = null;
      _newAdmin = false;
      _creating = false;
    });
    _load();
  }

  @override
  void dispose() {
    _identity.removeListener(_onCreateInputChanged);
    _identity.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _canCreateUser => !_creating && _identity.text.trim().isNotEmpty;

  void _onCreateInputChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final client = widget.client;
    try {
      final u = await client.users();
      if (_isCurrentLoad(generation, client)) {
        setState(() {
          _users = u;
          _error = null;
        });
      }
    } catch (e) {
      if (_isCurrentLoad(generation, client)) setState(() => _error = '$e');
    }
  }

  bool _isCurrentLoad(int generation, RelayClient client) =>
      mounted &&
      generation == _loadGeneration &&
      identical(client, widget.client);

  Future<void> _create() async {
    final id = _identity.text.trim();
    if (id.isEmpty || _creating) return;
    setState(() => _creating = true);
    try {
      final pw = await widget.client.createUser(
        id,
        password: _password.text.trim(),
        isAdmin: _newAdmin,
      );
      if (!mounted) return;
      _identity.clear();
      _password.clear();
      setState(() => _newAdmin = false);
      await _load();
      if (pw != null && pw.isNotEmpty && mounted) {
        _showSecret('账号 $id 的初始密码', pw);
      }
    } catch (e) {
      if (mounted) snack(context, '创建失败: ${errorText(e)}');
    } finally {
      if (mounted) setState(() => _creating = false);
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
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          '系统管理 · 账号',
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
                  '创建账号',
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
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final optionWidth = adminCreateOptionWidth(
                      constraints,
                      220,
                    );
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: optionWidth,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Checkbox(
                                value: _newAdmin,
                                onChanged: (v) =>
                                    setState(() => _newAdmin = v ?? false),
                              ),
                              const Flexible(
                                child: Text(
                                  '创建为系统管理员',
                                  key: ValueKey('admin-create-admin-label'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        FilledButton(
                          onPressed: _canCreateUser ? _create : null,
                          child: Text(_creating ? '创建中...' : '创建账号'),
                        ),
                      ],
                    );
                  },
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
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      adminUserTitle(u),
                      key: ValueKey('admin-user-title-${u.identity}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (u.isAdmin || u.disabled) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (u.isAdmin)
                            tag(adminFlagLabel(true), CcColors.accent),
                          if (u.disabled)
                            tag(disabledFlagLabel(true), CcColors.danger),
                        ],
                      ),
                    ],
                  ],
                ),
                subtitle: adminUserSubtitle(u) == null
                    ? null
                    : Text(
                        adminUserSubtitle(u)!,
                        key: ValueKey('admin-user-subtitle-${u.identity}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                      label: adminToggleLabel(u.isAdmin),
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
