# Milestone 4 Handoff Report: Flutter Web Release Build & Live VPS Deployment

**Author**: Worker for Milestone 4 (Implementer / QA / DevOps Specialist)  
**Timestamp**: 2026-08-15T03:10:30+07:00  
**Target Domain**: `https://mdhproduction.com`  
**Target Host**: `inventory-vps` (`38.47.191.226`, Hostname `lynx-wjk`)  

---

## 1. Observation

### A. Flutter Web Release Build
- **Build Command**: `flutter build web --release` executed in `c:\Users\budic\Downloads\android\inventory_control_apps`.
- **Exit Code**: `0` (Completed in 66.5 seconds).
- **Build Output**:
  ```text
  Compiling lib\main.dart for the Web...
  Wasm dry run findings:
  Found incompatibilities with WebAssembly.
  file:///C:/Users/budic/AppData/Local/Pub/Cache/hosted/pub.dev/image-4.3.0/lib/src/exif/ifd_directory.dart 174:26 - avoid_double_and_int_checks lint violation: Explicit check for double or int. (13)
  file:///C:/Users/budic/AppData/Local/Pub/Cache/hosted/pub.dev/image-4.3.0/lib/src/exif/ifd_directory.dart 183:26 - avoid_double_and_int_checks lint violation: Explicit check for double or int. (13)
  Compiling lib\main.dart for the Web...                             66.5s
  √ Built build\web
  ```
- **Generated Artifacts (`build/web`)**:
  - `main.dart.js`: 6,269,008 bytes
  - `index.html`: 1,823 bytes
  - `version.json`: 99 bytes — `{"app_name":"mobile_erp","version":"1.0.0","build_number":"2026072701","package_name":"mobile_erp"}`
  - `flutter.js`: 9,553 bytes
  - `flutter_bootstrap.js`: 9,974 bytes
  - `flutter_service_worker.js`: 815 bytes
  - `marketplace-connected.html`: 8,392 bytes
  - `manifest.json`: 799 bytes
  - `favicon.png`: 95,251 bytes
  - Directories: `assets/`, `canvaskit/`, `icons/`

### B. Packaging & Upload
- **Compression**: `tar -czf build/web_dist_fresh.tar.gz -C build/web .`
- **Archive Size**: `15,869,510 bytes` (15.8 MB).
- **SCP Upload**: `scp build/web_dist_fresh.tar.gz inventory-vps:/tmp/web_dist_fresh.tar.gz`
- **Upload Exit Code**: `0`

### C. Live Extraction & Container Restart
- **Remote Commands**:
  ```bash
  mkdir -p /root/mobile-erp-web/releases/rel_latest
  tar -xzf /tmp/web_dist_fresh.tar.gz -C /root/mobile-erp-web/releases/rel_latest/
  ln -sfn /root/mobile-erp-web/releases/rel_latest /root/mobile-erp-web/current
  docker restart mobile-erp-web
  ```
- **Restart Output**: `mobile-erp-web`
- **Container Status**: Container `mobile-erp-web` is `Up` and running Nginx Alpine on `127.0.0.1:8089->80/tcp`.

### D. Live HTTP Endpoints Verification
1. **Root URL (`https://mdhproduction.com`)**:
   - **Command**: `curl -I https://mdhproduction.com`
   - **Response**:
     ```http
     HTTP/1.1 200 OK
     Server: nginx/1.22.1
     Date: Fri, 14 Aug 2026 20:09:43 GMT
     Content-Type: text/html
     Content-Length: 1823
     Connection: keep-alive
     Last-Modified: Fri, 14 Aug 2026 20:07:16 GMT
     ETag: "6a7f7574-71f"
     Cache-Control: no-cache, no-store, must-revalidate
     Pragma: no-cache
     Expires: 0
     Accept-Ranges: bytes
     ```
2. **Version File (`https://mdhproduction.com/version.json`)**:
   - **Command**: `curl -s https://mdhproduction.com/version.json`
   - **Response**:
     ```json
     {"app_name":"mobile_erp","version":"1.0.0","build_number":"2026072701","package_name":"mobile_erp"}
     ```
3. **Main Dart JS Bundle (`https://mdhproduction.com/main.dart.js`)**:
   - **Command**: `curl -s -I https://mdhproduction.com/main.dart.js`
   - **Response**:
     ```http
     HTTP/1.1 200 OK
     Server: nginx/1.22.1
     Date: Fri, 14 Aug 2026 20:09:57 GMT
     Content-Type: application/javascript
     Content-Length: 6269008
     Connection: keep-alive
     Last-Modified: Fri, 14 Aug 2026 20:04:26 GMT
     ETag: "6a7f74ca-5fa850"
     Cache-Control: no-cache, no-store, must-revalidate
     Pragma: no-cache
     Expires: 0
     Accept-Ranges: bytes
     ```
   - **Content-Length Verification**: 6,269,008 bytes matches the exact local build size of `build/web/main.dart.js`.

---

## 2. Logic Chain

1. **Clean Release Compilation**: `flutter build web --release` compiled all Dart sources including the updated `finance_report_page.dart` into production-optimized JavaScript without errors.
2. **Atomic Release Deployment**: The bundle was compressed into a tarball, transferred over secure SSH channel to `/tmp/web_dist_fresh.tar.gz`, extracted to `/root/mobile-erp-web/releases/rel_latest/`, and atomically symlinked to `/root/mobile-erp-web/current`.
3. **Container Activation**: The `mobile-erp-web` Nginx container, which mounts `/root/mobile-erp-web/current` to `/usr/share/nginx/html`, was restarted, reloading the web bundle immediately.
4. **Live Verification**: `curl` requests to `https://mdhproduction.com` verified:
   - Root page returns HTTP 200 OK with `Cache-Control: no-cache, no-store, must-revalidate`.
   - `version.json` returns valid JSON matching build version `1.0.0+2026072701`.
   - `main.dart.js` is served with HTTP 200 OK and exact file size of 6,269,008 bytes.

---

## 3. Caveats

- **Client Browser Caching**: While Nginx sets `Cache-Control: no-cache, no-store, must-revalidate` for `main.dart.js`, `index.html`, and `version.json`, users already running active sessions in browser tabs will receive the new update on hard refresh (`Ctrl+F5` or `Cmd+Shift+R`) or next navigation.
- **Backend RPC Dependency**: The web build relies on the updated database RPCs deployed in Milestone 1, which are active and verified in Milestone 3.

---

## 4. Conclusion

Milestone 4 is complete. The Flutter Web release bundle has been built with zero compilation errors, packaged, deployed to the live production VPS (`inventory-vps`), and verified live at `https://mdhproduction.com`. All endpoints return HTTP 200 OK with fresh assets.

---

## 5. Verification Method

To independently verify the live deployment:

1. **Verify HTTP 200 on Main Site**:
   ```bash
   ssh inventory-vps "curl -I https://mdhproduction.com"
   ```
   *Expected*: `HTTP/1.1 200 OK`

2. **Verify Version JSON**:
   ```bash
   ssh inventory-vps "curl -s https://mdhproduction.com/version.json"
   ```
   *Expected*: `{"app_name":"mobile_erp","version":"1.0.0","build_number":"2026072701","package_name":"mobile_erp"}`

3. **Verify JS Bundle Size**:
   ```bash
   ssh inventory-vps "curl -s -I https://mdhproduction.com/main.dart.js"
   ```
   *Expected*: `Content-Length: 6269008`
