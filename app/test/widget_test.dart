import 'dart:io';

import 'package:app/api/github_client.dart';
import 'package:app/api/models.dart';
import 'package:app/local/diff_parse.dart';
import 'package:app/local/remote_prefs.dart';
import 'package:app/local/repo_config.dart';
import 'package:app/voice/stt.dart';
import 'package:app/widgets.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _sampleDiff = '''
diff --git a/lib/a.dart b/lib/a.dart
index 1111111..2222222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,3 +1,3 @@
 context1
-old line
+new line
 context2
diff --git a/lib/new.dart b/lib/new.dart
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/lib/new.dart
@@ -0,0 +1,2 @@
+added1
+added2
''';

void main() {
  test('account page does not expose internal build markers', () {
    final source = File('lib/screens/account_page.dart').readAsStringSync();

    expect(source, isNot(contains('kBuildMarker')));
    expect(source, isNot(contains('构建 \$kBuildMarker')));
  });

  test('account switcher labels are width constrained', () {
    for (final path in ['lib/main.dart', 'lib/main_web.dart']) {
      final source = File(path).readAsStringSync();
      final dialog = source.substring(
        source.indexOf('title: const Text(\'切换账号\')'),
      );

      expect(dialog, isNot(contains('Text(a.identity),')));
      expect(
        dialog,
        contains('a.identity,\n                          maxLines: 1'),
      );
      expect(dialog, contains('overflow: TextOverflow.ellipsis'));
      expect(dialog, contains('a.relayUrl)'));
    }
  });

  test('home shell bootstrap ignores stale auth results', () {
    final source = File('lib/main.dart').readAsStringSync();
    final state = source.substring(
      source.indexOf('class _HomeShellState'),
      source.indexOf('Future<void> _onLoggedIn'),
    );
    final logout = source.substring(
      source.indexOf('Future<void> _logout() async'),
      source.indexOf('Future<void> _showLogin() async'),
    );

    expect(state, contains('int _bootstrapGeneration = 0;'));
    expect(state, contains('final generation = ++_bootstrapGeneration;'));
    expect(state, contains('bool _isCurrentBootstrap(int generation)'));
    expect(state, contains('if (!_isCurrentBootstrap(generation)) return;'));
    expect(state, contains('config: activeCfg'));
    expect(logout, contains('_bootstrapGeneration++;'));
  });

  test('workspace session publishing ignores stale relay identity', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final relayPresence = source.substring(
      source.indexOf('void _connectRelayPresence()'),
      source.indexOf('// _publishSessions advertises our open sessions'),
    );
    final publish = source.substring(
      source.indexOf('Future<void> _publishSessionsNow() async'),
      source.indexOf('// _onRelayEvent acts on the cross-user message.deliver'),
    );

    expect(relayPresence, contains('bool _isCurrentRelayIdentity('));
    expect(relayPresence, contains('_cfg.relayUrl == relayUrl'));
    expect(relayPresence, contains('_cfg.token == token'));
    expect(relayPresence, contains('_cfg.identity == identity'));
    expect(
      relayPresence,
      contains(
        'if (!_isCurrentRelayIdentity(relayUrl, token, identity)) return;',
      ),
    );
    expect(publish, contains('final relayUrl = _cfg.relayUrl;'));
    expect(publish, contains('final token = _cfg.token;'));
    expect(publish, contains('final identity = _cfg.identity;'));
    expect(
      publish,
      contains(
        'if (!_isCurrentRelayIdentity(relayUrl, token, identity)) return;',
      ),
    );
    expect(
      publish.indexOf('await AppConfig.load()'),
      lessThan(publish.lastIndexOf('_isCurrentRelayIdentity')),
    );
  });

  test('workspace task loading ignores stale relay clients', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final state = source.substring(
      source.indexOf('Map<String, List<ListItem>> _tasksByRepo'),
      source.indexOf('// Split-pane file editor'),
    );
    final loadTasks = source.substring(
      source.indexOf('Future<void> _loadTasks() async'),
      source.indexOf('Future<void> _ensureWorktrees'),
    );

    expect(state, contains('int _taskLoadGeneration = 0;'));
    expect(loadTasks, contains('final generation = ++_taskLoadGeneration;'));
    expect(loadTasks, contains('final client = widget.client;'));
    expect(loadTasks, contains('bool _isCurrentTaskLoad('));
    expect(loadTasks, contains('generation == _taskLoadGeneration'));
    expect(loadTasks, contains('identical(client, widget.client)'));
    expect(
      loadTasks.indexOf('await Future.wait'),
      lessThan(loadTasks.lastIndexOf('_isCurrentTaskLoad(generation, client)')),
    );
  });

  test('account dynamic labels and dropdown menus are constrained', () {
    final source = File('lib/screens/account_page.dart').readAsStringSync();

    String between(String start, String end) {
      final startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative);
      final endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative);
      return source.substring(startIndex, endIndex);
    }

    final hookDialog = between(
      'Future<void> _chooseHookEvents(',
      'Future<void> _saveLocalConfig()',
    );
    expect(hookDialog, contains("'选择 \${h.name} hook',"));
    expect(hookDialog, contains('maxLines: 1'));
    expect(hookDialog, contains('overflow: TextOverflow.ellipsis'));
    expect(hookDialog, isNot(contains('title: Text(ev, style:')));

    final tokenCard = between(
      "'机器 token(给 CLI / watch / MCP)'",
      "if (!_isDesktop)",
    );
    expect(tokenCard, contains("t.label.isEmpty ? '(无标签)' : t.label"));
    expect(tokenCard, contains('maxLines: 1'));
    expect(tokenCard, contains('overflow: TextOverflow.ellipsis'));

    final hookRow = between('Widget _hookRow(', 'Widget _localConfigCard()');
    expect(hookRow, contains('h.name,'));
    expect(hookRow, contains('maxLines: 1'));
    expect(hookRow, contains('overflow: TextOverflow.ellipsis'));

    final localConfig = between(
      'Widget _localConfigCard()',
      'Widget _cfgField(',
    );
    expect(localConfig, contains('menuMaxHeight: accountMenuMaxHeight'));
    expect(localConfig, contains('_settingDropdownRow('));
    expect(localConfig, contains('isExpanded: true'));
    expect(localConfig, contains('selectedItemBuilder'));
    expect(localConfig, contains("_dropdownText('windows-terminal')"));
    expect(localConfig, contains("_dropdownItem('windows-terminal'"));

    final settingRow = between(
      'Widget _settingDropdownRow({',
      'Widget _localConfigCard()',
    );
    expect(settingRow, contains('Flexible('));
    expect(settingRow, contains('ConstrainedBox('));

    final dropdownText = between(
      'Widget _dropdownText(String text)',
      'DropdownMenuItem<String> _dropdownItem',
    );
    expect(dropdownText, contains('maxLines: 1'));
    expect(dropdownText, contains('overflow: TextOverflow.ellipsis'));
  });

  test('remote session content previews default to hidden', () {
    expect(kRemoteShowSessionContentDefault, isFalse);

    final account = File('lib/screens/account_page.dart').readAsStringSync();
    final remote = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    expect(account, contains('def: kRemoteShowSessionContentDefault'));
    expect(remote, contains('def: kRemoteShowSessionContentDefault'));
    expect(
      account,
      isNot(contains('kRemoteShowSessionContentPref,\n    def: true')),
    );
    expect(
      remote,
      isNot(contains('kRemoteShowSessionContentPref,\n          def: true')),
    );
  });

  test('remote new-session dropdown labels are width constrained', () {
    final remote = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();

    expect(remote, contains('overflow: TextOverflow.ellipsis'));
    expect(
      remote,
      isNot(contains('DropdownMenuItem(value: r, child: Text(r.name))')),
    );
    expect(remote, contains("'主仓 (\${project.name})'"));
    expect(
      remote,
      contains('w.branch.isEmpty ? pathBaseName(w.path) : w.branch'),
    );
  });

  test('remote project list titles are width constrained', () {
    final remote = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();

    expect(remote, isNot(contains('title: Text(r.name),')));
    expect(remote, contains('maxLines: 1'));
    expect(remote, contains('overflow: TextOverflow.ellipsis'));
  });

  test('todo assistant workspace menus are width constrained', () {
    final source = File('lib/screens/todos_page.dart').readAsStringSync();
    final dialog = source.substring(
      source.indexOf('Future<void> _summonTodoAssistant()'),
      source.indexOf('Future<void> _linearConfigDialog()'),
    );

    expect(dialog, contains('menuMaxHeight: todoMenuMaxHeight'));
    expect(dialog, isNot(contains('child: Text(w.name),')));
    expect(dialog, isNot(contains('child: Text(p.name),')));
    expect(
      dialog,
      contains('w.name,\n                            maxLines: 1'),
    );
    expect(
      dialog,
      contains('p.name,\n                            maxLines: 1'),
    );
    expect(dialog, contains('overflow: TextOverflow.ellipsis'));
  });

  test('todo property menu labels are width constrained', () {
    final source = File(
      'lib/widgets/todo_property_controls.dart',
    ).readAsStringSync();
    final row = source.substring(
      source.indexOf('PopupMenuItem<T> _checkableRow<T>({'),
      source.indexOf('class PriorityControl'),
    );

    expect(row, isNot(contains('Text(label),')));
    expect(row, contains('Expanded('));
    expect(row, contains('label, maxLines: 1'));
    expect(row, contains('overflow: TextOverflow.ellipsis'));
  });

  test('remote shared workspace dynamic labels are width constrained', () {
    final remote = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();

    String between(String start, String end) {
      final startIndex = remote.indexOf(start);
      final endIndex = remote.indexOf(end, startIndex);
      expect(startIndex, isNonNegative);
      expect(endIndex, isNonNegative);
      return remote.substring(startIndex, endIndex);
    }

    final fileHub = between('// _xferTile renders', '// _sendFileToMac');
    expect(fileHub, contains('x.name,\n        maxLines: 1'));
    expect(fileHub, contains('name,\n      maxLines: 1'));

    final screenShare = between(
      'void _showScreenShare()',
      'Future<void> _openScreenShare',
    );
    expect(
      screenShare,
      contains('source.name,\n                        maxLines: 1'),
    );

    final branchSheet = between(
      'Future<void> _branchSheet()',
      'Future<void> _newBranchDialog()',
    );
    expect(
      branchSheet,
      contains('b.name,\n                          maxLines: 1'),
    );

    final manageTab = between('Widget _manageTab()', 'void _openWorktrees');
    expect(
      manageTab,
      contains(
        'title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)',
      ),
    );

    final worktreeScreen = between(
      'class _WorktreeScreenState',
      'class _QuickReplyDialog',
    );
    expect(
      worktreeScreen,
      contains(
        "'\${widget.project.name} · Worktrees',\n              maxLines: 1",
      ),
    );
    expect(
      worktreeScreen,
      contains(
        'w.branch.isEmpty ? w.name : w.branch,\n                          maxLines: 1',
      ),
    );

    final keyEditor = between('void _openKeyBarEditor()', '// Common special');
    expect(
      keyEditor,
      contains('kb.label,\n                              maxLines: 1'),
    );
  });

  test('workspace session rows paint selected backgrounds on Material', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final sessionMenu = source.substring(source.indexOf('final sessionMenu ='));
    final tileBlock = sessionMenu.substring(
      sessionMenu.indexOf('return _ctxMenu('),
      sessionMenu.indexOf('sessionMenu,'),
    );

    expect(tileBlock, contains('Material('));
    expect(tileBlock, contains('CcColors.accent.withValues(alpha: 0.08)'));
    expect(
      tileBlock,
      isNot(
        contains('decoration: BoxDecoration(\n              color: active'),
      ),
    );
  });

  test('workspace project order sheet labels are width constrained', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final sheet = source.substring(
      source.indexOf('void _openProjectOrderSheet('),
      source.indexOf('PopupMenuButton<String> _projectMenu('),
    );

    expect(sheet, contains("'排序项目 · \${ws.name.isEmpty ? '默认' : ws.name}'"));
    expect(sheet, isNot(contains('title: Text(p.name),')));
    expect(sheet, contains('maxLines: 1'));
    expect(sheet, contains('overflow: TextOverflow.ellipsis'));
    expect(
      sheet,
      contains('p.name,\n                              maxLines: 1'),
    );
  });

  test('workspace git log filter menus are width constrained', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final filters = source.substring(
      source.indexOf('Widget _logFilterDropdown({'),
      source.indexOf('// _logPathFilterChip'),
    );

    expect(filters, contains('menuMaxHeight: 320'));
    expect(
      filters,
      isNot(contains('DropdownMenuItem(value: r, child: Text(r))')),
    );
    expect(
      filters,
      isNot(contains('DropdownMenuItem(value: a, child: Text(a))')),
    );
    expect(
      filters,
      contains('Text(r, maxLines: 1, overflow: TextOverflow.ellipsis)'),
    );
    expect(
      filters,
      contains('Text(a, maxLines: 1, overflow: TextOverflow.ellipsis)'),
    );
  });

  test('workspace change filter menu labels are width constrained', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final menu = source.substring(
      source.indexOf('Widget _changesFilterButton()'),
      source.indexOf('// _fileTypeIcon picks'),
    );

    expect(menu, isNot(contains('Expanded(child: Text(e.value))')));
    expect(menu, contains('e.value,\n                          maxLines: 1'));
    expect(menu, contains('overflow: TextOverflow.ellipsis'));
  });

  test('workspace management dialog titles are width constrained', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final fieldsDialog = source.substring(
      source.indexOf('class WorkspaceFieldsDialog'),
      source.indexOf('class WorkspaceSessionRenameDialog'),
    );
    final confirmDialog = source.substring(
      source.indexOf('@override\n  Future<bool> _confirm('),
      source.indexOf('void _openTask('),
    );

    expect(fieldsDialog, isNot(contains('title: Text(widget.title),')));
    expect(
      fieldsDialog,
      contains('widget.title, maxLines: 1, overflow: TextOverflow.ellipsis'),
    );
    expect(confirmDialog, isNot(contains('title: Text(title),')));
    expect(
      confirmDialog,
      contains('title, maxLines: 1, overflow: TextOverflow.ellipsis'),
    );
    expect(fieldsDialog, contains('overflow: TextOverflow.ellipsis'));
    expect(confirmDialog, contains('overflow: TextOverflow.ellipsis'));
  });

  test('workspace git dialog titles are width constrained', () {
    final gitMixin = File(
      'lib/screens/workspace/git_mixin.dart',
    ).readAsStringSync();
    final commitMenu = File(
      'lib/screens/workspace/git_log_commit_menu.dart',
    ).readAsStringSync();

    final stashDialog = gitMixin.substring(
      gitMixin.indexOf(
        'Future<({String message, bool includeUntracked})?> _askStashOptions({',
      ),
      gitMixin.indexOf('Future<void> _stashPushCurrent('),
    );
    final rewordDialog = commitMenu.substring(
      commitMenu.indexOf('Future<String?> _promptRewordMessage({'),
    );

    expect(stashDialog, isNot(contains('title: Text(title),')));
    expect(rewordDialog, isNot(contains('title: Text(title),')));
    expect(
      stashDialog,
      contains('title, maxLines: 1, overflow: TextOverflow.ellipsis'),
    );
    expect(
      rewordDialog,
      contains('title, maxLines: 1, overflow: TextOverflow.ellipsis'),
    );
  });

  test('terminal paste guards mounted before writing to the pty', () {
    final source = File('lib/screens/terminal_pane.dart').readAsStringSync();

    String between(String start, String end) {
      final startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative);
      final endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative);
      return source.substring(startIndex, endIndex);
    }

    void expectGuardBefore(String body, String after, String before) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf('if (!mounted) return;', afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    final pasteText = between(
      'Future<void> _paste() async {',
      '// _pasteImage',
    );
    expectGuardBefore(pasteText, 'Clipboard.getData', '_terminal.paste(text)');
    final pasteImage = between(
      'Future<void> _pasteImage() async {',
      '// Mirrors xterm',
    );
    expectGuardBefore(pasteImage, 'Pasteboard.image', 'if (bytes == null');
    expectGuardBefore(
      pasteImage,
      'File(path).writeAsBytes',
      '_terminal.paste(path)',
    );
  });

  test('workspace search dialogs guard mounted before opening files', () {
    final source = File(
      'lib/screens/workspace/search_mixin.dart',
    ).readAsStringSync();

    String between(String start, String end) {
      final startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative);
      final endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative);
      return source.substring(startIndex, endIndex);
    }

    void expectGuardBefore(String body, String after, String before) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf('if (!mounted) return;', afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    final methods = <(String, String)>[
      ('Future<void> _showQuickOpen()', 'Future<void> _showFindInFiles()'),
      (
        'Future<void> _showFindInFiles()',
        'Future<void> _showFindInCurrentFile()',
      ),
      ('Future<void> _showFindInCurrentFile()', 'Future<void> _showGoToLine()'),
      ('Future<void> _showGoToLine()', 'Future<void> _showFileStructure()'),
      ('Future<void> _showFileStructure()', 'Future<void> _showGoToSymbol()'),
      (
        'Future<void> _showGoToSymbol()',
        'Future<void> _showFindUsagesForActiveFile()',
      ),
      ('Future<void> _showFindUsagesForActiveFile()', '\n}'),
    ];
    for (final (start, end) in methods) {
      expectGuardBefore(between(start, end), 'showDialog', '_openCodeFile');
    }
  });

  test('workspace name dialog uses owned controller widget', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final dialog = source.substring(
      source.indexOf('Future<String?> _nameDialog('),
      source.indexOf('void _refreshFileTrees'),
    );

    expect(dialog, contains('showDialog<String>'));
    expect(dialog, contains('FileNameDialog('));
    expect(dialog, isNot(contains('TextEditingController')));
    expect(dialog, isNot(contains('showDialog<bool>')));
  });

  test('workspace fields dialog owns generated controllers', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final helper = source.substring(
      source.indexOf('Future<List<String>?> _fieldsDialog('),
      source.indexOf('@override\n  Future<bool> _confirm'),
    );

    expect(helper, contains('showDialog<List<String>>'));
    expect(helper, contains('WorkspaceFieldsDialog('));
    expect(helper, isNot(contains('TextEditingController')));
    expect(helper, isNot(contains('showDialog<bool>')));
  });

  test('workspace session rename uses owned controller widget', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final helper = source.substring(
      source.indexOf('Future<void> _renameSession('),
      source.indexOf('List<Widget> _worktreeNodes'),
    );

    expect(helper, contains('showDialog<String>'));
    expect(helper, contains('WorkspaceSessionRenameDialog('));
    expect(helper, isNot(contains('TextEditingController')));
    expect(helper, isNot(contains('showDialog<bool>')));
  });

  test('workspace commit branch dialog owns controller', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final helper = source.substring(
      source.indexOf('Future<void> _createBranchFromCommit('),
      source.indexOf('@override\n  Future<void> _cherryPickCommit'),
    );

    expect(helper, contains('showDialog<String>'));
    expect(helper, contains('WorkspaceCommitBranchDialog('));
    expect(helper, isNot(contains('TextEditingController')));
    expect(helper, isNot(contains('showDialog<bool>')));
  });

  test('workspace settings dialog owns controllers', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final helper = source.substring(
      source.indexOf('Future<void> _workspaceSettings('),
      source.indexOf('PopupMenuButton<String> _projectMenu'),
    );

    expect(helper, contains('showDialog<WorkspaceSettingsDraft>'));
    expect(helper, contains('WorkspaceSettingsDialog('));
    expect(helper, isNot(contains('TextEditingController')));
    expect(helper, isNot(contains('showDialog<bool>')));
  });

  test('workspace branch create and rename dialogs own controllers', () {
    final source = File(
      'lib/screens/workspace/branch_dialog.dart',
    ).readAsStringSync();
    final createHelper = source.substring(
      source.indexOf('Future<void> _createBranch('),
      source.indexOf('Future<void> _renameBranch('),
    );
    final renameHelper = source.substring(
      source.indexOf('Future<void> _renameBranch('),
      source.indexOf('Future<void> _deleteBranch('),
    );

    expect(createHelper, contains('showDialog<WorkspaceBranchCreateDraft>'));
    expect(createHelper, contains('WorkspaceBranchCreateDialog('));
    expect(createHelper, isNot(contains('TextEditingController')));
    expect(createHelper, isNot(contains('showDialog<bool>')));

    expect(renameHelper, contains('showDialog<String>'));
    expect(renameHelper, contains('WorkspaceBranchRenameDialog('));
    expect(renameHelper, isNot(contains('TextEditingController')));
    expect(renameHelper, isNot(contains('showDialog<bool>')));
  });

  test('todo assign member loader guards mounted before setState', () {
    final source = File('lib/screens/todos_page.dart').readAsStringSync();
    final loader = source.substring(
      source.indexOf('Future<void> _loadMembers() async {'),
      source.indexOf('// _assignToMember writes assignee_identity only'),
    );

    expect(loader, contains('if (!mounted) return;'));
    expect(
      loader.indexOf('if (!mounted) return;'),
      lessThan(loader.indexOf('setState(() {')),
    );
    final orgLookup = loader.indexOf('organization(detail!.project.orgId)');
    final orgGuard = loader.indexOf('if (!mounted) return;', orgLookup);
    final displayNames = loader.indexOf('todoMemberDisplayNames', orgLookup);
    expect(orgLookup, isNonNegative);
    expect(orgGuard, isNonNegative);
    expect(displayNames, isNonNegative);
    expect(orgGuard, lessThan(displayNames));
  });

  test('project detail dialogs guard mounted before mutations', () {
    final source = File('lib/screens/projects_page.dart').readAsStringSync();

    String between(String start, String end) {
      final startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative);
      final endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative);
      return source.substring(startIndex, endIndex);
    }

    void expectGuardBefore(String body, String after, String before) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf('if (!mounted) return', afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    final organizationSheet = between(
      'class _OrganizationSheetState',
      'class _ProjectSheet extends StatefulWidget',
    );
    final projectSheet = between(
      'class _ProjectSheetState',
      'class _CompactProjectChip',
    );

    for (final body in [organizationSheet, projectSheet]) {
      final doBody = body.substring(
        body.indexOf('Future<bool> _do('),
        body.indexOf('bool _canManage'),
      );
      expect(
        doBody.indexOf('if (!mounted) return false;'),
        lessThan(doBody.indexOf('if (_mutating) return false;')),
      );
    }

    expectGuardBefore(
      organizationSheet.substring(
        organizationSheet.indexOf('Future<void> _removeMember('),
        organizationSheet.indexOf('Future<void> _addMember()'),
      ),
      'if (!ok) return;',
      '_do(',
    );
    expectGuardBefore(
      projectSheet.substring(
        projectSheet.indexOf('Future<void> _rename('),
        projectSheet.indexOf('Future<void> _delete()'),
      ),
      'if (!ok || name.isEmpty) return;',
      'widget.client.renameProject',
    );
    expectGuardBefore(
      projectSheet.substring(
        projectSheet.indexOf('Future<void> _delete() async {'),
        projectSheet.indexOf('bool _isOnline('),
      ),
      'if (ok != true) return;',
      "setState(() => _mutationAction = 'deleteProject')",
    );
  });

  test('diff and capsule dialogs guard mounted before side effects', () {
    void expectGuardBefore(
      String body,
      String after,
      String before, {
      String guard = 'if (!mounted) return',
    }) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf(guard, afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    final diffView = File('lib/screens/diff_view.dart').readAsStringSync();
    final discard = diffView.substring(
      diffView.indexOf('Future<void> _discard()'),
      diffView.indexOf('@override\n  Widget build'),
    );
    expectGuardBefore(discard, 'if (ok != true) return;', 'gitRestore(');

    final capsule = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final load = capsule.substring(
      capsule.indexOf('Future<void> _load()'),
      capsule.indexOf('bool _isCurrentLoad('),
    );
    expectGuardBefore(load, 'Future<void> _load()', 'setState(() {');

    final edit = capsule.substring(
      capsule.indexOf('Future<void> _editCapsule('),
      capsule.indexOf('Future<void> _loadCapsule('),
    );
    expectGuardBefore(edit, 'showDialog<bool>', '_load();');
  });

  test('file browser and plugin dialogs guard mounted before side effects', () {
    void expectGuardBefore(
      String body,
      String after,
      String before, {
      String guard = 'if (!mounted) return',
    }) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf(guard, afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    final fileBrowser = File(
      'lib/screens/file_browser_page.dart',
    ).readAsStringSync();

    final nameDialog = fileBrowser.substring(
      fileBrowser.indexOf('Future<String?> _nameDialog('),
      fileBrowser.indexOf('Future<bool> _confirm('),
    );
    expectGuardBefore(
      nameDialog,
      'if (raw == null) return null;',
      'raw.trim()',
    );

    final confirm = fileBrowser.substring(
      fileBrowser.indexOf('Future<bool> _confirm('),
      fileBrowser.indexOf('Future<void> _newFile('),
    );
    expectGuardBefore(confirm, 'showDialog<bool>', 'return ok == true;');

    for (final entry in [
      ('Future<void> _newFile(', 'File(path).create'),
      ('Future<void> _newDirectory(', 'Directory(path).create'),
      ('Future<void> _renamePath(', 'Directory(path).rename'),
      ('Future<void> _deletePath(', 'Directory(path).delete'),
    ]) {
      final body = fileBrowser.substring(
        fileBrowser.indexOf(entry.$1),
        fileBrowser.indexOf('Future<void>', fileBrowser.indexOf(entry.$1) + 1),
      );
      expectGuardBefore(body, 'return;', entry.$2);
    }

    final plugins = File('lib/screens/plugins_page.dart').readAsStringSync();
    final editLsp = plugins.substring(
      plugins.indexOf('Future<void> _editLspCommand('),
      plugins.indexOf('}\n}\n\nclass LspCommandDialog'),
    );
    expectGuardBefore(
      editLsp,
      'if (result == null) return;',
      '_lsp.setCommand',
    );
  });

  test('workspace git confirmations guard mounted before loading state', () {
    final source = File(
      'lib/screens/workspace/git_mixin.dart',
    ).readAsStringSync();

    String method(String start, String end) => source.substring(
      source.indexOf('Future<$start'),
      source.indexOf('Future<$end'),
    );

    void expectGuardBeforeLoading(String body, String after) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf('if (!mounted) return;', afterIndex);
      final loadingIndex = body.indexOf(
        'setState(() => _gitLoading = true)',
        afterIndex,
      );

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(loadingIndex, isNonNegative);
      expect(guardIndex, lessThan(loadingIndex));
    }

    expectGuardBeforeLoading(
      method('void> _gitPullRebaseCurrent', 'void> _gitFetchCurrent'),
      'if (!ok) return;',
    );
    expectGuardBeforeLoading(
      method(
        'void> _gitDiscardFileCurrent',
        'void> _gitDiscardSelectedCurrent',
      ),
      "if (!await _confirm('丢弃文件改动?'",
    );
    expectGuardBeforeLoading(
      method('void> _gitDiscardSelectedCurrent', 'void> _gitDiscardAllCurrent'),
      'Rollback selected changes?',
    );
    expectGuardBeforeLoading(
      method(
        'void> _gitDiscardAllCurrent',
        'void> _gitContinueCurrentOperation',
      ),
      'Rollback all changes?',
    );
    expectGuardBeforeLoading(
      method('void> _gitAbortCurrentOperation', 'void> _gitCommitCurrent'),
      'Abort \${op.kind}?',
    );
    expectGuardBeforeLoading(
      method('void> _gitCommitAmendCurrent', 'void> _gitCommitSelected'),
      'Amend 上一条 commit?',
    );
    expectGuardBeforeLoading(
      method('void> _stashPushCurrent', 'void> _stashAllCurrent'),
      'if (opts == null) return;',
    );
    expectGuardBeforeLoading(
      method('void> _stashSelectedCurrent', 'void> _stashApplyCurrent'),
      'if (opts == null) return;',
    );
    expectGuardBeforeLoading(
      method('void> _stashDropCurrent', 'void> _gitPushCurrent'),
      "if (!await _confirm('Drop stash?'",
    );

    final pushFallback = method(
      'bool> _gitPushWithUpstreamFallback',
      'void> _showBranchDialog',
    );
    final upstreamOk = pushFallback.indexOf('if (!ok) return false;');
    final upstreamGuard = pushFallback.indexOf(
      'if (!mounted) return false;',
      upstreamOk,
    );
    final upstreamLoading = pushFallback.indexOf(
      'setState(() => _gitLoading = true)',
      upstreamOk,
    );
    expect(upstreamOk, isNonNegative);
    expect(upstreamGuard, isNonNegative);
    expect(upstreamLoading, isNonNegative);
    expect(upstreamGuard, lessThan(upstreamLoading));

    expectGuardBeforeLoading(
      method('void> _mergeBranchIntoCurrent', 'void> _rebaseCurrentOntoBranch'),
      'Merge into current branch?',
    );
    expectGuardBeforeLoading(
      source.substring(source.indexOf('Future<void> _rebaseCurrentOntoBranch')),
      'Rebase current branch?',
    );
  });

  test('workspace async dialogs guard mounted before state changes', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();

    String between(String start, String end) {
      final startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative);
      final endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative);
      return source.substring(startIndex, endIndex);
    }

    void expectGuardBefore(String body, String after, String before) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf('if (!mounted) return', afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    void expectClientGuardBefore(String body, String after, String before) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf(
        '_isCurrentRelayClient(client)',
        afterIndex,
      );
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    void expectMarkerBefore(String body, String marker, String before) {
      final markerIndex = body.indexOf(marker);
      final beforeIndex = body.indexOf(before, markerIndex);

      expect(markerIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(markerIndex, lessThan(beforeIndex));
    }

    expectGuardBefore(
      between('Future<String?> _nameDialog(', 'void _refreshFileTrees('),
      'if (raw == null) return null;',
      "_snack('\$label 不能为空",
    );
    expectGuardBefore(
      between(
        'Future<bool> _closeAffectedOpenFiles(',
        'Future<void> _newFileInDir(',
      ),
      "await _confirm('关闭未保存文件?'",
      'setState(() {',
    );
    expectGuardBefore(
      between(
        'Future<void> _closeCodeFile(',
        'Future<void> _closeActiveCodeFile',
      ),
      "await _confirm(\n        '关闭未保存文件?'",
      'setState(() {',
    );
    expectGuardBefore(
      between(
        'Future<void> _closeOtherCodeFiles(',
        'Future<void> _closeCodeFilesToRight',
      ),
      "await _confirm('关闭其他未保存文件?'",
      'setState(() {',
    );
    expectGuardBefore(
      between(
        'Future<void> _closeCodeFilesToRight(',
        'Future<void> _closeCodeFilesToLeft',
      ),
      "await _confirm('关闭右侧未保存文件?'",
      'setState(() {',
    );
    expectGuardBefore(
      between(
        'Future<void> _closeCodeFilesToLeft(',
        'Future<void> _closeUnmodifiedCodeFiles',
      ),
      "await _confirm('关闭左侧未保存文件?'",
      'setState(() {',
    );
    expectGuardBefore(
      between(
        'Future<void> _closeAllCodeFiles(',
        'Future<void> _closePaneFiles',
      ),
      "await _confirm('关闭所有未保存文件?'",
      'setState(() {',
    );
    expectGuardBefore(
      between('Future<void> _closePaneFiles(', 'void _copyFilePath'),
      "await _confirm('关闭此分屏未保存文件?'",
      'setState(() {',
    );
    expectGuardBefore(
      between(
        'void _refreshFileTrees(',
        'Future<bool> _closeAffectedOpenFiles(',
      ),
      'void _refreshFileTrees',
      'setState(() {',
    );
    expectGuardBefore(
      between('void _openCodeFile(', '// _openDiffTab opens'),
      'void _openCodeFile',
      'setState(',
    );
    expectGuardBefore(
      between('Future<void> _runCli(', 'void _launch('),
      'Future<void> _runCli',
      'setState(() => _busy = true)',
    );
    expectGuardBefore(
      between('Future<void> _runCli(', 'void _launch('),
      'await action();',
      'if (after != null)',
    );
    expectGuardBefore(
      between(
        'Future<void> _showRecentFiles()',
        'Future<void> _showRecentLocations()',
      ),
      'showDialog<String>',
      '_openCodeFile(path)',
    );
    expectGuardBefore(
      between(
        'Future<void> _showRecentLocations()',
        'Future<void> _setGitLogPathFilter()',
      ),
      'showDialog<_CodeLocation>',
      '_openCodeFile(loc.path',
    );
    expectGuardBefore(
      between(
        'Future<void> _setGitLogPathFilter()',
        'Future<void> _showShortcuts()',
      ),
      'ctl.dispose();',
      'setState(() => _logPathFilter = next)',
    );
    expectGuardBefore(
      between(
        'Future<List<String>?> _fieldsDialog(',
        '@override\n  Future<bool> _confirm',
      ),
      'if (raw == null) return null;',
      "_snack('\${fields[i].label} 不能为空')",
    );
    expectGuardBefore(
      between(
        'Future<void> _createBranchFromCommit(',
        '@override\n  Future<void> _cherryPickCommit',
      ),
      "if (branch.isEmpty)",
      'setState(() => _gitLoading = true)',
    );
    expectGuardBefore(
      between(
        '@override\n  Future<void> _cherryPickCommit',
        '@override\n  Future<void> _revertCommit',
      ),
      'if (!ok) return;',
      'setState(() => _gitLoading = true)',
    );
    expectGuardBefore(
      between(
        '@override\n  Future<void> _revertCommit',
        'Future<void> _selectStash',
      ),
      'if (!ok) return;',
      'setState(() => _gitLoading = true)',
    );
    expectGuardBefore(
      between('Future<void> _renameSession(', 'List<Widget> _worktreeNodes('),
      'final v = raw.trim();',
      'setState(() => s.name',
    );
    expectGuardBefore(
      between(
        'Future<void> _workspaceSettings(',
        'PopupMenuButton<String> _projectMenu(',
      ),
      'if (draft == null) return;',
      'await _runCli(',
    );
    final onlineSend = between(
      'Future<void> _showSendToOnlineUser(String text)',
      'Future<void> _loadTasks()',
    );
    expectMarkerBefore(onlineSend, 'if (!mounted ||', 'setSt(() {');
    expectMarkerBefore(onlineSend, 'seq != loadSeq', 'setSt(() {');
    final remoteAssign = between(
      'Future<String?> _remoteAssignTodo(',
      'SessionCard? _remoteCard(',
    );
    expect(remoteAssign, contains('账号已切换,请重新指派'));
    expectGuardBefore(
      remoteAssign,
      'fallback = await client.todo(todoId);',
      'final me = widget.me;',
    );
    expectClientGuardBefore(
      remoteAssign,
      'fallback = await client.todo(todoId);',
      'final me = widget.me;',
    );
    expectGuardBefore(
      remoteAssign,
      'final (spawnedSid, err) = await _spawnForDispatch',
      'sid = spawnedSid;',
    );
    expectClientGuardBefore(
      remoteAssign,
      'final (spawnedSid, err) = await _spawnForDispatch',
      'sid = spawnedSid;',
    );
    expectGuardBefore(
      remoteAssign,
      'await Future.delayed(const Duration(milliseconds: 100));',
      'card = _remoteCard(sid);',
    );
    expectClientGuardBefore(
      remoteAssign,
      'await Future.delayed(const Duration(milliseconds: 100));',
      'card = _remoteCard(sid);',
    );
    expectGuardBefore(
      remoteAssign,
      'final prep = await prepareTodoAssignmentText',
      'final dispatchErr = deliverLocalMessage',
    );
    expectClientGuardBefore(
      remoteAssign,
      'final prep = await prepareTodoAssignmentText',
      'final dispatchErr = deliverLocalMessage',
    );
    expectGuardBefore(
      remoteAssign,
      'await Future.delayed(const Duration(milliseconds: 200));',
      'card = _remoteCard(sid);',
    );
    expectClientGuardBefore(
      remoteAssign,
      'await Future.delayed(const Duration(milliseconds: 200));',
      'card = _remoteCard(sid);',
    );
    expectClientGuardBefore(
      remoteAssign,
      'await client.assignTodo',
      'await client.updateTodo',
    );
    expectClientGuardBefore(
      remoteAssign,
      'await client.updateTodo',
      'await client.setTodoStatus',
    );
  });

  test('workspace git refresh guards mounted before loading state', () {
    final source = File(
      'lib/screens/workspace/git_mixin.dart',
    ).readAsStringSync();
    final refresh = source.substring(
      source.indexOf('Future<void> _refreshGit() async {'),
      source.indexOf('/// 懒加载某个附加 worktree'),
    );

    final guardIndex = refresh.indexOf('if (!mounted) return;');
    final loadingIndex = refresh.indexOf('setState(() {');
    expect(guardIndex, isNonNegative);
    expect(loadingIndex, isNonNegative);
    expect(guardIndex, lessThan(loadingIndex));
  });

  test('workspace git menus guard mounted before git side effects', () {
    String between(String path, String start, String end) {
      final source = File(path).readAsStringSync();
      final startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative);
      final endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative);
      return source.substring(startIndex, endIndex);
    }

    void expectGuardBefore(String body, String after, String before) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf('if (!mounted) return', afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    void expectMarkerBefore(String body, String marker, String before) {
      final markerIndex = body.indexOf(marker);
      final beforeIndex = body.indexOf(before, markerIndex);

      expect(markerIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(markerIndex, lessThan(beforeIndex));
    }

    expectGuardBefore(
      between(
        'lib/screens/workspace/git_log_branch_menu.dart',
        'Future<void> _newBranchFrom(',
        'Future<void> _newBranchFromTag(',
      ),
      'if (name == null) return;',
      '_createBranchCurrent',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/git_log_branch_menu.dart',
        'Future<void> _newBranchFromTag(',
        'Future<void> _pushTagCurrent(',
      ),
      'if (name == null) return;',
      '_createBranchCurrent',
    );
    expectMarkerBefore(
      between(
        'lib/screens/workspace/git_log_branch_menu.dart',
        'Future<void> _checkoutTag(',
        'Future<void> _deleteLocalTag(',
      ),
      'if (!ok || !mounted || _gitLoading) return;',
      'setState(() => _gitLoading = true)',
    );
    expectMarkerBefore(
      between(
        'lib/screens/workspace/git_log_branch_menu.dart',
        'Future<void> _deleteLocalTag(',
        'Future<void> _updateBranch(',
      ),
      'if (!ok || !mounted || _gitLoading) return;',
      'setState(() => _gitLoading = true)',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/git_log_branch_menu.dart',
        'Future<void> _renameBranchPrompt(',
        '\n}',
      ),
      'if (name == null || name == b.name) return;',
      'setState(() => _gitLoading = true)',
    );

    for (final method in [
      'Future<void> _checkoutRevision(',
      'Future<void> _resetToCommit(',
      'Future<void> _undoCommit(',
      'Future<void> _rewordCommit(',
      'Future<void> _fixupOrSquash(',
      'Future<void> _dropCommit(',
      'Future<void> _pushUpToCommit(',
      'Future<void> _newTagAtCommit(',
    ]) {
      final body = between(
        'lib/screens/workspace/git_log_commit_menu.dart',
        method,
        method == 'Future<void> _newTagAtCommit('
            ? 'Future<void> _goToParent('
            : '  ///',
      );
      expectGuardBefore(body, 'return;', 'setState(() => _gitLoading = true)');
    }

    expectGuardBefore(
      between(
        'lib/screens/workspace/git_log_commit_menu.dart',
        'Future<void> _createPatchFromCommit(',
        'Future<void> _checkoutRevision(',
      ),
      'if (out == null) return;',
      'writePatchFile(out, patch)',
    );

    expectGuardBefore(
      between(
        'lib/screens/workspace/git_log_difftree_menu.dart',
        'Future<void> _applyFileDiffPatch(',
        'Future<void> _createPatchFromFileDiff(',
      ),
      'Revert selected changes?',
      'setState(() => _gitLoading = true)',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/git_log_difftree_menu.dart',
        'Future<void> _createPatchFromFileDiff(',
        'Future<void> _getFileFromRevision(',
      ),
      'if (out == null) return;',
      'writePatchFile(out, f.raw)',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/git_log_difftree_menu.dart',
        'Future<void> _getFileFromRevision(',
        'String _revShort(',
      ),
      'Get from revision?',
      'setState(() => _gitLoading = true)',
    );
    expect(
      File(
        'lib/screens/workspace/git_log_difftree_menu.dart',
      ).readAsStringSync(),
      isNot(contains('writePatchToPickedFile')),
    );

    expectGuardBefore(
      between(
        'lib/screens/workspace/commit_changes_menu.dart',
        'Future<void> _commitSingleFile(',
        'Future<void> _deleteChangeFile(',
      ),
      'if (msg == null) return;',
      'setState(() => _gitLoading = true)',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/commit_changes_menu.dart',
        'Future<void> _deleteChangeFile(',
        'Future<String?> _localChangesPatch(',
      ),
      'return;',
      'setState(() => _gitLoading = true)',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/commit_changes_menu.dart',
        'Future<void> _createPatchFromChanges(',
        'Future<void> _copyPatchToClipboard(',
      ),
      'if (patch == null) return;',
      'FilePicker.platform.saveFile',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/commit_changes_menu.dart',
        'Future<void> _createPatchFromChanges(',
        'Future<void> _copyPatchToClipboard(',
      ),
      'if (dest == null) return;',
      'File(out).writeAsString',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/commit_changes_menu.dart',
        'Future<void> _copyPatchToClipboard(',
        'Future<void> _shelveChange(',
      ),
      'if (patch == null) return;',
      'Clipboard.setData',
    );
    expectGuardBefore(
      between(
        'lib/screens/workspace/commit_changes_menu.dart',
        'Future<void> _shelveChange(',
        'Future<String?> _promptCommitMessage(',
      ),
      'if (opts == null) return;',
      'setState(() => _gitLoading = true)',
    );

    final branchDialog = File(
      'lib/screens/workspace/branch_dialog.dart',
    ).readAsStringSync();
    expect(
      branchDialog.substring(
        branchDialog.indexOf('Future<void> _run('),
        branchDialog.indexOf('Future<void> _checkout('),
      ),
      contains('if (!mounted) return;'),
    );
  });

  test('remote workspace dialogs guard mounted before remote commands', () {
    final source = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();

    String between(String start, String end) {
      final startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative);
      final endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative);
      return source.substring(startIndex, endIndex);
    }

    void expectGuardBefore(String body, String after, String before) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf('if (!mounted) return;', afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    expectGuardBefore(
      between('Future<void> _renameSessionDialog(', 'Widget _codeTab()'),
      'allowEmpty: true,',
      '_c.renameSession',
    );
    expectGuardBefore(
      between(
        'Future<void> _newSessionDialog()',
        '// Open the supervisor knowledge-base editor',
      ),
      'showDialog<RemoteSessionDraft>',
      '_c.newSession',
    );
    expectGuardBefore(
      between('Future<void> _confirmThen(', 'Future<void> _commitDialog()'),
      'final ok = await confirm(context, msg);',
      'if (ok) action();',
    );
    expectGuardBefore(
      between('Future<void> _openScreenShare(', '// _xferTile renders'),
      'await _c.shareViewer.init();',
      '_c.startShare(source)',
    );
    expectGuardBefore(
      between('Future<void> _commitDialog()', 'Future<void> _stashDialog()'),
      'showDialog<RemoteCommitDraft>',
      '_c.gitCommit',
    );
    expectGuardBefore(
      between('Future<void> _stashDialog()', 'Future<void> _branchSheet()'),
      'allowEmpty: true,',
      '_c.gitStash',
    );
    expectGuardBefore(
      between('Future<void> _newBranchDialog()', '// --- 管理'),
      'okLabel: \'创建\',',
      '_c.gitCreateBranch',
    );
    expectGuardBefore(
      between(
        'Future<void> _newWorkspaceDialog()',
        'Future<void> _addProjectDialog(',
      ),
      'showDialog<RemoteWorkspaceDraft>',
      '_c.newWorkspace',
    );
    expectGuardBefore(
      between('Future<void> _addProjectDialog(', 'class ScreenShareViewerPage'),
      'okLabel: \'添加\',',
      '_c.addProject',
    );
    expectGuardBefore(
      between('Future<void> _openFile(', 'Future<void> _newFile()'),
      'await Navigator.of(context).push',
      'widget.client.openDir(_cwd)',
    );
    expectGuardBefore(
      between('Future<void> _newFile()', 'void _descend('),
      'title: \'新建文件\'',
      '_openFile(',
    );
    expectGuardBefore(
      between('Future<void> _addDialog()', 'Future<void> _remove('),
      'showDialog<RemoteWorktreeDraft>',
      'widget.client.addWorktree',
    );
    expectGuardBefore(
      between('Future<void> _remove(', '@override\n  Widget build'),
      'final ok = await confirm',
      'widget.client.removeWorktree',
    );
    expectGuardBefore(
      between('Future<void> _paste()', '// _sendImage picks'),
      'Clipboard.getData',
      '_term.paste(text)',
    );

    final keyEditor = between(
      'void _openKeyBarEditor()',
      '// Common special keys',
    );
    final editExisting = keyEditor.indexOf(
      'final r = await _editKeyDialog(kb);',
    );
    final editExistingGuard = keyEditor.indexOf(
      'if (!mounted || !sheetCtx.mounted) return;',
      editExisting,
    );
    final editExistingApply = keyEditor.indexOf('apply(() {', editExisting);
    expect(editExistingGuard, isNonNegative);
    expect(editExistingApply, isNonNegative);
    expect(editExistingGuard, lessThan(editExistingApply));

    final addButton = keyEditor.indexOf(
      'final r = await _editKeyDialog(null);',
    );
    final addButtonGuard = keyEditor.indexOf(
      'if (!mounted || !sheetCtx.mounted) return;',
      addButton,
    );
    final addButtonApply = keyEditor.indexOf('if (r != null) apply', addButton);
    expect(addButtonGuard, isNonNegative);
    expect(addButtonApply, isNonNegative);
    expect(addButtonGuard, lessThan(addButtonApply));
  });

  test('team task dialogs guard mounted before side effects', () {
    String between(String path, String start, String end) {
      final source = File(path).readAsStringSync();
      final startIndex = source.indexOf(start);
      expect(startIndex, isNonNegative);
      final endIndex = source.indexOf(end, startIndex);
      expect(endIndex, isNonNegative);
      return source.substring(startIndex, endIndex);
    }

    void expectGuardBefore(String body, String after, String before) {
      final afterIndex = body.indexOf(after);
      final guardIndex = body.indexOf('if (!mounted) return', afterIndex);
      final beforeIndex = body.indexOf(before, afterIndex);

      expect(afterIndex, isNonNegative);
      expect(guardIndex, isNonNegative);
      expect(beforeIndex, isNonNegative);
      expect(guardIndex, lessThan(beforeIndex));
    }

    expectGuardBefore(
      between(
        'lib/screens/account_page.dart',
        'Future<void> _chooseHookEvents(',
        'Future<void> _saveLocalConfig()',
      ),
      'if (picked == null || picked.isEmpty) return;',
      '_reinstallHooks',
    );
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<bool> _confirmInit(',
        'Future<void> _retract(',
      ),
      'if (ok != true) return false;',
      'RepoConfig(',
    );
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<void> _postComment(',
        'Future<void> _ack(',
      ),
      'await _client.postComment',
      '_commentCtl.clear',
    );
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<void> _ack(',
        'Future<void> _pickup(',
      ),
      'await _client.ack',
      '_loadExtras',
    );
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<void> _pickup(',
        '// _confirmInit prompts',
      ),
      '_confirmInit(p, path)) return;',
      'setState(() => _picking = true)',
    );
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<void> _pickup(',
        '// _confirmInit prompts',
      ),
      'final r = await Cli.pickup',
      'widget.onOpenTerminal',
    );
    expectGuardBefore(
      between(
        'lib/screens/todos_page.dart',
        'Future<void> _createDialog()',
        '// _dropStatus is',
      ),
      'if (created == true)',
      '_store.refresh',
    );
    expectGuardBefore(
      between(
        'lib/screens/todos_page.dart',
        'Future<void> _assignDialog(',
        '@override\n  Widget build',
      ),
      'if (changed == true)',
      '_store.refresh',
    );
    expectGuardBefore(
      between(
        'lib/screens/todos_page.dart',
        'Future<void> _summonTodoAssistant()',
        '// _importFromLinear shells',
      ),
      'if (go != true || proj == null) return;',
      '_overview.spawn',
    );
    final linearConfigDialog = between(
      'lib/screens/todos_page.dart',
      'Future<void> _linearConfigDialog()',
      '@override\n  void dispose()',
    );
    expectGuardBefore(
      linearConfigDialog,
      'if (saved != true) return;',
      'Cli.configSet',
    );
    expect(linearConfigDialog, contains('finally {'));
    expect(linearConfigDialog, contains('tokenCtl.dispose();'));
    expect(linearConfigDialog, contains('teamCtl.dispose();'));
    expect(linearConfigDialog, contains('projectCtl.dispose();'));
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<void> _retract(',
        'Future<void> _reassign(',
      ),
      'if (reason == null) return;',
      '_client.retract',
    );
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<void> _retract(',
        'Future<void> _reassign(',
      ),
      'await _client.retract',
      'widget.onChanged',
    );
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<void> _reassign(',
        'Widget _header(',
      ),
      'if (result == null) return;',
      '_client.reassign',
    );
    expectGuardBefore(
      between(
        'lib/screens/handoff_detail_view.dart',
        'Future<void> _reassign(',
        'Widget _header(',
      ),
      'await _client.reassign',
      'widget.onChanged',
    );
    expectGuardBefore(
      between(
        'lib/screens/todo_detail_view.dart',
        'Future<void> _delete()',
        'Future<void> _postComment()',
      ),
      'if (ok != true) return;',
      'client.deleteTodo',
    );
    expectGuardBefore(
      between(
        'lib/screens/todo_detail_view.dart',
        'Future<void> _postComment()',
        'Future<void> _pickAndUploadAttachments()',
      ),
      'await client.postTodoComment',
      '_commentCtl.clear',
    );
    final attachmentUpload = between(
      'lib/screens/todo_detail_view.dart',
      'Future<void> _pickAndUploadAttachments()',
      'Color _statusColor(',
    );
    expectGuardBefore(
      attachmentUpload,
      'for (final f in res.files)',
      'File(f.path!).readAsBytes',
    );
    expectGuardBefore(
      attachmentUpload,
      'File(f.path!).readAsBytes',
      'client.uploadTodoAttachment',
    );
    final quickCreate = between(
      'lib/screens/todos_page.dart',
      'Future<void> _submit() async {',
      '@override\n  Widget build(BuildContext context) {',
    );
    expectGuardBefore(
      quickCreate,
      'await widget.client.createTodo',
      'for (final f in _files)',
    );
    expectGuardBefore(
      quickCreate,
      'for (final f in _files)',
      'File(f.path!).readAsBytes',
    );
    expectGuardBefore(
      quickCreate,
      'File(f.path!).readAsBytes',
      'widget.client.uploadTodoAttachment',
    );
    final assignExisting = between(
      'lib/screens/todos_page.dart',
      'Future<void> _assignToExisting() async {',
      'Future<void> _assignToNew() async {',
    );
    expectGuardBefore(
      assignExisting,
      'final prep = await _prepareAssignment',
      'widget.overviewStore.dispatch',
    );
    expectGuardBefore(
      assignExisting,
      'await _syncAssignVisibility',
      '_maybeBumpToInProgress',
    );
    final assignNew = between(
      'lib/screens/todos_page.dart',
      'Future<void> _assignToNew() async {',
      '// Remote variants (mobile):',
    );
    expectGuardBefore(
      assignNew,
      'await widget.overviewStore.spawn',
      'final prep = await _prepareAssignment',
    );
    expectGuardBefore(
      assignNew,
      'final prep = await _prepareAssignment',
      'widget.overviewStore.dispatch',
    );
    expectGuardBefore(
      assignNew,
      'await _syncAssignVisibility',
      '_maybeBumpToInProgress',
    );
    expectGuardBefore(
      between(
        'lib/widgets/todo_property_controls.dart',
        'class _PriorityControlState',
        'class StatusControl',
      ),
      'await _openBelow<String>',
      'widget.onChanged(v)',
    );
    expectGuardBefore(
      between(
        'lib/widgets/todo_property_controls.dart',
        'class _StatusControlState',
        'class RecurrenceControl',
      ),
      'await _openBelow<TodoStatus>',
      'widget.onChanged(v)',
    );
    expectGuardBefore(
      between(
        'lib/widgets/todo_property_controls.dart',
        'class _RecurrenceControlState',
        'class DueDatePill',
      ),
      'await _openBelow<String>',
      'widget.onChanged(v)',
    );
    expectGuardBefore(
      between(
        'lib/widgets/todo_property_controls.dart',
        'class _WorkspaceRepoControlState',
        'class GroupControl',
      ),
      'final repo = await _openBelow<ProjectCfg>',
      'widget.onBind',
    );
    expectGuardBefore(
      between(
        'lib/widgets/todo_property_controls.dart',
        'class _GroupControlState',
        '@override\n  Widget build',
      ),
      'showDialog<String>',
      'widget.onSelect(result)',
    );
  });

  test('speech recognizer debug logging is off by default', () {
    expect(kSpeechDebugLogging, isFalse);
  });

  group('splitFileNameDir', () {
    test('splits POSIX paths', () {
      expect(splitFileNameDir('/tmp/project/lib/main.dart'), (
        'main.dart',
        '/tmp/project/lib',
      ));
    });

    test('splits Windows paths', () {
      expect(splitFileNameDir(r'E:\demoFile\oppr\package.json'), (
        'package.json',
        r'E:\demoFile\oppr',
      ));
    });

    test('uses the last separator when paths are mixed', () {
      expect(splitFileNameDir(r'E:\demoFile\oppr/src/main.dart'), (
        'main.dart',
        r'E:\demoFile\oppr/src',
      ));
    });
  });

  test('parseUnifiedDiff splits files + counts; parseRows aligns', () {
    final files = parseUnifiedDiff(_sampleDiff);
    expect(files.length, 2);
    expect(files[0].path, 'lib/a.dart');
    expect(files[0].status, 'modified');
    expect(files[0].adds, 1);
    expect(files[0].dels, 1);
    expect(files[1].path, 'lib/new.dart');
    expect(files[1].status, 'added');

    final rows = parseRows(files[0].raw).where((r) => !r.isHunk).toList();
    // context1 | (old↔new paired) | context2
    expect(rows.length, 3);
    expect(rows[0].leftKind, DiffKind.context);
    expect(rows[1].leftKind, DiffKind.removed);
    expect(rows[1].rightKind, DiffKind.added);
    expect(rows[1].left, 'old line');
    expect(rows[1].right, 'new line');

    final added = parseRows(files[1].raw).where((r) => !r.isHunk).toList();
    expect(added.length, 2);
    expect(added[0].leftKind, DiffKind.empty); // new file → left blank
    expect(added[0].rightKind, DiffKind.added);
  });

  test('splitHunks separates header + hunks; hunk rows are numbered', () {
    final files = parseUnifiedDiff(_sampleDiff);
    final (header, hunks) = splitHunks(files[0].raw);
    expect(header.contains('diff --git a/lib/a.dart b/lib/a.dart'), isTrue);
    expect(header.contains('+++ b/lib/a.dart'), isTrue);
    expect(hunks.length, 1);
    expect(hunks[0].startsWith('@@'), isTrue);
    expect(hunks[0].contains('-old line'), isTrue);
    expect(hunks[0].contains('+new line'), isTrue);

    final hunkRows = parseRows(files[0].raw).where((r) => r.isHunk).toList();
    expect(hunkRows.length, 1);
    expect(hunkRows.first.hunkIndex, 0);
  });

  test('GitHubClient.parseSlug handles https / git@ / path / non-github', () {
    expect(
      GitHubClient.parseSlug('https://github.com/owner/repo.git'),
      'owner/repo',
    );
    expect(
      GitHubClient.parseSlug('https://github.com/owner/repo'),
      'owner/repo',
    );
    expect(
      GitHubClient.parseSlug('git@github.com:owner/repo.git'),
      'owner/repo',
    );
    expect(
      GitHubClient.parseSlug('https://github.com/owner/repo/pull/5'),
      'owner/repo',
    );
    expect(GitHubClient.parseSlug('/just/a/local/path'), isNull);
    expect(GitHubClient.parseSlug(''), isNull);
  });

  test('ListItem.fromJson parses fields + defaults kind', () {
    final it = ListItem.fromJson({
      'id': 'h1',
      'sender': 'a@x',
      'recipients': ['b@x', ' c@x ', ' '],
      'urgency': 'urgent',
      'state': 'pending',
      'repo_name': 'repo',
      'headline': 'hi',
      'created_at': '2026-01-01T00:00:00Z',
    });
    expect(it.id, 'h1');
    expect(it.sender, 'a@x');
    expect(it.urgency, 'urgent');
    expect(it.kind, 'delivery'); // omitted → default
    expect(it.repoName, 'repo');
    expect(it.recipients, ['b@x', 'c@x']);
    expect(it.recipientSummary, '2 人');
    expect(it.routeLabel, 'a@x → 2 人');
  });

  test('Package.fromJson parses nested api_delta / git / attachments', () {
    final p = Package.fromJson({
      'id': 'h1',
      'sender': 'a',
      'recipient': 'b',
      'recipients': ['b', 'c'],
      'summary_md': '# hi',
      'repo': {'name': 'r', 'branch': 'main'},
      'delivery_target': {
        'project_id': ' project-1 ',
        'org_id': 'org-1',
        'member': ' dev@team ',
      },
      'module_paths': ['a/b'],
      'attachments': [
        {'name': 'f.txt', 'size': 12, 'sha256': 'x'},
      ],
      'git': {
        'commits': [
          {'sha': 'abc', 'subject': 's'},
        ],
        'changed_paths': ['x.go'],
      },
      'api_delta': {
        'added': [
          {'method': 'GET', 'path': '/v1/x', 'summary': 'sum'},
        ],
      },
    });
    expect(p.repo.name, 'r');
    expect(p.recipients, ['b', 'c']);
    expect(p.routeLabel(), 'a → 2 人');
    expect(p.deliveryTarget?.projectId, 'project-1');
    expect(p.deliveryTarget?.orgId, 'org-1');
    expect(p.deliveryTarget?.member, 'dev@team');
    expect(
      deliveryTargetLabel(p.deliveryTarget!),
      '项目 project-1 · 团队 org-1 · 成员 dev@team',
    );
    expect(p.modulePaths, ['a/b']);
    expect(p.attachments.single.name, 'f.txt');
    expect(p.attachments.single.size, 12);
    expect(p.git!.commits.single.sha, 'abc');
    expect(p.git!.changedPaths, ['x.go']);
    expect(p.apiDelta!.added.single.method, 'GET');
    expect(p.apiDelta!.isEmpty, isFalse);
  });

  test('Package.fromJson ignores blank delivery_target', () {
    final p = Package.fromJson({
      'id': 'h_blank_target',
      'sender': 'a',
      'recipient': 'b',
      'repo': {'name': 'r'},
      'delivery_target': {'project_id': ' ', 'org_id': '', 'member': null},
    });
    expect(p.deliveryTarget, isNull);
  });

  test('Me.fromJson + ProjectRole', () {
    final me = Me.fromJson({
      'identity': 'a',
      'is_admin': true,
      'organizations': [
        {'id': 'o1', 'name': 'Org', 'role': 'admin'},
      ],
      'projects': [
        {'id': 'p1', 'name': 'P', 'role': 'owner'},
      ],
    });
    expect(me.isAdmin, isTrue);
    expect(me.organizations.single.role, 'admin');
    expect(me.projects.single.role, 'owner');
  });

  test('Organization.fromJson carries fresh caller role', () {
    final org = Organization.fromJson({
      'id': 'o1',
      'name': 'Org',
      'owner_identity': 'alice',
      'role': 'owner',
    });
    expect(org.role, 'owner');
  });

  test('multi-tenant models trim ids identities names and roles', () {
    final me = Me.fromJson({
      'identity': ' alice ',
      'organizations': [
        {'id': ' org-a ', 'name': ' Team A ', 'role': ' admin '},
      ],
      'projects': [
        {
          'id': ' p1 ',
          'org_id': ' org-a ',
          'name': ' Project A ',
          'role': ' owner ',
        },
      ],
    });
    final org = Organization.fromJson({
      'id': ' org-a ',
      'name': ' Team A ',
      'owner_identity': ' alice ',
      'role': ' owner ',
    });
    final project = Project.fromJson({
      'id': ' p1 ',
      'org_id': ' org-a ',
      'name': ' Project A ',
      'owner_identity': ' alice ',
      'role': ' member ',
    });
    final online = OnlineUser.fromJson({'identity': ' alice ', 'online': true});
    final user = User.fromJson({
      'identity': ' alice ',
      'display_name': ' Alice ',
    });

    expect(me.identity, 'alice');
    expect(me.organizations.single.id, 'org-a');
    expect(me.organizations.single.name, 'Team A');
    expect(me.organizations.single.role, 'admin');
    expect(me.projects.single.id, 'p1');
    expect(me.projects.single.orgId, 'org-a');
    expect(me.projects.single.name, 'Project A');
    expect(me.projects.single.role, 'owner');
    expect(org.id, 'org-a');
    expect(org.name, 'Team A');
    expect(org.ownerIdentity, 'alice');
    expect(org.role, 'owner');
    expect(project.id, 'p1');
    expect(project.orgId, 'org-a');
    expect(project.name, 'Project A');
    expect(project.ownerIdentity, 'alice');
    expect(project.role, 'member');
    expect(online.identity, 'alice');
    expect(user.identity, 'alice');
    expect(user.displayName, 'Alice');
  });

  test('Status.fromJson handles null picked_at', () {
    final s = Status.fromJson({
      'state': 'pending',
      'recipients': [' dev@x ', 'ops@x'],
      'pickup_by': {
        ' dev@x ': {'state': 'picked', 'picked_at': '2026-01-01T00:01:00Z'},
        'ops@x': {'state': 'pending'},
      },
      'comment_count': 3,
      'created_at': '2026-01-01T00:00:00Z',
    });
    expect(s.state, 'pending');
    expect(s.pickedAt, isNull);
    expect(s.commentCount, 3);
    expect(s.recipients, ['dev@x', 'ops@x']);
    expect(s.pickupBy['dev@x']?.state, 'picked');
    expect(s.pickupSlots.map((e) => '${e.identity}:${e.state}'), [
      'dev@x:picked',
      'ops@x:pending',
    ]);
  });

  test('errorText maps DioException to friendly text', () {
    final timeout = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionTimeout,
    );
    expect(errorText(timeout), contains('超时'));

    final forbidden = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/'),
        statusCode: 403,
      ),
    );
    expect(errorText(forbidden), contains('权限'));

    expect(errorText('boom'), 'boom');
  });

  test('RepoConfig save→load round-trips (.cc-handoff.toml)', () async {
    final dir = await Directory.systemTemp.createTemp('repocfg');
    try {
      final c = RepoConfig(
        raw: const {
          'integrations': {
            'other': {'enabled': true},
          },
        },
        partner: 'alex@frontend',
        partners: 'a@x, b@y',
        base: 'origin/main',
        autoLaunch: true,
        terminalApp: 'iterm2',
        linearEnabled: true,
        teamKey: 'ENG',
        linearProjectId: 'proj-123',
        types: 'mention',
        rules: [
          RuleCfg(
            whenPathMatches: '^x/',
            suggestEdit: 'a.ts, b.ts',
            suggestCreate: true,
          ),
        ],
      );
      await c.save(dir.path);
      final back = await RepoConfig.load(dir.path);
      expect(back.partner, 'alex@frontend');
      expect(back.partners, 'a@x, b@y');
      expect(back.base, 'origin/main');
      expect(back.autoLaunch, isTrue);
      expect(back.terminalApp, 'iterm2');
      expect(back.linearEnabled, isTrue);
      expect(back.teamKey, 'ENG');
      expect(back.linearProjectId, 'proj-123');
      expect(back.types, 'mention');
      expect((back.raw['integrations'] as Map?)?['other'], isNotNull);
      expect(back.rules.length, 1);
      expect(back.rules.first.whenPathMatches, '^x/');
      expect(back.rules.first.suggestCreate, isTrue);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
