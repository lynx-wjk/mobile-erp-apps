class MarketplaceAccount {
  final String marketplaceAccountId;
  final String marketplace;
  final String? shopName;
  final String? shopId;
  final String? shopCipher;
  final String? shopRegion;
  final String status;
  final DateTime? accessTokenExpiredAt;
  final DateTime? lastConnectedAt;
  final DateTime? lastCheckedAt;
  final String? lastError;

  const MarketplaceAccount({
    required this.marketplaceAccountId,
    required this.marketplace,
    this.shopName,
    this.shopId,
    this.shopCipher,
    this.shopRegion,
    required this.status,
    this.accessTokenExpiredAt,
    this.lastConnectedAt,
    this.lastCheckedAt,
    this.lastError,
  });

  factory MarketplaceAccount.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString());
    }

    return MarketplaceAccount(
      marketplaceAccountId: (map['marketplace_account_id'] ?? '').toString(),
      marketplace: (map['marketplace'] ?? '').toString(),
      shopName: map['shop_name']?.toString(),
      shopId: map['shop_id']?.toString(),
      shopCipher: map['shop_cipher']?.toString(),
      shopRegion: map['shop_region']?.toString(),
      status: (map['status'] ?? 'inactive').toString(),
      accessTokenExpiredAt: parseDate(map['access_token_expired_at']),
      lastConnectedAt: parseDate(map['last_connected_at']),
      lastCheckedAt: parseDate(map['last_checked_at']),
      lastError: map['last_error']?.toString(),
    );
  }
}

class MarketplaceSkuMap {
  final String mapId;
  final String marketplace;
  final String? marketplaceAccountId;
  final String productId;
  final String localSku;
  final String? localName;
  final num localStock;
  final String? remoteProductId;
  final String remoteSkuId;
  final String? remoteSellerSku;
  final String? remoteSkuName;
  final String? remoteProductName;
  final String? warehouseId;
  final bool isStockSyncEnabled;
  final num? lastLocalStock;
  final num? lastMarketplaceStock;
  final DateTime? lastSyncedAt;
  final String status;

  const MarketplaceSkuMap({
    required this.mapId,
    required this.marketplace,
    required this.marketplaceAccountId,
    required this.productId,
    required this.localSku,
    required this.localName,
    required this.localStock,
    required this.remoteProductId,
    required this.remoteSkuId,
    required this.remoteSellerSku,
    required this.remoteSkuName,
    required this.remoteProductName,
    required this.warehouseId,
    required this.isStockSyncEnabled,
    required this.lastLocalStock,
    required this.lastMarketplaceStock,
    required this.lastSyncedAt,
    required this.status,
  });

  factory MarketplaceSkuMap.fromMap(Map<String, dynamic> map) {
    final product = map['products'];
    final productMap = product is Map<String, dynamic> ? product : <String, dynamic>{};

    return MarketplaceSkuMap(
      mapId: (map['map_id'] ?? '').toString(),
      marketplace: (map['marketplace'] ?? '').toString(),
      marketplaceAccountId: map['marketplace_account_id']?.toString(),
      productId: (map['product_id'] ?? '').toString(),
      localSku: (map['local_sku'] ?? productMap['kode_sku'] ?? '').toString(),
      localName: (productMap['nama_barang'] ?? '').toString(),
      localStock: _asNum(productMap['stock_saat_ini']),
      remoteProductId: map['remote_product_id']?.toString(),
      remoteSkuId: (map['remote_sku_id'] ?? '').toString(),
      remoteSellerSku: map['remote_seller_sku']?.toString(),
      remoteSkuName: map['remote_sku_name']?.toString(),
      remoteProductName: map['remote_product_name']?.toString(),
      warehouseId: map['warehouse_id']?.toString(),
      isStockSyncEnabled: map['is_stock_sync_enabled'] == true,
      lastLocalStock: map['last_local_stock'] == null ? null : _asNum(map['last_local_stock']),
      lastMarketplaceStock: map['last_marketplace_stock'] == null ? null : _asNum(map['last_marketplace_stock']),
      lastSyncedAt: map['last_synced_at'] == null ? null : DateTime.tryParse(map['last_synced_at'].toString()),
      status: (map['status'] ?? 'active').toString(),
    );
  }
}

class LocalProductOption {
  final String productId;
  final String sku;
  final String name;
  final num stock;

  const LocalProductOption({
    required this.productId,
    required this.sku,
    required this.name,
    required this.stock,
  });

  factory LocalProductOption.fromMap(Map<String, dynamic> map) {
    return LocalProductOption(
      productId: (map['product_id'] ?? '').toString(),
      sku: (map['kode_sku'] ?? '').toString(),
      name: (map['nama_barang'] ?? '').toString(),
      stock: _asNum(map['stock_saat_ini']),
    );
  }
}

class MarketplaceOrder {
  final String marketplaceOrderId;
  final String marketplace;
  final String orderId;
  final String? trackingNumber;
  final String? orderStatus;
  final String? paymentStatus;
  final num grossAmount;
  final num paidAmount;
  final bool isStockOutCompleted;
  final DateTime? orderCreatedAt;

  const MarketplaceOrder({
    required this.marketplaceOrderId,
    required this.marketplace,
    required this.orderId,
    required this.trackingNumber,
    required this.orderStatus,
    required this.paymentStatus,
    required this.grossAmount,
    required this.paidAmount,
    required this.isStockOutCompleted,
    required this.orderCreatedAt,
  });

  factory MarketplaceOrder.fromMap(Map<String, dynamic> map) {
    return MarketplaceOrder(
      marketplaceOrderId: (map['marketplace_order_id'] ?? '').toString(),
      marketplace: (map['marketplace'] ?? '').toString(),
      orderId: (map['order_id'] ?? '').toString(),
      trackingNumber: map['tracking_number']?.toString(),
      orderStatus: map['order_status']?.toString(),
      paymentStatus: map['payment_status']?.toString(),
      grossAmount: _asNum(map['gross_amount']),
      paidAmount: _asNum(map['paid_amount']),
      isStockOutCompleted: map['is_stock_out_completed'] == true,
      orderCreatedAt: map['order_created_at'] == null ? null : DateTime.tryParse(map['order_created_at'].toString()),
    );
  }
}

class MarketplaceFinanceReport {
  final String financeReportId;
  final String marketplace;
  final String orderId;
  final num grossAmount;
  final num receivedAmount;
  final num totalHpp;
  final num? grossProfit;
  final num? marginPercent;
  final DateTime? pulledAt;

  const MarketplaceFinanceReport({
    required this.financeReportId,
    required this.marketplace,
    required this.orderId,
    required this.grossAmount,
    required this.receivedAmount,
    required this.totalHpp,
    required this.grossProfit,
    required this.marginPercent,
    required this.pulledAt,
  });

  factory MarketplaceFinanceReport.fromMap(Map<String, dynamic> map) {
    return MarketplaceFinanceReport(
      financeReportId: (map['finance_report_id'] ?? '').toString(),
      marketplace: (map['marketplace'] ?? '').toString(),
      orderId: (map['order_id'] ?? '').toString(),
      grossAmount: _asNum(map['gross_amount']),
      receivedAmount: _asNum(map['received_amount']),
      totalHpp: _asNum(map['total_hpp']),
      grossProfit: map['gross_profit'] == null ? null : _asNum(map['gross_profit']),
      marginPercent: map['margin_percent'] == null ? null : _asNum(map['margin_percent']),
      pulledAt: map['pulled_at'] == null ? null : DateTime.tryParse(map['pulled_at'].toString()),
    );
  }
}

class MarketplaceAbnormal {
  final String abnormalId;
  final String marketplace;
  final String orderId;
  final String abnormalType;
  final String severity;
  final String message;
  final num? expectedAmount;
  final num? actualAmount;
  final num? deltaAmount;
  final String status;

  const MarketplaceAbnormal({
    required this.abnormalId,
    required this.marketplace,
    required this.orderId,
    required this.abnormalType,
    required this.severity,
    required this.message,
    required this.expectedAmount,
    required this.actualAmount,
    required this.deltaAmount,
    required this.status,
  });

  factory MarketplaceAbnormal.fromMap(Map<String, dynamic> map) {
    return MarketplaceAbnormal(
      abnormalId: (map['abnormal_id'] ?? '').toString(),
      marketplace: (map['marketplace'] ?? '').toString(),
      orderId: (map['order_id'] ?? '').toString(),
      abnormalType: (map['abnormal_type'] ?? '').toString(),
      severity: (map['severity'] ?? '').toString(),
      message: (map['message'] ?? '').toString(),
      expectedAmount: map['expected_amount'] == null ? null : _asNum(map['expected_amount']),
      actualAmount: map['actual_amount'] == null ? null : _asNum(map['actual_amount']),
      deltaAmount: map['delta_amount'] == null ? null : _asNum(map['delta_amount']),
      status: (map['status'] ?? 'open').toString(),
    );
  }
}

num _asNum(dynamic value) {
  if (value is num) return value;
  if (value == null) return 0;
  return num.tryParse(value.toString()) ?? 0;
}
