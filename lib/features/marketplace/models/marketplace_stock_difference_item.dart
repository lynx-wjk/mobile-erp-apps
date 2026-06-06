class MarketplaceStockDifferenceItem {
  final String marketplaceSkuMapId;
  final String tenantId;
  final String? marketplaceAccountId;
  final String marketplace;
  final String accountStoreAlias;
  final String? accountShopName;
  final String localSku;
  final String localProductName;
  final num localStock;
  final String localProductStatus;
  final String? marketplaceProductId;
  final String? marketplaceSkuId;
  final String? marketplaceSellerSku;
  final String marketplaceProductName;
  final String? marketplaceVariationName;
  final int? marketplaceStock;
  final num stockDifference;
  final String differenceStatus;
  final String differenceLabel;
  final bool syncEnabled;
  final String mappingStatus;
  final String? productStatus;
  final String? skuStatus;
  final DateTime? lastSeenAt;
  final DateTime? updatedAt;

  const MarketplaceStockDifferenceItem({
    required this.marketplaceSkuMapId,
    required this.tenantId,
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.accountStoreAlias,
    required this.accountShopName,
    required this.localSku,
    required this.localProductName,
    required this.localStock,
    required this.localProductStatus,
    required this.marketplaceProductId,
    required this.marketplaceSkuId,
    required this.marketplaceSellerSku,
    required this.marketplaceProductName,
    required this.marketplaceVariationName,
    required this.marketplaceStock,
    required this.stockDifference,
    required this.differenceStatus,
    required this.differenceLabel,
    required this.syncEnabled,
    required this.mappingStatus,
    required this.productStatus,
    required this.skuStatus,
    required this.lastSeenAt,
    required this.updatedAt,
  });

  factory MarketplaceStockDifferenceItem.fromMap(Map<String, dynamic> map) {
    final status = _text(map['difference_status'], '-');
    return MarketplaceStockDifferenceItem(
      marketplaceSkuMapId: _text(map['marketplace_sku_map_id']),
      tenantId: _text(map['tenant_id']),
      marketplaceAccountId: _nullableText(map['marketplace_account_id']),
      marketplace: _text(map['marketplace'], '-'),
      accountStoreAlias: _text(map['account_store_alias'], '-'),
      accountShopName: _nullableText(map['account_shop_name']),
      localSku: _text(map['local_sku'], '-'),
      localProductName: _text(map['local_product_name'], '-'),
      localStock: _num(map['local_stock']),
      localProductStatus: _text(map['local_product_status'], '-'),
      marketplaceProductId: _nullableText(map['marketplace_product_id']),
      marketplaceSkuId: _nullableText(map['marketplace_sku_id']),
      marketplaceSellerSku: _nullableText(map['marketplace_seller_sku']),
      marketplaceProductName: _text(map['marketplace_product_name'], '-'),
      marketplaceVariationName: _nullableText(map['marketplace_variation_name']),
      marketplaceStock: _nullableInt(map['marketplace_stock']),
      stockDifference: _num(map['stock_difference']),
      differenceStatus: status,
      differenceLabel: _text(map['difference_label'], _labelForStatus(status)),
      syncEnabled: _bool(map['sync_enabled'], true),
      mappingStatus: _text(map['mapping_status'], 'active'),
      productStatus: _nullableText(map['product_status']),
      skuStatus: _nullableText(map['sku_status']),
      lastSeenAt: _date(map['last_seen_at']),
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

  String get safeAccountName {
    final alias = accountStoreAlias.trim();
    if (alias.isNotEmpty && alias != '-') return alias;
    final shop = accountShopName?.trim();
    if (shop != null && shop.isNotEmpty && shop != '-') return shop;
    return marketplaceLabel;
  }

  String get marketplaceVariantText {
    final variant = marketplaceVariationName?.trim();
    if (variant == null || variant.isEmpty || variant == '-' || variant.toLowerCase() == 'null') {
      return 'Default variant';
    }
    return variant;
  }

  String get localStockText => _formatNum(localStock);
  String get marketplaceStockText => marketplaceStock == null ? '-' : marketplaceStock.toString();
  String get differenceText => _formatNum(stockDifference);

  bool get canSync => differenceStatus == 'different' || differenceStatus == 'unknown_marketplace_stock';
  bool get isMatched => differenceStatus == 'matched';
  bool get needsAttention => !isMatched;
}

String _labelForStatus(String status) {
  switch (status) {
    case 'matched':
      return 'Matched';
    case 'different':
      return 'Different';
    case 'not_mapped':
      return 'Not Mapped';
    case 'sync_disabled':
      return 'Sync Disabled';
    case 'marketplace_inactive':
      return 'Marketplace Inactive';
    case 'unknown_marketplace_stock':
      return 'Unknown Stock';
    case 'local_inactive':
      return 'Local Inactive';
    default:
      return status.replaceAll('_', ' ');
  }
}

String _text(dynamic value, [String fallback = '']) {
  final raw = value?.toString().trim() ?? '';
  return raw.isEmpty ? fallback : raw;
}

String? _nullableText(dynamic value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty || raw == 'null') return null;
  return raw;
}

num _num(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  return num.tryParse(value.toString()) ?? 0;
}

int? _nullableInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
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

String _formatNum(num value) {
  if (value % 1 == 0) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}
