import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/production_progress.dart';

class ProductionProgressRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<ProductionProgress>> getProgressList() async {
    final data = await _client.rpc('list_production_progress');

    return (data as List)
        .map(
          (item) => ProductionProgress.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }

  Future<void> createProgress({
    required String productName,
    required String? sku,
    required double qty,
    required String? sourceNote,
    required DateTime? targetFinishDate,
    required String? proofUrl,
    required String? catatan,
  }) async {
    await _client.rpc(
      'create_production_progress',
      params: {
        'p_product_name': productName,
        'p_sku': sku,
        'p_qty': qty,
        'p_source_note': sourceNote,
        'p_target_finish_date':
        targetFinishDate?.toIso8601String().substring(0, 10),
        'p_proof_url': proofUrl,
        'p_catatan': catatan,
      },
    );
  }

  Future<void> updateStatus({
    required String progressId,
    required String status,
    required String? proofUrl,
    required String? catatan,
  }) async {
    await _client.rpc(
      'update_production_progress_status',
      params: {
        'p_progress_id': progressId,
        'p_status': status,
        'p_proof_url': proofUrl,
        'p_catatan': catatan,
      },
    );
  }
}