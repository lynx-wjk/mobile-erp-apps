import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppVisualMode {
  girl,
  man;

  String get storageValue => name;

  String get label => this == AppVisualMode.girl ? 'Girl Light' : 'Man Dark';

  String get shortLabel => this == AppVisualMode.girl ? 'Girl' : 'Man';

  static AppVisualMode fromValue(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized == 'man' || normalized == 'dark') return AppVisualMode.man;
    return AppVisualMode.girl;
  }
}

class AppThemeModeController {
  static const _storageKey = 'app_visual_mode_v1';
  static final ValueNotifier<AppVisualMode> mode =
      ValueNotifier<AppVisualMode>(AppVisualMode.girl);

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    mode.value = AppVisualMode.fromValue(prefs.getString(_storageKey));
  }

  static Future<void> setMode(AppVisualMode nextMode) async {
    if (mode.value == nextMode) return;
    mode.value = nextMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, nextMode.storageValue);
  }

  static Future<void> toggle() async {
    await setMode(
      mode.value == AppVisualMode.girl ? AppVisualMode.man : AppVisualMode.girl,
    );
  }
}
