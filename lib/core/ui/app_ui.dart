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
// App UI helpers and brand colours.
// ─────────────────────────────────────────────────────────────────────────────
class AppUi {
  static const blue = AppTheme.primaryColor;
  static const teal = AppTheme.accentColor;
  static const purple = AppTheme.accentColor;
  static const pink = AppTheme.pinkColor;
  static const green = AppTheme.successColor;
  static const orange = AppTheme.warningColor;
  static const red = AppTheme.dangerColor;

  static const List<Color> playfulPalette = [
    AppTheme.primaryColor,
    AppTheme.accentColor,
    AppTheme.successColor,
    AppTheme.warningColor,
    AppTheme.indigoColor,
    AppTheme.orangeColor,
    AppTheme.accentColor,
  ];

  static BoxDecoration glassDecoration(
    BuildContext context, {
    Color accent = AppTheme.primaryColor,
    double radius = 12,
    double accentOpacity = 0.15,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? theme.cardColor : theme.colorScheme.surface;
    final borderColor =
        (borderColorFor(context, accent)).withOpacity(isDark ? 0.42 : 0.22);

    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: Color.alphaBlend(
        accent.withOpacity(accentOpacity * (isDark ? 0.35 : 0.18)),
        surface,
      ),
      border: Border.all(color: borderColor),
      boxShadow: AppTheme.softShadow(theme.brightness),
    );
  }

  static Color borderColorFor(BuildContext context, [Color? accent]) {
    final theme = Theme.of(context);
    final base = accent ?? theme.colorScheme.outline;
    return theme.brightness == Brightness.dark
        ? Color.alphaBlend(base.withOpacity(0.22), theme.colorScheme.outline)
        : Color.alphaBlend(base.withOpacity(0.18), AppTheme.bgCardBorder);
  }

  static BorderSide softBorderSide(
    BuildContext context, {
    Color? color,
    double width = 0.8,
    double lightOpacity = 0.48,
    double darkOpacity = 0.30,
  }) {
    final theme = Theme.of(context);
    final base = color ?? theme.colorScheme.outlineVariant;
    return BorderSide(
      color: base.withOpacity(
        theme.brightness == Brightness.dark ? darkOpacity : lightOpacity,
      ),
      width: width,
    );
  }

  static BoxDecoration tintedDecoration(
    BuildContext context, {
    required Color color,
    double radius = 12,
    double lightOpacity = 0.08,
    double darkOpacity = 0.12,
    bool shadow = false,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return BoxDecoration(
      color: Color.alphaBlend(
        color.withOpacity(isDark ? darkOpacity : lightOpacity),
        theme.cardColor,
      ),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: color.withOpacity(isDark ? 0.24 : 0.16),
        width: 0.8,
      ),
      boxShadow: shadow ? AppTheme.softShadow(theme.brightness) : null,
    );
  }

  static BoxDecoration modernCardDecoration(
    BuildContext context, {
    double radius = 16,
    Color? borderColor,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBorder = borderColor ??
        theme.colorScheme.outlineVariant.withOpacity(isDark ? 0.3 : 0.5);
    return BoxDecoration(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: cardBorder, width: 0.8),
      boxShadow: AppTheme.softShadow(theme.brightness),
    );
  }

  static RoundedRectangleBorder modernShape(
    BuildContext context, {
    double radius = 16,
    Color? borderColor,
  }) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: softBorderSide(context, color: borderColor),
    );
  }

  static Color mutedText(BuildContext context, [double opacity = 0.88]) {
    final theme = Theme.of(context);
    if (theme.brightness == Brightness.light) {
      return AppTheme.textSecondary;
    }
    final safeOpacity = opacity < 0.88 ? 0.88 : opacity;
    return theme.colorScheme.onSurface.withOpacity(safeOpacity);
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
    return formatWibDateTime(value);
  }

  static String formatWibDateTime(dynamic value) {
    if (value == null) return '-';
    final parsed =
        value is DateTime ? value : DateTime.tryParse(value.toString());
    if (parsed == null) return '-';
    final wib = parsed.toUtc().add(const Duration(hours: 7));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(wib.day)}/${two(wib.month)}/${wib.year} ${two(wib.hour)}:${two(wib.minute)} WIB';
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

  static void showSnack(
    String message, {
    bool isError = false,
    String? title,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = rootNavigatorKey.currentContext;
      if (context == null) return;

      final dialogTitle = title ??
          (isError ? 'Perhatian / Kendala' : 'Informasi');

      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            elevation: 16,
            backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isError
                          ? (isDark ? const Color(0xFF450A0A) : const Color(0xFFFEF2F2))
                          : (isDark ? const Color(0xFF075985) : const Color(0xFFF0F9FF)),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isError ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
                      color: isError
                          ? (isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626))
                          : (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7)),
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    dialogTitle,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: isError
                          ? (isDark ? const Color(0xFFF87171) : const Color(0xFFB91C1C))
                          : (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1)),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155),
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: FilledButton.styleFrom(
                        backgroundColor: isError
                            ? (isDark ? const Color(0xFFDC2626) : const Color(0xFFB91C1C))
                            : const Color(0xFF4F46E5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text(
                        'Mengerti',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
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

  const FuturisticLoader({super.key, this.message, this.size = 44});

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
            child: SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: theme.colorScheme.primary,
                backgroundColor: theme.colorScheme.outlineVariant.withOpacity(
                  theme.brightness == Brightness.dark ? 0.28 : 0.52,
                ),
              ),
            ),
          ),
          if (widget.message != null) ...[
            const SizedBox(height: 16),
            Text(
              widget.message!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.68),
                fontWeight: FontWeight.w600,
                fontSize: 13,
                letterSpacing: 0,
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

  const ShimmerCard({super.key, this.height = 80, this.borderRadius = 16});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: theme.colorScheme.surfaceVariant.withOpacity(
          theme.brightness == Brightness.dark ? 0.42 : 0.68,
        ),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(
            theme.brightness == Brightness.dark ? 0.28 : 0.46,
          ),
          width: 0.8,
        ),
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
    final muted = theme.colorScheme.onSurface.withOpacity(0.72);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: AppTheme.radiusLg,
        border: Border.all(
            color: theme.colorScheme.outlineVariant
                .withOpacity(isDark ? 0.3 : 0.5),
            width: 0.8),
        boxShadow: AppTheme.softShadow(theme.brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary
                      .withOpacity(isDark ? 0.12 : 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.primary
                        .withOpacity(isDark ? 0.20 : 0.12),
                    width: 0.8,
                  ),
                ),
                child: Icon(icon, color: theme.colorScheme.primary, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: muted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: stats),
          ],
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
    final surface = Color.alphaBlend(
      color.withOpacity(isDark ? 0.12 : 0.08),
      theme.cardColor,
    );

    return Container(
      constraints: const BoxConstraints(minWidth: 92),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: color.withOpacity(isDark ? 0.24 : 0.15), width: 0.8),
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
              color: isDark ? color.withOpacity(0.95) : color,
              fontWeight: FontWeight.w800,
              fontSize: 13.5,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.68),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
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
          gridColor: isDark
              ? Colors.white.withOpacity(0.045)
              : const Color(0xFF2563EB).withOpacity(0.035),
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

    final rect = Offset.zero & size;
    final wash = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF0B1329), Color(0xFF161F30)]
            : const [Color(0xFFF8FAFC), Color(0xFFF1F5F9)],
      ).createShader(rect);
    canvas.drawRect(rect, wash);

    final halo = Paint()
      ..shader = RadialGradient(
        colors: [
          (isDark ? const Color(0xFF3B82F6) : const Color(0xFFBFDBFE))
              .withOpacity(isDark ? 0.08 : 0.22),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(size.width * 0.18, size.height * 0.04),
          radius: size.shortestSide * 0.62,
        ),
      );
    canvas.drawCircle(
      Offset(size.width * 0.18, size.height * 0.04),
      size.shortestSide * 0.62,
      halo,
    );
  }

  @override
  bool shouldRepaint(covariant _GlobalBackdropPainter oldDelegate) =>
      oldDelegate.isDark != isDark || oldDelegate.gridColor != gridColor;
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
    final requested = borderColor;
    final isLegacyContrast =
        requested == Colors.black || requested == Colors.white;
    final cardBorder = requested == null || isLegacyContrast
        ? theme.colorScheme.outlineVariant
            .withOpacity(theme.brightness == Brightness.dark ? 0.3 : 0.5)
        : requested.withOpacity(
            theme.brightness == Brightness.dark ? 0.35 : 0.22,
          );

    final container = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: AppTheme.radiusMd,
        border: Border.all(color: cardBorder, width: 0.8),
        boxShadow: AppTheme.softShadow(theme.brightness),
      ),
      child: Padding(padding: padding, child: child),
    );

    if (onTap == null) return container;

    return Material(
      color: Colors.transparent,
      borderRadius: AppTheme.radiusMd,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppTheme.radiusMd,
        child: container,
      ),
    );
  }
}

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? borderColor;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return NiceCard(
      padding: padding,
      onTap: onTap,
      borderColor: borderColor,
      child: child,
    );
  }
}

class AppResponsiveContainer extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  const AppResponsiveContainer({
    super.key,
    required this.child,
    this.maxWidth = 1180,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final horizontal = width < 600 ? 16.0 : 24.0;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: padding ??
              EdgeInsets.fromLTRB(
                horizontal,
                width < 600 ? 16 : 24,
                horizontal,
                24,
              ),
          child: child,
        ),
      ),
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
    return const FuturisticLoader(message: 'Memuat data...');
  }
}

class AppLoadingState extends LoadingState {
  const AppLoadingState({super.key});
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
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(
                  theme.brightness == Brightness.dark ? 0.18 : 0.10,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, size: 30, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.68),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppEmptyState extends EmptyState {
  const AppEmptyState({
    super.key,
    required super.title,
    required super.subtitle,
    super.icon,
  });
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
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Coba lagi'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AppErrorState extends ErrorState {
  const AppErrorState({
    super.key,
    required super.message,
    super.onRetry,
  });
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
          if (actionText != null && onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(
                actionText!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }
}

class AppSectionHeader extends SectionTitle {
  const AppSectionHeader({
    super.key,
    required super.title,
    super.actionText,
    super.onAction,
  });
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
    this.hint = 'Cari data',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        prefixIcon:
            Icon(Icons.search, color: theme.colorScheme.onSurfaceVariant),
        hintText: hint,
        isDense: true,
      ),
    );
  }
}

class AppTextField extends StatelessWidget {
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final String? labelText;
  final String? hintText;
  final TextInputType? keyboardType;
  final bool obscureText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  const AppTextField({
    super.key,
    this.controller,
    this.onChanged,
    this.labelText,
    this.hintText,
    this.keyboardType,
    this.obscureText = false,
    this.prefixIcon,
    this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: keyboardType,
      obscureText: obscureText,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
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
    final theme = Theme.of(context);
    final c = color ?? AppUi.statusColor(text);
    final isDark = theme.brightness == Brightness.dark;
    final background = Color.alphaBlend(
      c.withOpacity(isDark ? 0.18 : 0.10),
      theme.cardColor,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: c.withOpacity(isDark ? 0.30 : 0.20),
          width: 0.8,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isDark ? c.withOpacity(0.95) : c,
          fontSize: 11,
          fontWeight: FontWeight.w700,
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
              label,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AppMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final Color? color;
  final Widget? trailing;
  final VoidCallback? onTap;

  const AppMetricCard({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.color,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: accent.withOpacity(
                  theme.brightness == Brightness.dark ? 0.18 : 0.10,
                ),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.64),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

enum AppButtonVariant { filled, outlined, text }

class AppButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget? icon;
  final String label;
  final AppButtonVariant variant;

  const AppButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.variant = AppButtonVariant.filled,
  });

  @override
  Widget build(BuildContext context) {
    if (variant == AppButtonVariant.text) {
      return icon == null
          ? TextButton(onPressed: onPressed, child: Text(label))
          : TextButton.icon(
              onPressed: onPressed,
              icon: icon!,
              label: Text(label),
            );
    }
    if (variant == AppButtonVariant.outlined) {
      return icon == null
          ? OutlinedButton(onPressed: onPressed, child: Text(label))
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: icon!,
              label: Text(label),
            );
    }
    return icon == null
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : FilledButton.icon(
            onPressed: onPressed,
            icon: icon!,
            label: Text(label),
          );
  }
}

class AppScaffold extends StatelessWidget {
  final String? title;
  final Widget child;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool centerContent;
  final double maxWidth;

  const AppScaffold({
    super.key,
    this.title,
    required this.child,
    this.actions,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.centerContent = true,
    this.maxWidth = 1180,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: title == null
          ? null
          : AppBar(
              title: Text(title!),
              actions: actions,
            ),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        child: centerContent
            ? AppResponsiveContainer(maxWidth: maxWidth, child: child)
            : child,
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
