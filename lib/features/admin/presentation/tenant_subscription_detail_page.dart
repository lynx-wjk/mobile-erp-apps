import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/ui/app_ui.dart';

class TenantSubscriptionDetailPage extends StatefulWidget {
  final String tenantId;
  final String tenantName;
  final String tenantCode;
  final String? ownerName;
  final String? ownerEmail;

  const TenantSubscriptionDetailPage({
    super.key,
    required this.tenantId,
    required this.tenantName,
    required this.tenantCode,
    this.ownerName,
    this.ownerEmail,
  });

  @override
  State<TenantSubscriptionDetailPage> createState() =>
      _TenantSubscriptionDetailPageState();
}

class _TenantSubscriptionDetailPageState
    extends State<TenantSubscriptionDetailPage> {
  final SupabaseClient _client = Supabase.instance.client;
  bool _isLoading = true;

  // Data loaded from server
  Map<String, dynamic>? _currentSubscription;
  List<Map<String, dynamic>> _plansList = [];
  List<Map<String, dynamic>> _featureCatalog = [];
  List<Map<String, dynamic>> _overridesList = [];

  // Plan Assignment Form State
  String? _selectedPlanCode;
  String _selectedStatus = 'active';
  DateTime? _trialEndsAt;
  DateTime? _currentPeriodEnd;
  final TextEditingController _notesController = TextEditingController();

  // Override Form State
  String? _selectedOverrideFeatureKey;
  bool _overrideEnabled = true;
  final TextEditingController _overrideReasonController =
      TextEditingController();

  // Entitlement Preview State
  String? _selectedPreviewFeatureKey;
  bool _isPreviewLoading = false;
  Map<String, dynamic>? _previewResult;

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  @override
  void dispose() {
    _notesController.dispose();
    _overrideReasonController.dispose();
    super.dispose();
  }

  Future<void> _loadAllData() async {
    setState(() => _isLoading = true);
    try {
      // 1. Load active subscription plans
      final plansRes = await _client.rpc('list_subscription_plans_for_app');
      if (plansRes != null &&
          plansRes is Map &&
          (plansRes['ok'] as bool? ?? false)) {
        _plansList = (plansRes['plans'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }

      // 2. Load feature catalog
      final featuresRes = await _client
          .from('feature_catalog')
          .select('feature_key, feature_name')
          .eq('is_active', true)
          .order('sort_order');
      _featureCatalog = (featuresRes as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // 3. Load tenant's latest subscription
      final subRes = await _client
          .from('tenant_subscriptions')
          .select('*, subscription_plans(plan_name, plan_code)')
          .eq('tenant_id', widget.tenantId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      _currentSubscription =
          subRes != null ? Map<String, dynamic>.from(subRes as Map) : null;

      // 4. Load tenant's overrides
      final overridesRes = await _client
          .from('tenant_subscription_overrides')
          .select('*')
          .eq('tenant_id', widget.tenantId)
          .order('created_at', ascending: false);
      _overridesList = (overridesRes as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // Init plan assignment form with current values if available
      if (_plansList.isNotEmpty) {
        if (_currentSubscription != null) {
          final currentPlan = _currentSubscription!['subscription_plans'];
          _selectedPlanCode = currentPlan != null
              ? currentPlan['plan_code']?.toString()
              : _plansList.first['plan_code'];
          _selectedStatus = _currentSubscription!['status'] ?? 'active';
          _trialEndsAt = _currentSubscription!['trial_ends_at'] != null
              ? DateTime.parse(_currentSubscription!['trial_ends_at'])
              : null;
          _currentPeriodEnd =
              _currentSubscription!['current_period_end'] != null
                  ? DateTime.parse(_currentSubscription!['current_period_end'])
                  : null;
          _notesController.text =
              _currentSubscription!['notes']?.toString() ?? '';
        } else {
          _selectedPlanCode = _plansList.first['plan_code'];
          _selectedStatus = 'active';
          _trialEndsAt = null;
          _currentPeriodEnd = null;
          _notesController.clear();
        }
      }

      // Set default preview feature
      if (_featureCatalog.isNotEmpty && _selectedPreviewFeatureKey == null) {
        _selectedPreviewFeatureKey =
            _featureCatalog.first['feature_key']?.toString();
      }

      // Set default override feature
      if (_featureCatalog.isNotEmpty && _selectedOverrideFeatureKey == null) {
        _selectedOverrideFeatureKey =
            _featureCatalog.first['feature_key']?.toString();
      }

      if (_selectedPreviewFeatureKey != null) {
        await _loadPreview(_selectedPreviewFeatureKey!, showLoader: false);
      }
    } catch (e) {
      debugPrint('[LOAD_DETAIL_ERROR] $e');
      AppUi.showSnack('GAGAL MEMUAT DATA SUBSCRIPTION: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadPreview(String featureKey, {bool showLoader = true}) async {
    if (showLoader && mounted) {
      setState(() {
        _isPreviewLoading = true;
        _previewResult = null;
      });
    }
    try {
      final response = await _client.rpc(
        'tenant_has_feature',
        params: {
          'p_feature_key': featureKey,
          'p_tenant_id': widget.tenantId,
        },
      );
      if (mounted && response != null && response is Map) {
        setState(() {
          _previewResult = Map<String, dynamic>.from(response);
        });
      }
    } catch (e) {
      debugPrint('[PREVIEW_ERROR] $e');
    } finally {
      if (mounted && showLoader) setState(() => _isPreviewLoading = false);
    }
  }

  Future<void> _saveSubscription() async {
    if (_selectedPlanCode == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await _client.rpc(
        'platform_tenant_subscription_set',
        params: {
          'p_tenant_id': widget.tenantId,
          'p_plan_code': _selectedPlanCode,
          'p_status': _selectedStatus,
          'p_trial_ends_at': _trialEndsAt?.toUtc().toIso8601String(),
          'p_current_period_start': DateTime.now().toUtc().toIso8601String(),
          'p_current_period_end': _currentPeriodEnd?.toUtc().toIso8601String(),
          'p_notes': _notesController.text.trim().isEmpty
              ? null
              : _notesController.text.trim(),
        },
      );

      final ok = response != null &&
          response is Map &&
          (response['ok'] as bool? ?? false);
      if (ok) {
        AppUi.showSnack('Subscription berhasil diperbarui!');
        await _loadAllData();
      } else {
        throw Exception(
            response?['message'] ?? 'Gagal memperbarui subscription.');
      }
    } catch (e) {
      debugPrint('[SAVE_SUBSCRIPTION_ERROR] $e');
      AppUi.showSnack('GAGAL MENYIMPAN: ${e.toString()}');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveOverride() async {
    if (_selectedOverrideFeatureKey == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await _client.rpc(
        'platform_tenant_subscription_override_set',
        params: {
          'p_tenant_id': widget.tenantId,
          'p_feature_key': _selectedOverrideFeatureKey,
          'p_override_type': 'feature',
          'p_enabled': _overrideEnabled,
          'p_limit_value': null,
          'p_config': {},
          'p_reason': _overrideReasonController.text.trim().isEmpty
              ? null
              : _overrideReasonController.text.trim(),
          'p_ends_at': null, // unlimited override by default
        },
      );

      final ok = response != null &&
          response is Map &&
          (response['ok'] as bool? ?? false);
      if (ok) {
        AppUi.showSnack('Override fitur berhasil disimpan!');
        _overrideReasonController.clear();
        await _loadAllData();
      } else {
        throw Exception(response?['message'] ?? 'Gagal membuat override.');
      }
    } catch (e) {
      debugPrint('[SAVE_OVERRIDE_ERROR] $e');
      AppUi.showSnack('GAGAL MENYIMPAN OVERRIDE: ${e.toString()}');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickDate({required bool isTrial}) async {
    final initialDate = (isTrial ? _trialEndsAt : _currentPeriodEnd) ??
        DateTime.now().add(const Duration(days: 30));
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            dialogTheme: const DialogThemeData(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                  side: BorderSide(color: Colors.black, width: 3)),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        if (isTrial) {
          _trialEndsAt = picked;
        } else {
          _currentPeriodEnd = picked;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.secondary;

    return Scaffold(
      appBar: AppBar(
        title: Text('KELOLA SUBSCRIPTION: ${widget.tenantName.toUpperCase()}',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _loadAllData,
          ),
        ],
      ),
      body: AppGlobalBackdrop(
        child: _isLoading
            ? const Center(
                child: FuturisticLoader(
                    message: 'MEMUAT DATA DETAIL SUBSCRIPTION...'))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header Card
                    NiceCard(
                      borderColor: Colors.black,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  widget.tenantName.toUpperCase(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 18),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  border: Border.all(
                                      color: Colors.white, width: 1.5),
                                ),
                                child: Text(
                                  widget.tenantCode.toUpperCase(),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 9),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (widget.ownerName != null ||
                              widget.ownerEmail != null) ...[
                            Text(
                              'OWNER: ${widget.ownerName ?? "-"} (${widget.ownerEmail ?? "-"})'
                                  .toUpperCase(),
                              style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 11,
                                  color: Colors.grey[700]),
                            ),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            'TENANT ID: ${widget.tenantId}'.toUpperCase(),
                            style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 10,
                                color: Colors.grey[500]),
                          ),
                          const SizedBox(height: 12),
                          Divider(height: 1, thickness: 2, color: accent),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('STATUS PAKET AKTIF:',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 11)),
                              if (_currentSubscription == null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppUi.orange.withOpacity(0.15),
                                    border: Border.all(
                                        color: AppUi.orange, width: 1.5),
                                  ),
                                  child: const Text(
                                    'UNASSIGNED (FALLBACK)',
                                    style: TextStyle(
                                        color: AppUi.orange,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 9),
                                  ),
                                )
                              else
                                Row(
                                  children: [
                                    Text(
                                      (_currentSubscription![
                                                          'subscription_plans']
                                                      ?['plan_name']
                                                  ?.toString() ??
                                              'Unknown Plan')
                                          .toUpperCase(),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 12),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: AppUi.statusColor(
                                                _currentSubscription![
                                                        'status'] ??
                                                    'active')
                                            .withOpacity(0.15),
                                        border: Border.all(
                                            color: AppUi.statusColor(
                                                _currentSubscription![
                                                        'status'] ??
                                                    'active'),
                                            width: 1.5),
                                      ),
                                      child: Text(
                                        (_currentSubscription!['status']
                                                    ?.toString() ??
                                                'active')
                                            .toUpperCase(),
                                        style: TextStyle(
                                            color: AppUi.statusColor(
                                                _currentSubscription![
                                                        'status'] ??
                                                    'active'),
                                            fontWeight: FontWeight.w900,
                                            fontSize: 9),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                          if (_currentSubscription != null) ...[
                            const SizedBox(height: 8),
                            if (_currentSubscription!['trial_ends_at'] != null)
                              Text(
                                'BATAS TRIAL: ${AppUi.date(_currentSubscription!['trial_ends_at'])}'
                                    .toUpperCase(),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 10),
                              ),
                            if (_currentSubscription!['current_period_end'] !=
                                null)
                              Text(
                                'AKHIR PERIODE: ${AppUi.date(_currentSubscription!['current_period_end'])}'
                                    .toUpperCase(),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 10),
                              ),
                            if (_currentSubscription!['notes'] != null &&
                                _currentSubscription!['notes']
                                        ?.toString()
                                        .isNotEmpty ==
                                    true) ...[
                              const SizedBox(height: 4),
                              Text(
                                'CATATAN: ${_currentSubscription!['notes']}'
                                    .toUpperCase(),
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                    color: Colors.grey[700]),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Entitlement Preview UI
                    const SectionTitle(
                        title: 'PREVIEW HAK AKSES (ENTITLEMENT)'),
                    const SizedBox(height: 8),
                    NiceCard(
                      borderColor: Colors.black,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('PILIH FITUR UNTUK DIPREVIEW',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 11)),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _selectedPreviewFeatureKey,
                            isExpanded: true,
                            items: _featureCatalog.map((f) {
                              final fKey = f['feature_key']?.toString() ?? '-';
                              final fName =
                                  f['feature_name']?.toString() ?? '-';
                              return DropdownMenuItem<String>(
                                value: fKey,
                                child: Text('$fName ($fKey)'.toUpperCase(),
                                    style: const TextStyle(fontSize: 12)),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(
                                    () => _selectedPreviewFeatureKey = val);
                                _loadPreview(val);
                              }
                            },
                          ),
                          const SizedBox(height: 16),
                          if (_isPreviewLoading)
                            const Center(child: CircularProgressIndicator())
                          else if (_previewResult != null)
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: (_previewResult!['enabled'] as bool? ??
                                        false)
                                    ? AppUi.green.withOpacity(0.08)
                                    : AppUi.red.withOpacity(0.08),
                                border: Border.all(
                                  color: (_previewResult!['enabled'] as bool? ??
                                          false)
                                      ? AppUi.green
                                      : AppUi.red,
                                  width: 2,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('ENABLED:',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 12)),
                                      Text(
                                        (_previewResult!['enabled'] as bool? ??
                                                false)
                                            ? 'YES'
                                            : 'NO',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 14,
                                          color: (_previewResult!['enabled']
                                                      as bool? ??
                                                  false)
                                              ? AppUi.green
                                              : AppUi.red,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  _previewRow(
                                      'SOURCE', _previewResult!['source']),
                                  _previewRow('PLAN CODE',
                                      _previewResult!['plan_code']),
                                  _previewRow(
                                      'REASON', _previewResult!['reason']),
                                ],
                              ),
                            )
                          else
                            const Text('PILIH FITUR UNTUK MELIHAT STATUS',
                                style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Plan Assignment Form
                    const SectionTitle(
                        title: 'ATUR / PERBARUI PAKET SUBSCRIPTION'),
                    const SizedBox(height: 8),
                    NiceCard(
                      borderColor: Colors.black,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('PILIH PAKET',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 11)),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _selectedPlanCode,
                            isExpanded: true,
                            items: _plansList.map((p) {
                              final pCode = p['plan_code']?.toString() ?? '-';
                              final pName = p['plan_name']?.toString() ?? '-';
                              return DropdownMenuItem<String>(
                                value: pCode,
                                child: Text('$pName ($pCode)'.toUpperCase(),
                                    style: const TextStyle(fontSize: 12)),
                              );
                            }).toList(),
                            onChanged: (val) =>
                                setState(() => _selectedPlanCode = val),
                          ),
                          const SizedBox(height: 14),
                          const Text('STATUS SUBSCRIPTION',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 11)),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _selectedStatus,
                            items: const [
                              DropdownMenuItem(
                                  value: 'trialing', child: Text('TRIALING')),
                              DropdownMenuItem(
                                  value: 'active', child: Text('ACTIVE')),
                              DropdownMenuItem(
                                  value: 'past_due', child: Text('PAST DUE')),
                              DropdownMenuItem(
                                  value: 'suspended', child: Text('SUSPENDED')),
                              DropdownMenuItem(
                                  value: 'canceled', child: Text('CANCELED')),
                              DropdownMenuItem(
                                  value: 'expired', child: Text('EXPIRED')),
                            ],
                            onChanged: (val) => setState(
                                () => _selectedStatus = val ?? 'active'),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const Text('AKHIR TRIAL',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 10)),
                                    const SizedBox(height: 6),
                                    OutlinedButton(
                                      onPressed: () => _pickDate(isTrial: true),
                                      child: Text(
                                        _trialEndsAt == null
                                            ? 'PILIH TANGGAL'
                                            : AppUi.date(_trialEndsAt),
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 11),
                                      ),
                                    ),
                                    if (_trialEndsAt != null)
                                      TextButton(
                                        onPressed: () =>
                                            setState(() => _trialEndsAt = null),
                                        child: const Text('HAPUS',
                                            style: TextStyle(
                                                color: AppUi.red,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w900)),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const Text('AKHIR PERIODE',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 10)),
                                    const SizedBox(height: 6),
                                    OutlinedButton(
                                      onPressed: () =>
                                          _pickDate(isTrial: false),
                                      child: Text(
                                        _currentPeriodEnd == null
                                            ? 'PILIH TANGGAL'
                                            : AppUi.date(_currentPeriodEnd),
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 11),
                                      ),
                                    ),
                                    if (_currentPeriodEnd != null)
                                      TextButton(
                                        onPressed: () => setState(
                                            () => _currentPeriodEnd = null),
                                        child: const Text('HAPUS',
                                            style: TextStyle(
                                                color: AppUi.red,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w900)),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          const Text('CATATAN / NOTES',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 11)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _notesController,
                            decoration: const InputDecoration(
                              hintText:
                                  'Contoh: Pembayaran manual via bank transfer',
                            ),
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _saveSubscription,
                            child: const Text('SIMPAN SUBSCRIPTION'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Feature Override UI
                    const SectionTitle(
                        title: 'TAMBAH OVERRIDE FITUR SECARA MANUAL'),
                    const SizedBox(height: 8),
                    NiceCard(
                      borderColor: Colors.black,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('PILIH FITUR UNTUK DI-OVERRIDE',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 11)),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _selectedOverrideFeatureKey,
                            isExpanded: true,
                            items: _featureCatalog.map((f) {
                              final fKey = f['feature_key']?.toString() ?? '-';
                              final fName =
                                  f['feature_name']?.toString() ?? '-';
                              return DropdownMenuItem<String>(
                                value: fKey,
                                child: Text('$fName ($fKey)'.toUpperCase(),
                                    style: const TextStyle(fontSize: 12)),
                              );
                            }).toList(),
                            onChanged: (val) => setState(
                                () => _selectedOverrideFeatureKey = val),
                          ),
                          const SizedBox(height: 14),
                          const Text('TIPE OVERRIDE: FEATURE',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                  color: Colors.grey)),
                          const SizedBox(height: 14),
                          const Text('STATUS FITUR',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 11)),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<bool>(
                            value: _overrideEnabled,
                            items: const [
                              DropdownMenuItem(
                                  value: true, child: Text('AKTIFKAN (TRUE)')),
                              DropdownMenuItem(
                                  value: false, child: Text('MATIKAN (FALSE)')),
                            ],
                            onChanged: (val) =>
                                setState(() => _overrideEnabled = val ?? true),
                          ),
                          const SizedBox(height: 14),
                          const Text('ALASAN / REASON',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 11)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _overrideReasonController,
                            decoration: const InputDecoration(
                              hintText: 'Contoh: Free trial khusus modul baru',
                            ),
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _saveOverride,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppUi.purple,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('SIMPAN OVERRIDE'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Overrides List
                    const SectionTitle(title: 'DAFTAR OVERRIDE AKTIF'),
                    const SizedBox(height: 8),
                    if (_overridesList.isEmpty)
                      const EmptyState(
                        title: 'BELUM ADA OVERRIDE',
                        subtitle: 'Tidak ada override manual untuk tenant ini.',
                        icon: Icons.vpn_key_off,
                      )
                    else
                      ..._overridesList.map((ovr) {
                        final fKey = ovr['feature_key']?.toString() ?? '-';
                        final enabled = ovr['enabled'] as bool? ?? false;
                        final reason = ovr['reason']?.toString() ?? '';
                        final startsAt = ovr['starts_at']?.toString() ?? '';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 2),
                            color: theme.scaffoldBackgroundColor,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    fKey.toUpperCase(),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 12),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    color: enabled ? AppUi.green : AppUi.red,
                                    child: Text(
                                      enabled ? 'ENABLED' : 'DISABLED',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 8),
                                    ),
                                  ),
                                ],
                              ),
                              if (reason.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text('ALASAN: $reason'.toUpperCase(),
                                    style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.grey[700])),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                  'DIBUAT: ${AppUi.dateTime(startsAt)}'
                                      .toUpperCase(),
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.grey[500])),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _previewRow(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: '.toUpperCase(),
              style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 10,
                  color: Colors.grey[600])),
          Expanded(
            child: Text(
              (value?.toString() ?? '-').toUpperCase(),
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
