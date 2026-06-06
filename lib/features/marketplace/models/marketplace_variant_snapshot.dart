class MarketplaceVariantSnapshot {
  final String marketplaceVariantSnapshotId;
  final String tenantId;
  final String marketplaceAccountId;
  final String marketplace;
  final String accountStoreAlias;
  final String? accountShopName;
  final String shopRegion;
  final String marketplaceProductId;
  final String marketplaceSkuId;
  final String? marketplaceSkuCode;
  final String? marketplaceSellerSku;
  final String marketplaceProductName;
  final String marketplaceVariantName;
  final String? productStatus;
  final String? skuStatus;
  final double priceAmount;
  final String? priceCurrency;
  final int stockQuantity;
  final String? marketplaceSkuMapId;
  final String? mappedProductId;
  final String? mappedLocalSku;
  final String? mappedLocalProductName;
  final double mappedLocalStock;
  final bool mappedSyncEnabled;
  final String mapStatus;
  final DateTime? lastSeenAt;
  final DateTime? updatedAt;

  const MarketplaceVariantSnapshot({
    required this.marketplaceVariantSnapshotId,
    required this.tenantId,
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.accountStoreAlias,
    required this.accountShopName,
    required this.shopRegion,
    required this.marketplaceProductId,
    required this.marketplaceSkuId,
    required this.marketplaceSkuCode,
    required this.marketplaceSellerSku,
    required this.marketplaceProductName,
    required this.marketplaceVariantName,
    required this.productStatus,
    required this.skuStatus,
    required this.priceAmount,
    required this.priceCurrency,
    required this.stockQuantity,
    required this.marketplaceSkuMapId,
    required this.mappedProductId,
    required this.mappedLocalSku,
    required this.mappedLocalProductName,
    required this.mappedLocalStock,
    required this.mappedSyncEnabled,
    required this.mapStatus,
    required this.lastSeenAt,
    required this.updatedAt,
  });

  factory MarketplaceVariantSnapshot.fromMap(Map<String, dynamic> map) {
    return MarketplaceVariantSnapshot(
      marketplaceVariantSnapshotId: map['marketplace_variant_snapshot_id']?.toString() ?? '',
      tenantId: map['tenant_id']?.toString() ?? '',
      marketplaceAccountId: map['marketplace_account_id']?.toString() ?? '',
      marketplace: _firstText(map, const ['marketplace', 'account_marketplace']) ?? '',
      accountStoreAlias: _firstText(map, const ['account_store_alias', 'store_alias', 'store_label', 'account_name']) ?? '-',
      accountShopName: _firstText(map, const ['account_shop_name', 'shop_name']),
      shopRegion: _firstText(map, const ['shop_region', 'region']) ?? 'ID',
      marketplaceProductId: map['marketplace_product_id']?.toString() ?? '',
      marketplaceSkuId: map['marketplace_sku_id']?.toString() ?? '',
      marketplaceSkuCode: _firstText(map, const ['marketplace_sku_code', 'sku_code', 'seller_sku_code']),
      marketplaceSellerSku: _firstText(map, const ['marketplace_seller_sku', 'seller_sku', 'sellerSku'], rawKeys: const ['seller_sku', 'sellerSku', 'seller_sku_id', 'sku_code']),
      marketplaceProductName: _firstText(map, const ['marketplace_product_name', 'product_name', 'item_name', 'title', 'name'], rawKeys: const ['product_name', 'item_name', 'title', 'name']) ?? (map['marketplace_product_id']?.toString() ?? '-'),
      marketplaceVariantName: _firstText(map, const ['marketplace_variant_name', 'variant_name', 'model_name', 'sku_name'], rawKeys: const ['variant_name', 'model_name', 'sku_name', 'name']) ?? 'Default variant',
      productStatus: _firstText(map, const ['product_status', 'status']),
      skuStatus: _firstText(map, const ['sku_status', 'variant_status']),
      priceAmount: _toDouble(map['price_amount']),
      priceCurrency: _nullIfEmpty(map['price_currency']?.toString()),
      stockQuantity: _toInt(map['stock_quantity'] ?? map['stock'] ?? map['stock_on_hand']),
      marketplaceSkuMapId: _firstText(map, const ['marketplace_sku_map_id', 'map_id']),
      mappedProductId: _firstText(map, const ['mapped_product_id', 'local_product_id', 'product_id']),
      mappedLocalSku: _firstText(map, const ['mapped_local_sku', 'local_sku', 'kode_sku']),
      mappedLocalProductName: _firstText(map, const ['mapped_local_product_name', 'local_product_name', 'local_name', 'nama_barang']),
      mappedLocalStock: _toDouble(map['mapped_local_stock'] ?? map['local_stock'] ?? map['stock_saat_ini']),
      mappedSyncEnabled: _toBool(map['mapped_sync_enabled'] ?? map['sync_enabled'] ?? map['is_stock_sync_enabled']),
      mapStatus: _firstText(map, const ['map_status', 'mapping_status']) ?? ((_toBool(map['is_mapped'])) ? 'active' : 'unmapped'),
      lastSeenAt: _date(map['last_seen_at']),
      updatedAt: _date(map['updated_at']),
    );
  }

  bool get isMapped => marketplaceSkuMapId != null && marketplaceSkuMapId!.trim().isNotEmpty;
  bool get isActiveMarketplaceRecord =>
      !_statusLooksInactive(productStatus) && !_statusLooksInactive(skuStatus);


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

  String get displaySku {
    final seller = marketplaceSellerSku?.trim();
    if (seller != null && seller.isNotEmpty) return seller;
    final code = marketplaceSkuCode?.trim();
    if (code != null && code.isNotEmpty) return code;
    return marketplaceSkuId;
  }

  String get displayVariant {
    final variant = marketplaceVariantName.trim();
    if (variant.isEmpty) return 'Default variant';
    return variant;
  }

  List<String> get displayVariantParts {
    final variant = displayVariant.trim();
    if (variant.toLowerCase().startsWith('default variant')) return const [];
    return variant
        .split(RegExp(r'\s*[•|]\s*'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  bool get isDefaultVariantLabel => displayVariantParts.isEmpty;

  String get mappedLabel {
    if (!isMapped) return 'Belum mapped';
    final sku = mappedLocalSku?.trim();
    final name = mappedLocalProductName?.trim();
    if (sku != null && sku.isNotEmpty && name != null && name.isNotEmpty) {
      return '$sku · $name';
    }
    if (sku != null && sku.isNotEmpty) return sku;
    return 'Mapped';
  }

  static bool _statusLooksInactive(String? value) {
    final clean = value
        ?.trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    if (clean == null || clean.isEmpty || clean == 'null') return false;

    const inactiveMarkers = [
      'delete',
      'deleted',
      'archive',
      'archived',
      'deactivate',
      'deactivated',
      'inactive',
      'disable',
      'disabled',
      'suspend',
      'suspended',
      'draft',
      'rejected',
      'banned',
      'freeze',
      'frozen',
      'unpublish',
      'unpublished',
      'offline',
      'closed',
      'blocked',
    ];

    return inactiveMarkers.any((marker) => clean.contains(marker));
  }


  static String? _firstText(
    Map<String, dynamic> map,
    List<String> keys, {
    List<String> rawKeys = const [],
  }) {
    for (final key in keys) {
      final value = _nullIfEmpty(map[key]?.toString());
      if (value != null) return value;
    }

    for (final containerKey in const ['raw_variant', 'raw_product', 'raw']) {
      final raw = map[containerKey];
      if (raw is Map) {
        for (final key in rawKeys) {
          final value = _nullIfEmpty(raw[key]?.toString());
          if (value != null) return value;
        }
      }
    }

    return null;
  }

  static bool _toBool(dynamic value) {
    if (value == true) return true;
    if (value == false || value == null) return false;
    final clean = value.toString().trim().toLowerCase();
    return clean == 'true' || clean == '1' || clean == 'yes' || clean == 'active' || clean == 'enabled';
  }

  static String? _nullIfEmpty(String? value) {
    final clean = value?.trim();
    if (clean == null || clean.isEmpty || clean == 'null') return null;
    return clean;
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static int _toInt(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  static DateTime? _date(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }
}
