class MarketplaceStockSyncItem {
  final String marketplaceSkuMapId;
  final String tenantId;
  final String? marketplaceAccountId;
  final String marketplace;
  final String accountStoreAlias;
  final String? accountShopName;
  final String shopRegion;
  final String accountStatus;
  final String? productId;
  final String localSku;
  final String? localBarcode;
  final String localProductName;
  final num localStock;
  final String localProductStatus;
  final String? marketplaceProductId;
  final String? marketplaceSkuId;
  final String? marketplaceSku;
  final String marketplaceSellerSku;
  final String marketplaceProductName;
  final String? marketplaceVariationName;
  final bool syncEnabled;
  final String mappingStatus;
  final DateTime? mappingLastSyncAt;
  final String? mappingLastError;
  final String? lastSyncLogId;
  final String? lastSyncStatus;
  final String? lastSyncReason;
  final num lastRequestedStock;
  final String? lastErrorMessage;
  final DateTime? lastQueuedAt;
  final DateTime? lastFinishedAt;
  final bool canQueue;
  final bool apiReady;
  final String nextAction;

  const MarketplaceStockSyncItem({
    required this.marketplaceSkuMapId,
    required this.tenantId,
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.accountStoreAlias,
    required this.accountShopName,
    required this.shopRegion,
    required this.accountStatus,
    required this.productId,
    required this.localSku,
    required this.localBarcode,
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
    required this.mappingStatus,
    required this.mappingLastSyncAt,
    required this.mappingLastError,
    required this.lastSyncLogId,
    required this.lastSyncStatus,
    required this.lastSyncReason,
    required this.lastRequestedStock,
    required this.lastErrorMessage,
    required this.lastQueuedAt,
    required this.lastFinishedAt,
    required this.canQueue,
    required this.apiReady,
    required this.nextAction,
  });

  factory MarketplaceStockSyncItem.fromMap(Map<String, dynamic> map) {
    return MarketplaceStockSyncItem(
      marketplaceSkuMapId: _text(map['marketplace_sku_map_id']),
      tenantId: _text(map['tenant_id']),
      marketplaceAccountId: _nullableText(map['marketplace_account_id']),
      marketplace: _text(map['marketplace'], '-'),
      accountStoreAlias: _text(map['account_store_alias'], '-'),
      accountShopName: _nullableText(map['account_shop_name']),
      shopRegion: _text(map['shop_region'], 'ID'),
      accountStatus: _text(map['account_status'], 'active'),
      productId: _nullableText(map['product_id']),
      localSku: _text(map['local_sku'], '-'),
      localBarcode: _nullableText(map['local_barcode']),
      localProductName: _text(map['local_product_name'], '-'),
      localStock: _num(map['local_stock']),
      localProductStatus: _text(map['local_product_status'], '-'),
      marketplaceProductId: _nullableText(map['marketplace_product_id']),
      marketplaceSkuId: _nullableText(map['marketplace_sku_id']),
      marketplaceSku: _nullableText(map['marketplace_sku']),
      marketplaceSellerSku: _text(map['marketplace_seller_sku'], '-'),
      marketplaceProductName: _text(map['marketplace_product_name'], '-'),
      marketplaceVariationName: _nullableText(map['marketplace_variation_name']),
      syncEnabled: _bool(map['sync_enabled'], true),
      mappingStatus: _text(map['mapping_status'], 'active'),
      mappingLastSyncAt: _date(map['mapping_last_sync_at']),
      mappingLastError: _nullableText(map['mapping_last_error']),
      lastSyncLogId: _nullableText(map['last_sync_log_id']),
      lastSyncStatus: _nullableText(map['last_sync_status']),
      lastSyncReason: _nullableText(map['last_sync_reason']),
      lastRequestedStock: _num(map['last_requested_stock']),
      lastErrorMessage: _nullableText(map['last_error_message']),
      lastQueuedAt: _date(map['last_queued_at']),
      lastFinishedAt: _date(map['last_finished_at']),
      canQueue: _bool(map['can_queue'], false),
      apiReady: _bool(map['api_ready'], false),
      nextAction: _text(map['next_action'], '-'),
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


  String get marketplaceVariantText {
    final raw = marketplaceVariationName?.trim();
    if (raw == null || raw.isEmpty || raw == '-' || raw.toLowerCase() == 'null') {
      return 'Default variant';
    }
    return raw;
  }

  String get marketplaceProductWithVariant {
    final product = marketplaceProductName.trim().isEmpty ? '-' : marketplaceProductName.trim();
    final variant = marketplaceVariantText.trim();
    if (variant.isEmpty || variant.toLowerCase().startsWith('default variant')) {
      return product;
    }
    return '$product · $variant';
  }

  String get marketplaceSkuIdentity {
    final seller = marketplaceSellerSku.trim();
    final sku = marketplaceSku?.trim();
    final id = marketplaceSkuId?.trim();

    if (seller.isNotEmpty && seller != '-') return seller;
    if (sku != null && sku.isNotEmpty) return sku;
    if (id != null && id.isNotEmpty) return id;
    return '-';
  }

  String get apiIdentityText {
    final productId = marketplaceProductId?.trim();
    final skuId = marketplaceSkuId?.trim();
    return 'Product ID: ${productId == null || productId.isEmpty ? '-' : productId} · SKU ID: ${skuId == null || skuId.isEmpty ? '-' : skuId}';
  }

  String get safeAccountName {
    final alias = accountStoreAlias.trim();
    if (alias.isNotEmpty && alias != '-') return alias;

    final name = accountShopName?.trim();
    if (name != null && name.isNotEmpty) return name;

    return marketplaceLabel;
  }

  String get stockText {
    if (localStock % 1 == 0) return localStock.toStringAsFixed(0);
    return localStock.toStringAsFixed(2);
  }

  bool get hasLastError {
    final error = lastErrorMessage?.trim() ?? mappingLastError?.trim() ?? '';
    return error.isNotEmpty;
  }

  String? get visibleError {
    final last = lastErrorMessage?.trim();
    if (last != null && last.isNotEmpty) return last;

    final mapping = mappingLastError?.trim();
    if (mapping != null && mapping.isNotEmpty) return mapping;

    return null;
  }
}

String _text(dynamic value, [String fallback = '']) {
  final raw = value?.toString().trim() ?? '';
  return raw.isEmpty ? fallback : raw;
}

String? _nullableText(dynamic value) {
  final raw = value?.toString().trim() ?? '';
  return raw.isEmpty ? null : raw;
}

num _num(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  return num.tryParse(value.toString()) ?? 0;
}

bool _bool(dynamic value, bool fallback) {
  if (value == null) return fallback;
  if (value is bool) return value;
  final raw = value.toString().trim().toLowerCase();
  if (raw == 'true' || raw == '1' || raw == 'yes') return true;
  if (raw == 'false' || raw == '0' || raw == 'no') return false;
  return fallback;
}

DateTime? _date(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value.toLocal();
  return DateTime.tryParse(value.toString())?.toLocal();
}
