import 'dart:io';

import 'package:flutter/material.dart';

import 'api/models.dart';
import 'api/relay_client.dart';
import 'local/config.dart';
import 'screens/account_page.dart';
import 'screens/admin_page.dart';
import 'screens/handoffs_page.dart';
import 'screens/projects_page.dart';
import 'theme.dart';
import 'widgets.dart';

void main() => runApp(const CcApp());

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

// HomeShell loads the local config + relay client + identity, then hosts the
// pages behind a NavigationRail (desktop) / NavigationBar (mobile). The terminal
// cockpit is desktop-only; the management pages work on both.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppConfig? _cfg;
  RelayClient? _client;
  Me? _me;
  String? _error;
  bool _loading = true;
  int _index = 0;

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final cfg = await AppConfig.load();
    if (cfg == null) {
      setState(() {
        _loading = false;
        _error = '未配置 — 先运行 `cc-handoff init`(设置 relay_url + token)';
      });
      return;
    }
    final client = RelayClient(cfg.relayUrl, cfg.token);
    Me? me;
    try {
      me = await client.me();
    } catch (_) {
      // Older relay or transient error — treat as a non-admin member.
    }
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _client = client;
      _me = me;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _client == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error ?? '初始化失败',
                textAlign: TextAlign.center,
                style: const TextStyle(color: CcColors.muted)),
          ),
        ),
      );
    }

    final isAdmin = _me?.isAdmin ?? false;
    final dests = <_Dest>[
      const _Dest('收件箱', Icons.inbox_outlined, Icons.inbox),
      const _Dest('项目', Icons.folder_outlined, Icons.folder),
      const _Dest('账号', Icons.person_outline, Icons.person),
      if (isAdmin)
        const _Dest('Admin', Icons.shield_outlined, Icons.shield),
    ];
    if (_index >= dests.length) _index = 0;

    final pages = <Widget>[
      HandoffsPage(client: _client!, config: _cfg!, showTerminal: _isDesktop),
      ProjectsPage(client: _client!),
      AccountPage(client: _client!, identity: _cfg!.identity),
      if (isAdmin) AdminPage(client: _client!),
    ];
    // IndexedStack keeps every page (and the cockpit's SSE subscription) alive
    // across tab switches — no re-fetch / SSE reconnect on each switch.
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
          Expanded(child: body),
        ]),
      );
    }

    return Scaffold(
      appBar: _appBar(),
      body: body,
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
          const Text('cc-handoff',
              style: TextStyle(
                  color: CcColors.accent, fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          Flexible(
            child: Text('${hostOf(_cfg!.relayUrl)} · ${_cfg!.identity}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: CcColors.muted, fontSize: 12)),
          ),
        ]),
      );
}

class _Dest {
  final String label;
  final IconData icon;
  final IconData selected;
  const _Dest(this.label, this.icon, this.selected);
}
