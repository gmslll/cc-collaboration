import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../theme.dart';
import '../widgets.dart';

bool canManageOrganization(Organization org, {required bool isAdmin}) =>
    isAdmin || org.role == 'owner' || org.role == 'admin';

String organizationRoleLabel(String role, {required bool isAdmin}) {
  if (role.isEmpty && isAdmin) return '系统管理员';
  switch (role) {
    case 'owner':
      return '负责人';
    case 'admin':
      return '管理员';
    case 'member':
      return '成员';
    case 'guest':
      return '访客';
    default:
      return role.isEmpty ? '成员' : role;
  }
}

String projectRoleLabel(String role) {
  switch (role) {
    case 'admin':
      return '管理员';
    case 'owner':
      return '负责人';
    case 'member':
      return '成员';
    case 'viewer':
      return '只读';
    default:
      return role.isEmpty ? '成员' : role;
  }
}

String organizationMemberPickerLabel(OrganizationMember member) {
  final role = organizationRoleLabel(member.role, isAdmin: false);
  if (member.displayName.isEmpty) return '${member.identity} · $role';
  return '${member.displayName} · ${member.identity} · $role';
}

int organizationOwnerCount(Iterable<OrganizationMember> members) =>
    members.where((m) => m.role == 'owner').length;

bool canRemoveOrganizationMember(
  OrganizationMember member,
  Iterable<OrganizationMember> members,
) => member.role != 'owner' || organizationOwnerCount(members) > 1;

bool canUpsertOrganizationMemberRole(
  String identity,
  String nextRole,
  Iterable<OrganizationMember> members,
) {
  final id = identity.trim();
  final role = nextRole.trim();
  if (id.isEmpty) return false;
  if (role == 'owner') return true;
  for (final member in members) {
    if (member.identity.trim() == id) {
      return canRemoveOrganizationMember(member, members);
    }
  }
  return true;
}

String projectOwnerLabel(String identity) =>
    '${projectRoleLabel('owner')} · $identity';

String projectMemberTitle(ProjectMember member) =>
    member.displayName.isEmpty ? member.identity : member.displayName;

String? projectMemberSubtitle(ProjectMember member) =>
    member.displayName.isEmpty ? null : member.identity;

int projectOwnerCount(Iterable<ProjectMember> members) =>
    members.where((m) => m.role == 'owner').length;

bool canRemoveProjectMember(
  ProjectMember member,
  Iterable<ProjectMember> members,
) => member.role != 'owner' || projectOwnerCount(members) > 1;

bool canUpsertProjectMemberRole(
  String identity,
  String nextRole,
  Iterable<ProjectMember> members,
) {
  final id = identity.trim();
  final role = nextRole.trim();
  if (id.isEmpty) return false;
  if (role == 'owner') return true;
  for (final member in members) {
    if (member.identity.trim() == id) {
      return canRemoveProjectMember(member, members);
    }
  }
  return true;
}

class ProjectsPage extends StatefulWidget {
  final RelayClient client;
  const ProjectsPage({super.key, required this.client});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  List<Project>? _projects;
  List<Organization> _orgs = const [];
  Set<String> _manageableOrgIds = const <String>{};
  List<OnlineUser> _online = const [];
  bool _isAdmin = false;
  String _identity = '';
  String? _error;
  final _name = TextEditingController();
  final _orgName = TextEditingController();
  String? _selectedOrgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _orgName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final orgs = await widget.client.organizations().catchError(
        (_) => <Organization>[],
      );
      Me? me;
      try {
        me = await widget.client.me();
      } catch (_) {
        me = null;
      }
      final ps = await widget.client.projects();
      final online = await widget.client.onlineUsers().catchError(
        (_) => <OnlineUser>[],
      );
      final meOrgRoles = {
        for (final org in me?.organizations ?? const <OrganizationRole>[])
          org.id: org.role,
      };
      final manageableOrgIds = me?.isAdmin == true
          ? orgs.map((org) => org.id).toSet()
          : orgs
                .where((org) {
                  final role = org.role.isNotEmpty
                      ? org.role
                      : meOrgRoles[org.id] ?? '';
                  return role == 'owner' || role == 'admin';
                })
                .map((org) => org.id)
                .toSet();
      if (mounted) {
        setState(() {
          _orgs = orgs;
          _manageableOrgIds = manageableOrgIds;
          _isAdmin = me?.isAdmin == true;
          _identity = me?.identity ?? '';
          _projects = ps;
          _online = online;
          if (_selectedOrgId != null &&
              _selectedOrgId!.isNotEmpty &&
              !manageableOrgIds.contains(_selectedOrgId)) {
            _selectedOrgId = '';
          }
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    try {
      await widget.client.createProject(name, orgId: _selectedOrgId);
      _name.clear();
      await _load();
    } catch (e) {
      if (mounted) snack(context, '创建失败: ${errorText(e)}');
    }
  }

  Future<void> _createOrg() async {
    final name = _orgName.text.trim();
    if (name.isEmpty) return;
    try {
      final org = await widget.client.createOrganization(name);
      if (!mounted) return;
      _orgName.clear();
      setState(() {
        _orgs = [..._orgs, org];
        _manageableOrgIds = {..._manageableOrgIds, org.id};
        _selectedOrgId = org.id;
      });
      await _load();
    } catch (e) {
      if (mounted) snack(context, '创建团队失败: ${errorText(e)}');
    }
  }

  String _teamName(String id) {
    if (id.isEmpty) return '默认团队';
    for (final org in _orgs) {
      if (org.id == id) return org.name;
    }
    return id;
  }

  String _projectRoleLabel(Project p) {
    final role = p.role.isEmpty
        ? (_isAdmin
              ? 'admin'
              : (p.ownerIdentity == _identity ? 'owner' : 'member'))
        : p.role;
    return projectRoleLabel(role);
  }

  List<Organization> get _manageableOrgs =>
      _orgs.where((org) => _manageableOrgIds.contains(org.id)).toList();

  int _orgProjectCount(String orgId) =>
      (_projects ?? const <Project>[]).where((p) => p.orgId == orgId).length;

  Future<void> _showOrganizationSheet(Organization org) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OrganizationSheet(
        client: widget.client,
        id: org.id,
        isAdmin: _isAdmin,
        onChanged: _load,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            runSpacing: 8,
            spacing: 8,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _orgName,
                  decoration: const InputDecoration(
                    hintText: '新团队名称',
                    isDense: true,
                    prefixIcon: Icon(Icons.groups_rounded),
                  ),
                  onSubmitted: (_) => _createOrg(),
                ),
              ),
              FilledButton.icon(
                onPressed: _createOrg,
                icon: const Icon(Icons.group_add_rounded, size: 18),
                label: const Text('新建团队'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _teamPanel(),
          const SizedBox(height: 12),
          Wrap(
            runSpacing: 8,
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    hintText: '新项目名称',
                    isDense: true,
                    prefixIcon: Icon(Icons.create_new_folder_rounded),
                  ),
                  onSubmitted: (_) => _create(),
                ),
              ),
              if (_manageableOrgs.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: DropdownButton<String>(
                    value: _selectedOrgId ?? '',
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('我的默认团队')),
                      ..._manageableOrgs.map(
                        (o) =>
                            DropdownMenuItem(value: o.id, child: Text(o.name)),
                      ),
                    ],
                    onChanged: (v) => setState(() => _selectedOrgId = v),
                  ),
                ),
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建项目'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: CcColors.danger)),
      );
    }
    if (_projects == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_projects!.isEmpty) {
      return const Center(
        child: Text('还没有项目', style: TextStyle(color: CcColors.muted)),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: _projects!
          .map(
            (p) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: HoverLift(
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => _ProjectSheet(
                    client: widget.client,
                    id: p.id,
                    teamName: _teamName(p.orgId),
                    identity: _identity,
                    isAdmin: _isAdmin,
                    online: _online,
                    onChanged: _load,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_rounded,
                      color: CcColors.accent,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_teamName(p.orgId)} · ${_projectRoleLabel(p)} · ${projectOwnerLabel(p.ownerIdentity)}',
                            style: const TextStyle(
                              fontFamily: CcType.mono,
                              color: CcColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: CcColors.subtle,
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _teamPanel() {
    if (_orgs.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _orgs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final org = _orgs[i];
          final canManage = _manageableOrgIds.contains(org.id);
          return SizedBox(
            width: 286,
            child: Material(
              color: CcColors.panel,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(CcRadius.md),
                side: BorderSide(
                  color: canManage ? CcColors.accent : CcColors.borderSoft,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(CcRadius.md),
                onTap: () => _showOrganizationSheet(org),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            canManage
                                ? Icons.admin_panel_settings_rounded
                                : Icons.groups_rounded,
                            size: 18,
                            color: canManage
                                ? CcColors.accentBright
                                : CcColors.muted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              org.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Text(
                            organizationRoleLabel(org.role, isAdmin: _isAdmin),
                            style: CcType.code(
                              size: 11.5,
                              color: CcColors.accentBright,
                            ),
                          ),
                          Text(
                            '  ·  ',
                            style: CcType.code(
                              size: 11.5,
                              color: CcColors.subtle,
                            ),
                          ),
                          Text(
                            '${_orgProjectCount(org.id)} 项目',
                            style: CcType.code(
                              size: 11.5,
                              color: CcColors.muted,
                            ),
                          ),
                          const Spacer(),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: CcColors.subtle,
                            size: 20,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OrganizationSheet extends StatefulWidget {
  final RelayClient client;
  final String id;
  final bool isAdmin;
  final VoidCallback onChanged;

  const _OrganizationSheet({
    required this.client,
    required this.id,
    required this.isAdmin,
    required this.onChanged,
  });

  @override
  State<_OrganizationSheet> createState() => _OrganizationSheetState();
}

class _OrganizationSheetState extends State<_OrganizationSheet> {
  OrganizationDetail? _detail;
  final _identity = TextEditingController();
  String _role = 'member';

  @override
  void initState() {
    super.initState();
    _identity.addListener(_onIdentityInputChanged);
    _load();
  }

  @override
  void dispose() {
    _identity.removeListener(_onIdentityInputChanged);
    _identity.dispose();
    super.dispose();
  }

  void _onIdentityInputChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final detail = await widget.client.organization(widget.id);
      if (mounted) setState(() => _detail = detail);
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _do(Future<void> Function() action) async {
    try {
      await action();
      await _load();
      widget.onChanged();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  bool _canManage(OrganizationDetail d) =>
      canManageOrganization(d.organization, isAdmin: widget.isAdmin);

  Future<void> _removeMember(String identity) async {
    final ok = await confirm(
      context,
      '从团队移除 $identity ? 该用户将失去这个团队下项目的继承访问权。',
      title: '移除团队成员',
      okLabel: '移除',
    );
    if (!ok) return;
    await _do(
      () => widget.client.removeOrganizationMember(widget.id, identity),
    );
  }

  Future<void> _addMember() async {
    final identity = _identity.text.trim();
    if (identity.isEmpty) return;
    _identity.clear();
    await _do(
      () => widget.client.addOrganizationMember(widget.id, identity, _role),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final canManage = d != null && _canManage(d);
    final memberInput = _identity.text.trim();
    final canSubmitMember =
        d != null &&
        canUpsertOrganizationMemberRole(memberInput, _role, d.members);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: d == null
          ? const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.groups_rounded,
                        color: CcColors.accentBright,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              d.organization.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '${organizationRoleLabel(d.organization.role, isAdmin: widget.isAdmin)} · ${d.members.length} 成员 · ${d.projects.length} 项目',
                              style: CcType.code(
                                size: 12,
                                color: CcColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '成员',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  ...d.members.map((m) {
                    final canRemoveMember = canRemoveOrganizationMember(
                      m,
                      d.members,
                    );
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_rounded, size: 18),
                      title: Text(
                        m.displayName.isEmpty ? m.identity : m.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: m.displayName.isEmpty
                          ? null
                          : Text(
                              m.identity,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: canManage
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: m.role,
                                    isDense: true,
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'owner',
                                        child: Text('负责人'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'admin',
                                        child: Text('管理员'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'member',
                                        child: Text('成员'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'guest',
                                        child: Text('访客'),
                                      ),
                                    ],
                                    onChanged: canRemoveMember
                                        ? (role) {
                                            if (role == null ||
                                                role == m.role) {
                                              return;
                                            }
                                            _do(
                                              () => widget.client
                                                  .addOrganizationMember(
                                                    widget.id,
                                                    m.identity,
                                                    role,
                                                  ),
                                            );
                                          }
                                        : null,
                                  ),
                                ),
                                IconButton(
                                  tooltip: canRemoveMember ? '移除' : '至少保留一个负责人',
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: canRemoveMember
                                        ? CcColors.muted
                                        : CcColors.subtle,
                                  ),
                                  onPressed: canRemoveMember
                                      ? () => _removeMember(m.identity)
                                      : null,
                                ),
                              ],
                            )
                          : Text(
                              organizationRoleLabel(m.role, isAdmin: false),
                              style: const TextStyle(color: CcColors.muted),
                            ),
                    );
                  }),
                  if (canManage) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 280,
                          child: TextField(
                            controller: _identity,
                            decoration: const InputDecoration(
                              hintText: '成员 identity',
                              isDense: true,
                              prefixIcon: Icon(Icons.alternate_email_rounded),
                            ),
                            onSubmitted: (_) {
                              if (canSubmitMember) _addMember();
                            },
                          ),
                        ),
                        DropdownButton<String>(
                          value: _role,
                          items: const [
                            DropdownMenuItem(
                              value: 'member',
                              child: Text('成员'),
                            ),
                            DropdownMenuItem(
                              value: 'admin',
                              child: Text('管理员'),
                            ),
                            DropdownMenuItem(value: 'guest', child: Text('访客')),
                            DropdownMenuItem(
                              value: 'owner',
                              child: Text('负责人'),
                            ),
                          ],
                          onChanged: (v) =>
                              setState(() => _role = v ?? 'member'),
                        ),
                        Tooltip(
                          message: memberInput.isNotEmpty && !canSubmitMember
                              ? '至少保留一个负责人'
                              : '加入团队',
                          child: FilledButton.icon(
                            onPressed: canSubmitMember ? _addMember : null,
                            icon: const Icon(
                              Icons.person_add_alt_1_rounded,
                              size: 18,
                            ),
                            label: const Text('加入团队'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 18),
                  const Text(
                    '项目',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  if (d.projects.isEmpty)
                    const Text(
                      '还没有项目',
                      style: TextStyle(color: CcColors.muted, fontSize: 13),
                    )
                  else
                    ...d.projects.map(
                      (p) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_rounded, size: 18),
                        title: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          projectOwnerLabel(p.ownerIdentity),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ProjectSheet extends StatefulWidget {
  final RelayClient client;
  final String id;
  final String teamName;
  final String identity;
  final bool isAdmin;
  final List<OnlineUser> online;
  final VoidCallback onChanged;
  const _ProjectSheet({
    required this.client,
    required this.id,
    required this.teamName,
    required this.identity,
    required this.isAdmin,
    required this.online,
    required this.onChanged,
  });

  @override
  State<_ProjectSheet> createState() => _ProjectSheetState();
}

class _ProjectSheetState extends State<_ProjectSheet> {
  ProjectDetail? _d;
  List<OrganizationMember> _orgMembers = const [];
  final _repo = TextEditingController();
  final _member = TextEditingController();
  String _role = 'member';

  @override
  void initState() {
    super.initState();
    _member.addListener(_onMemberInputChanged);
    _load();
  }

  @override
  void dispose() {
    _member.removeListener(_onMemberInputChanged);
    _repo.dispose();
    _member.dispose();
    super.dispose();
  }

  void _onMemberInputChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final d = await widget.client.project(widget.id);
      var orgMembers = const <OrganizationMember>[];
      if (d.project.orgId.isNotEmpty) {
        try {
          final org = await widget.client.organization(d.project.orgId);
          orgMembers = org.members;
        } catch (_) {
          orgMembers = const [];
        }
      }
      if (mounted) {
        setState(() {
          _d = d;
          _orgMembers = orgMembers;
        });
      }
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _do(Future<void> Function() action) async {
    try {
      await action();
      await _load();
      widget.onChanged();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _rename(String current) async {
    final ctl = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名项目'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true || ctl.text.trim().isEmpty) return;
    await _do(() => widget.client.renameProject(widget.id, ctl.text.trim()));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除项目?'),
        content: const Text('删除后不可恢复(repo / 成员映射一并删除)。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.client.deleteProject(widget.id);
      widget.onChanged();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  bool _isOnline(String identity) =>
      widget.online.any((u) => u.identity == identity && u.online);

  bool _canManage(ProjectDetail d) {
    if (widget.isAdmin) return true;
    if (d.project.role == 'admin') return true;
    if (d.project.ownerIdentity == widget.identity) return true;
    return d.members.any(
      (m) => m.identity == widget.identity && m.role == 'owner',
    );
  }

  List<OrganizationMember> _memberCandidates(ProjectDetail d) {
    final projectMembers = d.members.map((m) => m.identity).toSet();
    final candidates = _orgMembers
        .where((m) => !projectMembers.contains(m.identity))
        .toList();
    candidates.sort((a, b) {
      final an = a.displayName.isEmpty ? a.identity : a.displayName;
      final bn = b.displayName.isEmpty ? b.identity : b.displayName;
      return an.compareTo(bn);
    });
    return candidates;
  }

  String _memberLabel(OrganizationMember m) {
    return organizationMemberPickerLabel(m);
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final canManage = d != null && _canManage(d);
    final memberCandidates = d == null
        ? const <OrganizationMember>[]
        : _memberCandidates(d);
    final memberInput = _member.text.trim();
    final canSubmitMember =
        d != null && canUpsertProjectMemberRole(memberInput, _role, d.members);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: d == null
          ? const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          d.project.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (canManage) ...[
                        IconButton(
                          icon: const Icon(Icons.edit_rounded, size: 18),
                          tooltip: '重命名',
                          onPressed: () => _rename(d.project.name),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_rounded,
                            size: 18,
                            color: CcColors.danger,
                          ),
                          tooltip: '删除',
                          onPressed: _delete,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        avatar: const Icon(Icons.groups_rounded, size: 16),
                        label: Text(widget.teamName),
                      ),
                      Chip(
                        avatar: const Icon(Icons.person_rounded, size: 16),
                        label: Text(
                          '${projectRoleLabel('owner')} · ${d.project.ownerIdentity}',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Repos',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: d.repos.isEmpty
                        ? [
                            const Text(
                              '无',
                              style: TextStyle(color: CcColors.muted),
                            ),
                          ]
                        : d.repos
                              .map(
                                (r) => Chip(
                                  label: Text(r),
                                  onDeleted: canManage
                                      ? () => _do(
                                          () => widget.client.unmapRepo(
                                            widget.id,
                                            r,
                                          ),
                                        )
                                      : null,
                                ),
                              )
                              .toList(),
                  ),
                  if (canManage)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _repo,
                            decoration: const InputDecoration(
                              hintText: 'repo 名(如 kunlun-backend)',
                              isDense: true,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            final r = _repo.text.trim();
                            if (r.isNotEmpty) {
                              _repo.clear();
                              _do(() => widget.client.mapRepo(widget.id, r));
                            }
                          },
                          child: const Text('绑定'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    '成员',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  ...d.members.map((m) {
                    final subtitle = projectMemberSubtitle(m);
                    final canRemoveMember = canRemoveProjectMember(
                      m,
                      d.members,
                    );
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: statusDot(
                        _isOnline(m.identity) ? CcColors.ok : CcColors.subtle,
                        size: 9,
                        glow: _isOnline(m.identity),
                      ),
                      title: Text(projectMemberTitle(m)),
                      subtitle: subtitle == null ? null : Text(subtitle),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            projectRoleLabel(m.role),
                            style: const TextStyle(color: CcColors.muted),
                          ),
                          if (canManage)
                            IconButton(
                              tooltip: canRemoveMember ? '移除' : '至少保留一个项目负责人',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              color: canRemoveMember
                                  ? CcColors.muted
                                  : CcColors.subtle,
                              onPressed: canRemoveMember
                                  ? () => _do(
                                      () => widget.client.removeMember(
                                        widget.id,
                                        m.identity,
                                      ),
                                    )
                                  : null,
                            ),
                        ],
                      ),
                    );
                  }),
                  if (canManage)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (memberCandidates.isNotEmpty)
                          SizedBox(
                            width: 260,
                            child: DropdownButtonFormField<String>(
                              initialValue: null,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                hintText: '从团队选择',
                                isDense: true,
                              ),
                              items: memberCandidates
                                  .map(
                                    (m) => DropdownMenuItem(
                                      value: m.identity,
                                      child: Text(
                                        _memberLabel(m),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) _member.text = v;
                              },
                            ),
                          ),
                        SizedBox(
                          width: 260,
                          child: TextField(
                            controller: _member,
                            decoration: const InputDecoration(
                              hintText: 'identity',
                              isDense: true,
                            ),
                          ),
                        ),
                        DropdownButton<String>(
                          value: _role,
                          items: const [
                            DropdownMenuItem(
                              value: 'member',
                              child: Text('成员'),
                            ),
                            DropdownMenuItem(
                              value: 'viewer',
                              child: Text('只读'),
                            ),
                            DropdownMenuItem(
                              value: 'owner',
                              child: Text('负责人'),
                            ),
                          ],
                          onChanged: (v) =>
                              setState(() => _role = v ?? 'member'),
                        ),
                        Tooltip(
                          message: memberInput.isNotEmpty && !canSubmitMember
                              ? '至少保留一个项目负责人'
                              : '加成员',
                          child: FilledButton.icon(
                            onPressed: canSubmitMember
                                ? () {
                                    final m = _member.text.trim();
                                    _member.clear();
                                    _do(
                                      () => widget.client.addMember(
                                        widget.id,
                                        m,
                                        _role,
                                      ),
                                    );
                                  }
                                : null,
                            icon: const Icon(
                              Icons.person_add_alt_1_rounded,
                              size: 18,
                            ),
                            label: const Text('加成员'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}
