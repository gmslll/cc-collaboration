import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Session is the active relay auth: where + who + token. It comes from an
// explicit login (stored securely) or, on desktop, from ~/.config/cc-handoff.
class Session {
  final String relayUrl;
  final String token;
  final String identity;
  final bool isAdmin;

  Session({
    required this.relayUrl,
    required this.token,
    required this.identity,
    this.isAdmin = false,
  });

  Session copyWith({bool? isAdmin}) => Session(
        relayUrl: relayUrl,
        token: token,
        identity: identity,
        isAdmin: isAdmin ?? this.isAdmin,
      );
}

// SessionStore persists a logged-in session in the platform secure store
// (Keychain / Keystore), so mobile (no config.toml) stays logged in.
class SessionStore {
  static const _s = FlutterSecureStorage();

  static Future<Session?> load() async {
    final url = await _s.read(key: 'relay_url');
    final token = await _s.read(key: 'token');
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return Session(
      relayUrl: url,
      token: token,
      identity: await _s.read(key: 'identity') ?? '',
      isAdmin: (await _s.read(key: 'is_admin')) == 'true',
    );
  }

  static Future<void> save(Session s) async {
    await _s.write(key: 'relay_url', value: s.relayUrl);
    await _s.write(key: 'token', value: s.token);
    await _s.write(key: 'identity', value: s.identity);
    await _s.write(key: 'is_admin', value: s.isAdmin.toString());
  }

  static Future<void> clear() async {
    for (final k in ['relay_url', 'token', 'identity', 'is_admin']) {
      await _s.delete(key: k);
    }
  }
}
