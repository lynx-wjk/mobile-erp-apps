import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/attendance_log.dart';

class AbsensiRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<void> submitAbsensi({
    required String attendanceType,
    required double latitude,
    required double longitude,
    required double? accuracy,
    required String? catatan,
  }) async {
    await _client.rpc(
      'register_attendance',
      params: {
        'p_attendance_type': attendanceType,
        'p_latitude': latitude,
        'p_longitude': longitude,
        'p_accuracy': accuracy,
        'p_catatan': catatan,
      },
    );
  }

  Future<List<AbsensiLog>> getMyAbsensiLogs() async {
    final currentUser = _client.auth.currentUser;

    if (currentUser == null) {
      return [];
    }

    final data = await _client
        .from('attendance_logs')
        .select('''
          attendance_id,
          user_id,
          nama_user,
          email_user,
          role_id,
          attendance_type,
          latitude,
          longitude,
          accuracy,
          catatan,
          created_at
        ''')
        .eq('user_id', currentUser.id)
        .order('created_at', ascending: false)
        .limit(50);

    return (data as List)
        .map(
          (item) => AbsensiLog.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }

  Future<List<AbsensiLog>> getAllAbsensiLogs() async {
    final data = await _client.rpc(
      'admin_list_attendance_logs',
      params: {
        'p_limit': 200,
      },
    );

    return (data as List)
        .map(
          (item) => AbsensiLog.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }
}