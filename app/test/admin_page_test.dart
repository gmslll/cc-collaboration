import 'dart:async';

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

  test('admin create option width does not exceed constraints', () {
    expect(
      adminCreateOptionWidth(const BoxConstraints(maxWidth: 160), 220),
      160,
    );
    expect(
      adminCreateOptionWidth(const BoxConstraints(maxWidth: 320), 220),
      220,
    );
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

  testWidgets('admin create controls wrap and reflect input state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 760);
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

    FilledButton createButton() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '创建账号'));

    final adminOptionLabel = tester.widget<Text>(
      find.byKey(const ValueKey('admin-create-admin-label')),
    );

    expect(tester.takeException(), isNull);
    expect(adminOptionLabel.maxLines, 1);
    expect(adminOptionLabel.overflow, TextOverflow.ellipsis);
    expect(createButton().onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'new@x');
    await tester.pump();

    expect(createButton().onPressed, isNotNull);
  });

  testWidgets('admin create completion after unmount is ignored', (
    tester,
  ) async {
    final client = _DelayedCreateAdminPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'new@x');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建账号'));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    client.completeCreate(null);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('stale admin user load cannot overwrite a newer reload', (
    tester,
  ) async {
    final client = _DelayedUsersAdminPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: client)),
      ),
    );
    await tester.pump();
    expect(client.userRequestCount, 1);

    await tester.enterText(find.byType(TextField).first, 'new@x');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建账号'));
    await tester.pump();
    client.completeCreate(null);
    await tester.pump();
    expect(client.userRequestCount, 2);

    client.completeLatestUsers([_user('new@x', displayName: 'New User')]);
    await tester.pumpAndSettle();
    expect(find.text('New User'), findsOneWidget);
    expect(find.text('Old User'), findsNothing);

    client.completeNextUsers([_user('old@x', displayName: 'Old User')]);
    await tester.pumpAndSettle();
    expect(find.text('New User'), findsOneWidget);
    expect(find.text('Old User'), findsNothing);
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

class _DelayedCreateAdminPageFakeClient extends _AdminPageFakeClient {
  final _createCompleter = Completer<String?>();

  @override
  Future<String?> createUser(
    String identity, {
    String? password,
    bool isAdmin = false,
  }) => _createCompleter.future;

  void completeCreate(String? password) {
    if (!_createCompleter.isCompleted) {
      _createCompleter.complete(password);
    }
  }
}

class _DelayedUsersAdminPageFakeClient extends _AdminPageFakeClient {
  final _usersRequests = <Completer<List<User>>>[];
  final _createCompleter = Completer<String?>();

  int get userRequestCount => _usersRequests.length;

  @override
  Future<List<User>> users() {
    final completer = Completer<List<User>>();
    _usersRequests.add(completer);
    return completer.future;
  }

  @override
  Future<String?> createUser(
    String identity, {
    String? password,
    bool isAdmin = false,
  }) => _createCompleter.future;

  void completeCreate(String? password) {
    if (!_createCompleter.isCompleted) {
      _createCompleter.complete(password);
    }
  }

  void completeNextUsers(List<User> users) {
    final request = _usersRequests.firstWhere((c) => !c.isCompleted);
    request.complete(users);
  }

  void completeLatestUsers(List<User> users) {
    final request = _usersRequests.lastWhere((c) => !c.isCompleted);
    request.complete(users);
  }
}

User _user(String identity, {String displayName = ''}) =>
    User.fromJson({'identity': identity, 'display_name': displayName});
