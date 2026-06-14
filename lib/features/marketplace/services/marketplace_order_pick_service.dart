import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/marketplace_return_review_item.dart';

class MarketplaceOrderPickResult {
  final bool ok;
  final String message;
  final int processed;
  final int failed;
  final bool orderReadyToFinalize;

  const MarketplaceOrderPickResult({
    required this.ok,
    required this.message,
    required this.processed,
    required this.failed,
    this.orderReadyToFinalize = false,
  });

  factory MarketplaceOrderPickResult.fromMap(Map<String, dynamic> map) {
    return MarketplaceOrderPickResult(
      ok: map['ok'] == true,
      message: map['message']?.toString() ?? 'Selesai.',
      processed: _asInt(map['processed'] ?? map['scanned_qty']),
      failed: _asInt(map['failed']),
      orderReadyToFinalize: map['order_ready_to_finalize'] == true,
    );
  }
}

class MarketplaceResiOrderResult {
  final bool ok;
  final String message;
  final String? marketplaceOrderId;
  final String? marketplace;
  final String? accountName;
  final String? externalOrderId;
  final String? trackingNumber;
  final String? marketplaceNote;
  final bool orderReadyToFinalize;
  final int processed;
  final int failed;

  const MarketplaceResiOrderResult({
    required this.ok,
    required this.message,
    this.marketplaceOrderId,
    this.marketplace,
    this.accountName,
    this.externalOrderId,
    this.trackingNumber,
    this.marketplaceNote,
    this.orderReadyToFinalize = false,
    this.processed = 0,
    this.failed = 0,
  });

  factory MarketplaceResiOrderResult.fromMap(Map<String, dynamic> map) {
    return MarketplaceResiOrderResult(
      ok: map['ok'] == true,
      message: map['message']?.toString() ?? 'Selesai.',
      marketplaceOrderId: map['marketplace_order_id']?.toString(),
      marketplace: map['marketplace']?.toString(),
      accountName: (map['account_name'] ?? map['shop_name'])?.toString(),
      externalOrderId: map['external_order_id']?.toString(),
      trackingNumber: map['tracking_number']?.toString(),
      marketplaceNote:
          (map['marketplace_note'] ?? map['seller_note'])?.toString(),
      orderReadyToFinalize: map['order_ready_to_finalize'] == true,
      processed: _asInt(map['processed'] ?? map['scanned_qty']),
      failed: _asInt(map['failed']),
    );
  }
}

class MarketplaceReturnReviewResult {
  final bool ok;
  final String message;
  final String reviewStatus;
  final String stockInStatus;
  final int stockInMovementCount;
  final int prepared;
  final int processed;
  final int failed;

  const MarketplaceReturnReviewResult({
    required this.ok,
    required this.message,
    required this.reviewStatus,
    required this.stockInStatus,
    required this.stockInMovementCount,
    this.prepared = 0,
    this.processed = 0,
    this.failed = 0,
  });

  factory MarketplaceReturnReviewResult.fromMap(Map<String, dynamic> map) {
    return MarketplaceReturnReviewResult(
      ok: map['ok'] == true,
      message: map['message']?.toString() ?? 'Review selesai.',
      reviewStatus: map['review_status']?.toString() ?? '-',
      stockInStatus: map['stock_in_status']?.toString() ?? '-',
      stockInMovementCount: _asInt(map['stock_in_movement_count']),
      prepared: _asInt(map['prepared']),
      processed: _asInt(map['processed']),
      failed: _asInt(map['failed']),
    );
  }
}

class MarketplaceOrderPickService {
  MarketplaceOrderPickService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<MarketplaceOrderPickResult> scanOrderItemBarcode({
    required String tenantId,
    required String marketplaceOrderId,
    required String scanCode,
  }) async {
    final response = await _client.rpc(
      'marketplace_scan_order_item_barcode',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_order_id': marketplaceOrderId,
        'p_scan_code': scanCode,
      },
    );

    return MarketplaceOrderPickResult.fromMap(_rpcMap(response));
  }

  Future<MarketplaceOrderPickResult> finalizeScannedOrderStockOut({
    required String tenantId,
    required String marketplaceOrderId,
  }) async {
    final response = await _client.rpc(
      'marketplace_finalize_scanned_order_stock_out',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_order_id': marketplaceOrderId,
      },
    );

    return MarketplaceOrderPickResult.fromMap(_rpcMap(response));
  }

  Future<MarketplaceResiOrderResult> findOrderByResi({
    required String tenantId,
    required String resiCode,
  }) async {
    final response = await _client.rpc(
      'marketplace_find_order_by_resi',
      params: {
        'p_tenant_id': tenantId,
        'p_resi_code': resiCode,
      },
    );

    return MarketplaceResiOrderResult.fromMap(_rpcMap(response));
  }

  Future<MarketplaceResiOrderResult> activateOrderForScanByResi({
    required String tenantId,
    required String resiCode,
  }) async {
    final response = await _client.rpc(
      'marketplace_activate_order_for_scan_by_resi',
      params: {
        'p_tenant_id': tenantId,
        'p_resi_code': resiCode,
      },
    );

    return MarketplaceResiOrderResult.fromMap(_rpcMap(response));
  }

  Future<MarketplaceResiOrderResult> scanOrderItemByResi({
    required String tenantId,
    required String resiCode,
    required String scanCode,
  }) async {
    final response = await _client.rpc(
      'marketplace_scan_order_item_by_resi',
      params: {
        'p_tenant_id': tenantId,
        'p_resi_code': resiCode,
        'p_scan_code': scanCode,
      },
    );

    return MarketplaceResiOrderResult.fromMap(_rpcMap(response));
  }

  Future<MarketplaceResiOrderResult> scanOrderItemManualByResi({
    required String tenantId,
    required String resiCode,
    required String marketplaceOrderItemId,
  }) async {
    final response = await _client.rpc(
      'marketplace_scan_order_item_manual_by_resi',
      params: {
        'p_tenant_id': tenantId,
        'p_resi_code': resiCode,
        'p_marketplace_order_item_id': marketplaceOrderItemId,
      },
    );

    return MarketplaceResiOrderResult.fromMap(_rpcMap(response));
  }

  Future<MarketplaceResiOrderResult> scanOrderItemManualOverrideByResi({
    required String tenantId,
    required String resiCode,
    required String marketplaceOrderItemId,
    required String actualProductId,
    String? overrideNote,
  }) async {
    final response = await _client.rpc(
      'marketplace_scan_order_item_manual_override_by_resi',
      params: {
        'p_tenant_id': tenantId,
        'p_resi_code': resiCode,
        'p_marketplace_order_item_id': marketplaceOrderItemId,
        'p_actual_product_id': actualProductId,
        'p_override_note': overrideNote,
      },
    );

    return MarketplaceResiOrderResult.fromMap(_rpcMap(response));
  }

  Future<MarketplaceResiOrderResult> finalizeScannedOrderStockOutByResi({
    required String tenantId,
    required String resiCode,
  }) async {
    final response = await _client.rpc(
      'marketplace_finalize_scanned_order_stock_out_by_resi_guarded',
      params: {
        'p_tenant_id': tenantId,
        'p_resi_code': resiCode,
      },
    );

    return MarketplaceResiOrderResult.fromMap(_rpcMap(response));
  }

  Future<MarketplaceReturnReviewResult> refreshReturnReviews({
    required String tenantId,
    String? marketplaceAccountId,
  }) async {
    final accountId = marketplaceAccountId?.trim();

    // Pull after-sales return/refund case dari TikTok dulu.
    // Kalau function belum dideploy / scope TikTok belum aktif, jangan matikan UI review lama.
    try {
      await _client.functions.invoke(
        'marketplace-return-refund-pull',
        body: {
          'tenant_id': tenantId,
          'marketplace_account_id':
              accountId == null || accountId.isEmpty ? null : accountId,
          'days_back': 90,
          'limit': 20,
          'max_pages': 3,
        },
      );
    } catch (_) {
      // RPC di bawah tetap jalan untuk cancel/order-status lama.
    }

    final response = await _client.rpc(
      'marketplace_prepare_return_item_reviews',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id':
            accountId == null || accountId.isEmpty || accountId == 'all'
                ? null
                : accountId,
      },
    );

    return MarketplaceReturnReviewResult.fromMap(_rpcMap(response));
  }

  Future<List<MarketplaceReturnReviewItem>> listReturnReviews({
    required String tenantId,
    String? marketplaceAccountId,
    String status = 'all',
    int limit = 150,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    await refreshReturnReviews(
        tenantId: tenantId, marketplaceAccountId: marketplaceAccountId);

    dynamic query = _client
        .from('marketplace_return_reviews_public')
        .select()
        .eq('tenant_id', tenantId);

    final accountId = marketplaceAccountId?.trim();
    if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
      query = query.eq('marketplace_account_id', accountId);
    }

    final cleanStatus = status.trim();
    if (cleanStatus.isNotEmpty && cleanStatus != 'all') {
      query = query.eq('review_status', cleanStatus);
    }

    final safeLimit = limit.clamp(1, 150).toInt();
    final data = await query
        .order('order_updated_at', ascending: false)
        .range(0, safeLimit - 1);

    return (data as List<dynamic>)
        .map((item) => MarketplaceReturnReviewItem.fromMap(
            Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<MarketplaceReturnReviewResult> submitReturnItemReview({
    required String tenantId,
    required String marketplaceOrderItemId,
    required String packageMatchStatus,
    required String itemCondition,
    required bool canRestock,
    String? note,
  }) async {
    final response = await _client.rpc(
      'marketplace_submit_return_item_review',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_order_item_id': marketplaceOrderItemId,
        'p_package_match_status': packageMatchStatus,
        'p_item_condition': itemCondition,
        'p_can_restock': canRestock,
        'p_note': note,
      },
    );

    return MarketplaceReturnReviewResult.fromMap(_rpcMap(response));
  }

  Future<List<Map<String, dynamic>>> findReturnByResi({
    required String resi,
  }) async {
    final response = await _client.rpc(
      'marketplace_find_return_by_resi_for_app',
      params: <String, dynamic>{'p_resi': resi.trim()},
    );
    final payload = _rpcMap(response);
    final rows = payload['rows'];
    if (rows is! List) return <Map<String, dynamic>>[];
    return rows
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  /// Backward compatible method. Keputusan yang sama diterapkan ke semua item pending pada order.
  Future<MarketplaceReturnReviewResult> submitReturnReview({
    required String tenantId,
    required String marketplaceOrderId,
    required String packageMatchStatus,
    required String itemCondition,
    required bool canRestock,
    String? note,
  }) async {
    final response = await _client.rpc(
      'marketplace_submit_return_review',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_order_id': marketplaceOrderId,
        'p_package_match_status': packageMatchStatus,
        'p_item_condition': itemCondition,
        'p_can_restock': canRestock,
        'p_note': note,
      },
    );

    return MarketplaceReturnReviewResult.fromMap(_rpcMap(response));
  }

  Map<String, dynamic> _rpcMap(dynamic response) {
    if (response is Map) return Map<String, dynamic>.from(response);
    if (response is List && response.isNotEmpty && response.first is Map) {
      return Map<String, dynamic>.from(response.first as Map);
    }
    return {
      'ok': false,
      'message': response?.toString() ?? 'Respons server belum sesuai.'
    };
  }
}

int _asInt(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}
