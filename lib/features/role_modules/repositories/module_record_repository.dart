import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/module_record.dart';

class ModuleRecordRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<ModuleRecord>> getRecords({
    required String moduleKey,
  }) async {
    final data = await _client.rpc(
      'list_module_records',
      params: {
        'p_module_key': moduleKey,
      },
    );

    return (data as List)
        .map(
          (item) => ModuleRecord.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }

  Future<void> createRecord({
    required String moduleKey,
    required String title,
    required String? description,
    required double amount,
    required String? assignedRole,
    required String status,
    required String? proofUrl,
  }) async {
    await _client.rpc(
      'create_module_record',
      params: {
        'p_module_key': moduleKey,
        'p_title': title,
        'p_description': description,
        'p_amount': amount,
        'p_assigned_role': assignedRole,
        'p_status': status,
        'p_proof_url': proofUrl,
      },
    );
  }

  Future<void> updateStatus({
    required String recordId,
    required String status,
    required String? note,
    required String? proofUrl,
  }) async {
    await _client.rpc(
      'update_module_record_status',
      params: {
        'p_record_id': recordId,
        'p_status': status,
        'p_description_append': note,
        'p_proof_url': proofUrl,
      },
    );
  }
}