import 'dart:async';

import 'package:flutter/foundation.dart';

/// Global guard untuk mencegah double click / spam action.
///
/// Pakai ini untuk action yang menjalankan:
/// - navigasi
/// - RPC / API
/// - simpan / hapus / sync
/// - refresh / export / import
///
/// Jangan dipakai untuk typing, scroll, drag chart, atau input realtime.
class AppActionGuard {
  AppActionGuard._();

  static final Map<String, DateTime> _lastRunAt = <String, DateTime>{};
  static final Set<String> _runningKeys = <String>{};

  static const Duration defaultThrottle = Duration(milliseconds: 750);

  static bool isRunning(String key) => _runningKeys.contains(_normalize(key));

  static Future<void> run(
    String key,
    FutureOr<void> Function() action, {
    Duration throttle = defaultThrottle,
    bool dropWhileRunning = true,
  }) async {
    final normalized = _normalize(key);
    final now = DateTime.now();
    final lastRun = _lastRunAt[normalized];

    if (lastRun != null && now.difference(lastRun) < throttle) {
      if (kDebugMode) {
        debugPrint('AppActionGuard dropped fast repeat: $normalized');
      }
      return;
    }

    if (dropWhileRunning && _runningKeys.contains(normalized)) {
      if (kDebugMode) {
        debugPrint('AppActionGuard dropped running action: $normalized');
      }
      return;
    }

    _lastRunAt[normalized] = now;
    _runningKeys.add(normalized);

    try {
      await Future<void>.sync(action);
    } finally {
      _runningKeys.remove(normalized);
    }
  }

  static VoidCallback tap(
    String key,
    FutureOr<void> Function() action, {
    Duration throttle = defaultThrottle,
    bool dropWhileRunning = true,
  }) {
    return () {
      unawaited(
        run(
          key,
          action,
          throttle: throttle,
          dropWhileRunning: dropWhileRunning,
        ),
      );
    };
  }

  static String _normalize(String key) {
    final trimmed = key.trim();
    return trimmed.isEmpty ? 'global-action' : trimmed;
  }

  static void clear() {
    _lastRunAt.clear();
    _runningKeys.clear();
  }
}
