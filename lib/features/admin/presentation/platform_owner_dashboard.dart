import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/constants/app_roles.dart';
import '../../../services/auth_service.dart';
import '../../auth/presentation/login_page.dart';
import 'subscription_plans_page.dart';
import 'tenant_subscription_detail_page.dart';

class PlatformOwnerDashboard extends StatefulWidget {
  const PlatformOwnerDashboard({super.key});

  @override
  State<PlatformOwnerDashboard> createState() => _PlatformOwnerDashboardState();
}

class _PlatformOwnerDashboardState extends State<PlatformOwnerDashboard> {
  final SupabaseClient _client = Supabase.instance.client;
  bool _isLoading = true;
  String _tenantFilter = 'all';
  List<Map<String, dynamic>> _readinessData = [];
  List<Map<String, dynamic>> _tenantsList = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      // Fetch readiness summary
      final response = await _client.rpc('platform_tenant_readiness_summary');
      if (response != null && response is List) {
        _readinessData =
            response.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else {
        _readinessData = [];
      }

      // Fetch distinct tenants list with subscription info
      final tenantsRes = await _client
          .from('app_tenants')
          .select(
              'tenant_id, tenant_code, tenant_name, owner_name, owner_email, status, tenant_subscriptions(status, trial_ends_at, current_period_end, created_at, subscription_plans(plan_name, plan_code))')
          .order('tenant_name');
      _tenantsList = (tenantsRes as List)
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

  bool _dateIsPast(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed != null && parsed.isBefore(DateTime.now());
  }

  String _tenantSubscriptionState(String tenantId) {
    final tenantObj = _tenantObjById(tenantId);
    final subs = tenantObj?['tenant_subscriptions'] as List?;
    final activeSub = _getActiveSubscription(subs);
    if (activeSub == null) return 'unassigned';

    final status = activeSub['status']?.toString().toLowerCase() ?? 'active';
    if (status == 'expired' ||
        status == 'suspended' ||
        status == 'canceled' ||
        status == 'past_due') {
      return 'expired';
    }
    if (_dateIsPast(activeSub['current_period_end'])) return 'expired';
    if (status == 'trialing') return 'trialing';
    return 'active';
  }

  bool _tenantMatchesFilter(String tenantId) {
    if (_tenantFilter == 'all') return true;
    return _tenantSubscriptionState(tenantId) == _tenantFilter;
  }

  Widget _filterChip(String value, String label) {
    return ChoiceChip(
      label: Text(label,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 10)),
      selected: _tenantFilter == value,
      onSelected: (_) => setState(() => _tenantFilter = value),
    );
  }

  Widget _tenantStatusChip(String status) {
    final color = AppUi.statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Text(
        status.toUpperCase(),
        style:
            TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 9),
      ),
    );
  }

  Future<void> _logout() async {
    final authService = AuthService();
    await authService.signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
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
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: Colors.black, width: 3),
          ),
          title: Text('TAMBAH TENANT BARU'.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w900)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('NAMA TENANT / CLIENT',
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
              child: const Text('BATAL',
                  style: TextStyle(fontWeight: FontWeight.w900)),
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
              child: const Text('SIMPAN'),
            ),
          ],
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
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
                side: BorderSide(color: Colors.black, width: 3),
              ),
              title: Text('GENERATE UNDANGAN'.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w900)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('TENANT TARGET',
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
                    const Text('PERAN / ROLE',
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
                    const Text('EMAIL PENERIMA (OPSIONAL)',
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
                    const Text('MASA BERLAKU (HARI)',
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
                  child: const Text('BATAL',
                      style: TextStyle(fontWeight: FontWeight.w900)),
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
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black),
                        )
                      : const Text('GENERATE'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showTokenSuccessDialog(String token, AppRole role) {
    final publicWebUrl = dotenv.env['PUBLIC_WEB_REGISTER_URL']?.trim() ?? '';
    final String registerUrl;
    if (publicWebUrl.isNotEmpty) {
      if (publicWebUrl.contains('?')) {
        registerUrl = '$publicWebUrl&invite=$token';
      } else {
        registerUrl = '$publicWebUrl?invite=$token';
      }
    } else {
      registerUrl = 'https://mobile-erp-apps.vercel.app/register?invite=$token';
    }

    final appDeepLink = 'mobileerp://register?invite=$token';

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: Colors.black, width: 3),
          ),
          title: Text('UNDANGAN DIHASILKAN'.toUpperCase(),
              style: const TextStyle(
                  fontWeight: FontWeight.w900, color: AppUi.green)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('LINK REGISTRASI UTAMA (HTTPS):',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.grey[600],
                      fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                registerUrl,
                style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                    decoration: TextDecoration.underline),
              ),
              const SizedBox(height: 16),
              Text('KODE TOKEN RAW:',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.grey[600],
                      fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                token,
                style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    fontSize: 13),
              ),
              const SizedBox(height: 16),
              Text('LINK APLIKASI (DEEP LINK):',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.grey[600],
                      fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                appDeepLink,
                style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                    color: Colors.grey),
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
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('COPY LINK',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
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
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('OPEN LINK',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
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
                  icon: const Icon(Icons.vpn_key, size: 16),
                  label: const Text('COPY TOKEN',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
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
                  icon: const Icon(Icons.phone_android, size: 16),
                  label: const Text('COPY APP LINK',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('SELESAI',
                      style: TextStyle(fontWeight: FontWeight.w900)),
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
        color = Colors.grey;
        label = 'BELUM ADA TOKO';
        break;
      default:
        color = Colors.black;
        label = status.toUpperCase();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        border: Border.all(color: color, width: 2),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 10),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark ? Colors.white : Colors.black;

    final grouped = Map<String, List<Map<String, dynamic>>>.fromEntries(
      _groupedTenants.entries.where((entry) => _tenantMatchesFilter(entry.key)),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('PLATFORM OWNER DASHBOARD',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Reload data',
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
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
                    // Welcome Header
                    FuturisticHeader(
                      icon: Icons.admin_panel_settings_rounded,
                      title: 'PLATFORM MANAGEMENT',
                      subtitle:
                          'Pantau kesiapan integrasi dan kelola client multi-tenant secara terpusat.',
                      stats: [
                        StatPill(
                            label: 'Total Tenants',
                            value: _tenantsList.length.toString(),
                            accentColor: AppUi.blue),
                        StatPill(
                            label: 'Integrations',
                            value: _readinessData
                                .where(
                                    (e) => e['marketplace_account_id'] != null)
                                .length
                                .toString(),
                            accentColor: AppUi.teal),
                      ],
                    ),
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
                              borderColor: Colors.black,
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
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900,
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
                        _filterChip('unassigned', 'BELUM DISET'),
                        _filterChip('expired', 'EXPIRED/SUSPENDED'),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Tenants List Header
                    SectionTitle(
                      title: 'DAFTAR CLIENT & STATUS KESIAPAN',
                      actionText: 'RELOAD',
                      onAction: _loadData,
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

                        return Container(
                          margin: const EdgeInsets.only(bottom: 20),
                          child: NiceCard(
                            borderColor: Colors.black,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Tenant Info Row
                                Row(
                                  children: [
                                    const Icon(Icons.business_center, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        tenantName.toUpperCase(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 15),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    _tenantStatusChip(tenantStatus),
                                    IconButton(
                                      tooltip: 'Kelola Subscription',
                                      icon: const Icon(
                                          Icons.card_membership_rounded,
                                          size: 18),
                                      onPressed: () {
                                        final tenantObj =
                                            _tenantObjById(tenantId) ??
                                                <String, dynamic>{};
                                        Navigator.of(context)
                                            .push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    TenantSubscriptionDetailPage(
                                                  tenantId: tenantId,
                                                  tenantName: tenantName,
                                                  tenantCode:
                                                      tenantObj['tenant_code']
                                                              ?.toString() ??
                                                          '-',
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
                                    ),
                                    IconButton(
                                      tooltip: 'Undang user ke tenant ini',
                                      icon: const Icon(
                                          Icons.person_add_alt_1_rounded,
                                          size: 18),
                                      onPressed: () =>
                                          _showGenerateInviteDialog(
                                              preselectedTenantId: tenantId),
                                    ),
                                  ],
                                ),
                                Builder(builder: (context) {
                                  final tenantObj = _tenantsList.firstWhere(
                                    (t) =>
                                        t['tenant_id']?.toString() == tenantId,
                                    orElse: () => <String, dynamic>{},
                                  );
                                  final subs = tenantObj['tenant_subscriptions']
                                      as List?;
                                  final activeSub =
                                      _getActiveSubscription(subs);
                                  if (activeSub == null) {
                                    return Container(
                                      margin: const EdgeInsets.only(top: 8),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: AppUi.orange.withOpacity(0.12),
                                        border: Border.all(
                                            color: AppUi.orange, width: 1.5),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                              Icons.warning_amber_rounded,
                                              size: 12,
                                              color: AppUi.orange),
                                          const SizedBox(width: 4),
                                          Text(
                                            'UNASSIGNED (FALLBACK ACTIVE)'
                                                .toUpperCase(),
                                            style: const TextStyle(
                                                color: AppUi.orange,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 9),
                                          ),
                                        ],
                                      ),
                                    );
                                  }

                                  final planName =
                                      activeSub['subscription_plans']
                                                  ?['plan_name']
                                              ?.toString() ??
                                          'Unknown Plan';
                                  final planCode =
                                      activeSub['subscription_plans']
                                                  ?['plan_code']
                                              ?.toString() ??
                                          '-';
                                  final subStatus =
                                      activeSub['status']?.toString() ??
                                          'active';
                                  final trialEnd =
                                      activeSub['trial_ends_at']?.toString();
                                  final periodEnd =
                                      activeSub['current_period_end']
                                          ?.toString();
                                  final expired = _dateIsPast(periodEnd);
                                  final color = expired
                                      ? AppUi.red
                                      : AppUi.statusColor(subStatus);

                                  return Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.only(top: 8),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: color.withOpacity(0.12),
                                      border:
                                          Border.all(color: color, width: 1.5),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(Icons.card_membership_rounded,
                                                size: 12, color: color),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                'PAKET: $planName ($planCode) - $subStatus'
                                                    .toUpperCase(),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 9,
                                                    color: color),
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (trialEnd != null ||
                                            periodEnd != null) ...[
                                          const SizedBox(height: 4),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 4,
                                            children: [
                                              if (trialEnd != null)
                                                Text(
                                                  'TRIAL: ${AppUi.date(trialEnd)}'
                                                      .toUpperCase(),
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      fontSize: 9),
                                                ),
                                              if (periodEnd != null)
                                                Text(
                                                  '${expired ? "EXPIRED" : "EXP"}: ${AppUi.date(periodEnd)}'
                                                      .toUpperCase(),
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      fontSize: 9,
                                                      color: expired
                                                          ? AppUi.red
                                                          : null),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                  );
                                }),
                                const SizedBox(height: 12),
                                Divider(height: 1, thickness: 2, color: accent),
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
                                                color: Colors.grey[600],
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
                                  final skuMapped =
                                      AppUi.toNum(row['sku_mapped_count'])
                                          .toInt();
                                  final hppMapped =
                                      AppUi.toNum(row['hpp_mapped_count'])
                                          .toInt();
                                  final unmappedItems = AppUi.toNum(
                                          row['unmapped_order_item_count'])
                                      .toInt();

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      border:
                                          Border.all(color: accent, width: 2),
                                      color: theme.scaffoldBackgroundColor,
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
                                                style: const TextStyle(
                                                    fontWeight: FontWeight.w900,
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
        color:
            alert ? AppUi.red.withOpacity(0.1) : Colors.grey.withOpacity(0.05),
        border: Border.all(
            color: alert ? AppUi.red : Colors.grey[400]!, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: '.toUpperCase(),
            style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 8.5,
                color: alert ? AppUi.red : Colors.grey[700]),
          ),
          Text(
            value,
            style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 9.5,
                color: alert ? AppUi.red : null),
          ),
        ],
      ),
    );
  }
}
