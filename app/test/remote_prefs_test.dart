import 'package:app/local/prefs.dart';
import 'package:app/local/remote_prefs.dart';
import 'package:app/remote/pty_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('remote PTY transport preference persists all modes', () {
    addTearDown(() => Prefs.setString(kRemotePtyTransportModePref, 'auto'));

    for (final mode in PtyTransportMode.values) {
      saveRemotePtyTransportMode(mode);
      expect(loadRemotePtyTransportMode(), mode);
    }
  });

  test('unknown remote PTY transport preference falls back to automatic', () {
    addTearDown(() => Prefs.setString(kRemotePtyTransportModePref, 'auto'));
    Prefs.setString(kRemotePtyTransportModePref, 'future-mode');

    expect(loadRemotePtyTransportMode(), PtyTransportMode.auto);
  });
}
