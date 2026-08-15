# Handoff Report: Frontend Flutter Specialist (Explorer 2)

## 1. Observation

### Target File
- File path: `c:\Users\budic\Downloads\android\inventory_control_apps\lib\features\finance\presentation\finance_report_page.dart` (17,591 lines).

### Key Code Findings

1. **Missing State Variable `_skuReturnedCountMap`**
   - At lines 142–143:
     ```dart
     final Map<String, int> _skuUnpaidCountMap = {};
     final Map<String, int> _skuPaidCountMap = {};
     ```
     `_skuReturnedCountMap` is not declared in `_FinanceReportPageState`.

2. **SKU Card Metrics Calculation (`_buildSkuRowCard`)**
   - At lines 10513–10556:
     ```dart
     final skuDetailRows = _safeOrderRefRows(row);
     final paidDetailRows = _filteredSkuOrderRows(skuDetailRows, 'paid');
     final unpaidDetailRows = _filteredSkuOrderRows(skuDetailRows, 'unpaid');
     final paidKey = _skuDetailBusyKeyV82o(row, 'paid');
     final unpaidKey = _skuDetailBusyKeyV82o(row, 'unpaid');
     ```
     Missing:
     - `final returnedKey = _skuDetailBusyKeyV82o(row, 'returned');`
     - `final returnedDetailRows = _filteredSkuOrderRows(skuDetailRows, 'returned');`
     - `returnedQtyDisplay` calculation only checks `row['qty_returned']`, `row['returned_qty']`, `row['qty_batal']`, `row['batal_qty']`, but ignores `_skuReturnedCountMap[returnedKey]` and `_qtyFromOrderRows(returnedDetailRows)`.
   - At lines 10638–10641:
     - `settledBusy` and `unpaidBusy` are computed, but `returnedBusy` (`_skuDetailBusyKey == _skuDetailBusyKeyV82o(row, 'returned')`) is missing, leaving the `Retur/Batal` button without a busy progress indicator during fetch.

3. **RPC Invocation (`_fetchSkuOrderDetailsV82oPageForRow`)**
   - At lines 14683–14697:
     ```dart
     final response = await _client.rpc(
       'finance_sku_order_line_details',
       params: {
         'p_start': _toDateParam(_start),
         'p_end': _toDateParam(_end),
         'p_marketplace': detailMarketplace,
         'p_account_id': detailAccountId,
         'p_marketplace_sku': marketplaceSkuParam,
         'p_local_sku': localSkuParam,
         'p_search': searchParam,
         'p_payout_filter': rpcPayoutFilter,
         'p_page': page,
         'p_page_size': pageSize,
       },
     );
     ```
   - `rpcPayoutFilter` is mapped via `_canonicalSkuPayoutFilterV82o('returned')` which outputs `'returned'`.
   - Parameter types and names match PostgreSQL function signature: `p_start` (date), `p_end` (date), `p_marketplace` (text), `p_account_id` (uuid), `p_marketplace_sku` (text), `p_local_sku` (text), `p_search` (text), `p_payout_filter` (text), `p_page` (int), `p_page_size` (int).

4. **Modal Opening & Payout Labeling (`_showSkuOrderRefsV82o`)**
   - At lines 14788–14793:
     ```dart
     final payoutLabel = payoutFilter == 'paid'
         ? 'sudah ada payout'
         : payoutFilter == 'unpaid'
             ? 'belum ada payout'
             : 'semua status payout';
     ```
     Does not map `payoutFilter == 'returned'` to `'retur / batal'`.
   - At lines 14822–14826:
     ```dart
     if (payoutFilter == 'unpaid') {
       _skuUnpaidCountMap[busyKey] = total;
     } else if (payoutFilter == 'paid') {
       _skuPaidCountMap[busyKey] = total;
     }
     ```
     Missing population:
     ```dart
     else if (payoutFilter == 'returned') {
       _skuReturnedCountMap[busyKey] = total;
     }
     ```

5. **Filtering Functions for Strict Separation (`_filteredSkuOrderRowsV82o` & `_filteredSkuOrderRows`)**
   - In `_skuDetailIsPendingPayoutV82o` (lines 14073–14077): checks `joinedStatus.contains('CANCEL') || joinedStatus.contains('REFUND') || joinedStatus.contains('RETURN')`, but does not explicitly check `joinedStatus.contains('BATAL')` or `row['is_returned'] == true`.
   - In `_skuDetailHasPayoutV82o` (lines 14037–14041): checks `CANCEL/REFUND/RETURN`, but does not explicitly check `BATAL` or `row['is_returned'] == true`.
   - In `_filteredSkuOrderRows` (lines 16328–16363): does not have a branch for `payoutFilter == 'returned'`, falling through to returning all deduped rows without filtering.

6. **Summary Map Overlay (`_fetchSkuPayoutCountSummaryMap` & `_mergeSkuPayoutCountSummaryRow`)**
   - At lines 3351–3375: `addToMapKey` aggregates `paid_qty` and `unpaid_qty`, but does not aggregate `qty_returned` / `returned_qty` or `hpp_return`.
   - At line 3458: `visibleQty` is computed as `paidQty + unpaidQty`, omitting `returnedQty`.

---

## 2. Logic Chain

1. When a user navigates to the SKU report, the UI displays SKU cards with buttons for `Detail SKU`, `Settled [qty]`, `Belum payout [qty]`, and `Retur/Batal [qty]`.
2. To accurately display the returned quantity and enable dynamic updates after the modal fetches order lines:
   - `_skuReturnedCountMap` must be declared and populated when `_fetchSkuOrderDetailsV82oPageForRow` succeeds for `payoutFilter = 'returned'`.
   - `returnedQtyDisplay` in `_buildSkuRowCard` must check `_skuReturnedCountMap[returnedKey]` and `_qtyFromOrderRows(returnedDetailRows)`.
3. When the user taps `Retur/Batal [qty]`, `_showSkuOrderRefsV82o(row, payoutFilter: 'returned')` is triggered.
   - `_canonicalSkuPayoutFilterV82o` translates `'returned'` into `'returned'`, which is sent to Supabase RPC `finance_sku_order_line_details`.
   - The returned rows are filtered by `_filteredSkuOrderRowsV82o(rawRows, 'returned')` which keeps rows where `is_returned == true` or status matches `(cancel|batal|return|refund|rts|gagal|closed)`.
   - The modal sheet opens, displaying header `'... · retur / batal · Deduped by order line/facts'` and the full order rows with search and pagination controls.
4. For strict separation of pending orders vs returned/cancelled orders (R2/R3):
   - `_skuDetailIsPendingPayoutV82o` and `_skuDetailHasPayoutV82o` must explicitly exclude orders with `is_returned == true` or status containing `BATAL` / `RETUR`.
   - `_filteredSkuOrderRows` must implement the `payoutFilter == 'returned'` branch.
5. In `_load()`, all cache maps (`_skuUnpaidCountMap`, `_skuPaidCountMap`, `_skuReturnedCountMap`) must be cleared on filter/date changes so stale counts do not persist.

---

## 3. Caveats

- **Existing Deprecation Warnings in Codebase**: `flutter analyze` produces 968 deprecation info items (e.g. `.withOpacity()` vs `.withValues()`) across unrelated feature folders (`lib/features/stock/`, `lib/features/supplier/`, etc.), but zero compile errors.
- **RPC Dependency**: The frontend modal depends on backend RPC `finance_sku_order_line_details` returning rows when `p_payout_filter = 'returned'`. The backend team/agent must implement R1 in SQL to ensure backend RPC does not filter out cancelled/returned orders before returning jsonb.
- **No Direct Source Editing During Exploration**: Code changes are formulated here for execution during the implementation phase.

---

## 4. Conclusion & Concrete Proposed Changes

### Proposed Code Changes in `lib/features/finance/presentation/finance_report_page.dart`:

#### Change 1: Add `_skuReturnedCountMap` declaration
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:143
  final Map<String, int> _skuUnpaidCountMap = {};
  final Map<String, int> _skuPaidCountMap = {};
  final Map<String, int> _skuReturnedCountMap = {};
```

#### Change 2: Clear `_skuReturnedCountMap` on `_load()`
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:2712
      _skuUnpaidCountMap.clear();
      _skuPaidCountMap.clear();
      _skuReturnedCountMap.clear();
```

#### Change 3: Update `_skuPayoutCountSummary` aggregation & merge
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:3357
          existing['qty_returned'] = _num(existing['qty_returned']) + _num(row['qty_returned'] ?? row['returned_qty']);
          existing['returned_qty'] = _num(existing['returned_qty']) + _num(row['returned_qty'] ?? row['qty_returned']);
          existing['hpp_return'] = _num(existing['hpp_return']) + _num(row['hpp_return'] ?? row['hpp_retur'] ?? row['return_hpp']);

// Location: lib/features/finance/presentation/finance_report_page.dart:3458
    final returnedQty = _numFirstNonZero([
      summary['qty_returned'],
      summary['returned_qty'],
      summary['qty_batal'],
      summary['batal_qty'],
      summary['returned_rows'],
      summary['returned_total'],
    ]).round();
    final visibleQty = paidQty + unpaidQty + returnedQty;
    if (returnedQty > 0) {
      merged['qty_returned'] = returnedQty;
      merged['returned_qty'] = returnedQty;
    }
```

#### Change 4: Update SKU Card metric calculation & busy state in `_buildSkuRowCard`
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:10513
    final skuDetailRows = _safeOrderRefRows(row);
    final paidDetailRows =
        _filteredSkuOrderRows(skuDetailRows, 'paid');
    final unpaidDetailRows =
        _filteredSkuOrderRows(skuDetailRows, 'unpaid');
    final returnedDetailRows =
        _filteredSkuOrderRows(skuDetailRows, 'returned');
    final rowTotalQty = _numFirstNonZero([
      row['qty'],
      row['qty_total'],
      row['total_qty'],
    ]).round();
    final paidKey = _skuDetailBusyKeyV82o(row, 'paid');
    final unpaidKey = _skuDetailBusyKeyV82o(row, 'unpaid');
    final returnedKey = _skuDetailBusyKeyV82o(row, 'returned');
    ...
    int returnedQtyDisplay = _numFirstNonZero([
      row['qty_returned'],
      row['returned_qty'],
      row['qty_batal'],
      row['batal_qty'],
      _skuReturnedCountMap[returnedKey],
      _qtyFromOrderRows(returnedDetailRows),
    ]).round();
```
And add `returnedBusy`:
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:10640
    final settledBusy =
        _skuDetailBusyKey == _skuDetailBusyKeyV82o(row, 'paid');
    final unpaidBusy =
        _skuDetailBusyKey == _skuDetailBusyKeyV82o(row, 'unpaid');
    final returnedBusy =
        _skuDetailBusyKey == _skuDetailBusyKeyV82o(row, 'returned');
    final detailBusy = _skuDetailBusyKey != null;
```
And update Retur/Batal icon:
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:10717
          if (returnedQtyDisplay > 0)
            TextButton.icon(
              onPressed: detailBusy
                  ? null
                  : () => _showSkuOrderRefsV82o(
                        row,
                        payoutFilter: 'returned',
                      ),
              icon: returnedBusy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.assignment_return_rounded, size: 16, color: Colors.red.shade600),
              label: Text('Retur/Batal $returnedQtyDisplay',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade600, fontWeight: FontWeight.w700)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
```

#### Change 5: Tighten `_skuDetailHasPayoutV82o` and `_skuDetailIsPendingPayoutV82o`
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:14037 & 14073
    if (row['is_returned'] == true ||
        joinedStatus.contains('CANCEL') ||
        joinedStatus.contains('REFUND') ||
        joinedStatus.contains('RETURN') ||
        joinedStatus.contains('BATAL') ||
        joinedStatus.contains('RETUR')) {
      return false;
    }
```

#### Change 6: Update `_showSkuOrderRefsV82o` and `_showSkuOrderRefs`
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:14788
    final payoutLabel = payoutFilter == 'paid'
        ? 'sudah ada payout'
        : payoutFilter == 'unpaid'
            ? 'belum ada payout'
            : (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur')
                ? 'retur / batal'
                : 'semua status payout';

// Location: lib/features/finance/presentation/finance_report_page.dart:14822
    if (payoutFilter == 'unpaid') {
      _skuUnpaidCountMap[busyKey] = total;
    } else if (payoutFilter == 'paid') {
      _skuPaidCountMap[busyKey] = total;
    } else if (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur') {
      _skuReturnedCountMap[busyKey] = total;
    }
```

#### Change 7: Support `returned` filter in `_filteredSkuOrderRows`
```dart
// Location: lib/features/finance/presentation/finance_report_page.dart:16330
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

    final deduped = _dedupeSkuDetailRows(rows);

    if (payoutFilter == 'paid') {
      return deduped
          .where(
              (item) => !isCancelRefundReturn(item) && _hasReleasedPayout(item))
          .toList();
    }

    if (payoutFilter == 'unpaid') {
      return deduped
          .where((item) =>
              !isCancelRefundReturn(item) && !_hasReleasedPayout(item))
          .toList();
    }

    if (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur') {
      return deduped.where(isCancelRefundReturn).toList();
    }

    return deduped;
```

---

## 5. Verification Method

1. **Static Analysis**:
   - Run `flutter analyze lib/features/finance/presentation/finance_report_page.dart`
   - Ensure 0 errors.
2. **Smoke / Unit Test**:
   - Run `flutter test test/widget_test.dart`
   - Ensure all tests pass.
3. **Web Build Verification**:
   - Run `flutter build web --release`
   - Ensure build output completes with exit code 0 into `build/web/`.
4. **Behavioral Invalidation Conditions**:
   - If clicking `Retur/Batal [qty]` opens an empty modal despite backend returning rows, check `_filteredSkuOrderRowsV82o` predicate against returned row status fields.
   - If `Belum payout` count contains returned orders, check `_skuDetailIsPendingPayoutV82o` exclusions.
