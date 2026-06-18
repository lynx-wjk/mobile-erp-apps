class MarketplaceOrderSummary {
  final String marketplaceOrderId;
  final String tenantId;
  final String marketplaceAccountId;
  final String marketplace;
  final String accountStoreAlias;
  final String accountShopName;
  final String externalOrderId;
  final String orderStatus;
  final String orderStatusLabel;
  final String stockActionStatus;
  final String stockActionLabel;
  final String buyerUsername;
  final String recipientName;
  final String paymentMethod;
  final String currency;
  final num totalAmount;
  final String? orderCreatedAt;
  final String? orderUpdatedAt;
  final String? pulledAt;
  final String? lastError;
  final int itemCount;
  final num qtyTotal;
  final int mappedItemCount;
  final int unmappedItemCount;
  final int stockOutDoneCount;
  final int stockOutFailedCount;
  final int reservedItemCount;
  final int partialScannedItemCount;
  final int scannedDoneItemCount;
  final String orderStatusGroup;
  final String trackingNumber;
  final String shippingProviderName;
  final String packageId;
  final String logisticStatus;
  final String labelCode;
  final bool hasBatalRequest;
  final String cancelRequestId;
  final String cancelRequestStatus;
  final String cancelRequestReason;
  final String cancelRequestNote;
  final String? cancelRequestedAt;
  final String? cancelRequestPulledAt;
  final int pendingReturnReviewCount;
  final String pendingReturnReviewTypes;

  const MarketplaceOrderSummary({
    required this.marketplaceOrderId,
    required this.tenantId,
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.accountStoreAlias,
    required this.accountShopName,
    required this.externalOrderId,
    required this.orderStatus,
    required this.orderStatusLabel,
    required this.stockActionStatus,
    required this.stockActionLabel,
    required this.buyerUsername,
    required this.recipientName,
    required this.paymentMethod,
    required this.currency,
    required this.totalAmount,
    required this.orderCreatedAt,
    required this.orderUpdatedAt,
    required this.pulledAt,
    required this.lastError,
    required this.itemCount,
    required this.qtyTotal,
    required this.mappedItemCount,
    required this.unmappedItemCount,
    required this.stockOutDoneCount,
    required this.stockOutFailedCount,
    required this.reservedItemCount,
    required this.partialScannedItemCount,
    required this.scannedDoneItemCount,
    required this.orderStatusGroup,
    required this.trackingNumber,
    required this.shippingProviderName,
    required this.packageId,
    required this.logisticStatus,
    required this.labelCode,
    required this.hasBatalRequest,
    required this.cancelRequestId,
    required this.cancelRequestStatus,
    required this.cancelRequestReason,
    required this.cancelRequestNote,
    required this.cancelRequestedAt,
    required this.cancelRequestPulledAt,
    required this.pendingReturnReviewCount,
    required this.pendingReturnReviewTypes,
  });

  factory MarketplaceOrderSummary.fromMap(Map<String, dynamic> map) {
    return MarketplaceOrderSummary(
      marketplaceOrderId: _pickText([map['marketplace_order_id']]),
      tenantId: _pickText([map['tenant_id']]),
      marketplaceAccountId: _pickText([map['marketplace_account_id']]),
      marketplace: _pickText([map['marketplace']], '-'),
      accountStoreAlias: _pickText([map['account_store_alias'], map['store_alias']], '-'),
      accountShopName: _pickText([map['account_shop_name'], map['shop_name'], map['seller_name']], '-'),
      externalOrderId: _pickText([map['external_order_id'], map['order_sn'], map['remote_order_id'], map['order_id']], '-'),
      orderStatus: _pickText([map['order_status'], map['status']], '-'),
      orderStatusLabel: _pickText([map['order_status_label'], map['order_status'], map['status']], '-'),
      stockActionStatus: map['stock_action_status']?.toString() ?? 'pending',
      stockActionLabel: map['stock_action_label']?.toString() ?? 'Pending',
      buyerUsername: map['buyer_username']?.toString() ?? '-',
      recipientName: map['recipient_name']?.toString() ?? '-',
      paymentMethod: map['payment_method']?.toString() ?? '-',
      currency: map['currency']?.toString() ?? '',
      totalAmount: _num(map['total_amount']),
      orderCreatedAt: map['order_created_at']?.toString(),
      orderUpdatedAt: map['order_updated_at']?.toString(),
      pulledAt: map['pulled_at']?.toString(),
      lastError: map['last_error']?.toString(),
      itemCount: _int(map['item_count']),
      qtyTotal: _num(map['qty_total']),
      mappedItemCount: _int(map['mapped_item_count']),
      unmappedItemCount: _int(map['unmapped_item_count']),
      stockOutDoneCount: _int(map['stock_out_done_count']),
      stockOutFailedCount: _int(map['stock_out_failed_count']),
      reservedItemCount: _int(map['reserved_item_count']),
      partialScannedItemCount: _int(map['partial_scanned_item_count']),
      scannedDoneItemCount: _int(map['scanned_done_item_count']),
      orderStatusGroup: map['order_status_group']?.toString() ?? 'normal',
      trackingNumber: map['tracking_number']?.toString() ?? '',
      shippingProviderName: map['shipping_provider_name']?.toString() ?? '',
      packageId: map['package_id']?.toString() ?? '',
      logisticStatus: map['logistic_status']?.toString() ?? '',
      labelCode: map['label_code']?.toString() ?? '',
      hasBatalRequest: _bool(map['has_cancel_request']),
      cancelRequestId: map['cancel_request_id']?.toString() ?? '',
      cancelRequestStatus: map['cancel_request_status']?.toString() ?? '',
      cancelRequestReason: map['cancel_request_reason']?.toString() ?? '',
      cancelRequestNote: map['cancel_request_note']?.toString() ?? '',
      cancelRequestedAt: map['cancel_requested_at']?.toString(),
      cancelRequestPulledAt: map['cancel_request_pulled_at']?.toString(),
      pendingReturnReviewCount: _int(map['pending_return_review_count']),
      pendingReturnReviewTypes: map['pending_return_review_types']?.toString() ?? '',
    );
  }

  bool get hasCancelRequest => hasBatalRequest;

  bool get canProcessStockOut =>
      !hasBatalRequest &&
      (stockActionStatus == 'ready_stock_out' ||
      stockActionStatus == 'ready_to_pick' ||
      stockActionStatus == 'reserve_failed' ||
      stockActionStatus == 'insufficient_stock');

  bool get canOpenPickScan =>
      stockActionStatus == 'reserved' ||
      stockActionStatus == 'partial_scanned' ||
      stockActionStatus == 'scanned_done' ||
      stockActionStatus == 'stock_out_failed';

  bool get canFinalizeStockOut => stockActionStatus == 'scanned_done';

  bool get hasPendingReturnReview => pendingReturnReviewCount > 0;

  bool get needsReturnReview =>
      hasPendingReturnReview ||
      stockActionStatus == 'return_review_required' ||
      stockActionStatus == 'cancel_review_required' ||
      hasBatalRequest ||
      orderStatusGroup == 'cancelled' ||
      orderStatusGroup == 'return_refund';

  String get reviewBadgeLabel {
    if (!hasPendingReturnReview) return stockActionLabel;
    if (stockActionStatus == 'stock_out_done') return 'Refund/Batal Review';
    return 'Review Required';
  }

  String get pendingReturnReviewSummary {
    if (!hasPendingReturnReview) return '';
    final typeText = pendingReturnReviewTypes.trim().isEmpty ? 'refund/cancel' : pendingReturnReviewTypes.trim();
    return '$pendingReturnReviewCount item perlu dicek di Refund / Batal Monitor. Tipe: $typeText.';
  }

  bool get hasUnmappedItems => unmappedItemCount > 0 || stockActionStatus == 'unmapped';

  bool get isDone => stockActionStatus == 'stock_out_done' || stockActionStatus == 'return_review_done' || stockActionStatus == 'cancelled_released';

  String get resiText {
    final tracking = trackingNumber.trim();
    if (tracking.isNotEmpty && tracking != '-') return tracking;

    // Fallback ini sengaja dipertahankan untuk proses Stock Out.
    // Beberapa marketplace belum memberi courier AWB pada order baru,
    // tapi package/label reference tetap harus bisa discan/dicopy untuk matching operasional.
    final label = labelCode.trim();
    if (label.isNotEmpty && label != '-') return label;

    final package = packageId.trim();
    if (package.isNotEmpty && package != '-') return package;

    return '-';
  }

  String get resiSourceText {
    final clean = resiText.trim();
    if (clean.isEmpty || clean == '-') return '-';
    if (trackingNumber.trim() == clean) return 'Tracking / AWB';
    if (labelCode.trim() == clean) return 'Label marketplace';
    if (packageId.trim() == clean) return 'Package / logistics reference';
    return 'Resi / reference';
  }

  String get cancelRequestStatusText {
    final value = cancelRequestStatus.trim();
    if (value.isEmpty || value == '-') return hasBatalRequest ? 'Batal Requested' : '-';
    return value.replaceAll('_', ' ');
  }

  String get cancelRequestedTimeText => _formatDate(cancelRequestedAt);

  String get cancelRequestPulledTimeText => _formatDate(cancelRequestPulledAt);

  String get cancelRequestSummary {
    if (!hasBatalRequest) return '';
    final parts = <String>[];
    final status = cancelRequestStatusText.trim();
    if (status.isNotEmpty && status != '-') parts.add(status);
    if (cancelRequestReason.trim().isNotEmpty) parts.add(cancelRequestReason.trim());
    if (cancelRequestedTimeText != '-') parts.add(cancelRequestedTimeText);
    return parts.isEmpty ? 'Buyer cancellation request detected' : parts.join(' · ');
  }

  String get accountName {
    if (accountShopName.trim().isNotEmpty && accountShopName != '-') return accountShopName;
    return accountStoreAlias;
  }

  String get orderTimeText => _formatDate(orderCreatedAt);

  String get pulledTimeText => _formatDate(pulledAt);

  String get totalText {
    if (totalAmount == 0 || currency.trim().isEmpty) return '-';
    return '$currency ${_formatMoney(totalAmount)}';
  }


  static String _formatMoney(num value) {
    final sign = value < 0 ? '-' : '';
    final raw = value.abs().round().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final reverse = raw.length - i;
      buffer.write(raw[i]);
      if (reverse > 1 && reverse % 3 == 1) buffer.write('.');
    }
    return '$sign${buffer.toString()}';
  }

  static int _int(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;

  static num _num(dynamic value) => num.tryParse(value?.toString() ?? '') ?? 0;

  static bool _bool(dynamic value) {
    if (value is bool) return value;
    final text = value?.toString().toLowerCase().trim() ?? '';
    return text == 'true' || text == '1' || text == 'yes';
  }

  static String _pickText(List<dynamic> values, [String fallback = '']) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != '-' && text.toLowerCase() != 'null') {
        return text;
      }
    }
    return fallback;
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
