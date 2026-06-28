import 'package:flutter/material.dart';

import 'local/session.dart';
import 'notifications.dart';
import 'screens/login_screen.dart';
import 'screens/remote_workspace_page.dart';
import 'theme.dart';

// Flutter Web entrypoint: the browser version of the phone's remote workspace.
// Build with `flutter build web -t lib/main_web.dart --base-href /app/`; the
// relay serves the bundle at /app/ (same origin → no CORS).
//
// It deliberately imports ONLY the client path (login + RemoteWorkspacePage) —
// never workspace_page / handoffs_page / config — so no dart:io or native plugin
// reaches the web build. (main.dart is the native entrypoint and is never
// compiled for web.)
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Notifications.init(); // graceful no-op on web
  runApp(const CcWebApp());
}

class CcWebApp extends StatelessWidget {
  const CcWebApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'cc-handoff web',
    debugShowCheckedModeBanner: false,
    theme: ccTheme(),
    home: const WebShell(),
  );
}

// WebShell resolves auth from the secure store (works on web via localStorage),
// shows the login screen if absent, else the remote workspace. Login defaults
// the relay URL to this page's origin since the bundle is served by the relay.
class WebShell extends StatefulWidget {
  const WebShell({super.key});

  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  Session? _session;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final s = await SessionStore.load();
    if (!mounted) return;
    setState(() {
      _session = s;
      _loading = false;
    });
  }

  Future<void> _onLoggedIn(Session s) async {
    await SessionStore.save(s);
    if (!mounted) return;
    setState(() => _session = s);
  }

  Future<void> _switchAccount() async {
    final current = _session;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          initialRelayUrl: current?.relayUrl ?? Uri.base.origin,
          initialIdentity: current?.identity,
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
    await SessionStore.clear();
    if (!mounted) return;
    setState(() => _session = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final s = _session;
    if (s == null) {
      return LoginScreen(
        initialRelayUrl: Uri.base.origin,
        onLoggedIn: _onLoggedIn,
      );
    }
    return RemoteWorkspacePage(
      relayUrl: s.relayUrl,
      token: s.token,
      onSwitchAccount: _switchAccount,
      onLogout: _logout,
    );
  }
}
