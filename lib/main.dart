import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/ui/app_ui.dart';
import 'core/theme/app_theme_mode.dart';
import 'features/auth/presentation/auth_gate.dart';
import 'services/app_session_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    String? supabaseUrl;
    String? supabaseAnonKey;

    if (!kIsWeb) {
      try {
        await dotenv.load(fileName: '.env');
        supabaseUrl = dotenv.env['SUPABASE_URL'];
        supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
      } catch (e) {
        debugPrint('dotenv load fallback: $e');
      }
    }

    supabaseUrl = (supabaseUrl != null && supabaseUrl.trim().isNotEmpty)
        ? supabaseUrl.trim()
        : const String.fromEnvironment('SUPABASE_URL',
            defaultValue: 'https://mdhproduction.com');
    supabaseAnonKey =
        (supabaseAnonKey != null && supabaseAnonKey.trim().isNotEmpty)
            ? supabaseAnonKey.trim()
            : const String.fromEnvironment('SUPABASE_ANON_KEY',
                defaultValue:
                    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzgxMzY1OTkwLCJleHAiOjQxMDI0NDQ4MDB9.4ksHkp45OfOVH--8p5ajWnfKUwwDDLUNYbsVV8uFh5Y');

    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      throw Exception('Missing SUPABASE_URL or SUPABASE_ANON_KEY configuration');
    }

    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        autoRefreshToken: true,
      ),
    );

    await AppThemeModeController.init();

    runApp(const MyApp());
  } catch (e, stackTrace) {
    debugPrint('Fatal initialization error: $e\n$stackTrace');
    runApp(StartupErrorApp(errorMessage: e.toString()));
  }
}

final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppVisualMode>(
      valueListenable: AppThemeModeController.mode,
      builder: (context, visualMode, _) {
        return MaterialApp(
          title: 'Mobile ERP',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: visualMode == AppVisualMode.man
              ? ThemeMode.dark
              : ThemeMode.light,
          navigatorKey: rootNavigatorKey,
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          builder: (context, child) {
            final media = MediaQuery.of(context);
            final textScale = media.textScaleFactor.clamp(0.92, 1.0).toDouble();
            return MediaQuery(
              data: media.copyWith(textScaleFactor: textScale),
              child: AppGlobalBackdrop(
                visualMode: visualMode,
                child: _InactivityLogoutWatcher(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );
          },
          home: const AuthGate(),
        );
      },
    );
  }
}

class _InactivityLogoutWatcher extends StatefulWidget {
  final Widget child;

  const _InactivityLogoutWatcher({required this.child});

  @override
  State<_InactivityLogoutWatcher> createState() =>
      _InactivityLogoutWatcherState();
}

class _InactivityLogoutWatcherState extends State<_InactivityLogoutWatcher> {
  static const Duration _checkInterval = Duration(seconds: 30);

  final SupabaseClient _client = Supabase.instance.client;

  Timer? _timer;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();

    final currentSession = _client.auth.currentSession;
    if (currentSession != null) {
      AppSessionManager.instance.recordActivity();
    }

    _authSubscription = _client.auth.onAuthStateChange.listen((state) {
      final hasSession = state.session != null;
      if (hasSession) {
        AppSessionManager.instance.recordLogin(state.session!.user.id);
      } else {
        AppSessionManager.instance.clearSession();
      }
    });

    _timer = Timer.periodic(_checkInterval, (_) {
      AppSessionManager.instance.checkAndEnforceSession();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => AppSessionManager.instance.recordActivity(),
      onPointerMove: (_) => AppSessionManager.instance.recordActivity(),
      onPointerUp: (_) => AppSessionManager.instance.recordActivity(),
      onPointerSignal: (_) => AppSessionManager.instance.recordActivity(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          AppSessionManager.instance.recordActivity();
          return false;
        },
        child: widget.child,
      ),
    );
  }
}

class StartupErrorApp extends StatelessWidget {
  final String errorMessage;

  const StartupErrorApp({
    super.key,
    required this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mobile ERP Error',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: Scaffold(
        backgroundColor: AppTheme.bgDeep,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppTheme.bgCardBorder,
                  ),
                  boxShadow: AppTheme.softShadow(Brightness.light),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Aplikasi belum bisa dibuka',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      errorMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
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
