import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/models.dart';
import 'api/relay_client.dart';
import 'local/config.dart';
import 'local/prefs.dart';
import 'local/session.dart';
import 'notifications.dart';
import 'screens/account_page.dart';
import 'screens/admin_page.dart';
import 'screens/handoffs_page.dart';
import 'screens/login_screen.dart';
import 'screens/projects_page.dart';
import 'screens/remote_workspace_page.dart';
import 'screens/workspace_page.dart';
import 'theme.dart';
import 'ui_scale.dart';
import 'widgets.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Prefs.load();
  Notifications.init();
  runApp(const CcApp());
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
  String? _relayHint;
  int _index = 0;
  // Top-level nav rail (工作区/收件箱/项目/账号) starts hidden for more canvas
  // width; toggled from the AppBar, remembered across launches.
  bool _navRailHidden = Prefs.getBool('nav.railHidden', def: true);

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
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
        (cfg != null && !loggedOut
            ? Session(
                relayUrl: cfg.relayUrl,
                token: cfg.token,
                identity: cfg.identity,
              )
            : null);

    if (session == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _needLogin = true;
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
    if (!mounted) return;
    setState(() {
      _cfg = AppConfig(
        session.relayUrl,
        session.token,
        session.identity,
        cfg?.repos ?? const {},
        cfg?.workspaces ?? const [],
      );
      _client = client;
      _me = me;
      _relayHint = session.relayUrl;
      _loading = false;
    });
  }

  Future<void> _onLoggedIn(Session s) async {
    await SessionStore.save(s);
    await _bootstrap();
  }

  Future<void> _logout() async {
    // Switch to the login screen immediately so the button always responds,
    // even if the secure-store writes below are slow or throw.
    if (mounted) {
      setState(() {
        _client = null;
        _cfg = null;
        _me = null;
        _index = 0;
        _needLogin = true;
      });
    }
    // Best-effort: drop the stored session and record the explicit logout so
    // _bootstrap won't re-auth from config.toml on the next launch.
    try {
      await SessionStore.clear();
      await SessionStore.markLoggedOut();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_needLogin) {
      return LoginScreen(initialRelayUrl: _relayHint, onLoggedIn: _onLoggedIn);
    }
    if (_client == null) {
      return const Scaffold(body: Center(child: Text('初始化失败')));
    }

    final isAdmin = _me?.isAdmin ?? false;
    // 工作区 (project-centric cockpit) is desktop-only — it needs local fs +
    // terminals. Both lists share the same `if (_isDesktop)` so they align.
    final dests = <_Dest>[
      if (_isDesktop)
        const _Dest('工作区', Icons.workspaces_rounded, Icons.workspaces_rounded),
      if (!_isDesktop)
        const _Dest('远程', Icons.cast_rounded, Icons.cast_connected_rounded),
      const _Dest('收件箱', Icons.inbox_rounded, Icons.inbox_rounded),
      const _Dest('项目', Icons.folder_rounded, Icons.folder_rounded),
      const _Dest('账号', Icons.person_rounded, Icons.person_rounded),
      if (isAdmin)
        const _Dest('Admin', Icons.shield_rounded, Icons.shield_rounded),
    ];
    if (_index >= dests.length) _index = 0;

    final pages = <Widget>[
      if (_isDesktop) WorkspacePage(client: _client!, config: _cfg!),
      if (!_isDesktop)
        RemoteWorkspacePage(relayUrl: _cfg!.relayUrl, token: _cfg!.token),
      HandoffsPage(client: _client!, config: _cfg!, showTerminal: _isDesktop),
      ProjectsPage(client: _client!),
      AccountPage(client: _client!, identity: _cfg!.identity),
      if (isAdmin) AdminPage(client: _client!),
    ];
    // dests and pages are built with matching `if (_isDesktop)` / `if (isAdmin)`
    // guards; keep them index-aligned for IndexedStack + the nav rail.
    assert(dests.length == pages.length, 'nav dests/pages must align');
    final body = IndexedStack(index: _index, children: pages);

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
            hostOf(_cfg!.relayUrl),
            style: CcType.code(size: 11.5, color: CcColors.muted),
          ),
          Text('  ·  ', style: CcType.code(size: 11.5, color: CcColors.subtle)),
          Text(
            _cfg!.identity,
            style: CcType.code(size: 11.5, color: CcColors.muted),
          ),
          const Spacer(),
          statusDot(CcColors.ok, size: 6, glow: true),
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
            '${hostOf(_cfg!.relayUrl)} · ${_cfg!.identity}',
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
          if (v == 'logout') _logout();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'logout',
            child: Row(
              children: [
                Icon(Icons.logout_rounded, size: 16),
                SizedBox(width: 8),
                Text('登出'),
              ],
            ),
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
