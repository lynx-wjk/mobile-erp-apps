import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/app_theme_mode.dart';

export '../theme/app_theme.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

// ─────────────────────────────────────────────────────────────────────────────
// App UI helpers and brand colours -- Retro Pixel Style
// ─────────────────────────────────────────────────────────────────────────────
class AppUi {
  static const blue = AppTheme.primaryColor;
  static const teal = Color(0xFF00FFD1); // Vibrant Neon
  static const purple = AppTheme.accentColor;
  static const pink = AppTheme.pinkColor;
  static const green = AppTheme.successColor;
  static const orange = AppTheme.warningColor;
  static const red = AppTheme.dangerColor;

  static const List<Color> playfulPalette = [
    AppTheme.primaryColor,
    Color(0xFF00FFD1),
    AppTheme.accentColor,
    AppTheme.pinkColor,
    AppTheme.orangeColor,
    AppTheme.indigoColor,
    Color(0xFF39FF14),
  ];

  static BoxDecoration glassDecoration(
    BuildContext context, {
    Color accent = AppTheme.primaryColor,
    double radius = 0,
    double accentOpacity = 0.15,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark ? Colors.white : Colors.black;

    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: theme.cardColor,
      border: Border.all(color: borderColor, width: 2.5),
      boxShadow: [
        BoxShadow(
          color: borderColor.withOpacity(0.8),
          blurRadius: 0,
          offset: const Offset(4, 4),
        ),
      ],
    );
  }

  // ── Formatters ──────────────────────────────────────────────────────────────
  static String money(num value) {
    final sign = value < 0 ? '-' : '';
    final raw = value.abs().round().toString();
    return '$sign${formatThousands(raw)}';
  }

  static String moneyInput(num value) {
    if (value == 0) return '';
    return money(value);
  }

  static String rupiah(num value) => 'Rp ${money(value)}';

  static num parseMoneyInput(String value) {
    final normalized = value
        .replaceAll('Rp', '')
        .replaceAll('rp', '')
        .replaceAll('.', '')
        .replaceAll(' ', '')
        .replaceAll(',', '.');
    return num.tryParse(normalized) ?? 0;
  }

  static String formatThousands(String value) {
    final sign = value.trim().startsWith('-') ? '-' : '';
    final clean = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.isEmpty) return '0';
    final trimmed = clean.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final buffer = StringBuffer();
    for (var i = 0; i < trimmed.length; i++) {
      final reverseIndex = trimmed.length - i;
      buffer.write(trimmed[i]);
      if (reverseIndex > 1 && reverseIndex % 3 == 1) buffer.write('.');
    }
    return '$sign${buffer.toString()}';
  }

  static String date(dynamic value) {
    final date = _toDate(value);
    if (date == null) return '-';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year}';
  }

  static String dateTime(dynamic value) {
    final date = _toDate(value);
    if (date == null) return '-';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} ${two(date.hour)}:${two(date.minute)}';
  }

  static DateTime? _toDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value.toLocal();
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  static num toNum(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value;
    return num.tryParse(value.toString()) ?? 0;
  }

  static String text(dynamic value, [String fallback = '-']) {
    final raw = value?.toString().trim() ?? '';
    return raw.isEmpty ? fallback : raw;
  }

  static Color statusColor(String status) {
    final clean = status.toLowerCase();
    if (clean.contains('done') ||
        clean.contains('finish') ||
        clean.contains('approved') ||
        clean.contains('verified') ||
        clean.contains('valid') ||
        clean.contains('active')) return green;
    if (clean.contains('reject') ||
        clean.contains('cancel') ||
        clean.contains('inactive') ||
        clean.contains('out')) return red;
    if (clean.contains('progress') ||
        clean.contains('revision') ||
        clean.contains('pending')) return orange;
    return blue;
  }

  static String userMessage(String message) {
    var text = message.trim();
    if (text.isEmpty) return 'Error. Coba lagi.';
    return text;
  }

  static void showSnack(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messenger = rootScaffoldMessengerKey.currentState;
      if (messenger == null) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text(message.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
        backgroundColor: Colors.black,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero, side: BorderSide(color: Colors.white, width: 2)),
      ));
    });
  }

  static void safeSnack(BuildContext context, String message) =>
      showSnack(message);

  static void safePop<T>(BuildContext context, [T? result]) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (context.mounted) {
      final navigator = Navigator.maybeOf(context);
      if (navigator != null && navigator.canPop()) {
        navigator.pop<T>(result);
        return;
      }
    }
    final rootNavigator = rootNavigatorKey.currentState;
    if (rootNavigator != null && rootNavigator.canPop()) {
      rootNavigator.pop<T>(result);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FuturisticLoader – Retro style
// ─────────────────────────────────────────────────────────────────────────────
class FuturisticLoader extends StatefulWidget {
  final String? message;
  final double size;

  const FuturisticLoader({super.key, this.message, this.size = 60});

  @override
  State<FuturisticLoader> createState() => _FuturisticLoaderState();
}

class _FuturisticLoaderState extends State<FuturisticLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _rotate;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat();
    _rotate = Tween<double>(begin: 0, end: 2 * math.pi).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = widget.size;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RotationTransition(
            turns: _rotate,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.primary, width: 4),
              ),
              child: Center(
                child: Container(
                  width: size * 0.4,
                  height: size * 0.4,
                  color: theme.colorScheme.secondary,
                ),
              ),
            ),
          ),
          if (widget.message != null) ...[
            const SizedBox(height: 16),
            Text(
              widget.message!.toUpperCase(),
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w900,
                fontSize: 12.5,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ShimmerCard – Blocky
// ─────────────────────────────────────────────────────────────────────────────
class ShimmerCard extends StatelessWidget {
  final double height;
  final double borderRadius;

  const ShimmerCard({super.key, this.height = 80, this.borderRadius = 0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        border: Border.all(color: theme.dividerColor, width: 2),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FuturisticHeader -- Arcade Style
// ─────────────────────────────────────────────────────────────────────────────
class FuturisticHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> stats;

  const FuturisticHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.stats = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark ? Colors.white : Colors.black;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border.all(color: accent, width: 3),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.9),
            blurRadius: 0,
            offset: const Offset(6, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      border: Border.all(color: accent, width: 2.5),
                    ),
                    child: Icon(icon, color: Colors.black, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title.toUpperCase(),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (stats.isNotEmpty) ...[
                const SizedBox(height: 16),
                Divider(height: 1, thickness: 2, color: accent),
                const SizedBox(height: 14),
                Wrap(spacing: 8, runSpacing: 8, children: stats),
              ],
            ],
          ),
          // Industrial indicator line
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              width: 40,
              height: 4,
              color: theme.colorScheme.tertiary.withOpacity(0.6),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// StatPill -- blocky badge
// ─────────────────────────────────────────────────────────────────────────────
class StatPill extends StatelessWidget {
  final String label;
  final String value;
  final Color? accentColor;

  const StatPill({
    super.key,
    required this.label,
    required this.value,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accentColor ?? theme.colorScheme.secondary;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark ? Colors.white : Colors.black;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        border: Border.all(color: borderColor, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark ? color : Colors.black,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: isDark ? Colors.white70 : Colors.black54,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppGlobalBackdrop -- Enhanced Arcade Grid
// ─────────────────────────────────────────────────────────────────────────────
class AppGlobalBackdrop extends StatelessWidget {
  final Widget child;
  final AppVisualMode visualMode;

  const AppGlobalBackdrop({
    super.key,
    required this.child,
    this.visualMode = AppVisualMode.girl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
      ),
      child: CustomPaint(
        painter: _GlobalBackdropPainter(
          isDark: isDark,
          gridColor: isDark ? Colors.white.withOpacity(0.12) : Colors.black.withOpacity(0.08),
        ),
        child: child,
      ),
    );
  }
}

class _GlobalBackdropPainter extends CustomPainter {
  final bool isDark;
  final Color gridColor;

  const _GlobalBackdropPainter({
    required this.isDark,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1.0;

    // Drawing the pixel grid
    const gap = 32.0;
    for (double x = 0; x <= size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Add retro corner ornaments
    final cornerPaint = Paint()
      ..color = (isDark ? Colors.cyan : Colors.black).withOpacity(0.2)
      ..strokeWidth = 4.0;

    const cornerSize = 48.0;
    const padding = 12.0;

    // Top Left
    canvas.drawLine(const Offset(padding, padding), const Offset(padding + cornerSize, padding), cornerPaint);
    canvas.drawLine(const Offset(padding, padding), const Offset(padding, padding + cornerSize), cornerPaint);

    // Top Right
    canvas.drawLine(Offset(size.width - padding, padding), Offset(size.width - padding - cornerSize, padding), cornerPaint);
    canvas.drawLine(Offset(size.width - padding, padding), Offset(size.width - padding, padding + cornerSize), cornerPaint);

    // Bottom Left
    canvas.drawLine(Offset(padding, size.height - padding), Offset(padding + cornerSize, size.height - padding), cornerPaint);
    canvas.drawLine(Offset(padding, size.height - padding), Offset(padding, size.height - padding - cornerSize), cornerPaint);

    // Bottom Right
    canvas.drawLine(Offset(size.width - padding, size.height - padding), Offset(size.width - padding - cornerSize, size.height - padding), cornerPaint);
    canvas.drawLine(Offset(size.width - padding, size.height - padding), Offset(size.width - padding, size.height - padding - cornerSize), cornerPaint);

    // Industrial data ornaments (pixel style)
    void drawPixelOrnament(Offset pos, Color color) {
       final p = Paint()..color = color;
       canvas.drawRect(Rect.fromLTWH(pos.dx, pos.dy, 8, 8), p);
       canvas.drawRect(Rect.fromLTWH(pos.dx + 12, pos.dy, 4, 4), p);
    }
    
    drawPixelOrnament(const Offset(padding + 10, padding + 10), cornerPaint.color);
    drawPixelOrnament(Offset(size.width - padding - 30, size.height - padding - 30), cornerPaint.color);

    // CRT Scanlines effect
    final scanlinePaint = Paint()
      ..color = (isDark ? Colors.white : Colors.black).withOpacity(0.015)
      ..strokeWidth = 1.0;
    for (double y = 0; y <= size.height; y += 6) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), scanlinePaint);
    }

    void drawLabel(String text, Offset pos) {
       final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: gridColor.withOpacity(isDark ? 0.3 : 0.2),
            fontSize: 8.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos);
    }

    drawLabel('SYSTEM.v2.PX', const Offset(padding + 60, padding + 4));
    drawLabel('LINK.STABLE', Offset(size.width - 160, size.height - padding - 14));

    // Linear Industrial ornaments
    final linePaint = Paint()
      ..color = gridColor.withOpacity(isDark ? 0.15 : 0.1)
      ..strokeWidth = 1.0;
    
    // Vertical sidebar line
    canvas.drawLine(const Offset(50, 0), Offset(50, size.height), linePaint);
    // Horizontal header line
    canvas.drawLine(const Offset(0, 100), Offset(size.width, 100), linePaint);

    // Pixel glitches (tiny rectangles)
    final rand = math.Random(1337);
    final glitchPaint = Paint()..color = gridColor.withOpacity(isDark ? 0.08 : 0.05);
    for (var i = 0; i < 15; i++) {
      final w = 20.0 + rand.nextDouble() * 40.0;
      final h = 2.0;
      final x = rand.nextDouble() * (size.width - w);
      final y = rand.nextDouble() * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), glitchPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GlobalBackdropPainter oldDelegate) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// NiceCard -- The core pixel art container
// ─────────────────────────────────────────────────────────────────────────────
class NiceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? borderColor;

  const NiceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark ? Colors.white : Colors.black;
    final cardBorder = borderColor ?? accent;

    final container = Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: theme.cardColor,
            border: Border.all(
              color: cardBorder,
              width: 2.5,
            ),
            boxShadow: [
              BoxShadow(
                color: cardBorder.withOpacity(0.8),
                blurRadius: 0,
                offset: const Offset(5, 5),
              ),
            ],
          ),
          child: Padding(padding: padding, child: child),
        ),
        // Decorative pixel dots in corners (Retro style)
        Positioned(
          top: 0,
          right: 0,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: cardBorder, width: 2.5),
                left: BorderSide(color: cardBorder, width: 2.5),
              ),
            ),
          ),
        ),
      ],
    );

    if (onTap == null) return container;

    return GestureDetector(
      onTap: onTap,
      child: container,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LoadingState
// ─────────────────────────────────────────────────────────────────────────────
class LoadingState extends StatelessWidget {
  const LoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return const FuturisticLoader(message: 'LOADING...');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EmptyState -- Retro style
// ─────────────────────────────────────────────────────────────────────────────
class EmptyState extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const EmptyState({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: NiceCard(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              title.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ErrorState -- Blocky alert
// ─────────────────────────────────────────────────────────────────────────────
class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorState({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: NiceCard(
        borderColor: theme.colorScheme.error,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 42, color: theme.colorScheme.error),
            const SizedBox(height: 14),
            Text(
              message.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('RETRY'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SectionTitle -- Chunky marker
// ─────────────────────────────────────────────────────────────────────────────
class SectionTitle extends StatelessWidget {
  final String title;
  final String? actionText;
  final VoidCallback? onAction;

  const SectionTitle({
    super.key,
    required this.title,
    this.actionText,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark ? Colors.white : Colors.black;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(width: 8, height: 24, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14.5, letterSpacing: 0.5),
            ),
          ),
          if (actionText != null && onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionText!.toUpperCase(), style: const TextStyle(decoration: TextDecoration.underline)),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SearchBox -- Sharp Input
// ─────────────────────────────────────────────────────────────────────────────
class SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;

  const SearchBox({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = 'SEARCH...',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(fontWeight: FontWeight.w800),
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.search, color: theme.colorScheme.onSurface),
        hintText: hint.toUpperCase(),
        isDense: true,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// StatusBadge -- blocky
// ─────────────────────────────────────────────────────────────────────────────
class StatusBadge extends StatelessWidget {
  final String text;
  final Color? color;

  const StatusBadge({super.key, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppUi.statusColor(text);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c,
        border: Border.all(color: Colors.black, width: 2),
      ),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: Colors.black,
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// InfoRow -- Simple & clean
// ─────────────────────────────────────────────────────────────────────────────
class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const InfoRow(
      {super.key, required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AppMoneyInputFormatter extends TextInputFormatter {
  const AppMoneyInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    final isNegative = raw.trim().startsWith('-');
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      return const TextEditingValue(
          text: '', selection: TextSelection.collapsed(offset: 0));
    }
    final cursorOffset = newValue.selection.baseOffset.clamp(0, raw.length);
    final digitsBeforeCursor =
        raw.substring(0, cursorOffset).replaceAll(RegExp(r'[^0-9]'), '').length;
    final formatted =
        '${isNegative ? '-' : ''}${AppUi.formatThousands(digits)}';
    final nextOffset = _offsetAfterDigitCount(formatted, digitsBeforeCursor);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
  }

  int _offsetAfterDigitCount(String text, int digitCount) {
    if (digitCount <= 0) return text.startsWith('-') ? 1 : 0;
    var seen = 0;
    for (var i = 0; i < text.length; i++) {
      if (RegExp(r'[0-9]').hasMatch(text[i])) {
        seen++;
        if (seen >= digitCount) return i + 1;
      }
    }
    return text.length;
  }
}
