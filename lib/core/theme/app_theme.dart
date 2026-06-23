import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryColor = Color(0xFF2563EB);
  static const Color accentColor = Color(0xFF14B8A6);
  static const Color successColor = Color(0xFF16A34A);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color dangerColor = Color(0xFFDC2626);
  static const Color pinkColor = Color(0xFFDB2777);
  static const Color orangeColor = Color(0xFFEA580C);
  static const Color indigoColor = Color(0xFF4F46E5);

  static const Color bgDeep = Color(0xFFF4F7FB);
  static const Color bgSurface = Color(0xFFFFFFFF);
  static const Color bgCard = Color(0xFFFFFFFF);
  static const Color bgCardBorder = Color(0xFFD7DEE8);
  static const Color bgElevated = Color(0xFFE9EEF5);

  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF334155);
  static const Color textMuted = Color(0xFF64748B);

  static const Color _darkBg = Color(0xFF0B1120);
  static const Color _darkSurface = Color(0xFF111827);
  static const Color _darkCard = Color(0xFF182235);
  static const Color _darkBorder = Color(0xFF334155);
  static const Color _darkText = Color(0xFFE5E7EB);
  static const Color _darkMuted = Color(0xFF94A3B8);

  static BorderRadius get radiusSm => BorderRadius.circular(8);
  static BorderRadius get radiusMd => BorderRadius.circular(12);
  static BorderRadius get radiusLg => BorderRadius.circular(16);

  static List<BoxShadow> softShadow(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return [
      BoxShadow(
        color: (dark ? Colors.black : const Color(0xFF64748B))
            .withOpacity(dark ? 0.28 : 0.10),
        blurRadius: dark ? 24 : 22,
        spreadRadius: -10,
        offset: const Offset(0, 14),
      ),
    ];
  }

  static TextTheme _textTheme(TextTheme base, Color color) {
    return base
        .apply(
          bodyColor: color,
          displayColor: color,
          fontFamily: 'Segoe UI',
        )
        .copyWith(
          displayLarge: base.displayLarge?.copyWith(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            height: 1.08,
            letterSpacing: 0,
          ),
          displayMedium: base.displayMedium?.copyWith(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            height: 1.1,
            letterSpacing: 0,
          ),
          displaySmall: base.displaySmall?.copyWith(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            height: 1.12,
            letterSpacing: 0,
          ),
          headlineLarge: base.headlineLarge?.copyWith(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            height: 1.14,
            letterSpacing: 0,
          ),
          headlineMedium: base.headlineMedium?.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.16,
            letterSpacing: 0,
          ),
          headlineSmall: base.headlineSmall?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.18,
            letterSpacing: 0,
          ),
          titleLarge: base.titleLarge?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1.22,
            letterSpacing: 0,
          ),
          titleMedium: base.titleMedium?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.25,
            letterSpacing: 0,
          ),
          titleSmall: base.titleSmall?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.24,
            letterSpacing: 0,
          ),
          bodyLarge: base.bodyLarge?.copyWith(
            fontSize: 14.5,
            fontWeight: FontWeight.w400,
            height: 1.42,
            letterSpacing: 0,
          ),
          bodyMedium: base.bodyMedium?.copyWith(
            fontSize: 13.5,
            fontWeight: FontWeight.w400,
            height: 1.38,
            letterSpacing: 0,
          ),
          bodySmall: base.bodySmall?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            height: 1.34,
            letterSpacing: 0,
          ),
          labelLarge: base.labelLarge?.copyWith(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
          labelMedium: base.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
          labelSmall: base.labelSmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        );
  }

  static ThemeData get lightTheme {
    final base = ThemeData.light(useMaterial3: true);
    const scheme = ColorScheme.light(
      primary: primaryColor,
      onPrimary: Colors.white,
      secondary: accentColor,
      onSecondary: Color(0xFF052E2B),
      tertiary: indigoColor,
      error: dangerColor,
      onError: Colors.white,
      surface: bgSurface,
      onSurface: textPrimary,
      surfaceVariant: Color(0xFFEFF4FA),
      outline: bgCardBorder,
      outlineVariant: Color(0xFFE5EAF1),
    );

    return base.copyWith(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: bgDeep,
      canvasColor: bgSurface,
      cardColor: bgCard,
      textTheme: _textTheme(base.textTheme, textPrimary),
      appBarTheme: AppBarTheme(
        backgroundColor: bgSurface.withOpacity(0.96),
        foregroundColor: textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: textSecondary, size: 22),
        titleTextStyle: const TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
      cardTheme: CardThemeData(
        color: bgCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radiusMd,
          side: const BorderSide(color: bgCardBorder),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: bgCard,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
        textStyle: const TextStyle(
          color: textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: bgSurface,
        surfaceTintColor: Colors.transparent,
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        minLeadingWidth: 28,
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        iconColor: textMuted,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: TextStyle(
          color: textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        hintStyle:
            const TextStyle(color: textMuted, fontWeight: FontWeight.w400),
        labelStyle:
            const TextStyle(color: textSecondary, fontWeight: FontWeight.w600),
        prefixIconColor: textMuted,
        suffixIconColor: textMuted,
        border: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: bgCardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: bgCardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: primaryColor, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: dangerColor),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: dangerColor, width: 1.6),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: bgElevated,
          disabledForegroundColor: textMuted,
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          shape: RoundedRectangleBorder(borderRadius: radiusMd),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: bgCardBorder),
          shape: RoundedRectangleBorder(borderRadius: radiusMd),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryColor,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          minimumSize: const Size(44, 40),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFFEFF4FA),
        selectedColor: const Color(0xFFDCEAFE),
        secondarySelectedColor: const Color(0xFFDCEAFE),
        disabledColor: bgElevated,
        labelStyle: const TextStyle(
          color: textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        side: const BorderSide(color: bgCardBorder),
        shape: RoundedRectangleBorder(borderRadius: radiusSm),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE5EAF1),
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: radiusLg),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: textPrimary,
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: primaryColor,
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: primaryColor,
        unselectedLabelColor: textMuted,
        labelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
        unselectedLabelStyle:
            TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        dividerColor: Color(0xFFE5EAF1),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: bgSurface,
        selectedItemColor: primaryColor,
        unselectedItemColor: textMuted,
        selectedLabelStyle:
            TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
        unselectedLabelStyle:
            TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bgSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFFDCEAFE),
        elevation: 0,
        height: 68,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: bgSurface,
        selectedIconTheme: IconThemeData(color: primaryColor),
        unselectedIconTheme: IconThemeData(color: textMuted),
        selectedLabelTextStyle:
            TextStyle(color: primaryColor, fontWeight: FontWeight.w700),
        unselectedLabelTextStyle:
            TextStyle(color: textMuted, fontWeight: FontWeight.w600),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: MaterialStateProperty.all(const Color(0xFFEFF4FA)),
        headingTextStyle: const TextStyle(
          color: textSecondary,
          fontWeight: FontWeight.w700,
        ),
        dataTextStyle: const TextStyle(color: textPrimary),
        dividerThickness: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStateProperty.resolveWith(
          (states) => states.contains(MaterialState.selected)
              ? Colors.white
              : textMuted,
        ),
        trackColor: MaterialStateProperty.resolveWith(
          (states) => states.contains(MaterialState.selected)
              ? primaryColor
              : bgElevated,
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    final base = ThemeData.dark(useMaterial3: true);
    const scheme = ColorScheme.dark(
      primary: Color(0xFF60A5FA),
      onPrimary: Color(0xFF07111F),
      secondary: Color(0xFF2DD4BF),
      onSecondary: Color(0xFF042F2E),
      tertiary: Color(0xFFA5B4FC),
      error: Color(0xFFF87171),
      onError: Color(0xFF2A0707),
      surface: _darkSurface,
      onSurface: _darkText,
      surfaceVariant: Color(0xFF1E293B),
      outline: _darkBorder,
      outlineVariant: Color(0xFF253348),
    );

    return base.copyWith(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: _darkBg,
      canvasColor: _darkSurface,
      cardColor: _darkCard,
      textTheme: _textTheme(base.textTheme, _darkText),
      appBarTheme: const AppBarTheme(
        backgroundColor: _darkSurface,
        foregroundColor: _darkText,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: _darkMuted, size: 22),
        titleTextStyle: TextStyle(
          color: _darkText,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
      cardTheme: CardThemeData(
        color: _darkCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radiusMd,
          side: const BorderSide(color: _darkBorder),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: _darkCard,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
        textStyle: const TextStyle(
          color: _darkText,
          fontWeight: FontWeight.w600,
        ),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: _darkSurface,
        surfaceTintColor: Colors.transparent,
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        minLeadingWidth: 28,
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        iconColor: _darkMuted,
        titleTextStyle: TextStyle(
          color: _darkText,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: TextStyle(
          color: _darkMuted,
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _darkSurface,
        hintStyle:
            const TextStyle(color: _darkMuted, fontWeight: FontWeight.w400),
        labelStyle:
            const TextStyle(color: _darkText, fontWeight: FontWeight.w600),
        prefixIconColor: _darkMuted,
        suffixIconColor: _darkMuted,
        border: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: _darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: _darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: Color(0xFF60A5FA), width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: Color(0xFFF87171)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: Color(0xFFF87171), width: 1.6),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF60A5FA),
          foregroundColor: const Color(0xFF07111F),
          disabledBackgroundColor: const Color(0xFF253348),
          disabledForegroundColor: _darkMuted,
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          shape: RoundedRectangleBorder(borderRadius: radiusMd),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _darkText,
          side: const BorderSide(color: _darkBorder),
          shape: RoundedRectangleBorder(borderRadius: radiusMd),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF93C5FD),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          minimumSize: const Size(44, 40),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFF1E293B),
        selectedColor: const Color(0xFF1D4ED8),
        secondarySelectedColor: const Color(0xFF1D4ED8),
        disabledColor: const Color(0xFF253348),
        labelStyle: const TextStyle(
          color: _darkText,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        side: const BorderSide(color: _darkBorder),
        shape: RoundedRectangleBorder(borderRadius: radiusSm),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF253348),
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: _darkSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: radiusLg),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFFE5E7EB),
        contentTextStyle: const TextStyle(
          color: Color(0xFF111827),
          fontWeight: FontWeight.w600,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: Color(0xFF60A5FA),
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: Color(0xFF93C5FD),
        unselectedLabelColor: _darkMuted,
        labelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
        unselectedLabelStyle:
            TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        dividerColor: Color(0xFF253348),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: _darkSurface,
        selectedItemColor: Color(0xFF93C5FD),
        unselectedItemColor: _darkMuted,
        selectedLabelStyle:
            TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
        unselectedLabelStyle:
            TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _darkSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFF1E3A8A),
        elevation: 0,
        height: 68,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: _darkSurface,
        selectedIconTheme: IconThemeData(color: Color(0xFF93C5FD)),
        unselectedIconTheme: IconThemeData(color: _darkMuted),
        selectedLabelTextStyle:
            TextStyle(color: Color(0xFF93C5FD), fontWeight: FontWeight.w700),
        unselectedLabelTextStyle:
            TextStyle(color: _darkMuted, fontWeight: FontWeight.w600),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: MaterialStateProperty.all(const Color(0xFF1E293B)),
        headingTextStyle: const TextStyle(
          color: _darkText,
          fontWeight: FontWeight.w700,
        ),
        dataTextStyle: const TextStyle(color: _darkText),
        dividerThickness: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStateProperty.resolveWith(
          (states) => states.contains(MaterialState.selected)
              ? const Color(0xFF07111F)
              : _darkMuted,
        ),
        trackColor: MaterialStateProperty.resolveWith(
          (states) => states.contains(MaterialState.selected)
              ? const Color(0xFF60A5FA)
              : const Color(0xFF253348),
        ),
      ),
    );
  }

  static ThemeData get manTheme => darkTheme;
}
