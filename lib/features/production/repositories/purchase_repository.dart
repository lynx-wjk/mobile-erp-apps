import 'package:supabase_flutter/supabase_flutter.dart';

import '../../master_data/models/supplier.dart';
import '../models/purchase_request.dart';

class PurchaseRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<Supplier>> getSuppliers() async {
    final data = await _client.rpc('list_suppliers');

    return (data as List)
        .map(
          (item) => Supplier.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }

  Future<List<PurchaseRequest>> getPurchaseRequests() async {
    final data = await _client.rpc('list_purchase_requests');

    return (data as List)
        .map(
          (item) => PurchaseRequest.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }

  Future<List<PurchaseRequestItem>> getPurchaseItems(String requestId) async {
    final data = await _client.rpc(
      'list_purchase_request_items',
      params: {
        'p_request_id': requestId,
      },
    );

    return (data as List)
        .map(
          (item) => PurchaseRequestItem.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }

  Future<void> createPurchaseRequest({
    required String? supplierId,
    required String supplierName,
    required String? nomorNota,
    required DateTime tanggalBeli,
    required String? notaUrl,
    required String? catatan,
    required List<PurchaseItemInput> items,
  }) async {
    await _client.rpc(
      'create_purchase_request',
      params: {
        'p_supplier_id': supplierId,
        'p_supplier_name': supplierName,
        'p_nomor_nota': nomorNota,
        'p_tanggal_beli': tanggalBeli.toIso8601String().substring(0, 10),
        'p_nota_url': notaUrl,
        'p_catatan': catatan,
        'p_items': items.map((item) => item.toJson()).toList(),
      },
    );
  }

  Future<void> verifyPurchase({
    required String requestId,
    required String status,
    required String? financeNote,
  }) async {
    await _client.rpc(
      'finance_verify_purchase',
      params: {
        'p_request_id': requestId,
        'p_status': status,
        'p_finance_note': financeNote,
      },
    );
  }
}