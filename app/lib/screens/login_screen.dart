import 'package:flutter/material.dart';

import '../api/relay_client.dart';
import '../local/session.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  final String? initialRelayUrl;
  final Future<void> Function(Session) onLoggedIn;
  const LoginScreen({super.key, this.initialRelayUrl, required this.onLoggedIn});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final _relay = TextEditingController(text: widget.initialRelayUrl ?? '');
  final _identity = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _relay.dispose();
    _identity.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _relay.text.trim();
    final id = _identity.text.trim();
    if (url.isEmpty || id.isEmpty || _password.text.isEmpty) {
      setState(() => _error = '请填写 relay 地址、identity、密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await login(url, id, _password.text);
      await widget.onLoggedIn(Session(
        relayUrl: url,
        token: res.token,
        identity: res.identity,
        isAdmin: res.isAdmin,
      ));
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '登录失败:$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('cc-handoff',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: CcColors.accent)),
                  const SizedBox(height: 4),
                  const Text('登录',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: CcColors.muted)),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _relay,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                        labelText: 'relay 地址',
                        hintText: 'https://relay.example.com',
                        isDense: true),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _identity,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'identity(如 you@backend)', isDense: true),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    onSubmitted: (_) => _busy ? null : _submit(),
                    decoration:
                        const InputDecoration(labelText: '密码', isDense: true),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: const TextStyle(color: CcColors.danger, fontSize: 13)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('登录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
