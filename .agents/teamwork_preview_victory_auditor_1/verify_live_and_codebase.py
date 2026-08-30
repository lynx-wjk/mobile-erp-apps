import os, sys, http.server, threading, urllib.request, time

def verify_codebase_alignment():
    print("=== 1. VERIFY CODEBASE FEATURE ALIGNMENT ===")
    features_to_check = {
        'WMS QR/Barcode': [
            'lib/features/stock',
            'lib/features/master_data'
        ],
        'OMS Marketplace': [
            'lib/features/marketplace',
            'lib/features/dashboard'
        ],
        'FMS Finance & Settlement': [
            'lib/features/finance'
        ],
        'HRIS Attendance & Host Live': [
            'lib/features/attendance',
            'lib/features/host_live',
            'lib/features/hr'
        ],
        'EMS Role & Multi-Tenant': [
            'lib/features/role_modules',
            'lib/features/auth',
            'lib/features/admin'
        ]
    }
    for feat, paths in features_to_check.items():
        found = all(os.path.exists(p) for p in paths)
        print(f"Feature '{feat}': Exists={found} -> Checked paths: {paths}")

def test_live_http_server():
    print("\n=== 2. INDEPENDENT LIVE HTTP SERVER TESTS ===")
    landing_dir = os.path.abspath('landing_page')
    
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=landing_dir, **kwargs)
        def log_message(self, format, *args):
            pass # quiet logging

    server = http.server.HTTPServer(('127.0.0.1', 8989), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.daemon = True
    thread.start()
    time.sleep(0.5)

    endpoints = [
        ('/', 200, 'text/html'),
        ('/index.html', 200, 'text/html'),
        ('/styles.css', 200, 'text/css'),
        ('/app.js', 200, 'application/javascript'),
        ('/assets/logo.png', 200, 'image/png'),
        ('/robots.txt', 200, 'text/plain'),
        ('/sitemap.xml', 200, 'text/xml'),
    ]

    for path, exp_code, exp_type in endpoints:
        url = f"http://127.0.0.1:8989{path}"
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req) as resp:
                status = resp.getcode()
                c_type = resp.headers.get('Content-Type', '')
                length = len(resp.read())
                type_ok = exp_type in c_type.lower() or (exp_type == 'text/xml' and 'xml' in c_type.lower())
                status_ok = status == exp_code
                print(f"HTTP GET {path:18} -> Status {status} (exp {exp_code}) | Content-Type: {c_type} (exp {exp_type}) | Size: {length} bytes -> {'PASS' if status_ok and type_ok else 'FAIL'}")
        except Exception as e:
            print(f"HTTP GET {path:18} -> FAILED WITH ERROR: {e}")

    server.shutdown()
    server.server_close()

def main():
    verify_codebase_alignment()
    test_live_http_server()

if __name__ == '__main__':
    main()
