import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../theme.dart';
import '../widgets.dart';

String normalizedRole(String role) => role.trim();

bool roleMatches(String left, String right) =>
    normalizedRole(left) == normalizedRole(right);

bool isManageRole(String role) {
  final value = normalizedRole(role);
  return value == 'owner' || value == 'admin';
}

bool canManageOrganization(Organization org, {required bool isAdmin}) =>
    isAdmin || isManageRole(org.role);

String organizationRoleLabel(String role, {required bool isAdmin}) {
  final value = normalizedRole(role);
  if (value.isEmpty && isAdmin) return '系统管理员';
  switch (value) {
    case 'owner':
      return '负责人';
    case 'admin':
      return '管理员';
    case 'member':
      return '成员';
    case 'guest':
      return '访客';
    default:
      return value.isEmpty ? '成员' : value;
  }
}

String organizationEditableRoleValue(String role) {
  final value = normalizedRole(role);
  if (value == 'owner' ||
      value == 'admin' ||
      value == 'member' ||
      value == 'guest') {
    return value;
  }
  return 'member';
}

String projectRoleLabel(String role) {
  final value = normalizedRole(role);
  switch (value) {
    case 'admin':
      return '管理员';
    case 'owner':
      return '负责人';
    case 'member':
      return '成员';
    case 'viewer':
      return '只读';
    default:
      return value.isEmpty ? '成员' : value;
  }
}

String projectEditableRoleValue(String role) {
  final value = normalizedRole(role);
  if (value == 'owner' || value == 'member' || value == 'viewer') return value;
  return 'member';
}

String projectListRoleLabel(
  Project project, {
  required bool isAdmin,
  required String identity,
}) {
  final role = normalizedRole(project.role);
  if (role.isNotEmpty) return projectRoleLabel(role);
  if (isAdmin) return projectRoleLabel('admin');
  if (identityMatches(project.ownerIdentity, identity)) {
    return projectRoleLabel('owner');
  }
  return projectRoleLabel('viewer');
}

String organizationMemberPickerLabel(OrganizationMember member) {
  final role = organizationRoleLabel(member.role, isAdmin: false);
  if (member.displayName.isEmpty) return '${member.identity} · $role';
  return '${member.displayName} · ${member.identity} · $role';
}

int organizationOwnerCount(Iterable<OrganizationMember> members) =>
    members.where((m) => normalizedRole(m.role) == 'owner').length;

bool canRemoveOrganizationMember(
  OrganizationMember member,
  Iterable<OrganizationMember> members,
) =>
    normalizedRole(member.role) != 'owner' ||
    organizationOwnerCount(members) > 1;

bool canUpsertOrganizationMemberRole(
  String identity,
  String nextRole,
  Iterable<OrganizationMember> members,
) {
  final id = identity.trim();
  final role = normalizedRole(nextRole);
  if (id.isEmpty) return false;
  if (role == 'owner') return true;
  for (final member in members) {
    if (member.identity.trim() == id) {
      return canRemoveOrganizationMember(member, members);
    }
  }
  return true;
}

String? organizationMemberRoleChangeBlockReason(
  OrganizationMember member,
  Iterable<OrganizationMember> members,
) => canRemoveOrganizationMember(member, members) ? null : '至少保留一个负责人';

String? organizationMemberRemovalBlockReason(
  OrganizationMember member,
  Iterable<OrganizationMember> members,
  Iterable<String> soleOwnedProjectNames, {
  required bool projectOwnerGuardComplete,
  Iterable<String> uncheckedProjectNames = const [],
}) {
  final roleReason = organizationMemberRoleChangeBlockReason(member, members);
  if (roleReason != null) return roleReason;
  if (!projectOwnerGuardComplete) {
    return projectOwnerGuardMessage(uncheckedProjectNames);
  }
  final names = [
    for (final name in soleOwnedProjectNames)
      if (name.trim().isNotEmpty) name.trim(),
  ];
  if (names.isEmpty) return null;
  return '先转移项目负责人: ${names.join(', ')}';
}

String projectOwnerGuardMessage(Iterable<String> uncheckedProjectNames) {
  final names = [
    for (final name in uncheckedProjectNames)
      if (name.trim().isNotEmpty) name.trim(),
  ];
  if (names.isEmpty) return '项目负责人状态未确认';
  return '项目负责人状态未确认: ${names.join(', ')}';
}

String identityDisplay(String identity) => identity.trim();

String projectOwnerLabel(String identity) =>
    '${projectRoleLabel('owner')} · ${identityDisplay(identity)}';

String projectListSubtitle(
  Project project, {
  required String teamName,
  required bool isAdmin,
  required String identity,
}) =>
    '$teamName · ${projectListRoleLabel(project, isAdmin: isAdmin, identity: identity)} · ${projectOwnerLabel(project.ownerIdentity)}';

bool identityMatches(String left, String right) {
  final l = left.trim();
  final r = right.trim();
  return l.isNotEmpty && l == r;
}

bool isIdentityOnline(Iterable<OnlineUser> onlineUsers, String identity) =>
    onlineUsers.any(
      (user) => user.online && identityMatches(user.identity, identity),
    );

bool canManageProjectDetail(
  ProjectDetail detail, {
  required bool isAdmin,
  required String identity,
}) {
  if (isAdmin) return true;
  if (isManageRole(detail.project.role)) return true;
  if (identityMatches(detail.project.ownerIdentity, identity)) return true;
  return detail.members.any(
    (member) =>
        identityMatches(member.identity, identity) &&
        normalizedRole(member.role) == 'owner',
  );
}

String projectMemberTitle(ProjectMember member) =>
    member.displayName.isEmpty ? member.identity : member.displayName;

String? projectMemberSubtitle(ProjectMember member) =>
    member.displayName.isEmpty ? null : member.identity;

int projectOwnerCount(Iterable<ProjectMember> members) =>
    members.where((m) => normalizedRole(m.role) == 'owner').length;

bool canRemoveProjectMember(
  ProjectMember member,
  Iterable<ProjectMember> members,
) => normalizedRole(member.role) != 'owner' || projectOwnerCount(members) > 1;

String? projectMemberRoleChangeBlockReason(
  ProjectMember member,
  Iterable<ProjectMember> members,
) => canRemoveProjectMember(member, members) ? null : '至少保留一个项目负责人';

bool canUpsertProjectMemberRole(
  String identity,
  String nextRole,
  Iterable<ProjectMember> members,
) {
  final id = identity.trim();
  final role = normalizedRole(nextRole);
  if (id.isEmpty) return false;
  if (role == 'owner') return true;
  for (final member in members) {
    if (member.identity.trim() == id) {
      return canRemoveProjectMember(member, members);
    }
  }
  return true;
}

List<OrganizationMember> projectMemberCandidates(
  Iterable<OrganizationMember> organizationMembers,
  Iterable<ProjectMember> projectMembers,
) {
  final projectIdentities = {
    for (final member in projectMembers)
      if (member.identity.trim().isNotEmpty) member.identity.trim(),
  };
  final seen = <String>{};
  final candidates = organizationMembers.where((member) {
    final identity = member.identity.trim();
    return identity.isNotEmpty &&
        !projectIdentities.contains(identity) &&
        seen.add(identity);
  }).toList();
  candidates.sort((a, b) {
    final an = a.displayName.isEmpty ? a.identity : a.displayName;
    final bn = b.displayName.isEmpty ? b.identity : b.displayName;
    return an.compareTo(bn);
  });
  return candidates;
}

double responsiveControlWidth(BoxConstraints constraints, double preferred) {
  final maxWidth = constraints.maxWidth;
  if (!maxWidth.isFinite || maxWidth <= 0) return preferred;
  return maxWidth < preferred ? maxWidth : preferred;
}

Map<String, List<String>> soleProjectOwnerNamesByIdentity(
  Iterable<ProjectDetail> details,
) {
  final out = <String, List<String>>{};
  for (final detail in details) {
    final owners = detail.members
        .where((m) => normalizedRole(m.role) == 'owner')
        .map((m) => m.identity.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (owners.length != 1) continue;
    final owner = owners.single;
    out.update(
      owner,
      (names) => [...names, detail.project.name],
      ifAbsent: () => [detail.project.name],
    );
  }
  return out;
}

typedef TeamWorkspaceStats = ({
  int teams,
  int manageableTeams,
  int projects,
  int onlineUsers,
});

TeamWorkspaceStats teamWorkspaceStats({
  required Iterable<Organization> organizations,
  required Iterable<Project> projects,
  required Iterable<OnlineUser> onlineUsers,
  required Set<String> manageableOrgIds,
}) {
  final onlineIdentities = <String>{
    for (final user in onlineUsers)
      if (user.online && user.identity.trim().isNotEmpty) user.identity.trim(),
  };
  return (
    teams: organizations.length,
    manageableTeams: organizations
        .where((org) => manageableOrgIds.contains(org.id))
        .length,
    projects: projects.length,
    onlineUsers: onlineIdentities.length,
  );
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
    _name.addListener(_onCreateInputChanged);
    _orgName.addListener(_onCreateInputChanged);
    _load();
  }

  @override
  void dispose() {
    _name.removeListener(_onCreateInputChanged);
    _orgName.removeListener(_onCreateInputChanged);
    _name.dispose();
    _orgName.dispose();
    super.dispose();
  }

  bool get _canCreateProject => _name.text.trim().isNotEmpty;
  bool get _canCreateOrg => _orgName.text.trim().isNotEmpty;

  void _onCreateInputChanged() {
    if (mounted) setState(() {});
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
                  final role = normalizedRole(org.role).isNotEmpty
                      ? org.role
                      : meOrgRoles[org.id] ?? '';
                  return isManageRole(role);
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
          _workspaceHeader(),
          const SizedBox(height: 12),
          _teamPanel(),
          const SizedBox(height: 12),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _workspaceHeader() {
    final stats = teamWorkspaceStats(
      organizations: _orgs,
      projects: _projects ?? const <Project>[],
      onlineUsers: _online,
      manageableOrgIds: _manageableOrgIds,
    );
    return Material(
      color: CcColors.panelHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CcRadius.md),
        side: const BorderSide(color: CcColors.borderSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final title = _workspaceTitle();
                final metrics = _workspaceMetrics(stats);
                if (constraints.maxWidth < 620) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 10), metrics],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Align(
                        alignment: Alignment.topRight,
                        child: metrics,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final fieldWidth = responsiveControlWidth(constraints, 260);
                final teamPickerWidth = responsiveControlWidth(
                  constraints,
                  240,
                );
                return Wrap(
                  runSpacing: 8,
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: fieldWidth,
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
                      onPressed: _canCreateOrg ? _createOrg : null,
                      icon: const Icon(Icons.group_add_rounded, size: 18),
                      label: const Text('新建团队'),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: fieldWidth,
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
                      SizedBox(
                        width: teamPickerWidth,
                        child: DropdownButton<String>(
                          value: _selectedOrgId ?? '',
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('我的默认团队'),
                            ),
                            ..._manageableOrgs.map(
                              (o) => DropdownMenuItem(
                                value: o.id,
                                child: Text(
                                  o.name,
                                  key: ValueKey('project-create-team-${o.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => _selectedOrgId = v),
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: _canCreateProject ? _create : null,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('新建项目'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _workspaceTitle() {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: CcColors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(CcRadius.md),
            border: Border.all(color: CcColors.accent.withValues(alpha: 0.36)),
          ),
          child: const Icon(
            Icons.hub_rounded,
            color: CcColors.accentBright,
            size: 19,
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '团队工作台',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 2),
              Text(
                '团队、项目、成员入口',
                style: TextStyle(color: CcColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _workspaceMetrics(TeamWorkspaceStats stats) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        _MetricPill(
          icon: Icons.groups_rounded,
          label: '团队',
          value: '${stats.teams}',
        ),
        _MetricPill(
          icon: Icons.admin_panel_settings_rounded,
          label: '可管理',
          value: '${stats.manageableTeams}',
          color: CcColors.accentBright,
        ),
        _MetricPill(
          icon: Icons.folder_rounded,
          label: '项目',
          value: '${stats.projects}',
        ),
        _MetricPill(
          icon: Icons.circle_rounded,
          label: '在线',
          value: '${stats.onlineUsers}',
          color: CcColors.ok,
        ),
      ],
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            projectListSubtitle(
                              p,
                              teamName: _teamName(p.orgId),
                              isAdmin: _isAdmin,
                              identity: _identity,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                          Flexible(
                            child: Text(
                              organizationRoleLabel(
                                org.role,
                                isAdmin: _isAdmin,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CcType.code(
                                size: 11.5,
                                color: CcColors.accentBright,
                              ),
                            ),
                          ),
                          Text(
                            '  ·  ',
                            style: CcType.code(
                              size: 11.5,
                              color: CcColors.subtle,
                            ),
                          ),
                          Flexible(
                            child: Text(
                              '${_orgProjectCount(org.id)} 项目',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CcType.code(
                                size: 11.5,
                                color: CcColors.muted,
                              ),
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

class _MetricPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetricPill({
    required this.icon,
    required this.label,
    required this.value,
    this.color = CcColors.muted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: CcColors.bg.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(CcRadius.pill),
        border: Border.all(color: CcColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(value, style: CcType.code(size: 12, color: CcColors.text)),
          const SizedBox(width: 4),
          Text(label, style: CcType.code(size: 11, color: CcColors.muted)),
        ],
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
  Map<String, List<String>> _soleProjectOwnerNames = const {};
  bool _projectOwnerGuardComplete = true;
  List<String> _uncheckedProjectOwnerNames = const [];
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
      var soleProjectOwnerNames = const <String, List<String>>{};
      var projectOwnerGuardComplete = true;
      final uncheckedProjectOwnerNames = <String>[];
      if (_canManageDetail(detail)) {
        final projectDetails = <ProjectDetail>[];
        for (final project in detail.projects) {
          try {
            projectDetails.add(await widget.client.project(project.id));
          } catch (_) {
            projectOwnerGuardComplete = false;
            uncheckedProjectOwnerNames.add(project.name);
          }
        }
        soleProjectOwnerNames = soleProjectOwnerNamesByIdentity(projectDetails);
      }
      if (mounted) {
        setState(() {
          _detail = detail;
          _soleProjectOwnerNames = soleProjectOwnerNames;
          _projectOwnerGuardComplete = projectOwnerGuardComplete;
          _uncheckedProjectOwnerNames = uncheckedProjectOwnerNames;
        });
      }
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<bool> _do(Future<void> Function() action) async {
    try {
      await action();
      await _load();
      widget.onChanged();
      return true;
    } catch (e) {
      if (mounted) snack(context, errorText(e));
      return false;
    }
  }

  bool _canManage(OrganizationDetail d) => _canManageDetail(d);

  bool _canManageDetail(OrganizationDetail d) =>
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
    final ok = await _do(
      () => widget.client.addOrganizationMember(widget.id, identity, _role),
    );
    if (ok) _identity.clear();
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final canManage = d != null && _canManage(d);
    final memberInput = _identity.text.trim();
    final canSubmitMember =
        d != null &&
        canUpsertOrganizationMemberRole(memberInput, _role, d.members);
    final projectOwnerGuardWarning = _projectOwnerGuardComplete
        ? null
        : projectOwnerGuardMessage(_uncheckedProjectOwnerNames);
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
                  if (projectOwnerGuardWarning != null) ...[
                    const SizedBox(height: 6),
                    _InlineWarning(projectOwnerGuardWarning),
                  ],
                  const SizedBox(height: 6),
                  ...d.members.map((m) {
                    final soleOwnedProjects =
                        _soleProjectOwnerNames[m.identity.trim()] ??
                        const <String>[];
                    final roleChangeBlockReason =
                        organizationMemberRoleChangeBlockReason(m, d.members);
                    final removeBlockReason =
                        organizationMemberRemovalBlockReason(
                          m,
                          d.members,
                          soleOwnedProjects,
                          projectOwnerGuardComplete: _projectOwnerGuardComplete,
                          uncheckedProjectNames: _uncheckedProjectOwnerNames,
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
                                    value: organizationEditableRoleValue(
                                      m.role,
                                    ),
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
                                    onChanged: roleChangeBlockReason == null
                                        ? (role) {
                                            if (role == null ||
                                                roleMatches(role, m.role)) {
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
                                  tooltip: removeBlockReason ?? '移除',
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: removeBlockReason == null
                                        ? CcColors.muted
                                        : CcColors.subtle,
                                  ),
                                  onPressed: removeBlockReason == null
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
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final memberFieldWidth = responsiveControlWidth(
                          constraints,
                          280,
                        );
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: memberFieldWidth,
                              child: TextField(
                                controller: _identity,
                                decoration: const InputDecoration(
                                  hintText: '成员 identity',
                                  isDense: true,
                                  prefixIcon: Icon(
                                    Icons.alternate_email_rounded,
                                  ),
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
                                DropdownMenuItem(
                                  value: 'guest',
                                  child: Text('访客'),
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
                              message:
                                  memberInput.isNotEmpty && !canSubmitMember
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
                        );
                      },
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

class _InlineWarning extends StatelessWidget {
  final String text;

  const _InlineWarning(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: CcColors.warning.withValues(alpha: 0.10),
        border: Border.all(color: CcColors.warning.withValues(alpha: 0.36)),
        borderRadius: BorderRadius.circular(CcRadius.md),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: CcColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: CcColors.warning, fontSize: 12),
            ),
          ),
        ],
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
    _repo.addListener(_onRepoInputChanged);
    _member.addListener(_onMemberInputChanged);
    _load();
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepoInputChanged);
    _member.removeListener(_onMemberInputChanged);
    _repo.dispose();
    _member.dispose();
    super.dispose();
  }

  bool get _canMapRepo => _repo.text.trim().isNotEmpty;

  void _onRepoInputChanged() {
    if (mounted) setState(() {});
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

  Future<bool> _do(Future<void> Function() action) async {
    try {
      await action();
      await _load();
      widget.onChanged();
      return true;
    } catch (e) {
      if (mounted) snack(context, errorText(e));
      return false;
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

  bool _isOnline(String identity) => isIdentityOnline(widget.online, identity);

  bool _canManage(ProjectDetail d) => canManageProjectDetail(
    d,
    isAdmin: widget.isAdmin,
    identity: widget.identity,
  );

  List<OrganizationMember> _memberCandidates(ProjectDetail d) =>
      projectMemberCandidates(_orgMembers, d.members);

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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                      _CompactProjectChip(
                        icon: Icons.groups_rounded,
                        label: widget.teamName,
                      ),
                      _CompactProjectChip(
                        icon: Icons.person_rounded,
                        label: projectOwnerLabel(d.project.ownerIdentity),
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
                                (r) => _CompactProjectChip(
                                  label: r,
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
                          onPressed: _canMapRepo
                              ? () async {
                                  final r = _repo.text.trim();
                                  final ok = await _do(
                                    () => widget.client.mapRepo(widget.id, r),
                                  );
                                  if (ok) _repo.clear();
                                }
                              : null,
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
                    final roleChangeBlockReason =
                        projectMemberRoleChangeBlockReason(m, d.members);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: statusDot(
                        _isOnline(m.identity) ? CcColors.ok : CcColors.subtle,
                        size: 9,
                        glow: _isOnline(m.identity),
                      ),
                      title: Text(
                        projectMemberTitle(m),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: subtitle == null
                          ? null
                          : Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (canManage)
                            DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: projectEditableRoleValue(m.role),
                                isDense: true,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'owner',
                                    child: Text('负责人'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'member',
                                    child: Text('成员'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'viewer',
                                    child: Text('只读'),
                                  ),
                                ],
                                onChanged: roleChangeBlockReason == null
                                    ? (role) {
                                        if (role == null ||
                                            roleMatches(role, m.role)) {
                                          return;
                                        }
                                        _do(
                                          () => widget.client.addMember(
                                            widget.id,
                                            m.identity,
                                            role,
                                          ),
                                        );
                                      }
                                    : null,
                              ),
                            )
                          else
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
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final memberControlWidth = responsiveControlWidth(
                          constraints,
                          260,
                        );
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (memberCandidates.isNotEmpty)
                              SizedBox(
                                width: memberControlWidth,
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
                              width: memberControlWidth,
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
                              message:
                                  memberInput.isNotEmpty && !canSubmitMember
                                  ? '至少保留一个项目负责人'
                                  : '加成员',
                              child: FilledButton.icon(
                                onPressed: canSubmitMember
                                    ? () async {
                                        final m = _member.text.trim();
                                        final ok = await _do(
                                          () => widget.client.addMember(
                                            widget.id,
                                            m,
                                            _role,
                                          ),
                                        );
                                        if (ok) _member.clear();
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
                        );
                      },
                    ),
                ],
              ),
            ),
    );
  }
}

class _CompactProjectChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onDeleted;

  const _CompactProjectChip({this.icon, required this.label, this.onDeleted});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Chip(
        avatar: icon == null ? null : Icon(icon, size: 16),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        onDeleted: onDeleted,
      ),
    );
  }
}
