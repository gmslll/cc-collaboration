import 'package:app/local/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saved account matching normalizes identity but not relay url', () {
    const account = SavedAccount(
      relayUrl: 'https://relay.example.test',
      token: 'tok',
      identity: ' Me@X ',
    );

    expect(
      savedAccountMatchesSession(
        account,
        relayUrl: 'https://relay.example.test',
        identity: 'me@x',
      ),
      isTrue,
    );
    expect(
      savedAccountMatchesSession(
        account,
        relayUrl: 'https://other.example.test',
        identity: 'me@x',
      ),
      isFalse,
    );
    expect(
      savedAccountMatchesSession(
        account,
        relayUrl: 'https://relay.example.test',
        identity: 'other@x',
      ),
      isFalse,
    );
  });
}
