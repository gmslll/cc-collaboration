import 'dart:convert';

import 'identity.dart';
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

class SavedAccount {
  final String relayUrl;
  final String token;
  final String identity;
  final bool isAdmin;

  const SavedAccount({
    required this.relayUrl,
    required this.token,
    required this.identity,
    this.isAdmin = false,
  });

  Session toSession() => Session(
    relayUrl: relayUrl,
    token: token,
    identity: identity,
    isAdmin: isAdmin,
  );

  Map<String, dynamic> toJson() => {
    'relay_url': relayUrl,
    'token': token,
    'identity': identity,
    'is_admin': isAdmin,
  };

  static SavedAccount? fromJson(Object? v) {
    if (v is! Map) return null;
    final relayUrl = (v['relay_url'] ?? '').toString();
    final token = (v['token'] ?? '').toString();
    final identity = (v['identity'] ?? '').toString();
    if (relayUrl.isEmpty || token.isEmpty || identity.isEmpty) return null;
    return SavedAccount(
      relayUrl: relayUrl,
      token: token,
      identity: identity,
      isAdmin: v['is_admin'] == true || v['is_admin'] == 'true',
    );
  }
}

bool savedAccountMatchesSession(
  SavedAccount account, {
  required String? relayUrl,
  required String? identity,
}) =>
    account.relayUrl == (relayUrl ?? '') &&
    sameIdentity(account.identity, identity ?? '');

// SessionStore persists a logged-in session via a per-platform key-value backend
// (OS secure store on desktop/mobile, browser localStorage on web — see
// session_kv.dart), so a client with no config.toml stays logged in.
class SessionStore {
  static const _accountsKey = 'accounts';

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
    await _upsertAccount(s);
    // A fresh login cancels any prior explicit logout (see markLoggedOut).
    await kvDelete(_loggedOutKey);
  }

  static Future<void> clear() async {
    for (final k in ['relay_url', 'token', 'identity', 'is_admin']) {
      await kvDelete(k);
    }
  }

  static Future<List<SavedAccount>> accounts() async {
    final raw = await kvRead(_accountsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final accounts = <SavedAccount>[];
      for (final item in decoded) {
        final account = SavedAccount.fromJson(item);
        if (account != null) accounts.add(account);
      }
      return accounts;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _upsertAccount(Session s) async {
    final list = await accounts();
    final next = <SavedAccount>[
      SavedAccount(
        relayUrl: s.relayUrl,
        token: s.token,
        identity: s.identity,
        isAdmin: s.isAdmin,
      ),
      for (final a in list)
        if (!savedAccountMatchesSession(
          a,
          relayUrl: s.relayUrl,
          identity: s.identity,
        ))
          a,
    ];
    await kvWrite(
      _accountsKey,
      jsonEncode(next.map((a) => a.toJson()).toList()),
    );
  }

  // --- explicit-logout sentinel -------------------------------------------
  //
  // On desktop _bootstrap falls back to ~/.config/cc-handoff/config.toml when no
  // session is stored, so clearing the session alone isn't enough — the app
  // would silently re-authenticate from config.toml on the next launch, making
  // "登出" look like it did nothing. markLoggedOut records that the user logged
  // out on purpose; _bootstrap then skips the config.toml fallback until the next
  // real login (save() clears the flag).
  static const _loggedOutKey = 'logged_out';

  static Future<void> markLoggedOut() => kvWrite(_loggedOutKey, 'true');

  static Future<bool> isLoggedOut() async =>
      (await kvRead(_loggedOutKey)) == 'true';
}
