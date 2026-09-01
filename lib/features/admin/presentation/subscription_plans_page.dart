import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';

class SubscriptionPlansPage extends StatefulWidget {
  const SubscriptionPlansPage({super.key});

  @override
  State<SubscriptionPlansPage> createState() => _SubscriptionPlansPageState();
}

class _SubscriptionPlansPageState extends State<SubscriptionPlansPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  bool _isSaving = false;
  List<Map<String, dynamic>> _plansList = [];
  List<Map<String, dynamic>> _featuresList = [];

  @override
  void initState() {
    super.initState();
    _loadPlans();
  }

  Future<void> _loadPlans({bool showLoader = true}) async {
    if (showLoader && mounted) {
      setState(() => _isLoading = true);
    }

    try {
      final response =
          await _client.rpc('platform_subscription_plan_editor_snapshot');
      final ok = response != null &&
          response is Map &&
          (response['ok'] as bool? ?? false);

      if (ok) {
        if (!mounted) return;
        setState(() {
          _plansList = (response['plans'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          _featuresList = (response['features'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        });
      } else {
        throw Exception(
          response is Map
              ? (response['message'] ?? response['error'] ?? response)
              : 'Gagal memuat paket subscription.',
        );
      }
    } catch (e, st) {
      debugPrint('[LOAD_PLAN_EDITOR_ERROR] $e\n$st');
      AppUi.showSnack('GAGAL MEMUAT EDITOR PAKET: ${e.toString()}');
    } finally {
      if (mounted && showLoader) setState(() => _isLoading = false);
    }
  }

  String _text(dynamic value) => value == null ? '' : value.toString();

  String? _nullableText(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _nullableInt(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed.replaceAll('.', '').replaceAll(',', ''));
  }

  String _priceText(dynamic value) {
    final price = AppUi.toNum(value);
    if (price == 0) return '0';
    if (price % 1 == 0) return price.toInt().toString();
    return price.toString();
  }

  List<Map<String, dynamic>> _planFeatures(Map<String, dynamic> plan) {
    final raw = plan['features'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  String _featureLabel(Map<String, dynamic> feature) {
    final publicLabel = feature['public_label']?.toString();
    if (publicLabel != null && publicLabel.trim().isNotEmpty) {
      return publicLabel;
    }
    return feature['feature_name']?.toString() ??
        feature['feature_key']?.toString() ??
        '-';
  }

  Future<bool> _savePlan({
    required String planCode,
    required String planName,
    required String? description,
    required String billingPeriod,
    required num priceAmount,
    required String currency,
    required int? maxUsers,
    required int? maxMarketplaceAccounts,
    required int? maxShopeeAccounts,
    required int? maxTiktokAccounts,
    required int? maxStorageMb,
    required int maxOrderRetentionDays,
    required bool isTrial,
    required bool isActive,
    required int sortOrder,
  }) async {
    if (planCode.trim().isEmpty || planName.trim().isEmpty) {
      AppUi.showSnack('KODE PAKET DAN NAMA PAKET WAJIB DIISI.');
      return false;
    }

    if (priceAmount < 0) {
      AppUi.showSnack('HARGA TIDAK BOLEH MINUS.');
      return false;
    }

    if (maxOrderRetentionDays < 1 || maxOrderRetentionDays > 90) {
      AppUi.showSnack('RETENSI ORDER HARUS 1 SAMPAI 90 HARI.');
      return false;
    }

    setState(() => _isSaving = true);
    try {
      final response = await _client.rpc(
        'platform_subscription_plan_upsert',
        params: {
          'p_plan_code': planCode.trim().toLowerCase(),
          'p_plan_name': planName.trim(),
          'p_description': description,
          'p_billing_period':
              billingPeriod.trim().isEmpty ? 'monthly' : billingPeriod.trim(),
          'p_price_amount': priceAmount,
          'p_currency':
              currency.trim().isEmpty ? 'IDR' : currency.trim().toUpperCase(),
          'p_max_users': maxUsers,
          'p_max_marketplace_accounts': maxMarketplaceAccounts,
          'p_max_shopee_accounts': maxShopeeAccounts,
          'p_max_tiktok_accounts': maxTiktokAccounts,
          'p_max_storage_mb': maxStorageMb,
          'p_max_order_retention_days': maxOrderRetentionDays,
          'p_is_trial': isTrial,
          'p_is_active': isActive,
          'p_sort_order': sortOrder,
        },
      );

      final ok = response != null &&
          response is Map &&
          (response['ok'] as bool? ?? false);

      if (!ok) {
        throw Exception(
          response is Map
              ? (response['message'] ?? response['error'] ?? response)
              : 'Gagal menyimpan paket.',
        );
      }

      AppUi.showSnack('PAKET SUBSCRIPTION BERHASIL DISIMPAN.');
      await _loadPlans(showLoader: false);
      return true;
    } catch (e, st) {
      debugPrint('[SAVE_PLAN_ERROR] $e\n$st');
      AppUi.showSnack('GAGAL MENYIMPAN PAKET: ${e.toString()}');
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<bool> _setPlanFeature({
    required String planCode,
    required String featureKey,
    required bool enabled,
    required int? limitValue,
  }) async {
    try {
      final response = await _client.rpc(
        'platform_subscription_plan_feature_set',
        params: {
          'p_plan_code': planCode.trim().toLowerCase(),
          'p_feature_key': featureKey,
          'p_enabled': enabled,
          'p_limit_value': limitValue,
          'p_config': <String, dynamic>{},
        },
      );

      final ok = response != null &&
          response is Map &&
          (response['ok'] as bool? ?? false);

      if (!ok) {
        throw Exception(
          response is Map
              ? (response['message'] ?? response['error'] ?? response)
              : 'Gagal menyimpan fitur paket.',
        );
      }

      await _loadPlans(showLoader: false);
      return true;
    } catch (e, st) {
      debugPrint('[SAVE_PLAN_FEATURE_ERROR] $e\n$st');
      AppUi.showSnack('GAGAL MENYIMPAN FITUR: ${e.toString()}');
      return false;
    }
  }

  Future<void> _setPlanActive(Map<String, dynamic> plan, bool isActive) async {
    final planCode = plan['plan_code']?.toString() ?? '';
    if (planCode.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final response = await _client.rpc(
        'platform_subscription_plan_set_active',
        params: {
          'p_plan_code': planCode,
          'p_is_active': isActive,
        },
      );

      final ok = response != null &&
          response is Map &&
          (response['ok'] as bool? ?? false);

      if (!ok) {
        throw Exception(
          response is Map
              ? (response['message'] ?? response['error'] ?? response)
              : 'Gagal mengubah status paket.',
        );
      }

      AppUi.showSnack(isActive ? 'PAKET DIAKTIFKAN.' : 'PAKET DINONAKTIFKAN.');
      await _loadPlans(showLoader: false);
    } catch (e, st) {
      debugPrint('[SET_PLAN_ACTIVE_ERROR] $e\n$st');
      AppUi.showSnack('GAGAL MENGUBAH STATUS PAKET: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _showPlanEditor({Map<String, dynamic>? plan}) async {
    final isEditing = plan != null;

    final codeController =
        TextEditingController(text: plan?['plan_code']?.toString() ?? '');
    final nameController =
        TextEditingController(text: plan?['plan_name']?.toString() ?? '');
    final descriptionController =
        TextEditingController(text: plan?['description']?.toString() ?? '');
    final priceController =
        TextEditingController(text: _priceText(plan?['price_amount']));
    final currencyController =
        TextEditingController(text: plan?['currency']?.toString() ?? 'IDR');
    final maxUsersController =
        TextEditingController(text: _text(plan?['max_users']));
    final maxMarketplaceController =
        TextEditingController(text: _text(plan?['max_marketplace_accounts']));
    final maxShopeeController =
        TextEditingController(text: _text(plan?['max_shopee_accounts']));
    final maxTiktokController =
        TextEditingController(text: _text(plan?['max_tiktok_accounts']));
    final maxStorageController =
        TextEditingController(text: _text(plan?['max_storage_mb']));
    final retentionController = TextEditingController(
        text: _text(plan?['max_order_retention_days'] ?? 90));
    final sortOrderController =
        TextEditingController(text: _text(plan?['sort_order'] ?? 0));

    var billingPeriod = plan?['billing_period']?.toString() ?? 'monthly';
    var isTrial = plan?['is_trial'] as bool? ?? false;
    var isActive = plan?['is_active'] as bool? ?? true;
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(
                isEditing ? 'EDIT PAKET SUBSCRIPTION' : 'TAMBAH PAKET BARU',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
              contentPadding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              actionsPadding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              actionsAlignment: MainAxisAlignment.end,
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 460,
                  maxHeight: MediaQuery.of(context).size.height * 0.74,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _fieldLabel('KODE PAKET (ID UNIK)'),
                      TextField(
                        controller: codeController,
                        onTap: AppUi.selectOnTap(codeController),
                        enabled: !isEditing && !saving,
                        decoration: const InputDecoration(
                          hintText: 'contoh: starter',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _fieldLabel('NAMA PAKET'),
                      TextField(
                        controller: nameController,
                        onTap: AppUi.selectOnTap(nameController),
                        enabled: !saving,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _fieldLabel('DESKRIPSI'),
                      TextField(
                        controller: descriptionController,
                        onTap: AppUi.selectOnTap(descriptionController),
                        enabled: !saving,
                        minLines: 2,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: 220,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _fieldLabel('HARGA'),
                                TextField(
                                  controller: priceController,
                                  onTap: AppUi.selectOnTap(priceController),
                                  enabled: !saving,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: const [
                                    _SubscriptionThousandsInputFormatter(),
                                  ],
                                  decoration: const InputDecoration(
                                    prefixText: 'Rp ',
                                    helperText: 'Contoh: 150000',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 112,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _fieldLabel('MATA UANG'),
                                TextField(
                                  controller: currencyController,
                                  onTap: AppUi.selectOnTap(currencyController),
                                  enabled: !saving,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 158,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _fieldLabel('PERIODE'),
                                DropdownButtonFormField<String>(
                                  value: billingPeriod,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'monthly',
                                      child: Text('MONTHLY'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'quarterly',
                                      child: Text('QUARTERLY'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'yearly',
                                      child: Text('YEARLY'),
                                    ),
                                  ],
                                  onChanged: saving
                                      ? null
                                      : (value) => setDialogState(
                                            () => billingPeriod =
                                                value ?? 'monthly',
                                          ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _fieldLabel('BATASAN KUOTA'),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          _smallNumberField('Max Users', maxUsersController),
                          _smallNumberField(
                              'Marketplace', maxMarketplaceController),
                          _smallNumberField('Shopee', maxShopeeController),
                          _smallNumberField('TikTok', maxTiktokController),
                          _smallNumberField('Storage MB', maxStorageController),
                          _smallNumberField(
                              'Retensi Hari', retentionController),
                          _smallNumberField('Sort Order', sortOrderController),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SwitchListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: EdgeInsets.zero,
                        value: isTrial,
                        title: Text(
                          'TRIAL PLAN',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        onChanged: saving
                            ? null
                            : (value) => setDialogState(() => isTrial = value),
                      ),
                      SwitchListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: EdgeInsets.zero,
                        value: isActive,
                        title: Text(
                          'AKTIF DI DAFTAR PAKET',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          'Nonaktif berarti paket disembunyikan dari pilihan aktif, bukan dihapus.',
                        ),
                        onChanged: saving
                            ? null
                            : (value) => setDialogState(() => isActive = value),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: Text(
                    'BATAL',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          setDialogState(() => saving = true);
                          final ok = await _savePlan(
                            planCode: codeController.text,
                            planName: nameController.text,
                            description:
                                _nullableText(descriptionController.text),
                            billingPeriod: billingPeriod,
                            priceAmount:
                                _subscriptionMoneyValue(priceController.text),
                            currency: currencyController.text,
                            maxUsers: _nullableInt(maxUsersController.text),
                            maxMarketplaceAccounts:
                                _nullableInt(maxMarketplaceController.text),
                            maxShopeeAccounts:
                                _nullableInt(maxShopeeController.text),
                            maxTiktokAccounts:
                                _nullableInt(maxTiktokController.text),
                            maxStorageMb:
                                _nullableInt(maxStorageController.text),
                            maxOrderRetentionDays:
                                _nullableInt(retentionController.text) ?? 90,
                            isTrial: isTrial,
                            isActive: isActive,
                            sortOrder:
                                _nullableInt(sortOrderController.text) ?? 0,
                          );
                          if (context.mounted && ok) {
                            Navigator.pop(context);
                          } else {
                            setDialogState(() => saving = false);
                          }
                        },
                  child: saving
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        )
                      : Text('SIMPAN'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showFeatureEditor(Map<String, dynamic> plan) async {
    final planCode = plan['plan_code']?.toString() ?? '';
    final planName = plan['plan_name']?.toString() ?? '-';
    final featureRows = _planFeatures(plan)
        .map((feature) => Map<String, dynamic>.from(feature))
        .toList();

    String? savingFeatureKey;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(
                'FITUR PAKET: ${planName.toUpperCase()}',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              content: SizedBox(
                width: 780,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.72,
                  ),
                  child: featureRows.isEmpty
                      ? const EmptyState(
                          title: 'BELUM ADA FITUR',
                          subtitle: 'Feature catalog masih kosong.',
                          icon: Icons.extension_rounded,
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: featureRows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final feature = featureRows[index];
                            final featureKey =
                                feature['feature_key']?.toString() ?? '-';
                            final enabled =
                                feature['enabled'] as bool? ?? false;
                            final visible =
                                feature['is_client_visible'] as bool? ?? true;
                            final limitValue = feature['limit_value'];

                            return Container(
                              padding: const EdgeInsets.all(10),
                              decoration: AppUi.modernCardDecoration(context,
                                  radius: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _featureLabel(feature).toUpperCase(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          featureKey,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                            color:
                                                AppUi.mutedText(context, 0.90),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: [
                                            _miniBadge(
                                              visible ? 'PUBLIC' : 'INTERNAL',
                                              visible
                                                  ? AppUi.green
                                                  : AppUi.orange,
                                            ),
                                            _miniBadge(
                                              limitValue == null
                                                  ? 'NO LIMIT'
                                                  : 'LIMIT: $limitValue',
                                              Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Edit limit fitur',
                                    icon: Icon(Icons.tune_rounded),
                                    onPressed: savingFeatureKey != null
                                        ? null
                                        : () async {
                                            final newLimit =
                                                await _showLimitEditor(
                                              featureLabel:
                                                  _featureLabel(feature),
                                              currentLimit: limitValue is int
                                                  ? limitValue
                                                  : int.tryParse(
                                                      limitValue?.toString() ??
                                                          '',
                                                    ),
                                            );
                                            if (newLimit is _NoLimitCancel) {
                                              return;
                                            }

                                            await Future<void>.delayed(
                                              const Duration(milliseconds: 120),
                                            );
                                            if (!context.mounted) return;

                                            setDialogState(() {
                                              savingFeatureKey = featureKey;
                                            });

                                            final ok = await _setPlanFeature(
                                              planCode: planCode,
                                              featureKey: featureKey,
                                              enabled: enabled,
                                              limitValue: newLimit.limit,
                                            );

                                            if (ok) {
                                              setDialogState(() {
                                                feature['limit_value'] =
                                                    newLimit.limit;
                                                savingFeatureKey = null;
                                              });
                                            } else {
                                              setDialogState(() {
                                                savingFeatureKey = null;
                                              });
                                            }
                                          },
                                  ),
                                  Switch(
                                    value: enabled,
                                    onChanged: savingFeatureKey != null
                                        ? null
                                        : (value) async {
                                            setDialogState(() {
                                              savingFeatureKey = featureKey;
                                            });

                                            final ok = await _setPlanFeature(
                                              planCode: planCode,
                                              featureKey: featureKey,
                                              enabled: value,
                                              limitValue: limitValue is int
                                                  ? limitValue
                                                  : int.tryParse(
                                                      limitValue?.toString() ??
                                                          '',
                                                    ),
                                            );

                                            setDialogState(() {
                                              if (ok) {
                                                feature['enabled'] = value;
                                              }
                                              savingFeatureKey = null;
                                            });
                                          },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: savingFeatureKey != null
                      ? null
                      : () => Navigator.pop(context),
                  child: Text(
                    'SELESAI',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<_FeatureLimitResult> _showLimitEditor({
    required String featureLabel,
    required int? currentLimit,
  }) async {
    final controller =
        TextEditingController(text: currentLimit?.toString() ?? '');

    final result = await showDialog<_FeatureLimitResult>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            'LIMIT: ${featureLabel.toUpperCase()}',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Limit value',
              hintText: 'Kosongkan untuk unlimited',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _NoLimitCancel()),
              child: Text(
                'BATAL',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                const _FeatureLimitResult(null),
              ),
              child: Text(
                'HAPUS LIMIT',
                style: TextStyle(fontWeight: FontWeight.w800, color: AppUi.red),
              ),
            ),
            FilledButton(
              onPressed: () {
                final parsed = _nullableInt(controller.text);
                if (controller.text.trim().isNotEmpty &&
                    (parsed == null || parsed < 0)) {
                  AppUi.showSnack('LIMIT HARUS ANGKA POSITIF ATAU KOSONG.');
                  return;
                }
                Navigator.pop(context, _FeatureLimitResult(parsed));
              },
              child: Text('SIMPAN'),
            ),
          ],
        );
      },
    );
    return result ?? _NoLimitCancel();
  }

  Future<void> _confirmToggleActive(Map<String, dynamic> plan) async {
    final planName = plan['plan_name']?.toString() ?? '-';
    final isActive = plan['is_active'] as bool? ?? true;
    final nextActive = !isActive;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            nextActive ? 'AKTIFKAN PAKET?' : 'NONAKTIFKAN PAKET?',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          content: Text(
            nextActive
                ? 'Paket "$planName" akan muncul lagi di daftar paket aktif.'
                : 'Paket "$planName" akan disembunyikan dari daftar aktif. Data subscription tenant tidak dihapus.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                'BATAL',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(nextActive ? 'AKTIFKAN' : 'NONAKTIFKAN'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await _setPlanActive(plan, nextActive);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.secondary;
    final activeCount =
        _plansList.where((p) => p['is_active'] as bool? ?? true).length;
    final inactiveCount = _plansList.length - activeCount;

    return WebResponsiveScaffold(
      appBar: AppBar(
        title: Text(
          'EDITOR PAKET SUBSCRIPTION',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
        ),
        actions: [
          IconButton(
            tooltip: 'Reload data',
            icon: Icon(Icons.refresh),
            onPressed: _isSaving ? null : _loadPlans,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isSaving ? null : () => _showPlanEditor(),
        icon: Icon(Icons.add),
        label: Text(
          'TAMBAH PAKET',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: AppGlobalBackdrop(
        child: _isLoading
            ? const Center(
                child: FuturisticLoader(message: 'MEMUAT EDITOR PAKET...'),
              )
            : _plansList.isEmpty
                ? const EmptyState(
                    title: 'BELUM ADA PAKET',
                    subtitle: 'Tidak ada paket subscription yang ditemukan.',
                    icon: Icons.card_membership_rounded,
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FuturisticHeader(
                          icon: Icons.card_membership_rounded,
                          title: 'PLAN EDITOR',
                          subtitle:
                              'Kelola harga, batasan, status aktif, dan fitur per paket. Tidak ada penghapusan permanen.',
                          stats: [
                            StatPill(
                              label: 'Total Paket',
                              value: _plansList.length.toString(),
                              accentColor: AppUi.purple,
                            ),
                            StatPill(
                              label: 'Aktif',
                              value: activeCount.toString(),
                              accentColor: AppUi.green,
                            ),
                            StatPill(
                              label: 'Nonaktif',
                              value: inactiveCount.toString(),
                              accentColor: AppUi.orange,
                            ),
                            StatPill(
                              label: 'Fitur',
                              value: _featuresList.length.toString(),
                              accentColor: AppUi.blue,
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        ..._plansList.map((plan) {
                          return _planCard(plan, theme, accent);
                        }),
                        const SizedBox(height: 72),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _planCard(
    Map<String, dynamic> plan,
    ThemeData theme,
    Color accent,
  ) {
    final planName = plan['plan_name']?.toString() ?? 'Unnamed Plan';
    final planCode = plan['plan_code']?.toString() ?? '-';
    final description = plan['description']?.toString() ?? '';
    final price = AppUi.toNum(plan['price_amount']);
    final currency = plan['currency']?.toString() ?? 'IDR';
    final billingPeriod = plan['billing_period']?.toString() ?? 'monthly';

    final maxUsers = plan['max_users'];
    final maxMarketplace = plan['max_marketplace_accounts'];
    final maxShopee = plan['max_shopee_accounts'];
    final maxTiktok = plan['max_tiktok_accounts'];
    final maxStorage = plan['max_storage_mb'];
    final retentionDays = plan['max_order_retention_days'] ?? 90;
    final isTrial = plan['is_trial'] as bool? ?? false;
    final isActive = plan['is_active'] as bool? ?? true;
    final features = _planFeatures(plan);
    final enabledFeatureCount =
        features.where((f) => f['enabled'] as bool? ?? false).length;

    final displayPrice = price == 0
        ? 'GRATIS'
        : '$currency ${AppUi.money(price)} / $billingPeriod';

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      child: NiceCard(
        borderColor: isActive
            ? (isTrial ? AppUi.teal : Theme.of(context).colorScheme.primary)
            : AppUi.orange,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    planName.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _statusBadge(isActive ? 'AKTIF' : 'NONAKTIF',
                    isActive ? AppUi.green : AppUi.orange),
                if (isTrial) ...[
                  const SizedBox(width: 6),
                  _statusBadge('TRIAL', AppUi.teal),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'KODE PAKET: $planCode'.toUpperCase(),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 10,
                color: AppUi.mutedText(context, 0.90),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              displayPrice,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: price == 0 ? AppUi.green : theme.colorScheme.primary,
              ),
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                description,
                style: TextStyle(
                    fontSize: 12, color: AppUi.mutedText(context, 0.90)),
              ),
            ],
            const SizedBox(height: 16),
            Divider(height: 1, thickness: 2, color: accent),
            const SizedBox(height: 16),
            Text(
              'BATASAN KUOTA',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _quotaStat('Max Users',
                    maxUsers != null ? maxUsers.toString() : 'Unlimited',
                    icon: Icons.people_outline_rounded),
                _quotaStat(
                    'Marketplace',
                    maxMarketplace != null
                        ? maxMarketplace.toString()
                        : 'Unlimited',
                    icon: Icons.storefront_rounded),
                _quotaStat('Shopee Toko',
                    maxShopee != null ? maxShopee.toString() : 'Unlimited',
                    icon: Icons.shopping_bag_outlined),
                _quotaStat('TikTok Toko',
                    maxTiktok != null ? maxTiktok.toString() : 'Unlimited',
                    icon: Icons.store_outlined),
                _quotaStat('Storage',
                    maxStorage != null ? '$maxStorage MB' : 'Unlimited',
                    icon: Icons.cloud_queue_rounded),
                _quotaStat('Retensi Order', '$retentionDays Hari',
                    icon: Icons.history_rounded),
                _quotaStat(
                    'Fitur Aktif', '$enabledFeatureCount/${features.length}',
                    icon: Icons.stars_rounded),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'FITUR TERMASUK',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (enabledFeatureCount == 0)
              Text(
                'Tidak ada fitur aktif.'.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppUi.mutedText(context, 0.90),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: features
                    .where((feature) => feature['enabled'] as bool? ?? false)
                    .take(18)
                    .map((feature) {
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppUi.green.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: AppUi.green.withOpacity(0.28), width: 0.8),
                    ),
                    child: Text(
                      _featureLabel(feature).toUpperCase(),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 8.5,
                        color: AppUi.green,
                      ),
                    ),
                  );
                }).toList(),
              ),
            if (enabledFeatureCount > 18) ...[
              const SizedBox(height: 8),
              Text(
                '+${enabledFeatureCount - 18} FITUR LAINNYA',
                style: TextStyle(
                  color: AppUi.mutedText(context, 0.90),
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed:
                      _isSaving ? null : () => _showPlanEditor(plan: plan),
                  icon: Icon(Icons.edit_rounded, size: 16),
                  label: Text('EDIT PAKET'),
                ),
                FilledButton.icon(
                  onPressed: _isSaving ? null : () => _showFeatureEditor(plan),
                  icon: Icon(Icons.extension_rounded, size: 16),
                  label: Text('EDIT FITUR'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _isSaving ? null : () => _confirmToggleActive(plan),
                  icon: Icon(
                    isActive
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 16,
                  ),
                  label: Text(isActive ? 'NONAKTIFKAN' : 'AKTIFKAN'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  num _subscriptionMoneyValue(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return 0;
    return num.tryParse(digits) ?? 0;
  }

  String _formatSubscriptionMoney(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';

    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      final reverseIndex = digits.length - i;
      buffer.write(digits[i]);
      if (reverseIndex > 1 && reverseIndex % 3 == 1) {
        buffer.write('.');
      }
    }
    return buffer.toString();
  }

  Widget _fieldLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 10,
          letterSpacing: 0.2,
          color: AppUi.mutedText(context, 0.90),
        ),
      ),
    );
  }

  Widget _smallNumberField(String label, TextEditingController controller) {
    return SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _fieldLabel(label),
          TextField(
            controller: controller,
            onTap: AppUi.selectOnTap(controller),
            keyboardType: TextInputType.number,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _quotaStat(String label, String value, {IconData? icon}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: AppUi.mutedText(context, 0.75)),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
              color: AppUi.mutedText(context, 0.85),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.08)
                  : Colors.black.withOpacity(0.06),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 11,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.32), width: 0.8),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 9,
        ),
      ),
    );
  }

  Widget _miniBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 8,
        ),
      ),
    );
  }
}

class _FeatureLimitResult {
  const _FeatureLimitResult(this.limit);

  final int? limit;
}

class _NoLimitCancel extends _FeatureLimitResult {
  _NoLimitCancel() : super(null);
}

class _SubscriptionThousandsInputFormatter extends TextInputFormatter {
  const _SubscriptionThousandsInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      final reverseIndex = digits.length - i;
      buffer.write(digits[i]);
      if (reverseIndex > 1 && reverseIndex % 3 == 1) {
        buffer.write('.');
      }
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
