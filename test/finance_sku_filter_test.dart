import 'package:flutter_test/flutter_test.dart';

bool isCancelRefundReturn(Map<String, dynamic> item) {
  if (item['is_returned'] == true) return true;
  final status = (item['status'] ??
          item['order_status'] ??
          item['payout_status'] ??
          item['settlement_status'] ??
          item['finance_status'] ??
          item['abnormal_status'] ??
          '')
      .toString()
      .toUpperCase();

  return status.contains('CANCEL') ||
      status.contains('REFUND') ||
      status.contains('RETURN') ||
      status.contains('BATAL') ||
      status.contains('RETUR');
}

bool skuDetailHasPayout(Map<String, dynamic> row) {
  final rawStatus = (row['status'] ?? row['order_status'] ?? '').toString().toUpperCase();
  final financeStatus = (row['payout_status'] ??
          row['finance_status'] ??
          row['settlement_status'] ??
          '')
      .toString()
      .toUpperCase();
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

  final payout = (row['payout'] ?? row['payout_amount'] ?? 0) as num;
  if (payout != 0) return true;

  if (row['positive_payout_exists'] == true) return true;

  return (financeStatus.contains('SETTLED') && !financeStatus.contains('UNSETTLED')) ||
      financeStatus.contains('PAID') ||
      financeStatus.contains('RELEASE') ||
      financeStatus.contains('PAYOUT_MINUS') ||
      financeStatus.contains('NEGATIVE_PAYOUT');
}

bool skuDetailIsPendingPayout(Map<String, dynamic> row) {
  final rawStatus = (row['status'] ?? row['order_status'] ?? '').toString().toUpperCase();
  final financeStatus = (row['payout_status'] ??
          row['finance_status'] ??
          row['settlement_status'] ??
          '')
      .toString()
      .toUpperCase();
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

  final payout = (row['payout'] ?? row['payout_amount'] ?? 0) as num;
  if (payout != 0) return false;

  if (row['positive_payout_exists'] == true) return false;

  return financeStatus.contains('BELUM') ||
      financeStatus.contains('PENDING') ||
      financeStatus.contains('UNPAID') ||
      financeStatus.contains('MISSING') ||
      financeStatus.contains('UNSETTLED') ||
      financeStatus.trim().isEmpty;
}

List<Map<String, dynamic>> filterSkuOrders(
    List<Map<String, dynamic>> rows, String payoutFilter) {
  if (payoutFilter == 'paid') {
    return rows
        .where((item) =>
            !isCancelRefundReturn(item) &&
            ((item['payout'] ?? 0) as num) > 0)
        .toList();
  }

  if (payoutFilter == 'unpaid') {
    return rows
        .where((item) =>
            !isCancelRefundReturn(item) &&
            ((item['payout'] ?? 0) as num) == 0)
        .toList();
  }

  if (payoutFilter == 'returned' ||
      payoutFilter == 'batal' ||
      payoutFilter == 'retur') {
    return rows.where(isCancelRefundReturn).toList();
  }

  return rows;
}

void main() {
  group('Finance SKU Order Filtering and Classification', () {
    test('isCancelRefundReturn identifies returned/cancelled orders correctly', () {
      expect(isCancelRefundReturn({'is_returned': true, 'status': 'DELIVERED'}), isTrue);
      expect(isCancelRefundReturn({'status': 'CANCELLED'}), isTrue);
      expect(isCancelRefundReturn({'order_status': 'Pesanan Dibatalkan'}), isTrue);
      expect(isCancelRefundReturn({'status': 'RETUR'}), isTrue);
      expect(isCancelRefundReturn({'status': 'REFUND_COMPLETED'}), isTrue);
      expect(isCancelRefundReturn({'status': 'COMPLETED', 'is_returned': false}), isFalse);
    });

    test('skuDetailIsPendingPayout excludes returned/cancelled orders strictly', () {
      final pendingActiveOrder = {
        'status': 'SHIPPED',
        'payout_status': 'UNSETTLED',
        'payout': 0,
        'is_returned': false,
      };
      final pendingReturnedOrder = {
        'status': 'CANCELLED',
        'payout_status': 'UNSETTLED',
        'payout': 0,
        'is_returned': true,
      };
      final returStatusOrder = {
        'status': 'RETUR_DISETUJUI',
        'payout_status': 'UNSETTLED',
        'payout': 0,
      };

      expect(skuDetailIsPendingPayout(pendingActiveOrder), isTrue);
      expect(skuDetailIsPendingPayout(pendingReturnedOrder), isFalse);
      expect(skuDetailIsPendingPayout(returStatusOrder), isFalse);
    });

    test('filterSkuOrders routes returned orders to returned filter', () {
      final orders = [
        {'id': '1', 'status': 'COMPLETED', 'payout': 100000, 'is_returned': false},
        {'id': '2', 'status': 'SHIPPED', 'payout': 0, 'is_returned': false},
        {'id': '3', 'status': 'BATAL', 'payout': 0, 'is_returned': true},
        {'id': '4', 'status': 'RETUR', 'payout': 0, 'is_returned': false},
      ];

      final paid = filterSkuOrders(orders, 'paid');
      final unpaid = filterSkuOrders(orders, 'unpaid');
      final returned = filterSkuOrders(orders, 'returned');

      expect(paid.map((e) => e['id']), ['1']);
      expect(unpaid.map((e) => e['id']), ['2']);
      expect(returned.map((e) => e['id']), ['3', '4']);
    });
  });
}
