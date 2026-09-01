import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_session_manager.dart';

class AuthService {
  final SupabaseClient _client = Supabase.instance.client;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Session? get currentSession => _client.auth.currentSession;

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    final response = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    if (response.user != null) {
      await AppSessionManager.instance.recordLogin(response.user!.id);
    }
  }

  Future<void> signOut() async {
    await AppSessionManager.instance.clearSession();
    await _client.auth.signOut();
  }
}