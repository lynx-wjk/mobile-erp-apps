import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:app_links/app_links.dart';

import '../../../models/app_user.dart';
import '../../../core/constants/app_roles.dart';
import '../../../repositories/user_repository.dart';
import '../../../services/auth_service.dart';
import '../../dashboard/presentation/dashboard_page.dart';
import 'login_page.dart';
import 'register_page.dart';
import '../../admin/presentation/platform_owner_dashboard.dart';
import '../../../core/ui/app_ui.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initDeepLinks() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _handleDeepLink(initialUri);
      }
    } catch (e) {
      debugPrint('Error getting initial link: $e');
    }

    _linkSubscription = _appLinks.uriLinkStream.listen(
      (uri) {
        _handleDeepLink(uri);
      },
      onError: (err) {
        debugPrint('Error listening to deep links: $err');
      },
    );
  }

  void _handleDeepLink(Uri uri) {
    debugPrint('Received deep link: $uri');
    final isMobileScheme = uri.scheme == 'mobileerp' && uri.host == 'register';
    final isWebPath = uri.path.contains('/register');

    if (isMobileScheme || isWebPath) {
      final token = uri.queryParameters['invite'];
      if (token != null && token.isNotEmpty) {
        rootNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (context) => RegisterPage(initialToken: token),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check for web deep link '/register'
    final uri = Uri.base;
    final isRegisterPath = uri.path.contains('/register');
    if (isRegisterPath) {
      final token = uri.queryParameters['invite'];
      return RegisterPage(initialToken: token);
    }

    final authService = AuthService();

    return StreamBuilder<AuthState>(
      stream: authService.authStateChanges,
      builder: (context, snapshot) {
        final session = authService.currentSession;

        if (session == null) {
          return const LoginPage();
        }

        return FutureBuilder<AppUser?>(
          future: UserRepository().getCurrentUserProfile(),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (profileSnapshot.hasError) {
              return _ProfileLoadErrorPage(
                message: profileSnapshot.error.toString(),
              );
            }

            final user = profileSnapshot.data;

            if (user == null) {
              return const _AutoLogoutPage(
                title: 'Akses akun belum tersedia',
                message:
                    'Profil pengguna belum terdaftar. Silakan hubungi admin untuk aktivasi akun.',
              );
            }

            if (!user.isActive) {
              return const _AutoLogoutPage(
                title: 'Akun tidak aktif',
                message:
                    'Akun Anda saat ini tidak aktif. Silakan hubungi admin untuk bantuan.',
              );
            }

            if (user.role == AppRole.platformOwner) {
              return const PlatformOwnerDashboard();
            }

            return DashboardPage(currentUser: user);
          },
        );
      },
    );
  }
}

class _ProfileLoadErrorPage extends StatelessWidget {
  final String message;

  const _ProfileLoadErrorPage({
    required this.message,
  });

  Future<void> _logout() async {
    await AuthService().signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil Belum Dapat Dimuat'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: NiceCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Sesi login aktif, tetapi profil pengguna belum dapat dimuat',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.68),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const AuthGate()),
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Coba Lagi'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AutoLogoutPage extends StatefulWidget {
  final String title;
  final String message;

  const _AutoLogoutPage({
    required this.title,
    required this.message,
  });

  @override
  State<_AutoLogoutPage> createState() => _AutoLogoutPageState();
}

class _AutoLogoutPageState extends State<_AutoLogoutPage> {
  @override
  void initState() {
    super.initState();
    _logout();
  }

  Future<void> _logout() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await AuthService().signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Akses Tidak Tersedia'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: NiceCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.68),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                const Text('Mengakhiri sesi...'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
