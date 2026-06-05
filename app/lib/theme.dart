import 'package:flutter/material.dart';

// Dark dev-tool theme mirroring the web UI's indigo palette
// (internal/relay/ui/styles.css dark tokens). Flutter renders CJK via system
// font fallback, so no bundled font is needed (unlike Fyne).
class CcColors {
  static const bg = Color(0xFF0B1220);
  static const panel = Color(0xFF111A2C);
  static const panelHigh = Color(0xFF142037);
  static const border = Color(0xFF1F2A40);
  static const text = Color(0xFFE2E8F0);
  static const muted = Color(0xFF94A3B8);
  static const accent = Color(0xFF818CF8);
  static const danger = Color(0xFFF87171);
  static const warning = Color(0xFFFBBF24);
  static const ok = Color(0xFF4ADE80);
}

ThemeData ccTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: CcColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: CcColors.accent,
    surface: CcColors.panel,
    onSurface: CcColors.text,
    outline: CcColors.border,
    error: CcColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: CcColors.bg,
    canvasColor: CcColors.bg,
    dividerColor: CcColors.border,
    dividerTheme: const DividerThemeData(color: CcColors.border, thickness: 1),
    cardTheme: CardThemeData(
      color: CcColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: CcColors.border),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: CcColors.panel,
      foregroundColor: CcColors.text,
      elevation: 0,
    ),
    listTileTheme: const ListTileThemeData(
      selectedTileColor: CcColors.panelHigh,
      iconColor: CcColors.muted,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: CcColors.accent,
        foregroundColor: CcColors.bg,
      ),
    ),
  );
}
