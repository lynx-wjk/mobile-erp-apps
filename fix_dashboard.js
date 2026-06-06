
const fs = require('fs');
let code = fs.readFileSync('lib/features/dashboard/presentation/dashboard_page.dart', 'utf-8');

// 1. Replace background
const bgOld = \      body: Container(
        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor),
        child: CustomPaint(
          painter: _DashboardBackdropPainter(
            gridColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.045),
            primaryColor: Theme.of(context).colorScheme.primary,
            accentColor: Theme.of(context).colorScheme.tertiary,
          ),
          child: Stack(\;
const bgNew = \      body: AppGlobalBackdrop(
        visualMode: AppVisualMode.girl,
        child: Stack(\;
code = code.replace(bgOld, bgNew);

// 2. Replace _profileCard container
code = code.replace(
\    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            blurRadius: 0,
            offset: Offset(6, 6),
          ),
        ],
      ),
      child: Row(\,
\    return NiceCard(
      padding: const EdgeInsets.all(18),
      child: Row(\
);

// 3. Replace _adminAnalyticsCard container
code = code.replace(
\    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 2.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            blurRadius: 0,
            offset: Offset(5, 5),
          ),
        ],
      ),
      child: Column(\,
\    return NiceCard(
      padding: const EdgeInsets.all(16),
      child: Column(\
);

// 4. Update _financeContent to be GridView
const fcOld = \  List<Widget> _financeContent() {
    return [
      _sectionHeader('Analytics Finance'),
      const SizedBox(height: 10),
      _financeCard(
        'Laporan Keuangan',
        'Pantau omzet, HPP, biaya, dan laba rugi.',
        Icons.account_balance_wallet_rounded,
        Theme.of(context).colorScheme.primary,
        () => _open(const FinanceReportPage()),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Absensi',
        'Check-in dan check-out karyawan dengan validasi lokasi.',
        Icons.how_to_reg_rounded,
        Theme.of(context).colorScheme.secondary,
        () => _open(AbsensiPage(currentUser: _requiredAppUser)),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Tugas',
        'Lihat task yang ditugaskan ke akun finance.',
        Icons.task_alt_rounded,
        Theme.of(context).colorScheme.primary,
        () => _open(const TaskPage()),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Verifikasi Pembelian',
        'Cek nota dan status pembelian pending.',
        Icons.verified_rounded,
        Theme.of(context).colorScheme.primary,
        () => _open(const PurchaseVerificationPage()),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Export Data Finance',
        'Download finance + seluruh marketplace di laporan keuangan ke XLSX.',
        Icons.file_download_rounded,
        Theme.of(context).colorScheme.secondary,
        () => _open(const DataExportImportPage()),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Anomali Marketplace',
        'Temukan pesanan dengan payout atau margin tidak wajar.',
        Icons.warning_amber_rounded,
        Theme.of(context).colorScheme.secondary,
        () => _open(const FinanceReportPage(initialTabIndex: 6)),
      ),
    ];
  }\;

const fcNew = \  List<Widget> _financeContent() {
    final items = <Widget>[
      _menuCard(_DashboardMenu('Laporan Keuangan', 'Pantau omzet, HPP, biaya, dan laba rugi.', Icons.account_balance_wallet_rounded, () => _open(const FinanceReportPage()))),
      _menuCard(_DashboardMenu('Absensi', 'Check-in dan check-out karyawan dengan validasi lokasi.', Icons.how_to_reg_rounded, () => _open(AbsensiPage(currentUser: _requiredAppUser)))),
      _menuCard(_DashboardMenu('Tugas', 'Lihat task yang ditugaskan ke akun finance.', Icons.task_alt_rounded, () => _open(const TaskPage()))),
      _menuCard(_DashboardMenu('Verifikasi Pembelian', 'Cek nota dan status pembelian pending.', Icons.verified_rounded, () => _open(const PurchaseVerificationPage()))),
      _menuCard(_DashboardMenu('Export Data Finance', 'Download finance + seluruh marketplace di laporan keuangan ke XLSX.', Icons.file_download_rounded, () => _open(const DataExportImportPage()))),
      _menuCard(_DashboardMenu('Abnormal Marketplace', 'Temukan pesanan dengan payout atau margin tidak wajar.', Icons.warning_amber_rounded, () => _open(const FinanceReportPage(initialTabIndex: 6)))),
    ];

    if (items.isEmpty) return const [];

    return [
      _sectionHeader('Menu Operasional Finance'),
      const SizedBox(height: 12),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.95,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) => items[index],
      ),
    ];
  }\;
code = code.replace(fcOld, fcNew);

// 5. Update _roleAnalyticsContent to use GridView as well
const roleOld = \  List<Widget> _roleAnalyticsContent() {
    final role = _role;
    final title = 'Analytics ' + _roleLabel(role);
    final managedTasks = _isManagementRole ? _allOpenTasks : _myOpenTasks;
    final cards = <Widget>[];

    void addCard(
      String title,
      String subtitle,
      IconData icon,
      Color color,
      VoidCallback onTap,
    ) {
      cards
        ..add(_financeCard(title, subtitle, icon, color, onTap))
        ..add(const SizedBox(height: 10));
    }\;

// We will change addCard to push _menuCard instead of _financeCard, and avoid SizedBox!
const roleOld2 = \    void addCard(
      String title,
      String subtitle,
      IconData icon,
      Color color,
      VoidCallback onTap,
    ) {
      cards
        ..add(_financeCard(title, subtitle, icon, color, onTap))
        ..add(const SizedBox(height: 10));
    }\;

const roleNew2 = \    void addCard(
      String title,
      String subtitle,
      IconData icon,
      Color color,
      VoidCallback onTap,
    ) {
      cards.add(_menuCard(_DashboardMenu(title, subtitle, icon, onTap)));
    }\;

code = code.replace(roleOld2, roleNew2);

// And we must replace the return of _roleAnalyticsContent:
// The original returns \eturn cards;\ at the end
const roleReturnOld = \      addCard(
        'SOP & Dokumentasi',
        'Lihat dan pelajari standar operasional.',
        Icons.book_rounded,
        Theme.of(context).colorScheme.primary,
        () {},
      );
    }

    return cards;
  }\;

const roleReturnNew = \      addCard(
        'SOP & Dokumentasi',
        'Lihat dan pelajari standar operasional.',
        Icons.book_rounded,
        Theme.of(context).colorScheme.primary,
        () {},
      );
    }

    if (cards.length <= 2) return cards; // If only section header and spacing

    final header = cards[0];
    final items = cards.sublist(2); // Skip header and sizedbox

    return [
      header,
      const SizedBox(height: 12),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.95,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) => items[index],
      ),
    ];
  }\;

code = code.replace(roleReturnOld, roleReturnNew);

// 6. Fix _menuCard to use NiceCard
const menuOld = \  Widget _menuCard(_DashboardMenu item) {
    final color = _menuAccent(item);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: _pixelDecoration(color),
          child: Row(\;

const menuNew = \  Widget _menuCard(_DashboardMenu item) {
    final color = _menuAccent(item);
    return NiceCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: item.onTap,
      borderColor: color,
      child: Column(\; // Wait, Column!

// In _menuCard, we should use Column because it's in a grid view, so icon on top, text below!
// Let's rewrite the ENTIRE _menuCard using regex replace that spans the whole method
const menuOldFullRegex = /Widget _menuCard\\(_DashboardMenu item\\) \\{[\\s\\S]*?return Material\\([\\s\\S]*?child: Row\\([\\s\\S]*?children: \\[[\\s\\S]*?Container\\([\\s\\S]*?child: Icon\\(item\\.icon, color: color, size: 24\\),[\\s\\S]*?\\),[\\s\\S]*?const SizedBox\\(width: 14\\),[\\s\\S]*?Expanded\\([\\s\\S]*?child: Column\\([\\s\\S]*?children: \\[[\\s\\S]*?Text\\([\\s\\S]*?item\\.title\\.toUpperCase\\(\\),[\\s\\S]*?\\),[\\s\\S]*?const SizedBox\\(height: 3\\),[\\s\\S]*?Text\\([\\s\\S]*?item\\.subtitle,[\\s\\S]*?\\),[\\s\\S]*?\\][\\s\\S]*?\\)[\\s\\S]*?\\)[\\s\\S]*?\\][\\s\\S]*?\\)[\\s\\S]*?\\)[\\s\\S]*?\\)[\\s\\S]*?\\);[\\s\\S]*?\\}/;

const menuNewFull = \Widget _menuCard(_DashboardMenu item) {
    final color = _menuAccent(item);
    return NiceCard(
      padding: const EdgeInsets.all(16),
      onTap: item.onTap,
      borderColor: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.zero,
              color: color.withOpacity(0.14),
              border: Border.all(color: Colors.black, width: 2),
            ),
            child: Icon(item.icon, color: color, size: 24),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title.toUpperCase(),
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    item.subtitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.60),
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }\;

code = code.replace(menuOldFullRegex, menuNewFull);

fs.writeFileSync('lib/features/dashboard/presentation/dashboard_page.dart', code);
console.log('Script executed');

