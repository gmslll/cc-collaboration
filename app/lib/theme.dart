import 'package:flutter/material.dart';

// Dark dev-tool theme mirroring the web UI's indigo palette
// (internal/relay/ui/styles.css dark tokens). Flutter renders CJK via system
// font fallback, so no bundled font is needed (unlike Fyne).
class CcColors {
  static const bg = Color(0xFF0B1220);
  static const panel = Color(0xFF111A2C);
  static const panelHigh = Color(0xFF142037);
  static const border = Color(0xFF1F2A40);
  static const borderSoft = Color(0xFF27344D);
  static const text = Color(0xFFE2E8F0);
  static const muted = Color(0xFF94A3B8);
  static const subtle = Color(0xFF64748B);
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
    hoverColor: CcColors.accent.withValues(alpha: 0.06),
    focusColor: CcColors.accent.withValues(alpha: 0.12),
    dividerTheme: const DividerThemeData(color: CcColors.border, thickness: 1),
    cardTheme: CardThemeData(
      color: CcColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: CcColors.borderSoft),
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
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: CcColors.bg.withValues(alpha: 0.28),
      hintStyle: const TextStyle(color: CcColors.subtle),
      labelStyle: const TextStyle(color: CcColors.muted),
      prefixIconColor: CcColors.muted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: CcColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: CcColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: CcColors.accent, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: CcColors.accent,
        foregroundColor: CcColors.bg,
        minimumSize: const Size(44, 38),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: CcColors.text,
        side: const BorderSide(color: CcColors.borderSoft),
        minimumSize: const Size(44, 38),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? CcColors.accent.withValues(alpha: 0.14)
                : CcColors.panel),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? CcColors.text : CcColors.muted),
        side: WidgetStateProperty.resolveWith((states) => BorderSide(
              color: states.contains(WidgetState.selected)
                  ? CcColors.accent.withValues(alpha: 0.55)
                  : CcColors.border,
            )),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      dividerColor: CcColors.border,
      indicatorColor: CcColors.accent,
      labelColor: CcColors.text,
      unselectedLabelColor: CcColors.muted,
      labelStyle: TextStyle(fontWeight: FontWeight.w700),
      indicatorSize: TabBarIndicatorSize.label,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: CcColors.panelHigh,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: CcColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: CcColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
