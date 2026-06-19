class MarketplaceOrderItem {
  final String marketplaceOrderItemId;
  final String marketplaceOrderId;
  final String externalOrderItemId;
  final String marketplaceProductId;
  final String marketplaceSkuId;
  final String sellerSku;
  final String productName;
  final String variantName;
  final num quantity;
  final String? mappedProductId;
  final String mappedLocalSku;
  final String? marketplaceSkuMapId;
  final String mappingStatus;
  final String mappingLabel;
  final String stockActionStatus;
  final String stockActionLabel;
  final num reservedQty;
  final num scannedQty;
  final num returnedQty;
  final String localProductName;
  final String localBarcode;
  final num localStock;
  final num reservedStockTotal;
  final num availableStock;
  final String? lastError;
  final String trackingNumber;
  final String packageId;

  const MarketplaceOrderItem({
    required this.marketplaceOrderItemId,
    required this.marketplaceOrderId,
    required this.externalOrderItemId,
    required this.marketplaceProductId,
    required this.marketplaceSkuId,
    required this.sellerSku,
    required this.productName,
    required this.variantName,
    required this.quantity,
    required this.mappedProductId,
    required this.mappedLocalSku,
    required this.marketplaceSkuMapId,
    required this.mappingStatus,
    required this.mappingLabel,
    required this.stockActionStatus,
    required this.stockActionLabel,
    required this.reservedQty,
    required this.scannedQty,
    required this.returnedQty,
    required this.localProductName,
    required this.localBarcode,
    required this.localStock,
    required this.reservedStockTotal,
    required this.availableStock,
    required this.lastError,
    required this.trackingNumber,
    required this.packageId,
  });

  factory MarketplaceOrderItem.fromMap(Map<String, dynamic> map) {
    final rawMappingStatus =
        map['mapping_status']?.toString().trim().toLowerCase() ?? 'unmapped';
    final rawMappedProductId =
        map['mapped_product_id']?.toString().trim() ?? '';
    final rawMappedLocalSku = map['mapped_local_sku']?.toString().trim() ?? '';
    final hasMappedSku =
        rawMappedLocalSku.isNotEmpty && rawMappedLocalSku != '-';
    final isMapped = rawMappingStatus == 'mapped' &&
        (rawMappedProductId.isNotEmpty || hasMappedSku);

    return MarketplaceOrderItem(
      marketplaceOrderItemId:
          map['marketplace_order_item_id']?.toString() ?? '',
      marketplaceOrderId: map['marketplace_order_id']?.toString() ?? '',
      externalOrderItemId: map['external_order_item_id']?.toString() ?? '',
      marketplaceProductId: map['marketplace_product_id']?.toString() ?? '-',
      marketplaceSkuId: map['marketplace_sku_id']?.toString() ?? '-',
      sellerSku: map['seller_sku']?.toString() ?? '-',
      productName: map['product_name']?.toString() ?? '-',
      variantName: map['variant_name']?.toString() ?? '-',
      quantity: num.tryParse(map['quantity']?.toString() ?? '') ?? 0,
      mappedProductId: isMapped ? rawMappedProductId : null,
      mappedLocalSku: isMapped ? rawMappedLocalSku : '-',
      marketplaceSkuMapId:
          isMapped ? map['marketplace_sku_map_id']?.toString() : null,
      mappingStatus: isMapped ? 'mapped' : 'unmapped',
      mappingLabel:
          isMapped ? map['mapping_label']?.toString() ?? 'Mapped' : 'Unmapped',
      stockActionStatus: map['stock_action_status']?.toString() ?? 'pending',
      stockActionLabel: map['stock_action_label']?.toString() ?? 'Pending',
      reservedQty: num.tryParse(map['reserved_qty']?.toString() ?? '') ?? 0,
      scannedQty: num.tryParse(map['scanned_qty']?.toString() ?? '') ?? 0,
      returnedQty: num.tryParse(map['returned_qty']?.toString() ?? '') ?? 0,
      localProductName:
          isMapped ? map['local_product_name']?.toString() ?? '-' : '-',
      localBarcode: isMapped ? map['local_barcode']?.toString() ?? '-' : '-',
      localStock: isMapped
          ? num.tryParse(map['local_stock']?.toString() ?? '') ?? 0
          : 0,
      reservedStockTotal: isMapped
          ? num.tryParse(map['reserved_stock_total']?.toString() ?? '') ?? 0
          : 0,
      availableStock: isMapped
          ? num.tryParse(map['available_stock']?.toString() ?? '') ?? 0
          : 0,
      lastError: map['last_error']?.toString(),
      trackingNumber: map['tracking_number']?.toString() ?? '',
      packageId: map['package_id']?.toString() ?? '',
    );
  }

  bool get isMapped =>
      mappingStatus == 'mapped' &&
      ((mappedProductId?.trim().isNotEmpty ?? false) ||
          mappedLocalSku.trim().isNotEmpty && mappedLocalSku.trim() != '-');

  bool get isDone => stockActionStatus == 'stock_out_done';

  bool get scanComplete => scannedQty >= quantity && quantity > 0;

  String get scanProgressText =>
      '${_formatQty(scannedQty)}/${_formatQty(quantity)}';

  String get reserveText => _formatQty(reservedQty);

  String get availableStockText => _formatQty(availableStock);

  String get qtyText => _formatQty(quantity);

  static String _formatQty(num value) {
    if (value % 1 == 0) return value.toStringAsFixed(0);
    return value.toString();
  }
}
