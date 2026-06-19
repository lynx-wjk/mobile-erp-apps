import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class FinanceLocalCache {
  static const String _prefix = 'finance_cache_live_20260619_v29_scope';
  static const int defaultTtlDays = 90;

  static String _dateOnly(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String snapshotKey({
    required DateTime start,
    required DateTime end,
    required String marketplace,
    required String accountId,
    required String tenantId,
    required String tab,
    required int page,
    required String cacheVersion,
  }) {
    return '$_prefix:snapshot:$tenantId:${_dateOnly(start)}:${_dateOnly(end)}:$marketplace:$accountId:$tab:$page:$cacheVersion';
  }

  static String skuDetailKey({
    required DateTime start,
    required DateTime end,
    required String marketplace,
    required String accountId,
    required String tenantId,
    required String tab,
    required int page,
    required String cacheVersion,
    required String sku,
  }) {
    final safeSku = base64Url.encode(utf8.encode(sku.trim().toLowerCase()));
    return '$_prefix:sku_detail:$tenantId:${_dateOnly(start)}:${_dateOnly(end)}:$marketplace:$accountId:$tab:$page:$cacheVersion:$safeSku';
  }

  static String skuPageKey({
    required DateTime start,
    required DateTime end,
    required String marketplace,
    required String accountId,
    required String tenantId,
    required String payoutFilter,
    required int page,
    required String cacheVersion,
  }) {
    return '$_prefix:sku_page:$tenantId:${_dateOnly(start)}:${_dateOnly(end)}:$marketplace:$accountId:$payoutFilter:$page:$cacheVersion';
  }

  static Future<Map<String, dynamic>?> readJson(String key,
      {int ttlDays = defaultTtlDays}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final envelope = Map<String, dynamic>.from(decoded);
      final savedAt = DateTime.tryParse(envelope['saved_at']?.toString() ?? '');
      if (savedAt == null) return null;
      if (DateTime.now().difference(savedAt).inDays > ttlDays) {
        await prefs.remove(key);
        return null;
      }
      final data = envelope['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
      return envelope;
    } catch (_) {
      await prefs.remove(key);
      return null;
    }
  }

  static Future<void> writeJson(String key, Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final envelope = <String, dynamic>{
      'saved_at': DateTime.now().toIso8601String(),
      'data': data,
    };
    await prefs.setString(key, jsonEncode(envelope));
  }

  static Future<void> writeRows(
      String key, List<Map<String, dynamic>> rows) async {
    await writeJson(key, {'rows': rows});
  }

  static Future<List<Map<String, dynamic>>?> readRows(String key,
      {int ttlDays = defaultTtlDays}) async {
    final data = await readJson(key, ttlDays: ttlDays);
    if (data == null) return null;
    final rows = data['rows'];
    if (rows is! List) return null;
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  static Future<void> removeWhere(bool Function(String key) test) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(test).toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  static Future<void> clearAllFinanceCaches() async {
    await removeWhere((key) => key.startsWith('finance_cache_'));
  }

  static Future<void> cleanup({int ttlDays = defaultTtlDays}) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith('finance_cache_'))
        .toList();
    for (final key in keys) {
      if (!key.startsWith(_prefix)) {
        await prefs.remove(key);
        continue;
      }
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final savedAt =
            DateTime.tryParse(decoded['saved_at']?.toString() ?? '');
        if (savedAt == null || now.difference(savedAt).inDays > ttlDays) {
          await prefs.remove(key);
        }
      } catch (_) {
        await prefs.remove(key);
      }
    }
  }
}
