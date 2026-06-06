import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/marketplace_providers.dart';
import '../models/marketplace_models.dart';

class MarketplaceRepository {
  final SupabaseClient _client;

  MarketplaceRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  Future<List<MarketplaceAccount>> fetchAccounts() async {
    final response = await _client
        .from('marketplace_accounts')
        .select()
        .order('last_connected_at', ascending: false)
        .range(0, 199);

    return (response as List<dynamic>)
        .map((item) =>
            MarketplaceAccount.fromMap(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<List<LocalProductOption>> fetchProducts() async {
    final response = await _client
        .from('products')
        .select('product_id, kode_sku, nama_barang, stock_saat_ini, status')
        .eq('status', 'active')
        .order('kode_sku')
        .range(0, 199);

    return (response as List<dynamic>)
        .map((item) =>
            LocalProductOption.fromMap(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<List<MarketplaceSkuMap>> fetchSkuMaps({String? accountId}) async {
    var query = _client.from('marketplace_sku_maps').select(
        '*, products!marketplace_sku_maps_product_id_fkey(product_id, kode_sku, nama_barang, stock_saat_ini)');

    if (accountId != null && accountId.isNotEmpty) {
      query = query.eq('marketplace_account_id', accountId);
    }

    final response =
        await query.order('created_at', ascending: false).range(0, 199);

    return (response as List<dynamic>)
        .map((item) =>
            MarketplaceSkuMap.fromMap(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<List<MarketplaceOrder>> fetchOrders({String? accountId}) async {
    var query = _client.from('marketplace_orders').select();

    if (accountId != null && accountId.isNotEmpty) {
      query = query.eq('marketplace_account_id', accountId);
    }

    final response =
        await query.order('order_created_at', ascending: false).range(0, 199);

    return (response as List<dynamic>)
        .map((item) =>
            MarketplaceOrder.fromMap(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<List<MarketplaceFinanceReport>> fetchFinanceReports(
      {String? accountId}) async {
    var query = _client.from('marketplace_finance_reports').select();

    if (accountId != null && accountId.isNotEmpty) {
      query = query.eq('marketplace_account_id', accountId);
    }

    final response =
        await query.order('pulled_at', ascending: false).range(0, 199);

    return (response as List<dynamic>)
        .map((item) => MarketplaceFinanceReport.fromMap(
            Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<List<MarketplaceAbnormal>> fetchAbnormales({String? accountId}) async {
    Future<List<MarketplaceAbnormal>> run(
        {required bool filterByAccount}) async {
      var query = _client.from('marketplace_abnormals').select();

      if (filterByAccount && accountId != null && accountId.isNotEmpty) {
        query = query.eq('marketplace_account_id', accountId);
      }

      final response =
          await query.order('created_at', ascending: false).range(0, 199);

      return (response as List<dynamic>)
          .map((item) => MarketplaceAbnormal.fromMap(
              Map<String, dynamic>.from(item as Map)))
          .toList();
    }

    try {
      return await run(filterByAccount: true);
    } catch (_) {
      // Compatibility fallback for older database view without marketplace_account_id.
      return run(filterByAccount: false);
    }
  }

  Future<void> createSkuMap({
    required String marketplaceAccountId,
    String marketplace = 'tiktok_shop',
    required String productId,
    required String localSku,
    required String remoteProductId,
    required String remoteSkuId,
    required String remoteSellerSku,
    required String remoteSkuName,
    required String warehouseId,
  }) async {
    final userId = _client.auth.currentUser?.id;
    final providerId = MarketplaceProviders.normalize(marketplace);
    if (!MarketplaceProviders.isSupported(providerId)) {
      throw Exception('Marketplace belum didukung.');
    }
    await _client.from('marketplace_sku_maps').insert({
      'marketplace_account_id': marketplaceAccountId,
      'marketplace': providerId,
      'product_id': productId,
      'local_sku': localSku,
      'remote_product_id': remoteProductId,
      'remote_sku_id': remoteSkuId,
      'remote_seller_sku': remoteSellerSku.isEmpty ? null : remoteSellerSku,
      'remote_sku_name': remoteSkuName.isEmpty ? null : remoteSkuName,
      'warehouse_id': warehouseId.isEmpty ? null : warehouseId,
      'is_stock_sync_enabled': true,
      'status': 'active',
      'created_by': userId,
      'updated_by': userId,
    });
  }

  Future<void> setSkuMapStatus(String mapId, String status) async {
    await _client.from('marketplace_sku_maps').update({
      'status': status,
      'updated_by': _client.auth.currentUser?.id,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('map_id', mapId);
  }

  @Deprecated('Use invokeMarketplaceAction with an explicit marketplace.')
  Future<Map<String, dynamic>> invokeTikTok(
    String action, {
    Map<String, dynamic>? params,
  }) async {
    return invokeMarketplaceAction(
      action,
      marketplace: MarketplaceProviders.tiktokShop.id,
      params: params,
    );
  }

  Future<Map<String, dynamic>> invokeMarketplaceAction(
    String action, {
    String marketplace = 'tiktok_shop',
    Map<String, dynamic>? params,
  }) async {
    final providerId = MarketplaceProviders.normalize(marketplace);
    if (!MarketplaceProviders.isSupported(providerId)) {
      throw Exception('Marketplace belum didukung.');
    }

    final payload = <String, dynamic>{
      ...?params,
      'marketplace': providerId,
    };

    final endpoint = switch (action) {
      'pull_products' => 'marketplace-product-pull',
      'pull_orders' => 'marketplace-order-pull',
      'sync_stock' || 'sync_all_stock' => 'marketplace-stock-sync-worker',
      _ => null,
    };

    if (endpoint == null) {
      throw Exception('Aksi marketplace belum tersedia di layanan baru.');
    }

    final response = await _client.functions.invoke(endpoint, body: payload);

    final data = response.data;
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      if (map['ok'] == false) {
        throw Exception(map['message'] ?? 'Request marketplace gagal.');
      }
      return map;
    }

    return <String, dynamic>{'ok': true, 'data': data};
  }
}
