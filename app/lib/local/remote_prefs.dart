import '../remote/pty_transport.dart';
import 'prefs.dart';

const String kRemoteShowSessionContentPref = 'remote.showSessionContent';
const bool kRemoteShowSessionContentDefault = false;

const String kRemotePtyTransportModePref = 'remote.ptyTransportMode';

PtyTransportMode loadRemotePtyTransportMode() =>
    PtyTransportMode.fromWire(
      Prefs.getString(kRemotePtyTransportModePref, def: 'auto'),
    ) ??
    PtyTransportMode.auto;

void saveRemotePtyTransportMode(PtyTransportMode mode) =>
    Prefs.setString(kRemotePtyTransportModePref, mode.wireName);
