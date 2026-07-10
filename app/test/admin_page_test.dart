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

Finder _userActions(String identity) =>
    find.byKey(ValueKey('admin-user-actions-$identity'));

Future<void> _openCreateDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('admin-open-create')));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _submitCreate(WidgetTester tester, String identity) async {
  await _openCreateDialog(tester);
  await tester.enterText(
    find.byKey(const ValueKey('admin-create-identity')),
    identity,
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('admin-create-submit')));
  await tester.pump();
}

void main() {
  test('admin account labels are localized', () {
    expect(adminFlagLabel(true), '系统管理员');
    expect(adminFlagLabel(false), '普通成员');
    expect(disabledFlagLabel(true), '已停用');
    expect(disabledFlagLabel(false), '已启用');
    expect(deletedFlagLabel(true), '已删除');
    expect(deletedFlagLabel(false), '未删除');
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

  test('admin secret dialog width fits compact screens', () {
    expect(adminSecretDialogWidth(const Size(320, 760)), 288);
    expect(adminSecretDialogWidth(const Size(1024, 760)), 420);
    expect(adminSecretDialogWidth(const Size(360, 760), preferred: 460), 328);
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
    tester.view.physicalSize = const Size(320, 760);
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
    expect(
      find.byKey(const ValueKey('admin-user-compact-list')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('admin-user-table-header')), findsNothing);
    expect(find.text('系统管理员'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
  });

  testWidgets('admin create dialog is compact and reflects input state', (
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

    expect(find.byKey(const ValueKey('admin-create-identity')), findsNothing);
    await _openCreateDialog(tester);
    FilledButton createButton() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('admin-create-submit')),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-create-admin-option')),
      findsOneWidget,
    );
    expect(createButton().onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('admin-create-identity')),
      'new@x',
    );
    await tester.pump();

    expect(createButton().onPressed, isNotNull);
    expect(tester.takeException(), isNull);
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

    await _submitCreate(tester, 'new@x');

    await tester.pumpWidget(const SizedBox.shrink());
    client.completeCreate(null);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('admin create completion after account switch is ignored', (
    tester,
  ) async {
    final oldClient = _DelayedCreateAdminPageFakeClient();
    final newClient = _AdminPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: oldClient)),
      ),
    );
    await tester.pumpAndSettle();

    await _submitCreate(tester, 'old@x');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: newClient)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    oldClient.completeCreate('old-secret');
    await tester.pumpAndSettle();

    expect(oldClient.createCount, 1);
    expect(find.text('old-secret'), findsNothing);
    expect(find.text('账号 old@x 的初始密码'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'admin create secret is dropped when account switches during reload',
    (tester) async {
      final oldClient = _DelayedUsersAdminPageFakeClient();
      final newClient = _AdminPageFakeClient();
      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: AdminPage(client: oldClient)),
        ),
      );
      await tester.pump();
      oldClient.completeLatestUsers([
        _user('old-admin@x', displayName: 'Old Admin'),
      ]);
      await tester.pumpAndSettle();

      await _submitCreate(tester, 'created-on-old@x');
      oldClient.completeCreate('old-generated-secret');
      await tester.pump();
      expect(oldClient.userRequestCount, 2);

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: AdminPage(client: newClient)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsNothing);

      oldClient.completeLatestUsers([
        _user('created-on-old@x', displayName: 'Old Created User'),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('old-generated-secret'), findsNothing);
      expect(find.text('账号 created-on-old@x 的初始密码'), findsNothing);
      expect(find.text('Old Created User'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('admin create is disabled while request is in flight', (
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

    await _submitCreate(tester, 'new@x');

    expect(client.createCount, 1);
    expect(find.text('创建中...'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('admin-create-submit')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('admin-create-submit')));
    await tester.pump();
    expect(client.createCount, 1);

    client.completeCreate(null);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('admin-open-create')), findsOneWidget);
    expect(client.createCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin generated password dialog title is width constrained', (
    tester,
  ) async {
    final client = _DelayedCreateAdminPageFakeClient();
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await _submitCreate(tester, _longAdminIdentity);
    client.completeCreate('secret-password');
    await tester.pumpAndSettle();

    final dialogTitle = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.data == '账号 $_longAdminIdentity 的初始密码',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(dialogTitle.maxLines, 1);
    expect(dialogTitle.overflow, TextOverflow.ellipsis);

    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    final secretScroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      ),
    );

    expect(
      dialog.insetPadding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    );
    expect(secretScroll.scrollDirection, Axis.horizontal);
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

    await _submitCreate(tester, 'new@x');
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

  testWidgets('admin page account switch ignores stale user loads', (
    tester,
  ) async {
    final oldClient = _DelayedUsersAdminPageFakeClient();
    final newClient = _DelayedUsersAdminPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: oldClient)),
      ),
    );
    await tester.pump();
    expect(oldClient.userRequestCount, 1);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: newClient)),
      ),
    );
    await tester.pump();
    expect(newClient.userRequestCount, 1);

    newClient.completeLatestUsers([
      _user('new@x', displayName: 'New Account User'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New Account User'), findsOneWidget);
    expect(find.text('Old Account User'), findsNothing);

    oldClient.completeLatestUsers([
      _user('old@x', displayName: 'Old Account User'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New Account User'), findsOneWidget);
    expect(find.text('Old Account User'), findsNothing);
  });

  testWidgets('admin reset password after account switch is ignored', (
    tester,
  ) async {
    final oldClient = _DelayedResetAdminPageFakeClient();
    final newClient = _AdminPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: oldClient)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_userActions(_longAdminIdentity));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置密码'));
    await tester.pump();
    expect(oldClient.resetCount, 1);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: newClient)),
      ),
    );
    await tester.pumpAndSettle();

    oldClient.completeReset('old-secret');
    await tester.pumpAndSettle();

    expect(find.text('old-secret'), findsNothing);
    expect(find.text('$_longAdminIdentity 的新密码'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin user action is locked while request is in flight', (
    tester,
  ) async {
    final client = _DelayedAdminToggleAdminPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_userActions(_longAdminIdentity));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消管理员'));
    await tester.pump();

    expect(client.setAdminCount, 1);
    expect(_userActions(_longAdminIdentity), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    client.completeSetAdmin();
    await tester.pumpAndSettle();

    expect(client.setAdminCount, 1);
    expect(_userActions(_longAdminIdentity), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin account delete requires confirmation and shows loading', (
    tester,
  ) async {
    final client = _DelayedDeleteAdminPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: AdminPage(client: client, currentIdentity: 'current@x'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_userActions(_longAdminIdentity));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除账号'));
    await tester.pumpAndSettle();

    expect(find.text('删除账号？'), findsOneWidget);
    expect(client.deleteCount, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(client.deleteCount, 0);

    await tester.tap(_userActions(_longAdminIdentity));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除账号'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除账号'),
      ),
    );
    await tester.pump();

    expect(client.deleteCount, 1);
    expect(_userActions(_longAdminIdentity), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    client.completeDelete();
    await tester.pump();

    expect(
      find.byKey(ValueKey('admin-user-title-$_longAdminIdentity')),
      findsNothing,
    );
    expect(find.text('没有账号。'), findsOneWidget);
    await tester.tap(find.text('已删除'));
    await tester.pump();
    expect(
      find.byKey(ValueKey('admin-user-title-$_longAdminIdentity')),
      findsOneWidget,
    );
    expect(_userActions(_longAdminIdentity), findsNothing);

    client.completeReload();
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('admin-user-title-$_longAdminIdentity')),
      findsOneWidget,
    );
    expect(_userActions(_longAdminIdentity), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'admin account protects all destructive current account actions',
    (tester) async {
      final client = _CurrentAdminPageFakeClient();
      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: AdminPage(
              client: client,
              currentIdentity: _longAdminIdentity,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('当前'), findsOneWidget);
      await tester.tap(_userActions(_longAdminIdentity));
      await tester.pumpAndSettle();
      for (final label in const ['不能取消当前账号管理员', '不能停用当前账号', '不能删除当前账号']) {
        final item = tester.widget<PopupMenuItem<String>>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(PopupMenuItem<String>),
          ),
        );
        expect(item.enabled, isFalse, reason: label);
      }
      expect(client.setAdminCount, 0);
      expect(client.setDisabledCount, 0);
      expect(client.deleteCount, 0);
    },
  );

  testWidgets('admin defaults to active accounts and switches to tombstones', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: _MixedAdminPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('admin-user-title-active@x')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-user-title-deleted@x')),
      findsNothing,
    );
    expect(_userActions('active@x'), findsOneWidget);

    await tester.tap(find.text('已删除'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('admin-user-title-active@x')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('admin-user-title-deleted@x')),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsNothing);
    expect(_userActions('deleted@x'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin toolbar searches identity and filters active status', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: AdminPage(client: _FilterAdminPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('admin-user-title-enabled@x')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-user-title-disabled@x')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('admin-user-search')),
      'paused person',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('admin-user-title-enabled@x')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('admin-user-title-disabled@x')),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const ValueKey('admin-user-search')), '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('admin-user-status-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '启用'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('admin-user-title-enabled@x')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-user-title-disabled@x')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin account delete surfaces request errors', (tester) async {
    final client = _FailDeleteAdminPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: AdminPage(client: client, currentIdentity: 'current@x'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_userActions(_longAdminIdentity));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除账号'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除账号'),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.deleteCount, 1);
    expect(find.textContaining('delete failed'), findsOneWidget);
    expect(_userActions(_longAdminIdentity), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
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
  int createCount = 0;

  @override
  Future<String?> createUser(
    String identity, {
    String? password,
    bool isAdmin = false,
  }) {
    createCount += 1;
    return _createCompleter.future;
  }

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

class _DelayedResetAdminPageFakeClient extends _AdminPageFakeClient {
  final _resetCompleter = Completer<String>();
  int resetCount = 0;

  @override
  Future<String> resetPassword(String identity) {
    resetCount++;
    return _resetCompleter.future;
  }

  void completeReset(String password) {
    if (!_resetCompleter.isCompleted) {
      _resetCompleter.complete(password);
    }
  }
}

class _DelayedAdminToggleAdminPageFakeClient extends _AdminPageFakeClient {
  final _setAdminCompleter = Completer<void>();
  int setAdminCount = 0;

  @override
  Future<void> setUserAdmin(String identity, bool isAdmin) {
    setAdminCount++;
    return _setAdminCompleter.future;
  }

  void completeSetAdmin() {
    if (!_setAdminCompleter.isCompleted) {
      _setAdminCompleter.complete();
    }
  }
}

class _DelayedDeleteAdminPageFakeClient extends _AdminPageFakeClient {
  final _deleteCompleter = Completer<void>();
  final _reloadCompleter = Completer<List<User>>();
  bool _deleted = false;
  int deleteCount = 0;

  @override
  Future<List<User>> users() {
    if (_deleted) return _reloadCompleter.future;
    return super.users();
  }

  @override
  Future<void> deleteUser(String identity) {
    deleteCount++;
    return _deleteCompleter.future;
  }

  void completeDelete() {
    if (!_deleteCompleter.isCompleted) {
      _deleted = true;
      _deleteCompleter.complete();
    }
  }

  void completeReload() {
    if (!_reloadCompleter.isCompleted) {
      _reloadCompleter.complete([
        User.fromJson({
          'identity': _longAdminIdentity,
          'display_name': _longAdminDisplayName,
          'disabled': true,
          'deleted': true,
        }),
      ]);
    }
  }
}

class _CurrentAdminPageFakeClient extends _AdminPageFakeClient {
  int setAdminCount = 0;
  int setDisabledCount = 0;
  int deleteCount = 0;

  @override
  Future<List<User>> users() async => [
    User.fromJson({
      'identity': _longAdminIdentity,
      'display_name': _longAdminDisplayName,
      'is_admin': true,
    }),
  ];

  @override
  Future<void> setUserAdmin(String identity, bool isAdmin) async {
    setAdminCount++;
  }

  @override
  Future<void> setUserDisabled(String identity, bool disabled) async {
    setDisabledCount++;
  }

  @override
  Future<void> deleteUser(String identity) async {
    deleteCount++;
  }
}

class _MixedAdminPageFakeClient extends _AdminPageFakeClient {
  @override
  Future<List<User>> users() async => [
    User.fromJson({'identity': 'active@x', 'display_name': 'Active User'}),
    User.fromJson({
      'identity': 'deleted@x',
      'display_name': 'Deleted User',
      'disabled': true,
      'deleted': true,
    }),
  ];
}

class _FilterAdminPageFakeClient extends _AdminPageFakeClient {
  @override
  Future<List<User>> users() async => [
    User.fromJson({'identity': 'enabled@x', 'display_name': 'Active Person'}),
    User.fromJson({
      'identity': 'disabled@x',
      'display_name': 'Paused Person',
      'disabled': true,
    }),
    User.fromJson({
      'identity': 'deleted@x',
      'display_name': 'Deleted Person',
      'disabled': true,
      'deleted': true,
    }),
  ];
}

class _FailDeleteAdminPageFakeClient extends _AdminPageFakeClient {
  int deleteCount = 0;

  @override
  Future<void> deleteUser(String identity) {
    deleteCount++;
    return Future<void>.error(Exception('delete failed'));
  }
}

User _user(String identity, {String displayName = ''}) =>
    User.fromJson({'identity': identity, 'display_name': displayName});
