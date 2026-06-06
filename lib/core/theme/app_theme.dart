import 'package:flutter/material.dart';

class AppTheme {
  // ── Pixel Art Retro Palette ────────────────────────────────────────────────
  static const Color primaryColor = Color(0xFF00D4FF); // Arcade Blue
  static const Color accentColor = Color(0xFF8B5CF6);  // Retro Purple
  static const Color successColor = Color(0xFF39FF14); // Matrix Green
  static const Color warningColor = Color(0xFFFFD700); // Arcade Yellow
  static const Color dangerColor = Color(0xFFFF0033);  // Power Red
  static const Color pinkColor = Color(0xFFFF006E);    // Neon Pink
  static const Color orangeColor = Color(0xFFFF6B00);  // Burn Orange
  static const Color indigoColor = Color(0xFF4D4DFF);  // Deep Blue

  // ── Backgrounds ────────────────────────────────────────────────────────────
  static const Color bgDeep = Color(0xFFE2E2E2);     // Visible Retro Gray
  static const Color bgSurface = Color(0xFFF0F0F0);  // Off White
  static const Color bgCard = Color(0xFFFFFFFF);
  static const Color bgCardBorder = Color(0xFF000000); // Black for high contrast
  static const Color bgElevated = Color(0xFFBDBDBD);

  static const Color textPrimary = Color(0xFF000000);
  static const Color textSecondary = Color(0xFF333333);
  static const Color textMuted = Color(0xFF666666);

  static TextTheme _proportionalTextTheme(TextTheme base, Color color) {
    return base.apply(
      bodyColor: color,
      displayColor: color,
    ).copyWith(
      displayLarge: base.displayLarge?.copyWith(fontSize: 36, fontWeight: FontWeight.w800),
      displayMedium: base.displayMedium?.copyWith(fontSize: 32, fontWeight: FontWeight.w800),
      displaySmall: base.displaySmall?.copyWith(fontSize: 28, fontWeight: FontWeight.w800),
      headlineLarge: base.headlineLarge?.copyWith(fontSize: 25, fontWeight: FontWeight.w800),
      headlineMedium: base.headlineMedium?.copyWith(fontSize: 22, fontWeight: FontWeight.w800),
      headlineSmall: base.headlineSmall?.copyWith(fontSize: 19, fontWeight: FontWeight.w800),
      titleLarge: base.titleLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
      titleMedium: base.titleMedium?.copyWith(fontSize: 15, fontWeight: FontWeight.w800),
      titleSmall: base.titleSmall?.copyWith(fontSize: 13, fontWeight: FontWeight.w800),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w500, height: 1.25),
      bodyMedium: base.bodyMedium?.copyWith(fontSize: 13, fontWeight: FontWeight.w500, height: 1.25),
      bodySmall: base.bodySmall?.copyWith(fontSize: 11.5, fontWeight: FontWeight.w500, height: 1.25),
      labelLarge: base.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w800),
      labelMedium: base.labelMedium?.copyWith(fontSize: 11.5, fontWeight: FontWeight.w800),
      labelSmall: base.labelSmall?.copyWith(fontSize: 10.5, fontWeight: FontWeight.w800),
    );
  }

  static ThemeData get lightTheme {
    final base = ThemeData.light(useMaterial3: true);

    return base.copyWith(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: primaryColor,
        secondary: accentColor,
        tertiary: pinkColor,
        surface: bgSurface,
        error: dangerColor,
        onPrimary: Color(0xFF000000),
        onSecondary: Color(0xFFFFFFFF),
        onSurface: textPrimary,
        outline: bgCardBorder,
      ),
      scaffoldBackgroundColor: bgDeep,
      canvasColor: bgCard,
      cardColor: bgCard,
      textTheme: _proportionalTextTheme(base.textTheme, textPrimary),
      listTileTheme: const ListTileThemeData(
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        titleTextStyle: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w800),
        subtitleTextStyle: TextStyle(color: textMuted, fontSize: 12, fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bgSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: Colors.black, size: 24),
        titleTextStyle: TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.w900,
          fontSize: 18,
          letterSpacing: -0.5,
        ),
        shape: Border(bottom: BorderSide(color: bgCardBorder, width: 3)),
      ),
      cardTheme: const CardThemeData(
        color: bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: bgCardBorder, width: 2.5),
        ),
        margin: EdgeInsets.zero,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: bgCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: bgCardBorder, width: 2),
        ),
        textStyle: TextStyle(color: textPrimary, fontWeight: FontWeight.w900),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFFFFFFF),
        hintStyle: TextStyle(color: textMuted, fontWeight: FontWeight.w700),
        labelStyle: TextStyle(color: textPrimary, fontWeight: FontWeight.w900),
        prefixIconColor: bgCardBorder,
        suffixIconColor: bgCardBorder,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: bgCardBorder, width: 2.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: bgCardBorder, width: 2.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: primaryColor, width: 3),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: dangerColor, width: 2.5),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: const Color(0xFF000000),
          disabledBackgroundColor: bgElevated,
          disabledForegroundColor: textMuted,
          textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: bgCardBorder, width: 2.5),
          ),
          minimumSize: const Size.fromHeight(54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          backgroundColor: Colors.white,
          side: const BorderSide(color: bgCardBorder, width: 2.5),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          textStyle: const TextStyle(fontWeight: FontWeight.w900),
          minimumSize: const Size.fromHeight(54),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: textPrimary,
          textStyle: const TextStyle(fontWeight: FontWeight.w900, decoration: TextDecoration.underline),
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: bgSurface,
        selectedColor: primaryColor,
        labelStyle: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: textPrimary),
        side: BorderSide(color: bgCardBorder, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      dividerTheme: const DividerThemeData(
        color: bgCardBorder,
        thickness: 2,
        space: 1,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: bgSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: bgCardBorder, width: 3),
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: primaryColor,
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: primaryColor,
        unselectedLabelColor: bgCardBorder,
        labelStyle: TextStyle(fontWeight: FontWeight.w900, fontSize: 10.5, letterSpacing: 0.6),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 10.5),
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: primaryColor, width: 4),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: bgSurface,
        selectedItemColor: primaryColor,
        unselectedItemColor: bgCardBorder,
        selectedLabelStyle: TextStyle(fontWeight: FontWeight.w900, fontSize: 10.5),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 10.5),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }

  static ThemeData get darkTheme {
    final base = ThemeData.dark(useMaterial3: true);
    const darkBg = Color(0xFF05070A);
    const darkSurface = Color(0xFF0F172A);
    const darkCard = Color(0xFF1E293B);
    const darkText = Color(0xFFFFFFFF);
    const neonPrimary = Color(0xFF00D4FF);
    const neonSecondary = Color(0xFFBC13FE);

    return base.copyWith(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: neonPrimary,
        secondary: neonSecondary,
        tertiary: Color(0xFFFF006E),
        surface: darkSurface,
        error: dangerColor,
        onPrimary: Color(0xFF000000),
        onSecondary: Color(0xFFFFFFFF),
        onSurface: darkText,
        outline: Color(0xFFFFFFFF),
      ),
      scaffoldBackgroundColor: darkBg,
      canvasColor: darkCard,
      cardColor: darkCard,
      textTheme: _proportionalTextTheme(base.textTheme, darkText),
      listTileTheme: const ListTileThemeData(
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        titleTextStyle: TextStyle(color: darkText, fontSize: 14, fontWeight: FontWeight.w800),
        subtitleTextStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: Colors.white),
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 18,
          letterSpacing: -0.5,
        ),
        shape: Border(bottom: BorderSide(color: Colors.white, width: 3)),
      ),
      cardTheme: const CardThemeData(
        color: darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: Colors.white, width: 2.5),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF0F172A),
        hintStyle: TextStyle(color: Color(0xFF94A3B8), fontWeight: FontWeight.w700),
        labelStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
        prefixIconColor: Colors.white,
        suffixIconColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: Colors.white, width: 2.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: Colors.white, width: 2.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: neonPrimary, width: 3),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: neonPrimary,
          foregroundColor: const Color(0xFF000000),
          textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: Colors.white, width: 2.5),
          ),
          minimumSize: const Size.fromHeight(54),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white, width: 2.5),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          textStyle: const TextStyle(fontWeight: FontWeight.w900),
          minimumSize: const Size.fromHeight(54),
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: darkSurface,
        selectedColor: neonPrimary,
        labelStyle: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: Colors.white),
        side: BorderSide(color: Colors.white, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: neonPrimary,
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: neonPrimary,
        unselectedLabelColor: Colors.white,
        labelStyle: TextStyle(fontWeight: FontWeight.w900, fontSize: 10.5, letterSpacing: 0.6),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 10.5),
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: neonPrimary, width: 4),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: darkSurface,
        selectedItemColor: neonPrimary,
        unselectedItemColor: Colors.white,
        selectedLabelStyle: TextStyle(fontWeight: FontWeight.w900, fontSize: 10.5),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 10.5),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }

  static ThemeData get manTheme => darkTheme;
}
