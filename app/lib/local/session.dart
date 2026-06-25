import 'session_kv.dart';

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

// SessionStore persists a logged-in session via a per-platform key-value backend
// (OS secure store on desktop/mobile, browser localStorage on web — see
// session_kv.dart), so a client with no config.toml stays logged in.
class SessionStore {
  static Future<Session?> load() async {
    final url = await kvRead('relay_url');
    final token = await kvRead('token');
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return Session(
      relayUrl: url,
      token: token,
      identity: await kvRead('identity') ?? '',
      isAdmin: (await kvRead('is_admin')) == 'true',
    );
  }

  static Future<void> save(Session s) async {
    await kvWrite('relay_url', s.relayUrl);
    await kvWrite('token', s.token);
    await kvWrite('identity', s.identity);
    await kvWrite('is_admin', s.isAdmin.toString());
  }

  static Future<void> clear() async {
    for (final k in ['relay_url', 'token', 'identity', 'is_admin']) {
      await kvDelete(k);
    }
  }
}
