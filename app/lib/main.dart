import 'dart:io';

import 'package:flutter/material.dart';

import 'api/models.dart';
import 'api/relay_client.dart';
import 'local/config.dart';
import 'local/session.dart';
import 'notifications.dart';
import 'screens/account_page.dart';
import 'screens/admin_page.dart';
import 'screens/handoffs_page.dart';
import 'screens/login_screen.dart';
import 'screens/projects_page.dart';
import 'screens/workspace_page.dart';
import 'theme.dart';
import 'widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Notifications.init();
  runApp(const CcApp());
}

class CcApp extends StatelessWidget {
  const CcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cc-handoff',
      debugShowCheckedModeBanner: false,
      theme: ccTheme(),
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
  AppConfig? _cfg; // active auth (from session) + repos (from config.toml, if any)
  RelayClient? _client;
  Me? _me;
  bool _loading = true;
  bool _needLogin = false;
  String? _relayHint;
  int _index = 0;

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
    final cfg = await AppConfig.load(); // config.toml: auth + repos, or null (mobile)
    final stored = await SessionStore.load(); // explicit login, or null

    final session = stored ??
        (cfg != null
            ? Session(
                relayUrl: cfg.relayUrl, token: cfg.token, identity: cfg.identity)
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
      _cfg = AppConfig(session.relayUrl, session.token, session.identity,
          cfg?.repos ?? const {}, cfg?.workspaces ?? const []);
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
    await SessionStore.clear();
    if (!mounted) return;
    setState(() {
      _client = null;
      _cfg = null;
      _me = null;
      _index = 0;
      _needLogin = true;
    });
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
        const _Dest('工作区', Icons.workspaces_outline, Icons.workspaces),
      const _Dest('收件箱', Icons.inbox_outlined, Icons.inbox),
      const _Dest('项目', Icons.folder_outlined, Icons.folder),
      const _Dest('账号', Icons.person_outline, Icons.person),
      if (isAdmin) const _Dest('Admin', Icons.shield_outlined, Icons.shield),
    ];
    if (_index >= dests.length) _index = 0;

    final pages = <Widget>[
      if (_isDesktop) WorkspacePage(client: _client!, config: _cfg!),
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
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            backgroundColor: CcColors.panel,
            destinations: dests
                .map((d) => NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label)))
                .toList(),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: DecoratedBox(decoration: appGradient, child: body)),
        ]),
      );
    }

    return Scaffold(
      appBar: _appBar(),
      body: DecoratedBox(decoration: appGradient, child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: dests
            .map((d) => NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selected),
                label: d.label))
            .toList(),
      ),
    );
  }

  PreferredSizeWidget _appBar() => AppBar(
        titleSpacing: 16,
        title: Row(children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: CcColors.accent,
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                    color: CcColors.accent.withValues(alpha: 0.45),
                    blurRadius: 8)
              ],
            ),
            child: const Icon(Icons.sync_alt, size: 13, color: CcColors.bg),
          ),
          const SizedBox(width: 10),
          const Text('cc-handoff',
              style: TextStyle(
                  color: CcColors.text,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2)),
          const SizedBox(width: 12),
          Flexible(
            child: Text('${hostOf(_cfg!.relayUrl)} · ${_cfg!.identity}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: CcType.mono,
                    color: CcColors.muted,
                    fontSize: 12)),
          ),
        ]),
        actions: [
          PopupMenuButton<String>(
            tooltip: '账号',
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (v) {
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout, size: 16),
                  SizedBox(width: 8),
                  Text('登出'),
                ]),
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
