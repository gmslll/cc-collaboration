import 'package:app/api/models.dart';
import 'package:app/screens/projects_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('global admin can manage organizations without an org role', () {
    final org = Organization.fromJson({
      'id': 'org1',
      'name': 'Kunlun',
      'owner_identity': 'owner@x',
      'role': '',
    });

    expect(canManageOrganization(org, isAdmin: true), isTrue);
    expect(canManageOrganization(org, isAdmin: false), isFalse);
  });

  test('organization owner and admin roles can manage organizations', () {
    Organization orgWithRole(String role) => Organization.fromJson({
      'id': 'org1',
      'name': 'Kunlun',
      'owner_identity': 'owner@x',
      'role': role,
    });

    expect(canManageOrganization(orgWithRole('owner'), isAdmin: false), isTrue);
    expect(canManageOrganization(orgWithRole('admin'), isAdmin: false), isTrue);
    expect(
      canManageOrganization(orgWithRole('member'), isAdmin: false),
      isFalse,
    );
    expect(
      canManageOrganization(orgWithRole('guest'), isAdmin: false),
      isFalse,
    );
  });

  test('organization role label reflects global admin fallback', () {
    expect(organizationRoleLabel('', isAdmin: true), '系统管理员');
    expect(organizationRoleLabel('', isAdmin: false), '成员');
    expect(organizationRoleLabel('owner', isAdmin: true), '负责人');
    expect(organizationRoleLabel('admin', isAdmin: true), '管理员');
    expect(organizationRoleLabel('member', isAdmin: true), '成员');
    expect(organizationRoleLabel('guest', isAdmin: true), '访客');
  });

  test('project role label uses team-facing Chinese labels', () {
    expect(projectRoleLabel(''), '成员');
    expect(projectRoleLabel('admin'), '管理员');
    expect(projectRoleLabel('owner'), '负责人');
    expect(projectRoleLabel('member'), '成员');
    expect(projectRoleLabel('viewer'), '只读');
    expect(projectRoleLabel('custom'), 'custom');
  });

  test('organization member picker label localizes roles', () {
    final named = OrganizationMember.fromJson({
      'identity': 'dev@x',
      'role': 'admin',
      'display_name': 'Dev',
    });
    final unnamed = OrganizationMember.fromJson({
      'identity': 'ops@x',
      'role': 'guest',
    });

    expect(organizationMemberPickerLabel(named), 'Dev · dev@x · 管理员');
    expect(organizationMemberPickerLabel(unnamed), 'ops@x · 访客');
  });

  test('organization member picker ignores blank display names', () {
    final member = OrganizationMember.fromJson({
      'identity': ' ops@x ',
      'role': ' guest ',
      'display_name': '   ',
    });

    expect(organizationMemberPickerLabel(member), 'ops@x · 访客');
  });

  test('organization member role updates protect the last owner', () {
    final owner = OrganizationMember.fromJson({
      'identity': ' owner@x ',
      'role': 'owner',
    });
    final member = OrganizationMember.fromJson({
      'identity': 'member@x',
      'role': 'member',
    });
    final secondOwner = OrganizationMember.fromJson({
      'identity': 'owner2@x',
      'role': 'owner',
    });

    expect(organizationOwnerCount([owner, member]), 1);
    expect(canRemoveOrganizationMember(owner, [owner, member]), isFalse);
    expect(canRemoveOrganizationMember(member, [owner, member]), isTrue);
    expect(
      canUpsertOrganizationMemberRole('owner@x', 'admin', [owner, member]),
      isFalse,
    );
    expect(
      canUpsertOrganizationMemberRole('owner@x', 'guest', [owner, member]),
      isFalse,
    );
    expect(
      canUpsertOrganizationMemberRole('owner@x', 'owner', [owner, member]),
      isTrue,
    );
    expect(
      canUpsertOrganizationMemberRole('owner@x', 'member', [
        owner,
        secondOwner,
        member,
      ]),
      isTrue,
    );
    expect(
      canUpsertOrganizationMemberRole('new@x', 'admin', [owner, member]),
      isTrue,
    );
    expect(canUpsertOrganizationMemberRole('', 'member', [owner]), isFalse);
  });

  test('project owner label uses localized owner text', () {
    expect(projectOwnerLabel('owner@x'), '负责人 · owner@x');
  });

  test(
    'project member display prefers display name with identity subtitle',
    () {
      final named = ProjectMember.fromJson({
        'identity': 'dev@x',
        'role': 'member',
        'display_name': 'Dev',
      });
      final unnamed = ProjectMember.fromJson({
        'identity': 'ops@x',
        'role': 'viewer',
      });

      expect(projectMemberTitle(named), 'Dev');
      expect(projectMemberSubtitle(named), 'dev@x');
      expect(projectMemberTitle(unnamed), 'ops@x');
      expect(projectMemberSubtitle(unnamed), isNull);
    },
  );

  test('project member display trims names and falls back on blank names', () {
    final named = ProjectMember.fromJson({
      'identity': ' dev@x ',
      'role': ' member ',
      'display_name': ' Dev ',
    });
    final blank = ProjectMember.fromJson({
      'identity': ' ops@x ',
      'role': ' viewer ',
      'display_name': '   ',
    });

    expect(projectMemberTitle(named), 'Dev');
    expect(projectMemberSubtitle(named), 'dev@x');
    expect(projectMemberTitle(blank), 'ops@x');
    expect(projectMemberSubtitle(blank), isNull);
  });

  test('project member removal protects the last project owner', () {
    final owner = ProjectMember.fromJson({
      'identity': 'owner@x',
      'role': 'owner',
    });
    final member = ProjectMember.fromJson({
      'identity': 'member@x',
      'role': 'member',
    });
    final secondOwner = ProjectMember.fromJson({
      'identity': 'owner2@x',
      'role': 'owner',
    });

    expect(projectOwnerCount([owner, member]), 1);
    expect(canRemoveProjectMember(owner, [owner, member]), isFalse);
    expect(canRemoveProjectMember(member, [owner, member]), isTrue);
    expect(canRemoveProjectMember(owner, [owner, secondOwner, member]), isTrue);
  });

  test('project member role updates protect the last project owner', () {
    final owner = ProjectMember.fromJson({
      'identity': ' owner@x ',
      'role': 'owner',
    });
    final member = ProjectMember.fromJson({
      'identity': 'member@x',
      'role': 'member',
    });
    final secondOwner = ProjectMember.fromJson({
      'identity': 'owner2@x',
      'role': 'owner',
    });

    expect(canUpsertProjectMemberRole('', 'member', [owner]), isFalse);
    expect(
      canUpsertProjectMemberRole('owner@x', 'member', [owner, member]),
      isFalse,
    );
    expect(
      canUpsertProjectMemberRole('owner@x', 'viewer', [owner, member]),
      isFalse,
    );
    expect(
      canUpsertProjectMemberRole('owner@x', 'owner', [owner, member]),
      isTrue,
    );
    expect(
      canUpsertProjectMemberRole('owner@x', 'member', [
        owner,
        secondOwner,
        member,
      ]),
      isTrue,
    );
    expect(
      canUpsertProjectMemberRole('new@x', 'viewer', [owner, member]),
      isTrue,
    );
  });
}
