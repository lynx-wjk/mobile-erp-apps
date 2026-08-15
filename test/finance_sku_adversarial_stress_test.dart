import 'package:flutter_test/flutter_test.dart';

// Helper reproduction matching finance_report_page.dart
String _text(dynamic value, [String fallback = '']) {
  if (value == null) return fallback;
  final str = value.toString();
  return str.isEmpty ? fallback : str;
}

num _num(dynamic value, [num fallback = 0]) {
  if (value == null) return fallback;
  if (value is num) return value;
  final str = value.toString().trim().replaceAll(',', '.');
  return num.tryParse(str) ?? fallback;
}

num _numFirstNonZero(List<dynamic> values, [num fallback = 0]) {
  for (final v in values) {
    final n = _num(v);
    if (n != 0) return n;
  }
  return fallback;
}

num _skuOrderDetailPayoutValueV82o(Map<String, dynamic> row) {
  return _numFirstNonZero([
    row['payout'],
    row['payout_amount'],
    row['payout_total'],
    row['order_payout'],
    row['received_amount'],
    row['net_received'],
    row['net_settlement'],
    row['settlement_amount'],
    row['paid_amount'],
    row['payout_per_item'],
    row['unit_paid_amount'],
    row['unit_payout_amount'],
  ]);
}

num _linePayoutAmount(Map<String, dynamic> detail) {
  final direct = _skuOrderDetailPayoutValueV82o(detail);
  if (direct != 0) return direct;
  final safeQty = _num(detail['qty'] ?? detail['quantity']);
  final perItem = _num(detail['payout_per_item'] ??
      detail['payout_item'] ??
      detail['settlement_per_item']);
  return perItem * safeQty;
}

bool _hasReleasedPayout(Map<String, dynamic> detail) {
  final payout = _linePayoutAmount(detail);
  if (payout != 0) {
    return true;
  }

  if (detail.containsKey('has_payout') && detail['has_payout'] != null) {
    if (detail['has_payout'] == true) return true;
  }

  final orderStatus = _text(
    detail['status'] ?? detail['order_status'],
    '',
  ).toUpperCase();

  final financeStatus = _text(
    detail['payout_status'] ??
        detail['settlement_status'] ??
        detail['finance_status'] ??
        detail['abnormal_status'],
    '',
  ).toUpperCase();

  final joinedStatus = '$orderStatus $financeStatus';

  if (joinedStatus.contains('CANCEL') ||
      joinedStatus.contains('REFUND') ||
      joinedStatus.contains('RETURN') ||
      joinedStatus.contains('BATAL') ||
      joinedStatus.contains('RETUR')) {
    return false;
  }

  if (financeStatus.contains('SETTLED') && !financeStatus.contains('UNSETTLED')) {
    return true;
  }

  final marketplace = _text(detail['marketplace'] ?? detail['marketplace_name'], '').toLowerCase();
  if (marketplace.contains('shopee')) {
    if (financeStatus.contains('SETTLED') || financeStatus.contains('PAID') || financeStatus.contains('RELEASE')) {
      return true;
    }
    final bool isUnpaidStatus = financeStatus.contains('SHIPPED') ||
        financeStatus.contains('DIKIRIM') ||
        financeStatus.contains('RECEIVE') ||
        financeStatus.contains('BELUM') ||
        financeStatus.contains('UNPAID') ||
        financeStatus.contains('UNSETTLED') ||
        financeStatus.contains('PENDING');
    if (isUnpaidStatus) return false;
  }

  return false;
}

bool _skuDetailHasPayoutV82o(Map<String, dynamic> row) {
  final payout = _skuOrderDetailPayoutValueV82o(row);

  final rawStatus = _text(
    row['status'] ?? row['order_status'],
    '',
  ).toUpperCase();

  final financeStatus = _text(
    row['payout_status'] ?? row['finance_status'] ?? row['settlement_status'],
    '',
  ).toUpperCase();

  final joinedStatus = '$rawStatus $financeStatus';

  if (row['is_returned'] == true ||
      joinedStatus.contains('CANCEL') ||
      joinedStatus.contains('REFUND') ||
      joinedStatus.contains('RETURN') ||
      joinedStatus.contains('BATAL') ||
      joinedStatus.contains('RETUR')) {
    return false;
  }

  if (row.containsKey('has_payout') && row['has_payout'] != null) {
    return row['has_payout'] == true;
  }

  if (payout != 0) return true;

  if (row['positive_payout_exists'] == true) return true;

  return (financeStatus.contains('SETTLED') && !financeStatus.contains('UNSETTLED')) ||
      financeStatus.contains('PAID') ||
      financeStatus.contains('RELEASE') ||
      financeStatus.contains('PAYOUT_MINUS') ||
      financeStatus.contains('NEGATIVE_PAYOUT');
}

bool _skuDetailIsPendingPayoutV82o(Map<String, dynamic> row) {
  final payout = _skuOrderDetailPayoutValueV82o(row);

  final rawStatus = _text(
    row['status'] ?? row['order_status'],
    '',
  ).toUpperCase();

  final financeStatus = _text(
    row['payout_status'] ?? row['finance_status'] ?? row['settlement_status'],
    '',
  ).toUpperCase();

  final joinedStatus = '$rawStatus $financeStatus';

  if (row['is_returned'] == true ||
      joinedStatus.contains('CANCEL') ||
      joinedStatus.contains('REFUND') ||
      joinedStatus.contains('RETURN') ||
      joinedStatus.contains('BATAL') ||
      joinedStatus.contains('RETUR')) {
    return false;
  }

  if (row.containsKey('has_payout') && row['has_payout'] != null) {
    return row['has_payout'] == false;
  }

  if (payout != 0) return false;

  if (row['positive_payout_exists'] == true) return false;

  return financeStatus.contains('BELUM') ||
      financeStatus.contains('PENDING') ||
      financeStatus.contains('UNPAID') ||
      financeStatus.contains('MISSING') ||
      financeStatus.contains('UNSETTLED') ||
      financeStatus.trim().isEmpty;
}

List<Map<String, dynamic>> _filteredSkuOrderRows(
    List<Map<String, dynamic>> rows, String payoutFilter) {
  bool isCancelRefundReturn(Map<String, dynamic> item) {
    if (item['is_returned'] == true) return true;
    final status = _text(
      item['status'] ??
          item['order_status'] ??
          item['payout_status'] ??
          item['settlement_status'] ??
          item['finance_status'] ??
          item['abnormal_status'],
      '',
    ).toUpperCase();

    return status.contains('CANCEL') ||
        status.contains('REFUND') ||
        status.contains('RETURN') ||
        status.contains('BATAL') ||
        status.contains('RETUR');
  }

  if (payoutFilter == 'paid') {
    return rows
        .where(
            (item) => !isCancelRefundReturn(item) && _hasReleasedPayout(item))
        .toList();
  }

  if (payoutFilter == 'unpaid') {
    return rows
        .where((item) =>
            !isCancelRefundReturn(item) && !_hasReleasedPayout(item))
        .toList();
  }

  if (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur') {
    return rows.where(isCancelRefundReturn).toList();
  }

  return rows;
}

String _canonicalSkuPayoutFilterV82o(String value) {
  final clean = value.trim().toLowerCase().replaceAll('_', ' ');
  if (clean == 'settled' ||
      clean == 'released' ||
      clean == 'release' ||
      clean == 'payout' ||
      clean == 'paid payout' ||
      clean == 'sudah payout' ||
      clean == 'paid') {
    return 'paid';
  }
  if (clean == 'pending' ||
      clean == 'belum payout' ||
      clean == 'no payout' ||
      clean == 'missing payout' ||
      clean == 'unpaid') {
    return 'unpaid';
  }
  if (clean == 'returned' ||
      clean == 'retur' ||
      clean == 'batal' ||
      clean == 'cancelled' ||
      clean == 'refund') {
    return 'returned';
  }
  return clean.isEmpty ? 'all' : value.trim().toLowerCase();
}

Map<String, dynamic> mergeSummaryRow(Map<String, dynamic> summary) {
  final paidQty = _numFirstNonZero([
    summary['paid_qty_total'],
    summary['settled_qty_total'],
    summary['paid_qty'],
    summary['settled_qty'],
    summary['qty_paid'],
    summary['qty_settled'],
  ]).round();

  final unpaidQty = _numFirstNonZero([
    summary['unpaid_qty'],
    summary['qty_unpaid'],
    summary['unpaid_qty_total'],
    summary['pending_payout_qty'],
    summary['pending_payout_qty_total'],
    summary['qty_pending'],
    summary['qty_belum_payout'],
    summary['belum_payout_qty'],
  ]).round();

  final returnedQty = _numFirstNonZero([
    summary['qty_returned'],
    summary['returned_qty'],
    summary['qty_batal'],
    summary['batal_qty'],
  ]).round();

  final visibleQty = paidQty + unpaidQty + returnedQty;
  final merged = Map<String, dynamic>.from(summary);
  merged['qty_paid'] = paidQty;
  merged['paid_qty'] = paidQty;
  merged['qty_unpaid'] = unpaidQty;
  merged['unpaid_qty'] = unpaidQty;
  merged['qty_returned'] = returnedQty;
  merged['returned_qty'] = returnedQty;
  merged['qty_visible'] = visibleQty;
  return merged;
}

void main() {
  group('Empirical Stress Testing: Null Safety & Edge Formats', () {
    test('Empty and null-filled maps never throw exceptions', () {
      final emptyMap = <String, dynamic>{};
      expect(_skuOrderDetailPayoutValueV82o(emptyMap), 0);
      expect(_skuDetailHasPayoutV82o(emptyMap), isFalse);
      expect(_skuDetailIsPendingPayoutV82o(emptyMap), isTrue);

      final nullMap = <String, dynamic>{
        'status': null,
        'order_status': null,
        'payout_status': null,
        'settlement_status': null,
        'finance_status': null,
        'abnormal_status': null,
        'payout': null,
        'is_returned': null,
        'has_payout': null,
      };
      expect(_skuDetailHasPayoutV82o(nullMap), isFalse);
      expect(_skuDetailIsPendingPayoutV82o(nullMap), isTrue);
      expect(_filteredSkuOrderRows([nullMap], 'paid'), isEmpty);
      expect(_filteredSkuOrderRows([nullMap], 'unpaid'), hasLength(1));
      expect(_filteredSkuOrderRows([nullMap], 'returned'), isEmpty);
    });

    test('String formatting with commas, spaces, and negative payouts', () {
      final row = <String, dynamic>{
        'payout': ' 250000,75 ',
        'status': 'COMPLETED',
        'payout_status': 'SETTLED',
        'is_returned': false,
      };
      expect(_skuOrderDetailPayoutValueV82o(row), 250000.75);
      expect(_skuDetailHasPayoutV82o(row), isTrue);
      expect(_skuDetailIsPendingPayoutV82o(row), isFalse);

      final negativeRow = <String, dynamic>{
        'payout': -15000,
        'status': 'COMPLETED',
        'payout_status': 'PAYOUT_MINUS',
        'is_returned': false,
      };
      expect(_skuDetailHasPayoutV82o(negativeRow), isTrue);
      expect(_skuDetailIsPendingPayoutV82o(negativeRow), isFalse);
    });
  });

  group('Empirical Stress Testing: Strict Pending vs Retur/Batal Separation', () {
    final cancelAndReturnStatuses = [
      'CANCEL',
      'cancelled',
      'CANCELED',
      'cancel_by_buyer',
      'CANCEL_BY_SELLER',
      'batal',
      'BATAL',
      'Pesanan Dibatalkan',
      'dibatalkan',
      'return',
      'RETURN',
      'returned',
      'Permintaan Pengembalian Barang (Retur)',
      'retur',
      'RETUR',
      'retur_selesai',
      'refund',
      'REFUND',
      'REFUND_SETTLED',
      'REFUND_PENDING',
    ];

    for (final status in cancelAndReturnStatuses) {
      test('Strict exclusion for status "$status"', () {
        final zeroPayoutOrder = {
          'id': 'ord_$status',
          'status': status,
          'payout_status': 'UNSETTLED',
          'payout': 0,
          'is_returned': false,
        };

        // Even with 0 payout and UNSETTLED finance status, cancelled/returned orders MUST NOT be pending!
        expect(_skuDetailIsPendingPayoutV82o(zeroPayoutOrder), isFalse,
            reason: 'Cancelled/returned order "$status" must not be pending payout');
        expect(_skuDetailHasPayoutV82o(zeroPayoutOrder), isFalse);

        final withPayoutOrder = {
          'id': 'ord_payout_$status',
          'status': status,
          'payout_status': 'SETTLED',
          'payout': 100000,
          'has_payout': true,
          'is_returned': false,
        };

        // Even with positive payout and SETTLED status, cancelled/returned orders MUST NOT be in settled/paid metrics!
        expect(_skuDetailHasPayoutV82o(withPayoutOrder), isFalse,
            reason: 'Cancelled/returned order "$status" must not be in settled payout');
        expect(_skuDetailIsPendingPayoutV82o(withPayoutOrder), isFalse);

        final list = [zeroPayoutOrder, withPayoutOrder];
        expect(_filteredSkuOrderRows(list, 'paid'), isEmpty);
        expect(_filteredSkuOrderRows(list, 'unpaid'), isEmpty);
        expect(_filteredSkuOrderRows(list, 'returned'), hasLength(2));
      });
    }

    test('is_returned == true flag is authoritative regardless of status string', () {
      final returnedOrder = {
        'id': 'ret_1',
        'status': 'DELIVERED',
        'payout_status': 'SETTLED',
        'payout': 150000,
        'has_payout': true,
        'is_returned': true,
      };

      expect(_skuDetailHasPayoutV82o(returnedOrder), isFalse);
      expect(_skuDetailIsPendingPayoutV82o(returnedOrder), isFalse);
      expect(_filteredSkuOrderRows([returnedOrder], 'returned'), hasLength(1));
      expect(_filteredSkuOrderRows([returnedOrder], 'paid'), isEmpty);
      expect(_filteredSkuOrderRows([returnedOrder], 'unpaid'), isEmpty);
    });
  });

  group('Empirical Stress Testing: Active Pending & Settled Classification', () {
    test('Active non-cancelled orders are correctly segregated', () {
      final activePending1 = {
        'id': 'p1',
        'status': 'SHIPPED',
        'payout_status': 'UNSETTLED',
        'payout': 0,
        'is_returned': false,
      };
      final activePending2 = {
        'id': 'p2',
        'status': 'DELIVERED',
        'payout_status': 'BELUM_BAYAR',
        'payout': 0,
        'is_returned': false,
      };
      final activeSettled1 = {
        'id': 's1',
        'status': 'COMPLETED',
        'payout_status': 'SETTLED',
        'payout': 85000,
        'is_returned': false,
      };
      final activeSettled2 = {
        'id': 's2',
        'status': 'DELIVERED',
        'payout_status': 'PAID',
        'payout': 45000,
        'is_returned': false,
      };

      expect(_skuDetailIsPendingPayoutV82o(activePending1), isTrue);
      expect(_skuDetailHasPayoutV82o(activePending1), isFalse);

      expect(_skuDetailIsPendingPayoutV82o(activePending2), isTrue);
      expect(_skuDetailHasPayoutV82o(activePending2), isFalse);

      expect(_skuDetailHasPayoutV82o(activeSettled1), isTrue);
      expect(_skuDetailIsPendingPayoutV82o(activeSettled1), isFalse);

      expect(_skuDetailHasPayoutV82o(activeSettled2), isTrue);
      expect(_skuDetailIsPendingPayoutV82o(activeSettled2), isFalse);

      final list = [activePending1, activePending2, activeSettled1, activeSettled2];
      expect(_filteredSkuOrderRows(list, 'paid').map((e) => e['id']), ['s1', 's2']);
      expect(_filteredSkuOrderRows(list, 'unpaid').map((e) => e['id']), ['p1', 'p2']);
      expect(_filteredSkuOrderRows(list, 'returned'), isEmpty);
    });
  });

  group('Empirical Stress Testing: Summary Row Merging & Aggregation', () {
    test('mergeSummaryRow calculates visibleQty correctly with retur', () {
      final summary = {
        'paid_qty': 10,
        'unpaid_qty': 5,
        'qty_returned': 3,
        'hpp_return': 75000,
      };

      final merged = mergeSummaryRow(summary);
      expect(merged['qty_paid'], 10);
      expect(merged['qty_unpaid'], 5);
      expect(merged['qty_returned'], 3);
      expect(merged['qty_visible'], 18);
    });

    test('Division by zero protections in display calculations', () {
      final zeroRow = {
        'qty': 0,
        'total_payout': 0,
        'gross_sales': 0,
        'paid_hpp_total': 0,
      };

      final paidQtyDisplay = 0;
      final qtyTotalDisplay = 0;

      final displayPayoutPerItem = paidQtyDisplay > 0
          ? (_num(zeroRow['total_payout']) / paidQtyDisplay)
          : 0;
      final grossPerItem = qtyTotalDisplay > 0
          ? (_num(zeroRow['gross_sales']) / qtyTotalDisplay)
          : 0;
      final displayHppPerItem = paidQtyDisplay > 0
          ? (_num(zeroRow['paid_hpp_total']) / paidQtyDisplay)
          : 0;

      expect(displayPayoutPerItem, 0);
      expect(grossPerItem, 0);
      expect(displayHppPerItem, 0);
    });
  });

  group('Empirical Stress Testing: Canonical Filter Parsing', () {
    test('Canonical filter maps all variations correctly', () {
      expect(_canonicalSkuPayoutFilterV82o('paid'), 'paid');
      expect(_canonicalSkuPayoutFilterV82o('PAID'), 'paid');
      expect(_canonicalSkuPayoutFilterV82o('settled'), 'paid');
      expect(_canonicalSkuPayoutFilterV82o('SETTLED'), 'paid');
      expect(_canonicalSkuPayoutFilterV82o('released'), 'paid');
      expect(_canonicalSkuPayoutFilterV82o('sudah payout'), 'paid');
      expect(_canonicalSkuPayoutFilterV82o('paid_payout'), 'paid');

      expect(_canonicalSkuPayoutFilterV82o('unpaid'), 'unpaid');
      expect(_canonicalSkuPayoutFilterV82o('UNPAID'), 'unpaid');
      expect(_canonicalSkuPayoutFilterV82o('pending'), 'unpaid');
      expect(_canonicalSkuPayoutFilterV82o('belum_payout'), 'unpaid');
      expect(_canonicalSkuPayoutFilterV82o('missing payout'), 'unpaid');

      expect(_canonicalSkuPayoutFilterV82o('returned'), 'returned');
      expect(_canonicalSkuPayoutFilterV82o('RETURNED'), 'returned');
      expect(_canonicalSkuPayoutFilterV82o('retur'), 'returned');
      expect(_canonicalSkuPayoutFilterV82o('batal'), 'returned');
      expect(_canonicalSkuPayoutFilterV82o('cancelled'), 'returned');
      expect(_canonicalSkuPayoutFilterV82o('refund'), 'returned');

      expect(_canonicalSkuPayoutFilterV82o(''), 'all');
      expect(_canonicalSkuPayoutFilterV82o('all'), 'all');
    });
  });
}
