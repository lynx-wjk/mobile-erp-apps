## 2026-08-16T12:54:08Z
You are the Remediation Worker (Iteration 2) for the Mobile ERP Landing Page project.
Your working directory is: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_worker_impl_2

Read:
- c:\Users\budic\Downloads\android\inventory_control_apps\ORIGINAL_REQUEST.md
- c:\Users\budic\Downloads\android\inventory_control_apps\PROJECT.md
- Reviewer 1 handoff: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_reviewer_1\handoff.md
- Reviewer 2 handoff: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_reviewer_2\handoff.md
- Challenger 1 handoff: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_challenger_1\handoff.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work.

Your specific remediation tasks on files in `landing_page/`:
1. **Fix Footer WA Link & Floating Launcher in `landing_page/index.html`**:
   - At line ~1071 (footer WA link): Change `href="https://wa.me/6285155338246"` to `href="https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20tertarik%20dengan%20solusi%20Mobile%20ERP%20untuk%20perusahaan%20kami.%20Mohon%20informasi%20panduan%20setup%20dan%20aktivasi%20akun%20enterprise%20kami."`
   - At line ~1096 (floating launcher link): Update query text so it starts with `"Halo Tim Konsultan Mobile ERP, ..."` (matching `test_uj04`).
2. **Fix Navbar Logo DOM Placement in `landing_page/index.html`**:
   - Ensure `<nav class="navbar">` (or `<nav>`) wraps the `.brand-unit` container containing `<img src="assets/logo.png" alt="Logo Resmi Mobile ERP" class="brand-logo-img">` so that `nav.find("img")` in `test_f01_tc02` and `test_c01_tc04` directly locates the metallic logo image inside `<nav>`.
3. **Fix CSS Hex Tokens in `landing_page/styles.css`**:
   - In `:root`, ensure `--bg-dark: #080c14;` and `--bg-surface-1: #0d1322;` (with lowercase `#080c14` / `#0d1322` or matching both cases) to satisfy `test_c04_tc01`.
4. **Fix Static Template String Matching in `landing_page/app.js`**:
   - In `app.js` (inside `renderFallbackPlans()` and WhatsApp builder), ensure the exact Indonesian consultation message strings for each plan explicitly contain:
     - Trial: `"Halo Tim Konsultan Mobile ERP, saya tertarik dengan uji coba gratis (Trial 14 Hari). Mohon informasi panduan setup dan aktivasi akun enterprise kami."`
     - Starter: `"Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket Starter (Rp 300.000/bln). Mohon informasi panduan setup dan aktivasi akun enterprise kami."`
     - Growth: `"Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket Growth (Rp 500.000/bln). Mohon informasi panduan setup dan aktivasi akun enterprise kami."`
     - Pro: `"Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket Pro (Rp 800.000/bln). Mohon informasi panduan setup dan aktivasi akun enterprise kami."`
     - Enterprise: `"Halo Tim Konsultan Mobile ERP, kami membutuhkan penawaran khusus dan panduan implementasi untuk paket Enterprise Multi-Cabang. Mohon info diskusi lebih lanjut."`
     (This satisfies `test_f04_tc02` and `test_f04_tc04`).

5. Run the master E2E test runner:
   `python tests/run_e2e_tests.py`
   Ensure **94/94 tests PASS (100% Pass Rate, 0 Failures, 0 Errors)**.

Write your completion report and handoff to:
c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_worker_impl_2\handoff.md

When complete, send a message to your parent.
