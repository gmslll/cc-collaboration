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

  test('project owner label uses localized owner text', () {
    expect(projectOwnerLabel('owner@x'), '负责人 · owner@x');
  });
}
