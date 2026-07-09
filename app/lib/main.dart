import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/models.dart';
import 'api/relay_client.dart';
import 'local/config.dart';
import 'local/crash_log.dart';
import 'local/prefs.dart';
import 'local/session.dart';
import 'local/session_overview.dart';
import 'local/todo_store.dart';
import 'local/update_service.dart';
import 'notifications.dart';
import 'screens/account_page.dart';
import 'screens/admin_page.dart';
import 'screens/capsule_plaza_page.dart';
import 'screens/handoffs_page.dart';
import 'screens/login_screen.dart';
import 'screens/projects_page.dart';
import 'screens/remote_workspace_page.dart';
import 'screens/session_overview_page.dart';
import 'screens/todos_page.dart';
import 'screens/workspace_page.dart';
import 'theme.dart';
import 'ui_scale.dart';
import 'widgets.dart';

void main() {
  // runZonedGuarded + installCrashHandlers() route uncaught Dart errors (and
  // lifecycle breadcrumbs) into <appSupport>/crash.log — see crash_log.dart.
  // On Windows the app can vanish outright on a NATIVE crash (ConPTY / IME) that
  // no Dart handler catches, so the value is the breadcrumb trail before the
  // process dies. ensureInitialized() must run inside the same zone as runApp.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initCrashLog();
    installCrashHandlers();
    // Any uncaught build/layout/paint error shows a readable panel instead of
    // the release default — a silent grey box that fills the whole window. This
    // is the safety net that turns a future regression (like the _me! one that
    // grey-screened the app on a transient /v1/me failure) into a legible error.
    ErrorWidget.builder = (details) => _ErrorPanel(details);
    await Prefs.load();
    Notifications.init();
    runApp(const CcApp());
  }, (error, stack) => logCrash(error, stack));
}

// Release-safe replacement for Flutter's default grey ErrorWidget. Kept
// deliberately minimal and dependency-free: it can be invoked outside a
// MaterialApp (e.g. if the root itself throws), so it brings its own
// Directionality/Material and must never throw itself.
class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel(this.details);
  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: CcColors.bg,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: CcColors.danger,
                  size: 40,
                ),
                const SizedBox(height: 12),
                const Text(
                  '出错了',
                  style: TextStyle(
                    color: CcColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  details.exceptionAsString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CcColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Zoom the whole UI in/out (⌘+ / ⌘- / ⌘0) — see ui_scale.dart.
class _ZoomIntent extends Intent {
  final double delta;
  const _ZoomIntent(this.delta);
}

class _ZoomResetIntent extends Intent {
  const _ZoomResetIntent();
}

class CcApp extends StatelessWidget {
  const CcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cc-handoff',
      debugShowCheckedModeBanner: false,
      theme: ccTheme(),
      shortcuts: <ShortcutActivator, Intent>{
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.equal, meta: true):
            const _ZoomIntent(uiScaleStep),
        const SingleActivator(
          LogicalKeyboardKey.equal,
          meta: true,
          shift: true,
        ): const _ZoomIntent(
          uiScaleStep,
        ),
        const SingleActivator(LogicalKeyboardKey.minus, meta: true):
            const _ZoomIntent(-uiScaleStep),
        const SingleActivator(LogicalKeyboardKey.digit0, meta: true):
            const _ZoomResetIntent(),
        const SingleActivator(LogicalKeyboardKey.equal, control: true):
            const _ZoomIntent(uiScaleStep),
        const SingleActivator(LogicalKeyboardKey.minus, control: true):
            const _ZoomIntent(-uiScaleStep),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true):
            const _ZoomResetIntent(),
      },
      actions: <Type, Action<Intent>>{
        ...WidgetsApp.defaultActions,
        _ZoomIntent: CallbackAction<_ZoomIntent>(
          onInvoke: (i) {
            nudgeUiScale(i.delta);
            return null;
          },
        ),
        _ZoomResetIntent: CallbackAction<_ZoomResetIntent>(
          onInvoke: (_) {
            resetUiScale();
            return null;
          },
        ),
      },
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: uiScale,
        builder: (_, scale, _) => UiScaler(scale: scale, child: child!),
      ),
      home: const HomeShell(),
    );
  }
}

// HomeShell resolves auth (stored session → desktop config.toml → login screen),
// then hosts the pages behind a NavigationRail (desktop) / NavigationBar
// (mobile). The terminal cockpit is desktop-only; management works on both.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppConfig?
  _cfg; // active auth (from session) + repos (from config.toml, if any)
  RelayClient? _client;
  Me? _me;
  bool _loading = true;
  bool _needLogin = false;
  // True when /v1/me failed at launch and _me is a synthesized fallback (see
  // _bootstrap). Drives the degraded banner + reconnect affordance in build().
  bool _meDegraded = false;
  String? _relayHint;
  int _index = 0;
  // Top-level nav rail (工作区/收件箱/项目/账号) starts hidden for more canvas
  // width; toggled from the AppBar, remembered across launches.
  bool _navRailHidden = Prefs.getBool('nav.railHidden', def: true);
  // Shared 会话总览 projection: WorkspacePage produces into it, SessionOverviewPage
  // renders from it. Owned here so the two sibling pages share one instance.
  final SessionOverviewStore _overviewStore = SessionOverviewStore();
  // Backs the 待办 top-level page. Owned here (not by TodosPage) so it can
  // start loading via _bootstrap before the page ever builds — see start()'s
  // doc comment in local/todo_store.dart.
  final TodoStore _todoStore = TodoStore();
  bool _checkedUpdate = false; // one-shot on-launch update check guard
  int _bootstrapGeneration = 0;

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  bool get _loggedIn =>
      _client != null &&
      (_cfg?.relayUrl ?? '').isNotEmpty &&
      (_cfg?.token ?? '').isNotEmpty;
  String? get _initialRelayUrl {
    final relay = _cfg?.relayUrl ?? '';
    return relay.isNotEmpty ? relay : _relayHint;
  }

  AppConfig _configWithSession(AppConfig? cfg, Session session) => AppConfig(
    session.relayUrl,
    session.token,
    session.identity,
    cfg?.repos ?? const {},
    cfg?.workspaces ?? const [],
    cfg?.agent ?? '',
    cfg?.workspaceRoot ?? '',
    cfg?.gradeCommand ?? '',
    cfg?.linearToken ?? '',
    cfg?.githubToken ?? '',
    cfg?.terminalApp ?? '',
    cfg?.claudeCommand ?? '',
    cfg?.codexCommand ?? '',
    cfg?.publishSessions ?? false,
  );

  Future<void> _reloadLocalConfig() async {
    final cfg = await AppConfig.load();
    if (!mounted || cfg == null) return;
    final current = _cfg;
    if (current == null || !_loggedIn) {
      setState(() => _cfg = cfg);
      return;
    }
    final session = Session(
      relayUrl: current.relayUrl,
      token: current.token,
      identity: current.identity,
    );
    setState(() => _cfg = _configWithSession(cfg, session));
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    final generation = ++_bootstrapGeneration;
    setState(() {
      _loading = true;
      _needLogin = false;
    });
    final cfg =
        await AppConfig.load(); // config.toml: auth + repos, or null (mobile)
    final stored = await SessionStore.load(); // explicit login, or null
    // After an explicit logout, don't silently re-auth from config.toml — wait
    // for a real login (which clears the flag). Only matters when there's no
    // stored session; a stored session always wins.
    final loggedOut = stored == null && await SessionStore.isLoggedOut();

    final session =
        stored ??
        (cfg != null &&
                !loggedOut &&
                cfg.relayUrl.isNotEmpty &&
                cfg.token.isNotEmpty
            ? Session(
                relayUrl: cfg.relayUrl,
                token: cfg.token,
                identity: cfg.identity,
              )
            : null);

    if (session == null) {
      if (!_isCurrentBootstrap(generation)) return;
      await _todoStore.stop();
      if (!_isCurrentBootstrap(generation)) return;
      final localCfg = cfg ?? AppConfig('', '', '', const {});
      setState(() {
        _cfg = localCfg;
        _client = null;
        _me = null;
        _meDegraded = false;
        _loading = false;
        _needLogin = !_isDesktop;
        _relayHint = cfg?.relayUrl;
      });
      return;
    }

    final client = RelayClient(session.relayUrl, session.token);
    Me? me;
    try {
      me = await client.me();
    } catch (_) {
      // older relay / transient — treat as non-admin member
    }
    if (!_isCurrentBootstrap(generation)) return;
    final activeCfg = _configWithSession(cfg, session);
    setState(() {
      _cfg = activeCfg;
      _client = client;
      // /v1/me can fail transiently (relay 502 / timeout / offline). Fall back
      // to a non-admin member identity so the local workspace still renders —
      // build() force-unwraps _me!, and a null here used to grey-screen the
      // whole window. _meDegraded surfaces a reconnect banner instead.
      _me = me ?? Me.member(session.identity);
      _meDegraded = me == null;
      _relayHint = session.relayUrl;
      _loading = false;
    });
    // Started here (not just from _onLoggedIn) so a relaunch that restores a
    // stored session also loads todos, not only a fresh interactive login.
    // Skipped when `me` came back null (older relay / transient /me failure
    // above) since TodoStore.start requires a non-null Me.
    if (me != null) {
      if (!_isCurrentBootstrap(generation)) return;
      await _todoStore.start(client: client, me: me, config: activeCfg);
    }
  }

  bool _isCurrentBootstrap(int generation) =>
      mounted && generation == _bootstrapGeneration;

  Future<void> _onLoggedIn(Session s) async {
    await SessionStore.save(s);
    // Also write the global config.toml so the bundled/installed cc-handoff CLI
    // (which the app shells out to for workspace/worktree/pickup ops) is
    // authenticated — a freshly-registered user otherwise has no config and the
    // CLI fails. Best-effort: never block login on it.
    try {
      await AppConfig.saveAuth(s.relayUrl, s.token, s.identity);
    } catch (_) {}
    await _bootstrap();
  }

  Future<void> _switchAccount() async {
    final currentRelay = _initialRelayUrl;
    final currentIdentity = _cfg?.identity;
    final accounts = await SessionStore.accounts();
    if (!mounted) return;
    final action = await showDialog<Object>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('切换账号'),
        children: [
          for (final a in accounts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, a),
              child: Row(
                children: [
                  Icon(
                    savedAccountMatchesSession(
                          a,
                          relayUrl: currentRelay,
                          identity: currentIdentity,
                        )
                        ? Icons.check_circle_rounded
                        : Icons.account_circle_rounded,
                    size: 20,
                    color:
                        savedAccountMatchesSession(
                          a,
                          relayUrl: currentRelay,
                          identity: currentIdentity,
                        )
                        ? CcColors.accent
                        : CcColors.muted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.identity,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          hostOf(a.relayUrl),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: CcColors.subtle,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'add'),
            child: const Row(
              children: [
                Icon(Icons.add_rounded, size: 20),
                SizedBox(width: 10),
                Text('添加账号'),
              ],
            ),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action is SavedAccount) {
      await _onLoggedIn(action.toSession());
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          initialRelayUrl: currentRelay,
          showCancel: true,
          onLoggedIn: (s) async {
            await _onLoggedIn(s);
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  Future<void> _logout() async {
    _bootstrapGeneration++;
    // Switch to the login screen immediately so the button always responds,
    // even if the secure-store writes below are slow or throw.
    if (mounted) {
      unawaited(_todoStore.stop());
      final localCfg = _cfg == null
          ? AppConfig('', '', '', const {})
          : AppConfig(
              '',
              '',
              '',
              _cfg!.repos,
              _cfg!.workspaces,
              _cfg!.agent,
              _cfg!.workspaceRoot,
              _cfg!.gradeCommand,
              _cfg!.linearToken,
              _cfg!.githubToken,
              _cfg!.terminalApp,
              _cfg!.claudeCommand,
              _cfg!.codexCommand,
              _cfg!.publishSessions,
            );
      setState(() {
        _client = null;
        _cfg = localCfg;
        _me = null;
        _meDegraded = false;
        _index = 0;
        _needLogin = !_isDesktop;
      });
    }
    // Best-effort: drop the stored session and record the explicit logout so
    // _bootstrap won't re-auth from config.toml on the next launch.
    try {
      await SessionStore.clear();
      await SessionStore.markLoggedOut();
    } catch (_) {}
  }

  Future<void> _showLogin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          initialRelayUrl: _initialRelayUrl,
          showCancel: true,
          onLoggedIn: (s) async {
            await _onLoggedIn(s);
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  // _openSessionInWorkspace is invoked from the 会话总览 cards: switch to the
  // 工作区 (desktop index 0) and ask WorkspacePage (via the shared store) to
  // reopen + focus that session's tab.
  void _openSessionInWorkspace(String sid) {
    setState(() => _index = 0);
    _overviewStore.requestOpen(sid);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_needLogin) {
      return LoginScreen(initialRelayUrl: _relayHint, onLoggedIn: _onLoggedIn);
    }
    if (_cfg == null) {
      return const Scaffold(body: Center(child: Text('初始化失败')));
    }

    // Once per launch (after we're past login), quietly check GitHub Releases for
    // a newer build and prompt to download/install. Post-frame so context has a
    // Navigator/Messenger; silent so it says nothing when already current.
    if (!_checkedUpdate) {
      _checkedUpdate = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) checkForUpdatesUi(context, silent: true);
      });
    }

    final isAdmin = _me?.isAdmin ?? false;
    // 工作区 (project-centric cockpit) is desktop-only — it needs local fs +
    // terminals. Both lists share the same `if (_isDesktop)` so they align.
    final dests = <_Dest>[
      if (_isDesktop)
        const _Dest('工作区', Icons.workspaces_rounded, Icons.workspaces_rounded),
      if (_isDesktop)
        const _Dest('会话总览', Icons.grid_view_rounded, Icons.grid_view_rounded),
      if (!_isDesktop)
        const _Dest('远程', Icons.cast_rounded, Icons.cast_connected_rounded),
      const _Dest('收件箱', Icons.inbox_rounded, Icons.inbox_rounded),
      const _Dest('广场', Icons.storefront_rounded, Icons.storefront_rounded),
      const _Dest('待办', Icons.checklist_rounded, Icons.checklist_rounded),
      const _Dest('项目', Icons.folder_rounded, Icons.folder_rounded),
      const _Dest('账号', Icons.person_rounded, Icons.person_rounded),
      if (isAdmin)
        const _Dest('Admin', Icons.shield_rounded, Icons.shield_rounded),
    ];
    if (_index >= dests.length) _index = 0;

    final pages = <Widget>[
      if (_isDesktop)
        WorkspacePage(
          client: _client,
          config: _cfg!,
          overviewStore: _overviewStore,
          me: _me,
          store: _todoStore,
        ),
      // 会话总览 sits right after 工作区 on desktop (index 1) — keep in sync with
      // _openSessionInWorkspace, which switches back to index 0 to focus a tab.
      if (_isDesktop)
        SessionOverviewPage(
          store: _overviewStore,
          onOpenSession: _openSessionInWorkspace,
          active: _index == 1,
        ),
      if (!_isDesktop)
        RemoteWorkspacePage(relayUrl: _cfg!.relayUrl, token: _cfg!.token),
      _loggedIn
          ? HandoffsPage(
              client: _client!,
              config: _cfg!,
              me: _me,
              showTerminal: _isDesktop,
            )
          : _loginRequiredPage('收件箱'),
      _loggedIn
          ? CapsulePlazaPage(
              client: _client!,
              identity: _cfg!.identity,
              overviewStore: _overviewStore,
              config: _cfg!,
              isDesktop: _isDesktop,
            )
          : _loginRequiredPage('广场'),
      _loggedIn
          ? TodosPage(
              client: _client!,
              config: _cfg!,
              me: _me!,
              store: _todoStore,
              overviewStore: _overviewStore,
              onOpenSession: _isDesktop ? _openSessionInWorkspace : null,
            )
          : _loginRequiredPage('待办'),
      _loggedIn ? ProjectsPage(client: _client!) : _loginRequiredPage('项目'),
      _loggedIn
          ? AccountPage(
              client: _client!,
              identity: _cfg!.identity,
              onSwitchAccount: _switchAccount,
              onConfigSaved: () =>
                  unawaited(_reloadLocalConfig().catchError((_) {})),
            )
          : _loginRequiredPage('账号'),
      if (isAdmin) AdminPage(client: _client!),
    ];
    // dests and pages are built with matching `if (_isDesktop)` / `if (isAdmin)`
    // guards; keep them index-aligned for IndexedStack + the nav rail.
    assert(dests.length == pages.length, 'nav dests/pages must align');
    Widget body = IndexedStack(index: _index, children: pages);
    // When /v1/me failed at launch (_meDegraded), sit a reconnect banner above
    // the pages so the user knows relay-backed views are empty on purpose.
    if (_meDegraded) {
      body = Column(
        children: [
          _degradedBar(),
          Expanded(child: body),
        ],
      );
    } else if (!_loggedIn && _isDesktop) {
      body = Column(
        children: [
          _localOnlyBar(),
          Expanded(child: body),
        ],
      );
    }

    if (_isDesktop) {
      return Scaffold(
        appBar: _appBar(),
        body: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  if (!_navRailHidden) ...[
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelType: NavigationRailLabelType.all,
                      backgroundColor: CcColors.panel,
                      minWidth: 84,
                      groupAlignment: -0.9,
                      destinations: dests
                          .map(
                            (d) => NavigationRailDestination(
                              icon: Icon(d.icon),
                              selectedIcon: Icon(d.selected),
                              label: Text(d.label),
                            ),
                          )
                          .toList(),
                    ),
                    const VerticalDivider(width: 1),
                  ],
                  Expanded(
                    child: DecoratedBox(decoration: appGradient, child: body),
                  ),
                ],
              ),
            ),
            _statusBar(dests),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: _appBar(),
      body: DecoratedBox(decoration: appGradient, child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: dests
            .map(
              (d) => NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selected),
                label: d.label,
              ),
            )
            .toList(),
      ),
    );
  }

  // Shown at the top of the shell when /v1/me failed at launch and _me is a
  // fallback member identity. Local workspace works; relay-backed views (待办/
  // 团队/Admin) are empty until a successful reconnect. Tapping re-runs
  // _bootstrap — once /v1/me returns, TodoStore.start fires and it clears.
  Widget _degradedBar() {
    // Amber warning strip, aligned with _statusBanner in remote_workspace_page:
    // CcColors.warning at 0.14 for the fill, solid warning for text/icons.
    return Material(
      color: CcColors.warning.withValues(alpha: 0.14),
      child: InkWell(
        onTap: _bootstrap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, size: 15, color: CcColors.warning),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '未连接 relay,部分功能暂不可用(本地工作区正常)',
                  style: TextStyle(color: CcColors.warning, fontSize: 12),
                ),
              ),
              SizedBox(width: 8),
              Text(
                '重试',
                style: TextStyle(
                  color: CcColors.warning,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: 3),
              Icon(Icons.refresh_rounded, size: 15, color: CcColors.warning),
            ],
          ),
        ),
      ),
    );
  }

  Widget _localOnlyBar() => Material(
    color: CcColors.panel,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.lock_open_rounded, size: 15, color: CcColors.muted),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '本地模式: 工作区和会话总览可用,收件箱/广场/待办等 relay 功能需要登录',
              style: TextStyle(color: CcColors.muted, fontSize: 12),
            ),
          ),
          TextButton.icon(
            onPressed: _showLogin,
            icon: const Icon(Icons.login_rounded, size: 15),
            label: const Text('登录'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _loginRequiredPage(String feature) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_sync_rounded, size: 36, color: CcColors.muted),
          const SizedBox(height: 12),
          Text(
            '$feature 需要登录 relay',
            style: const TextStyle(
              color: CcColors.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '本地工作区可以继续使用。登录后会自动启用同步、团队和广场功能。',
            textAlign: TextAlign.center,
            style: TextStyle(color: CcColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _showLogin,
            icon: const Icon(Icons.login_rounded, size: 18),
            label: const Text('登录账号'),
          ),
        ],
      ),
    ),
  );

  // _statusBar is a tmux/vim-style footer (desktop): host · identity on the
  // left, the active view as a "mode" on the right. Mono, terminal feel.
  Widget _statusBar(List<_Dest> dests) {
    final page = dests[_index.clamp(0, dests.length - 1)].label;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(top: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          Text('❯', style: CcType.code(size: 12, color: CcColors.ok)),
          const SizedBox(width: 6),
          Text(
            _loggedIn ? hostOf(_cfg!.relayUrl) : 'local',
            style: CcType.code(size: 11.5, color: CcColors.muted),
          ),
          Text('  ·  ', style: CcType.code(size: 11.5, color: CcColors.subtle)),
          Text(
            _loggedIn ? _cfg!.identity : '未登录',
            style: CcType.code(size: 11.5, color: CcColors.muted),
          ),
          const Spacer(),
          statusDot(
            _loggedIn ? CcColors.ok : CcColors.muted,
            size: 6,
            glow: _loggedIn,
          ),
          const SizedBox(width: 6),
          Text(
            page,
            style: CcType.code(
              size: 11,
              color: CcColors.subtle,
              weight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _appBar() => AppBar(
    leading: _isDesktop
        ? IconButton(
            tooltip: _navRailHidden ? '显示导航' : '隐藏导航',
            icon: Icon(
              _navRailHidden ? Icons.menu_rounded : Icons.menu_open_rounded,
            ),
            onPressed: () => setState(() {
              _navRailHidden = !_navRailHidden;
              Prefs.setBool('nav.railHidden', _navRailHidden);
            }),
          )
        : null,
    titleSpacing: 16,
    title: Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: CcColors.accent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: CcColors.accent.withValues(alpha: 0.45),
                blurRadius: 8,
              ),
            ],
          ),
          child: const Icon(
            Icons.sync_alt_rounded,
            size: 13,
            color: CcColors.bg,
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'cc-handoff',
          style: TextStyle(
            color: CcColors.text,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            _loggedIn
                ? '${hostOf(_cfg!.relayUrl)} · ${_cfg!.identity}'
                : '本地模式 · 未登录',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: CcType.mono,
              color: CcColors.muted,
              fontSize: 12,
            ),
          ),
        ),
      ],
    ),
    actions: [
      PopupMenuButton<String>(
        tooltip: '账号',
        icon: const Icon(Icons.account_circle_rounded),
        onSelected: (v) {
          if (v == 'login') _showLogin();
          if (v == 'switch') _switchAccount();
          if (v == 'logout') _logout();
        },
        itemBuilder: (_) => _loggedIn
            ? [
                ccMenuItem(
                  value: 'switch',
                  icon: Icons.switch_account_rounded,
                  label: '切换账号',
                ),
                ccMenuItem(
                  value: 'logout',
                  icon: Icons.logout_rounded,
                  label: '登出',
                ),
              ]
            : [
                ccMenuItem(
                  value: 'login',
                  icon: Icons.login_rounded,
                  label: '登录账号',
                ),
              ],
      ),
      const SizedBox(width: 4),
    ],
  );
}

class _Dest {
  final String label;
  final IconData icon;
  final IconData selected;
  const _Dest(this.label, this.icon, this.selected);
}
