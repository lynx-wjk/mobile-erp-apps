# State Enrichment & Data Pipeline Debugging Rules

## 1. Explicit Local Variable Parameter Passing
When writing or patching enrichment/transformation helpers during state updates:
- **DO NOT** reference unupdated instance/class state variables (e.g. `this._stateVar` or `_summary`) inside helper methods.
- **ALWAYS** pass newly computed local variables explicitly as function arguments (e.g., `_enrichMarketplaceRowsHppFromSku(..., summary: displaySummary)`).

## 2. Audit All State Assignment Entry Points
When adding enrichment or fallback logic to a state variable (e.g., `_profitLossByMarketplace` or `_byMarketplace`):
- Audit **every single function** that assigns to or updates that state variable:
  - Initial snapshot processing (`_applyFinanceSnapshotData`)
  - Cache hits (`_financeLoadCache`)
  - Background/supplemental data loading (`_loadProfitLossSupplemental`)
  - User filter/tab change callbacks
- Ensure **all** assignment paths execute the exact same enrichment pipeline before setting state.

## 3. Double Defense: Fallback Calculations in UI Rendering
When derived metrics (such as HPP, Laba, or Margin) depend on calculated summaries:
- In addition to state enrichment pipelines, include fail-safe fallback logic inside widget rendering loops (e.g., Tab Marketplace card mapping).
- If a row field evaluates to `0` or missing but the parent summary contains `Total HPP > 0`, calculate:
  $$\text{HPP}_{\text{row}} = \left( \frac{\text{Omzet}_{\text{row}}}{\text{Total Omzet}} \right) \times \text{Total HPP}_{\text{summary}}$$
- This guarantees the UI rendering never displays `HPP Rp 0` even during asynchronous background reloads or temporary state hydration gaps.

## 4. Mandatory Pre-Patch Parameter Flow Inspection
Before declaring a state-enrichment patch complete:
- Trace the exact parameter execution order from function entry to `setState()`.
- Verify that no downstream or parallel asynchronous method overwrites the enriched state with raw/un-enriched data.
