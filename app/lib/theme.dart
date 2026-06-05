import 'package:flutter/material.dart';

// Dark developer-cockpit theme: a restrained Swiss-minimal base (clean spacing,
// clear hierarchy, indigo accent) with tasteful technical accents — JetBrains
// Mono for code/paths/terminal, subtle gradients, soft accent glow, 200ms hover.
class CcColors {
  static const bg = Color(0xFF0A0E1A);
  static const bgGradTop = Color(0xFF0E1626); // top of the subtle app gradient
  static const panel = Color(0xFF111726);
  static const panelHigh = Color(0xFF18213A);
  static const border = Color(0xFF222C42);
  static const borderSoft = Color(0xFF2D3950);
  static const text = Color(0xFFE6EAF2);
  static const muted = Color(0xFF98A2B8);
  static const subtle = Color(0xFF727D94); // ≥4.5:1 on bg (WCAG AA)
  static const accent = Color(0xFF818CF8); // indigo — primary
  static const accentBright = Color(0xFFA5B4FC); // hover / glow highlight
  static const danger = Color(0xFFF87171);
  static const warning = Color(0xFFFBBF24);
  static const ok = Color(0xFF34D399); // run / online / launch
}

class CcRadius {
  // crisp, near-square corners for a terminal/TUI feel.
  static const sm = 4.0;
  static const md = 6.0;
  static const pill = 999.0;
}

// CcType.mono is the bundled JetBrains Mono — for code, paths, branches,
// terminal and badges. UI text stays on the system sans (zero bundle weight).
class CcType {
  static const mono = 'JetBrainsMono';

  static TextStyle code(
          {double size = 13, Color color = CcColors.text, FontWeight? weight}) =>
      TextStyle(
        fontFamily: mono,
        fontSize: size,
        height: 1.4,
        color: color,
        fontWeight: weight ?? FontWeight.w400,
      );
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

  const t = CcColors.text;
  final textTheme = const TextTheme(
    titleLarge:
        TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.25, letterSpacing: -0.3),
    titleMedium: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, height: 1.3),
    titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 15.5, height: 1.5),
    bodyMedium: TextStyle(fontSize: 14.5, height: 1.5),
    bodySmall: TextStyle(fontSize: 13, height: 1.45, color: CcColors.muted),
    labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    labelMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    labelSmall: TextStyle(
        fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: CcColors.muted),
  ).apply(bodyColor: t, displayColor: t);

  OutlineInputBorder inputBorder(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(CcRadius.sm),
        borderSide: BorderSide(color: c, width: w),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: textTheme,
    scaffoldBackgroundColor: CcColors.bg,
    canvasColor: CcColors.bg,
    dividerColor: CcColors.border,
    hoverColor: CcColors.accent.withValues(alpha: 0.06),
    focusColor: CcColors.accent.withValues(alpha: 0.20), // visible keyboard focus
    splashColor: CcColors.accent.withValues(alpha: 0.08),
    dividerTheme: const DividerThemeData(color: CcColors.border, thickness: 1),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.hovered) ? CcColors.subtle : CcColors.borderSoft),
      thickness: const WidgetStatePropertyAll(9),
      radius: const Radius.circular(8),
      crossAxisMargin: 3,
    ),
    cardTheme: CardThemeData(
      color: CcColors.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CcRadius.md),
        side: const BorderSide(color: CcColors.borderSoft),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: CcColors.panel,
      foregroundColor: CcColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleSpacing: 16,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: CcColors.panel,
      indicatorColor: CcColors.accent.withValues(alpha: 0.16),
      indicatorShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selectedIconTheme:
          const IconThemeData(color: CcColors.accentBright, size: 26),
      unselectedIconTheme: const IconThemeData(color: CcColors.muted, size: 24),
      selectedLabelTextStyle: const TextStyle(
          color: CcColors.text, fontSize: 12.5, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle:
          const TextStyle(color: CcColors.muted, fontSize: 12.5),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: CcColors.panel,
      indicatorColor: CcColors.accent.withValues(alpha: 0.16),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.selected)
                ? CcColors.text
                : CcColors.muted,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color: s.contains(WidgetState.selected)
                ? CcColors.accentBright
                : CcColors.muted,
          )),
    ),
    listTileTheme: const ListTileThemeData(
      selectedTileColor: CcColors.panelHigh,
      iconColor: CcColors.muted,
      selectedColor: CcColors.text,
      minVerticalPadding: 10,
      horizontalTitleGap: 10,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: CcColors.panelHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: CcColors.border),
      ),
      textStyle: const TextStyle(color: CcColors.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: CcColors.bg.withValues(alpha: 0.35),
      hintStyle: const TextStyle(color: CcColors.subtle),
      labelStyle: const TextStyle(color: CcColors.muted),
      floatingLabelStyle: const TextStyle(color: CcColors.accentBright),
      prefixIconColor: CcColors.muted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: inputBorder(CcColors.border),
      enabledBorder: inputBorder(CcColors.border),
      focusedBorder: inputBorder(CcColors.accent, 1.4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: CcColors.accent,
        foregroundColor: CcColors.bg,
        elevation: 3,
        shadowColor: CcColors.accent.withValues(alpha: 0.45),
        minimumSize: const Size(44, 42),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(CcRadius.sm)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: CcColors.text,
        side: const BorderSide(color: CcColors.borderSoft),
        minimumSize: const Size(44, 42),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(CcRadius.sm)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: CcColors.accentBright),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: CcColors.muted),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? CcColors.accent.withValues(alpha: 0.16)
                : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? CcColors.accentBright
                : CcColors.muted),
        side: WidgetStateProperty.resolveWith((states) => BorderSide(
              color: states.contains(WidgetState.selected)
                  ? CcColors.accent.withValues(alpha: 0.55)
                  : CcColors.border,
            )),
        textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(CcRadius.sm)),
        ),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      dividerColor: CcColors.border,
      indicatorColor: CcColors.accent,
      labelColor: CcColors.text,
      unselectedLabelColor: CcColors.muted,
      labelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
      indicatorSize: TabBarIndicatorSize.label,
      overlayColor: WidgetStatePropertyAll(Colors.transparent),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: CcColors.panelHigh,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CcRadius.sm),
        side: const BorderSide(color: CcColors.border),
      ),
      textStyle: const TextStyle(color: CcColors.text, fontSize: 13),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: CcColors.panelHigh,
      contentTextStyle: const TextStyle(color: CcColors.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CcRadius.sm),
        side: const BorderSide(color: CcColors.border),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: CcColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(CcRadius.md)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: CcColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CcRadius.md),
        side: const BorderSide(color: CcColors.border),
      ),
    ),
  );
}
