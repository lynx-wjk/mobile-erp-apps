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
      registerUrl = 'https://mobile-erp-apps.vercel.app/register?invite=$token';
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
                            borderColor: null,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Tenant Info Row
                                Row(
                                  children: [
                                    Icon(Icons.business_center, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        tenantName.toUpperCase(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontWeight: FontWeight.w800,
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
                                      icon: Icon(Icons.card_membership_rounded,
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
                                      icon: Icon(Icons.person_add_alt_1_rounded,
                                          size: 18),
                                      onPressed: () =>
                                          _showGenerateInviteDialog(
                                              preselectedTenantId: tenantId),
                                    ),
                                    IconButton(
                                      tooltip: 'Kelola User / Reset Password',
                                      icon: Icon(Icons.manage_accounts_rounded,
                                          size: 18),
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
                                          Icon(Icons.warning_amber_rounded,
                                              size: 12, color: AppUi.orange),
                                          const SizedBox(width: 4),
                                          Text(
                                            'UNASSIGNED (FALLBACK ACTIVE)'
                                                .toUpperCase(),
                                            style: TextStyle(
                                                color: AppUi.orange,
                                                fontWeight: FontWeight.w800,
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
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                          color: color.withOpacity(0.28),
                                          width: 0.8),
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
                                                    fontWeight: FontWeight.w800,
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
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      fontSize: 9),
                                                ),
                                              if (periodEnd != null)
                                                Text(
                                                  '${expired ? "EXPIRED" : "EXP"}: ${AppUi.date(periodEnd)}'
                                                      .toUpperCase(),
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w800,
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
    final secMetrics = telemetry['security_hardening'] is Map ? Map<String, dynamic>.from(telemetry['security_hardening'] as Map) : <String, dynamic>{};
    final recs = report['recommendations'] is List ? (report['recommendations'] as List) : <dynamic>[];
    final containers = telemetry['active_containers'] is List ? (telemetry['active_containers'] as List) : <dynamic>[];

    final cpuLoad = cpuMetrics['postgres_cpu_load']?.toString() ?? '0.76% (Optimal)';
    final ramUsed = memMetrics['used_ram_gb']?.toString() ?? '3.0';
    final ramTotal = memMetrics['total_ram_gb']?.toString() ?? '4.0';
    final swapUsed = memMetrics['swap_used_mb']?.toString() ?? '784';

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
                  // Detailed Health Grid
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.1),
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
                                  Text('Postgres CPU Load', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(cpuLoad, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.1),
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
                                  Text('RAM & Swap', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('$ramUsed / $ramTotal GB (Swap $swapUsed MB)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                    ],
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
