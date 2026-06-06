class MarketplaceReturnReviewItem {
  final String marketplaceReturnItemReviewId;
  final String marketplaceOrderItemId;
  final String marketplaceOrderId;
  final String tenantId;
  final String marketplaceAccountId;
  final String marketplace;
  final String accountStoreAlias;
  final String accountShopName;
  final String externalOrderId;
  final String? orderSn;
  final String? trackingNumber;
  final String orderStatus;
  final String orderStatusLabel;
  final String orderStatusGroup;
  final String stockActionStatus;
  final String reviewStatus;
  final String packageMatchStatus;
  final String itemCondition;
  final bool? canRestock;
  final String stockInStatus;
  final int stockInMovementCount;
  final String? note;
  final String? reviewedAt;
  final String? orderCreatedAt;
  final String? orderUpdatedAt;
  final String? pulledAt;
  final String? lastError;
  final String? marketplaceProductName;
  final String? marketplaceVariantName;
  final String? sellerSku;
  final String? marketplaceSkuId;
  final String? mappedLocalSku;
  final String? mappedProductId;
  final String? localProductName;
  final String? localBarcode;
  final num localStock;
  final int itemCount;
  final num qtyTotal;
  final num reservedQtyTotal;
  final num scannedQtyTotal;
  final num stockOutQtyTotal;
  final num itemReturnedQty;
  final String itemStockActionStatus;
  final String itemReturnReviewStatus;

  const MarketplaceReturnReviewItem({
    required this.marketplaceReturnItemReviewId,
    required this.marketplaceOrderItemId,
    required this.marketplaceOrderId,
    required this.tenantId,
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.accountStoreAlias,
    required this.accountShopName,
    required this.externalOrderId,
    required this.orderSn,
    required this.trackingNumber,
    required this.orderStatus,
    required this.orderStatusLabel,
    required this.orderStatusGroup,
    required this.stockActionStatus,
    required this.reviewStatus,
    required this.packageMatchStatus,
    required this.itemCondition,
    required this.canRestock,
    required this.stockInStatus,
    required this.stockInMovementCount,
    required this.note,
    required this.reviewedAt,
    required this.orderCreatedAt,
    required this.orderUpdatedAt,
    required this.pulledAt,
    required this.lastError,
    required this.marketplaceProductName,
    required this.marketplaceVariantName,
    required this.sellerSku,
    required this.marketplaceSkuId,
    required this.mappedLocalSku,
    required this.mappedProductId,
    required this.localProductName,
    required this.localBarcode,
    required this.localStock,
    required this.itemCount,
    required this.qtyTotal,
    required this.reservedQtyTotal,
    required this.scannedQtyTotal,
    required this.stockOutQtyTotal,
    required this.itemReturnedQty,
    required this.itemStockActionStatus,
    required this.itemReturnReviewStatus,
  });

  factory MarketplaceReturnReviewItem.fromMap(Map<String, dynamic> map) {
    return MarketplaceReturnReviewItem(
      marketplaceReturnItemReviewId: map['marketplace_return_item_review_id']?.toString() ?? '',
      marketplaceOrderItemId: map['marketplace_order_item_id']?.toString() ?? '',
      marketplaceOrderId: map['marketplace_order_id']?.toString() ?? '',
      tenantId: map['tenant_id']?.toString() ?? '',
      marketplaceAccountId: map['marketplace_account_id']?.toString() ?? '',
      marketplace: map['marketplace']?.toString() ?? '-',
      accountStoreAlias: map['account_store_alias']?.toString() ?? '-',
      accountShopName: map['account_shop_name']?.toString() ?? '-',
      externalOrderId: map['external_order_id']?.toString() ?? '-',
      orderSn: map['order_sn']?.toString(),
      trackingNumber: map['tracking_number']?.toString(),
      orderStatus: map['order_status']?.toString() ?? '-',
      orderStatusLabel: map['order_status_label']?.toString() ?? '-',
      orderStatusGroup: map['order_status_group']?.toString() ?? 'normal',
      stockActionStatus: map['stock_action_status']?.toString() ?? 'pending',
      reviewStatus: map['review_status']?.toString() ?? 'pending',
      packageMatchStatus: map['package_match_status']?.toString() ?? 'pending',
      itemCondition: map['item_condition']?.toString() ?? 'pending',
      canRestock: map['can_restock'] is bool ? map['can_restock'] as bool : null,
      stockInStatus: map['stock_in_status']?.toString() ?? 'not_applicable',
      stockInMovementCount: _int(map['stock_in_movement_count']),
      note: map['note']?.toString(),
      reviewedAt: map['reviewed_at']?.toString(),
      orderCreatedAt: map['order_created_at']?.toString(),
      orderUpdatedAt: map['order_updated_at']?.toString(),
      pulledAt: map['pulled_at']?.toString(),
      lastError: map['last_error']?.toString(),
      marketplaceProductName: map['marketplace_product_name']?.toString(),
      marketplaceVariantName: map['marketplace_variant_name']?.toString(),
      sellerSku: map['seller_sku']?.toString(),
      marketplaceSkuId: map['marketplace_sku_id']?.toString(),
      mappedLocalSku: map['mapped_local_sku']?.toString(),
      mappedProductId: map['mapped_product_id']?.toString(),
      localProductName: map['local_product_name']?.toString(),
      localBarcode: map['local_barcode']?.toString(),
      localStock: _num(map['local_stock']),
      itemCount: _int(map['item_count']),
      qtyTotal: _num(map['qty_total'] ?? map['item_qty']),
      reservedQtyTotal: _num(map['reserved_qty_total'] ?? map['item_reserved_qty']),
      scannedQtyTotal: _num(map['scanned_qty_total'] ?? map['item_scanned_qty']),
      stockOutQtyTotal: _num(map['stock_out_qty_total'] ?? map['item_stock_out_qty']),
      itemReturnedQty: _num(map['item_returned_qty']),
      itemStockActionStatus: map['item_stock_action_status']?.toString() ?? '-',
      itemReturnReviewStatus: map['item_return_review_status']?.toString() ?? '-',
    );
  }

  String get accountName {
    if (accountShopName.trim().isNotEmpty && accountShopName != '-') return accountShopName;
    return accountStoreAlias;
  }

  bool get isPending => reviewStatus == 'pending' || reviewStatus == 'not_required';

  bool get hasPhysicalStockOut => stockOutQtyTotal > 0 || itemStockActionStatus == 'stock_out_done';

  bool get canStockIn => hasPhysicalStockOut && isPending;

  String get marketplaceItemTitle {
    final product = (marketplaceProductName ?? '').trim();
    final variant = (marketplaceVariantName ?? '').trim();
    if (product.isEmpty && variant.isEmpty) return sellerSku ?? marketplaceSkuId ?? '-';
    if (variant.isEmpty || variant == '-') return product;
    return '$product · $variant';
  }

  String get localItemTitle {
    final name = (localProductName ?? '').trim();
    final sku = (mappedLocalSku ?? '').trim();
    if (name.isEmpty && sku.isEmpty) return '-';
    if (name.isEmpty) return sku;
    if (sku.isEmpty) return name;
    return '$sku · $name';
  }

  String get qtyText => _formatQty(qtyTotal);

  String get reservedText => _formatQty(reservedQtyTotal);

  String get scannedText => _formatQty(scannedQtyTotal);

  String get stockOutText => _formatQty(stockOutQtyTotal);

  String get returnedText => _formatQty(itemReturnedQty);

  String get localStockText => _formatQty(localStock);

  String get reviewedAtText => _formatDate(reviewedAt);

  String get orderTimeText => _formatDate(orderCreatedAt);

  static int _int(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;

  static num _num(dynamic value) => num.tryParse(value?.toString() ?? '') ?? 0;

  static String _formatQty(num value) {
    if (value % 1 == 0) return value.toStringAsFixed(0);
    return value.toString();
  }

  static String _formatDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  }
}
