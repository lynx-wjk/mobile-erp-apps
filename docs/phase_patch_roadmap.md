# Mobile ERP Phase Patch Roadmap

This document outlines the roadmap for future development phases (Phases 3 to 10), detailing how subsequent work can be executed incrementally and safely with minimal AI tokens and zero risk to stable systems.

---

## Roadmap Overview

```mermaid
graph TD
    Hotfix3E[Hotfix 3E: Invite Links] --> Phase2Check[Phase 2: Dynamic Stage Persistence Fix]
    Phase2Check --> Phase3[Phase 3: Canonical RPC Wrappers]
    Phase3 --> Phase4[Phase 4: Marketplace RLS Hardening]
    Phase4 --> Phase5[Phase 5: SaaS Subscription Core]
    Phase5 --> Phase6[Phase 6: Entitlement RPCs]
    Phase6 --> Phase7[Phase 7: Lifecycle Maintenance]
    Phase7 --> Phase8[Phase 8: Token Purge / Disconnect]
    Phase8 --> Phase9[Phase 9: Scalable Autojob Queue]
    Phase9 --> Phase10[Phase 10: Subscription Platform UI]
```

---

## Safe Execution Strategy

To ensure zero regressions and minimize token cost during execution:
1. **Incremental Rerouting**:
   - Reroute Flutter RPC calls module by module instead of all at once.
   - Verify every UI screen after changing its backend hooks.
2. **Analysis-First Approach**:
   - Keep future phase schemas and scripts documented as drafts under `supabase/migrations_draft/`.
   - Apply them only when that specific phase is approved and active.
3. **Canonical RPC Convention**:
   - Never create duplicate numbered or versioned functions (e.g. `*_v2`, `*_v24_6_82e`).
   - Overwrite stable canonical functions or use clean unversioned names.
4. **No Destructive Operations**:
   - Do not drop old versioned functions or tables until all modules are rerouted and thoroughly verified on physical devices.
5. **No Cron/Worker Activation**:
   - Keep lifecycle maintenance scripts, sync crons, and queues manual or dry-run only until explicitly approved.
