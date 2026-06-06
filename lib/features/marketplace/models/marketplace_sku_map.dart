class MarketplaceSkuMap {
  final String marketplaceSkuMapId;
  final String tenantId;
  final String? marketplaceAccountId;
  final String marketplace;
  final String accountStoreAlias;
  final String? accountShopName;
  final String shopRegion;
  final String? productId;
  final String localSku;
  final String? localProductSku;
  final String? localProductBarcode;
  final String localProductName;
  final double localStock;
  final String localProductStatus;
  final String? marketplaceProductId;
  final String? marketplaceSkuId;
  final String? marketplaceSku;
  final String marketplaceSellerSku;
  final String marketplaceProductName;
  final String? marketplaceVariationName;
  final bool syncEnabled;
  final String status;
  final DateTime? lastSyncAt;
  final String? lastError;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const MarketplaceSkuMap({
    required this.marketplaceSkuMapId,
    required this.tenantId,
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.accountStoreAlias,
    required this.accountShopName,
    required this.shopRegion,
    required this.productId,
    required this.localSku,
    required this.localProductSku,
    required this.localProductBarcode,
    required this.localProductName,
    required this.localStock,
    required this.localProductStatus,
    required this.marketplaceProductId,
    required this.marketplaceSkuId,
    required this.marketplaceSku,
    required this.marketplaceSellerSku,
    required this.marketplaceProductName,
    required this.marketplaceVariationName,
    required this.syncEnabled,
    required this.status,
    required this.lastSyncAt,
    required this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MarketplaceSkuMap.fromMap(Map<String, dynamic> map) {
    return MarketplaceSkuMap(
      marketplaceSkuMapId: map['marketplace_sku_map_id']?.toString() ?? '',
      tenantId: map['tenant_id']?.toString() ?? '',
      marketplaceAccountId: _nullableText(map['marketplace_account_id']),
      marketplace: map['marketplace']?.toString() ?? '-',
      accountStoreAlias: map['account_store_alias']?.toString() ?? '-',
      accountShopName: _nullableText(map['account_shop_name']),
      shopRegion: map['shop_region']?.toString() ?? 'ID',
      productId: _nullableText(map['product_id']),
      localSku: map['local_sku']?.toString() ?? '-',
      localProductSku: _nullableText(map['local_product_sku']),
      localProductBarcode: _nullableText(map['local_product_barcode']),
      localProductName: map['local_product_name']?.toString() ?? 'Produk lokal belum dipilih',
      localStock: _toDouble(map['local_stock']),
      localProductStatus: map['local_product_status']?.toString() ?? '-',
      marketplaceProductId: _nullableText(map['marketplace_product_id']),
      marketplaceSkuId: _nullableText(map['marketplace_sku_id']),
      marketplaceSku: _nullableText(map['marketplace_sku']),
      marketplaceSellerSku: map['marketplace_seller_sku']?.toString() ?? '-',
      marketplaceProductName: map['marketplace_product_name']?.toString() ?? '-',
      marketplaceVariationName: _nullableText(map['marketplace_variation_name']),
      syncEnabled: map['sync_enabled'] == true || map['sync_enabled']?.toString() == 'true',
      status: map['status']?.toString() ?? 'active',
      lastSyncAt: _date(map['last_sync_at']),
      lastError: _nullableText(map['last_error']),
      createdAt: _date(map['created_at']),
      updatedAt: _date(map['updated_at']),
    );
  }

  String get marketplaceLabel {
    switch (marketplace) {
      case 'tiktok_shop':
        return 'TikTok Shop';
      case 'shopee':
        return 'Shopee';
      default:
        return marketplace;
    }
  }

  String get syncLabel => syncEnabled ? 'Sync ON' : 'Sync OFF';

  bool get hasLocalProduct => productId != null && productId!.trim().isNotEmpty;

  static String? _nullableText(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') return null;
    return text;
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static DateTime? _date(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }
}
