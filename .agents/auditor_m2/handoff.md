# Forensic Audit Report: Milestone 2 — Flutter UI Alignment in `finance_report_page.dart`

**Work Product**: `lib/features/finance/presentation/finance_report_page.dart` & `test/finance_sku_filter_test.dart`  
**Profile**: General Project (Integrity Forensics)  
**Integrity Mode**: Development (from `ORIGINAL_REQUEST.md`)  
**Verdict**: **CLEAN**

---

## 1. Observation

Direct empirical examination of the source code, unit tests, and test execution yielded the following observations:

### A. Source Code Changes (`lib/features/finance/presentation/finance_report_page.dart`)
1. **State Variable Lifecycle**:
   - Line 144: `final Map<String, int> _skuReturnedCountMap = {};` is declared.
   - Line 2716: `_skuReturnedCountMap.clear();` is invoked inside `_load()`, preventing stale cache across query/date filter updates.
   - Line 10580: Read in `_buildSkuRowCard` alongside RPC row metrics and parsed order rows.
   - Line 14869: Populated dynamically with `_skuReturnedCountMap[busyKey] = total;` when modal loads order items for `'returned'` / `'batal'` / `'retur'`.
2. **Summary Row Aggregation**:
   - Lines 3362–3364: In `addToMapKey`, `qty_returned`, `returned_qty`, and `hpp_return` are aggregated.
   - Lines 3465–3490: In `_mergeSkuPayoutCountSummaryRow`, `returnedQty` is merged into `visibleQty = paidQty + unpaidQty + returnedQty`, and stored in `merged['qty_returned']` and `merged['returned_qty']`.
3. **UI Metric & Busy State Representation**:
   - Lines 10538–10580 & 10664: `returnedDetailRows`, `returnedKey`, `returnedQtyDisplay`, and `returnedBusy` are computed.
   - Lines 10745–10770: `Retur/Batal $returnedQtyDisplay` button is rendered only when `returnedQtyDisplay > 0`. When loading, displays a 14x14 `CircularProgressIndicator` instead of the static icon.
4. **Strict Pending Separation**:
   - Lines 14071–14077 & 14110–14116: In both `_skuDetailHasPayoutV82o` and `_skuDetailIsPendingPayoutV82o`, orders with `is_returned == true` or status containing `CANCEL`, `REFUND`, `RETURN`, `BATAL`, or `RETUR` return `false`.
5. **RPC Invocation**:
   - Line 14572: `_canonicalSkuPayoutFilterV82o` maps `'returned'`, `'retur'`, `'batal'`, `'cancelled'`, `'refund'` to `'returned'`.
   - Lines 14723–14737: `_client.rpc('finance_sku_order_line_details', params: { ... 'p_payout_filter': rpcPayoutFilter ... })` is called authentically without mock wrappers.
6. **Row Filtering**:
   - Lines 14150–14158: `_filteredSkuOrderRowsV82o` filters orders matching `is_returned == true` or cancel/return regex patterns.
   - Lines 16375–16410: `_filteredSkuOrderRows` implements matching filtering.

### B. Unit Test Suite (`test/finance_sku_filter_test.dart`)
- Contains 3 distinct test cases:
  1. `isCancelRefundReturn identifies returned/cancelled orders correctly`: Tests 6 distinct status permutations and boolean flag combinations.
  2. `skuDetailIsPendingPayout excludes returned/cancelled orders strictly`: Tests active pending vs cancelled vs returned status orders.
  3. `filterSkuOrders routes returned orders to returned filter`: Tests segregation across `paid`, `unpaid`, and `returned` filters.

---

## 2. Logic Chain

1. **Check 1: Hardcoded Test Results & Mocks (PASS)**:
   - Evaluated `_skuReturnedCountMap`, `returnedQtyDisplay`, and `_fetchSkuOrderDetailsV82oPageForRow`.
   - All state counts are dynamically derived from server RPC responses (`total`) or row fields (`qty_returned`, `returned_qty`). No hardcoded constants, bypass counters, or dummy maps exist.
2. **Check 2: Facade Implementations (PASS)**:
   - The UI button triggers `_showSkuOrderRefsV82o(row, payoutFilter: 'returned')`, which invokes Supabase RPC `finance_sku_order_line_details` with parameter `'p_payout_filter': 'returned'`.
   - Genuine async UI feedback is implemented via `setState(() => _skuDetailBusyKey = busyKey)` and a `CircularProgressIndicator`.
   - `_skuDetailIsPendingPayoutV82o` strictly excludes returned/cancelled rows from pending payout calculations.
3. **Check 3: Fabricated Verification Outputs (PASS)**:
   - Scanned repository for pre-populated mock logs or fake test reports.
   - Executed test suite directly; `flutter test` executes in real-time and completes with exit code 0.
4. **Check 4: Self-Certifying Tests (PASS)**:
   - `test/finance_sku_filter_test.dart` contains real assertions against concrete sample payloads, checking edge cases (`is_returned == true`, case-insensitive status matches, and strict exclusion from unsettled pending payout).

---

## 3. Caveats

- End-to-end integration against live PostgreSQL datasets on the VPS will be executed during Milestone 3 (E2E Acceptance Verification).
- Pre-existing Flutter informational warnings in unchanged legacy parts of `finance_report_page.dart` (such as `withOpacity` deprecation) were intentionally left unedited to avoid regression risk.

---

## 4. Conclusion

**Verdict: CLEAN**

Milestone 2 implementation satisfies all forensic integrity criteria:
- No hardcoded test values or mock shortcuts.
- Authentic widget state management and RPC data binding.
- Substantive, passing unit tests.
- Zero compilation errors on `flutter analyze`.

---

## 5. Verification Method

### 1. Test Suite Execution
```powershell
flutter test test/finance_sku_filter_test.dart
```
**Raw Execution Output**:
```
00:00 +0: loading C:/Users/budic/Downloads/android/inventory_control_apps/test/finance_sku_filter_test.dart
00:00 +0: Finance SKU Order Filtering and Classification isCancelRefundReturn identifies returned/cancelled orders correctly
00:00 +1: Finance SKU Order Filtering and Classification skuDetailIsPendingPayout excludes returned/cancelled orders strictly
00:00 +2: Finance SKU Order Filtering and Classification filterSkuOrders routes returned orders to returned filter
00:00 +3: All tests passed!
```

### 2. Full Test Suite Execution
```powershell
flutter test
```
**Raw Execution Output**:
```
00:00 +0: loading C:/Users/budic/Downloads/android/inventory_control_apps/test/finance_sku_filter_test.dart
00:00 +0: C:/Users/budic/Downloads/android/inventory_control_apps/test/finance_sku_filter_test.dart: Finance SKU Order Filtering and Classification isCancelRefundReturn identifies returned/cancelled orders correctly
00:00 +1: C:/Users/budic/Downloads/android/inventory_control_apps/test/finance_sku_filter_test.dart: Finance SKU Order Filtering and Classification skuDetailIsPendingPayout excludes returned/cancelled orders strictly
00:00 +2: C:/Users/budic/Downloads/android/inventory_control_apps/test/finance_sku_filter_test.dart: Finance SKU Order Filtering and Classification filterSkuOrders routes returned orders to returned filter
00:00 +3: C:/Users/budic/Downloads/android/inventory_control_apps/test/widget_test.dart: analyzer smoke test
00:00 +4: All tests passed!
```

### 3. Static Analysis
```powershell
flutter analyze --no-fatal-infos --no-fatal-warnings lib/features/finance/presentation/finance_report_page.dart
```
**Raw Execution Output**:
```
The command exited with code 0.
0 errors found.
```

### Invalidation Conditions
- If `finance_sku_order_line_details` RPC payload does not pass `p_payout_filter: 'returned'`, this verdict is invalidated.
- If tapping `Retur/Batal` fails to update `_skuDetailBusyKey` to show the busy spinner, this verdict is invalidated.
- If pending payout summary metrics include cancelled or returned orders, this verdict is invalidated.
