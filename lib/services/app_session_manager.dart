import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';

class AppSessionManager {
  AppSessionManager._();
  static final AppSessionManager instance = AppSessionManager._();

  /// 12 Hours auto-logout timeout
  static const Duration timeoutDuration = Duration(hours: 12);

  static const String _keyLastActivityMs = 'app_session_last_activity_ms';
  static const String _keyLoginMs = 'app_session_login_ms';
  static const String _keyUserId = 'app_session_user_id';

  DateTime _lastActivityTime = DateTime.now();
  DateTime? _lastPersistedTime;
  bool _isLoggingOut = false;

  DateTime get lastActivityTime => _lastActivityTime;

  /// Called when user signs in or when session becomes active
  Future<void> recordLogin(String userId) async {
    final now = DateTime.now();
    _lastActivityTime = now;
    _lastPersistedTime = now;
    _isLoggingOut = false;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyLoginMs, now.millisecondsSinceEpoch);
      await prefs.setInt(_keyLastActivityMs, now.millisecondsSinceEpoch);
      await prefs.setString(_keyUserId, userId);
    } catch (e) {
      debugPrint('[AppSessionManager] Error recording login: $e');
    }
  }

  /// Called on any user interaction (tap, move, scroll, keypress)
  void recordActivity() {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return;

    final now = DateTime.now();
    _lastActivityTime = now;

    // Throttle disk persistence: at most once every 15 seconds
    if (_lastPersistedTime == null ||
        now.difference(_lastPersistedTime!).inSeconds >= 15) {
      _lastPersistedTime = now;
      _persistLastActivity(now.millisecondsSinceEpoch);
    }
  }

  Future<void> _persistLastActivity(int timestampMs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyLastActivityMs, timestampMs);
    } catch (e) {
      debugPrint('[AppSessionManager] Error persisting activity: $e');
    }
  }

  /// Check if the session has expired (either in memory or from persistent storage)
  Future<bool> isSessionExpired() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return false;

    final now = DateTime.now();

    // 1. In-memory check
    if (now.difference(_lastActivityTime) >= timeoutDuration) {
      return true;
    }

    // 2. Persistent storage check (crucial for page reloads / app restarts / tab reopen)
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedLastActivityMs = prefs.getInt(_keyLastActivityMs);
      final savedLoginMs = prefs.getInt(_keyLoginMs);
      final savedUserId = prefs.getString(_keyUserId);

      // If user changed or no record exists yet, initialize it
      if (savedUserId != null && savedUserId != session.user.id) {
        await recordLogin(session.user.id);
        return false;
      }

      if (savedLastActivityMs == null) {
        // Fallback to login time if last activity missing
        if (savedLoginMs != null) {
          final diff = now.millisecondsSinceEpoch - savedLoginMs;
          if (diff >= timeoutDuration.inMilliseconds) {
            return true;
          }
        }
        await recordLogin(session.user.id);
        return false;
      }

      final diffMs = now.millisecondsSinceEpoch - savedLastActivityMs;
      if (diffMs >= timeoutDuration.inMilliseconds) {
        return true;
      }

      // Update in-memory time from storage if storage is newer
      final savedDate =
          DateTime.fromMillisecondsSinceEpoch(savedLastActivityMs);
      if (savedDate.isAfter(_lastActivityTime)) {
        _lastActivityTime = savedDate;
      }
    } catch (e) {
      debugPrint('[AppSessionManager] Error checking expiration: $e');
    }

    return false;
  }

  /// Perform logout due to 12-hour expiration
  Future<void> handleSessionExpired({String? customMessage}) async {
    if (_isLoggingOut) return;
    _isLoggingOut = true;

    try {
      await clearSession();
      await Supabase.instance.client.auth.signOut();
    } catch (e) {
      debugPrint('[AppSessionManager] Error signing out on expiry: $e');
    } finally {
      _lastActivityTime = DateTime.now();
      _lastPersistedTime = null;
      _isLoggingOut = false;
    }

    final message = customMessage ??
        'Sesi Anda telah berakhir setelah 12 jam. Silakan login kembali.';

    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent.shade700,
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Clear persistent session info on manual logout
  Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyLastActivityMs);
      await prefs.remove(_keyLoginMs);
      await prefs.remove(_keyUserId);
    } catch (e) {
      debugPrint('[AppSessionManager] Error clearing session: $e');
    }
  }

  /// Periodically called by background timer
  Future<void> checkAndEnforceSession() async {
    if (_isLoggingOut) return;
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return;

    final expired = await isSessionExpired();
    if (expired) {
      await handleSessionExpired();
    }
  }
}
