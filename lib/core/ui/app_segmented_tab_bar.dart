import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTabItem {
  final String label;
  final IconData? icon;
  final Widget? badge;

  const AppTabItem({
    required this.label,
    this.icon,
    this.badge,
  });
}

class AppSegmentedTabBar extends StatelessWidget {
  final TabController? controller;
  final List<AppTabItem> tabs;
  final double maxWidth;
  final EdgeInsetsGeometry margin;
  final bool isScrollable;
  final ValueChanged<int>? onTap;

  const AppSegmentedTabBar({
    super.key,
    this.controller,
    required this.tabs,
    this.maxWidth = 600,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.isScrollable = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final indicatorColor = isDark ? const Color(0xFF334155) : Colors.white;
    final activeTextColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final inactiveTextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: isScrollable ? double.infinity : maxWidth),
        margin: margin,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: TabBar(
          controller: controller,
          isScrollable: isScrollable,
          tabAlignment: isScrollable ? TabAlignment.start : TabAlignment.fill,
          onTap: onTap,
          indicator: BoxDecoration(
            color: indicatorColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          labelColor: activeTextColor,
          unselectedLabelColor: inactiveTextColor,
          labelStyle: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 13),
          unselectedLabelStyle: GoogleFonts.outfit(fontWeight: FontWeight.w500, fontSize: 13),
          tabs: tabs.map((t) {
            return Tab(
              height: 38,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isScrollable ? 10 : 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t.icon != null) ...[
                      Icon(t.icon, size: 17),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      t.label,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (t.badge != null) ...[
                      const SizedBox(width: 6),
                      t.badge!,
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
