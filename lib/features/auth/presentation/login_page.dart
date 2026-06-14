import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
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
          msg.contains('wrong password')) {
        return 'Email atau password salah.';
      }
      return error.message;
    }
    return 'Gagal. Coba lagi.';
  }

  Future<void> _login() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      AppUi.showSnack('Isi semua bidang.');
      return;
    }
    setState(() => _isLoading = true);
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
    } catch (error) {
      AppUi.showSnack(_friendlyAuthError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // ── Hero section ─────────────────────────────────────────────────────────────
  Widget _hero() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            border: Border.all(color: Colors.black, width: 3),
            boxShadow: const [
              BoxShadow(color: Colors.black, offset: Offset(5, 5)),
            ],
          ),
          child: const Icon(Icons.account_balance_rounded, color: Colors.black, size: 42),
        ),
        const SizedBox(height: 28),
        Text(
          'Mobile ERP'.toUpperCase(),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 32,
            fontWeight: FontWeight.w900,
            height: 1,
            letterSpacing: -1,
          ),
        ),
        Text(
          'OMNICHANNEL MANAGEMENT SYSTEM'.toUpperCase(),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: theme.colorScheme.primary,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            height: 1.2,
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
        _previewChip(Icons.trending_up_rounded, 'FINANCE', AppTheme.primaryColor),
        _previewChip(Icons.inventory_2_rounded, 'STOCK', AppTheme.accentColor),
        _previewChip(Icons.store_rounded, 'MARKET', AppTheme.pinkColor),
      ],
    );
  }

  Widget _previewChip(IconData icon, String label, Color color) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? color.withOpacity(0.92) : color.withOpacity(0.22);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: Colors.black, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, size: 0, color: Colors.transparent),
          Icon(icon, size: 16, color: Colors.black),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  // ── Form card ────────────────────────────────────────────────────────────────
  Widget _form() {
    return NiceCard(
      borderColor: Colors.black,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'SYSTEM LOGIN',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 24),
          ),
          const SizedBox(height: 22),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'EMAIL', prefixIcon: Icon(Icons.email)),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _passwordController,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'PASSWORD',
              prefixIcon: const Icon(Icons.lock),
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
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('SYSTEM LOGIN'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RequestAccessPage()),
              );
            },
            child: const Text('REQUEST ACCESS'),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RegisterPage()),
              );
            },
            icon: const Icon(Icons.mail_outline_rounded, size: 16),
            label: const Text('DAFTAR LEWAT UNDANGAN'),
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
                      'AUTHORIZED PERSONNEL ONLY'.toUpperCase(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
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
