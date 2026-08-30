import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/constants/app_roles.dart';
import '../../../../core/ui/app_ui.dart';
import '../../../../models/app_user.dart';
import '../../../marketplace/presentation/marketplace_accounts_page.dart';
import '../../../marketplace/presentation/marketplace_sku_mapping_page.dart';
import '../../../master_data/presentation/work_location_page.dart';
import '../../../hr/presentation/payroll_page.dart';
import '../../../stock/presentation/product_list_page.dart';
import '../../../supplier/presentation/supplier_page.dart';
import '../../../finance/presentation/finance_report_page.dart';

class TenantOnboardingBannerWidget extends StatefulWidget {
  final AppUser? currentUser;
  final VoidCallback? onRefresh;

  const TenantOnboardingBannerWidget({
    super.key,
    this.currentUser,
    this.onRefresh,
  });

  @override
  State<TenantOnboardingBannerWidget> createState() =>
      _TenantOnboardingBannerWidgetState();
}

class _TenantOnboardingBannerWidgetState
    extends State<TenantOnboardingBannerWidget> {
  final SupabaseClient _client = Supabase.instance.client;
  bool _isLoading = true;
  bool _isExpanded = false;
  Map<String, dynamic>? _progress;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    try {
      final res = await _client.rpc('tenant_get_onboarding_progress');
      if (mounted && res != null && res is Map) {
        setState(() {
          _progress = Map<String, dynamic>.from(res);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[ONBOARDING_PROGRESS_ERROR] ');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  AppUser get _effectiveUser {
    final existing = widget.currentUser;
    if (existing != null) return existing;
    final authUser = _client.auth.currentUser;
    return AppUser.fromMap({
      'user_id': authUser?.id ?? '',
      'nama': authUser?.email ?? '-',
      'email': authUser?.email ?? '-',
      'role_id': 'admin',
      'status': 'active',
      'tenant_id': _progress?['tenant_id']?.toString() ?? '',
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const SizedBox.shrink();
    if (_progress == null) return const SizedBox.shrink();

    final isComplete = _progress?['is_complete'] as bool? ?? false;
    final percentage = AppUi.toNum(_progress?['percentage']).toInt();
    final completedSteps = AppUi.toNum(_progress?['completed_steps']).toInt();
    final totalSteps = AppUi.toNum(_progress?['total_steps']).toInt();

    // Setup onboarding only visible to administrative setup roles
    final roleId = _effectiveUser.role.roleId.trim().toLowerCase();
    final canManageTenantSetup = AppRolePermissions.isSuperRoleId(roleId) ||
        roleId == 'admin' ||
        roleId == 'owner' ||
        roleId == 'platform_owner';
    if (!canManageTenantSetup) return const SizedBox.shrink();

    // If 100% complete, do not show large banner
    if (isComplete || percentage >= 100) return const SizedBox.shrink();

    final hasLocation = _progress?['has_location'] as bool? ?? false;
    final hasPayroll = _progress?['has_payroll_settings'] as bool? ?? false;
    final productCount = AppUi.toNum(_progress?['product_count']).toInt();
    final hasHpp = AppUi.toNum(_progress?['has_hpp_count']).toInt() > 0;
    final hasCash = _progress?['has_opening_cash'] as bool? ?? false;
    final hasSupplier = _progress?['has_supplier'] as bool? ?? false;
    final hasMarketplace =
        _progress?['has_marketplace_account'] as bool? ?? false;
    final variantSnapshots =
        AppUi.toNum(_progress?['variant_snapshot_count']).toInt();
    final skuMapped = AppUi.toNum(_progress?['sku_mapped_count']).toInt();
    final isSkuMappedComplete =
        hasMarketplace && variantSnapshots > 0 && skuMapped >= variantSnapshots;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: AppUi.blue.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppUi.blue.withOpacity(0.3), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header Row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppUi.blue.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.rocket_launch_rounded,
                      color: AppUi.blue, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'PANDUAN SETUP AWAL TOKO (ONBOARDING)',
                        style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                            color: AppUi.blue),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Selesaikan $totalSteps langkah berikut agar data stok, barcode, dan laporan keuangan akurat.',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppUi.mutedText(context, 0.8),
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _isExpanded ? 'Tutup Rincian' : 'Buka Rincian',
                  icon: Icon(_isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded),
                  onPressed: () =>
                      setState(() => _isExpanded = !_isExpanded),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Progress Bar & Percentage
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: percentage / 100.0,
                      minHeight: 10,
                      backgroundColor: Colors.grey.withOpacity(0.2),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        percentage < 50
                            ? AppUi.orange
                            : (percentage < 80 ? AppUi.blue : AppUi.green),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$completedSteps / $totalSteps ($percentage%)',
                  style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      color: AppUi.blue),
                ),
              ],
            ),

            if (_isExpanded) ...[
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),

              // Steps List
              _buildStepTile(
                stepNum: '1',
                title: 'Lokasi Kerja GPS & Geofence',
                subtitle: hasLocation
                    ? 'Lokasi kantor/gudang terdaftar'
                    : 'Wajib untuk validasi radius absensi karyawan',
                isDone: hasLocation,
                actionLabel: 'SET LOKASI',
                onAction: () => _navigate(context, const WorkLocationPage()),
              ),
              _buildStepTile(
                stepNum: '2',
                title: 'Pengaturan Payroll & Lembur',
                subtitle: hasPayroll
                    ? 'Parameter cut-off & lembur tersimpan'
                    : 'Wajib sebelum mencetak slip gaji karyawan',
                isDone: hasPayroll,
                actionLabel: 'SET PAYROLL',
                onAction: () => _navigate(context, const PayrollPage()),
              ),
              _buildStepTile(
                stepNum: '3',
                title: 'Master Produk & Varian',
                subtitle: productCount > 0
                    ? '$productCount produk terdaftar di katalog'
                    : 'Input barang & varian agar barcode dapat discan',
                isDone: productCount > 0,
                actionLabel: 'INPUT PRODUK',
                onAction: () => _navigate(context, const ProductListPage()),
              ),
              _buildStepTile(
                stepNum: '4',
                title: 'Harga Modal / HPP Produk',
                subtitle: hasHpp
                    ? '${_progress?['has_hpp_count'] ?? ''} produk/varian memiliki HPP'
                    : 'Wajib agar profit di laporan keuangan tidak 0',
                isDone: hasHpp,
                actionLabel: 'SET HPP',
                onAction: () => _navigate(
                    context,
                    MarketplaceSkuMappingPage(
                      currentUser: _effectiveUser,
                      initialTabIndex: 1,
                    )),
              ),
              _buildStepTile(
                stepNum: '5',
                title: 'Saldo Awal Kas / Bank',
                subtitle: hasCash
                    ? 'Saldo kas pembukaan tercatat'
                    : 'Wajib agar buku besar kas tidak minus saat bayar supplier',
                isDone: hasCash,
                actionLabel: 'SET KAS AWAL',
                onAction: () => _navigate(context, const FinanceReportPage()),
              ),
              _buildStepTile(
                stepNum: '6',
                title: 'Master Supplier',
                subtitle: hasSupplier
                    ? 'Daftar vendor/supplier tersimpan'
                    : 'Diperlukan saat membuat pesanan pembelian barang',
                isDone: hasSupplier,
                actionLabel: 'SET SUPPLIER',
                onAction: () => _navigate(context, const SupplierPage()),
              ),
              _buildStepTile(
                stepNum: '7',
                title: 'Hubungkan Akun Marketplace',
                subtitle: hasMarketplace
                    ? 'Akun Shopee/TikTok terhubung'
                    : 'Hubungkan toko online untuk sinkronisasi pesanan',
                isDone: hasMarketplace,
                actionLabel: 'CONNECT TOKO',
                onAction: () =>
                    _navigate(context, MarketplaceAccountsPage(currentUser: _effectiveUser)),
              ),
              _buildStepTile(
                stepNum: '8',
                title: 'Pemetaan SKU Marketplace',
                subtitle: !hasMarketplace
                    ? 'Hubungkan toko marketplace terlebih dahulu untuk sinkronisasi SKU'
                    : variantSnapshots == 0
                        ? 'Tarik/sinkron produk dari marketplace untuk memulai pemetaan'
                        : isSkuMappedComplete
                            ? 'Semua SKU online terpetakan ke master lokal ($skuMapped/$variantSnapshots)'
                            : '$skuMapped dari $variantSnapshots SKU terpetakan (Wajib sebelum tarik pesanan)',
                isDone: isSkuMappedComplete,
                actionLabel: 'MAPPING SKU',
                onAction: () => _navigate(
                    context,
                    MarketplaceSkuMappingPage(
                      currentUser: _effectiveUser,
                      initialTabIndex: 0,
                    )),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStepTile({
    required String stepNum,
    required String title,
    required String subtitle,
    required bool isDone,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: isDone
                  ? AppUi.green.withOpacity(0.15)
                  : Colors.grey.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(
                  color: isDone ? AppUi.green : Colors.grey, width: 1.5),
            ),
            child: Center(
              child: isDone
                  ? const Icon(Icons.check, size: 14, color: AppUi.green)
                  : Text(stepNum,
                      style: const TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: isDone
                        ? null
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10,
                    color: isDone
                        ? AppUi.green
                        : AppUi.mutedText(context, 0.7),
                    fontWeight: isDone ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (!isDone) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              ),
              child: Text(actionLabel,
                  style: const TextStyle(
                      fontSize: 9, fontWeight: FontWeight.w800)),
            ),
          ],
        ],
      ),
    );
  }

  void _navigate(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)).then((_) {
      _loadProgress();
      widget.onRefresh?.call();
    });
  }
}
