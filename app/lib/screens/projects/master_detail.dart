part of '../projects_page.dart';

const double projectsTeamRailWidth = 220;

bool useCompactProjectsLayout(double width) => width < 760;

bool isMyProject(Project project, String identity) {
  final role = normalizedRole(project.role);
  return identityMatches(project.ownerIdentity, identity) ||
      role == 'owner' ||
      role == 'member' ||
      role == 'viewer';
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
  List<Invitation> _invitations = const [];
  Set<String> _manageableOrgIds = const <String>{};
  List<OnlineUser> _online = const [];
  Map<String, ProjectDetail> _projectDetails = const {};
  OrganizationDetail? _selectedOrgDetail;
  bool _selectedOrgLoading = false;
  bool _isAdmin = false;
  bool _creatingProject = false;
  bool _creatingOrg = false;
  bool _handlingInvitation = false;
  String _identity = '';
  String _selection = 'all';
  int _teamTab = 0;
  String? _error;
  final _search = TextEditingController();
  int _loadGeneration = 0;
  int _detailGeneration = 0;
  int _orgDetailGeneration = 0;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant ProjectsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client == widget.client) return;
    _loadGeneration++;
    _detailGeneration++;
    _orgDetailGeneration++;
    _search.clear();
    setState(() {
      _projects = null;
      _orgs = const [];
      _invitations = const [];
      _manageableOrgIds = const <String>{};
      _online = const [];
      _projectDetails = const {};
      _selectedOrgDetail = null;
      _selectedOrgLoading = false;
      _isAdmin = false;
      _creatingProject = false;
      _creatingOrg = false;
      _handlingInvitation = false;
      _identity = '';
      _selection = 'all';
      _teamTab = 0;
      _error = null;
    });
    _load();
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchChanged);
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final client = widget.client;
    try {
      final orgs = await Future.sync(
        client.organizations,
      ).catchError((_) => <Organization>[]);
      Me? me;
      try {
        me = await client.me();
      } catch (_) {
        me = null;
      }
      final projects = await client.projects();
      final online = await Future.sync(
        client.onlineUsers,
      ).catchError((_) => <OnlineUser>[]);
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
      if (!_isCurrentLoad(generation, client)) return;
      setState(() {
        _orgs = orgs;
        _invitations = me?.invitations ?? const [];
        _manageableOrgIds = manageableOrgIds;
        _isAdmin = me?.isAdmin == true;
        _identity = me?.identity ?? '';
        _projects = projects;
        _online = online;
        if (_selection.startsWith('org:') &&
            !orgs.any((org) => 'org:${org.id}' == _selection)) {
          _selection = 'all';
          _teamTab = 0;
        }
        _error = null;
      });
      unawaited(_loadProjectDetails(client, projects));
      final org = _selectedOrganization;
      if (org != null) unawaited(_loadSelectedOrganization(org));
    } catch (e) {
      if (_isCurrentLoad(generation, client)) setState(() => _error = '$e');
    }
  }

  Future<void> _loadProjectDetails(
    RelayClient client,
    List<Project> projects,
  ) async {
    final generation = ++_detailGeneration;
    final entries = await Future.wait([
      for (final project in projects) _loadOneProject(client, project.id),
    ]);
    if (!mounted ||
        generation != _detailGeneration ||
        !identical(client, widget.client)) {
      return;
    }
    setState(() {
      _projectDetails = {
        for (final entry in entries)
          if (entry != null) entry.key: entry.value,
      };
    });
  }

  Future<MapEntry<String, ProjectDetail>?> _loadOneProject(
    RelayClient client,
    String id,
  ) async {
    try {
      return MapEntry(id, await client.project(id));
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSelectedOrganization(Organization org) async {
    final generation = ++_orgDetailGeneration;
    final client = widget.client;
    setState(() {
      _selectedOrgLoading = true;
      _selectedOrgDetail = null;
    });
    try {
      final detail = await client.organization(org.id);
      if (!_isCurrentOrgDetail(generation, client, org.id)) return;
      setState(() {
        _selectedOrgDetail = detail;
        _selectedOrgLoading = false;
      });
    } catch (e) {
      if (!_isCurrentOrgDetail(generation, client, org.id)) return;
      setState(() => _selectedOrgLoading = false);
      if (!mounted) return;
      snack(context, '团队详情加载失败: ${errorText(e)}');
    }
  }

  bool _isCurrentLoad(int generation, RelayClient client) =>
      mounted &&
      generation == _loadGeneration &&
      identical(client, widget.client);

  bool _isCurrentOrgDetail(int generation, RelayClient client, String orgId) =>
      mounted &&
      generation == _orgDetailGeneration &&
      identical(client, widget.client) &&
      _selection == 'org:$orgId';

  bool _isCurrentClient(RelayClient client) =>
      mounted && identical(client, widget.client);

  Organization? get _selectedOrganization {
    if (!_selection.startsWith('org:')) return null;
    final id = _selection.substring(4);
    for (final org in _orgs) {
      if (org.id == id) return org;
    }
    return null;
  }

  List<Organization> get _manageableOrgs =>
      _orgs.where((org) => _manageableOrgIds.contains(org.id)).toList();

  String _teamName(String id) {
    for (final org in _orgs) {
      if (org.id == id) return org.name;
    }
    return id.isEmpty ? '未分配团队' : id;
  }

  int _orgProjectCount(String orgId) =>
      (_projects ?? const <Project>[]).where((p) => p.orgId == orgId).length;

  List<Project> get _visibleProjects {
    final orgById = {for (final org in _orgs) org.id: org};
    final query = _search.text;
    return (_projects ?? const <Project>[])
        .where((project) {
          if (!projectVisibleForSearch(
            project,
            query,
            team: orgById[project.orgId],
            fallbackTeamName: _teamName(project.orgId),
            isAdmin: _isAdmin,
            identity: _identity,
          )) {
            return false;
          }
          if (_selection == 'mine') return isMyProject(project, _identity);
          final org = _selectedOrganization;
          return org == null || project.orgId == org.id;
        })
        .toList(growable: false);
  }

  void _selectScope(String selection) {
    if (_selection == selection) return;
    setState(() {
      _selection = selection;
      _teamTab = 0;
      _selectedOrgDetail = null;
      _selectedOrgLoading = false;
    });
    final org = _selectedOrganization;
    if (org != null) unawaited(_loadSelectedOrganization(org));
  }

  Future<void> _createOrganization() async {
    if (_creatingOrg) return;
    final client = widget.client;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const OrganizationCreateDialog(),
    );
    if (name == null || !_isCurrentClient(client)) return;
    setState(() => _creatingOrg = true);
    try {
      final org = await client.createOrganization(name);
      if (!_isCurrentClient(client)) return;
      _selection = 'org:${org.id}';
      await _load();
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, '创建团队失败: ${errorText(e)}');
    } finally {
      if (_isCurrentClient(client)) setState(() => _creatingOrg = false);
    }
  }

  Future<void> _createProject({Organization? initialTeam}) async {
    if (_creatingProject) return;
    if (_manageableOrgs.isEmpty) {
      snack(context, '没有可管理的团队，请先创建团队或联系团队管理员');
      return;
    }
    final client = widget.client;
    final draft = await showDialog<ProjectCreateDraft>(
      context: context,
      builder: (_) => ProjectCreateDialog(
        organizations: _manageableOrgs,
        initialOrgId: initialTeam?.id,
      ),
    );
    if (draft == null || !_isCurrentClient(client)) return;
    setState(() => _creatingProject = true);
    try {
      await client.createProject(draft.name, orgId: draft.orgId);
      if (!_isCurrentClient(client)) return;
      _selection = 'org:${draft.orgId}';
      await _load();
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, '创建项目失败: ${errorText(e)}');
    } finally {
      if (_isCurrentClient(client)) setState(() => _creatingProject = false);
    }
  }

  Future<void> _acceptInvitation(Invitation invitation) async {
    if (_handlingInvitation) return;
    final client = widget.client;
    setState(() => _handlingInvitation = true);
    try {
      await client.acceptInvitation(invitation.id);
      if (_isCurrentClient(client)) await _load();
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, '接受邀请失败: ${errorText(e)}');
    } finally {
      if (_isCurrentClient(client)) {
        setState(() => _handlingInvitation = false);
      }
    }
  }

  Future<void> _declineInvitation(Invitation invitation) async {
    if (_handlingInvitation) return;
    final client = widget.client;
    final ok = await confirm(
      context,
      '拒绝 ${invitationTargetLabel(invitation)} 的邀请？',
      title: '拒绝邀请',
      okLabel: '拒绝',
    );
    if (!ok || !_isCurrentClient(client)) return;
    setState(() => _handlingInvitation = true);
    try {
      await client.declineInvitation(invitation.id);
      if (_isCurrentClient(client)) await _load();
    } catch (e) {
      if (!mounted || !identical(client, widget.client)) return;
      snack(context, '拒绝邀请失败: ${errorText(e)}');
    } finally {
      if (_isCurrentClient(client)) {
        setState(() => _handlingInvitation = false);
      }
    }
  }

  Future<void> _showOrganizationSheet(Organization org) async {
    final client = widget.client;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OrganizationSheet(
        client: client,
        id: org.id,
        isAdmin: _isAdmin,
        isCurrentContext: () => _isCurrentClient(client),
        onChanged: _load,
      ),
    );
  }

  void _showProject(Project project) {
    final client = widget.client;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ProjectSheet(
        client: client,
        id: project.id,
        teamName: _teamName(project.orgId),
        identity: _identity,
        isAdmin: _isAdmin,
        online: _online,
        isCurrentContext: () => _isCurrentClient(client),
        onChanged: _load,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: CcColors.danger)),
      );
    }
    if (_projects == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (useCompactProjectsLayout(constraints.maxWidth)) {
          return Column(
            children: [
              _compactTeamPicker(),
              const Divider(height: 1),
              Expanded(child: _mainPane()),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
              key: const ValueKey('projects-team-rail'),
              width: projectsTeamRailWidth,
              child: _teamRail(),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _mainPane()),
          ],
        );
      },
    );
  }

  Widget _teamRail() {
    return Material(
      color: CcColors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 16, 12, 8),
            child: Text(
              '团队项目',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ),
          _scopeTile('all', Icons.folder_copy_outlined, '全部项目'),
          _scopeTile('mine', Icons.person_outline_rounded, '我的项目'),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 12, 6),
            child: Text(
              '已加入的团队',
              style: TextStyle(color: CcColors.muted, fontSize: 11.5),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _orgs.length,
              itemBuilder: (_, index) {
                final org = _orgs[index];
                return _scopeTile(
                  'org:${org.id}',
                  _manageableOrgIds.contains(org.id)
                      ? Icons.admin_panel_settings_outlined
                      : Icons.groups_outlined,
                  org.name,
                  count: _orgProjectCount(org.id),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: OutlinedButton.icon(
              onPressed: _creatingOrg ? null : _createOrganization,
              icon: _creatingOrg
                  ? const _InlineButtonSpinner()
                  : const Icon(Icons.group_add_outlined, size: 17),
              label: Text(_creatingOrg ? '创建中' : '新建团队'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scopeTile(String value, IconData icon, String label, {int? count}) {
    final selected = _selection == value;
    return ListTile(
      key: ValueKey('project-scope-$value'),
      dense: true,
      selected: selected,
      selectedTileColor: CcColors.accent.withValues(alpha: 0.12),
      leading: Icon(
        icon,
        size: 18,
        color: selected ? CcColors.accentBright : CcColors.muted,
      ),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: count == null
          ? null
          : Text(
              '$count',
              style: CcType.code(size: 11, color: CcColors.subtle),
            ),
      onTap: () => _selectScope(value),
    );
  }

  Widget _compactTeamPicker() {
    return Material(
      key: const ValueKey('projects-compact-team-picker'),
      color: CcColors.panel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selection,
                  isExpanded: true,
                  menuMaxHeight: projectsMenuMaxHeight(
                    MediaQuery.sizeOf(context),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text('全部项目', overflow: TextOverflow.ellipsis),
                    ),
                    const DropdownMenuItem(
                      value: 'mine',
                      child: Text('我的项目', overflow: TextOverflow.ellipsis),
                    ),
                    for (final org in _orgs)
                      DropdownMenuItem(
                        value: 'org:${org.id}',
                        child: Text(
                          org.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) _selectScope(value);
                  },
                ),
              ),
            ),
            IconButton(
              tooltip: '新建团队',
              onPressed: _creatingOrg ? null : _createOrganization,
              icon: const Icon(Icons.group_add_outlined, size: 19),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mainPane() {
    final selectedOrg = _selectedOrganization;
    final title = selectedOrg?.name ?? (_selection == 'mine' ? '我的项目' : '全部项目');
    final projects = _visibleProjects;
    final memberSummary = _selectedOrgLoading
        ? '成员加载中'
        : _selectedOrgDetail == null
        ? '成员信息不可用'
        : '${_selectedOrgDetail!.members.length} 名成员';
    final summary = selectedOrg == null
        ? '${projects.length} 个可见项目'
        : '${_orgProjectCount(selectedOrg.id)} 个项目 · $memberSummary · ${organizationRoleLabel(selectedOrg.role, isAdmin: _isAdmin)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.code(size: 11.5, color: CcColors.muted),
                    ),
                  ],
                ),
              ),
              if (selectedOrg == null && _manageableOrgs.isNotEmpty)
                IconButton(
                  tooltip: '新建项目',
                  onPressed: _creatingProject ? null : () => _createProject(),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                ),
              if (selectedOrg != null)
                PopupMenuButton<String>(
                  tooltip: '团队管理',
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (value) {
                    if (value == 'manage') {
                      _showOrganizationSheet(selectedOrg);
                    }
                    if (value == 'create') {
                      _createProject(initialTeam: selectedOrg);
                    }
                  },
                  itemBuilder: (_) => [
                    if (_manageableOrgIds.contains(selectedOrg.id))
                      ccMenuItem(
                        value: 'create',
                        icon: Icons.create_new_folder_outlined,
                        label: '新建项目',
                      ),
                    ccMenuItem(
                      value: 'manage',
                      icon: _manageableOrgIds.contains(selectedOrg.id)
                          ? Icons.settings_outlined
                          : Icons.info_outline_rounded,
                      label: _manageableOrgIds.contains(selectedOrg.id)
                          ? '管理团队'
                          : '查看团队详情',
                    ),
                  ],
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: '搜索团队 / 项目 / 负责人',
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _search.clear,
                    ),
            ),
          ),
        ),
        if (selectedOrg == null && _invitations.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _InvitationPanel(
              invitations: _invitations,
              busy: _handlingInvitation,
              onAccept: _acceptInvitation,
              onDecline: _declineInvitation,
            ),
          ),
        if (selectedOrg != null) _teamTabs(),
        const Divider(height: 1),
        Expanded(
          child: selectedOrg == null
              ? _projectList(projects)
              : switch (_teamTab) {
                  1 => _memberList(),
                  2 => _invitationList(selectedOrg),
                  _ => _projectList(projects),
                },
        ),
      ],
    );
  }

  Widget _teamTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _teamTabButton(0, Icons.folder_outlined, '项目'),
          _teamTabButton(1, Icons.people_outline_rounded, '成员'),
          _teamTabButton(2, Icons.mail_outline_rounded, '邀请'),
        ],
      ),
    );
  }

  Widget _teamTabButton(int value, IconData icon, String label) {
    final selected = _teamTab == value;
    return TextButton.icon(
      key: ValueKey('project-team-tab-$value'),
      onPressed: () => setState(() => _teamTab = value),
      style: TextButton.styleFrom(
        foregroundColor: selected ? CcColors.accentBright : CcColors.muted,
      ),
      icon: Icon(icon, size: 17),
      label: Text(label),
    );
  }

  Widget _projectList(List<Project> projects) {
    if (projects.isEmpty) {
      return Center(
        child: Text(
          _search.text.trim().isEmpty ? '这里还没有项目' : '没有匹配的项目',
          style: const TextStyle(color: CcColors.muted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemCount: projects.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 48),
      itemBuilder: (_, index) {
        final project = projects[index];
        final detail = _projectDetails[project.id];
        final repos = detail?.cloneableRepos ?? const <ProjectRepo>[];
        final repoText = repos.isNotEmpty
            ? repos.map((repo) => repo.cloneUrl).join(' · ')
            : detail == null
            ? '仓库信息加载中…'
            : '未绑定 GitHub 仓库';
        return ListTile(
          key: ValueKey('project-row-${project.id}'),
          dense: true,
          leading: const Icon(
            Icons.folder_outlined,
            color: CcColors.accent,
            size: 20,
          ),
          title: Text(
            project.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                repoText,
                key: ValueKey('project-row-repos-${project.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(
                  size: 11.5,
                  color: repos.isEmpty ? CcColors.subtle : CcColors.muted,
                ),
              ),
              if (_selectedOrganization == null)
                Text(
                  _teamName(project.orgId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CcColors.subtle,
                    fontSize: 11.5,
                  ),
                ),
            ],
          ),
          trailing: Text(
            projectListRoleLabel(
              project,
              isAdmin: _isAdmin,
              identity: _identity,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 11, color: CcColors.muted),
          ),
          onTap: () => _showProject(project),
        );
      },
    );
  }

  Widget _memberList() {
    if (_selectedOrgLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final members = _selectedOrgDetail?.members ?? const <OrganizationMember>[];
    if (members.isEmpty) {
      return const Center(
        child: Text('没有可显示的成员', style: TextStyle(color: CcColors.muted)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      itemCount: members.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 44),
      itemBuilder: (_, index) {
        final member = members[index];
        final online = isIdentityOnline(_online, member.identity);
        return ListTile(
          dense: true,
          leading: statusDot(
            online ? CcColors.ok : CcColors.subtle,
            size: 9,
            glow: online,
          ),
          title: Text(
            member.displayName.isEmpty ? member.identity : member.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: member.displayName.isEmpty
              ? null
              : Text(
                  member.identity,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Text(
            organizationRoleLabel(member.role, isAdmin: false),
            style: CcType.code(size: 11.5, color: CcColors.muted),
          ),
        );
      },
    );
  }

  Widget _invitationList(Organization org) {
    if (_selectedOrgLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final incoming = _invitations
        .where((invitation) => invitation.orgId == org.id)
        .toList();
    final pending = _selectedOrgDetail?.invitations ?? const <Invitation>[];
    if (incoming.isEmpty && pending.isEmpty) {
      return const Center(
        child: Text('没有待处理邀请', style: TextStyle(color: CcColors.muted)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        if (incoming.isNotEmpty)
          _InvitationPanel(
            invitations: incoming,
            busy: _handlingInvitation,
            onAccept: _acceptInvitation,
            onDecline: _declineInvitation,
          ),
        if (pending.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Text(
              '已发出 · 等待接受',
              style: TextStyle(color: CcColors.muted, fontSize: 12),
            ),
          ),
          for (final invitation in pending)
            ListTile(
              dense: true,
              leading: const Icon(Icons.schedule_send_outlined, size: 18),
              title: Text(
                invitation.identity,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                invitationRoleLabel(invitation),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ],
    );
  }
}

class ProjectCreateDraft {
  final String name, orgId;

  const ProjectCreateDraft({required this.name, required this.orgId});
}

class OrganizationCreateDialog extends StatefulWidget {
  const OrganizationCreateDialog({super.key});

  @override
  State<OrganizationCreateDialog> createState() =>
      _OrganizationCreateDialogState();
}

class _OrganizationCreateDialogState extends State<OrganizationCreateDialog> {
  final _controller = TextEditingController();
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = !_submitted && _controller.text.trim().isNotEmpty;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('新建团队', maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: projectDialogWidth(MediaQuery.sizeOf(context)),
        child: TextField(
          key: const ValueKey('create-organization-name'),
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '团队名称'),
          onSubmitted: (_) {
            if (valid) _submit();
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: valid ? _submit : null,
          child: const Text('创建'),
        ),
      ],
    );
  }

  void _submit() {
    if (_submitted || _controller.text.trim().isEmpty) return;
    _submitted = true;
    Navigator.pop(context, _controller.text.trim());
  }
}

class ProjectCreateDialog extends StatefulWidget {
  final List<Organization> organizations;
  final String? initialOrgId;

  const ProjectCreateDialog({
    super.key,
    required this.organizations,
    this.initialOrgId,
  });

  @override
  State<ProjectCreateDialog> createState() => _ProjectCreateDialogState();
}

class _ProjectCreateDialogState extends State<ProjectCreateDialog> {
  final _controller = TextEditingController();
  bool _submitted = false;
  late String _orgId =
      createProjectTeamId(widget.initialOrgId, widget.organizations) ?? '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (_submitted || name.isEmpty || _orgId.isEmpty) return;
    _submitted = true;
    Navigator.pop(context, ProjectCreateDraft(name: name, orgId: _orgId));
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        !_submitted && _controller.text.trim().isNotEmpty && _orgId.isNotEmpty;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('新建项目', maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: projectDialogWidth(MediaQuery.sizeOf(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('create-project-name'),
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '项目名称'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('create-project-team'),
              initialValue: _orgId,
              isExpanded: true,
              menuMaxHeight: projectsMenuMaxHeight(MediaQuery.sizeOf(context)),
              decoration: const InputDecoration(labelText: '所属团队'),
              items: [
                for (final org in widget.organizations)
                  DropdownMenuItem(
                    value: org.id,
                    child: Text(
                      org.name,
                      key: ValueKey('project-create-team-${org.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _orgId = value ?? ''),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: valid ? _submit : null,
          child: const Text('创建'),
        ),
      ],
    );
  }
}
