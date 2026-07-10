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
  final _search = TextEditingController();
  bool _newAdmin = false;
  bool _creating = false;
  bool _showDeleted = false;
  String _statusFilter = 'all';
  final Set<String> _pendingUserActions = {};
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AdminPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client == widget.client) return;
    _loadGeneration++;
    setState(() {
      _users = null;
      _error = null;
      _newAdmin = false;
      _creating = false;
      _showDeleted = false;
      _statusFilter = 'all';
      _pendingUserActions.clear();
    });
    final client = widget.client;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrentClient(client)) return;
      _identity.clear();
      _password.clear();
      _search.clear();
      setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _identity.dispose();
    _password.dispose();
    _search.dispose();
    super.dispose();
  }

  List<User> get _visibleUsers {
    final query = _search.text.trim().toLowerCase();
    return _users?.where((user) {
          if (user.deleted != _showDeleted) return false;
          if (query.isNotEmpty &&
              !user.identity.toLowerCase().contains(query) &&
              !user.displayName.toLowerCase().contains(query)) {
            return false;
          }
          if (_showDeleted || _statusFilter == 'all') return true;
          return _statusFilter == 'disabled' ? user.disabled : !user.disabled;
        }).toList() ??
        const [];
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

  Future<({bool success, String? password, String identity})> _create() async {
    final id = _identity.text.trim();
    if (id.isEmpty || _creating) {
      return (success: false, password: null, identity: id);
    }
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
      if (!_isCurrentClient(client)) {
        return (success: false, password: null, identity: id);
      }
      _identity.clear();
      _password.clear();
      setState(() => _newAdmin = false);
      await _load();
      return (success: true, password: pw, identity: id);
    } catch (e) {
      if (mounted && identical(client, widget.client)) {
        snack(context, '创建失败: ${errorText(e)}');
      }
      return (success: false, password: null, identity: id);
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

  void _showCreateDialog() {
    if (_creating) return;
    _identity.clear();
    _password.clear();
    _newAdmin = false;
    var submitting = false;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final canSubmit = !submitting && _identity.text.trim().isNotEmpty;

          Future<void> submit() async {
            if (!canSubmit) return;
            setDialogState(() => submitting = true);
            final result = await _create();
            if (!dialogContext.mounted) return;
            if (!result.success) {
              setDialogState(() => submitting = false);
              return;
            }
            Navigator.pop(dialogContext);
            if (result.password != null &&
                result.password!.isNotEmpty &&
                mounted) {
              _showSecret('账号 ${result.identity} 的初始密码', result.password!);
            }
          }

          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            title: const Row(
              children: [
                Icon(Icons.person_add_alt_1_rounded, size: 20),
                SizedBox(width: 8),
                Text('创建账号'),
              ],
            ),
            content: SizedBox(
              width: adminSecretDialogWidth(
                MediaQuery.sizeOf(context),
                preferred: 460,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('admin-create-identity'),
                    controller: _identity,
                    autofocus: true,
                    enabled: !submitting,
                    decoration: const InputDecoration(
                      labelText: 'identity（如 alex@frontend）',
                      isDense: true,
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('admin-create-password'),
                    controller: _password,
                    enabled: !submitting,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '初始密码（留空自动生成）',
                      isDense: true,
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const ValueKey('admin-create-admin-option'),
                    value: _newAdmin,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('创建为系统管理员'),
                    onChanged: submitting
                        ? null
                        : (value) =>
                              setDialogState(() => _newAdmin = value ?? false),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting
                    ? null
                    : () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                key: const ValueKey('admin-create-submit'),
                onPressed: canSubmit ? submit : null,
                icon: submitting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.person_add_alt_1_rounded, size: 16),
                label: Text(submitting ? '创建中...' : '创建账号'),
              ),
            ],
          );
        },
      ),
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

  String get _statusFilterLabel => switch (_statusFilter) {
    'enabled' => '启用',
    'disabled' => '停用',
    _ => '全部',
  };

  String get _emptyMessage {
    final filtered =
        _search.text.trim().isNotEmpty ||
        (!_showDeleted && _statusFilter != 'all');
    if (_showDeleted) {
      return filtered ? '没有匹配的已删除账号。' : '没有已删除账号。';
    }
    return filtered ? '没有匹配的账号。' : '没有账号。';
  }

  Widget _toolbar() => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < 680;
      final search = SizedBox(
        width: narrow ? constraints.maxWidth : 320,
        height: 36,
        child: TextField(
          key: const ValueKey('admin-user-search'),
          controller: _search,
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            hintText: '搜索账号或名称',
            isDense: true,
            prefixIcon: const Icon(Icons.search_rounded, size: 17),
            prefixIconConstraints: const BoxConstraints(minWidth: 34),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('admin-user-search-clear'),
                    tooltip: '清除搜索',
                    icon: const Icon(Icons.close_rounded, size: 16),
                    onPressed: () {
                      _search.clear();
                      setState(() {});
                    },
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
      );
      final viewSwitch = SegmentedButton<bool>(
        key: const ValueKey('admin-user-view-tabs'),
        segments: const [
          ButtonSegment(value: false, label: Text('现有账号')),
          ButtonSegment(value: true, label: Text('已删除')),
        ],
        selected: {_showDeleted},
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onSelectionChanged: (selected) => setState(() {
          _showDeleted = selected.first;
          _statusFilter = 'all';
        }),
      );
      return Container(
        key: const ValueKey('admin-user-toolbar'),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: CcColors.panel,
          border: Border.all(color: CcColors.border),
          borderRadius: BorderRadius.circular(CcRadius.md),
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [search, viewSwitch, if (!_showDeleted) _statusMenu()],
        ),
      );
    },
  );

  Widget _statusMenu() => PopupMenuButton<String>(
    key: const ValueKey('admin-user-status-filter'),
    tooltip: '筛选账号状态',
    initialValue: _statusFilter,
    onSelected: (value) => setState(() => _statusFilter = value),
    itemBuilder: (_) => [
      for (final option in const [
        ('all', '全部'),
        ('enabled', '启用'),
        ('disabled', '停用'),
      ])
        PopupMenuItem<String>(
          value: option.$1,
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: _statusFilter == option.$1
                    ? const Icon(Icons.check_rounded, size: 16)
                    : null,
              ),
              Text(option.$2),
            ],
          ),
        ),
    ],
    child: Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: CcColors.border),
        borderRadius: BorderRadius.circular(CcRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.filter_alt_outlined, size: 16),
          const SizedBox(width: 6),
          Text(_statusFilterLabel),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down_rounded, size: 18),
        ],
      ),
    ),
  );

  Widget _userList() => LayoutBuilder(
    builder: (context, constraints) {
      final users = _visibleUsers;
      if (users.isEmpty) {
        return Container(
          key: const ValueKey('admin-user-empty'),
          constraints: const BoxConstraints(minHeight: 96),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: CcColors.panel,
            border: Border.all(color: CcColors.border),
            borderRadius: BorderRadius.circular(CcRadius.md),
          ),
          child: Text(
            _emptyMessage,
            style: const TextStyle(color: CcColors.muted),
          ),
        );
      }
      final desktop = constraints.maxWidth >= 720;
      return Container(
        key: ValueKey(desktop ? 'admin-user-table' : 'admin-user-compact-list'),
        decoration: BoxDecoration(
          color: CcColors.panel,
          border: Border.all(color: CcColors.border),
          borderRadius: BorderRadius.circular(CcRadius.md),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            if (desktop) _tableHeader(),
            for (var i = 0; i < users.length; i++) ...[
              if (desktop || i > 0)
                const Divider(height: 1, color: CcColors.border),
              desktop ? _desktopUserRow(users[i]) : _compactUserRow(users[i]),
            ],
          ],
        ),
      );
    },
  );

  Widget _tableHeader() => Container(
    key: const ValueKey('admin-user-table-header'),
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    color: CcColors.toolbar,
    child: const Row(
      children: [
        Expanded(
          flex: 5,
          child: Text(
            '账号',
            style: TextStyle(fontSize: 12, color: CcColors.muted),
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            '角色',
            style: TextStyle(fontSize: 12, color: CcColors.muted),
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            '状态',
            style: TextStyle(fontSize: 12, color: CcColors.muted),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            '操作',
            style: TextStyle(fontSize: 12, color: CcColors.muted),
          ),
        ),
      ],
    ),
  );

  Widget _desktopUserRow(User user) => SizedBox(
    key: ValueKey('admin-user-row-${user.identity}'),
    height: 58,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(flex: 5, child: _accountCell(user)),
          Expanded(flex: 2, child: _roleCell(user)),
          Expanded(flex: 2, child: _statusCell(user)),
          SizedBox(width: 38, child: _actionCell(user)),
        ],
      ),
    ),
  );

  Widget _compactUserRow(User user) => Container(
    key: ValueKey('admin-user-row-${user.identity}'),
    constraints: const BoxConstraints(minHeight: 72),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _accountCell(user),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [_roleCell(user), _statusCell(user)],
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 34, child: _actionCell(user)),
      ],
    ),
  );

  Widget _accountCell(User user) {
    final subtitle = adminUserSubtitle(user);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                adminUserTitle(user),
                key: ValueKey('admin-user-title-${user.identity}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (user.identity == widget.currentIdentity) ...[
              const SizedBox(width: 6),
              tag('当前', CcColors.info),
            ],
          ],
        ),
        if (subtitle != null)
          Text(
            subtitle,
            key: ValueKey('admin-user-subtitle-${user.identity}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: CcColors.muted,
              fontFamily: CcType.mono,
              fontSize: 11.5,
            ),
          ),
      ],
    );
  }

  Widget _roleCell(User user) => user.isAdmin
      ? tag(adminFlagLabel(true), CcColors.accent)
      : Text(
          adminFlagLabel(false),
          key: ValueKey('admin-user-role-${user.identity}'),
          style: const TextStyle(fontSize: 12.5, color: CcColors.muted),
        );

  Widget _statusCell(User user) {
    if (user.deleted) return tag(deletedFlagLabel(true), CcColors.danger);
    if (user.disabled) return tag(disabledFlagLabel(true), CcColors.warning);
    return tag(disabledFlagLabel(false), CcColors.ok);
  }

  Widget _actionCell(User user) {
    if (user.deleted) return const SizedBox.shrink();
    if (_pendingUserActions.contains(user.identity)) {
      return const Center(
        child: SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return PopupMenuButton<String>(
      key: ValueKey('admin-user-actions-${user.identity}'),
      tooltip: '账号操作',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz_rounded, size: 19),
      onSelected: (value) => _handleUserAction(user, value),
      itemBuilder: (_) => [
        ccMenuItem(
          value: 'admin',
          icon: Icons.shield_rounded,
          label: adminToggleLabel(user.isAdmin),
        ),
        ccMenuItem(
          value: 'disable',
          icon: user.disabled
              ? Icons.check_circle_outline_rounded
              : Icons.block_rounded,
          label: user.disabled ? '启用' : '停用',
        ),
        ccMenuItem(value: 'reset', icon: Icons.password_rounded, label: '重置密码'),
        ccMenuItem(
          value: user.identity == widget.currentIdentity ? null : 'delete',
          icon: Icons.delete_forever_rounded,
          label: user.identity == widget.currentIdentity ? '不能删除当前账号' : '删除账号',
          danger: true,
        ),
      ],
    );
  }

  Future<void> _handleUserAction(User user, String value) async {
    final client = widget.client;
    switch (value) {
      case 'admin':
        await _act(
          client,
          user.identity,
          (client) => client.setUserAdmin(user.identity, !user.isAdmin),
        );
      case 'disable':
        await _act(
          client,
          user.identity,
          (client) => client.setUserDisabled(user.identity, !user.disabled),
        );
      case 'reset':
        await _act(client, user.identity, (client) async {
          final password = await client.resetPassword(user.identity);
          if (_isCurrentClient(client)) {
            _showSecret('${user.identity} 的新密码', password);
          }
        });
      case 'delete':
        if (await _confirmDelete(user) && _isCurrentClient(client)) {
          await _act(client, user.identity, (client) async {
            await client.deleteUser(user.identity);
            if (_isCurrentClient(client)) {
              setState(() => _markDeleted(user));
            }
          });
        }
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Row(
        key: const ValueKey('admin-page-header'),
        children: [
          const Expanded(
            child: Text(
              '系统管理 · 账号',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            key: const ValueKey('admin-open-create'),
            onPressed: _creating ? null : _showCreateDialog,
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
            label: const Text('创建账号'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      _toolbar(),
      const SizedBox(height: 12),
      if (_error != null)
        Text(_error!, style: const TextStyle(color: CcColors.danger))
      else if (_users == null)
        const Center(child: CircularProgressIndicator())
      else
        _userList(),
    ],
  );
}
