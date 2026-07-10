import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../theme.dart';
import '../widgets.dart';

String adminFlagLabel(bool isAdmin) => isAdmin ? '系统管理员' : '普通成员';
String disabledFlagLabel(bool disabled) => disabled ? '已停用' : '已启用';
String deletedFlagLabel(bool deleted) => deleted ? '已删除' : '未删除';
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

double adminSecretDialogWidth(Size size, {double preferred = 420}) {
  final available = size.width - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

class AdminPage extends StatefulWidget {
  final RelayClient client;
  final String currentIdentity;
  const AdminPage({super.key, required this.client, this.currentIdentity = ''});

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
  bool _showDeleted = false;
  final Set<String> _pendingUserActions = {};
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
      _showDeleted = false;
      _pendingUserActions.clear();
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

  List<User> get _visibleUsers =>
      _users?.where((user) => user.deleted == _showDeleted).toList() ??
      const [];

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

  bool _isCurrentClient(RelayClient client) =>
      mounted && identical(client, widget.client);

  Future<void> _create() async {
    final id = _identity.text.trim();
    if (id.isEmpty || _creating) return;
    final client = widget.client;
    final password = _password.text.trim();
    final isAdmin = _newAdmin;
    setState(() => _creating = true);
    try {
      final pw = await client.createUser(
        id,
        password: password,
        isAdmin: isAdmin,
      );
      if (!_isCurrentClient(client)) return;
      _identity.clear();
      _password.clear();
      setState(() => _newAdmin = false);
      await _load();
      if (pw != null && pw.isNotEmpty && _isCurrentClient(client)) {
        _showSecret('账号 $id 的初始密码', pw);
      }
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, '创建失败: ${errorText(e)}');
    } finally {
      if (_isCurrentClient(client)) setState(() => _creating = false);
    }
  }

  Future<void> _act(
    RelayClient client,
    String identity,
    Future<void> Function(RelayClient client) f,
  ) async {
    if (_pendingUserActions.contains(identity)) return;
    setState(() => _pendingUserActions.add(identity));
    try {
      await f(client);
      if (!_isCurrentClient(client)) return;
      await _load();
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, errorText(e));
    } finally {
      if (_isCurrentClient(client)) {
        setState(() => _pendingUserActions.remove(identity));
      }
    }
  }

  void _showSecret(String title, String secret) {
    showDialog(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: adminSecretDialogWidth(size),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                secret,
                style: const TextStyle(fontFamily: CcType.mono),
              ),
            ),
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
        );
      },
    );
  }

  Future<bool> _confirmDelete(User user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账号？'),
        content: Text(
          '确定删除 ${user.identity}？删除后无法恢复，该 identity 不能重新注册，所有登录和机器 token 会立即失效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            child: const Text('删除账号'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void _markDeleted(User user) {
    _users = _users
        ?.map(
          (candidate) => candidate.identity == user.identity
              ? User.fromJson({
                  'identity': candidate.identity,
                  'display_name': candidate.displayName,
                  'disabled': true,
                  'deleted': true,
                })
              : candidate,
        )
        .toList();
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
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<bool>(
            key: const ValueKey('admin-user-view-tabs'),
            segments: const [
              ButtonSegment(value: false, label: Text('账号')),
              ButtonSegment(value: true, label: Text('已删除')),
            ],
            selected: {_showDeleted},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (selected) =>
                setState(() => _showDeleted = selected.first),
          ),
        ),
        if (!_showDeleted) ...[
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
        ],
        const SizedBox(height: 16),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: CcColors.danger))
        else if (_users == null)
          const Center(child: CircularProgressIndicator())
        else if (_visibleUsers.isEmpty)
          Center(child: Text(_showDeleted ? '没有已删除账号。' : '没有账号。'))
        else
          ..._visibleUsers.map(
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
                    if (u.isAdmin || u.disabled || u.deleted) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (u.isAdmin)
                            tag(adminFlagLabel(true), CcColors.accent),
                          if (u.deleted)
                            tag(deletedFlagLabel(true), CcColors.danger)
                          else if (u.disabled)
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
                trailing: u.deleted
                    ? null
                    : _pendingUserActions.contains(u.identity)
                    ? const SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    : PopupMenuButton<String>(
                        onSelected: (v) async {
                          final client = widget.client;
                          switch (v) {
                            case 'admin':
                              _act(
                                client,
                                u.identity,
                                (client) =>
                                    client.setUserAdmin(u.identity, !u.isAdmin),
                              );
                            case 'disable':
                              _act(
                                client,
                                u.identity,
                                (client) => client.setUserDisabled(
                                  u.identity,
                                  !u.disabled,
                                ),
                              );
                            case 'reset':
                              _act(client, u.identity, (client) async {
                                final pw = await client.resetPassword(
                                  u.identity,
                                );
                                if (_isCurrentClient(client)) {
                                  _showSecret('${u.identity} 的新密码', pw);
                                }
                              });
                            case 'delete':
                              if (await _confirmDelete(u) &&
                                  _isCurrentClient(client)) {
                                await _act(client, u.identity, (client) async {
                                  await client.deleteUser(u.identity);
                                  if (_isCurrentClient(client)) {
                                    setState(() => _markDeleted(u));
                                  }
                                });
                              }
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
                          ccMenuItem(
                            value: u.identity == widget.currentIdentity
                                ? null
                                : 'delete',
                            icon: Icons.delete_forever_rounded,
                            label: u.identity == widget.currentIdentity
                                ? '不能删除当前账号'
                                : '删除账号',
                            danger: true,
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
