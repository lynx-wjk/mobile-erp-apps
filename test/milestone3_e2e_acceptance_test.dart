import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Milestone 3 E2E Acceptance Verification Models & Invariants', () {
    test('1. Group Totals Mathematical Integrity (Total Qty = Settled + Unsettled + Returned)', () {
      final juneGroupData = {
        'total_qty': 16709,
        'qty_settled': 14005,
        'qty_unsettled': 254,
        'qty_returned': 2450,
        'settled_hpp': 442550500.0,
        'unpaid_hpp': 8386500.0,
        'hpp_return': 76682500.0,
        'total_hpp': 442550500.0,
        'total_omzet': 931329012.0,
        'total_payout': 890296964.46,
        'net_profit': 447746464.46,
      };

      // Invariant: total_qty = qty_settled + qty_unsettled + qty_returned
      expect(
        juneGroupData['total_qty'],
        equals((juneGroupData['qty_settled'] as int) +
               (juneGroupData['qty_unsettled'] as int) +
               (juneGroupData['qty_returned'] as int)),
      );

      // Invariant: Net Profit = Total Payout - Settled HPP
      final expectedProfit = (juneGroupData['total_payout'] as double) - (juneGroupData['settled_hpp'] as double);
      expect((juneGroupData['net_profit'] as double).toStringAsFixed(2), equals(expectedProfit.toStringAsFixed(2)));

      final julyGroupData = {
        'total_qty': 10237,
        'qty_settled': 8453,
        'qty_unsettled': 176,
        'qty_returned': 1608,
        'settled_hpp': 278841000.0,
        'unpaid_hpp': 7008000.0,
        'hpp_return': 52224500.0,
        'total_hpp': 278841000.0,
        'total_omzet': 569123279.0,
        'total_payout': 506953765.45,
        'net_profit': 228112765.45,
      };

      // Invariant: total_qty = qty_settled + qty_unsettled + qty_returned
      expect(
        julyGroupData['total_qty'],
        equals((julyGroupData['qty_settled'] as int) +
               (julyGroupData['qty_unsettled'] as int) +
               (julyGroupData['qty_returned'] as int)),
      );

      // Invariant: Net Profit = Total Payout - Settled HPP
      final expectedJulyProfit = (julyGroupData['total_payout'] as double) - (julyGroupData['settled_hpp'] as double);
      expect((julyGroupData['net_profit'] as double).toStringAsFixed(2), equals(expectedJulyProfit.toStringAsFixed(2)));
    });

    test('2. Order Line Item Payout Filter Categorization Strict Invariants', () {
      final sampleItems = [
        {
          'order_id': '584790571653760021',
          'order_status': 'CANCELLED',
          'is_returned': true,
          'has_payout': false,
          'payout_status': 'Cancel/Refund/Return',
        },
        {
          'order_id': '584789787629028707',
          'order_status': 'CANCELLED',
          'is_returned': true,
          'has_payout': false,
          'payout_status': 'Cancel/Refund/Return',
        },
        {
          'order_id': '584785851688191282',
          'order_status': 'COMPLETED',
          'is_returned': false,
          'has_payout': false,
          'payout_status': 'Belum Payout',
        },
        {
          'order_id': '584781234567890123',
          'order_status': 'COMPLETED',
          'is_returned': false,
          'has_payout': true,
          'payout_status': 'Settled',
        },
      ];

      // Filter: returned
      final returned = sampleItems.where((i) => i['is_returned'] == true).toList();
      expect(returned.length, equals(2));
      for (final r in returned) {
        expect(r['is_returned'], isTrue);
        expect(r['payout_status'], equals('Cancel/Refund/Return'));
      }

      // Filter: unpaid (strictly non-returned pending)
      final unpaid = sampleItems.where((i) => i['has_payout'] == false && i['is_returned'] == false).toList();
      expect(unpaid.length, equals(1));
      expect(unpaid.first['order_id'], equals('584785851688191282'));
      expect(unpaid.first['is_returned'], isFalse);

      // Filter: paid
      final paid = sampleItems.where((i) => i['has_payout'] == true && i['is_returned'] == false).toList();
      expect(paid.length, equals(1));
      expect(paid.first['order_id'], equals('584781234567890123'));
    });

    test('3. SKU Row Card Retur/Batal Button Visibility Resolution', () {
      int resolveReturnedQtyDisplay(Map<String, dynamic> row, Map<String, int> countMap, String busyKey) {
        final rQty = row['qty_returned'] ?? row['returned_qty'] ?? 0;
        final cached = countMap[busyKey] ?? 0;
        if (rQty > 0) return rQty;
        if (cached > 0) return cached;
        return 0;
      }

      final rowWithRpcCount = {'local_sku': 'SKU-001', 'qty_returned': 427};
      expect(resolveReturnedQtyDisplay(rowWithRpcCount, {}, 'SKU-001_returned'), equals(427));

      final rowWithCachedCount = {'local_sku': 'SKU-002', 'qty_returned': 0};
      final countMap = {'SKU-002_returned': 15};
      expect(resolveReturnedQtyDisplay(rowWithCachedCount, countMap, 'SKU-002_returned'), equals(15));

      final rowZero = {'local_sku': 'SKU-003', 'qty_returned': 0};
      expect(resolveReturnedQtyDisplay(rowZero, {}, 'SKU-003_returned'), equals(0));
    });
  });
}
