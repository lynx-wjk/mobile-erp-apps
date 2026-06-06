class MarketplaceSyncLogItem {
  final String marketplaceStockSyncLogId;
  final String tenantId;
  final String? marketplaceAccountId;
  final String marketplace;
  final String accountStoreAlias;
  final String? accountShopName;
  final String? marketplaceSkuMapId;
  final String? productId;
  final String localSku;
  final String localProductName;
  final num localStock;
  final String? marketplaceProductId;
  final String? marketplaceSkuId;
  final String? marketplaceSellerSku;
  final String marketplaceProductName;
  final String? marketplaceVariationName;
  final num requestedStock;
  final String syncStatus;
  final String statusLabel;
  final int attemptCount;
  final String? errorMessage;
  final String? workerMessage;
  final String? workerName;
  final bool isDryRun;
  final bool canRetry;
  final bool canHapus;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final DateTime? updatedAt;

  const MarketplaceSyncLogItem({
    required this.marketplaceStockSyncLogId,
    required this.tenantId,
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.accountStoreAlias,
    required this.accountShopName,
    required this.marketplaceSkuMapId,
    required this.productId,
    required this.localSku,
    required this.localProductName,
    required this.localStock,
    required this.marketplaceProductId,
    required this.marketplaceSkuId,
    required this.marketplaceSellerSku,
    required this.marketplaceProductName,
    required this.marketplaceVariationName,
    required this.requestedStock,
    required this.syncStatus,
    required this.statusLabel,
    required this.attemptCount,
    required this.errorMessage,
    required this.workerMessage,
    required this.workerName,
    required this.isDryRun,
    required this.canRetry,
    required this.canHapus,
    required this.createdAt,
    required this.startedAt,
    required this.finishedAt,
    required this.updatedAt,
  });

  factory MarketplaceSyncLogItem.fromMap(Map<String, dynamic> map) {
    final status = _text(map['sync_status'], '-');
    return MarketplaceSyncLogItem(
      marketplaceStockSyncLogId: _text(map['marketplace_stock_sync_log_id']),
      tenantId: _text(map['tenant_id']),
      marketplaceAccountId: _nullableText(map['marketplace_account_id']),
      marketplace: _text(map['marketplace'], '-'),
      accountStoreAlias: _text(map['account_store_alias'], '-'),
      accountShopName: _nullableText(map['account_shop_name']),
      marketplaceSkuMapId: _nullableText(map['marketplace_sku_map_id']),
      productId: _nullableText(map['product_id']),
      localSku: _text(map['local_sku'], '-'),
      localProductName: _text(map['local_product_name'], '-'),
      localStock: _num(map['local_stock']),
      marketplaceProductId: _nullableText(map['marketplace_product_id']),
      marketplaceSkuId: _nullableText(map['marketplace_sku_id']),
      marketplaceSellerSku: _nullableText(map['marketplace_seller_sku']),
      marketplaceProductName: _text(map['marketplace_product_name'], '-'),
      marketplaceVariationName: _nullableText(map['marketplace_variation_name']),
      requestedStock: _num(map['requested_stock']),
      syncStatus: status,
      statusLabel: _text(map['status_label'], _labelForStatus(status)),
      attemptCount: _int(map['attempt_count']),
      errorMessage: _nullableText(map['error_message']),
      workerMessage: _nullableText(map['worker_message']),
      workerName: _nullableText(map['worker_name']),
      isDryRun: _bool(map['is_dry_run']),
      canRetry: _bool(map['can_retry']),
      canHapus: map.containsKey('can_delete')
          ? _bool(map['can_delete'])
          : _defaultCanHapus(status),
      createdAt: _date(map['created_at']),
      startedAt: _date(map['started_at']),
      finishedAt: _date(map['finished_at']),
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

  String get marketplaceIdentity {
    final seller = marketplaceSellerSku?.trim();
    if (seller != null && seller.isNotEmpty && seller != '-') return seller;
    final skuId = marketplaceSkuId?.trim();
    if (skuId != null && skuId.isNotEmpty) return skuId;
    return '-';
  }

  String get stockText => _formatNum(requestedStock == 0 ? localStock : requestedStock);

  String get createdText => _formatDate(createdAt);
  String get finishedText => _formatDate(finishedAt ?? updatedAt ?? createdAt);

  bool get isSuccess => syncStatus == 'success' || syncStatus == 'dry_run_success';
  bool get isFailed => syncStatus.contains('failed') || syncStatus == 'auth_required';
  bool get isMenunggu => syncStatus == 'queued' || syncStatus == 'processing';

  String get visibleError {
    final error = errorMessage?.trim();
    if (error != null && error.isNotEmpty) return error;
    final worker = workerMessage?.trim();
    if (worker != null && worker.isNotEmpty) return worker;
    return '-';
  }
}

String _labelForStatus(String status) {
  switch (status) {
    case 'queued':
      return 'Menunggu';
    case 'processing':
      return 'Processing';
    case 'success':
      return 'Success';
    case 'dry_run_success':
      return 'Cek OK';
    case 'waiting_marketplace_ids':
      return 'Waiting ID';
    case 'auth_required':
      return 'Auth Required';
    case 'skipped':
      return 'Skipped';
    case 'failed':
    case 'failed_retryable':
      return 'Failed';
    case 'failed_final':
      return 'Failed Final';
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

int _int(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}


bool _defaultCanHapus(String status) {
  return status != 'queued' && status != 'processing';
}

bool _bool(dynamic value) {
  if (value == null) return false;
  if (value is bool) return value;
  final raw = value.toString().trim().toLowerCase();
  return raw == 'true' || raw == '1' || raw == 'yes';
}

DateTime? _date(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value.toLocal();
  return DateTime.tryParse(value.toString())?.toLocal();
}

String _formatDate(DateTime? value) {
  if (value == null) return '-';
  final local = value.toLocal();
  String two(int input) => input.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
}

String _formatNum(num value) {
  if (value % 1 == 0) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}
