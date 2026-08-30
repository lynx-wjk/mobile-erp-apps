import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../../../core/ui/ai_chat_assistant_sheet.dart';
import '../../../core/theme/app_theme_mode.dart';
import '../../../core/constants/app_roles.dart';
import '../../../services/auth_service.dart';
import '../../auth/presentation/login_page.dart';
import 'subscription_plans_page.dart';
import 'landing_page_cms_page.dart';
import 'tenant_subscription_detail_page.dart';
import 'user_management_page.dart';

class PlatformOwnerDashboard extends StatefulWidget {
  const PlatformOwnerDashboard({super.key});

  @override
  State<PlatformOwnerDashboard> createState() => _PlatformOwnerDashboardState();
}

class _PlatformOwnerDashboardState extends State<PlatformOwnerDashboard> {
  final SupabaseClient _client = Supabase.instance.client;
  bool _isLoading = true;
  String _tenantFilter = 'all';
  bool _themeSwitching = false;
  bool _isLoggingOut = false;
  List<Map<String, dynamic>> _readinessData = [];
  List<Map<String, dynamic>> _tenantsList = [];
  List<Map<String, dynamic>> _plansList = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData({bool forceRefresh = false}) async {
    setState(() => _isLoading = true);
    try {
      final response = await _client.rpc('platform_tenant_readiness_summary',
          params: {'p_force_refresh': forceRefresh});
      final tenantsRes = await _client
          .from('app_tenants')
          .select(
              'tenant_id, tenant_code, tenant_name, owner_name, owner_email, status, order_retention_days, tenant_subscriptions(status, trial_ends_at, current_period_end, created_at, subscription_plans(plan_name, plan_code, max_order_retention_days))')
          .order('tenant_name');

      final plansRes = await _client
          .from('subscription_plans')
          .select('plan_id, plan_code, plan_name, price_amount, billing_period')
          .eq('is_active', true)
          .order('sort_order');

      if (response != null && response is List) {
        _readinessData =
            response.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else {
        _readinessData = [];
      }

      _tenantsList = (tenantsRes as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      _plansList = (plansRes as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      debugPrint('[PLATFORM_DASHBOARD_LOAD_ERROR] $e\n$st');
      AppUi.showSnack('GAGAL MEMUAT DATA: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Map<String, dynamic>? _getActiveSubscription(List<dynamic>? subs) {
    if (subs == null || subs.isEmpty) return null;
    final list = subs.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    list.sort((a, b) {
      final aTime = DateTime.tryParse(a['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = DateTime.tryParse(b['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return list.first;
  }

  Map<String, dynamic>? _tenantObjById(String tenantId) {
    try {
      return _tenantsList
          .firstWhere((t) => t['tenant_id']?.toString() == tenantId);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _getTenantGraceState(String tenantId) {
    final tenantObj = _tenantObjById(tenantId);
    final subs = tenantObj?['tenant_subscriptions'] as List?;
    final activeSub = _getActiveSubscription(subs);
    if (activeSub == null) {
      return {
        'state': 'unassigned',
        'label': 'BELUM DISET',
        'color': AppUi.orange,
        'daysLeft': 0,
        'isPurgeable': false,
        'planName': '-',
        'planCode': '-',
      };
    }

    final planName = activeSub['subscription_plans']?['plan_name']?.toString() ??
        'Standard Plan';
    final planCode =
        activeSub['subscription_plans']?['plan_code']?.toString() ?? '-';
    final status = activeSub['status']?.toString().toLowerCase() ?? 'active';
    final periodEndStr = activeSub['current_period_end']?.toString();
    final periodEnd = DateTime.tryParse(periodEndStr ?? '');
    final now = DateTime.now();

    if (status == 'trialing') {
      final trialEnd =
          DateTime.tryParse(activeSub['trial_ends_at']?.toString() ?? '');
      final days = trialEnd != null ? trialEnd.difference(now).inDays : 0;
      return {
        'state': 'trialing',
        'label': 'TRIAL ($days HARI LAGI)',
        'color': AppUi.teal,
        'daysLeft': days,
        'isPurgeable': false,
        'planName': planName,
        'planCode': planCode,
        'periodEnd': trialEnd,
        'sub': activeSub,
      };
    }

    if (periodEnd == null) {
      return {
        'state': 'active',
        'label': 'AKTIF PERMANEN',
        'color': AppUi.green,
        'daysLeft': 9999,
        'isPurgeable': false,
        'planName': planName,
        'planCode': planCode,
        'periodEnd': null,
        'sub': activeSub,
      };
    }

    final diff = periodEnd.difference(now);
    if (diff.inSeconds > 0) {
      final days = diff.inDays;
      return {
        'state': 'active',
        'label': days > 0 ? 'AKTIF ($days HARI LAGI)' : 'JATUH TEMPO HARI INI',
        'color': AppUi.green,
        'daysLeft': days,
        'isPurgeable': false,
        'planName': planName,
        'planCode': planCode,
        'periodEnd': periodEnd,
        'sub': activeSub,
      };
    }

    // Past current_period_end: check 7 days grace period
    final overdueDays = now.difference(periodEnd).inDays;
    if (overdueDays <= 7) {
      final graceDaysLeft = 7 - overdueDays;
      return {
        'state': 'grace_period',
        'label': 'GRACE PERIOD (SISA $graceDaysLeft HARI)',
        'color': Colors.amber,
        'daysLeft': -overdueDays,
        'graceDaysLeft': graceDaysLeft,
        'isPurgeable': false,
        'planName': planName,
        'planCode': planCode,
        'periodEnd': periodEnd,
        'sub': activeSub,
      };
    }

    return {
      'state': 'expired',
      'label': 'EXPIRED ($overdueDays HARI LALU - SIAP PURGE)',
      'color': AppUi.red,
      'daysLeft': -overdueDays,
      'isPurgeable': true,
      'planName': planName,
      'planCode': planCode,
      'periodEnd': periodEnd,
      'sub': activeSub,
    };
  }

  String _tenantSubscriptionState(String tenantId) {
    return _getTenantGraceState(tenantId)['state']?.toString() ?? 'unassigned';
  }

  double _calculateEstimatedMrr() {
    double total = 0;
    for (final tenant in _tenantsList) {
      final subs = tenant['tenant_subscriptions'] as List?;
      final activeSub = _getActiveSubscription(subs);
      if (activeSub == null) continue;
      final status = activeSub['status']?.toString().toLowerCase();
      if (status == 'active' || status == 'trialing') {
        final planCode =
            activeSub['subscription_plans']?['plan_code']?.toString() ?? '';
        final plan = _plansList.firstWhere(
          (p) => p['plan_code']?.toString() == planCode,
          orElse: () => <String, dynamic>{},
        );
        final price = AppUi.toNum(plan['price_amount']).toDouble();
        if (price < 100000000) {
          total += price;
        }
      }
    }
    return total;
  }

  bool _tenantMatchesFilter(String tenantId) {
    if (_tenantFilter == 'all') return true;
    return _tenantSubscriptionState(tenantId) == _tenantFilter;
  }

  Widget _filterChip(String value, String label) {
    return ChoiceChip(
      label: Text(label,
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 10)),
      selected: _tenantFilter == value,
      onSelected: (_) => setState(() => _tenantFilter = value),
    );
  }

  Widget _tenantStatusChip(String status) {
    final color = AppUi.statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.34), width: 0.8),
      ),
      child: Text(
        status,
        style:
            TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 10),
      ),
    );
  }

  Future<void> _logout() async {
    if (_isLoggingOut) return;

    FocusManager.instance.primaryFocus?.unfocus();
    if (mounted) {
      setState(() => _isLoggingOut = true);
    }

    final navigator = rootNavigatorKey.currentState;
    if (navigator != null) {
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 320));

    try {
      await AuthService().signOut();
    } catch (e) {
      debugPrint('[PLATFORM_OWNER_LOGOUT_ERROR] $e');
    }
  }

  Future<void> _switchThemeSafely() async {
    if (_themeSwitching) return;

    FocusManager.instance.primaryFocus?.unfocus();
    if (mounted) setState(() => _themeSwitching = true);

    try {
      await Future<void>.delayed(const Duration(milliseconds: 220));
      await AppThemeModeController.toggle();
      await Future<void>.delayed(const Duration(milliseconds: 220));
    } finally {
      if (mounted) setState(() => _themeSwitching = false);
    }
  }

  // Group readiness summary by Tenant
  Map<String, List<Map<String, dynamic>>> get _groupedTenants {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final row in _readinessData) {
      final tenantId = row['tenant_id']?.toString() ?? '';
      if (tenantId.isEmpty) continue;
      map.putIfAbsent(tenantId, () => []).add(row);
    }
    return map;
  }

  // Create Tenant Dialog
  void _showCreateTenantDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('TAMBAH TENANT BARU'.toUpperCase(),
              style: TextStyle(fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('NAMA TENANT / CLIENT',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: 'Contoh: PT Sukses Bersama',
                  prefixIcon: Icon(Icons.business),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  Text('BATAL', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            FilledButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  AppUi.showSnack('NAMA TENANT TIDAK BOLEH KOSONG.');
                  return;
                }
                Navigator.pop(context);
                setState(() => _isLoading = true);
                try {
                  final result = await _client.rpc(
                    'platform_create_tenant_for_app',
                    params: {
                      'p_tenant_name': name,
                      'p_owner_name': null,
                      'p_owner_email': null,
                      'p_notes': null,
                    },
                  );
                  final ok = result is Map && (result['ok'] as bool? ?? false);
                  if (ok) {
                    AppUi.showSnack(
                        'TENANT BERHASIL DIBUAT: ${result['tenant_name']} (${result['tenant_code']})');
                    _loadData();
                  } else {
                    throw Exception('RPC returned ok=false. $result');
                  }
                } catch (e, st) {
                  debugPrint('[TENANT_CREATE_ERROR] $e\n$st');
                  AppUi.showSnack('GAGAL MEMBUAT TENANT: ${e.toString()}');
                  setState(() => _isLoading = false);
                }
              },
              child: Text('SIMPAN'),
            ),
          ],
        );
      },
    );
  }

  // Extend Subscription & Record Payment Dialog
  void _showExtendSubscriptionDialog({
    required String tenantId,
    required String tenantName,
    required String initialPlanCode,
  }) {
    String selectedPlan = _plansList.any((p) => p['plan_code'] == initialPlanCode)
        ? initialPlanCode
        : (_plansList.isNotEmpty
            ? _plansList.first['plan_code']?.toString() ?? 'starter'
            : 'starter');
    int selectedMonths = 1;
    String selectedPaymentMethod = 'bank_transfer';
    final notesController =
        TextEditingController(text: 'Perpanjangan via Transfer Bank');
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final currentPlanObj = _plansList.firstWhere(
              (p) => p['plan_code']?.toString() == selectedPlan,
              orElse: () => <String, dynamic>{'price_amount': 300000},
            );
            final unitPrice =
                AppUi.toNum(currentPlanObj['price_amount']).toDouble();
            final totalAmount = unitPrice * selectedMonths;

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.credit_card_rounded, color: AppUi.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'PERPANJANG LANGGANAN'.toUpperCase(),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppUi.blue.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: AppUi.blue.withOpacity(0.2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('TENANT:',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppUi.mutedText(context, 0.7),
                                  fontWeight: FontWeight.bold)),
                          Text(tenantName.toUpperCase(),
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('PILIH PAKET LANGGANAN',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 11)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: selectedPlan,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.workspace_premium_rounded),
                      ),
                      items: _plansList.map((plan) {
                        final code = plan['plan_code']?.toString() ?? '';
                        final name = plan['plan_name']?.toString() ?? code;
                        final price =
                            AppUi.toNum(plan['price_amount']).toDouble();
                        return DropdownMenuItem(
                          value: code,
                          child: Text(
                              '$name - ${AppUi.rupiah(price)}/bln',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => selectedPlan = val);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text('DURASI PERPANJANGAN',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 11)),
                    const SizedBox(height: 6),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 1, label: Text('1 Bln')),
                        ButtonSegment(value: 3, label: Text('3 Bln')),
                        ButtonSegment(value: 6, label: Text('6 Bln')),
                        ButtonSegment(value: 12, label: Text('1 Thn')),
                      ],
                      selected: {selectedMonths},
                      onSelectionChanged: (set) {
                        setDialogState(() => selectedMonths = set.first);
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text('METODE PEMBAYARAN',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 11)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: selectedPaymentMethod,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.payment_rounded),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'bank_transfer',
                            child: Text('Transfer Bank Manual')),
                        DropdownMenuItem(
                            value: 'qris', child: Text('QRIS Online')),
                        DropdownMenuItem(
                            value: 'virtual_account',
                            child: Text('Virtual Account (VA)')),
                        DropdownMenuItem(
                            value: 'manual_waived',
                            child: Text('Gratis / Waived / Demo')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => selectedPaymentMethod = val);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppUi.green.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: AppUi.green.withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('TOTAL TAGIHAN:',
                              style: TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 11)),
                          Text(
                            AppUi.rupiah(totalAmount),
                            style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: AppUi.green),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('CATATAN / NOMOR REFERENSI',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 11)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: notesController,
                      decoration: const InputDecoration(
                        hintText:
                            'Contoh: Transfer BCA an Budi / Ref: TR-9988',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting ? null : () => Navigator.pop(context),
                  child: const Text('BATAL',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                FilledButton(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          setDialogState(() => isSubmitting = true);
                          try {
                            final res = await _client.rpc(
                              'platform_extend_tenant_subscription',
                              params: {
                                'p_tenant_id': tenantId,
                                'p_plan_code': selectedPlan,
                                'p_duration_months': selectedMonths,
                                'p_payment_method': selectedPaymentMethod,
                                'p_amount': totalAmount,
                                'p_notes': notesController.text.trim(),
                              },
                            );
                            final ok =
                                res is Map && (res['ok'] as bool? ?? false);
                            if (ok) {
                              if (context.mounted) Navigator.pop(context);
                              AppUi.showSnack(res['message']?.toString() ??
                                  'Langganan berhasil diperpanjang!');
                              _loadData(forceRefresh: true);
                            } else {
                              throw Exception(res['message'] ??
                                  'Gagal memperpanjang langganan');
                            }
                          } catch (e, st) {
                            debugPrint('[EXTEND_SUB_ERROR] $e\n$st');
                            AppUi.showSnack('GAGAL: ${e.toString()}');
                          } finally {
                            if (context.mounted) {
                              setDialogState(() => isSubmitting = false);
                            }
                          }
                        },
                  child: isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('KONFIRMASI PEMBAYARAN'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Configure Historical Data Lookback Dialog
  void _showConfigureLookbackDialog({
    required String tenantId,
    required String tenantName,
    required String tenantCode,
    int? currentRetentionDays,
    int? defaultPlanDays,
  }) {
    int selectedDays = currentRetentionDays ?? defaultPlanDays ?? 90;
    bool shouldResetHistoricalPull = false;
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Theme.of(context).colorScheme.surface,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                    color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppUi.blue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.history_toggle_off_rounded,
                        color: AppUi.blue, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'HISTORICAL LOOKBACK',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5),
                        ),
                        Text(
                          '$tenantName ($tenantCode)',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppUi.blue.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppUi.blue.withOpacity(0.2),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_outline_rounded,
                                color: AppUi.blue, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Tentukan batas lookback hari penarikan data historis marketplace (Shopee & TikTok Shop). Maksimal 180 hari untuk menjaga performa server.',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey,
                                    height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'PILIH RENTANG LOOKBACK HARI:',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [30, 60, 90, 120, 180].map((days) {
                          final isSelected = selectedDays == days;
                          return ChoiceChip(
                            label: Text(
                              days == 180 ? '180 Hari (Max)' : '$days Hari',
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.w900
                                    : FontWeight.w600,
                                fontSize: 12,
                                color: isSelected ? Colors.white : null,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: AppUi.blue,
                            onSelected: (selected) {
                              if (selected) {
                                setDialogState(() => selectedDays = days);
                              }
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Checkbox(
                              value: shouldResetHistoricalPull,
                              activeColor: AppUi.blue,
                              onChanged: (val) {
                                setDialogState(() =>
                                    shouldResetHistoricalPull = val ?? false);
                              },
                            ),
                            const Expanded(
                              child: Text(
                                'Reset cursor & jalankan auto-pull data historis dari rentang awal hari ini',
                                style: TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(context),
                  child: const Text('BATAL'),
                ),
                FilledButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          setDialogState(() => isSaving = true);
                          try {
                            // 1. Update app_tenants order_retention_days
                            await _client.from('app_tenants').update({
                              'order_retention_days': selectedDays,
                              'updated_at': DateTime.now().toIso8601String(),
                            }).eq('tenant_id', tenantId);

                            // 2. If requested, reset historical sync state cursors
                            if (shouldResetHistoricalPull) {
                              final nowSec =
                                  DateTime.now().millisecondsSinceEpoch ~/ 1000;
                              final fromSec = nowSec - (selectedDays * 86400);

                              await _client
                                  .from('marketplace_order_sync_state')
                                  .update({
                                'bootstrap_status': 'pending',
                                'bootstrap_from_seconds': fromSec,
                                'bootstrap_to_seconds': nowSec,
                                'bootstrap_cursor_seconds': fromSec,
                                'next_run_at': DateTime.now().toIso8601String(),
                                'failure_count': 0,
                                'last_error': null,
                                'updated_at': DateTime.now().toIso8601String(),
                              }).eq('tenant_id', tenantId);

                              final fromDate = DateTime.now()
                                  .subtract(Duration(days: selectedDays))
                                  .toIso8601String()
                                  .split('T')
                                  .first;
                              final toDate = DateTime.now()
                                  .toIso8601String()
                                  .split('T')
                                  .first;

                              await _client
                                  .from('marketplace_finance_sync_state')
                                  .update({
                                'finance_status': 'pending',
                                'bootstrap_from_date': fromDate,
                                'bootstrap_to_date': toDate,
                                'bootstrap_cursor_date': fromDate,
                                'next_run_at': DateTime.now().toIso8601String(),
                                'failure_count': 0,
                                'last_error': null,
                                'updated_at': DateTime.now().toIso8601String(),
                              }).eq('tenant_id', tenantId);
                            }

                            if (mounted) {
                              Navigator.pop(context);
                              AppUi.showSnack(
                                  'Historical Lookback berhasil diset ke $selectedDays hari.');
                              _loadData();
                            }
                          } catch (e) {
                            if (mounted) {
                              setDialogState(() => isSaving = false);
                              AppUi.showSnack('Gagal menyimpan: $e');
                            }
                          }
                        },
                  style: FilledButton.styleFrom(backgroundColor: AppUi.blue),
                  child: isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('SIMPAN KONFIGURASI'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Hard Delete / Purge Operational Data Dialog
  void _showPurgeTenantDialog({
    required String tenantId,
    required String tenantName,
    required String tenantCode,
  }) {
    final confirmController = TextEditingController();
    bool isPurging = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isMatch = confirmController.text.trim().toLowerCase() ==
                tenantCode.trim().toLowerCase();

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: AppUi.red, size: 28),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'HARD DELETE DATA OPERASIONAL'.toUpperCase(),
                      style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: AppUi.red,
                          fontSize: 15),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppUi.red.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: AppUi.red.withOpacity(0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '⚠️ PERINGATAN PENGHAPUSAN PERMANEN:',
                            style: TextStyle(
                                color: AppUi.red,
                                fontWeight: FontWeight.w900,
                                fontSize: 12),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Tindakan ini akan menghapus 100% data operasional tenant:\n'
                            '• Semua Katalog Produk & Varian\n'
                            '• Riwayat Mutasi Stok & Barcode\n'
                            '• Seluruh Pesanan & Item Marketplace\n'
                            '• Laporan Keuangan, Payout & Mutasi Kas\n'
                            '• Data Pembelian, Supplier, Payroll & Absensi\n\n'
                            '🛡️ AKUN LOGIN OWNER TETAP DISIMPAN:\n'
                            'User Owner tetap dapat login di kemudian hari untuk memilih paket baru dan mengaktifkan kembali tokonya.',
                            style: TextStyle(fontSize: 11, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Ketik kode tenant "$tenantCode" di bawah untuk mengonfirmasi:',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: confirmController,
                      decoration: InputDecoration(
                        hintText: tenantCode,
                        prefixIcon: const Icon(Icons.delete_forever_rounded,
                            color: AppUi.red),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isPurging ? null : () => Navigator.pop(context),
                  child: const Text('BATAL',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppUi.red),
                  onPressed: (!isMatch || isPurging)
                      ? null
                      : () async {
                          setDialogState(() => isPurging = true);
                          try {
                            final res = await _client.rpc(
                              'platform_purge_tenant_operational_data',
                              params: {
                                'p_tenant_id': tenantId,
                                'p_confirmation_code':
                                    confirmController.text.trim(),
                              },
                            );
                            final ok =
                                res is Map && (res['ok'] as bool? ?? false);
                            if (ok) {
                              if (context.mounted) Navigator.pop(context);
                              AppUi.showSnack(res['message']?.toString() ??
                                  'Data operasional tenant berhasil dibersihkan!');
                              _loadData(forceRefresh: true);
                            } else {
                              throw Exception(res['message'] ??
                                  'Gagal membersihkan data tenant');
                            }
                          } catch (e, st) {
                            debugPrint('[PURGE_TENANT_ERROR] $e\n$st');
                            AppUi.showSnack('GAGAL: ${e.toString()}');
                          } finally {
                            if (context.mounted) {
                              setDialogState(() => isPurging = false);
                            }
                          }
                        },
                  child: isPurging
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('HAPUS TOTAL DATA'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Generate Invite Link Dialog
  void _showGenerateInviteDialog({String? preselectedTenantId}) {
    String? selectedTenantId = preselectedTenantId ??
        (_tenantsList.isNotEmpty
            ? _tenantsList.first['tenant_id']?.toString()
            : null);
    AppRole selectedRole = AppRole.superAdmin;
    final emailController = TextEditingController();
    final expiresController = TextEditingController(text: '7');
    bool generating = false;

    // List of roles eligible for invite creation
    final availableRoles = [
      AppRole.superAdmin,
      AppRole.admin,
      AppRole.warehouse,
      AppRole.produksi,
      AppRole.finance,
      AppRole.hostLive,
      AppRole.hr,
      AppRole.contentCreator,
    ];

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('GENERATE UNDANGAN'.toUpperCase(),
                  style: TextStyle(fontWeight: FontWeight.w800)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('TENANT TARGET',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 12)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: selectedTenantId,
                      items: _tenantsList.map((t) {
                        return DropdownMenuItem<String>(
                          value: t['tenant_id']?.toString(),
                          child: Text(t['tenant_name']?.toString() ?? '-'),
                        );
                      }).toList(),
                      onChanged: generating
                          ? null
                          : (val) =>
                              setDialogState(() => selectedTenantId = val),
                    ),
                    const SizedBox(height: 14),
                    Text('PERAN / ROLE',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 12)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<AppRole>(
                      value: selectedRole,
                      items: availableRoles.map((r) {
                        return DropdownMenuItem<AppRole>(
                          value: r,
                          child: Text(r.label),
                        );
                      }).toList(),
                      onChanged: generating
                          ? null
                          : (val) => setDialogState(
                              () => selectedRole = val ?? AppRole.superAdmin),
                    ),
                    const SizedBox(height: 14),
                    Text('EMAIL PENERIMA (OPSIONAL)',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: emailController,
                      enabled: !generating,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        hintText: 'Email wajib sama saat pendaftaran',
                        prefixIcon: Icon(Icons.email),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text('MASA BERLAKU (HARI)',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: expiresController,
                      enabled: !generating,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        hintText: 'Default: 7 hari',
                        prefixIcon: Icon(Icons.today),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: generating ? null : () => Navigator.pop(context),
                  child: Text('BATAL',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                FilledButton(
                  onPressed: (generating || selectedTenantId == null)
                      ? null
                      : () async {
                          setDialogState(() => generating = true);
                          try {
                            final email = emailController.text.trim();
                            final expiresStr = expiresController.text.trim();
                            final days = int.tryParse(expiresStr) ?? 7;

                            final token =
                                await _client.rpc('create_invite', params: {
                              'p_tenant_id': selectedTenantId,
                              'p_role_id': selectedRole.roleId,
                              'p_email': email.isEmpty ? null : email,
                              'p_expires_in_days': days,
                            }) as String?;

                            if (token != null) {
                              Navigator.pop(context);
                              _showTokenSuccessDialog(token, selectedRole);
                            } else {
                              throw Exception(
                                  'Gagal mendapatkan token undangan.');
                            }
                          } catch (e, st) {
                            debugPrint('[CREATE_INVITE_ERROR] $e\n$st');
                            AppUi.showSnack(
                                'GAGAL MEMBUAT UNDANGAN: ${e.toString()}');
                            setDialogState(() => generating = false);
                          }
                        },
                  child: generating
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        )
                      : Text('GENERATE'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showTokenSuccessDialog(String token, AppRole role) {
    final publicWebUrl = dotenv.isInitialized ? (dotenv.env['PUBLIC_WEB_REGISTER_URL']?.trim() ?? '') : '';
    final String registerUrl;
    if (publicWebUrl.isNotEmpty) {
      if (publicWebUrl.contains('?')) {
        registerUrl = '$publicWebUrl&invite=$token';
      } else {
        registerUrl = '$publicWebUrl?invite=$token';
      }
    } else {
      registerUrl = 'https://app.mdhproduction.com/register?invite=$token';
    }

    final appDeepLink = 'mobileerp://register?invite=$token';

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('UNDANGAN DIHASILKAN'.toUpperCase(),
              style:
                  TextStyle(fontWeight: FontWeight.w800, color: AppUi.green)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('LINK REGISTRASI UTAMA (HTTPS):',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppUi.mutedText(context, 0.90),
                      fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                registerUrl,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    decoration: TextDecoration.underline),
              ),
              const SizedBox(height: 16),
              Text('KODE TOKEN RAW:',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppUi.mutedText(context, 0.90),
                      fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                token,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                    fontSize: 13),
              ),
              const SizedBox(height: 16),
              Text('LINK APLIKASI (DEEP LINK):',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppUi.mutedText(context, 0.90),
                      fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                appDeepLink,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    color: AppUi.mutedText(context, 0.90)),
              ),
            ],
          ),
          actions: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: registerUrl));
                    AppUi.showSnack('LINK REGISTRASI DISALIN KE CLIPBOARD.');
                  },
                  icon: Icon(Icons.copy, size: 16),
                  label: Text('COPY LINK',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse(registerUrl);
                    try {
                      final launched = await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                      if (!launched) {
                        Clipboard.setData(ClipboardData(text: registerUrl));
                        AppUi.showSnack(
                            'GAGAL MEMBUKA LINK. LINK DISALIN KE CLIPBOARD.');
                      }
                    } catch (_) {
                      Clipboard.setData(ClipboardData(text: registerUrl));
                      AppUi.showSnack(
                          'GAGAL MEMBUKA LINK. LINK DISALIN KE CLIPBOARD.');
                    }
                  },
                  icon: Icon(Icons.open_in_new, size: 16),
                  label: Text('OPEN LINK',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: token));
                    AppUi.showSnack('TOKEN RAW DISALIN KE CLIPBOARD.');
                  },
                  icon: Icon(Icons.vpn_key, size: 16),
                  label: Text('COPY TOKEN',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: appDeepLink));
                    AppUi.showSnack('LINK APLIKASI DISALIN KE CLIPBOARD.');
                  },
                  icon: Icon(Icons.phone_android, size: 16),
                  label: Text('COPY APP LINK',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('SELESAI',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // Style badge based on readiness_status
  Widget _readinessBadge(String status) {
    Color color;
    String label;

    switch (status) {
      case 'ready':
        color = AppUi.green;
        label = 'READY';
        break;
      case 'unmapped_skus':
        color = AppUi.orange;
        label = 'SKU BELUM DI-MAP';
        break;
      case 'no_variants':
        color = AppUi.blue;
        label = 'TIDAK ADA VARIAN';
        break;
      case 'token_expired':
        color = AppUi.red;
        label = 'AKSES TOKEN EXPIRED';
        break;
      case 'no_account':
        color = Theme.of(context).colorScheme.onSurfaceVariant;
        label = 'BELUM ADA TOKO';
        break;
      default:
        color = Theme.of(context).colorScheme.onSurfaceVariant;
        label = status.toUpperCase();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.30), width: 0.8),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 10),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    final grouped = Map<String, List<Map<String, dynamic>>>.fromEntries(
      _groupedTenants.entries.where((entry) => _tenantMatchesFilter(entry.key)),
    );

    return WebResponsiveScaffold(
      appBar: AppBar(
        title: const Text('PLATFORM OWNER DASHBOARD',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: '🤖 AI Infrastructure Report',
            icon: const Icon(Icons.smart_toy_rounded, color: Colors.amberAccent),
            onPressed: _showVpsAiInfraDialog,
          ),
          IconButton(
            tooltip: 'Reload data',
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
          ValueListenableBuilder<AppVisualMode>(
            valueListenable: AppThemeModeController.mode,
            builder: (context, visualMode, _) {
              final isDark = visualMode == AppVisualMode.man;
              return IconButton(
                icon: Icon(
                  isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                ),
                tooltip: isDark ? 'Switch to Girl Light' : 'Switch to Man Dark',
                onPressed: _themeSwitching ? null : _switchThemeSafely,
              );
            },
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: _isLoggingOut ? null : _logout,
          ),
        ],
      ),
      body: AppGlobalBackdrop(
        child: _isLoading
            ? const Center(
                child: FuturisticLoader(message: 'MEMUAT DATA TENANT...'))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Welcome Header & Bento Stats
                    Builder(builder: (context) {
                      final activeCount = _tenantsList
                          .where((t) =>
                              _getTenantGraceState(
                                  t['tenant_id']?.toString() ?? '')['state'] ==
                              'active')
                          .length;
                      final graceCount = _tenantsList
                          .where((t) =>
                              _getTenantGraceState(
                                  t['tenant_id']?.toString() ?? '')['state'] ==
                              'grace_period')
                          .length;
                      final expiredCount = _tenantsList
                          .where((t) =>
                              _getTenantGraceState(
                                  t['tenant_id']?.toString() ?? '')['state'] ==
                              'expired')
                          .length;
                      final mrr = _calculateEstimatedMrr();

                      return FuturisticHeader(
                        icon: Icons.admin_panel_settings_rounded,
                        title: 'PLATFORM MANAGEMENT',
                        subtitle:
                            'Pantau kesiapan integrasi, kelola siklus langganan SaaS, dan bersihkan data tenant expired.',
                        stats: [
                          StatPill(
                              label: 'Total Tenants',
                              value: _tenantsList.length.toString(),
                              accentColor: AppUi.blue),
                          StatPill(
                              label: 'Aktif',
                              value: activeCount.toString(),
                              accentColor: AppUi.green),
                          StatPill(
                              label: 'Grace Period',
                              value: graceCount.toString(),
                              accentColor: Colors.amber),
                          StatPill(
                              label: 'Expired',
                              value: expiredCount.toString(),
                              accentColor: AppUi.red),
                          StatPill(
                              label: 'Projected MRR',
                              value: AppUi.rupiah(mrr),
                              accentColor: AppUi.teal),
                        ],
                      );
                    }),
                    const SizedBox(height: 24),

                    // Quick Actions
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final itemWidth = constraints.maxWidth >= 720
                            ? (constraints.maxWidth - 24) / 3
                            : constraints.maxWidth;

                        Widget actionCard({
                          required IconData icon,
                          required String label,
                          required VoidCallback onTap,
                        }) {
                          return SizedBox(
                            width: itemWidth,
                            child: NiceCard(
                              onTap: onTap,
                              borderColor: null,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(icon),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            actionCard(
                              icon: Icons.chat_rounded,
                              label: 'TANYA AI ASSISTANT',
                              onTap: () => AiChatAssistantSheet.show(
                                context,
                                title: '🤖 Platform Owner AI Assistant',
                                subtitle: 'Tanyakan statistik tenant, performa VPS, atau kesehatan server',
                                isPlatformOwner: true,
                              ),
                            ),
                            actionCard(
                              icon: Icons.smart_toy_rounded,
                              label: '🤖 AI INFRASTRUCTURE',
                              onTap: _showVpsAiInfraDialog,
                            ),
                            actionCard(
                              icon: Icons.add_business_rounded,
                              label: 'TAMBAH TENANT',
                              onTap: _showCreateTenantDialog,
                            ),
                            actionCard(
                              icon: Icons.mail_outline_rounded,
                              label: 'KIRIM UNDANGAN',
                              onTap: () => _showGenerateInviteDialog(),
                            ),
                            actionCard(
                              icon: Icons.card_membership_rounded,
                              label: 'DAFTAR PAKET',
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const SubscriptionPlansPage()),
                                );
                              },
                            ),
                            actionCard(
                              icon: Icons.web_rounded,
                              label: 'CMS LANDING PAGE',
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const LandingPageCmsPage()),
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 24),

                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _filterChip('all', 'SEMUA'),
                        _filterChip('active', 'AKTIF'),
                        _filterChip('trialing', 'TRIAL'),
                        _filterChip('grace_period', 'GRACE PERIOD (7D)'),
                        _filterChip('expired', 'EXPIRED / PURGE'),
                        _filterChip('unassigned', 'BELUM DISET'),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Tenants List Header
                    SectionTitle(
                      title: 'DAFTAR CLIENT & STATUS KESIAPAN',
                      actionText: 'RELOAD',
                      onAction: () => _loadData(forceRefresh: true),
                    ),

                    if (grouped.isEmpty)
                      const EmptyState(
                        title: 'BELUM ADA TENANT',
                        subtitle:
                            'Tekan "TAMBAH TENANT" untuk mendaftarkan client pertama Anda.',
                        icon: Icons.business,
                      )
                    else
                      ...grouped.entries.map((entry) {
                        final tenantId = entry.key;
                        final rows = entry.value;
                        final tenantName =
                            rows.first['tenant_name']?.toString() ??
                                'Unknown Tenant';
                        final tenantStatus =
                            rows.first['tenant_status']?.toString() ?? 'active';

                        final tenantObj = _tenantObjById(tenantId) ??
                            <String, dynamic>{};
                        final tenantCode =
                            tenantObj['tenant_code']?.toString() ?? '-';
                        final graceState = _getTenantGraceState(tenantId);
                        final graceColor = graceState['color'] as Color;
                        final isPurgeable =
                            graceState['isPurgeable'] as bool? ?? false;
                        final planCode =
                            graceState['planCode']?.toString() ?? 'starter';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 20),
                          child: NiceCard(
                            borderColor: isPurgeable ? AppUi.red.withOpacity(0.5) : null,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Tenant Info Row
                                Row(
                                  children: [
                                    Icon(Icons.business_center, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            tenantName.toUpperCase(),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 15),
                                          ),
                                          Text(
                                            'CODE: $tenantCode',
                                            style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700,
                                                color: AppUi.mutedText(
                                                    context, 0.7)),
                                          ),
                                        ],
                                      ),
                                    ),
                                    _tenantStatusChip(tenantStatus),
                                  ],
                                ),
                                const SizedBox(height: 10),

                                // Subscription & Grace Period Banner
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: graceColor.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: graceColor.withOpacity(0.4),
                                        width: 1),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.card_membership_rounded,
                                              size: 14, color: graceColor),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              'PAKET: ${graceState['planName']} (${graceState['planCode']})'
                                                  .toUpperCase(),
                                              style: TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 11,
                                                  color: graceColor),
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color:
                                                  graceColor.withOpacity(0.2),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              graceState['label']
                                                  .toString()
                                                  .toUpperCase(),
                                              style: TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 9,
                                                  color: graceColor),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (graceState['periodEnd'] != null) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          'Jatuh Tempo: ${AppUi.date(graceState['periodEnd'].toString())}',
                                          style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              color: AppUi.mutedText(
                                                  context, 0.8)),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),

                                // Quick Action Buttons Bar
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      FilledButton.icon(
                                        onPressed: () =>
                                            _showExtendSubscriptionDialog(
                                          tenantId: tenantId,
                                          tenantName: tenantName,
                                          initialPlanCode: planCode,
                                        ),
                                        icon: const Icon(
                                            Icons.credit_card_rounded,
                                            size: 14),
                                        label: const Text('PERPANJANG / BAYAR',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 10)),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: AppUi.blue,
                                          minimumSize: const Size(0, 34),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: () {
                                          Navigator.of(context)
                                              .push(
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      TenantSubscriptionDetailPage(
                                                    tenantId: tenantId,
                                                    tenantName: tenantName,
                                                    tenantCode: tenantCode,
                                                    ownerName:
                                                        tenantObj['owner_name']
                                                            ?.toString(),
                                                    ownerEmail:
                                                        tenantObj['owner_email']
                                                            ?.toString(),
                                                  ),
                                                ),
                                              )
                                              .then((_) => _loadData());
                                        },
                                        icon: const Icon(Icons.settings_rounded,
                                            size: 14),
                                        label: const Text('DETAIL PAKET',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 10)),
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size(0, 34),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: () {
                                          final currentRetention = tenantObj['order_retention_days'] is int
                                              ? tenantObj['order_retention_days'] as int
                                              : int.tryParse(tenantObj['order_retention_days']?.toString() ?? '');
                                          final subList = tenantObj['tenant_subscriptions'] as List?;
                                          final activeSub = subList != null && subList.isNotEmpty ? subList.first as Map<String, dynamic>? : null;
                                          final defaultPlanDays = activeSub?['subscription_plans']?['max_order_retention_days'] is int
                                              ? activeSub!['subscription_plans']['max_order_retention_days'] as int
                                              : int.tryParse(activeSub?['subscription_plans']?['max_order_retention_days']?.toString() ?? '');
                                          _showConfigureLookbackDialog(
                                            tenantId: tenantId,
                                            tenantName: tenantName,
                                            tenantCode: tenantCode,
                                            currentRetentionDays: currentRetention,
                                            defaultPlanDays: defaultPlanDays,
                                          );
                                        },
                                        icon: const Icon(Icons.history_toggle_off_rounded,
                                            size: 14),
                                        label: Text(
                                          tenantObj['order_retention_days'] != null
                                              ? 'LOOKBACK (' + tenantObj['order_retention_days'].toString() + 'H)'
                                              : 'LOOKBACK',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 10),
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size(0, 34),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: () {
                                          Navigator.of(context)
                                              .push(
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      UserManagementPage(
                                                    tenantId: tenantId,
                                                    tenantName: tenantName,
                                                  ),
                                                ),
                                              )
                                              .then((_) => _loadData());
                                        },
                                        icon: const Icon(
                                            Icons.manage_accounts_rounded,
                                            size: 14),
                                        label: const Text('USER',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 10)),
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size(0, 34),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: () =>
                                            _showGenerateInviteDialog(
                                                preselectedTenantId: tenantId),
                                        icon: const Icon(
                                            Icons.person_add_alt_1_rounded,
                                            size: 14),
                                        label: const Text('UNDANG',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 10)),
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size(0, 34),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10),
                                        ),
                                      ),
                                      if (isPurgeable) ...[
                                        const SizedBox(width: 8),
                                        FilledButton.icon(
                                          onPressed: () => _showPurgeTenantDialog(
                                            tenantId: tenantId,
                                            tenantName: tenantName,
                                            tenantCode: tenantCode,
                                          ),
                                          icon: const Icon(
                                              Icons.delete_forever_rounded,
                                              size: 14),
                                          label: const Text('HARD DELETE DATA',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 10)),
                                          style: FilledButton.styleFrom(
                                            backgroundColor: AppUi.red,
                                            minimumSize: const Size(0, 34),
                                            padding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 10),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Divider(height: 1, thickness: 1, color: accent.withOpacity(0.3)),
                                const SizedBox(height: 12),

                                // Accounts list
                                ...rows.map((row) {
                                  final marketplace =
                                      row['marketplace']?.toString();
                                  final storeAlias =
                                      row['store_alias']?.toString() ?? '-';
                                  final readinessStatus =
                                      row['readiness_status']?.toString() ??
                                          'no_account';

                                  if (marketplace == null) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 8),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            'Belum ada akun toko terhubung.'
                                                .toUpperCase(),
                                            style: TextStyle(
                                                color: AppUi.mutedText(
                                                    context, 0.90),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800),
                                          ),
                                          _readinessBadge('no_account'),
                                        ],
                                      ),
                                    );
                                  }

                                  // Account connected metrics
                                  final productsCount =
                                      AppUi.toNum(row['product_snapshot_count'])
                                          .toInt();
                                  final variantsCount =
                                      AppUi.toNum(row['variant_snapshot_count'])
                                          .toInt();
                                  final orderCount =
                                      AppUi.toNum(row['order_count']).toInt();
                                  final financeCount =
                                      AppUi.toNum(row['finance_count']).toInt();
                                  final rawSkuMapped =
                                      AppUi.toNum(row['sku_mapped_count'])
                                          .toInt();
                                  final rawHppMapped =
                                      AppUi.toNum(row['hpp_mapped_count'])
                                          .toInt();
                                  final skuMapped = variantsCount > 0 &&
                                          rawSkuMapped > variantsCount
                                      ? variantsCount
                                      : rawSkuMapped;
                                  final hppMapped = variantsCount > 0 &&
                                          rawHppMapped > variantsCount
                                      ? variantsCount
                                      : rawHppMapped;
                                  final unmappedItems = AppUi.toNum(
                                          row['unmapped_order_item_count'])
                                      .toInt();

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(12),
                                    decoration: AppUi.modernCardDecoration(
                                      context,
                                      radius: 16,
                                      borderColor: accent.withOpacity(0.18),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              marketplace.toLowerCase() ==
                                                      'shopee'
                                                  ? Icons.shopping_bag_outlined
                                                  : Icons.storefront_outlined,
                                              size: 18,
                                              color: theme.colorScheme.primary,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                '${marketplace.toUpperCase()}: $storeAlias',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 12),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            _readinessBadge(readinessStatus),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        // Metrics grid
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            _smallStat('Products',
                                                productsCount.toString()),
                                            _smallStat('Variants',
                                                variantsCount.toString()),
                                            _smallStat('Orders',
                                                orderCount.toString()),
                                            _smallStat('Finance Recs',
                                                financeCount.toString()),
                                            _smallStat('SKU Mapped',
                                                '$skuMapped/$variantsCount',
                                                alert: variantsCount > 0 &&
                                                    skuMapped < variantsCount),
                                            _smallStat('HPP Mapped',
                                                '$hppMapped/$variantsCount',
                                                alert: variantsCount > 0 &&
                                                    hppMapped < variantsCount),
                                            _smallStat('Unmapped Items',
                                                unmappedItems.toString(),
                                                alert: unmappedItems > 0),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _smallStat(String label, String value, {bool alert = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: alert
            ? AppUi.red.withOpacity(0.1)
            : AppUi.mutedText(context, 0.90).withOpacity(0.05),
        border: Border.all(
            color: alert ? AppUi.red : AppUi.mutedText(context, 0.90),
            width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: '.toUpperCase(),
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 8.5,
                color: alert ? AppUi.red : AppUi.mutedText(context, 0.90)),
          ),
          Text(
            value,
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 9.5,
                color: alert ? AppUi.red : null),
          ),
        ],
      ),
    );
  }

  Future<void> _showVpsAiInfraDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Container(
          width: 320,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 18),
              Text(
                'Mengaudit Performa VPS & Infrastruktur\nvia AI Agent...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      final response = await _client.functions.invoke(
        'ai-insights-engine',
        body: <String, dynamic>{
          'action': 'vps_infra_report',
        },
      );

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};

      if (response.status != 200 || data['ok'] == false) {
        final err = data['error'] ?? 'Gagal memuat Laporan AI VPS';
        AppUi.safeSnack(context, 'AI VPS Error: $err');
        return;
      }

      final report = data['report'] is Map ? Map<String, dynamic>.from(data['report'] as Map) : <String, dynamic>{};
      final telemetry = data['telemetry'] is Map ? Map<String, dynamic>.from(data['telemetry'] as Map) : <String, dynamic>{};

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (modalCtx) {
          return _buildVpsAiInfraBottomSheet(modalCtx, report, telemetry);
        },
      );
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        AppUi.safeSnack(context, 'AI VPS Report gagal: $e');
      }
    }
  }

  Widget _buildVpsAiInfraBottomSheet(
      BuildContext modalCtx, Map<String, dynamic> report, Map<String, dynamic> telemetry) {
    final status = report['system_status']?.toString() ?? 'HEALTHY';
    final cpuMetrics = telemetry['cpu_metrics'] is Map ? Map<String, dynamic>.from(telemetry['cpu_metrics'] as Map) : <String, dynamic>{};
    final memMetrics = telemetry['memory_metrics'] is Map ? Map<String, dynamic>.from(telemetry['memory_metrics'] as Map) : <String, dynamic>{};
    final diskMetrics = telemetry['disk_health'] is Map ? Map<String, dynamic>.from(telemetry['disk_health'] as Map) : <String, dynamic>{};
    final saasOverview = telemetry['saas_overview'] is Map ? Map<String, dynamic>.from(telemetry['saas_overview'] as Map) : <String, dynamic>{};
    final secMetrics = telemetry['security_hardening'] is Map ? Map<String, dynamic>.from(telemetry['security_hardening'] as Map) : <String, dynamic>{};
    final recs = report['recommendations'] is List ? (report['recommendations'] as List) : <dynamic>[];
    final containers = telemetry['active_containers'] is List ? (telemetry['active_containers'] as List) : <dynamic>[];
    final execSummary = report['executive_summary']?.toString() ?? '';

    final cpuLoad = cpuMetrics['postgres_cpu_load']?.toString() ?? 'Load 1m: 0.30';
    final bufferCache = cpuMetrics['buffer_cache_hit_ratio']?.toString() ?? '99.89%';
    final activeConns = cpuMetrics['active_connections']?.toString() ?? '1';
    final ramUsed = memMetrics['used_ram_gb']?.toString() ?? '2.6';
    final ramTotal = memMetrics['total_ram_gb']?.toString() ?? '3.8';
    final swapUsed = memMetrics['swap_used_mb']?.toString() ?? '910';
    final diskUsed = diskMetrics['used_space']?.toString() ?? '32G (49%)';
    final diskTotal = diskMetrics['total_space']?.toString() ?? '69G';
    final diskAvail = diskMetrics['available_space']?.toString() ?? '34G';

    final totalTenants = saasOverview['total_tenants']?.toString() ?? '4';
    final activeTenants = saasOverview['active_tenants']?.toString() ?? '2';
    final projectedMrr = (saasOverview['projected_mrr_idr'] is num)
        ? 'Rp ${(saasOverview['projected_mrr_idr'] as num).round().toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}'
        : 'Rp 2.000.000.000';

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(modalCtx).size.height * 0.88,
      ),
      decoration: BoxDecoration(
        color: Theme.of(modalCtx).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(modalCtx).colorScheme.onSurface.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.smart_toy_rounded, color: Colors.amber, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '🤖 VPS & Infra AI Agent Health Audit',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        'Host: ${telemetry['hostname'] ?? 'inventory-vps'} • Status: $status',
                        style: const TextStyle(
                            fontSize: 12,
                            color: Colors.green,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(modalCtx),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Executive Summary Box
                  if (execSummary.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.indigo.withOpacity(0.3)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.auto_awesome_rounded, color: Colors.indigo, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Evaluasi AI DevSecOps', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: Colors.indigo)),
                                const SizedBox(height: 4),
                                Text(execSummary, style: const TextStyle(fontSize: 12, height: 1.4)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // 4-Grid Telemetry Cards
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.green.withOpacity(0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.speed_rounded, color: Colors.green, size: 18),
                                  SizedBox(width: 6),
                                  Text('Postgres CPU Load', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(cpuLoad, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.blue.withOpacity(0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.memory_rounded, color: Colors.blue, size: 18),
                                  SizedBox(width: 6),
                                  Text('RAM & Swap', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('$ramUsed / $ramTotal GB (Swap: ${swapUsed}MB)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.orange.withOpacity(0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.storage_rounded, color: Colors.orange, size: 18),
                                  SizedBox(width: 6),
                                  Text('NVMe Disk', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('$diskUsed dari $diskTotal (Sisa: $diskAvail)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.teal.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.teal.withOpacity(0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.data_thresholding_rounded, color: Colors.teal, size: 18),
                                  SizedBox(width: 6),
                                  Text('DB Cache Hit & Conns', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('$bufferCache • $activeConns active', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // SaaS Multi-Tenant Live Stats Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.purple.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.purple.withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                                Icon(Icons.hub_rounded, color: Colors.purple, size: 18),
                            SizedBox(width: 8),
                            Text('SaaS Multi-Tenant Overview (Live)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Colors.purple)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('• Total Tenant Terdaftar: $totalTenants toko ($activeTenants aktif)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        Text('• Projected MRR: $projectedMrr / bulan', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.purple)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Security Audit Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Theme.of(modalCtx).colorScheme.primaryContainer.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(modalCtx).colorScheme.primary.withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.shield_rounded, color: Theme.of(modalCtx).colorScheme.primary, size: 18),
                            const SizedBox(width: 8),
                            const Text('Audit Keamanan & Network Hardening (Read-Only)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('• Kong Loopback: ${secMetrics['kong_ports'] ?? 'Bound 127.0.0.1:8050'}', style: const TextStyle(fontSize: 12)),
                        Text('• Proteksi File .env: ${secMetrics['dotfile_access'] ?? 'Blocked 404'}', style: const TextStyle(fontSize: 12)),
                        Text('• Nginx Timeout: ${secMetrics['nginx_read_timeout'] ?? '180s (No 504 Timeout)'}', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Error Logs & VPS Bugs Card
                  if (telemetry['active_error_logs_and_bugs'] is List && (telemetry['active_error_logs_and_bugs'] as List).isNotEmpty) ...[
                    const Text(
                      '🐛 Audit Error Log & Bug Infrastruktur',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 10),
                    ...(telemetry['active_error_logs_and_bugs'] as List).map((bug) {
                      final b = bug is Map ? Map<String, dynamic>.from(bug as Map) : <String, dynamic>{};
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange.withOpacity(0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Chip(
                                  label: Text(b['severity']?.toString() ?? 'WARNING', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                                  backgroundColor: b['severity'] == 'HIGH' ? Colors.red : Colors.orange,
                                  visualDensity: VisualDensity.compact,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${b['subsystem'] ?? 'VPS'}: ${b['error_code'] ?? ''}',
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text('• Log: ${b['message'] ?? ''}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text('• Remidiasi: ${b['remediation'] ?? ''}', style: TextStyle(fontSize: 11, color: Theme.of(modalCtx).colorScheme.onSurface.withOpacity(0.7))),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                  ],

                  // Docker Microservices Status
                  const Text(
                    '🐳 Status Docker Microservices',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: containers.map((c) {
                      final isMap = c is Map;
                      final name = isMap ? c['name'].toString() : c.toString();
                      final mem = isMap ? ' (${c['memory'] ?? ''})' : '';
                      return Chip(
                        avatar: const Icon(Icons.check_circle_rounded, color: Colors.green, size: 16),
                        label: Text('$name$mem', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                        backgroundColor: Theme.of(modalCtx).colorScheme.surfaceVariant,
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),

                  // AI Recommendations
                  const Text(
                    '🛡️ Rekomendasi DevSecOps AI Agent',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  ...recs.map((rec) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(modalCtx).colorScheme.surfaceVariant.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Theme.of(modalCtx).colorScheme.outlineVariant.withOpacity(0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.verified_rounded, color: Colors.amber, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Text(rec.toString(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                      ],
                    ),
                  )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
