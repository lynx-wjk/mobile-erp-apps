# Challenger 2 Handoff Report: Milestone 2 (Flutter UI Alignment)

**Verdict**: **CONFIRM_CORRECTNESS**

---

## 1. Observation

### Target Codebase Inspection
- **File**: `lib/features/finance/presentation/finance_report_page.dart`
- **Line 144**: `final Map<String, int> _skuReturnedCountMap = {};` declared.
- **Line 2716**: `_skuReturnedCountMap.clear();` executed within `_load()`, ensuring cache invalidation whenever date range or filters change.
- **Lines 3362–3364**: Summary map aggregation handles `qty_returned`, `returned_qty`, and `hpp_return`:
  ```dart
  existing['qty_returned'] = _num(existing['qty_returned']) + _num(row['qty_returned'] ?? row['returned_qty']);
  existing['returned_qty'] = _num(existing['returned_qty']) + _num(row['returned_qty'] ?? row['qty_returned']);
  existing['hpp_return'] = _num(existing['hpp_return']) + _num(row['hpp_return'] ?? row['hpp_retur'] ?? row['return_hpp']);
  ```
- **Lines 3465–3497**: `_mergeSkuPayoutCountSummaryRow` calculates `visibleQty = paidQty + unpaidQty + returnedQty`, ensuring returned items contribute correctly to the SKU's total quantity and stores `merged['qty_returned'] = returnedQty; merged['returned_qty'] = returnedQty;`.
- **Lines 10539–10582**: `_buildSkuRowCard` computes `returnedDetailRows`, `returnedKey`, `returnedQtyDisplay` using fallback chain:
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
- **Lines 10744–10767**: Renders `Retur/Batal $returnedQtyDisplay` button with red warning styling, loading spinner (`CircularProgressIndicator(strokeWidth: 2)`) when `returnedBusy` is true, and routes click to `_showSkuOrderRefsV82o(row, payoutFilter: 'returned')`.
- **Lines 14071–14077 & 14110–14116**: `_skuDetailHasPayoutV82o` and `_skuDetailIsPendingPayoutV82o` strictly exclude rows where `row['is_returned'] == true` or `joinedStatus` contains `CANCEL`, `REFUND`, `RETURN`, `BATAL`, `RETUR`.
- **Lines 14567–14573**: `_canonicalSkuPayoutFilterV82o` maps `'returned'`, `'retur'`, `'batal'`, `'cancelled'`, `'refund'` to `'returned'`.
- **Lines 14723–14737**: RPC call to `finance_sku_order_line_details` passes `'p_payout_filter': rpcPayoutFilter`.
- **Lines 14828–14835 & 14869**: `_showSkuOrderRefsV82o` maps payout filter to label `'retur / batal'` and populates `_skuReturnedCountMap[busyKey] = total;` upon receiving server response.
- **Lines 16375–16413**: `_filteredSkuOrderRows` handles `payoutFilter == 'returned'` / `'batal'` / `'retur'` via `isCancelRefundReturn`.

### Empirical Test Execution
- **Command**: `flutter test test/milestone2_adversarial_challenger_test.dart`
- **Output**:
  ```
  00:00 +0: Challenger 2 Empirical Verification for Milestone 2 1. RPC Parameter Canonicalization for payoutFilter
  00:00 +1: Challenger 2 Empirical Verification for Milestone 2 2. Strict Pending Payout Separation (Adversarial Edge Cases)
  00:00 +2: Challenger 2 Empirical Verification for Milestone 2 3. Paid Payout Strict Separation from Returns
  00:00 +3: Challenger 2 Empirical Verification for Milestone 2 4. Modal Title Label Resolution
  00:00 +4: Challenger 2 Empirical Verification for Milestone 2 5. Sku Returned Count Map Caching & Fallback Chain
  00:00 +5: Challenger 2 Empirical Verification for Milestone 2 6. Summary Merge Invariant (visibleQty = paidQty + unpaidQty + returnedQty)
  00:00 +6: Challenger 2 Empirical Verification for Milestone 2 7. Filtered SKU Order Rows for returned modal
  00:00 +7: All tests passed!
  ```
- **Command**: `flutter test`
- **Output**:
  ```
  00:00 +38: All tests passed! (38 test cases across all test suites)
  ```
- **Command**: `flutter analyze --no-fatal-infos --no-fatal-warnings lib/features/finance/presentation/finance_report_page.dart`
- **Output**: `0 errors found` (Exit Code 0).

---

## 2. Logic Chain

1. **RPC Parameter Passing**:
   - Tapping `Retur/Batal` invokes `_showSkuOrderRefsV82o(row, payoutFilter: 'returned')` (Observation: Line 10748).
   - `_fetchSkuOrderDetailsV82oPageForRow` passes `'p_payout_filter': rpcPayoutFilter` where `_canonicalSkuPayoutFilterV82o('returned')` yields `'returned'` (Observation: Lines 14567, 14733).
   - Backend RPC `finance_sku_order_line_details` correctly receives `p_payout_filter = 'returned'`.
2. **Modal Title and Presentation**:
   - `_showSkuOrderRefsV82o` maps `'returned'` to label `'retur / batal'`, which dynamically sets the sheet header to `Detail Order SKU (retur / batal)` and displays accurate error/loading messages (Observation: Line 14833).
3. **Cache Synchronization & Flicker Prevention**:
   - When the RPC returns the paginated response, `_skuReturnedCountMap[busyKey] = total` caches the returned quantity (Observation: Line 14869).
   - `_buildSkuRowCard` checks `_skuReturnedCountMap[returnedKey]` in the fallback chain, preventing zero-flicker or count drops during intermediate UI rebuilds (Observation: Line 10580).
   - When `_load()` runs due to date or store filter changes, `_skuReturnedCountMap.clear()` flushes cache entries to prevent cross-period count pollution (Observation: Line 2716).
4. **Strict Pending vs Returned Separation**:
   - Both `_skuDetailIsPendingPayoutV82o` and `_skuDetailHasPayoutV82o` filter out any order with `is_returned == true` or status containing `CANCEL|REFUND|RETURN|BATAL|RETUR` (Observation: Lines 14071, 14110).
   - All returned/cancelled orders are strictly routed to the Retur/Batal bucket and excluded from unpaid/pending metrics.

---

## 3. Caveats

- Milestone 2 covers the Flutter UI logic in `finance_report_page.dart`. Live backend RPC database verification with live June/July 2026 data on VPS is part of Milestone 3.

---

## 4. Conclusion

**Verdict**: **CONFIRM_CORRECTNESS**

The implementation in `lib/features/finance/presentation/finance_report_page.dart` adheres completely to the interface contracts, properly handles `payoutFilter = 'returned'`, synchronizes the `_skuReturnedCountMap` cache, strictly separates pending payout from returned orders, and passes all 38 unit and adversarial stress tests with zero compilation errors.

---

## 5. Verification Method

To independently verify this assessment:

1. **Run full Flutter test suite**:
   ```powershell
   flutter test
   ```
   *Expected: All 38 tests pass.*

2. **Run dedicated Challenger 2 test suite**:
   ```powershell
   flutter test test/milestone2_adversarial_challenger_test.dart
   ```
   *Expected: All 7 adversarial tests pass.*

3. **Run Flutter static analysis on target file**:
   ```powershell
   flutter analyze --no-fatal-infos --no-fatal-warnings lib/features/finance/presentation/finance_report_page.dart
   ```
   *Expected: 0 errors.*

### Invalidation Conditions
- If passing `payoutFilter = 'returned'` sends anything other than `'returned'` to `finance_sku_order_line_details`, this conclusion is invalidated.
- If `_skuDetailIsPendingPayoutV82o` returns `true` for any cancelled or returned order, this conclusion is invalidated.
