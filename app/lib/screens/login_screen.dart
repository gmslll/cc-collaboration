import 'package:flutter/material.dart';

import '../api/relay_client.dart';
import '../brand.dart';
import '../local/session.dart';
import '../theme.dart';
import '../widgets.dart';

String loginModeTitle(bool isRegisterMode) => isRegisterMode ? '注册新账号' : '登录';

String loginModeSubtitle(bool isRegisterMode) =>
    isRegisterMode ? '注册后可通过邀请加入团队或项目' : AppBrand.chineseTagline;

String loginModeSwitchLabel(bool isRegisterMode) =>
    isRegisterMode ? '已有账号?去登录' : '没有账号?去注册';

class LoginScreen extends StatefulWidget {
  final String? initialRelayUrl;
  final String? initialIdentity;
  final bool showCancel;
  final Future<void> Function(Session) onLoggedIn;
  const LoginScreen({
    super.key,
    this.initialRelayUrl,
    this.initialIdentity,
    this.showCancel = false,
    required this.onLoggedIn,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final _relay = TextEditingController(text: widget.initialRelayUrl ?? '');
  late final _identity = TextEditingController(
    text: widget.initialIdentity ?? '',
  );
  final _password = TextEditingController();
  bool _busy = false;
  bool _isRegisterMode = false;
  List<SavedAccount> _accounts = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final accounts = await SessionStore.accounts();
    if (mounted) setState(() => _accounts = accounts);
  }

  @override
  void dispose() {
    _relay.dispose();
    _identity.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final url = _relay.text.trim();
    final id = _identity.text.trim();
    if (url.isEmpty || id.isEmpty || _password.text.isEmpty) {
      setState(() => _error = '请填写企业 relay 地址、identity、密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = _isRegisterMode
          ? await register(url, id, _password.text)
          : await login(url, id, _password.text);
      await widget.onLoggedIn(
        Session(
          relayUrl: url,
          token: res.token,
          identity: res.identity,
          isAdmin: res.isAdmin,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '${_isRegisterMode ? '注册' : '登录'}失败:$e';
      });
    }
  }

  Future<void> _useSaved(SavedAccount account) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onLoggedIn(account.toSession());
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '切换失败:$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: appGradient,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight > 48
                      ? constraints.maxHeight - 48
                      : 0,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(26),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: CcColors.accent,
                                  borderRadius: BorderRadius.circular(14),
                                  boxShadow: [
                                    BoxShadow(
                                      color: CcColors.accent.withValues(
                                        alpha: 0.5,
                                      ),
                                      blurRadius: 18,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.sync_alt_rounded,
                                  size: 26,
                                  color: CcColors.bg,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              AppBrand.productName,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0,
                                color: CcColors.text,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              loginModeTitle(_isRegisterMode),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: CcColors.muted),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              loginModeSubtitle(_isRegisterMode),
                              textAlign: TextAlign.center,
                              style: CcType.code(
                                size: 11.5,
                                color: CcColors.subtle,
                              ),
                            ),
                            if (_accounts.isNotEmpty && !_isRegisterMode) ...[
                              const SizedBox(height: 16),
                              for (final account in _accounts.take(4))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: OutlinedButton.icon(
                                    onPressed: _busy
                                        ? null
                                        : () => _useSaved(account),
                                    icon: const Icon(
                                      Icons.account_circle_rounded,
                                      size: 18,
                                    ),
                                    label: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        '${account.identity} · ${_hostOf(account.relayUrl)}',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 4),
                              const Divider(),
                            ],
                            const SizedBox(height: 20),
                            TextField(
                              controller: _relay,
                              autocorrect: false,
                              keyboardType: TextInputType.url,
                              decoration: const InputDecoration(
                                labelText: '企业 relay 地址',
                                hintText: 'https://relay.example.com',
                                prefixIcon: Icon(Icons.dns_rounded),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _identity,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'identity',
                                hintText: 'you@backend',
                                prefixIcon: Icon(Icons.badge_rounded),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _password,
                              obscureText: true,
                              onSubmitted: (_) => _busy ? null : _submit(),
                              decoration: const InputDecoration(
                                labelText: '密码',
                                prefixIcon: Icon(Icons.lock_rounded),
                                isDense: true,
                              ),
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: CcColors.danger.withValues(
                                    alpha: 0.10,
                                  ),
                                  border: Border.all(
                                    color: CcColors.danger.withValues(
                                      alpha: 0.28,
                                    ),
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                    color: CcColors.danger,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                            if (_isRegisterMode) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: CcColors.accent.withValues(
                                    alpha: 0.08,
                                  ),
                                  border: Border.all(
                                    color: CcColors.accent.withValues(
                                      alpha: 0.22,
                                    ),
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.groups_rounded,
                                      size: 16,
                                      color: CcColors.accent,
                                    ),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '注册后默认不创建团队。你可以接受团队或项目邀请，也可以在「团队」里新建自己的团队。',
                                        style: TextStyle(
                                          color: CcColors.muted,
                                          fontSize: 12.5,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            FilledButton.icon(
                              onPressed: _busy ? null : _submit,
                              icon: _busy
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      _isRegisterMode
                                          ? Icons.person_add_alt_1_rounded
                                          : Icons.arrow_forward_rounded,
                                      size: 18,
                                    ),
                              label: Text(
                                _busy
                                    ? (_isRegisterMode ? '注册中' : '登录中')
                                    : (_isRegisterMode ? '注册' : '登录'),
                              ),
                            ),
                            const SizedBox(height: 4),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                      _isRegisterMode = !_isRegisterMode;
                                      _error = null;
                                    }),
                              child: Text(
                                loginModeSwitchLabel(_isRegisterMode),
                              ),
                            ),
                            if (widget.showCancel) ...[
                              const SizedBox(height: 2),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => Navigator.pop(context),
                                child: const Text('取消'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _hostOf(String url) {
  try {
    return Uri.parse(url).host;
  } catch (_) {
    return url;
  }
}
