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
}
