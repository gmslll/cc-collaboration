import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/identity.dart' as identity_utils;
import '../theme.dart';
import '../widgets.dart';

part 'projects/master_detail.dart';

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

String invitationTargetLabel(Invitation invitation) {
  if (invitation.scope == 'project') {
    final project = invitation.projectName.isEmpty
        ? invitation.projectId
        : invitation.projectName;
    final org = invitation.orgName.isEmpty
        ? invitation.orgId
        : invitation.orgName;
    return org.isEmpty ? project : '$org · $project';
  }
  return invitation.orgName.isEmpty ? invitation.orgId : invitation.orgName;
}

String invitationRoleLabel(Invitation invitation) =>
    invitation.scope == 'project'
    ? projectRoleLabel(invitation.role)
    : organizationRoleLabel(invitation.role, isAdmin: false);

String invitationScopeLabel(Invitation invitation) =>
    invitation.scope == 'project' ? '项目邀请' : '团队邀请';

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
  final id = identity_utils.cleanedIdentity(identity);
  final role = normalizedRole(nextRole);
  if (id.isEmpty) return false;
  if (role == 'owner') return true;
  for (final member in members) {
    if (identityMatches(member.identity, id)) {
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

String identityDisplay(String identity) =>
    identity_utils.cleanedIdentity(identity);

String projectOwnerLabel(String identity) =>
    '${projectRoleLabel('owner')} · ${identityDisplay(identity)}';

String projectListSubtitle(
  Project project, {
  required String teamName,
  required bool isAdmin,
  required String identity,
}) =>
    '$teamName · ${projectListRoleLabel(project, isAdmin: isAdmin, identity: identity)} · ${projectOwnerLabel(project.ownerIdentity)}';

String normalizedProjectSearchQuery(String query) => query.trim().toLowerCase();

bool organizationMatchesSearch(Organization org, String query) {
  final q = normalizedProjectSearchQuery(query);
  if (q.isEmpty) return true;
  return [
    org.name,
    org.id,
    org.ownerIdentity,
    organizationRoleLabel(org.role, isAdmin: false),
  ].any((value) => value.toLowerCase().contains(q));
}

bool projectMatchesSearch(
  Project project,
  String query, {
  required String teamName,
  required bool isAdmin,
  required String identity,
}) {
  final q = normalizedProjectSearchQuery(query);
  if (q.isEmpty) return true;
  return [
    project.name,
    project.id,
    teamName,
    project.ownerIdentity,
    projectListRoleLabel(project, isAdmin: isAdmin, identity: identity),
  ].any((value) => value.toLowerCase().contains(q));
}

bool projectVisibleForSearch(
  Project project,
  String query, {
  required Organization? team,
  required String fallbackTeamName,
  required bool isAdmin,
  required String identity,
}) {
  final q = normalizedProjectSearchQuery(query);
  if (q.isEmpty) return true;
  if (team != null && organizationMatchesSearch(team, q)) return true;
  return projectMatchesSearch(
    project,
    q,
    teamName: team?.name ?? fallbackTeamName,
    isAdmin: isAdmin,
    identity: identity,
  );
}

bool identityMatches(String left, String right) =>
    identity_utils.sameIdentity(left, right);

bool isIdentityOnline(Iterable<OnlineUser> onlineUsers, String identity) =>
    onlineUsers.any(
      (user) => user.online && identityMatches(user.identity, identity),
    );

String? githubRepoNameFromCloneUrl(String value) {
  final input = value.trim();
  if (input.isEmpty ||
      input.length > 2048 ||
      input.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      input.contains(RegExp(r'[?#%]'))) {
    return null;
  }
  String path;
  if (input.toLowerCase().startsWith('git@github.com:')) {
    path = input.substring(input.indexOf(':') + 1);
  } else {
    final uri = Uri.tryParse(input);
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        (scheme != 'https' && scheme != 'ssh') ||
        uri.host.toLowerCase() != 'github.com' ||
        uri.hasPort ||
        (scheme == 'https' && uri.userInfo.isNotEmpty) ||
        (scheme == 'ssh' && uri.userInfo != 'git')) {
      return null;
    }
    path = uri.path;
  }
  path = path.replaceFirst(RegExp(r'^/+'), '').replaceFirst(RegExp(r'/+$'), '');
  final parts = path.split('/');
  if (parts.length != 2) return null;
  final owner = parts.first;
  final name = parts.last.endsWith('.git')
      ? parts.last.substring(0, parts.last.length - 4)
      : parts.last;
  final component = RegExp(r'^[A-Za-z0-9_.-]+$');
  if (owner.isEmpty ||
      name.isEmpty ||
      owner == '.' ||
      owner == '..' ||
      name == '.' ||
      name == '..' ||
      !component.hasMatch(owner) ||
      !component.hasMatch(name)) {
    return null;
  }
  return name;
}

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

String projectMemberCandidateSortLabel(OrganizationMember member) {
  final label = member.displayName.isEmpty
      ? member.identity
      : member.displayName;
  return label.trim().toLowerCase();
}

bool canUpsertProjectMemberRole(
  String identity,
  String nextRole,
  Iterable<ProjectMember> members,
) {
  final id = identity_utils.cleanedIdentity(identity);
  final role = normalizedRole(nextRole);
  if (id.isEmpty) return false;
  if (role == 'owner') return true;
  for (final member in members) {
    if (identityMatches(member.identity, id)) {
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
      if (identity_utils.identityLookupKey(member.identity).isNotEmpty)
        identity_utils.identityLookupKey(member.identity),
  };
  final seen = <String>{};
  final candidates = organizationMembers.where((member) {
    final identity = identity_utils.identityLookupKey(member.identity);
    return identity.isNotEmpty &&
        !projectIdentities.contains(identity) &&
        seen.add(identity);
  }).toList();
  candidates.sort((a, b) {
    final byLabel = projectMemberCandidateSortLabel(
      a,
    ).compareTo(projectMemberCandidateSortLabel(b));
    if (byLabel != 0) return byLabel;
    return a.identity.compareTo(b.identity);
  });
  return candidates;
}

String? createProjectTeamId(
  String? selectedOrgId,
  Iterable<Organization> manageableOrgs,
) {
  final orgs = manageableOrgs.toList(growable: false);
  if (orgs.isEmpty) return null;
  final id = selectedOrgId?.trim() ?? '';
  if (id.isEmpty) return orgs.first.id;
  return orgs.any((org) => org.id == id) ? id : orgs.first.id;
}

double responsiveControlWidth(BoxConstraints constraints, double preferred) {
  final maxWidth = constraints.maxWidth;
  if (!maxWidth.isFinite || maxWidth <= 0) return preferred;
  return maxWidth < preferred ? maxWidth : preferred;
}

double projectDialogWidth(Size screenSize, {double preferred = 420}) {
  final available = screenSize.width - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

double memberActionWidth(
  BoxConstraints constraints, {
  double preferred = 156,
  double maxFraction = 0.48,
}) {
  final maxWidth = constraints.maxWidth;
  if (!maxWidth.isFinite || maxWidth <= 0) return preferred;
  final available = maxWidth * maxFraction.clamp(0, 1);
  return available < preferred ? available : preferred;
}

double projectsMenuMaxHeight(
  Size screenSize, {
  double preferred = 320,
  double minHeight = 160,
  double maxFraction = 0.58,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

double projectSheetLoadingHeight(
  Size screenSize, {
  double preferred = 180,
  double minHeight = 96,
  double maxFraction = 0.28,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

Map<String, List<String>> soleProjectOwnerNamesByIdentity(
  Iterable<ProjectDetail> details,
) {
  final out = <String, List<String>>{};
  for (final detail in details) {
    final owners = detail.members
        .where((m) => normalizedRole(m.role) == 'owner')
        .map((m) => identity_utils.identityLookupKey(m.identity))
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

class _InvitationPanel extends StatelessWidget {
  final List<Invitation> invitations;
  final bool busy;
  final ValueChanged<Invitation> onAccept;
  final ValueChanged<Invitation> onDecline;

  const _InvitationPanel({
    required this.invitations,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CcColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CcRadius.md),
        side: const BorderSide(color: CcColors.borderSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.mark_email_unread_rounded,
                  size: 18,
                  color: CcColors.accentBright,
                ),
                const SizedBox(width: 8),
                Text(
                  '待处理邀请',
                  style: CcType.code(size: 12, color: CcColors.text),
                ),
                const Spacer(),
                Text(
                  '${invitations.length}',
                  style: CcType.code(size: 12, color: CcColors.muted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: invitations.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final invitation = invitations[index];
                  return _IncomingInvitationTile(
                    invitation: invitation,
                    busy: busy,
                    onAccept: () => onAccept(invitation),
                    onDecline: () => onDecline(invitation),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingInvitationTile extends StatelessWidget {
  final Invitation invitation;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _IncomingInvitationTile({
    required this.invitation,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            invitation.scope == 'project'
                ? Icons.folder_shared_rounded
                : Icons.groups_rounded,
            size: 18,
            color: CcColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invitationTargetLabel(invitation),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${invitationScopeLabel(invitation)} · ${invitationRoleLabel(invitation)} · ${invitation.inviterIdentity}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 11, color: CcColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '拒绝',
            onPressed: busy ? null : onDecline,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
          FilledButton.icon(
            onPressed: busy ? null : onAccept,
            icon: busy
                ? const _InlineButtonSpinner()
                : const Icon(Icons.check_rounded, size: 18),
            label: const Text('接受'),
          ),
        ],
      ),
    );
  }
}

class _InlineButtonSpinner extends StatelessWidget {
  const _InlineButtonSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

class _OrganizationSheet extends StatefulWidget {
  final RelayClient client;
  final String id;
  final bool isAdmin;
  final bool Function() isCurrentContext;
  final VoidCallback onChanged;

  const _OrganizationSheet({
    required this.client,
    required this.id,
    required this.isAdmin,
    required this.isCurrentContext,
    required this.onChanged,
  });

  @override
  State<_OrganizationSheet> createState() => _OrganizationSheetState();
}

class _OrganizationSheetState extends State<_OrganizationSheet> {
  OrganizationDetail? _detail;
  Map<String, List<String>> _soleProjectOwnerNames = const {};
  bool _projectOwnerGuardComplete = true;
  String? _mutationAction;
  List<String> _uncheckedProjectOwnerNames = const [];
  int _loadGeneration = 0;
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

  bool get _mutating => _mutationAction != null;

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final detail = await widget.client.organization(widget.id);
      if (!_isCurrentLoad(generation)) return;
      var soleProjectOwnerNames = const <String, List<String>>{};
      var projectOwnerGuardComplete = true;
      final uncheckedProjectOwnerNames = <String>[];
      if (_canManageDetail(detail)) {
        final projectDetails = <ProjectDetail>[];
        for (final project in detail.projects) {
          try {
            projectDetails.add(await widget.client.project(project.id));
            if (!_isCurrentLoad(generation)) return;
          } catch (_) {
            if (!_isCurrentLoad(generation)) return;
            projectOwnerGuardComplete = false;
            uncheckedProjectOwnerNames.add(project.name);
          }
        }
        soleProjectOwnerNames = soleProjectOwnerNamesByIdentity(projectDetails);
      }
      if (_isCurrentLoad(generation)) {
        setState(() {
          _detail = detail;
          _soleProjectOwnerNames = soleProjectOwnerNames;
          _projectOwnerGuardComplete = projectOwnerGuardComplete;
          _uncheckedProjectOwnerNames = uncheckedProjectOwnerNames;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (generation != _loadGeneration || !widget.isCurrentContext()) return;
      snack(context, errorText(e));
    }
  }

  bool _isCurrentLoad(int generation) =>
      mounted && generation == _loadGeneration && widget.isCurrentContext();

  bool _closeIfStaleContext() {
    if (widget.isCurrentContext()) return false;
    Navigator.pop(context);
    return true;
  }

  Future<bool> _do(
    Future<void> Function() action, {
    String actionKey = 'mutation',
  }) async {
    if (!mounted) return false;
    if (_mutating) return false;
    if (_closeIfStaleContext()) return false;
    if (mounted) setState(() => _mutationAction = actionKey);
    try {
      await action();
      if (!mounted) return false;
      if (_closeIfStaleContext()) return false;
      await _load();
      if (!mounted) return false;
      if (_closeIfStaleContext()) return false;
      widget.onChanged();
      return true;
    } catch (e) {
      if (!mounted) return false;
      if (_closeIfStaleContext()) return false;
      if (mounted) snack(context, errorText(e));
      return false;
    } finally {
      if (mounted && widget.isCurrentContext()) {
        setState(() => _mutationAction = null);
      }
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
    if (!mounted) return;
    await _do(
      () => widget.client.removeOrganizationMember(widget.id, identity),
    );
  }

  Future<void> _addMember() async {
    final identity = _identity.text.trim();
    if (identity.isEmpty) return;
    final ok = await _do(
      () => widget.client.addOrganizationMember(widget.id, identity, _role),
      actionKey: 'addOrgMember',
    );
    if (ok) _identity.clear();
  }

  Future<void> _inviteMember() async {
    final identity = _identity.text.trim();
    if (identity.isEmpty) return;
    final ok = await _do(
      () => widget.client
          .inviteOrganizationMember(widget.id, identity, _role)
          .then((_) {}),
      actionKey: 'inviteOrgMember',
    );
    if (ok) _identity.clear();
  }

  Future<void> _cancelInvitation(String invitationId) async {
    await _do(
      () => widget.client.cancelOrganizationInvitation(widget.id, invitationId),
      actionKey: 'cancelOrgInvitation',
    );
  }

  Future<void> _deleteOrganization() async {
    final d = _detail;
    if (d == null) return;
    final name = d.organization.name.trim();
    final projectCount = d.projects.length;
    final detail = projectCount == 0
        ? '将删除团队 "$name"。成员和待处理邀请会一并删除，删除后不可恢复。'
        : '将删除团队 "$name"，并同时删除 $projectCount 个项目、项目成员、项目待办和邀请。删除后不可恢复。';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: const Text(
            '删除团队?',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: projectDialogWidth(size),
            child: SingleChildScrollView(child: Text(detail)),
          ),
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
        );
      },
    );
    if (ok != true) return;
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    if (_mutating) return;
    if (mounted) setState(() => _mutationAction = 'deleteOrganization');
    try {
      await widget.client.deleteOrganization(widget.id);
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      widget.onChanged();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      if (mounted) snack(context, errorText(e));
    } finally {
      if (mounted && widget.isCurrentContext()) {
        setState(() => _mutationAction = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final canManage = d != null && _canManage(d);
    final memberInput = _identity.text.trim();
    final canSubmitMember =
        d != null &&
        !_mutating &&
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
          ? SizedBox(
              height: projectSheetLoadingHeight(MediaQuery.sizeOf(context)),
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CcType.code(
                                size: 12,
                                color: CcColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (canManage)
                        SizedBox(
                          width: 36,
                          height: 36,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: '删除团队',
                            icon: _mutationAction == 'deleteOrganization'
                                ? const _InlineButtonSpinner()
                                : const Icon(
                                    Icons.delete_rounded,
                                    size: 18,
                                    color: CcColors.danger,
                                  ),
                            onPressed: _mutating ? null : _deleteOrganization,
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
                        _soleProjectOwnerNames[identity_utils.identityLookupKey(
                          m.identity,
                        )] ??
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
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final actionWidth = memberActionWidth(constraints);
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
                              ? SizedBox(
                                  width: actionWidth,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Expanded(
                                        child: DropdownButtonHideUnderline(
                                          child: DropdownButton<String>(
                                            value:
                                                organizationEditableRoleValue(
                                                  m.role,
                                                ),
                                            isDense: true,
                                            isExpanded: true,
                                            menuMaxHeight:
                                                projectsMenuMaxHeight(
                                                  MediaQuery.sizeOf(context),
                                                ),
                                            selectedItemBuilder: (_) => const [
                                              _RoleMenuText('负责人'),
                                              _RoleMenuText('管理员'),
                                              _RoleMenuText('成员'),
                                              _RoleMenuText('访客'),
                                            ],
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
                                            onChanged:
                                                !_mutating &&
                                                    roleChangeBlockReason ==
                                                        null
                                                ? (role) {
                                                    if (role == null ||
                                                        roleMatches(
                                                          role,
                                                          m.role,
                                                        )) {
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
                                      ),
                                      SizedBox(
                                        width: 36,
                                        height: 36,
                                        child: IconButton(
                                          padding: EdgeInsets.zero,
                                          tooltip: removeBlockReason ?? '移除',
                                          icon: Icon(
                                            Icons.close_rounded,
                                            size: 18,
                                            color: removeBlockReason == null
                                                ? CcColors.muted
                                                : CcColors.subtle,
                                          ),
                                          onPressed:
                                              !_mutating &&
                                                  removeBlockReason == null
                                              ? () => _removeMember(m.identity)
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : SizedBox(
                                  width: actionWidth,
                                  child: Text(
                                    organizationRoleLabel(
                                      m.role,
                                      isAdmin: false,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      color: CcColors.muted,
                                    ),
                                  ),
                                ),
                        );
                      },
                    );
                  }),
                  if (canManage && d.invitations.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '待接受邀请',
                      style: CcType.code(size: 12, color: CcColors.muted),
                    ),
                    ...d.invitations.map(
                      (invitation) => _PendingInvitationTile(
                        invitation: invitation,
                        busy: _mutating,
                        onCancel: () => _cancelInvitation(invitation.id),
                      ),
                    ),
                  ],
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
                                enabled: !_mutating,
                                decoration: const InputDecoration(
                                  hintText: '成员 identity',
                                  isDense: true,
                                  prefixIcon: Icon(
                                    Icons.alternate_email_rounded,
                                  ),
                                ),
                                onEditingComplete: () {
                                  if (canSubmitMember) _addMember();
                                },
                                onSubmitted: (_) {
                                  if (canSubmitMember) _addMember();
                                },
                              ),
                            ),
                            DropdownButton<String>(
                              value: _role,
                              menuMaxHeight: projectsMenuMaxHeight(
                                MediaQuery.sizeOf(context),
                              ),
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
                              onChanged: _mutating
                                  ? null
                                  : (v) =>
                                        setState(() => _role = v ?? 'member'),
                            ),
                            Tooltip(
                              message:
                                  memberInput.isNotEmpty && !canSubmitMember
                                  ? '至少保留一个负责人'
                                  : '加入团队',
                              child: FilledButton.icon(
                                onPressed: canSubmitMember ? _addMember : null,
                                icon: _mutationAction == 'addOrgMember'
                                    ? const _InlineButtonSpinner()
                                    : const Icon(
                                        Icons.person_add_alt_1_rounded,
                                        size: 18,
                                      ),
                                label: Text(
                                  _mutationAction == 'addOrgMember'
                                      ? '加入中'
                                      : '加入团队',
                                ),
                              ),
                            ),
                            Tooltip(
                              message:
                                  memberInput.isNotEmpty && !canSubmitMember
                                  ? '至少保留一个负责人'
                                  : '邀请加入团队',
                              child: OutlinedButton.icon(
                                onPressed: canSubmitMember
                                    ? _inviteMember
                                    : null,
                                icon: _mutationAction == 'inviteOrgMember'
                                    ? const _InlineButtonSpinner()
                                    : const Icon(
                                        Icons.mark_email_unread_rounded,
                                        size: 18,
                                      ),
                                label: Text(
                                  _mutationAction == 'inviteOrgMember'
                                      ? '邀请中'
                                      : '邀请',
                                ),
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
                    const _CompactEmptyState(
                      icon: Icons.folder_off_rounded,
                      title: '还没有项目',
                      detail: '在团队工作台新建项目后，会出现在这里。',
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

class _RoleMenuText extends StatelessWidget {
  final String text;

  const _RoleMenuText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}

class _CompactEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;

  const _CompactEmptyState({
    required this.icon,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 420),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: CcColors.bg.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(CcRadius.md),
          border: Border.all(color: CcColors.borderSoft),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: CcColors.panel.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(CcRadius.sm),
                border: Border.all(color: CcColors.border),
              ),
              child: Icon(icon, size: 16, color: CcColors.muted),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: CcColors.muted, fontSize: 12),
                  ),
                ],
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
  final bool Function() isCurrentContext;
  final VoidCallback onChanged;
  const _ProjectSheet({
    required this.client,
    required this.id,
    required this.teamName,
    required this.identity,
    required this.isAdmin,
    required this.online,
    required this.isCurrentContext,
    required this.onChanged,
  });

  @override
  State<_ProjectSheet> createState() => _ProjectSheetState();
}

class _ProjectSheetState extends State<_ProjectSheet> {
  ProjectDetail? _d;
  List<OrganizationMember> _orgMembers = const [];
  String? _mutationAction;
  int _loadGeneration = 0;
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

  bool get _canMapRepo => githubRepoNameFromCloneUrl(_repo.text) != null;

  void _onRepoInputChanged() {
    if (mounted) setState(() {});
  }

  void _onMemberInputChanged() {
    if (mounted) setState(() {});
  }

  bool get _mutating => _mutationAction != null;

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final d = await widget.client.project(widget.id);
      if (!_isCurrentLoad(generation)) return;
      var orgMembers = const <OrganizationMember>[];
      if (d.project.orgId.isNotEmpty) {
        try {
          final org = await widget.client.organization(d.project.orgId);
          if (!_isCurrentLoad(generation)) return;
          orgMembers = org.members;
        } catch (_) {
          if (!_isCurrentLoad(generation)) return;
          orgMembers = const [];
        }
      }
      if (_isCurrentLoad(generation)) {
        setState(() {
          _d = d;
          _orgMembers = orgMembers;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (generation != _loadGeneration || !widget.isCurrentContext()) return;
      snack(context, errorText(e));
    }
  }

  bool _isCurrentLoad(int generation) =>
      mounted && generation == _loadGeneration && widget.isCurrentContext();

  bool _closeIfStaleContext() {
    if (widget.isCurrentContext()) return false;
    Navigator.pop(context);
    return true;
  }

  Future<bool> _do(
    Future<void> Function() action, {
    String actionKey = 'mutation',
  }) async {
    if (!mounted) return false;
    if (_mutating) return false;
    if (_closeIfStaleContext()) return false;
    if (mounted) setState(() => _mutationAction = actionKey);
    try {
      await action();
      if (!mounted) return false;
      if (_closeIfStaleContext()) return false;
      await _load();
      if (!mounted) return false;
      if (_closeIfStaleContext()) return false;
      widget.onChanged();
      return true;
    } catch (e) {
      if (!mounted) return false;
      if (_closeIfStaleContext()) return false;
      if (mounted) snack(context, errorText(e));
      return false;
    } finally {
      if (mounted && widget.isCurrentContext()) {
        setState(() => _mutationAction = null);
      }
    }
  }

  Future<void> _rename(String current) async {
    final ctl = TextEditingController(text: current);
    bool ok = false;
    String name = '';
    try {
      ok =
          await showDialog<bool>(
            context: context,
            builder: (ctx) {
              final size = MediaQuery.sizeOf(ctx);
              return AlertDialog(
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                title: const Text(
                  '重命名项目',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                content: SizedBox(
                  width: projectDialogWidth(size),
                  child: TextField(
                    controller: ctl,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: '项目名称'),
                    onSubmitted: (_) => Navigator.pop(ctx, true),
                  ),
                ),
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
              );
            },
          ) ==
          true;
      name = ctl.text.trim();
    } finally {
      ctl.dispose();
    }
    if (!ok || name.isEmpty) return;
    if (!mounted) return;
    await _do(() => widget.client.renameProject(widget.id, name));
  }

  Future<void> _removeMember(String identity) async {
    final ok = await confirm(
      context,
      '从项目移除 $identity ? 该用户将失去这个项目的访问权。',
      title: '移除项目成员',
      okLabel: '移除',
    );
    if (!ok) return;
    if (!mounted) return;
    await _do(() => widget.client.removeMember(widget.id, identity));
  }

  Future<void> _addMember() async {
    final member = _member.text.trim();
    if (member.isEmpty) return;
    final d = _d;
    if (d == null || !canUpsertProjectMemberRole(member, _role, d.members)) {
      return;
    }
    final ok = await _do(
      () => widget.client.addMember(widget.id, member, _role),
      actionKey: 'addProjectMember',
    );
    if (ok) _member.clear();
  }

  Future<void> _inviteMember() async {
    final member = _member.text.trim();
    if (member.isEmpty) return;
    final d = _d;
    if (d == null || !canUpsertProjectMemberRole(member, _role, d.members)) {
      return;
    }
    final ok = await _do(
      () => widget.client
          .inviteProjectMember(widget.id, member, _role)
          .then((_) {}),
      actionKey: 'inviteProjectMember',
    );
    if (ok) _member.clear();
  }

  Future<void> _cancelInvitation(String invitationId) async {
    await _do(
      () => widget.client.cancelProjectInvitation(widget.id, invitationId),
      actionKey: 'cancelProjectInvitation',
    );
  }

  Future<void> _bindRepo() async {
    final cloneUrl = _repo.text.trim();
    final repoName = githubRepoNameFromCloneUrl(cloneUrl);
    if (repoName == null) return;
    final ok = await _do(
      () => widget.client
          .upsertProjectRepo(widget.id, repoName, cloneUrl)
          .then((_) {}),
      actionKey: 'mapRepo',
    );
    if (ok) _repo.clear();
  }

  Future<void> _editRepo(ProjectRepo repo) async {
    final cloneUrl = await showDialog<String>(
      context: context,
      builder: (_) => _RepoUrlDialog(repo: repo),
    );
    if (cloneUrl == null || !mounted) return;
    await _do(
      () => widget.client
          .upsertProjectRepo(widget.id, repo.repoName, cloneUrl)
          .then((_) {}),
      actionKey: 'editRepo:${repo.repoName}',
    );
  }

  Future<void> _unbindRepo(ProjectRepo repo) async {
    final ok = await confirm(
      context,
      '解除 ${repo.repoName} 与此团队项目的绑定？本地仓库不会被删除。',
      title: '解绑 GitHub 仓库',
      okLabel: '解绑',
    );
    if (!ok || !mounted) return;
    await _do(
      () => widget.client.unmapRepo(widget.id, repo.repoName),
      actionKey: 'unmapRepo:${repo.repoName}',
    );
  }

  Future<void> _delete() async {
    final projectName = _d?.project.name.trim() ?? '';
    final detail = projectName.isEmpty
        ? '删除后不可恢复(repo / 成员映射一并删除)。'
        : '将删除项目 "$projectName"。删除后不可恢复(repo / 成员映射一并删除)。';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: const Text(
            '删除项目?',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: projectDialogWidth(size),
            child: SingleChildScrollView(child: Text(detail)),
          ),
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
        );
      },
    );
    if (ok != true) return;
    if (!mounted) return;
    if (_closeIfStaleContext()) return;
    if (_mutating) return;
    if (mounted) setState(() => _mutationAction = 'deleteProject');
    try {
      await widget.client.deleteProject(widget.id);
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      widget.onChanged();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      if (mounted) snack(context, errorText(e));
    } finally {
      if (mounted && widget.isCurrentContext()) {
        setState(() => _mutationAction = null);
      }
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
        d != null &&
        !_mutating &&
        canUpsertProjectMemberRole(memberInput, _role, d.members);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: d == null
          ? SizedBox(
              height: projectSheetLoadingHeight(MediaQuery.sizeOf(context)),
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
                          onPressed: _mutating
                              ? null
                              : () => _rename(d.project.name),
                        ),
                        IconButton(
                          icon: _mutationAction == 'deleteProject'
                              ? const _InlineButtonSpinner()
                              : const Icon(
                                  Icons.delete_rounded,
                                  size: 18,
                                  color: CcColors.danger,
                                ),
                          tooltip: '删除',
                          onPressed: _mutating ? null : _delete,
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
                    'GitHub 仓库',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (d.repoBindings.isEmpty)
                    const _CompactEmptyState(
                      icon: Icons.link_off_rounded,
                      title: '还没有绑定 GitHub 仓库',
                      detail: '添加 clone URL 后，成员可从工作区拉取团队项目。',
                    )
                  else
                    ...d.repoBindings.map(
                      (repo) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.code_rounded, size: 18),
                        title: Text(
                          repo.repoName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          repo.cloneUrl.isEmpty
                              ? '历史绑定 · 尚未添加 GitHub clone URL'
                              : repo.cloneUrl,
                          key: ValueKey('project-repo-url-${repo.repoName}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(
                            size: 11.5,
                            color: repo.cloneUrl.isEmpty
                                ? CcColors.warning
                                : CcColors.muted,
                          ),
                        ),
                        trailing: canManage
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: repo.cloneUrl.isEmpty
                                        ? '补充 GitHub URL'
                                        : '更新 GitHub URL',
                                    onPressed: _mutating
                                        ? null
                                        : () => _editRepo(repo),
                                    icon:
                                        _mutationAction ==
                                            'editRepo:${repo.repoName}'
                                        ? const _InlineButtonSpinner()
                                        : const Icon(
                                            Icons.edit_rounded,
                                            size: 18,
                                          ),
                                  ),
                                  IconButton(
                                    tooltip: '解绑',
                                    onPressed: _mutating
                                        ? null
                                        : () => _unbindRepo(repo),
                                    icon: const Icon(
                                      Icons.link_off_rounded,
                                      size: 18,
                                    ),
                                  ),
                                ],
                              )
                            : null,
                      ),
                    ),
                  if (canManage) ...[
                    const SizedBox(height: 6),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final inferred = githubRepoNameFromCloneUrl(_repo.text);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _repo,
                              enabled: !_mutating,
                              keyboardType: TextInputType.url,
                              decoration: InputDecoration(
                                hintText: 'GitHub HTTPS / SSH URL',
                                isDense: true,
                                prefixIcon: const Icon(Icons.link_rounded),
                                helperText: _repo.text.trim().isEmpty
                                    ? '不会保存 token 或密码，私有仓库使用本机 Git/SSH 凭据'
                                    : inferred == null
                                    ? '请输入 github.com 的 HTTPS 或 SSH clone URL'
                                    : '仓库名：$inferred',
                                errorText:
                                    _repo.text.trim().isNotEmpty &&
                                        inferred == null
                                    ? 'GitHub URL 无效'
                                    : null,
                              ),
                              onSubmitted: (_) {
                                if (_canMapRepo && !_mutating) _bindRepo();
                              },
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton.icon(
                                onPressed: _canMapRepo && !_mutating
                                    ? _bindRepo
                                    : null,
                                icon: _mutationAction == 'mapRepo'
                                    ? const _InlineButtonSpinner()
                                    : const Icon(
                                        Icons.add_link_rounded,
                                        size: 18,
                                      ),
                                label: Text(
                                  _mutationAction == 'mapRepo' ? '绑定中' : '绑定仓库',
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
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
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final actionWidth = memberActionWidth(constraints);
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: statusDot(
                            _isOnline(m.identity)
                                ? CcColors.ok
                                : CcColors.subtle,
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
                          trailing: SizedBox(
                            width: actionWidth,
                            child: canManage
                                ? Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Expanded(
                                        child: DropdownButtonHideUnderline(
                                          child: DropdownButton<String>(
                                            value: projectEditableRoleValue(
                                              m.role,
                                            ),
                                            isDense: true,
                                            isExpanded: true,
                                            menuMaxHeight:
                                                projectsMenuMaxHeight(
                                                  MediaQuery.sizeOf(context),
                                                ),
                                            selectedItemBuilder: (_) => const [
                                              _RoleMenuText('负责人'),
                                              _RoleMenuText('成员'),
                                              _RoleMenuText('只读'),
                                            ],
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
                                            onChanged:
                                                !_mutating &&
                                                    roleChangeBlockReason ==
                                                        null
                                                ? (role) {
                                                    if (role == null ||
                                                        roleMatches(
                                                          role,
                                                          m.role,
                                                        )) {
                                                      return;
                                                    }
                                                    _do(
                                                      () => widget.client
                                                          .addMember(
                                                            widget.id,
                                                            m.identity,
                                                            role,
                                                          ),
                                                    );
                                                  }
                                                : null,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 36,
                                        height: 36,
                                        child: IconButton(
                                          padding: EdgeInsets.zero,
                                          tooltip: canRemoveMember
                                              ? '移除'
                                              : '至少保留一个项目负责人',
                                          icon: const Icon(
                                            Icons.close_rounded,
                                            size: 18,
                                          ),
                                          color: canRemoveMember
                                              ? CcColors.muted
                                              : CcColors.subtle,
                                          onPressed:
                                              !_mutating && canRemoveMember
                                              ? () => _removeMember(m.identity)
                                              : null,
                                        ),
                                      ),
                                    ],
                                  )
                                : Text(
                                    projectRoleLabel(m.role),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      color: CcColors.muted,
                                    ),
                                  ),
                          ),
                        );
                      },
                    );
                  }),
                  if (canManage && d.invitations.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '待接受邀请',
                      style: CcType.code(size: 12, color: CcColors.muted),
                    ),
                    ...d.invitations.map(
                      (invitation) => _PendingInvitationTile(
                        invitation: invitation,
                        busy: _mutating,
                        onCancel: () => _cancelInvitation(invitation.id),
                      ),
                    ),
                  ],
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
                                  menuMaxHeight: projectsMenuMaxHeight(
                                    MediaQuery.sizeOf(context),
                                  ),
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
                                            key: ValueKey(
                                              'project-member-candidate-${m.identity}',
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: _mutating
                                      ? null
                                      : (v) {
                                          if (v != null) _member.text = v;
                                        },
                                ),
                              ),
                            SizedBox(
                              width: memberControlWidth,
                              child: TextField(
                                controller: _member,
                                enabled: !_mutating,
                                textInputAction: TextInputAction.done,
                                decoration: const InputDecoration(
                                  hintText: 'identity',
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
                              menuMaxHeight: projectsMenuMaxHeight(
                                MediaQuery.sizeOf(context),
                              ),
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
                              onChanged: _mutating
                                  ? null
                                  : (v) =>
                                        setState(() => _role = v ?? 'member'),
                            ),
                            Tooltip(
                              message:
                                  memberInput.isNotEmpty && !canSubmitMember
                                  ? '至少保留一个项目负责人'
                                  : '加成员',
                              child: FilledButton.icon(
                                onPressed: canSubmitMember ? _addMember : null,
                                icon: _mutationAction == 'addProjectMember'
                                    ? const _InlineButtonSpinner()
                                    : const Icon(
                                        Icons.person_add_alt_1_rounded,
                                        size: 18,
                                      ),
                                label: Text(
                                  _mutationAction == 'addProjectMember'
                                      ? '添加中'
                                      : '加成员',
                                ),
                              ),
                            ),
                            Tooltip(
                              message:
                                  memberInput.isNotEmpty && !canSubmitMember
                                  ? '至少保留一个项目负责人'
                                  : '邀请加入项目',
                              child: OutlinedButton.icon(
                                onPressed: canSubmitMember
                                    ? _inviteMember
                                    : null,
                                icon: _mutationAction == 'inviteProjectMember'
                                    ? const _InlineButtonSpinner()
                                    : const Icon(
                                        Icons.mark_email_unread_rounded,
                                        size: 18,
                                      ),
                                label: Text(
                                  _mutationAction == 'inviteProjectMember'
                                      ? '邀请中'
                                      : '邀请',
                                ),
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

class _PendingInvitationTile extends StatelessWidget {
  final Invitation invitation;
  final bool busy;
  final VoidCallback onCancel;

  const _PendingInvitationTile({
    required this.invitation,
    required this.busy,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.schedule_send_rounded, size: 18),
      title: Text(
        invitation.identity,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${invitationRoleLabel(invitation)} · ${invitation.inviterIdentity}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: '取消邀请',
        onPressed: busy ? null : onCancel,
        icon: const Icon(Icons.close_rounded, size: 18),
      ),
    );
  }
}

class _RepoUrlDialog extends StatefulWidget {
  final ProjectRepo repo;

  const _RepoUrlDialog({required this.repo});

  @override
  State<_RepoUrlDialog> createState() => _RepoUrlDialogState();
}

class _RepoUrlDialogState extends State<_RepoUrlDialog> {
  bool _submitted = false;
  late final TextEditingController _controller = TextEditingController(
    text: widget.repo.cloneUrl,
  )..addListener(_changed);

  void _changed() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        !_submitted && githubRepoNameFromCloneUrl(_controller.text) != null;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(
        widget.repo.cloneUrl.isEmpty ? '补充 GitHub URL' : '更新 GitHub URL',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: projectDialogWidth(MediaQuery.sizeOf(context)),
        child: TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: widget.repo.repoName,
            hintText: 'https://github.com/org/repo.git',
            helperText: '仓库名保持不变；不会保存 GitHub 凭据',
            errorText: _controller.text.trim().isNotEmpty && !valid
                ? 'GitHub URL 无效'
                : null,
          ),
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
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _submit() {
    if (_submitted || githubRepoNameFromCloneUrl(_controller.text) == null) {
      return;
    }
    _submitted = true;
    Navigator.pop(context, _controller.text.trim());
  }
}

class _CompactProjectChip extends StatelessWidget {
  final IconData? icon;
  final String label;

  const _CompactProjectChip({this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Chip(
        avatar: icon == null ? null : Icon(icon, size: 16),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
