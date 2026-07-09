import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/screens/admin_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _longAdminIdentity =
    'admin.with.a.very.long.identity.for.account.management@kunlun.example.com';
const _longAdminDisplayName =
    'Account Administrator With A Very Long Display Name For Team Management';

void main() {
  test('admin account labels are localized', () {
    expect(adminFlagLabel(true), '系统管理员');
    expect(adminFlagLabel(false), '普通成员');
    expect(disabledFlagLabel(true), '已停用');
    expect(disabledFlagLabel(false), '已启用');
  });

  test('admin toggle label describes the next action', () {
    expect(adminToggleLabel(true), '取消管理员');
    expect(adminToggleLabel(false), '设为管理员');
  });

  test('admin user labels prefer display names with identity subtitle', () {
    final named = User.fromJson({
      'identity': 'admin@x',
      'display_name': 'Admin',
    });
    final unnamed = User.fromJson({'identity': 'ops@x'});

    expect(adminUserTitle(named), 'Admin');
    expect(adminUserSubtitle(named), 'admin@x');
    expect(adminUserTitle(unnamed), 'ops@x');
    expect(adminUserSubtitle(unnamed), isNull);
  });

  testWidgets('admin user rows clamp long account labels', (tester) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: _AdminPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(
      find.byKey(ValueKey('admin-user-title-$_longAdminIdentity')),
    );
    final subtitle = tester.widget<Text>(
      find.byKey(ValueKey('admin-user-subtitle-$_longAdminIdentity')),
    );

    expect(tester.takeException(), isNull);
    expect(title.data, _longAdminDisplayName);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(subtitle.data, _longAdminIdentity);
    expect(subtitle.maxLines, 1);
    expect(subtitle.overflow, TextOverflow.ellipsis);
    expect(find.text('系统管理员'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
  });
}

class _AdminPageFakeClient extends RelayClient {
  _AdminPageFakeClient() : super('http://127.0.0.1', 'tok');

  @override
  Future<List<User>> users() async => [
    User.fromJson({
      'identity': _longAdminIdentity,
      'display_name': _longAdminDisplayName,
      'is_admin': true,
      'disabled': true,
    }),
  ];
}
