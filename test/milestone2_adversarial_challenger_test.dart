import 'package:flutter_test/flutter_test.dart';

// -----------------------------------------------------------------------------
// Pure logic reproductions from lib/features/finance/presentation/finance_report_page.dart
// -----------------------------------------------------------------------------

String canonicalSkuPayoutFilterV82o(String value) {
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

String textHelper(dynamic value, [String fallback = '']) {
  if (value == null) return fallback;
  final str = value.toString().trim();
  return str.isEmpty ? fallback : str;
}

double numHelper(dynamic value, [double fallback = 0.0]) {
  if (value == null) return fallback;
  if (value is num) return value.toDouble();
  final parsed = double.tryParse(value.toString().replaceAll(',', '.'));
  return parsed ?? fallback;
}

double numFirstNonZero(List<dynamic> values) {
  for (final v in values) {
    final parsed = numHelper(v);
    if (parsed != 0) return parsed;
  }
  return 0.0;
}

double skuOrderDetailPayoutValueV82o(Map<String, dynamic> row) {
  return numFirstNonZero([
    row['payout'],
    row['payout_amount'],
    row['payout_total'],
    row['total_payout'],
    row['net_payout'],
    row['amount_released'],
    row['released_amount'],
    row['settlement_amount'],
    row['received_amount'],
  ]);
}

bool skuDetailHasPayoutV82o(Map<String, dynamic> row) {
  final payout = skuOrderDetailPayoutValueV82o(row);

  final rawStatus = textHelper(
    row['status'] ?? row['order_status'],
    '',
  ).toUpperCase();

  final financeStatus = textHelper(
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

bool skuDetailIsPendingPayoutV82o(Map<String, dynamic> row) {
  final payout = skuOrderDetailPayoutValueV82o(row);

  final rawStatus = textHelper(
    row['status'] ?? row['order_status'],
    '',
  ).toUpperCase();

  final financeStatus = textHelper(
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

List<Map<String, dynamic>> filteredSkuOrderRowsV82o(
    List<Map<String, dynamic>> rows, String payoutFilter) {
  if (payoutFilter == 'paid') {
    return rows.where(skuDetailHasPayoutV82o).toList();
  }

  if (payoutFilter == 'unpaid') {
    return rows.where(skuDetailIsPendingPayoutV82o).toList();
  }

  if (payoutFilter == 'returned' ||
      payoutFilter == 'batal' ||
      payoutFilter == 'retur') {
    return rows.where((r) {
      if (r['is_returned'] == true) return true;
      final st = textHelper(r['settlement_status'], '').toLowerCase();
      if (st.contains('retur') || st.contains('batal')) return true;
      final os = textHelper(r['status'] ?? r['order_status'], '').toLowerCase();
      return RegExp(r'(cancel|batal|return|refund|rts|gagal|closed)').hasMatch(os);
    }).toList();
  }

  return rows;
}

String getPayoutModalLabel(String payoutFilter) {
  return payoutFilter == 'paid'
      ? 'sudah ada payout'
      : payoutFilter == 'unpaid'
          ? 'belum ada payout'
          : (payoutFilter == 'returned' ||
                  payoutFilter == 'batal' ||
                  payoutFilter == 'retur')
              ? 'retur / batal'
              : 'semua status payout';
}

int computeReturnedQtyDisplay({
  required Map<String, dynamic> row,
  required String returnedKey,
  required Map<String, int> skuReturnedCountMap,
  required List<Map<String, dynamic>> returnedDetailRows,
}) {
  int qtyFromOrderRows(List<Map<String, dynamic>> items) {
    int total = 0;
    for (final item in items) {
      total += numFirstNonZero([item['quantity'], item['qty'], 1]).round();
    }
    return total;
  }

  return numFirstNonZero([
    row['qty_returned'],
    row['returned_qty'],
    row['qty_batal'],
    row['batal_qty'],
    skuReturnedCountMap[returnedKey],
    qtyFromOrderRows(returnedDetailRows),
  ]).round();
}

Map<String, dynamic> mergeSkuPayoutCountSummaryRow(
  Map<String, dynamic> row,
  Map<String, Map<String, dynamic>> summaryMap,
  String key,
) {
  final summary = summaryMap[key];
  if (summary == null) return row;

  final paidQty = numFirstNonZero([
    summary['paid_qty'],
    summary['settled_qty'],
    summary['paid_rows'],
    summary['paid_total'],
  ]).round();

  final unpaidQty = numFirstNonZero([
    summary['unpaid_qty'],
    summary['qty_unpaid'],
    summary['unpaid_rows'],
    summary['unpaid_total'],
  ]).round();

  final returnedQty = numFirstNonZero([
    summary['qty_returned'],
    summary['returned_qty'],
    summary['qty_batal'],
    summary['batal_qty'],
    summary['returned_rows'],
    summary['returned_total'],
  ]).round();

  final visibleQty = paidQty + unpaidQty + returnedQty;
  final merged = Map<String, dynamic>.from(row);

  merged['paid_qty'] = paidQty;
  merged['settled_qty'] = paidQty;
  merged['qty_paid'] = paidQty;
  merged['positive_payout_qty'] = paidQty;

  merged['unpaid_qty'] = unpaidQty;
  merged['qty_unpaid'] = unpaidQty;
  merged['pending_payout_qty'] = unpaidQty;
  merged['pending_payout_qty_total'] = unpaidQty;

  if (returnedQty > 0) {
    merged['qty_returned'] = returnedQty;
    merged['returned_qty'] = returnedQty;
  }

  if (visibleQty > 0) {
    merged['qty'] = visibleQty;
    merged['quantity'] = visibleQty;
    merged['qty_total'] = visibleQty;
    merged['total_qty'] = visibleQty;
  }

  merged['sku_count_source'] = 'finance_sku_payout_count_summary';
  return merged;
}

// -----------------------------------------------------------------------------
// Test Suites
// -----------------------------------------------------------------------------

void main() {
  group('Challenger 2 Empirical Verification for Milestone 2', () {
    test('1. RPC Parameter Canonicalization for payoutFilter', () {
      expect(canonicalSkuPayoutFilterV82o('returned'), equals('returned'));
      expect(canonicalSkuPayoutFilterV82o('retur'), equals('returned'));
      expect(canonicalSkuPayoutFilterV82o('batal'), equals('returned'));
      expect(canonicalSkuPayoutFilterV82o('CANCELLED'), equals('returned'));
      expect(canonicalSkuPayoutFilterV82o('refund'), equals('returned'));
      expect(canonicalSkuPayoutFilterV82o('  RETURNED  '), equals('returned'));

      expect(canonicalSkuPayoutFilterV82o('paid'), equals('paid'));
      expect(canonicalSkuPayoutFilterV82o('settled'), equals('paid'));
      expect(canonicalSkuPayoutFilterV82o('released'), equals('paid'));
      expect(canonicalSkuPayoutFilterV82o('sudah_payout'), equals('paid'));

      expect(canonicalSkuPayoutFilterV82o('unpaid'), equals('unpaid'));
      expect(canonicalSkuPayoutFilterV82o('pending'), equals('unpaid'));
      expect(canonicalSkuPayoutFilterV82o('belum_payout'), equals('unpaid'));
      expect(canonicalSkuPayoutFilterV82o('missing_payout'), equals('unpaid'));

      expect(canonicalSkuPayoutFilterV82o(''), equals('all'));
      expect(canonicalSkuPayoutFilterV82o('   '), equals('all'));
    });

    test('2. Strict Pending Payout Separation (Adversarial Edge Cases)', () {
      // Normal active pending order
      expect(
        skuDetailIsPendingPayoutV82o({
          'status': 'SHIPPED',
          'payout_status': 'UNSETTLED',
          'payout': 0,
          'is_returned': false,
        }),
        isTrue,
      );

      // Cancelled order marked as UNSETTLED must NOT be pending payout
      expect(
        skuDetailIsPendingPayoutV82o({
          'status': 'CANCELLED',
          'payout_status': 'UNSETTLED',
          'payout': 0,
          'is_returned': false,
        }),
        isFalse,
      );

      // Returned order marked as UNSETTLED must NOT be pending payout
      expect(
        skuDetailIsPendingPayoutV82o({
          'status': 'RETURN_TO_SELLER',
          'payout_status': 'UNSETTLED',
          'payout': 0,
          'is_returned': false,
        }),
        isFalse,
      );

      // Order with is_returned = true must NEVER be pending payout even if has_payout = false
      expect(
        skuDetailIsPendingPayoutV82o({
          'status': 'DELIVERED',
          'payout_status': 'PENDING',
          'has_payout': false,
          'is_returned': true,
        }),
        isFalse,
      );

      // Indonesian status BATAL / RETUR
      expect(
        skuDetailIsPendingPayoutV82o({
          'order_status': 'Pesanan Dibatalkan',
          'finance_status': 'BELUM DICAIRKAN',
          'payout': 0,
        }),
        isFalse,
      );

      // Refund status
      expect(
        skuDetailIsPendingPayoutV82o({
          'status': 'COMPLETED',
          'finance_status': 'REFUND_SETTLEMENT',
          'payout': 0,
        }),
        isFalse,
      );
    });

    test('3. Paid Payout Strict Separation from Returns', () {
      // Normal settled order
      expect(
        skuDetailHasPayoutV82o({
          'status': 'COMPLETED',
          'payout_status': 'SETTLED',
          'payout': 150000,
          'is_returned': false,
        }),
        isTrue,
      );

      // Cancelled order that somehow had payout value recorded (e.g. adjustment) must NOT count as settled order
      expect(
        skuDetailHasPayoutV82o({
          'status': 'CANCELLED',
          'payout_status': 'SETTLED',
          'payout': 150000,
          'is_returned': false,
        }),
        isFalse,
      );

      // Returned order with is_returned = true
      expect(
        skuDetailHasPayoutV82o({
          'status': 'DELIVERED',
          'payout_status': 'PAID',
          'has_payout': true,
          'is_returned': true,
        }),
        isFalse,
      );
    });

    test('4. Modal Title Label Resolution', () {
      expect(getPayoutModalLabel('returned'), equals('retur / batal'));
      expect(getPayoutModalLabel('batal'), equals('retur / batal'));
      expect(getPayoutModalLabel('retur'), equals('retur / batal'));
      expect(getPayoutModalLabel('paid'), equals('sudah ada payout'));
      expect(getPayoutModalLabel('unpaid'), equals('belum ada payout'));
      expect(getPayoutModalLabel('all'), equals('semua status payout'));
    });

    test('5. Sku Returned Count Map Caching & Fallback Chain', () {
      final returnedKey = 'returned|SKU-001|LOCAL-001|';
      final skuReturnedCountMap = <String, int>{};

      // Initial state: row has 0, map empty, detail rows empty -> 0
      int display1 = computeReturnedQtyDisplay(
        row: {'sku': 'SKU-001'},
        returnedKey: returnedKey,
        skuReturnedCountMap: skuReturnedCountMap,
        returnedDetailRows: [],
      );
      expect(display1, equals(0));

      // Modal loads and populates count map
      skuReturnedCountMap[returnedKey] = 5;

      // Re-evaluation without row update must use cached count map
      int display2 = computeReturnedQtyDisplay(
        row: {'sku': 'SKU-001'},
        returnedKey: returnedKey,
        skuReturnedCountMap: skuReturnedCountMap,
        returnedDetailRows: [],
      );
      expect(display2, equals(5));

      // When row already has qty_returned (e.g. from summary), row takes priority
      int display3 = computeReturnedQtyDisplay(
        row: {'sku': 'SKU-001', 'qty_returned': 8},
        returnedKey: returnedKey,
        skuReturnedCountMap: skuReturnedCountMap,
        returnedDetailRows: [],
      );
      expect(display3, equals(8));

      // Cache clearing (simulating _load() on filter change)
      skuReturnedCountMap.clear();
      int display4 = computeReturnedQtyDisplay(
        row: {'sku': 'SKU-001'},
        returnedKey: returnedKey,
        skuReturnedCountMap: skuReturnedCountMap,
        returnedDetailRows: [],
      );
      expect(display4, equals(0));
    });

    test('6. Summary Merge Invariant (visibleQty = paidQty + unpaidQty + returnedQty)', () {
      final row = {
        'sku': 'TSHIRT-BLK-L',
        'qty': 10,
      };

      final summaryMap = {
        'TSHIRT-BLK-L': {
          'paid_qty': 12,
          'unpaid_qty': 4,
          'qty_returned': 3,
          'hpp_return': 75000,
        }
      };

      final merged = mergeSkuPayoutCountSummaryRow(row, summaryMap, 'TSHIRT-BLK-L');

      expect(merged['paid_qty'], equals(12));
      expect(merged['unpaid_qty'], equals(4));
      expect(merged['qty_returned'], equals(3));
      expect(merged['returned_qty'], equals(3));
      // Total visible quantity must be 12 + 4 + 3 = 19
      expect(merged['qty'], equals(19));
      expect(merged['qty_total'], equals(19));
      expect(merged['sku_count_source'], equals('finance_sku_payout_count_summary'));
    });

    test('7. Filtered SKU Order Rows for returned modal', () {
      final sampleRows = [
        {'ref': 'ORD-1', 'status': 'COMPLETED', 'payout': 100000, 'is_returned': false},
        {'ref': 'ORD-2', 'status': 'SHIPPED', 'payout': 0, 'is_returned': false},
        {'ref': 'ORD-3', 'status': 'BATAL', 'payout': 0, 'is_returned': false},
        {'ref': 'ORD-4', 'status': 'DELIVERED', 'settlement_status': 'RETUR DITERIMA', 'is_returned': false},
        {'ref': 'ORD-5', 'status': 'DELIVERED', 'is_returned': true},
        {'ref': 'ORD-6', 'status': 'RTS', 'payout': 0},
      ];

      final returnedRows = filteredSkuOrderRowsV82o(sampleRows, 'returned');
      expect(returnedRows.map((r) => r['ref']), containsAll(['ORD-3', 'ORD-4', 'ORD-5', 'ORD-6']));
      expect(returnedRows.map((r) => r['ref']), isNot(contains('ORD-1')));
      expect(returnedRows.map((r) => r['ref']), isNot(contains('ORD-2')));
    });
  });
}
