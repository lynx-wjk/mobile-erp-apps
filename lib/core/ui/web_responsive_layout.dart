import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme_mode.dart';

/// Helper to detect web viewport
bool isDesktopWeb(BuildContext context) {
  return kIsWeb && MediaQuery.of(context).size.width >= 900;
}

/// Full Scaffold replacement for desktop web.
/// On desktop (>=1024px): floating glass header replaces AppBar, content is
/// max-width constrained to 1600px with horizontal padding.
/// On mobile (<1024px): renders a standard Scaffold with the provided AppBar.
class WebResponsiveScaffold extends StatelessWidget {
  final String? title;
  final String? activeWebTitle;
  final List<Widget>? actions;
  final Widget body;
  final Widget? floatingActionButton;
  final PreferredSizeWidget? bottom; // tabs
  final VoidCallback? onBack;
  final Widget? drawer;
  final Color? backgroundColor;
  final PreferredSizeWidget? appBar;

  const WebResponsiveScaffold({
    super.key,
    this.title,
    this.activeWebTitle,
    this.actions,
    required this.body,
    this.floatingActionButton,
    this.bottom,
    this.onBack,
    this.drawer,
    this.backgroundColor,
    this.appBar,
  });

  String _resolveTitle() {
    if (title != null && title!.isNotEmpty) return title!;
    if (appBar is AppBar) {
      final ab = appBar as AppBar;
      if (ab.title is Text) {
        return (ab.title as Text).data ?? '';
      }
    }
    return '';
  }

  List<Widget>? _resolveActions() {
    if (actions != null) return actions;
    if (appBar is AppBar) {
      return (appBar as AppBar).actions;
    }
    return null;
  }

  PreferredSizeWidget? _resolveBottom() {
    if (bottom != null) return bottom;
    if (appBar is AppBar) {
      return (appBar as AppBar).bottom;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveTitle = _resolveTitle();
    final effectiveActions = _resolveActions();
    final effectiveBottom = _resolveBottom();

    // Mobile: standard Scaffold with AppBar
    if (!isDesktopWeb(context)) {
      return Scaffold(
        backgroundColor: backgroundColor,
        drawer: drawer,
        appBar: appBar ??
            AppBar(
              title: Text(effectiveTitle),
              actions: effectiveActions,
              bottom: effectiveBottom,
              leading: onBack != null
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: onBack,
                    )
                  : null,
            ),
        floatingActionButton: floatingActionButton,
        body: body,
      );
    }

    // Desktop web: floating glass header replaces AppBar
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = backgroundColor ??
        (isDark ? const Color(0xFF0B0F19) : const Color(0xFFF8FAFC));
    final screenWidth = MediaQuery.of(context).size.width;
    final hPadding = screenWidth < 768 ? 8.0 : 32.0;

    return Scaffold(
      backgroundColor: bg,
      floatingActionButton: floatingActionButton,
      body: SafeArea(
        child: Column(
          children: [
            // Floating glass header with integrated title + tabs + actions
            _WebFloatingHeaderBar(
              title: effectiveTitle,
              activeWebTitle: activeWebTitle ?? effectiveTitle,
              actions: effectiveActions,
              bottom: effectiveBottom,
              onBack: onBack ?? () => Navigator.maybePop(context),
            ),
            // Main content
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: hPadding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1600),
                    child: body,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keep the old WebResponsiveWrapper for backward compat during migration.
/// It now just passes through with max-width constraint on desktop.
class WebResponsiveWrapper extends StatelessWidget {
  final Widget child;
  final String? activeTitle;
  final List<Widget>? extraActions;

  const WebResponsiveWrapper({
    super.key,
    required this.child,
    this.activeTitle,
    this.extraActions,
  });

  @override
  Widget build(BuildContext context) {
    if (!isDesktopWeb(context)) {
      return child;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: child,
        ),
      ),
    );
  }
}

/// Floating Glass Header Pill matching Acme Corp ERP top navigation pill design
class _WebFloatingHeaderBar extends StatelessWidget {
  final String title;
  final String activeWebTitle;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final VoidCallback onBack;

  const _WebFloatingHeaderBar({
    required this.title,
    required this.activeWebTitle,
    this.actions,
    this.bottom,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glassBg = isDark
        ? const Color(0xFF151C2C).withValues(alpha: 0.85)
        : Colors.white.withValues(alpha: 0.90);
    final borderColor = isDark
        ? const Color(0xFF28354A)
        : const Color(0xFFE2E8F0);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    final screenWidth = MediaQuery.of(context).size.width;
    final hMargin = screenWidth < 768 ? 8.0 : 32.0;

    return Container(
      margin: EdgeInsets.only(top: 14, left: hMargin, right: hMargin, bottom: 12),
      height: bottom != null ? 58 : 52,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: glassBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor, width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.06),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          // Back button
          IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: mutedColor, size: 18),
            onPressed: onBack,
            tooltip: 'Kembali',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 4),

          // Logo Icon + Brand Name
          Container(
            width: 28,
            height: 28,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFF38BDF8), Color(0xFF2563EB)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Center(
              child: Text(
                'A',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Mobile ERP',
            style: GoogleFonts.outfit(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: textColor,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 16),
          Container(height: 18, width: 1, color: borderColor),
          const SizedBox(width: 16),

          // Navigation Links or Tabs Bar in Middle
          Expanded(
            child: bottom != null
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        tabBarTheme: TabBarThemeData(
                          indicator: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF334155)
                                : const Color(0xFFE2E8F0),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          indicatorSize: TabBarIndicatorSize.tab,
                          labelColor: textColor,
                          unselectedLabelColor: mutedColor,
                          labelStyle: GoogleFonts.outfit(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                          unselectedLabelStyle: GoogleFonts.outfit(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                          dividerColor: Colors.transparent,
                        ),
                      ),
                      child: Container(
                        height: 38,
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: bottom!,
                      ),
                    ),
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF334155).withValues(alpha: 0.6)
                            : const Color(0xFFE2E8F0).withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        activeWebTitle,
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 12),

          // Right side: Custom Actions + User Avatar + Theme Switcher Toggle
          if (actions != null) ...[
            ...actions!.map((a) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: a,
                )),
            const SizedBox(width: 8),
          ],

          // User Avatar Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1E293B)
                  : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: borderColor, width: 0.8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircleAvatar(
                  radius: 11,
                  backgroundColor: Color(0xFF38BDF8),
                  child: Icon(Icons.person, size: 13, color: Colors.white),
                ),
                const SizedBox(width: 6),
                Text(
                  'User',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Sun / Moon Toggle Switch Pill
          _ThemeSwitcherPill(borderColor: borderColor, textColor: textColor),
          const SizedBox(width: 8),

          // Logout Button
          IconButton(
            tooltip: 'Logout / Keluar',
            icon: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 18),
            onPressed: () async {
              try {
                await Supabase.instance.client.auth.signOut();
              } catch (_) {}
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

/// Compact Sun/Moon capsule toggle switch matching screenshot
class _ThemeSwitcherPill extends StatelessWidget {
  final Color borderColor;
  final Color textColor;

  const _ThemeSwitcherPill({
    required this.borderColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppVisualMode>(
      valueListenable: AppThemeModeController.mode,
      builder: (context, mode, _) {
        final isCurrentDark = mode == AppVisualMode.man;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return Tooltip(
          message: isCurrentDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
          child: InkWell(
            onTap: () async {
              await AppThemeModeController.toggle();
            },
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0F172A)
                    : const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: borderColor, width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: !isCurrentDark
                          ? const Color(0xFF38BDF8)
                          : Colors.transparent,
                    ),
                    child: Icon(
                      Icons.light_mode_rounded,
                      size: 14,
                      color: !isCurrentDark ? Colors.white : const Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isCurrentDark
                          ? const Color(0xFF3B82F6)
                          : Colors.transparent,
                    ),
                    child: Icon(
                      Icons.dark_mode_rounded,
                      size: 14,
                      color: isCurrentDark ? Colors.white : const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Reusable Subtle Glass Card with no aggressive glow and clean 1px border
class WebSubtleGlassCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final double radius;
  final Color? accentColor;

  const WebSubtleGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.onTap,
    this.radius = 16,
    this.accentColor,
  });

  @override
  State<WebSubtleGlassCard> createState() => _WebSubtleGlassCardState();
}

class _WebSubtleGlassCardState extends State<WebSubtleGlassCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark
        ? const Color(0xFF1E293B)
            .withValues(alpha: _isHovered ? 0.65 : 0.45)
        : Colors.white.withValues(alpha: _isHovered ? 0.95 : 0.85);
    final borderColor = isDark
        ? (_isHovered ? const Color(0xFF475569) : const Color(0xFF334155))
        : (_isHovered ? const Color(0xFFCBD5E1) : const Color(0xFFE2E8F0));

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          transform: Matrix4.identity()
            ..translate(0.0, _isHovered ? -2.0 : 0.0),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(color: borderColor, width: 1.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                    alpha: isDark
                        ? (_isHovered ? 0.20 : 0.10)
                        : (_isHovered ? 0.08 : 0.03)),
                blurRadius: _isHovered ? 16 : 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Adaptive Grid Helper for Web Desktop
class WebSpaciousGrid extends StatelessWidget {
  final List<Widget> children;
  final int desktopCrossAxisCount;
  final double spacing;

  const WebSpaciousGrid({
    super.key,
    required this.children,
    this.desktopCrossAxisCount = 3,
    this.spacing = 24,
  });

  @override
  Widget build(BuildContext context) {
    if (!isDesktopWeb(context)) {
      return Column(
        children: children
            .map((c) => Padding(
                padding: EdgeInsets.only(bottom: spacing), child: c))
            .toList(),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = desktopCrossAxisCount;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: children.map((c) {
            final itemWidth =
                (constraints.maxWidth - (spacing * (cols - 1))) / cols;
            return SizedBox(
              width: itemWidth.floorToDouble(),
              child: c,
            );
          }).toList(),
        );
      },
    );
  }
}
