# Handoff Report: Milestone 2 — Flutter UI Alignment in `finance_report_page.dart`

## 1. Observation

### Target File
- File path: `c:\Users\budic\Downloads\android\inventory_control_apps\lib\features\finance\presentation\finance_report_page.dart`
- Test file: `c:\Users\budic\Downloads\android\inventory_control_apps\test\finance_sku_filter_test.dart`

### Code Modifications Implemented

1. **Declared `_skuReturnedCountMap` state variable**
   - Line 144: `final Map<String, int> _skuReturnedCountMap = {};` added alongside `_skuUnpaidCountMap` and `_skuPaidCountMap`.

2. **Cleared `_skuReturnedCountMap` in `_load()`**
   - Lines 2714–2716:
     ```dart
     _skuUnpaidCountMap.clear();
     _skuPaidCountMap.clear();
     _skuReturnedCountMap.clear();
     ```
   - Prevents stale count cache from lingering across filter/date changes.

3. **Updated Summary Map Aggregation & Row Merge**
   - In `addToMapKey` (lines 3362–3364):
     ```dart
     existing['qty_returned'] = _num(existing['qty_returned']) + _num(row['qty_returned'] ?? row['returned_qty']);
     existing['returned_qty'] = _num(existing['returned_qty']) + _num(row['returned_qty'] ?? row['qty_returned']);
     existing['hpp_return'] = _num(existing['hpp_return']) + _num(row['hpp_return'] ?? row['hpp_retur'] ?? row['return_hpp']);
     ```
   - In `_mergeSkuPayoutCountSummaryRow` (lines 3465–3485):
     Extracts `returnedQty` from summary, adds it to `visibleQty = paidQty + unpaidQty + returnedQty`, and stores `merged['qty_returned'] = returnedQty; merged['returned_qty'] = returnedQty;`.

4. **Updated `_buildSkuRowCard` Metric Calculation & Busy Indicator**
   - In `_buildSkuRowCard` (lines 10538–10580):
     - Added `final returnedDetailRows = _filteredSkuOrderRows(skuDetailRows, 'returned');`
     - Added `final returnedKey = _skuDetailBusyKeyV82o(row, 'returned');`
     - Updated `returnedQtyDisplay`:
       ```dart
       int returnedQtyDisplay = _numFirstNonZero([
         row['qty_returned'],
         row['returned_qty'],
         row['qty_batal'],
         row['batal_qty'],
         _skuReturnedCountMap[returnedKey],
         _qtyFromOrderRows(returnedDetailRows),
       ]).round();
       ```
     - Added `final returnedBusy = _skuDetailBusyKey == _skuDetailBusyKeyV82o(row, 'returned');`
     - Added busy spinner (`CircularProgressIndicator(strokeWidth: 2)`) to `Retur/Batal $returnedQtyDisplay` button when loading.

5. **Tightened `_skuDetailHasPayoutV82o` and `_skuDetailIsPendingPayoutV82o`**
   - Lines 14071–14077 and lines 14110–14116:
     ```dart
     if (row['is_returned'] == true ||
         joinedStatus.contains('CANCEL') ||
         joinedStatus.contains('REFUND') ||
         joinedStatus.contains('RETURN') ||
         joinedStatus.contains('BATAL') ||
         joinedStatus.contains('RETUR')) {
       return false;
     }
     ```
   - Strictly excludes returned or cancelled orders from both settled/paid and unsettled/pending payout metrics.

6. **Updated Modal Title and Dynamic Count Map Cache in `_showSkuOrderRefsV82o` and `_showSkuOrderRefs`**
   - Lines 14829–14867:
     - Maps `payoutFilter == 'returned'` / `'batal'` / `'retur'` to label `'retur / batal'`.
     - Populates `_skuReturnedCountMap[busyKey] = total;` when modal loads order items.
   - Lines 15408–15413: Updated legacy `_showSkuOrderRefs` fallback label.

7. **Updated `_filteredSkuOrderRows`**
   - Lines 16375–16410:
     - `isCancelRefundReturn` checks `is_returned == true`, `CANCEL`, `REFUND`, `RETURN`, `BATAL`, `RETUR`.
     - Added branch `if (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur') return deduped.where(isCancelRefundReturn).toList();`.

---

## 2. Logic Chain

1. **Retur/Batal Count Visibility**: When SKU cards render, `returnedQtyDisplay` checks RPC-returned returned quantities, cached counts from `_skuReturnedCountMap[returnedKey]`, and parsed rows from `returnedDetailRows`. When `returnedQtyDisplay > 0`, the `Retur/Batal` button is displayed with the count.
2. **Interactive Loading**: Clicking `Retur/Batal` triggers `_showSkuOrderRefsV82o(row, payoutFilter: 'returned')`. While the RPC call `finance_sku_order_line_details` is in flight, `returnedBusy` displays a 14x14 CircularProgressIndicator on the button.
3. **Modal Display & Cache Refresh**: Once RPC returns, the total returned count is stored in `_skuReturnedCountMap[busyKey] = total`, and the modal displays the order lines under the label `retur / batal`.
4. **Strict Pending Separation**: Active orders awaiting payout remain in `unpaid` / `pending`, while any order marked with `is_returned == true` or status matching `CANCEL / BATAL / RETURN / RETUR / REFUND` is excluded from pending payout and routed to the retur/batal category.

---

## 3. Caveats

- The live modal content depends on backend RPC `finance_sku_order_line_details` returning order records for `p_payout_filter = 'returned'` (addressed in Milestone 1).
- Existing Flutter info warnings across the codebase (e.g. `withOpacity` deprecation) were preserved without unrelated refactoring to keep edits minimal and safe.

---

## 4. Conclusion

All 7 required frontend UI changes in `finance_report_page.dart` have been implemented cleanly according to specifications. Static analysis completes with 0 errors and all unit tests pass.

---

## 5. Verification Method

### 1. Static Analysis
Command:
```powershell
flutter analyze --no-fatal-infos --no-fatal-warnings lib/features/finance/presentation/finance_report_page.dart
```
Result:
```
The command exited with code 0.
0 errors found.
```

### 2. Unit Testing
Command:
```powershell
flutter test
```
Result:
```
00:00 +4: All tests passed! (including test/finance_sku_filter_test.dart)
```

### Invalidation Conditions
- If tapping `Retur/Batal` fails to display a loading indicator, inspect `returnedBusy` assignment.
- If pending payout includes returned orders, inspect `_skuDetailIsPendingPayoutV82o` exclusions.
