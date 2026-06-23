import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../../core/constants/app_roles.dart';
import '../../../repositories/user_repository.dart';
import '../../admin/presentation/platform_owner_dashboard.dart';
import '../../dashboard/presentation/dashboard_page.dart';
import '../../finance/services/finance_local_cache.dart';
import 'register_page.dart';
import 'request_access_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _obscure = true;

  late final AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _friendlyAuthError(dynamic error) {
    if (error is AuthException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('invalid login') ||
          msg.contains('invalid credentials') ||
          msg.contains('wrong password') ||
          msg.contains('username tidak ditemukan') ||
          msg.contains('email/username atau password salah')) {
        return 'Email/Username atau password salah.';
      }
      return error.message;
    }
    return 'Gagal. Coba lagi.';
  }

  Future<String> _resolveUsername(String username) async {
    final response = await _client.functions.invoke(
      'admin-auth',
      body: {
        'action': 'lookup_username',
        'username': username,
      },
    );
    if (response.status == 200) {
      final data = response.data;
      if (data is Map && data.containsKey('email')) {
        return data['email'].toString();
      }
    }
    throw const AuthException('Email/Username atau password salah.');
  }

  Future<void> _login() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final input = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    if (input.isEmpty || password.isEmpty) {
      AppUi.showSnack('Isi semua bidang.');
      return;
    }
    setState(() => _isLoading = true);
    try {
      String resolvedEmail = input;
      if (!input.contains('@')) {
        try {
          resolvedEmail = await _resolveUsername(input);
        } catch (_) {
          throw const AuthException('Email/Username atau password salah.');
        }
      }

      final authResponse = await _client.auth
          .signInWithPassword(email: resolvedEmail, password: password);

      if (authResponse.session == null || authResponse.user == null) {
        AppUi.showSnack('Login berhasil tapi sesi belum aktif. Coba lagi.');
        return;
      }

      final appUser = await UserRepository().getCurrentUserProfile();
      if (!mounted) return;

      if (appUser == null) {
        AppUi.showSnack(
          'Login berhasil, tapi profil aplikasi belum tersedia.',
        );
        return;
      }

      if (!appUser.isActive) {
        AppUi.showSnack('Akun tidak aktif. Hubungi admin.');
        await _client.auth.signOut();
        return;
      }

      await FinanceLocalCache.clearAllFinanceCaches();

      final target = appUser.role == AppRole.platformOwner
          ? const PlatformOwnerDashboard()
          : DashboardPage(currentUser: appUser);

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => target),
        (_) => false,
      );
    } catch (error) {
      AppUi.showSnack(_friendlyAuthError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Hero section ─────────────────────────────────────────────────────────────
  Widget _hero() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(isDark ? 0.12 : 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color:
                  theme.colorScheme.primary.withOpacity(isDark ? 0.22 : 0.12),
              width: 0.8,
            ),
            boxShadow: AppTheme.softShadow(theme.brightness),
          ),
          child: Icon(
            Icons.account_balance_rounded,
            color: theme.colorScheme.primary,
            size: 38,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Mobile ERP',
          textAlign: TextAlign.center,
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.05,
          ),
        ),
        Text(
          'Omnichannel management system',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 24),
        _miniPreviewStrip(),
      ],
    );
  }

  Widget _miniPreviewStrip() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: [
        _previewChip(
            Icons.trending_up_rounded, 'Finance', AppTheme.primaryColor),
        _previewChip(Icons.inventory_2_rounded, 'Stock', AppTheme.accentColor),
        _previewChip(Icons.store_rounded, 'Market', AppTheme.indigoColor),
      ],
    );
  }

  Widget _previewChip(IconData icon, String label, Color color) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background = Color.alphaBlend(
      color.withOpacity(isDark ? 0.12 : 0.08),
      theme.cardColor,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color: color.withOpacity(isDark ? 0.24 : 0.15), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 0, color: Colors.transparent),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: isDark ? color.withOpacity(0.95) : color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // ── Form card ────────────────────────────────────────────────────────────────
  Widget _form() {
    return NiceCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Masuk ke workspace',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
          ),
          const SizedBox(height: 22),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
                labelText: 'Email atau username',
                prefixIcon: Icon(Icons.email)),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _passwordController,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: Icon(Icons.lock),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _isLoading ? null : _login,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text('Masuk'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RequestAccessPage()),
              );
            },
            child: Text('Lihat paket dan request access'),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RegisterPage()),
              );
            },
            icon: Icon(Icons.mail_outline_rounded, size: 16),
            label: Text('Daftar lewat undangan'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppGlobalBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  children: [
                    _hero(),
                    const SizedBox(height: 32),
                    _form(),
                    const SizedBox(height: 24),
                    Text(
                      'Akses khusus pengguna terdaftar',
                      style: TextStyle(
                        color: AppUi.mutedText(context, 0.92).withOpacity(0.5),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
