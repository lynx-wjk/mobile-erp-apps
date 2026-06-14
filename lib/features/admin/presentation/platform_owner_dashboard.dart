import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/constants/app_roles.dart';
import '../../../services/auth_service.dart';
import '../../auth/presentation/login_page.dart';

class PlatformOwnerDashboard extends StatefulWidget {
  const PlatformOwnerDashboard({super.key});

  @override
  State<PlatformOwnerDashboard> createState() => _PlatformOwnerDashboardState();
}

class _PlatformOwnerDashboardState extends State<PlatformOwnerDashboard> {
  final SupabaseClient _client = Supabase.instance.client;
  bool _isLoading = true;
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
        _readinessData = response.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else {
        _readinessData = [];
      }

      // Fetch distinct tenants list for invite generator & tenant creation checks
      final tenantsRes = await _client
          .from('app_tenants')
          .select('tenant_id, tenant_name, status')
          .order('tenant_name');
      if (tenantsRes is List) {
        _tenantsList = tenantsRes.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else {
        _tenantsList = [];
      }
    } catch (e) {
      AppUi.showSnack('GAGAL MEMUAT DATA: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
          title: Text('TAMBAH TENANT BARU'.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w900)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('NAMA TENANT / CLIENT', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
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
              child: const Text('BATAL', style: TextStyle(fontWeight: FontWeight.w900)),
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
                  await _client.from('app_tenants').insert({
                    'tenant_name': name,
                    'status': 'active',
                  });
                  AppUi.showSnack('TENANT BERHASIL DIBUAT.');
                  _loadData();
                } catch (e) {
                  AppUi.showSnack('GAGAL MEMBUAT TENANT: $e');
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
    String? selectedTenantId = preselectedTenantId ?? (_tenantsList.isNotEmpty ? _tenantsList.first['tenant_id']?.toString() : null);
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
              title: Text('GENERATE UNDANGAN'.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w900)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('TENANT TARGET', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: selectedTenantId,
                      items: _tenantsList.map((t) {
                        return DropdownMenuItem<String>(
                          value: t['tenant_id']?.toString(),
                          child: Text(t['tenant_name']?.toString() ?? '-'),
                        );
                      }).toList(),
                      onChanged: generating ? null : (val) => setDialogState(() => selectedTenantId = val),
                    ),
                    const SizedBox(height: 14),

                    const Text('PERAN / ROLE', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<AppRole>(
                      value: selectedRole,
                      items: availableRoles.map((r) {
                        return DropdownMenuItem<AppRole>(
                          value: r,
                          child: Text(r.label),
                        );
                      }).toList(),
                      onChanged: generating ? null : (val) => setDialogState(() => selectedRole = val ?? AppRole.superAdmin),
                    ),
                    const SizedBox(height: 14),

                    const Text('EMAIL PENERIMA (OPSIONAL)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
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

                    const Text('MASA BERLAKU (HARI)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
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
                  child: const Text('BATAL', style: TextStyle(fontWeight: FontWeight.w900)),
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

                            final token = await _client.rpc('create_invite', params: {
                              'p_tenant_id': selectedTenantId,
                              'p_role_id': selectedRole.roleId,
                              'p_email': email.isEmpty ? null : email,
                              'p_expires_in_days': days,
                            }) as String?;

                            if (token != null) {
                              Navigator.pop(context);
                              _showTokenSuccessDialog(token, selectedRole);
                            } else {
                              throw Exception('Gagal mendapatkan token.');
                            }
                          } catch (e) {
                            AppUi.showSnack('GAGAL: $e');
                            setDialogState(() => generating = false);
                          }
                        },
                  child: generating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
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
    final baseUri = Uri.base;
    final String registerUrl;
    if (baseUri.host.isNotEmpty && baseUri.host != 'localhost' && !baseUri.host.startsWith('127.0.0.1')) {
      registerUrl = '${baseUri.scheme}://${baseUri.host}${baseUri.port != 80 && baseUri.port != 443 ? ":${baseUri.port}" : ""}/#/register?invite=$token';
    } else {
      registerUrl = 'http://localhost/register?invite=$token';
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: Colors.black, width: 3),
          ),
          title: Text('UNDANGAN DIHASILKAN'.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w900, color: AppUi.green)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('KODE TOKEN RAW:', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey[600], fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                token,
                style: const TextStyle(fontWeight: FontWeight.w900, fontFamily: 'monospace', fontSize: 13),
              ),
              const SizedBox(height: 16),
              Text('LINK REGISTRASI WEB:', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey[600], fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                registerUrl,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, decoration: TextDecoration.underline),
              ),
            ],
          ),
          actions: [
            FilledButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: registerUrl));
                AppUi.showSnack('LINK REGISTRASI DISALIN KE CLIPBOARD.');
              },
              icon: const Icon(Icons.copy),
              label: const Text('COPY LINK'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('SELESAI', style: TextStyle(fontWeight: FontWeight.w900)),
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
        style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 10),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark ? Colors.white : Colors.black;

    final grouped = _groupedTenants;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PLATFORM OWNER DASHBOARD', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
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
            ? const Center(child: FuturisticLoader(message: 'MEMUAT DATA TENANT...'))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Welcome Header
                    FuturisticHeader(
                      icon: Icons.admin_panel_settings_rounded,
                      title: 'PLATFORM MANAGEMENT',
                      subtitle: 'Pantau kesiapan integrasi dan kelola client multi-tenant secara terpusat.',
                      stats: [
                        StatPill(label: 'Total Tenants', value: _tenantsList.length.toString(), accentColor: AppUi.blue),
                        StatPill(label: 'Integrations', value: _readinessData.where((e) => e['marketplace_account_id'] != null).length.toString(), accentColor: AppUi.teal),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Quick Actions
                    Row(
                      children: [
                        Expanded(
                          child: NiceCard(
                            onTap: _showCreateTenantDialog,
                            borderColor: Colors.black,
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_business_rounded),
                                SizedBox(width: 8),
                                Text('TAMBAH TENANT', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: NiceCard(
                            onTap: () => _showGenerateInviteDialog(),
                            borderColor: Colors.black,
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.mail_outline_rounded),
                                SizedBox(width: 8),
                                Text('KIRIM UNDANGAN', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Tenants List Header
                    SectionTitle(
                      title: 'DAFTAR CLIENT & STATUS KESIAPAN',
                      actionText: 'RELOAD',
                      onAction: _loadData,
                    ),

                    if (grouped.isEmpty)
                      const EmptyState(
                        title: 'BELUM ADA TENANT',
                        subtitle: 'Tekan "TAMBAH TENANT" untuk mendaftarkan client pertama Anda.',
                        icon: Icons.business,
                      )
                    else
                      ...grouped.entries.map((entry) {
                        final tenantId = entry.key;
                        final rows = entry.value;
                        final tenantName = rows.first['tenant_name']?.toString() ?? 'Unknown Tenant';
                        final tenantStatus = rows.first['tenant_status']?.toString() ?? 'active';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 20),
                          child: NiceCard(
                            borderColor: Colors.black,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Tenant Info Row
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Row(
                                        children: [
                                          const Icon(Icons.business_center, size: 20),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              tenantName.toUpperCase(),
                                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: AppUi.statusColor(tenantStatus).withOpacity(0.15),
                                            border: Border.all(color: AppUi.statusColor(tenantStatus), width: 1.5),
                                          ),
                                          child: Text(
                                            tenantStatus.toUpperCase(),
                                            style: TextStyle(color: AppUi.statusColor(tenantStatus), fontWeight: FontWeight.w900, fontSize: 9),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: 'Undang user ke tenant ini',
                                          icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                                          onPressed: () => _showGenerateInviteDialog(preselectedTenantId: tenantId),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Divider(height: 1, thickness: 2, color: accent),
                                const SizedBox(height: 12),

                                // Accounts list
                                ...rows.map((row) {
                                  final marketplace = row['marketplace']?.toString();
                                  final storeAlias = row['store_alias']?.toString() ?? '-';
                                  final readinessStatus = row['readiness_status']?.toString() ?? 'no_account';

                                  if (marketplace == null) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            'Belum ada akun toko terhubung.'.toUpperCase(),
                                            style: TextStyle(color: Colors.grey[600], fontSize: 11, fontWeight: FontWeight.w800),
                                          ),
                                          _readinessBadge('no_account'),
                                        ],
                                      ),
                                    );
                                  }

                                  // Account connected metrics
                                  final productsCount = AppUi.toNum(row['product_snapshot_count']).toInt();
                                  final variantsCount = AppUi.toNum(row['variant_snapshot_count']).toInt();
                                  final orderCount = AppUi.toNum(row['order_count']).toInt();
                                  final financeCount = AppUi.toNum(row['finance_count']).toInt();
                                  final skuMapped = AppUi.toNum(row['sku_mapped_count']).toInt();
                                  final hppMapped = AppUi.toNum(row['hpp_mapped_count']).toInt();
                                  final unmappedItems = AppUi.toNum(row['unmapped_order_item_count']).toInt();

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: accent, width: 2),
                                      color: theme.scaffoldBackgroundColor,
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                Icon(
                                                  marketplace.toLowerCase() == 'shopee'
                                                      ? Icons.shopping_bag_outlined
                                                      : Icons.storefront_outlined,
                                                  size: 18,
                                                  color: theme.colorScheme.primary,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  '${marketplace.toUpperCase()}: $storeAlias',
                                                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
                                                ),
                                              ],
                                            ),
                                            _readinessBadge(readinessStatus),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        // Metrics grid
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            _smallStat('Products', productsCount.toString()),
                                            _smallStat('Variants', variantsCount.toString()),
                                            _smallStat('Orders', orderCount.toString()),
                                            _smallStat('Finance Recs', financeCount.toString()),
                                            _smallStat('SKU Mapped', '$skuMapped/$variantsCount', alert: variantsCount > 0 && skuMapped < variantsCount),
                                            _smallStat('HPP Mapped', '$hppMapped/$variantsCount', alert: variantsCount > 0 && hppMapped < variantsCount),
                                            _smallStat('Unmapped Items', unmappedItems.toString(), alert: unmappedItems > 0),
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
        color: alert ? AppUi.red.withOpacity(0.1) : Colors.grey.withOpacity(0.05),
        border: Border.all(color: alert ? AppUi.red : Colors.grey[400]!, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: '.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 8.5, color: alert ? AppUi.red : Colors.grey[700]),
          ),
          Text(
            value,
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 9.5, color: alert ? AppUi.red : null),
          ),
        ],
      ),
    );
  }
}
