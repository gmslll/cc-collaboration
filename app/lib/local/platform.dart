import 'dart:io';

// Cross-platform path/home helpers. The desktop app was written POSIX-first
// (HOME, ~/.config); these mirror the Go CLI's platform handling so the app and
// the bundled cc-handoff binary agree on where config/state live — notably on
// Windows, where there is no $HOME and config belongs under %AppData%.

/// homeDir resolves the user's home directory. Windows has no HOME by default —
/// it uses USERPROFILE — so fall back to it. Mirrors Go's os.UserHomeDir().
String homeDir() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    '';

/// ccConfigDir is cc-handoff's user-level config directory, mirroring the Go
/// CLI's config.UserConfigPath: %AppData%\cc-handoff on Windows
/// (os.UserConfigDir), ~/.config/cc-handoff on macOS/Linux. The app and the
/// bundled binary MUST agree here, or the app reads/writes a different file than
/// the CLI and the user ends up "logged in but unconfigured" on Windows.
String ccConfigDir() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) return '$appData\\cc-handoff';
    return '${homeDir()}\\AppData\\Roaming\\cc-handoff';
  }
  return '${homeDir()}/.config/cc-handoff';
}

/// expandHome expands a leading `~` / `~/` to the user's home directory; any
/// other string is returned unchanged. Shared by config-path parsing and PTY
/// working-directory resolution so the two agree.
String expandHome(String p) {
  if (p == '~') return homeDir();
  if (p.startsWith('~/')) return '${homeDir()}/${p.substring(2)}';
  return p;
}
