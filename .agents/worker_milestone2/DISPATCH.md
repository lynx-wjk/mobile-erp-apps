## 2026-08-14T19:15:02Z
You are Worker 2 (Frontend Flutter Implementation Specialist).
Your working directory is: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\worker_milestone2
Original Request: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\ORIGINAL_REQUEST.md
Workspace Root: c:\Users\budic\Downloads\android\inventory_control_apps
Skills: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\skills\frontend\SKILL.md, c:\Users\budic\Downloads\android\inventory_control_apps\.agents\skills\external-flutter-expert\SKILL.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Background & Context:
Read Explorer 2's handoff report at `c:\Users\budic\Downloads\android\inventory_control_apps\.agents\explorer_survey_frontend\handoff.md`.

Your Objective (Milestone 2 - Flutter UI Alignment in `finance_report_page.dart`):
1. Modify `lib/features/finance/presentation/finance_report_page.dart` to implement all 7 changes from Explorer 2's report:
   - Add `final Map<String, int> _skuReturnedCountMap = {};` in `_FinanceReportPageState`.
   - Clear `_skuReturnedCountMap.clear();` in `_load()`.
   - Update `_fetchSkuPayoutCountSummaryMap` / `_mergeSkuPayoutCountSummaryRow` to aggregate and merge `qty_returned`, `returned_qty`, and `hpp_return`.
   - Update `_buildSkuRowCard` to calculate `returnedQtyDisplay` using `_skuReturnedCountMap[returnedKey]` and `_qtyFromOrderRows(returnedDetailRows)`, add `returnedBusy`, and show the `Retur/Batal $returnedQtyDisplay` button with busy indicator.
   - Tighten `_skuDetailHasPayoutV82o` and `_skuDetailIsPendingPayoutV82o` to exclude orders with `is_returned == true` or status containing `BATAL` or `RETUR`.
   - Update `_showSkuOrderRefsV82o` to set label `'retur / batal'` when `payoutFilter == 'returned'` and populate `_skuReturnedCountMap[busyKey] = total`.
   - Update `_filteredSkuOrderRows` to support `payoutFilter == 'returned'` / `'batal'` / `'retur'`.
2. Run `flutter analyze lib/features/finance/presentation/finance_report_page.dart` and confirm zero compilation errors.
3. Document all edits and verification output in `c:\Users\budic\Downloads\android\inventory_control_apps\.agents\worker_milestone2\handoff.md`.
4. Message the orchestrator with your results.
