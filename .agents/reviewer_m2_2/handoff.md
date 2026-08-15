# Review & Challenge Report: Milestone 2 — Flutter UI Alignment in `finance_report_page.dart`

**Reviewer**: Reviewer 2 (Roles: Reviewer, Critic)  
**Date**: 2026-08-15T03:02:20+07:00  
**Verdict**: **APPROVE**  
**Integrity Assessment**: **PASS** (Zero integrity violations, no facade logic, no hardcoded cheats)

---

## 1. Observation

### Verified Files & Line Ranges
- `lib/features/finance/presentation/finance_report_page.dart`:
  - Lines 144: `final Map<String, int> _skuReturnedCountMap = {};`
  - Lines 2714–2716: `_skuUnpaidCountMap.clear(); _skuPaidCountMap.clear(); _skuReturnedCountMap.clear();` in `_load()`.
  - Lines 3362–3364: Aggregates `qty_returned`, `returned_qty`, `hpp_return` in `addToMapKey`.
  - Lines 3465–3490: Incorporates `returnedQty` into `visibleQty = paidQty + unpaidQty + returnedQty` and assigns `merged['qty_returned'] = returnedQty` in `_mergeSkuPayoutCountSummaryRow`.
  - Lines 10538–10582: Evaluates `returnedDetailRows`, `returnedKey`, `returnedQtyDisplay` with cascading fallbacks from RPC fields, `_skuReturnedCountMap`, and row counts.
  - Lines 10744–10767: Renders `TextButton.icon` with dynamic `Retur/Batal $returnedQtyDisplay` label, red accent styling, loading spinner (`CircularProgressIndicator(strokeWidth: 2)`) when `returnedBusy == true`, and triggers `_showSkuOrderRefsV82o(row, payoutFilter: 'returned')`.
  - Lines 14071–14077 & 14110–14116: Strictly excludes cancelled/returned items (`is_returned == true` or status matching `CANCEL`, `REFUND`, `RETURN`, `BATAL`, `RETUR`) from both `_skuDetailHasPayoutV82o` and `_skuDetailIsPendingPayoutV82o`.
  - Lines 14828–14870: Maps filter variants (`returned`, `batal`, `retur`) to `'retur / batal'` modal header and updates count cache `_skuReturnedCountMap[busyKey] = total`.
  - Lines 15377–15383: Safely disposes `searchController` and resets `_skuDetailBusyKey = null` inside a `finally` block upon modal exit.
  - Lines 16376–16413: Updates legacy `_filteredSkuOrderRows` to support `isCancelRefundReturn` and filter `returned`.
- `test/finance_sku_filter_test.dart`:
  - 3 unit tests verifying `isCancelRefundReturn`, `skuDetailIsPendingPayout`, and `filterSkuOrders`.

### Verbatim Tool Results
1. **Flutter Analyzer**:
   - Command: `flutter analyze --no-fatal-infos --no-fatal-warnings lib/features/finance/presentation/finance_report_page.dart`
   - Exit code: `0` (0 errors found).
2. **Flutter Test Suite**:
   - Command: `flutter test`
   - Exit code: `0`
   - Result: `00:00 +4: All tests passed!`

---

## 2. Logic Chain

1. **R3 Requirement Alignment**: R3 specifies that `finance_report_page.dart` must support `payoutFilter = 'returned'`, display `_skuReturnedCountMap` / returned counts, and open the modal with complete cancelled/returned order rows.
2. **Data Consistency**:
   - When SKU cards render, returned quantities from backend aggregations, cached map totals, and lazy-loaded detail rows are unified into `returnedQtyDisplay`.
   - When a user interacts with the `Retur/Batal` button, `_showSkuOrderRefsV82o(row, payoutFilter: 'returned')` invokes `finance_sku_order_line_details` with `p_payout_filter = 'returned'`.
   - The returned count cache `_skuReturnedCountMap` updates upon receiving RPC responses, preventing desynchronization.
3. **Pending Payout Separation**:
   - Both `_skuDetailHasPayoutV82o` and `_skuDetailIsPendingPayoutV82o` check `row['is_returned'] == true` and string matches for `CANCEL`, `BATAL`, `RETURN`, `RETUR`, `REFUND`.
   - Active pending orders remain strictly isolated from returned/cancelled orders in the UI metrics and modal rows.
4. **Adversarial & Robustness Analysis**:
   - **Null & Type Safety**: Handled via `_text()`, `_num()`, and `_numFirstNonZero()`, preventing runtime null dereferences or `TypeError` crashes.
   - **Resource Lifecycle**: `_skuDetailBusyKey` reset and `searchController.dispose()` are encapsulated in a `finally` block, ensuring no memory leaks or stuck loading spinners if an error occurs or the modal is dismissed rapidly.
   - **State Invalidation**: Cache maps are cleared in `_load()`, ensuring stale counts from previously selected date ranges or store filters do not leak into newly queried data.

---

## 3. Caveats

- End-to-end verification of actual order row data returned from PostgreSQL on live June & July 2026 data is scoped for Milestone 3 (E2E Acceptance Verification).
- Non-breaking deprecation hints in the broader legacy codebase (such as `withOpacity`) remain present and were deliberately untouched to avoid introducing regression risks.

---

## 4. Conclusion

The implementation of Milestone 2 meets all requirements defined in `PROJECT.md` (R3) and `ORIGINAL_REQUEST.md`. Code quality, error resilience, null safety, and state lifecycle management are sound. Zero integrity violations or shortcuts were identified.

**Verdict**: **APPROVE**

---

## 5. Verification Method

To independently reproduce verification:

```powershell
# 1. Run Flutter static analysis on target file
flutter analyze --no-fatal-infos --no-fatal-warnings lib/features/finance/presentation/finance_report_page.dart

# 2. Run project test suite
flutter test
```
