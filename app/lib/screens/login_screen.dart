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
              padding: const EdgeInsets.all(26),
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
                        prefixIcon: Icon(Icons.dns_outlined),
                        isDense: true),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _identity,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'identity',
                        hintText: 'you@backend',
                        prefixIcon: Icon(Icons.badge_outlined),
                        isDense: true),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    onSubmitted: (_) => _busy ? null : _submit(),
                    decoration: const InputDecoration(
                        labelText: '密码',
                        prefixIcon: Icon(Icons.lock_outline),
                        isDense: true),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: CcColors.danger.withValues(alpha: 0.10),
                        border: Border.all(
                            color: CcColors.danger.withValues(alpha: 0.28)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!,
                          style: const TextStyle(
                              color: CcColors.danger, fontSize: 13)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    icon: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.arrow_forward, size: 18),
                    label: Text(_busy ? '登录中' : '登录'),
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
