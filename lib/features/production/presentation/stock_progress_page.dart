import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/evidence/models/photo_evidence.dart';
import '../../../core/evidence/services/photo_evidence_service.dart';
import '../../../core/evidence/widgets/evidence_camera_field.dart';
import '../../../core/ui/app_ui.dart';
import '../../marketplace/models/marketplace_sku_map.dart';
import '../../marketplace/services/marketplace_service.dart';
import '../../stock/models/product.dart';
import 'package:collection/collection.dart';

class StockProgressPage extends StatefulWidget {
  const StockProgressPage({super.key});

  @override
  State<StockProgressPage> createState() => _StockProgressPageState();
}

class _StockProgressPageState extends State<StockProgressPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final MarketplaceService _marketplaceService = MarketplaceService();
  final PhotoEvidenceService _uploadService = PhotoEvidenceService();
  final TextEditingController _searchController = TextEditingController();

  bool _loading = true;
  bool _isSuperAdmin = false;
  String _currentTenantId = '';
  String _currentRoleId = '';
  String? _error;
  String _tailorFilter = 'all';
  String _statusFilter = 'all';
  String _paymentFilter = 'all';
  DateTime _activeMonth = DateTime(DateTime.now().year, DateTime.now().month);
  Timer? _debounce;

  Map<String, dynamic> _summary = <String, dynamic>{};
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _tailors = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _tailorCards = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _deposits = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _materialPurchases = <Map<String, dynamic>>[];
  List<Product> _localProducts = <Product>[];
  List<MarketplaceSkuMap> _skuMaps = <MarketplaceSkuMap>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final userRow = await _loadCurrentUser();
      _currentTenantId = AppUi.text(userRow['tenant_id'], '');
      _currentRoleId = AppUi.text(userRow['role_id'], '');
      _isSuperAdmin = _currentRoleId == 'super_admin';

      final payload = await _client.rpc(
        'list_production_progress_full_for_app',
        params: <String, dynamic>{
          'p_tailor_id': _tailorFilter == 'all' ? null : _tailorFilter,
          'p_status': _statusFilter == 'all' ? null : _statusFilter,
          'p_payment_status': _paymentFilter == 'all' ? null : _paymentFilter,
          'p_search': _searchController.text.trim().isEmpty
              ? null
              : _searchController.text.trim(),
          'p_month': _dateOnly(_activeMonth),
        },
      );

      final products = _currentTenantId.isEmpty
          ? <Product>[]
          : await _marketplaceService.listLocalProducts(
              tenantId: _currentTenantId,
              limit: 200,
            );
      final skuMaps = _currentTenantId.isEmpty
          ? <MarketplaceSkuMap>[]
          : await _marketplaceService.listSkuMaps(
              tenantId: _currentTenantId,
              limit: 500,
            );

      final data = _map(payload);
      final rows = _mapList(data['rows']);
      final tailors = _mapList(data['tailors']);
      final summary = _map(data['summary']);
      final deposits = _mapList(data['deposits']);
      final materialPurchases = _mapList(data['material_purchases']);
      final directTailors =
          await _client.rpc('list_production_tailors_for_app');

      if (!mounted) return;
      setState(() {
        _summary = summary;
        _items = rows;
        _tailorCards = tailors
            .where((item) => AppUi.text(item['status'], 'active') != 'deleted')
            .toList();
        _deposits = deposits;
        _materialPurchases = materialPurchases;
        _tailors = _mapList(directTailors)
            .where((item) => AppUi.text(item['status'], 'active') != 'deleted')
            .toList();
        if (_tailorFilter != 'all' &&
            !_tailors.any(
                (item) => AppUi.text(item['tailor_id'], '') == _tailorFilter)) {
          _tailorFilter = 'all';
        }
        _localProducts = products
            .where((item) => item.status.toLowerCase() != 'inactive')
            .toList();
        _skuMaps = skuMaps
            .where((item) =>
                item.hasLocalProduct &&
                item.localProductStatus.toLowerCase() != 'inactive' &&
                item.status.toLowerCase() != 'deleted')
            .toList();
        _loading = false;
      });
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AppUi.userMessage(e.toString());
          _loading = false;
        });
      }
    }
  }

  bool _ensureCanWriteProduction() {
    if (_isSuperAdmin ||
        _currentRoleId == 'production' ||
        _currentRoleId == 'produksi' ||
        _currentRoleId == 'platform_owner') {
      return true;
    }
    AppUi.showSnack('Akses tulis produksi tidak tersedia.');
    return false;
  }

  Future<Map<String, dynamic>> _loadCurrentUser() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return <String, dynamic>{};
    final row = await _client
        .from('users')
        .select('tenant_id, role_id')
        .eq('user_id', userId)
        .maybeSingle();
    return row == null ? <String, dynamic>{} : Map<String, dynamic>.from(row);
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), _load);
  }

  String _dateOnly(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)}';
  }

  String _monthLabel(DateTime value) {
    const names = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    return '${names[value.month - 1]} ${value.year}';
  }

  DateTime _monthEnd(DateTime value) {
    return DateTime(value.year, value.month + 1, 0);
  }

  Future<void> _pickActiveMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _activeMonth,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Pilih bulan produksi',
    );
    if (picked == null) return;
    setState(() {
      _activeMonth = DateTime(picked.year, picked.month);
    });
    await _load();
  }

  Future<DateTime?> _pickDate(DateTime? initial) {
    return showDatePicker(
      context: context,
      initialDate: initial ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
  }

  Future<String?> _pickAndUploadFile({
    required String label,
    required void Function(bool value) setUploading,
  }) async {
    final picked = await FilePicker.pickFiles(
      allowMultiple: false,
      withData: true,
      type: FileType.custom,
      allowedExtensions: const <String>['pdf', 'jpg', 'jpeg', 'png', 'webp'],
    );
    if (picked == null || picked.files.isEmpty) return null;

    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw Exception(
          'File tidak bisa dibaca. Pilih file dari galeri/dokumen.');
    }

    setUploading(true);
    try {
      final url = await _uploadService.uploadBytesToDrive(
        fileName: file.name,
        mimeType: _mimeFromName(file.name),
        bytes: Uint8List.fromList(bytes),
      );
      AppUi.showSnack('$label berhasil diunggah.');
      return url;
    } finally {
      setUploading(false);
    }
  }

  String _mimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _createProgress() async {
    if (!_ensureCanWriteProduction()) return;
    final suratJalanNumber = TextEditingController();
    final patternCode = TextEditingController();
    final note = TextEditingController();
    final customStageController = TextEditingController();
    final lines = <_ProductionLineInput>[_ProductionLineInput()];

    final availableStages = await _loadStageTemplatesForCreate();

    final uniquePatternCodes = _items
        .map((item) => AppUi.text(item['pattern_code']))
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    uniquePatternCodes.sort();
    DateTime productionDate = DateTime.now();
    DateTime? targetDate;
    String? suratJalanUrl;
    PhotoEvidence? proofEvidence;
    bool saving = false;
    bool uploadingFile = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            num totalQty() => lines.fold<num>(0, (sum, line) => sum + line.qty);

            Future<void> submit() async {
              final manualSuratJalan = suratJalanNumber.text.trim();
              if (manualSuratJalan.isEmpty) {
                AppUi.showSnack('Nomor Surat Jalan wajib diisi manual.');
                return;
              }
              final validLines = lines
                  .where((line) =>
                      (line.productId ?? '').trim().isNotEmpty && line.qty > 0)
                  .toList();
              if (validLines.isEmpty) {
                AppUi.showSnack('Pilih minimal satu SKU lokal dan qty proses.');
                return;
              }
              final activeStagesPayload = availableStages
                  .where((stage) => stage['active'] == true)
                  .map((stage) => <String, dynamic>{
                        'key': AppUi.text(stage['key']),
                        'label': _editableStageLabel(stage),
                      })
                  .where((stage) => AppUi.text(stage['key']).isNotEmpty)
                  .toList();
              if (activeStagesPayload.isEmpty) {
                AppUi.showSnack('Pilih minimal satu progress proses.');
                return;
              }

              try {
                setSheetState(() => saving = true);
                if (_currentTenantId.isNotEmpty) {
                  final duplicate = await _client
                      .from('production_progress')
                      .select('progress_id')
                      .eq('tenant_id', _currentTenantId)
                      .eq('surat_jalan_number', manualSuratJalan)
                      .limit(1);
                  if (_mapList(duplicate).isNotEmpty) {
                    AppUi.showSnack('Nomor Surat Jalan sudah dipakai.');
                    return;
                  }
                }

                await _client.rpc(
                  'create_production_progress_full_for_app',
                  params: <String, dynamic>{
                    'p_pattern_code': patternCode.text.trim(),
                    'p_production_date': _dateOnly(productionDate),
                    'p_target_finish_date':
                        targetDate == null ? null : _dateOnly(targetDate!),
                    'p_items': validLines.map((line) {
                      return <String, dynamic>{
                        'product_id': line.productId,
                        'size_label': line.sizeLabel,
                        'qty': line.qty,
                        'sewing_price_per_pcs': 0,
                        'sort_order': lines.indexOf(line) + 1,
                      };
                    }).toList(),
                    'p_surat_jalan_url': suratJalanUrl,
                    'p_catatan': note.text.trim(),
                    'p_proof_url': proofEvidence?.publicUrl,
                    'p_surat_jalan_number': manualSuratJalan,
                    'p_active_stages': activeStagesPayload,
                  },
                );

                if (sheetContext.mounted) AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (e) {
                AppUi.showSnack(e.message);
              } catch (e) {
                AppUi.showSnack(AppUi.userMessage(e.toString()));
              } finally {
                if (sheetContext.mounted) setSheetState(() => saving = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    'Tambah Produksi Berjalan',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: suratJalanNumber,
                    enabled: !saving,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Nomor Surat Jalan',
                      helperText: 'Isi manual sesuai nomor fisik/admin.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Autocomplete<String>(
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      if (textEditingValue.text.isEmpty) {
                        return uniquePatternCodes;
                      }
                      return uniquePatternCodes.where((String option) {
                        return option
                            .toLowerCase()
                            .contains(textEditingValue.text.toLowerCase());
                      });
                    },
                    onSelected: (String selection) {
                      patternCode.text = selection;
                    },
                    optionsViewBuilder: (BuildContext context,
                        AutocompleteOnSelected<String> onSelected,
                        Iterable<String> options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4.0,
                          borderRadius: BorderRadius.circular(8),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: 200,
                              minWidth: MediaQuery.of(context).size.width - 32,
                              maxWidth: MediaQuery.of(context).size.width - 32,
                            ),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (BuildContext context, int index) {
                                final String option = options.elementAt(index);
                                return ListTile(
                                  title: Text(option),
                                  onTap: () {
                                    onSelected(option);
                                  },
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                    fieldViewBuilder:
                        (context, controller, focusNode, onEditingComplete) {
                      controller.addListener(() {
                        patternCode.text = controller.text;
                      });
                      if (controller.text.isEmpty &&
                          patternCode.text.isNotEmpty) {
                        controller.text = patternCode.text;
                      }
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        enabled: !saving,
                        decoration: const InputDecoration(
                          labelText: 'Kode Pola (Pilih atau Ketik Manual)',
                          border: OutlineInputBorder(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () async {
                                  final picked =
                                      await _pickDate(productionDate);
                                  if (picked != null && sheetContext.mounted) {
                                    setSheetState(
                                        () => productionDate = picked);
                                  }
                                },
                          icon: Icon(Icons.event_outlined),
                          label: Text('Tanggal ${AppUi.date(productionDate)}'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () async {
                                  final picked = await _pickDate(targetDate);
                                  if (picked != null && sheetContext.mounted) {
                                    setSheetState(() => targetDate = picked);
                                  }
                                },
                          icon: Icon(Icons.flag_outlined),
                          label: Text(targetDate == null
                              ? 'Target'
                              : AppUi.date(targetDate)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text('Progress Proses',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  ...availableStages.map((stage) {
                    return _buildCreateStageTemplateTile(
                      sheetContext: sheetContext,
                      stage: stage,
                      saving: saving,
                      onChanged: (bool value) {
                        setSheetState(() {
                          stage['active'] = value;
                        });
                      },
                      onEdit: () async {
                        final edited = await _editStageLabelDialog(
                          _editableStageLabel(stage),
                        );
                        if (edited == null || edited.trim().isEmpty) return;
                        try {
                          setSheetState(() => saving = true);
                          await _client.rpc(
                            'upsert_production_stage_template_for_app',
                            params: <String, dynamic>{
                              'p_stage_key': AppUi.text(stage['key']),
                              'p_stage_label': edited.trim(),
                              'p_default_selected': null,
                            },
                          );
                          if (!sheetContext.mounted) return;
                          setSheetState(() {
                            stage['label'] = edited.trim();
                          });
                          AppUi.showSnack('Template progress diperbarui.');
                        } on PostgrestException catch (e) {
                          AppUi.showSnack(e.message);
                        } catch (e) {
                          AppUi.showSnack(AppUi.userMessage(e.toString()));
                        } finally {
                          if (sheetContext.mounted) {
                            setSheetState(() => saving = false);
                          }
                        }
                      },
                      onDelete: () async {
                        final key = AppUi.text(stage['key']);
                        if (key.isEmpty) return;
                        final confirmed = await showDialog<bool>(
                          context: sheetContext,
                          builder: (dialogContext) => AlertDialog(
                            title: Text('Hapus template progress?'),
                            content: Text(
                              'Progress "${_editableStageLabel(stage)}" tidak akan muncul lagi saat tambah produksi baru. Progress lama tetap aman.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    AppUi.safePop(dialogContext, false),
                                child: Text('Batal'),
                              ),
                              FilledButton.icon(
                                onPressed: () =>
                                    AppUi.safePop(dialogContext, true),
                                icon: Icon(Icons.delete_outline),
                                label: Text('Hapus'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        try {
                          setSheetState(() => saving = true);
                          await _client.rpc(
                            'delete_production_stage_template_for_app',
                            params: <String, dynamic>{'p_stage_key': key},
                          );
                          if (!sheetContext.mounted) return;
                          setSheetState(() {
                            availableStages.removeWhere(
                              (row) => AppUi.text(row['key']) == key,
                            );
                          });
                          AppUi.showSnack('Template progress dihapus.');
                        } on PostgrestException catch (e) {
                          AppUi.showSnack(e.message);
                        } catch (e) {
                          AppUi.showSnack(AppUi.userMessage(e.toString()));
                        } finally {
                          if (sheetContext.mounted) {
                            setSheetState(() => saving = false);
                          }
                        }
                      },
                    );
                  }),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: customStageController,
                          enabled: !saving,
                          decoration: const InputDecoration(
                            labelText: 'Tambah progress custom',
                            hintText: 'Misal: bordir, sablon',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline),
                        onPressed: saving
                            ? null
                            : () async {
                                final text = customStageController.text.trim();
                                if (text.isEmpty) return;
                                final key = _normalizeStageKey(text);
                                if (key.isEmpty) return;
                                final existing =
                                    availableStages.firstWhereOrNull(
                                  (stage) => AppUi.text(stage['key']) == key,
                                );
                                if (existing != null) {
                                  setSheetState(() {
                                    existing
                                      ..['label'] = text
                                      ..['active'] = true;
                                    customStageController.clear();
                                  });
                                  AppUi.showSnack(
                                      'Progress "$text" dipilih untuk produksi ini.');
                                  return;
                                }

                                try {
                                  setSheetState(() => saving = true);
                                  await _client.rpc(
                                    'upsert_production_stage_template_for_app',
                                    params: <String, dynamic>{
                                      'p_stage_key': key,
                                      'p_stage_label': text,
                                      'p_default_selected': true,
                                    },
                                  );
                                  if (!sheetContext.mounted) return;
                                  setSheetState(() {
                                    availableStages.add(<String, dynamic>{
                                      'key': key,
                                      'label': text,
                                      'active': true,
                                    });
                                    customStageController.clear();
                                  });
                                  AppUi.showSnack(
                                      'Template progress "$text" ditambahkan.');
                                } on PostgrestException catch (e) {
                                  AppUi.showSnack(e.message);
                                } catch (e) {
                                  AppUi.showSnack(
                                      AppUi.userMessage(e.toString()));
                                } finally {
                                  if (sheetContext.mounted) {
                                    setSheetState(() => saving = false);
                                  }
                                }
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text('Breakdown Size',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  if (_localProducts.isEmpty)
                    const EmptyState(
                      title: 'SKU lokal belum ada',
                      subtitle:
                          'Tambahkan produk/SKU lokal aktif dulu di menu stok. Produksi akan masuk ke SKU lokal ini.',
                      icon: Icons.inventory_2_outlined,
                    )
                  else
                    ...lines.map((line) {
                      return _lineEditor(
                        context: sheetContext,
                        line: line,
                        canRemove: lines.length > 1,
                        saving: saving,
                        onChanged: () => setSheetState(() {}),
                        onRemove: () {
                          setSheetState(() {
                            line.dispose();
                            lines.remove(line);
                          });
                        },
                      );
                    }),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: saving
                          ? null
                          : () => setSheetState(
                              () => lines.add(_ProductionLineInput())),
                      icon: Icon(Icons.add_circle_outline),
                      label: Text('Tambah size'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _miniMetric('Total qty', totalQty().toStringAsFixed(0)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: saving || uploadingFile
                        ? null
                        : () async {
                            try {
                              final url = await _pickAndUploadFile(
                                label: 'Surat jalan',
                                setUploading: (value) {
                                  if (sheetContext.mounted) {
                                    setSheetState(() => uploadingFile = value);
                                  }
                                },
                              );
                              if (url != null && sheetContext.mounted) {
                                setSheetState(() => suratJalanUrl = url);
                              }
                            } catch (e) {
                              AppUi.showSnack(AppUi.userMessage(e.toString()));
                            }
                          },
                    icon: uploadingFile
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.attach_file_outlined),
                    label: Text(suratJalanUrl == null
                        ? 'Upload surat jalan'
                        : 'Surat jalan tersimpan'),
                  ),
                  const SizedBox(height: 12),
                  EvidenceCameraField(
                    label: 'Foto produksi',
                    moduleName: 'production_progress',
                    purpose: 'create_progress',
                    allowGallery: true,
                    onUploaded: (evidence) {
                      proofEvidence = evidence;
                      if (sheetContext.mounted) setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Catatan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.save_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Simpan Progress'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      suratJalanNumber.dispose();
      patternCode.dispose();
      note.dispose();
      customStageController.dispose();
      for (final line in lines) {
        line.dispose();
      }
    });

    if (saved == true) _load();
  }

  Widget _lineEditor({
    required BuildContext context,
    required _ProductionLineInput line,
    required bool canRemove,
    required bool saving,
    required VoidCallback onChanged,
    required VoidCallback onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NiceCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: saving
                        ? null
                        : () async {
                            final selected = await _showProductPicker();
                            if (selected != null) {
                              line.product = selected;
                              onChanged();
                            }
                          },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Pilih SKU Master / Produk',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.arrow_drop_down),
                      ),
                      child: Text(
                        line.product != null
                            ? _productionSkuLabel(line.product!)
                            : 'Ketuk untuk memilih SKU/Produk',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: line.product != null
                              ? null
                              : Theme.of(context).hintColor,
                        ),
                      ),
                    ),
                  ),
                ),
                if (canRemove)
                  IconButton(
                    tooltip: 'Hapus size',
                    onPressed: saving ? null : onRemove,
                    icon: Icon(Icons.remove_circle_outline),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: line.qtyController,
                    keyboardType: TextInputType.number,
                    enabled: !saving,
                    decoration: const InputDecoration(
                      labelText: 'Qty proses',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<Product?> _showProductPicker({
    String title = 'Pilih SKU Master / Produk',
    String searchLabel = 'Cari nama / SKU / barcode',
    String? helperText,
  }) async {
    final searchController = TextEditingController();
    List<Product> filtered = List<Product>.from(_localProducts);

    final result = await showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void filter(String value) {
              final keyword = value.trim().toLowerCase();

              setSheetState(() {
                filtered = _localProducts.where((product) {
                  return product.namaBarang.toLowerCase().contains(keyword) ||
                      product.kodeSku.toLowerCase().contains(keyword) ||
                      (product.kodeBarcode?.toLowerCase() ?? '')
                          .contains(keyword);
                }).toList();
              });
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.88,
              minChildSize: 0.48,
              maxChildSize: 0.96,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: searchController,
                            onChanged: filter,
                            decoration: InputDecoration(
                              labelText: searchLabel,
                              prefixIcon: Icon(Icons.search),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          if ((helperText ?? '').trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              helperText!,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withOpacity(0.72),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('Produk tidak ditemukan'))
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final product = filtered[index];

                                return Card(
                                  shape: AppUi.modernShape(context, radius: 16),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withOpacity(0.12),
                                      child: Icon(Icons.inventory_2_outlined),
                                    ),
                                    title: Text(
                                      product.namaBarang,
                                      style: TextStyle(
                                          fontWeight: FontWeight.w800),
                                    ),
                                    subtitle: Text(
                                      'SKU: ${product.kodeSku}\n'
                                      'Barcode: ${product.kodeBarcode}\n'
                                      'Stock: ${product.stockSaatIni.toStringAsFixed(0)} ${product.satuan}',
                                    ),
                                    isThreeLine: true,
                                    onTap: () =>
                                        AppUi.safePop(context, product),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      searchController.dispose();
    });
    return result;
  }

  String _productionSkuLabel(Product product) {
    return '${product.kodeSku} - ${product.namaBarang} (Stok: ${product.stockSaatIni.toStringAsFixed(0)} ${product.satuan})';
  }

  Future<void> _showPaymentSheet({
    Map<String, dynamic>? progress,
    Map<String, dynamic>? tailor,
    Map<String, dynamic>? payment,
    String initialType = 'sewing_payment',
    String? initialStageKey,
  }) async {
    if (!_ensureCanWriteProduction()) return;
    final existingType = AppUi.text(payment?['payment_type'], initialType);
    final depositOnly = existingType == 'deposit' ||
        (progress == null && tailor == null && initialType == 'deposit');

    final stages = progress != null
        ? _mapList(progress['stages'])
        : <Map<String, dynamic>>[];
    final payableStages = stages.where((stage) {
      final status = AppUi.text(stage['status']);
      final skipped =
          status == 'skipped' || AppUi.text(stage['is_skipped']) == 'true';
      return !skipped;
    }).toList();

    String? selectedStageKey = payment != null
        ? AppUi.text(payment['stage_key'])
        : (initialStageKey ??
            (payableStages.isNotEmpty
                ? AppUi.text(payableStages.first['stage_key'])
                : null));

    String? selectedTailorIdForPayment =
        tailor?['tailor_id'] ?? payment?['tailor_id'];

    final amount = TextEditingController(
      text: payment != null
          ? AppUi.moneyInput(AppUi.toNum(payment['amount']))
          : '',
    );
    final note = TextEditingController(
      text: AppUi.text(
          payment?['note'], depositOnly ? 'Deposit awal produksi' : ''),
    );
    final paymentLabel = TextEditingController(
      text: AppUi.text(payment?['payment_label']),
    );
    final depositSuggestions = {
      'Deposit awal produksi',
      ..._deposits.map((e) => AppUi.text(e['note'])).where((t) => t.isNotEmpty),
      ..._items
          .map((e) => AppUi.text(e['note']))
          .where((t) => t.isNotEmpty && t.length < 50),
    }.toList();

    String paymentType = existingType;
    String paymentStatus =
        AppUi.text(payment?['payment_status'], 'sudah_bayar');
    DateTime paymentDate =
        DateTime.tryParse(AppUi.text(payment?['payment_date'], '')) ??
            DateTime.now();
    PhotoEvidence? proofEvidence;
    final initialProofUrl = AppUi.text(payment?['proof_url'], '');
    bool saving = false;
    bool initialized = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            num getStageUnpaidAmount(String stageKey) {
              final stage = stages.firstWhere(
                  (s) => AppUi.text(s['stage_key']) == stageKey,
                  orElse: () => <String, dynamic>{});
              final totalAmount = AppUi.toNum(stage['total_amount']);
              final paymentsList = progress != null
                  ? _mapList(progress['payments'])
                  : <Map<String, dynamic>>[];
              final paidAmount = paymentsList
                  .where((p) =>
                      AppUi.text(p['stage_key']) == stageKey &&
                      AppUi.text(p['payment_status']) == 'sudah_bayar' &&
                      AppUi.text(p['payment_id']) !=
                          AppUi.text(payment?['payment_id']))
                  .fold<num>(0, (sum, p) => sum + AppUi.toNum(p['amount']));
              final unpaid = totalAmount - paidAmount;
              return unpaid < 0 ? 0 : unpaid;
            }

            void updateStageFields(String stageKey) {
              final stage = stages.firstWhere(
                  (s) => AppUi.text(s['stage_key']) == stageKey,
                  orElse: () => <String, dynamic>{});
              final unpaid = getStageUnpaidAmount(stageKey);
              final stageTailorId = AppUi.text(stage['tailor_id'], '');
              setSheetState(() {
                selectedStageKey = stageKey;
                if (payment == null && paymentType == 'sewing_payment') {
                  amount.text = AppUi.moneyInput(unpaid);
                }
                if (stageTailorId.isNotEmpty) {
                  selectedTailorIdForPayment = stageTailorId;
                }
                if (note.text.isEmpty ||
                    note.text.startsWith('Bayar ') ||
                    note.text.startsWith('Kasbon ') ||
                    note.text == 'Deposit awal produksi') {
                  if (paymentType == 'sewing_payment') {
                    note.text =
                        'Bayar ${_stageLabel(stageKey)} - ${AppUi.text(progress?['surat_jalan_number'])}';
                  } else {
                    note.text =
                        'Kasbon ${_stageLabel(stageKey)} - ${AppUi.text(progress?['surat_jalan_number'])}';
                  }
                }
              });
            }

            if (!initialized) {
              initialized = true;
              if (progress != null &&
                  (paymentType == 'sewing_payment' ||
                      paymentType == 'kasbon') &&
                  selectedStageKey != null) {
                final unpaid = getStageUnpaidAmount(selectedStageKey!);
                final stage = stages.firstWhere(
                    (s) => AppUi.text(s['stage_key']) == selectedStageKey!,
                    orElse: () => <String, dynamic>{});
                final stageTailorId = AppUi.text(stage['tailor_id'], '');
                if (stageTailorId.isNotEmpty) {
                  selectedTailorIdForPayment = stageTailorId;
                }
                if (paymentType == 'kasbon' &&
                    selectedTailorIdForPayment == null &&
                    _tailors.isNotEmpty) {
                  selectedTailorIdForPayment = progress?['tailor_id'];
                }
                if (payment == null && paymentType == 'sewing_payment') {
                  amount.text = AppUi.moneyInput(unpaid);
                }
                if (note.text.isEmpty || note.text == 'Deposit awal produksi') {
                  if (paymentType == 'sewing_payment') {
                    note.text =
                        'Bayar ${_stageLabel(selectedStageKey!)} - ${AppUi.text(progress?['surat_jalan_number'])}';
                  } else {
                    note.text =
                        'Kasbon ${_stageLabel(selectedStageKey!)} - ${AppUi.text(progress?['surat_jalan_number'])}';
                  }
                }
              }
            }

            Future<void> submit() async {
              final nominal = AppUi.parseMoneyInput(amount.text);
              if (nominal <= 0) {
                AppUi.showSnack(depositOnly
                    ? 'Nominal deposit wajib lebih dari 0.'
                    : 'Nominal pembayaran wajib lebih dari 0.');
                return;
              }

              try {
                setSheetState(() => saving = true);
                if (depositOnly) {
                  await _client.rpc(
                    'upsert_production_deposit_for_app',
                    params: <String, dynamic>{
                      'p_payment_id': payment?['payment_id'],
                      'p_amount': nominal,
                      'p_payment_date': _dateOnly(paymentDate),
                      'p_payment_status': paymentStatus,
                      'p_note': note.text.trim(),
                      'p_finance_month': _dateOnly(_activeMonth),
                      'p_proof_evidence_id': proofEvidence?.evidenceId,
                      'p_proof_url':
                          proofEvidence?.publicUrl ?? initialProofUrl,
                      'p_payment_label': paymentLabel.text.trim().isEmpty
                          ? null
                          : paymentLabel.text.trim(),
                    },
                  );
                } else {
                  final stage = stages.firstWhere(
                    (s) => AppUi.text(s['stage_key']) == selectedStageKey,
                    orElse: () => <String, dynamic>{},
                  );
                  final stageTailorId =
                      AppUi.text(stage['tailor_id'], '').isNotEmpty
                          ? AppUi.text(stage['tailor_id'])
                          : null;

                  await _client.rpc(
                    'upsert_production_tailor_payment_for_app',
                    params: <String, dynamic>{
                      'p_payment_id': payment?['payment_id'],
                      'p_progress_id': progress?['progress_id'],
                      'p_tailor_id': tailor?['tailor_id'] ??
                          selectedTailorIdForPayment ??
                          stageTailorId ??
                          progress?['tailor_id'] ??
                          payment?['tailor_id'],
                      'p_payment_type': paymentType,
                      'p_amount': nominal,
                      'p_payment_date': _dateOnly(paymentDate),
                      'p_payment_status': paymentStatus,
                      'p_note': note.text.trim(),
                      'p_finance_month': _dateOnly(_activeMonth),
                      'p_proof_evidence_id': proofEvidence?.evidenceId,
                      'p_proof_url':
                          proofEvidence?.publicUrl ?? initialProofUrl,
                      'p_stage_key': selectedStageKey,
                      'p_payment_label': paymentLabel.text.trim().isEmpty
                          ? null
                          : paymentLabel.text.trim(),
                    },
                  );
                }
                if (sheetContext.mounted) AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (e) {
                AppUi.showSnack(e.message);
              } catch (e) {
                AppUi.showSnack(AppUi.userMessage(e.toString()));
              } finally {
                if (sheetContext.mounted) setSheetState(() => saving = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    payment != null
                        ? (depositOnly
                            ? 'Edit Deposit Awal'
                            : 'Edit Pembayaran Pekerja')
                        : (depositOnly
                            ? 'Tambah Deposit Awal'
                            : 'Pembayaran Pekerja'),
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  if (progress != null &&
                      (paymentType == 'sewing_payment' ||
                          paymentType == 'kasbon')) ...[
                    DropdownButtonFormField<String>(
                      value: selectedStageKey,
                      decoration: const InputDecoration(
                        labelText: 'Pilih Proses / Progress',
                        border: OutlineInputBorder(),
                      ),
                      items: payableStages.map((stage) {
                        final key = AppUi.text(stage['stage_key']);
                        final label = _stageLabel(key);
                        final worker = AppUi.text(stage['tailor_name'], '');
                        final displayLabel =
                            worker.isNotEmpty ? '$label ($worker)' : label;
                        return DropdownMenuItem<String>(
                          value: key,
                          child: Text(displayLabel),
                        );
                      }).toList(),
                      onChanged: saving
                          ? null
                          : (value) {
                              if (value != null) {
                                updateStageFields(value);
                              }
                            },
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (depositOnly)
                    LayoutBuilder(
                      builder: (context, constraints) => DropdownMenu<String>(
                        width: constraints.maxWidth,
                        initialSelection: note.text,
                        label: Text('Jenis / Deskripsi'),
                        controller: note,
                        enableFilter: true,
                        enableSearch: true,
                        dropdownMenuEntries: depositSuggestions
                            .map((s) => DropdownMenuEntry(value: s, label: s))
                            .toList(),
                        onSelected: (v) {
                          if (v != null) setSheetState(() => note.text = v);
                        },
                        inputDecorationTheme: const InputDecorationTheme(
                          border: OutlineInputBorder(),
                          filled: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                    )
                  else ...[
                    DropdownButtonFormField<String>(
                      value: paymentType,
                      decoration: const InputDecoration(
                        labelText: 'Jenis',
                        border: OutlineInputBorder(),
                      ),
                      items: progress != null
                          ? const [
                              DropdownMenuItem(
                                  value: 'sewing_payment',
                                  child: Text('Pembayaran ongkos proses')),
                              DropdownMenuItem(
                                  value: 'kasbon',
                                  child: Text('Kasbon pekerja')),
                            ]
                          : const [
                              DropdownMenuItem(
                                  value: 'kasbon',
                                  child: Text('Kasbon pekerja')),
                            ],
                      onChanged: saving
                          ? null
                          : (value) {
                              if (value != null) {
                                setSheetState(() {
                                  paymentType = value;
                                  if (selectedStageKey != null) {
                                    updateStageFields(selectedStageKey!);
                                  }
                                });
                              }
                            },
                    ),
                    const SizedBox(height: 10),
                    if (paymentType == 'kasbon') ...[
                      DropdownButtonFormField<String>(
                        value: selectedTailorIdForPayment,
                        decoration: const InputDecoration(
                          labelText: 'Pilih Pekerja untuk Kasbon',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('Pekerja manual / Belum dipilih'),
                          ),
                          ..._tailors.map((tailor) => DropdownMenuItem<String>(
                                value: AppUi.text(tailor['tailor_id']),
                                child: Text(AppUi.text(tailor['tailor_name'])),
                              )),
                        ],
                        onChanged: saving
                            ? null
                            : (value) {
                                setSheetState(() {
                                  selectedTailorIdForPayment = value;
                                });
                              },
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [AppMoneyInputFormatter()],
                    decoration: const InputDecoration(
                      labelText: 'Nominal',
                      prefixText: 'Rp ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, constraints) => DropdownMenu<String>(
                      width: constraints.maxWidth,
                      initialSelection: paymentLabel.text,
                      label: Text('Label Pembayaran (Opsional)'),
                      controller: paymentLabel,
                      enableFilter: true,
                      enableSearch: true,
                      dropdownMenuEntries: const [
                        DropdownMenuEntry(
                            value: 'Ongkos Potong', label: 'Ongkos Potong'),
                        DropdownMenuEntry(
                            value: 'Ongkos jahit', label: 'Ongkos jahit'),
                        DropdownMenuEntry(
                            value: 'Ongkos Finishing',
                            label: 'Ongkos Finishing'),
                        DropdownMenuEntry(
                            value: 'Ongkos Packing', label: 'Ongkos Packing'),
                        DropdownMenuEntry(
                            value: 'Deposit Tambahan',
                            label: 'Deposit Tambahan'),
                      ],
                      onSelected: (v) {
                        if (v != null)
                          setSheetState(() => paymentLabel.text = v);
                      },
                      inputDecorationTheme: const InputDecorationTheme(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () async {
                                  final picked = await _pickDate(paymentDate);
                                  if (picked != null && sheetContext.mounted) {
                                    setSheetState(() => paymentDate = picked);
                                  }
                                },
                          icon: Icon(Icons.event_outlined),
                          label: Text(AppUi.date(paymentDate)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: paymentStatus,
                          decoration: const InputDecoration(
                            labelText: 'Status',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 'sudah_bayar',
                                child: Text('Sudah bayar')),
                            DropdownMenuItem(
                                value: 'belum_bayar',
                                child: Text('Belum bayar')),
                          ],
                          onChanged: saving
                              ? null
                              : (value) => setSheetState(
                                  () => paymentStatus = value ?? 'sudah_bayar'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  EvidenceCameraField(
                    label: 'Bukti pembayaran',
                    moduleName: depositOnly
                        ? 'production_deposit'
                        : 'production_payment',
                    purpose: '${paymentType}_proof',
                    referenceId: payment?['payment_id']?.toString(),
                    initialPhotoUrl: initialProofUrl,
                    helperText:
                        'Bukti pembayaran opsional. Bisa ambil kamera atau pilih dari galeri.',
                    allowGallery: true,
                    onUploaded: (evidence) {
                      proofEvidence = evidence;
                      if (sheetContext.mounted) setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Catatan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.payments_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Simpan Pembayaran'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      amount.dispose();
      note.dispose();
      paymentLabel.dispose();
    });
    if (saved == true) _load();
  }

  Future<void> _deletePayment(Map<String, dynamic> payment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Hapus pembayaran produksi?'),
        content: Text(
          '${_getPaymentDisplayLabel(payment)} - ${AppUi.rupiah(AppUi.toNum(payment['amount']))}',
        ),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext, false),
            child: Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => AppUi.safePop(dialogContext, true),
            icon: Icon(Icons.delete_outline),
            label: Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _client.rpc(
        'delete_production_tailor_payment_for_app',
        params: <String, dynamic>{'p_payment_id': payment['payment_id']},
      );
      AppUi.showSnack('Pembayaran produksi dihapus.');
      await _load();
    } on PostgrestException catch (e) {
      AppUi.showSnack(e.message);
    } catch (e) {
      AppUi.showSnack(AppUi.userMessage(e.toString()));
    }
  }

  Future<void> _updateStage(Map<String, dynamic> item, String stageKey,
      Map<String, dynamic> stage) async {
    if (!_ensureCanWriteProduction()) return;
    final bool isProgressLocked = false;
    String status = AppUi.text(stage['status'], 'progress');
    bool isSkipped = (stage['is_skipped'] == true ||
            AppUi.text(stage['is_skipped']) == 'true') ||
        status == 'skipped';
    String selectedTailorId = AppUi.text(stage['tailor_id'], '');
    final manualTailorController =
        TextEditingController(text: AppUi.text(stage['tailor_name']));

    final priceController = TextEditingController(
      text: AppUi.moneyInput(AppUi.toNum(stage['price_per_pcs'])),
    );
    final noteController =
        TextEditingController(text: AppUi.text(stage['note']));

    DateTime processDate = stage['process_date'] != null
        ? DateTime.tryParse(AppUi.text(stage['process_date'])) ?? DateTime.now()
        : DateTime.now();

    PhotoEvidence? proofEvidence;
    final initialProofUrl = AppUi.text(stage['proof_url'], '');
    bool saving = false;

    if (selectedTailorId.isNotEmpty) {
      if (!_tailors
          .any((t) => AppUi.text(t['tailor_id']) == selectedTailorId)) {
        selectedTailorId = '';
      }
    }
    if (selectedTailorId.isEmpty && manualTailorController.text.isNotEmpty) {
      final match = _tailors.firstWhere(
        (t) =>
            AppUi.text(t['tailor_name']).trim().toLowerCase() ==
            manualTailorController.text.trim().toLowerCase(),
        orElse: () => <String, dynamic>{},
      );
      if (match.isNotEmpty) {
        selectedTailorId = AppUi.text(match['tailor_id']);
      }
    }

    final items = _mapList(item['items']);
    final existingBreakdown = _mapList(stage['size_breakdown']);

    final List<Map<String, dynamic>> sizeInputs = [];
    for (final row in items) {
      final productId = AppUi.text(row['product_id']);
      final sizeLabel = AppUi.text(row['size_label']);
      final double sizeDefaultQty = AppUi.toNum(row['qty']).toDouble();

      final exist = existingBreakdown.firstWhere(
        (e) =>
            AppUi.text(e['product_id']) == productId &&
            AppUi.text(e['size_label']) == sizeLabel,
        orElse: () => <String, dynamic>{},
      );

      final double sizeQtyIn = exist.isNotEmpty
          ? AppUi.toNum(exist['qty_in']).toDouble()
          : sizeDefaultQty;
      final double sizeQtyOut = exist.isNotEmpty
          ? AppUi.toNum(exist['qty_out']).toDouble()
          : (exist.isNotEmpty
              ? AppUi.toNum(exist['qty_in']).toDouble()
              : sizeDefaultQty);
      final double sizeQtyReject =
          exist.isNotEmpty ? AppUi.toNum(exist['qty_reject']).toDouble() : 0.0;

      sizeInputs.add({
        'product_id': productId,
        'size_label': sizeLabel,
        'local_sku': AppUi.text(row['local_sku']),
        'local_product_name': AppUi.text(row['local_product_name']),
        'qty_in_controller':
            TextEditingController(text: sizeQtyIn.toStringAsFixed(0)),
        'qty_out_controller':
            TextEditingController(text: sizeQtyOut.toStringAsFixed(0)),
        'qty_reject_controller':
            TextEditingController(text: sizeQtyReject.toStringAsFixed(0)),
      });
    }

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> submit() async {
              final double price =
                  AppUi.parseMoneyInput(priceController.text).toDouble();
              final String tailorName = manualTailorController.text.trim();

              if (!isSkipped && tailorName.isEmpty) {
                AppUi.showSnack('Pekerja proses wajib diisi.');
                return;
              }
              if (isSkipped && noteController.text.trim().isEmpty) {
                AppUi.showSnack('Catatan wajib diisi jika proses dilewati.');
                return;
              }

              final List<Map<String, dynamic>> sizeBreakdownJson = [];
              double totalQtyIn = 0;
              double totalQtyOut = 0;
              double totalQtyReject = 0;

              for (final input in sizeInputs) {
                final qi = double.tryParse(
                        (input['qty_in_controller'] as TextEditingController)
                            .text
                            .trim()) ??
                    0;
                final qo = double.tryParse(
                        (input['qty_out_controller'] as TextEditingController)
                            .text
                            .trim()) ??
                    0;
                final qr = double.tryParse((input['qty_reject_controller']
                            as TextEditingController)
                        .text
                        .trim()) ??
                    0;

                totalQtyIn += qi;
                totalQtyOut += qo;
                totalQtyReject += qr;

                sizeBreakdownJson.add({
                  'product_id': input['product_id'],
                  'size_label': input['size_label'],
                  'qty_in': qi,
                  'qty_out': qo,
                  'qty_reject': qr,
                });
              }

              try {
                setSheetState(() => saving = true);

                final String? finalTailorId =
                    selectedTailorId.isNotEmpty ? selectedTailorId : null;

                await _client.rpc(
                  'upsert_production_process_stage_for_app',
                  params: <String, dynamic>{
                    'p_progress_id': item['progress_id'],
                    'p_stage_key': stageKey,
                    'p_status': isSkipped ? 'skipped' : status,
                    'p_tailor_id': finalTailorId,
                    'p_tailor_name': tailorName.isEmpty ? null : tailorName,
                    'p_qty_in': totalQtyIn,
                    'p_qty_out': totalQtyOut,
                    'p_qty_reject': totalQtyReject,
                    'p_price_per_pcs': price,
                    'p_process_date': _dateOnly(processDate),
                    'p_proof_url': proofEvidence?.publicUrl ??
                        (initialProofUrl.isNotEmpty ? initialProofUrl : null),
                    'p_note': noteController.text.trim().isEmpty
                        ? null
                        : noteController.text.trim(),
                    'p_is_skipped': isSkipped,
                    'p_size_breakdown': sizeBreakdownJson,
                  },
                );

                if (sheetContext.mounted) AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (e) {
                AppUi.showSnack(e.message);
              } catch (e) {
                AppUi.showSnack(AppUi.userMessage(e.toString()));
              } finally {
                if (sheetContext.mounted) setSheetState(() => saving = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Update Progress: ${_stageLabel(stageKey)}',
                          style: Theme.of(sheetContext)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Lewati Progress'),
                          Switch(
                            value: isSkipped,
                            onChanged: saving || isProgressLocked
                                ? null
                                : (val) {
                                    setSheetState(() {
                                      isSkipped = val;
                                      if (isSkipped) {
                                        status = 'skipped';
                                      } else {
                                        status = AppUi.text(stage['status'],
                                                    'progress') ==
                                                'skipped'
                                            ? 'progress'
                                            : AppUi.text(
                                                stage['status'], 'progress');
                                      }
                                    });
                                  },
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!isSkipped) ...[
                    DropdownButtonFormField<String>(
                      value: status == 'skipped' ? 'progress' : status,
                      decoration: const InputDecoration(
                        labelText: 'Status Progress',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'pending', child: Text('Pending')),
                        DropdownMenuItem(
                            value: 'progress', child: Text('Progress')),
                        DropdownMenuItem(value: 'done', child: Text('Done')),
                        DropdownMenuItem(
                            value: 'cancelled', child: Text('Dibatalkan')),
                      ],
                      onChanged: saving || isProgressLocked
                          ? null
                          : (value) =>
                              setSheetState(() => status = value ?? 'progress'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedTailorId.isEmpty ? null : selectedTailorId,
                      decoration: const InputDecoration(
                        labelText: 'Pilih Pekerja (Tailor)',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('Pekerja manual / Belum dipilih'),
                        ),
                        ..._tailors.map((tailor) => DropdownMenuItem<String>(
                              value: AppUi.text(tailor['tailor_id']),
                              child: Text(AppUi.text(tailor['tailor_name'])),
                            )),
                      ],
                      onChanged: saving || isProgressLocked
                          ? null
                          : (value) {
                              setSheetState(() {
                                selectedTailorId = value ?? '';
                                if (selectedTailorId.isNotEmpty) {
                                  final t = _tailors.firstWhere((element) =>
                                      AppUi.text(element['tailor_id']) ==
                                      selectedTailorId);
                                  manualTailorController.text =
                                      AppUi.text(t['tailor_name']);
                                }
                              });
                            },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: manualTailorController,
                      enabled: !saving && !isProgressLocked,
                      decoration: const InputDecoration(
                        labelText: 'Nama Pekerja',
                        helperText:
                            'Bisa diisi manual jika nama tidak terdaftar di rekap.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Size Breakdown Qty:',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    ...sizeInputs.map((input) {
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(sheetContext)
                                .colorScheme
                                .outlineVariant
                                .withOpacity(
                                  Theme.of(sheetContext).brightness ==
                                          Brightness.dark
                                      ? 0.3
                                      : 0.5,
                                ),
                            width: 0.8,
                          ),
                          borderRadius: AppTheme.radiusSm,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${input['size_label']} - ${input['local_sku']} (${input['local_product_name']})',
                              style: TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 11),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: input['qty_in_controller']
                                        as TextEditingController,
                                    keyboardType: TextInputType.number,
                                    enabled: !saving && !isProgressLocked,
                                    decoration: const InputDecoration(
                                      labelText: 'Qty In',
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 8),
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: input['qty_out_controller']
                                        as TextEditingController,
                                    keyboardType: TextInputType.number,
                                    enabled: !saving && !isProgressLocked,
                                    decoration: const InputDecoration(
                                      labelText: 'Qty Out',
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 8),
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: input['qty_reject_controller']
                                        as TextEditingController,
                                    keyboardType: TextInputType.number,
                                    enabled: !saving && !isProgressLocked,
                                    decoration: const InputDecoration(
                                      labelText: 'Reject',
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 8),
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 12),
                    TextField(
                      controller: priceController,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [AppMoneyInputFormatter()],
                      enabled: !saving && !isProgressLocked,
                      decoration: const InputDecoration(
                        labelText: 'Tarif / Ongkos per pcs',
                        prefixText: 'Rp ',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  ListTile(
                    title: Text('Tanggal Proses'),
                    subtitle: Text(AppUi.date(processDate)),
                    trailing: Icon(Icons.calendar_today_outlined),
                    onTap: saving || isProgressLocked
                        ? null
                        : () async {
                            final picked = await _pickDate(processDate);
                            if (picked != null) {
                              setSheetState(() => processDate = picked);
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  IgnorePointer(
                    ignoring: isProgressLocked,
                    child: EvidenceCameraField(
                      label: 'Foto update progress',
                      moduleName: 'production_progress',
                      purpose: 'stage_$stageKey',
                      referenceId: item['progress_id']?.toString(),
                      initialPhotoUrl: initialProofUrl,
                      allowGallery: true,
                      onUploaded: (evidence) {
                        proofEvidence = evidence;
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteController,
                    maxLines: 3,
                    enabled: !saving && !isProgressLocked,
                    decoration: InputDecoration(
                      labelText: isSkipped
                          ? 'Alasan dilewati (Wajib)'
                          : 'Catatan (Opsional)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (!isSkipped &&
                      manualTailorController.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () {
                        AppUi.safePop(sheetContext, false);
                        _showPaymentSheet(
                          progress: item,
                          initialStageKey: stageKey,
                          initialType: 'sewing_payment',
                        );
                      },
                      icon: Icon(Icons.payments_outlined,
                          color: Theme.of(context).colorScheme.primary),
                      label: Text('Bayar Ongkos Progress Ini'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        side: BorderSide(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.38),
                          width: 0.8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ],
                  if (stage.isNotEmpty &&
                      (_currentRoleId == 'platform_owner' ||
                          _currentRoleId == 'super_admin' ||
                          ((_currentRoleId == 'production' ||
                                  _currentRoleId == 'produksi') &&
                              !isProgressLocked)) &&
                      !saving) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: Text('Hapus progress ini?'),
                            content: Text(
                                'Menghapus progress "${_stageLabel(stageKey)}" akan mem-void semua rincian pembayaran terkait progress ini.\n\nApakah Anda yakin?'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    AppUi.safePop(dialogContext, false),
                                child: Text('Batal'),
                              ),
                              FilledButton.icon(
                                onPressed: () =>
                                    AppUi.safePop(dialogContext, true),
                                icon: Icon(Icons.delete_outline),
                                label: Text('Hapus'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;

                        try {
                          setSheetState(() => saving = true);
                          await _client.rpc(
                            'delete_production_progress_stage_for_app',
                            params: <String, dynamic>{
                              'p_progress_id': item['progress_id'],
                              'p_stage_key': stageKey,
                            },
                          );
                          if (sheetContext.mounted)
                            AppUi.safePop(sheetContext, true);
                        } on PostgrestException catch (e) {
                          AppUi.showSnack(e.message);
                        } catch (e) {
                          AppUi.showSnack(AppUi.userMessage(e.toString()));
                        } finally {
                          if (sheetContext.mounted)
                            setSheetState(() => saving = false);
                        }
                      },
                      icon: Icon(Icons.delete_outline, color: Colors.red),
                      label: Text('Hapus Progress Ini'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        side: const BorderSide(color: Colors.red),
                      ),
                    ),
                  ],
                  if (!isProgressLocked) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: saving ? null : submit,
                      icon: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.task_alt_outlined),
                      label: Text(stageKey == 'packing' &&
                              status == 'done' &&
                              !isSkipped
                          ? 'Selesaikan dan Masuk Stock'
                          : 'Simpan Progress'),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      manualTailorController.dispose();
      priceController.dispose();
      noteController.dispose();
      for (final input in sizeInputs) {
        (input['qty_in_controller'] as TextEditingController).dispose();
        (input['qty_out_controller'] as TextEditingController).dispose();
        (input['qty_reject_controller'] as TextEditingController).dispose();
      }
    });
    if (saved == true) _load();
  }

  Future<void> _markDone(Map<String, dynamic> item) async {
    if (!_ensureCanWriteProduction()) return;
    final items = _mapList(item['items']);
    final Map<String, TextEditingController> controllers = {};
    for (final row in items) {
      final itemId = AppUi.text(row['progress_item_id']);
      final qty = AppUi.toNum(row['qty']).toDouble();
      controllers[itemId] = TextEditingController(text: qty.toStringAsFixed(0));
    }
    bool saving = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> submit() async {
              try {
                setSheetState(() => saving = true);

                // 1. Update quantities in database for each size
                for (final row in items) {
                  final itemId = AppUi.text(row['progress_item_id']);
                  final controller = controllers[itemId];
                  if (controller == null) continue;
                  final double newQty =
                      double.tryParse(controller.text.trim()) ?? 0.0;

                  await _client
                      .from('production_progress_items')
                      .update({'qty': newQty}).eq('progress_item_id', itemId);
                }

                // 2. Call the RPC to finalize and stock in
                await _client.rpc(
                  'update_production_progress_status_full_for_app',
                  params: <String, dynamic>{
                    'p_progress_id': item['progress_id'],
                    'p_status': 'done',
                    'p_stage_key': 'finishing',
                    'p_proof_url': item['proof_url'] ?? item['proof_photo_url'],
                    'p_catatan': item['catatan'],
                  },
                );

                if (sheetContext.mounted) AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (e) {
                AppUi.showSnack(e.message);
              } catch (e) {
                AppUi.showSnack(AppUi.userMessage(e.toString()));
              } finally {
                if (sheetContext.mounted) setSheetState(() => saving = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    'Selesaikan & Stock In',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Masukkan kuantitas masuk riil per size. Stock lokal akan bertambah sesuai kuantitas ini.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  ...items.map((row) {
                    final itemId = AppUi.text(row['progress_item_id']);
                    final controller = controllers[itemId];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${AppUi.text(row['size_label'])} - ${AppUi.text(row['local_sku'])} (${AppUi.text(row['local_product_name'])}):',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 100,
                            child: TextField(
                              controller: controller,
                              keyboardType: TextInputType.number,
                              enabled: !saving,
                              decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: saving
                              ? null
                              : () => AppUi.safePop(sheetContext, false),
                          child: Text('Batal'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: saving ? null : submit,
                          icon: saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(Icons.inventory_2_outlined),
                          label: Text('Stock In'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    for (final controller in controllers.values) {
      Future.delayed(
          const Duration(milliseconds: 700), () => controller.dispose());
    }
    if (saved == true) _load();
  }

  Future<void> _deleteProgress(Map<String, dynamic> item) async {
    final bool isAllowedRole = _currentRoleId == 'platform_owner' ||
        _currentRoleId == 'super_admin' ||
        _currentRoleId == 'production' ||
        _currentRoleId == 'produksi';
    if (!isAllowedRole) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Hapus progress produksi?'),
        content: Text(
            'Menghapus Surat Jalan ini akan menghapus semua progress proses, catatan pembayaran pekerja, '
            'dan otomatis membatalkan penambahan stok barang di master SKU (jika sudah Done).\n\n'
            'Apakah Anda yakin ingin menghapus "${AppUi.text(item['surat_jalan_number'])}"?'),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext, false),
            child: Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => AppUi.safePop(dialogContext, true),
            icon: Icon(Icons.delete_outline),
            label: Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _client.rpc(
        'delete_production_progress_for_app',
        params: <String, dynamic>{'p_progress_id': item['progress_id']},
      );
      AppUi.showSnack('Progress produksi dihapus.');
      await _load();
    } on PostgrestException catch (e) {
      AppUi.showSnack(e.message);
    } catch (e) {
      AppUi.showSnack(AppUi.userMessage(e.toString()));
    }
  }

  Future<void> _editProgress(Map<String, dynamic> item) async {
    if (!_ensureCanWriteProduction()) return;
    final suratJalanNumber =
        TextEditingController(text: AppUi.text(item['surat_jalan_number']));
    final patternCode =
        TextEditingController(text: AppUi.text(item['pattern_code']));
    final note = TextEditingController(text: AppUi.text(item['catatan']));
    final customStageController = TextEditingController();
    DateTime productionDate =
        DateTime.tryParse(AppUi.text(item['production_date'])) ??
            DateTime.now();
    DateTime? targetDate =
        DateTime.tryParse(AppUi.text(item['target_finish_date']));
    bool saving = false;

    List<Map<String, dynamic>> dbStages = [];
    List<Map<String, dynamic>> availableStages =
        _buildEditableStageRows(dbStages);

    try {
      final stagesRes = await _client
          .from('production_progress_stages')
          .select('stage_key, stage_label, is_active, deleted_at')
          .eq('progress_id', item['progress_id']);
      dbStages = _mapList(stagesRes);
      availableStages = _buildEditableStageRows(dbStages);
    } catch (e) {
      debugPrint('Error loading stages: $e');
    }

    // Load initial size breakdown lines
    final initialItems = _mapList(item['items']);
    final lines = initialItems.map((itemRow) {
      final line = _ProductionLineInput();
      final pId = AppUi.text(itemRow['product_id']);
      final prod = _localProducts.firstWhereOrNull((p) => p.productId == pId) ??
          Product(
            productId: pId,
            kodeSku: AppUi.text(itemRow['size_label']),
            kodeBarcode: null,
            namaBarang:
                AppUi.text(itemRow['nama_barang'] ?? itemRow['size_label']),
            kategori: null,
            satuan: 'pcs',
            stockAwal: 0,
            stockSaatIni: 0,
            lowStockLimit: 0,
            lokasiRak: null,
            status: 'active',
          );
      line.product = prod;
      line.qtyController.text = AppUi.toNum(itemRow['qty']).toStringAsFixed(0);
      return line;
    }).toList();
    if (lines.isEmpty) {
      lines.add(_ProductionLineInput());
    }

    final uniquePatternCodes = _items
        .map((e) => AppUi.text(e['pattern_code']))
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    uniquePatternCodes.sort();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            num totalQty() => lines.fold<num>(0, (sum, line) => sum + line.qty);

            Future<void> submit() async {
              final manualSuratJalan = suratJalanNumber.text.trim();
              if (manualSuratJalan.isEmpty) {
                AppUi.showSnack('Nomor Surat Jalan wajib diisi.');
                return;
              }

              final validLines = lines
                  .where((line) =>
                      (line.productId ?? '').trim().isNotEmpty && line.qty > 0)
                  .toList();
              if (validLines.isEmpty) {
                AppUi.showSnack('Pilih minimal satu SKU lokal dan qty proses.');
                return;
              }

              try {
                setSheetState(() => saving = true);

                for (final stage in availableStages) {
                  final key = AppUi.text(stage['key']).trim();
                  if (key.isEmpty) continue;
                  final label = _editableStageLabel(stage).trim();
                  final isActive = stage['active'] == true;
                  final persisted = stage['persisted'] == true;
                  final originalActive = stage['originalActive'] == true;
                  final originalLabel =
                      AppUi.text(stage['originalLabel']).trim();
                  final labelChanged = label != originalLabel;

                  if (isActive) {
                    if (!persisted || !originalActive || labelChanged) {
                      await _client.rpc(
                        'set_production_stage_active_for_app',
                        params: <String, dynamic>{
                          'p_progress_id': item['progress_id'],
                          'p_stage_key': key,
                          'p_stage_label': label,
                        },
                      );
                      stage['persisted'] = true;
                      stage['originalActive'] = true;
                      stage['originalLabel'] = label;
                    }
                  } else if (persisted && originalActive) {
                    await _client.rpc(
                      'delete_production_progress_stage_for_app',
                      params: <String, dynamic>{
                        'p_progress_id': item['progress_id'],
                        'p_stage_key': key,
                      },
                    );
                    stage['originalActive'] = false;
                  }
                }

                final firstLine = validLines.first;
                final firstProductId = firstLine.productId;
                final firstProductName = firstLine.product?.namaBarang ?? '';
                final firstSku = firstLine.product?.kodeSku ?? '';

                await _client.from('production_progress').update({
                  'surat_jalan_number': manualSuratJalan,
                  'pattern_code': patternCode.text.trim(),
                  'production_date': _dateOnly(productionDate),
                  'target_finish_date':
                      targetDate == null ? null : _dateOnly(targetDate!),
                  'catatan': note.text.trim(),
                  'product_id': firstProductId,
                  'product_name': firstProductName,
                  'nama_barang': firstProductName,
                  'sku': firstSku,
                  'updated_at': DateTime.now().toIso8601String(),
                }).eq('progress_id', item['progress_id']);

                // Delete existing items
                await _client
                    .from('production_progress_items')
                    .delete()
                    .eq('progress_id', item['progress_id']);

                // Insert new/updated items
                int sortOrder = 0;
                final newItems = validLines.map((line) {
                  sortOrder++;
                  return <String, dynamic>{
                    'progress_id': item['progress_id'],
                    'tenant_id': _currentTenantId,
                    'product_id': line.productId,
                    'local_sku': line.product?.kodeSku ?? '',
                    'local_product_name': line.product?.namaBarang ?? '',
                    'local_product_barcode': line.product?.kodeBarcode,
                    'size_label': line.sizeLabel,
                    'qty': line.qty,
                    'sewing_price_per_pcs': 0,
                    'line_total': 0,
                    'sort_order': sortOrder,
                  };
                }).toList();

                await _client
                    .from('production_progress_items')
                    .insert(newItems);

                // Recalculate totals
                await _client.rpc(
                  'production_recalculate_progress_totals',
                  params: <String, dynamic>{
                    'p_progress_id': item['progress_id'],
                  },
                );

                if (sheetContext.mounted) AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (e) {
                AppUi.showSnack(e.message);
              } catch (e) {
                AppUi.showSnack(AppUi.userMessage(e.toString()));
              } finally {
                if (sheetContext.mounted) setSheetState(() => saving = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    'Edit Surat Jalan / Progress',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: suratJalanNumber,
                    enabled: !saving,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Nomor Surat Jalan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Autocomplete<String>(
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      if (textEditingValue.text.isEmpty) {
                        return uniquePatternCodes;
                      }
                      return uniquePatternCodes.where((String option) {
                        return option
                            .toLowerCase()
                            .contains(textEditingValue.text.toLowerCase());
                      });
                    },
                    initialValue: TextEditingValue(text: patternCode.text),
                    onSelected: (String selection) {
                      patternCode.text = selection;
                    },
                    optionsViewBuilder: (BuildContext context,
                        AutocompleteOnSelected<String> onSelected,
                        Iterable<String> options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4.0,
                          borderRadius: BorderRadius.circular(8),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: 200,
                              minWidth: MediaQuery.of(context).size.width - 32,
                              maxWidth: MediaQuery.of(context).size.width - 32,
                            ),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (BuildContext context, int index) {
                                final String option = options.elementAt(index);
                                return ListTile(
                                  title: Text(option),
                                  onTap: () => onSelected(option),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                    fieldViewBuilder:
                        (context, controller, focusNode, onEditingComplete) {
                      controller.addListener(() {
                        patternCode.text = controller.text;
                      });
                      if (controller.text.isEmpty &&
                          patternCode.text.isNotEmpty) {
                        controller.text = patternCode.text;
                      }
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        enabled: !saving,
                        decoration: const InputDecoration(
                          labelText: 'Kode Pola (Pilih atau Ketik Manual)',
                          border: OutlineInputBorder(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () async {
                                  final picked =
                                      await _pickDate(productionDate);
                                  if (picked != null) {
                                    setSheetState(
                                        () => productionDate = picked);
                                  }
                                },
                          icon: Icon(Icons.event_outlined),
                          label: Text('Mulai: ${AppUi.date(productionDate)}'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () async {
                                  final picked = await _pickDate(targetDate);
                                  if (picked != null) {
                                    setSheetState(() => targetDate = picked);
                                  }
                                },
                          icon: Icon(Icons.flag_outlined),
                          label: Text(targetDate == null
                              ? 'Target: -'
                              : 'Target: ${AppUi.date(targetDate!)}'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text('Breakdown Size',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  if (_localProducts.isEmpty)
                    const EmptyState(
                      title: 'SKU lokal belum ada',
                      subtitle:
                          'Tambahkan produk/SKU lokal aktif dulu di menu stok.',
                      icon: Icons.inventory_2_outlined,
                    )
                  else
                    ...lines.map((line) {
                      return _lineEditor(
                        context: sheetContext,
                        line: line,
                        canRemove: lines.length > 1,
                        saving: saving,
                        onChanged: () => setSheetState(() {}),
                        onRemove: () {
                          setSheetState(() {
                            line.dispose();
                            lines.remove(line);
                          });
                        },
                      );
                    }),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: saving
                          ? null
                          : () => setSheetState(
                              () => lines.add(_ProductionLineInput())),
                      icon: Icon(Icons.add_circle_outline),
                      label: Text('Tambah size'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _miniMetric('Total qty', totalQty().toStringAsFixed(0)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text('Progress Proses',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  ...availableStages.map((stage) {
                    final key = AppUi.text(stage['key']);
                    final label = _editableStageLabel(stage);
                    final active = stage['active'] == true;
                    final persisted = stage['persisted'] == true;
                    final originalActive = stage['originalActive'] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(sheetContext)
                              .dividerColor
                              .withOpacity(0.35),
                        ),
                        color: active
                            ? Theme.of(sheetContext)
                                .colorScheme
                                .primary
                                .withOpacity(0.06)
                            : Theme.of(sheetContext)
                                .colorScheme
                                .surfaceVariant
                                .withOpacity(0.3),
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            value: active,
                            onChanged: saving
                                ? null
                                : (bool? value) {
                                    setSheetState(() {
                                      stage['active'] = value ?? false;
                                    });
                                  },
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    decoration: active
                                        ? null
                                        : TextDecoration.lineThrough,
                                  ),
                                ),
                                Text(
                                  '${persisted ? 'Tersimpan' : 'Baru'} · ${originalActive ? 'aktif sebelumnya' : 'nonaktif sebelumnya'} · key: $key',
                                  style: Theme.of(sheetContext)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(sheetContext)
                                            .colorScheme
                                            .onSurface
                                            .withOpacity(0.62),
                                      ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Edit label',
                            icon: Icon(Icons.edit_outlined),
                            onPressed: saving
                                ? null
                                : () async {
                                    final edited =
                                        await _editStageLabelDialog(label);
                                    if (edited == null ||
                                        edited.trim().isEmpty ||
                                        !sheetContext.mounted) {
                                      return;
                                    }
                                    setSheetState(() {
                                      stage['label'] = edited.trim();
                                    });
                                  },
                          ),
                          IconButton(
                            tooltip: 'Hapus / nonaktifkan',
                            icon: Icon(Icons.delete_outline),
                            color: Colors.red,
                            onPressed: saving
                                ? null
                                : () {
                                    setSheetState(() {
                                      stage['active'] = false;
                                    });
                                  },
                          ),
                        ],
                      ),
                    );
                  }),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: customStageController,
                          enabled: !saving,
                          decoration: const InputDecoration(
                            labelText: 'Tambah progress custom',
                            hintText: 'Misal: bordir, sablon',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline),
                        onPressed: saving
                            ? null
                            : () {
                                final text = customStageController.text.trim();
                                if (text.isEmpty) return;
                                final key = _normalizeStageKey(text);
                                if (key.isEmpty) {
                                  AppUi.showSnack('Nama progress tidak valid.');
                                  return;
                                }
                                final existing =
                                    availableStages.firstWhereOrNull(
                                  (stage) => AppUi.text(stage['key']) == key,
                                );
                                setSheetState(() {
                                  if (existing == null) {
                                    availableStages.add(<String, dynamic>{
                                      'key': key,
                                      'label': text,
                                      'active': true,
                                      'persisted': false,
                                      'originalLabel': '',
                                      'originalActive': false,
                                    });
                                  } else if (existing['active'] == true) {
                                    AppUi.showSnack(
                                        'Progress "$text" sudah ada.');
                                  } else {
                                    existing
                                      ..['label'] = text
                                      ..['active'] = true;
                                  }
                                  customStageController.clear();
                                });
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    enabled: !saving,
                    decoration: const InputDecoration(
                      labelText: 'Catatan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.save_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Simpan Perubahan'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future.delayed(const Duration(milliseconds: 700), () {
      suratJalanNumber.dispose();
      patternCode.dispose();
      note.dispose();
      customStageController.dispose();
      for (final line in lines) {
        line.dispose();
      }
    });
    if (saved == true) _load();
  }

  Future<void> _showTailorSheet({Map<String, dynamic>? tailor}) async {
    final name =
        TextEditingController(text: AppUi.text(tailor?['tailor_name'], ''));
    final phone = TextEditingController(text: AppUi.text(tailor?['phone'], ''));
    final note = TextEditingController(text: AppUi.text(tailor?['note'], ''));
    String status = AppUi.text(tailor?['status'], 'active');
    bool saving = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> submit() async {
              if (name.text.trim().isEmpty) {
                AppUi.showSnack('Nama penjahit wajib diisi.');
                return;
              }
              try {
                setSheetState(() => saving = true);
                await _client.rpc(
                  'upsert_production_tailor_for_app',
                  params: <String, dynamic>{
                    'p_tailor_id': tailor?['tailor_id'],
                    'p_tailor_name': name.text.trim(),
                    'p_phone': phone.text.trim(),
                    'p_note': note.text.trim(),
                    'p_status': status,
                  },
                );
                if (sheetContext.mounted) AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (e) {
                AppUi.showSnack(e.message);
              } catch (e) {
                AppUi.showSnack(AppUi.userMessage(e.toString()));
              } finally {
                if (sheetContext.mounted) setSheetState(() => saving = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    tailor == null ? 'Tambah Penjahit' : 'Edit Penjahit',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 12),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Nama penjahit',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 10),
                  TextField(
                    controller: phone,
                    decoration: const InputDecoration(
                      labelText: 'Nomor HP',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: status == 'inactive' ? 'inactive' : 'active',
                    decoration: const InputDecoration(
                      labelText: 'Status',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'active', child: Text('Aktif')),
                      DropdownMenuItem(
                          value: 'inactive', child: Text('Nonaktif')),
                    ],
                    onChanged: saving
                        ? null
                        : (value) =>
                            setSheetState(() => status = value ?? 'active'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Catatan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.save_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Simpan Penjahit'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 500), () {
      name.dispose();
      phone.dispose();
      note.dispose();
    });
    if (saved == true) _load();
  }

  Future<void> _deleteTailor(Map<String, dynamic> tailor) async {
    final tailorId = AppUi.text(tailor['tailor_id'], '');
    if (tailorId.isEmpty) {
      AppUi.showSnack('ID penjahit tidak valid.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus penjahit?'),
        content: Text(
          'Penjahit "${AppUi.text(tailor['tailor_name'])}" akan dihapus dari daftar. Histori produksi lama tetap aman.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Batal'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            icon: Icon(Icons.delete_outline),
            label: Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final result = await _client.rpc(
        'delete_production_tailor_for_app',
        params: <String, dynamic>{'p_tailor_id': tailorId},
      );
      final action = AppUi.text(_map(result)['action'], 'deleted');
      AppUi.showSnack(action == 'hard_deleted'
          ? 'Penjahit dihapus permanen.'
          : 'Penjahit dihapus dari daftar. Histori lama tetap tersimpan.');
      await _load();
    } on PostgrestException catch (e) {
      AppUi.showSnack(e.message);
    } catch (e) {
      AppUi.showSnack(AppUi.userMessage(e.toString()));
    }
  }

  Future<void> _showMaterialPurchaseSheet({
    Map<String, dynamic>? purchase,
  }) async {
    final supplierName =
        TextEditingController(text: AppUi.text(purchase?['supplier_name'], ''));
    final note = TextEditingController();
    final rawNote = AppUi.text(purchase?['catatan'], '');
    if (rawNote.isNotEmpty && !rawNote.startsWith('[production_material]')) {
      note.text = rawNote;
    }
    String paymentStatus =
        AppUi.text(purchase?['payment_status'], 'belum_bayar');
    DateTime purchaseDate = DateTime.tryParse(
          AppUi.text(purchase?['actual_date'], ''),
        ) ??
        DateTime.tryParse(AppUi.text(purchase?['tanggal'], '')) ??
        DateTime.now();
    PhotoEvidence? proofEvidence;
    final initialPhotoUrl = AppUi.text(
      purchase?['photo_url'] ?? purchase?['nota_url'] ?? purchase?['bukti_url'],
      '',
    );
    bool saving = false;

    final existingLines = _mapList(purchase?['items']);
    final lines = existingLines.isEmpty
        ? <_MaterialPurchaseLineInput>[_MaterialPurchaseLineInput()]
        : existingLines.map((row) {
            final line = _MaterialPurchaseLineInput();
            final productId = AppUi.text(row['product_id'], '');
            line.nameController.text = AppUi.text(
              row['nama_barang'] ?? row['nama_barang_manual'],
              '',
            );
            line.qtyController.text = AppUi.moneyInput(AppUi.toNum(row['qty']));
            line.priceController.text = AppUi.moneyInput(
              AppUi.toNum(row['harga_item'] ?? row['harga_per_item']),
            );
            line.satuanController.text = AppUi.text(row['satuan'], 'pcs');
            line.noteController.text = AppUi.text(row['catatan'], '');
            return line;
          }).toList();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            num totalAmount() =>
                lines.fold<num>(0, (sum, line) => sum + line.total);

            Future<void> submit() async {
              final validLines = lines
                  .where((line) =>
                      line.nameController.text.trim().isNotEmpty &&
                      line.qty > 0)
                  .toList();
              if (validLines.isEmpty) {
                AppUi.showSnack('Isi minimal satu item pembelian bahan.');
                return;
              }
              if (paymentStatus == 'sudah_bayar' &&
                  proofEvidence == null &&
                  initialPhotoUrl.isEmpty) {
                AppUi.showSnack(
                    'Bukti nota/foto wajib diisi untuk pembelian sudah bayar.');
                return;
              }

              try {
                setSheetState(() => saving = true);
                await _client.rpc(
                  'upsert_production_material_purchase_for_app',
                  params: <String, dynamic>{
                    'p_purchase_id': purchase?['purchase_id'],
                    'p_supplier_id': null,
                    'p_supplier_name': supplierName.text.trim(),
                    'p_purchase_date': _dateOnly(purchaseDate),
                    'p_finance_month': _dateOnly(_activeMonth),
                    'p_payment_status': paymentStatus,
                    'p_note': note.text.trim(),
                    'p_photo_url': proofEvidence?.publicUrl ?? initialPhotoUrl,
                    'p_latitude': proofEvidence?.latitude,
                    'p_longitude': proofEvidence?.longitude,
                    'p_items': validLines.map((line) {
                      return <String, dynamic>{
                        'product_id': null,
                        'kode_sku': null,
                        'kode_barcode': null,
                        'nama_barang': line.nameController.text.trim(),
                        'nama_barang_manual': line.nameController.text.trim(),
                        'qty': line.qty,
                        'satuan': line.satuanController.text.trim().isEmpty
                            ? 'pcs'
                            : line.satuanController.text.trim(),
                        'harga_item': line.price,
                        'stock_in': false,
                        'catatan': line.noteController.text.trim(),
                      };
                    }).toList(),
                  },
                );
                if (sheetContext.mounted) AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (e) {
                AppUi.showSnack(e.message);
              } catch (e) {
                AppUi.showSnack(AppUi.userMessage(e.toString()));
              } finally {
                if (sheetContext.mounted) setSheetState(() => saving = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    purchase == null
                        ? 'Pembelian Bahan / Barang'
                        : 'Edit Pembelian Bahan',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 12),
                  TextField(
                    controller: supplierName,
                    decoration: const InputDecoration(
                      labelText: 'Supplier / toko',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () async {
                                  final picked = await _pickDate(purchaseDate);
                                  if (picked != null && sheetContext.mounted) {
                                    setSheetState(() => purchaseDate = picked);
                                  }
                                },
                          icon: Icon(Icons.event_outlined),
                          label: Text(AppUi.date(purchaseDate)),
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: paymentStatus,
                          decoration: const InputDecoration(
                            labelText: 'Status bayar',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 'sudah_bayar',
                                child: Text('Sudah bayar')),
                            DropdownMenuItem(
                                value: 'belum_bayar',
                                child: Text('Belum bayar')),
                          ],
                          onChanged: saving
                              ? null
                              : (value) => setSheetState(
                                  () => paymentStatus = value ?? 'belum_bayar'),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 14),
                  Text('Item pembelian',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  SizedBox(height: 8),
                  ...lines.map((line) => _materialLineEditor(
                        context: sheetContext,
                        line: line,
                        canRemove: lines.length > 1,
                        saving: saving,
                        onChanged: () => setSheetState(() {}),
                        onRemove: () {
                          setSheetState(() {
                            line.dispose();
                            lines.remove(line);
                          });
                        },
                      )),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: saving
                          ? null
                          : () => setSheetState(
                              () => lines.add(_MaterialPurchaseLineInput())),
                      icon: Icon(Icons.add_circle_outline),
                      label: Text('Tambah item'),
                    ),
                  ),
                  _miniMetric('Total pembelian', AppUi.rupiah(totalAmount())),
                  SizedBox(height: 12),
                  EvidenceCameraField(
                    label: 'Bukti nota / barang',
                    moduleName: 'production_material_purchase',
                    purpose: 'purchase_proof',
                    allowGallery: true,
                    referenceId: purchase?['purchase_id']?.toString(),
                    initialPhotoUrl: initialPhotoUrl,
                    helperText: 'Bisa foto kamera atau pilih dari galeri.',
                    onUploaded: (evidence) {
                      proofEvidence = evidence;
                      if (sheetContext.mounted) setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Catatan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.save_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Simpan Pembelian'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 500), () {
      supplierName.dispose();
      note.dispose();
      for (final line in lines) {
        line.dispose();
      }
    });
    if (saved == true) _load();
  }

  Widget _materialLineEditor({
    required BuildContext context,
    required _MaterialPurchaseLineInput line,
    required bool canRemove,
    required bool saving,
    required VoidCallback onChanged,
    required VoidCallback onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NiceCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: line.nameController,
                    decoration: const InputDecoration(
                      labelText: 'Nama bahan / barang',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                if (canRemove)
                  IconButton(
                    tooltip: 'Hapus item',
                    onPressed: saving ? null : onRemove,
                    icon: Icon(Icons.remove_circle_outline),
                  ),
              ],
            ),
            SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: line.qtyController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Qty',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: line.satuanController,
                    decoration: const InputDecoration(
                      labelText: 'Satuan',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10),
            TextField(
              controller: line.priceController,
              keyboardType: TextInputType.number,
              inputFormatters: const [AppMoneyInputFormatter()],
              decoration: const InputDecoration(
                labelText: 'Harga/item',
                prefixText: 'Rp ',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => onChanged(),
            ),
            TextField(
              controller: line.noteController,
              decoration: const InputDecoration(
                labelText: 'Catatan item',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Total ${AppUi.rupiah(line.total)}',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMaterialPurchase(Map<String, dynamic> purchase) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Hapus pembelian produksi?'),
        content: Text(
          '${AppUi.text(purchase['supplier_name'], 'Pembelian')} - ${AppUi.rupiah(AppUi.toNum(purchase['total_pembelian']))}',
        ),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext, false),
            child: Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => AppUi.safePop(dialogContext, true),
            icon: Icon(Icons.delete_outline),
            label: Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _client.rpc(
        'delete_production_material_purchase_for_app',
        params: <String, dynamic>{'p_purchase_id': purchase['purchase_id']},
      );
      AppUi.showSnack('Pembelian bahan produksi dihapus.');
      await _load();
    } on PostgrestException catch (e) {
      AppUi.showSnack(e.message);
    } catch (e) {
      AppUi.showSnack(AppUi.userMessage(e.toString()));
    }
  }

  CellValue _excelCell(dynamic value) {
    if (value == null) return TextCellValue('');
    if (value is num) return TextCellValue(value.toString());
    if (value is bool) return TextCellValue(value ? 'TRUE' : 'FALSE');
    return TextCellValue(value.toString());
  }

  void _appendExcelSheet(
    Excel workbook,
    String sheetName,
    List<Map<String, dynamic>> rows,
  ) {
    final cleanName =
        sheetName.length > 31 ? sheetName.substring(0, 31) : sheetName;
    final sheet = workbook[cleanName];
    final headers = <String>[];
    for (final row in rows) {
      for (final key in row.keys) {
        if (!headers.contains(key)) headers.add(key);
      }
    }
    if (headers.isEmpty) {
      sheet.appendRow(<CellValue>[TextCellValue('empty')]);
      return;
    }
    sheet.appendRow(
        headers.map<CellValue>((key) => TextCellValue(key)).toList());
    for (final row in rows) {
      sheet.appendRow(headers.map<CellValue>((key) {
        final value = row[key];
        if (value is List || value is Map)
          return TextCellValue(value.toString());
        return _excelCell(value);
      }).toList());
    }
  }

  Future<File> _exportProductionMonthExcel() async {
    final workbook = Excel.createExcel();

    // Summary Sheet
    final summaryRows = <Map<String, dynamic>>[
      {
        'Bulan': _monthLabel(_activeMonth),
        'Total Deposit Awal': AppUi.toNum(_summary['deposit_total']),
        'Paid Sewing Total': AppUi.toNum(_summary['paid_total']),
        'Unpaid Sewing Total': AppUi.toNum(_summary['unpaid_total']),
        'Material Paid Total': AppUi.toNum(_summary['material_paid_total']),
        'Kasbon Active Total': AppUi.toNum(_summary['kasbon_active_total']),
        'Saldo Akhir (Deposit Remaining)':
            AppUi.toNum(_summary['deposit_remaining_total']),
        'Progress Count': AppUi.toNum(_summary['progress_count']),
        'Done Count': AppUi.toNum(_summary['done_count']),
        'Export Date': DateTime.now().toIso8601String(),
      }
    ];
    _appendExcelSheet(workbook, 'summary', summaryRows);

    // Progress Sheet with Item Breakdown
    final progressRows = <Map<String, dynamic>>[];
    for (final item in _items) {
      final items = _mapList(item['items']);
      if (items.isEmpty) {
        progressRows.add({
          'Progress ID': item['progress_id'],
          'Pattern Code': item['pattern_code'],
          'Tailor': item['tailor_name'],
          'Date': AppUi.date(item['production_date']),
          'Status': item['status'],
          'Total Qty': AppUi.toNum(item['qty']),
          'Sewing Price/Pcs': AppUi.toNum(item['sewing_price_per_pcs']),
          'Total Amount': AppUi.toNum(item['sewing_total_amount']),
          'Paid': AppUi.toNum(item['payment_paid_amount']),
          'Unpaid': AppUi.toNum(item['payment_unpaid_amount']),
          'Size': '-',
          'SKU': '-',
          'Item Qty': '-',
        });
      } else {
        for (final detail in items) {
          progressRows.add({
            'Progress ID': item['progress_id'],
            'Pattern Code': item['pattern_code'],
            'Tailor': item['tailor_name'],
            'Date': AppUi.date(item['production_date']),
            'Status': item['status'],
            'Total Qty': AppUi.toNum(item['qty']),
            'Total Amount': AppUi.toNum(item['sewing_total_amount']),
            'Paid': AppUi.toNum(item['payment_paid_amount']),
            'Unpaid': AppUi.toNum(item['payment_unpaid_amount']),
            'Size': detail['size_label'],
            'SKU': detail['local_sku'],
            'Item Qty': detail['qty'],
            'Item Price/Pcs': detail['sewing_price_per_pcs'],
          });
        }
      }
    }
    _appendExcelSheet(workbook, 'progress_details', progressRows);

    // Deposit Sheet
    _appendExcelSheet(workbook, 'deposits', _deposits);

    // Material Purchases Sheet
    final purchaseRows = <Map<String, dynamic>>[];
    for (final p in _materialPurchases) {
      final items = _mapList(p['items']);
      for (final it in items) {
        purchaseRows.add({
          'Purchase ID': p['purchase_id'],
          'Supplier': p['supplier_name'],
          'Date': AppUi.date(p['actual_date'] ?? p['tanggal']),
          'Status': p['payment_status'],
          'Total Purchase': AppUi.toNum(p['total_pembelian']),
          'Item Name': it['nama_barang'] ?? it['nama_barang_manual'],
          'Qty': it['qty'],
          'Unit': it['satuan'],
          'Price': it['harga_item'],
          'Stock In': it['stock_in'],
          'Note': it['catatan'],
        });
      }
    }
    _appendExcelSheet(workbook, 'material_purchases', purchaseRows);

    // Payments & Kasbon Sheet
    final paymentRows = <Map<String, dynamic>>[];
    for (final progress in _items) {
      for (final payment in _mapList(progress['payments'])) {
        paymentRows.add(<String, dynamic>{
          'Type': _getPaymentDisplayLabel(payment),
          'Tailor': progress['tailor_name'],
          'Ref Pattern': progress['pattern_code'],
          'Amount': AppUi.toNum(payment['amount']),
          'Date': AppUi.date(payment['payment_date']),
          'Status': payment['payment_status'],
          'Note': payment['note'],
          'Progress ID': progress['progress_id'],
        });
      }
    }
    // Add standalone kasbon from tailors if not linked to progress
    for (final tailor in _tailorCards) {
      final tailorId = tailor['tailor_id'];
      final tailorName = tailor['tailor_name'];
      // We'd need to fetch standalone payments if any, but the current _items covers most.
      // For now, ensure we have a Tailor Summary sheet.
    }
    _appendExcelSheet(workbook, 'ledger_payments', paymentRows);

    // Tailor Summary Sheet
    _appendExcelSheet(workbook, 'tailor_summary', _tailorCards);

    final defaultSheet = workbook.getDefaultSheet();
    if (defaultSheet != null && workbook.tables.length > 1) {
      workbook.delete(defaultSheet);
    }

    final bytes = workbook.save();
    if (bytes == null) throw Exception('Gagal membuat file XLSX.');

    final dir = await getApplicationDocumentsDirectory();
    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final file = File(
      '${dir.path}/arsip_produksi_${_activeMonth.year}_${_activeMonth.month.toString().padLeft(2, '0')}_$stamp.xlsx',
    );
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'Arsip Produksi ${_monthLabel(_activeMonth)}',
      text: 'File arsip produksi berhasil dibuat.',
    );
    return file;
  }

  Future<void> _downloadProductionArchive() async {
    try {
      final file = await _exportProductionMonthExcel();
      AppUi.showSnack('Arsip Excel dibuat: ${file.path}');
    } catch (e) {
      AppUi.showSnack(AppUi.userMessage(e.toString()));
    }
  }

  Future<void> _resetActiveMonth() async {
    if (!_isSuperAdmin) {
      AppUi.showSnack('Reset bulanan hanya untuk Super Admin.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Reset ${_monthLabel(_activeMonth)}?'),
        content: Text(
          'Aplikasi akan membuat file Excel dulu. Setelah export berhasil, data produksi bulan ini dan finance terkait akan dihapus dari database.',
        ),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext, false),
            child: Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => AppUi.safePop(dialogContext, true),
            icon: Icon(Icons.download_outlined),
            label: Text('Export lalu Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _exportProductionMonthExcel();
      final result = await _client.rpc(
        'reset_production_month_after_export_for_app',
        params: <String, dynamic>{
          'p_month': _dateOnly(_activeMonth),
          'p_export_confirmed': true,
        },
      );
      AppUi.showSnack('Reset bulanan selesai: ${AppUi.text(result)}');
      await _load();
    } on PostgrestException catch (e) {
      AppUi.showSnack(e.message);
    } catch (e) {
      AppUi.showSnack(AppUi.userMessage(e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: LoadingState());

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text('Produksi Berjalan')),
        body: ErrorState(message: _error!, onRetry: _load),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Produksi Berjalan'),
          actions: [
            IconButton(onPressed: _load, icon: Icon(Icons.refresh)),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.assignment_outlined), text: 'Progress'),
              Tab(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  text: 'Keuangan'),
              Tab(icon: Icon(Icons.people_outline), text: 'Pekerja'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _createProgress,
          icon: Icon(Icons.add),
          label: Text('Progress'),
        ),
        body: TabBarView(
          children: [
            // Tab 1: Surat Jalan
            RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  FuturisticHeader(
                    icon: Icons.precision_manufacturing_outlined,
                    title: 'Produksi Berjalan',
                    subtitle:
                        'Pantau potong kain, jahit, finishing, pembayaran penjahit, dan stock-in otomatis per SKU lokal.',
                    stats: [
                      StatPill(
                          label: 'Progress',
                          value: AppUi.toNum(_summary['progress_count'])
                              .toStringAsFixed(0)),
                      StatPill(
                          label: 'Done',
                          value: AppUi.toNum(_summary['done_count'])
                              .toStringAsFixed(0)),
                      StatPill(
                          label: 'Kasbon',
                          value: AppUi.rupiah(
                              AppUi.toNum(_summary['kasbon_active_total']))),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SearchBox(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    hint: 'Cari produk, SKU, kode pola, penjahit',
                  ),
                  const SizedBox(height: 12),
                  _filters(),
                  const SizedBox(height: 14),
                  if (_items.isEmpty)
                    const EmptyState(
                      title: 'Belum ada data',
                      subtitle: 'Tambah progress produksi dari tombol bawah.',
                      icon: Icons.precision_manufacturing_outlined,
                    )
                  else
                    ..._items.map(_progressCard),
                ],
              ),
            ),
            // Tab 2: Keuangan
            RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _monthToolbar(),
                  const SizedBox(height: 14),
                  _summaryGrid(),
                  const SizedBox(height: 14),
                  _depositLedger(),
                  const SizedBox(height: 14),
                  _materialPurchaseSection(),
                ],
              ),
            ),
            // Tab 3: Pekerja
            RefreshIndicator(
              onRefresh: _load,
              child: _tailorDashboard(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _monthToolbar() {
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Bulan produksi',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    SizedBox(height: 4),
                    Text(
                      '${_monthLabel(_activeMonth)} (${AppUi.date(_activeMonth)} - ${AppUi.date(_monthEnd(_activeMonth))})',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Pilih bulan',
                onPressed: _pickActiveMonth,
                icon: Icon(Icons.calendar_month_outlined),
              ),
            ],
          ),
          SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _showPaymentSheet(initialType: 'deposit'),
                icon: Icon(Icons.account_balance_wallet_outlined),
                label: Text('Deposit awal'),
              ),
              OutlinedButton.icon(
                onPressed: () => _showMaterialPurchaseSheet(),
                icon: Icon(Icons.shopping_cart_checkout_outlined),
                label: Text('Pembelian bahan'),
              ),
              OutlinedButton.icon(
                onPressed: _downloadProductionArchive,
                icon: Icon(Icons.file_download_outlined),
                label: Text('Excel'),
              ),
              if (_isSuperAdmin)
                OutlinedButton.icon(
                  onPressed: _resetActiveMonth,
                  icon: Icon(Icons.restart_alt_outlined),
                  label: Text('Reset bulan'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryGrid() {
    final metrics = [
      (
        'Total deposit awal',
        AppUi.rupiah(AppUi.toNum(_summary['deposit_total'])),
        Icons.savings_outlined,
        AppUi.teal,
        'Total saldo awal bulan ini.'
      ),
      (
        'Ongkos jahit (paid)',
        AppUi.rupiah(AppUi.toNum(_summary['paid_total'])),
        Icons.payments_outlined,
        AppUi.green,
        'Ongkos jahit yang sudah dibayar.'
      ),
      (
        'Pembelian bahan (paid)',
        AppUi.rupiah(AppUi.toNum(_summary['material_paid_total'])),
        Icons.shopping_basket_outlined,
        AppUi.pink,
        'Bahan baku yang sudah lunas.'
      ),
      (
        'Kasbon aktif',
        AppUi.rupiah(AppUi.toNum(_summary['kasbon_active_total'])),
        Icons.money_off_csred_outlined,
        AppUi.orange,
        'Saldo kasbon penjahit yang belum dipotong.'
      ),
      (
        'Saldo deposit',
        AppUi.rupiah(AppUi.toNum(_summary['deposit_remaining_total'])),
        Icons.account_balance_wallet_outlined,
        AppUi.blue,
        'Sisa saldo: Deposit - (Jahit + Bahan + Kasbon).'
      ),
      (
        'Belum dibayar',
        AppUi.rupiah(AppUi.toNum(_summary['unpaid_total'])),
        Icons.pending_actions_outlined,
        AppUi.mutedText(context, 0.92),
        'Kewajiban ongkos jahit yang belum lunas.'
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth > 620;
        final width =
            twoColumns ? (constraints.maxWidth - 10) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: metrics.map((metric) {
            return SizedBox(
              width: width,
              child: Tooltip(
                message: metric.$5,
                child: NiceCard(
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: metric.$4.withOpacity(0.12),
                        child: Icon(metric.$3, color: metric.$4),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(metric.$1,
                                style: TextStyle(fontWeight: FontWeight.w800)),
                            SizedBox(height: 4),
                            Text(metric.$2,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: metric.$1 == 'Saldo deposit' &&
                                                AppUi.toNum(_summary[
                                                        'deposit_remaining_total']) <
                                                    0
                                            ? AppUi.red
                                            : null)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _depositLedger() {
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SectionTitle(title: 'Ledger Deposit Awal'),
              ),
              TextButton.icon(
                onPressed: () => _showPaymentSheet(initialType: 'deposit'),
                icon: Icon(Icons.add_circle_outline),
                label: Text('Tambah'),
              ),
            ],
          ),
          SizedBox(height: 8),
          if (_deposits.isEmpty)
            const EmptyState(
              title: 'Deposit belum ada',
              subtitle: 'Tambahkan saldo awal bulan produksi dari tombol ini.',
              icon: Icons.savings_outlined,
            )
          else
            ..._deposits.map((deposit) {
              final statusText = AppUi.text(deposit['payment_status']);
              final statusColor = AppUi.statusColor(statusText);
              final proofUrl = AppUi.text(deposit['proof_url'], '');
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceVariant
                      .withOpacity(0.4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withOpacity(0.5),
                      width: 0.8),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppUi.teal.withOpacity(0.08),
                        border: Border.all(
                            color: AppUi.teal.withOpacity(0.16), width: 0.8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.savings_outlined, color: AppUi.teal),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              AppUi.text(
                                      deposit['note'], 'Deposit awal produksi')
                                  .toUpperCase(),
                              style: TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 12)),
                          Text(AppUi.rupiah(AppUi.toNum(deposit['amount'])),
                              style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                          Text('${AppUi.date(deposit['payment_date'])}'),
                          if (proofUrl.isNotEmpty)
                            Text('Bukti: $proofUrl',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                            color: statusColor.withOpacity(0.30), width: 0.8),
                      ),
                      child: Text(statusText,
                          style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 11)),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') {
                          _showPaymentSheet(
                            payment: deposit,
                            initialType: 'deposit',
                          );
                        }
                        if (value == 'delete') _deletePayment(deposit);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Hapus')),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _materialPurchaseSection() {
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SectionTitle(title: 'Pembelian Bahan / Barang'),
              ),
              TextButton.icon(
                onPressed: () => _showMaterialPurchaseSheet(),
                icon: Icon(Icons.add_circle_outline),
                label: Text('Tambah'),
              ),
            ],
          ),
          SizedBox(height: 8),
          if (_materialPurchases.isEmpty)
            const EmptyState(
              title: 'Belum ada pembelian bahan',
              subtitle:
                  'Pembelian paid akan mengurangi saldo deposit bulan aktif.',
              icon: Icons.shopping_basket_outlined,
            )
          else
            ..._materialPurchases.map((purchase) {
              final paid =
                  AppUi.text(purchase['payment_status']) == 'sudah_bayar';
              final statusColor = paid ? AppUi.green : AppUi.orange;
              final items = _mapList(purchase['items']);
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.fromBorderSide(AppUi.softBorderSide(context)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            AppUi.text(
                                purchase['supplier_name'], 'Supplier manual'),
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                                color: statusColor.withOpacity(0.30),
                                width: 0.8),
                          ),
                          child: Text(
                            paid ? 'sudah_bayar' : 'belum_bayar',
                            style: TextStyle(
                                color: statusColor,
                                fontWeight: FontWeight.w800,
                                fontSize: 11),
                          ),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') {
                              _showMaterialPurchaseSheet(purchase: purchase);
                            }
                            if (value == 'delete') {
                              _deleteMaterialPurchase(purchase);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(
                                value: 'delete', child: Text('Hapus')),
                          ],
                        ),
                      ],
                    ),
                    SizedBox(height: 4),
                    Text(
                      '${AppUi.date(purchase['actual_date'] ?? purchase['tanggal'])} - ${AppUi.rupiah(AppUi.toNum(purchase['total_pembelian']))}',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: items.take(6).map((item) {
                        return _miniMetric(
                          AppUi.text(item['nama_barang'],
                              AppUi.text(item['nama_barang_manual'], 'Item')),
                          '${AppUi.money(AppUi.toNum(item['qty']))} ${AppUi.text(item['satuan'], 'pcs')}',
                        );
                      }).toList(),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _filters() {
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: DropdownButtonFormField<String>(
            value: _tailorFilter,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Penjahit',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: 'all', child: Text('Semua')),
              ..._tailors.map((tailor) => DropdownMenuItem<String>(
                    value: AppUi.text(tailor['tailor_id'], ''),
                    child: Text(AppUi.text(tailor['tailor_name']),
                        overflow: TextOverflow.ellipsis),
                  )),
            ],
            onChanged: (value) {
              setState(() => _tailorFilter = value ?? 'all');
              _load();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            value: _statusFilter,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Status',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Semua')),
              DropdownMenuItem(value: 'progress', child: Text('Progress')),
              DropdownMenuItem(value: 'done', child: Text('Done')),
              DropdownMenuItem(value: 'cancelled', child: Text('Batal')),
            ],
            onChanged: (value) {
              setState(() => _statusFilter = value ?? 'all');
              _load();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            value: _paymentFilter,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Bayar',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Semua')),
              DropdownMenuItem(value: 'sudah_bayar', child: Text('Sudah')),
              DropdownMenuItem(value: 'belum_bayar', child: Text('Belum')),
            ],
            onChanged: (value) {
              setState(() => _paymentFilter = value ?? 'all');
              _load();
            },
          ),
        ),
      ],
    );
  }

  Widget _tailorDashboard() {
    final byId = <String, Map<String, dynamic>>{};
    for (final tailor in _tailors) {
      final id = AppUi.text(tailor['tailor_id'], '');
      if (id.isNotEmpty) byId[id] = Map<String, dynamic>.from(tailor);
    }
    for (final tailor in _tailorCards) {
      final id = AppUi.text(tailor['tailor_id'], '');
      if (id.isEmpty) continue;
      byId[id] = <String, dynamic>{
        ...?byId[id],
        ...tailor,
      };
    }
    final visibleTailors = byId.values
        .where((tailor) => AppUi.text(tailor['status'], 'active') != 'deleted')
        .toList()
      ..sort((a, b) => AppUi.text(a['tailor_name'])
          .toLowerCase()
          .compareTo(AppUi.text(b['tailor_name']).toLowerCase()));

    debugPrint(
        'DEBUG TAILORS: _tailors=${_tailors.length}, _tailorCards=${_tailorCards.length}, byId=${byId.length}, visibleTailors=${visibleTailors.length}');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Rekap Pekerja',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            FilledButton.icon(
              onPressed: () => _showTailorSheet(),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              icon: Icon(Icons.add),
              label: Text('Tambah Pekerja'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (visibleTailors.isEmpty)
          const EmptyState(
            title: 'Belum ada pekerja',
            subtitle: 'Klik tombol di atas untuk menambah pekerja baru.',
            icon: Icons.people_outline,
          )
        else
          ...visibleTailors.map((tailor) {
            final status = AppUi.text(tailor['status'], 'active');
            return NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(AppUi.text(tailor['tailor_name']),
                            style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      if (status == 'inactive')
                        Chip(
                          label: Text('Nonaktif'),
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .secondary
                              .withOpacity(.14),
                          side: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .secondary
                                .withOpacity(.45),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: () => _showTailorSheet(tailor: tailor),
                        icon: Icon(Icons.edit_outlined),
                        label: Text('Edit'),
                      ),
                      TextButton.icon(
                        onPressed: () => _deleteTailor(tailor),
                        icon: Icon(Icons.delete_outline),
                        label: Text('Hapus'),
                      ),
                      TextButton.icon(
                        onPressed: () => _showPaymentSheet(
                          tailor: tailor,
                          initialType: 'kasbon',
                        ),
                        icon: Icon(Icons.add_card_outlined),
                        label: Text('Kasbon'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _miniMetric(
                          'Total jahit',
                          AppUi.toNum(tailor['total_jahit'])
                              .toStringAsFixed(0)),
                      _miniMetric('Ongkos',
                          AppUi.rupiah(AppUi.toNum(tailor['total_ongkos']))),
                      _miniMetric('Sudah',
                          AppUi.rupiah(AppUi.toNum(tailor['sudah_bayar']))),
                      _miniMetric('Belum',
                          AppUi.rupiah(AppUi.toNum(tailor['belum_bayar']))),
                      _miniMetric('Kasbon',
                          AppUi.rupiah(AppUi.toNum(tailor['kasbon']))),
                    ],
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _progressCard(Map<String, dynamic> item) {
    final status = AppUi.text(item['status'], 'progress');
    final color = AppUi.statusColor(status);
    final items = _mapList(item['items']);
    final stages = _mapList(item['stages']);
    final payments = _mapList(item['payments']);

    final stageTailors = stages
        .map((s) => AppUi.text(s['tailor_name']).trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .join(', ');

    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: color.withOpacity(0.12),
                child:
                    Icon(Icons.precision_manufacturing_outlined, color: color),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppUi.text(item['surat_jalan_number'], '-'),
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Kode Pola: ${AppUi.text(item['pattern_code'], '-')}',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                        'Pekerja: ${stageTailors.isEmpty ? '-' : stageTailors} - Tanggal: ${AppUi.date(item['production_date'])}'),
                    Text(
                        'Qty ${AppUi.toNum(item['qty']).toStringAsFixed(0)} - Status $status - Bayar ${AppUi.text(item['payment_status'])}'),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _editProgress(item);
                  if (value == 'delete') _deleteProgress(item);
                },
                itemBuilder: (_) {
                  final canDelete = _currentRoleId == 'platform_owner' ||
                      _currentRoleId == 'super_admin' ||
                      _currentRoleId == 'production' ||
                      _currentRoleId == 'produksi';
                  return [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('Edit'),
                    ),
                    if (canDelete)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Hapus'),
                      ),
                  ];
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (payments.isNotEmpty) ...[
            Text('Rincian pembayaran',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            ...payments.map((payment) {
              final statusText = AppUi.text(payment['payment_status']);
              final statusColor = AppUi.statusColor(statusText);
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_getPaymentDisplayLabel(payment)} - ${AppUi.date(payment['payment_date'])}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: statusColor.withOpacity(0.28),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppUi.rupiah(AppUi.toNum(payment['amount'])),
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') {
                          _showPaymentSheet(
                            progress: item,
                            payment: payment,
                            initialType: AppUi.text(
                                payment['payment_type'], 'sewing_payment'),
                          );
                        }
                        if (value == 'delete') _deletePayment(payment);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Hapus')),
                      ],
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _miniMetric('Ongkos',
                  AppUi.rupiah(AppUi.toNum(item['sewing_total_amount']))),
              _miniMetric('Sudah',
                  AppUi.rupiah(AppUi.toNum(item['payment_paid_amount']))),
              _miniMetric('Belum',
                  AppUi.rupiah(AppUi.toNum(item['payment_unpaid_amount']))),
            ],
          ),
          const SizedBox(height: 12),
          if (items.isNotEmpty) ...[
            Text('Size breakdown',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            ...items.map((row) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${AppUi.text(row['size_label'])} - ${AppUi.text(row['local_sku'])} - ${AppUi.text(row['local_product_name'])}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${AppUi.toNum(row['qty']).toStringAsFixed(0)} pcs',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final stage in stages)
                _stageCard(
                  item: item,
                  stageKey: AppUi.text(stage['stage_key']),
                  stage: stage,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: status == 'done' ? null : () => _markDone(item),
                  icon: Icon(Icons.inventory_2_outlined),
                  label: Text('Done / Stock In'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _showStageSelectionForPayment(item),
                  icon: Icon(Icons.payments_outlined),
                  label: Text('Bayar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stageCard({
    required Map<String, dynamic> item,
    required String stageKey,
    required Map<String, dynamic> stage,
  }) {
    final status = AppUi.text(stage['status'], 'pending');
    final paymentStatus = AppUi.text(stage['payment_status'], 'belum_bayar');
    final color = AppUi.statusColor(status);
    final isSkipped = status == 'skipped';

    final totalAmount = AppUi.toNum(stage['total_amount']);
    final tailorName = AppUi.text(stage['tailor_name']);
    final pricePerPcs =
        AppUi.toNum(stage['price_per_pcs'] ?? stage['sewing_price_per_pcs']);
    final qtyIn = AppUi.toNum(stage['qty_in']);
    final qtyOut = AppUi.toNum(stage['qty_out']);
    final qtyReject = AppUi.toNum(stage['qty_reject']);
    final catatan = AppUi.text(stage['note'] ?? stage['catatan']);
    final dates = AppUi.text(stage['updated_at']);

    final sizeBreakdownRaw = stage['size_breakdown'];
    List<dynamic> sizeBreakdown = [];
    if (sizeBreakdownRaw != null) {
      if (sizeBreakdownRaw is List) {
        sizeBreakdown = sizeBreakdownRaw;
      }
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.32),
          width: 0.8,
        ),
      ),
      child: InkWell(
        onTap: () => _updateStage(item, stageKey, stage),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isSkipped
                        ? Icons.skip_next_outlined
                        : status == 'done'
                            ? Icons.check_circle_outline
                            : status == 'progress'
                                ? Icons.pending_actions_outlined
                                : Icons.circle_outlined,
                    color: color,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _stageLabel(stageKey),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: color.withOpacity(0.35)),
                    ),
                    child: Text(
                      status.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Pekerja: ${tailorName.isNotEmpty ? tailorName : '-'}',
                    style: TextStyle(fontSize: 11),
                  ),
                  Text(
                    'Tarif: ${AppUi.rupiah(pricePerPcs)}/pcs',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Total Ongkos: ${AppUi.rupiah(totalAmount)}',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: paymentStatus == 'sudah_bayar'
                          ? Colors.green.withOpacity(0.12)
                          : Colors.orange.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      paymentStatus == 'sudah_bayar' ? 'LUNAS' : 'BELUM BAYAR',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        color: paymentStatus == 'sudah_bayar'
                            ? Colors.green
                            : Colors.orange,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('In: ${qtyIn.toStringAsFixed(0)} pcs',
                      style: TextStyle(fontSize: 10)),
                  Text('Out: ${qtyOut.toStringAsFixed(0)} pcs',
                      style: TextStyle(fontSize: 10)),
                  Text('Reject: ${qtyReject.toStringAsFixed(0)} pcs',
                      style: TextStyle(fontSize: 10)),
                ],
              ),
              if (sizeBreakdown.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: sizeBreakdown.map((sb) {
                    final label = AppUi.text(sb['size_label']);
                    final sbIn = AppUi.toNum(sb['qty_in']);
                    final sbOut = AppUi.toNum(sb['qty_out']);
                    final sbReject = AppUi.toNum(sb['qty_reject']);
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceVariant
                            .withOpacity(0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '$label (In: ${sbIn.toStringAsFixed(0)}, Out: ${sbOut.toStringAsFixed(0)}, Rej: ${sbReject.toStringAsFixed(0)})',
                        style: TextStyle(fontSize: 9),
                      ),
                    );
                  }).toList(),
                ),
              ],
              if (catatan.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Catatan: $catatan',
                  style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic),
                ),
              ],
              if (dates.isNotEmpty) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Text(
                    'Update terakhir: ${AppUi.dateTime(dates)}',
                    style: TextStyle(
                        fontSize: 8, color: Theme.of(context).hintColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniMetric(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.fromBorderSide(AppUi.softBorderSide(context)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          SizedBox(height: 2),
          Text(value, style: TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _buildCreateStageTemplateTile({
    required BuildContext sheetContext,
    required Map<String, dynamic> stage,
    required bool saving,
    required ValueChanged<bool> onChanged,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    final label = _editableStageLabel(stage);
    final key = AppUi.text(stage['key']);
    final active = stage['active'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? Theme.of(sheetContext).colorScheme.primary.withOpacity(0.08)
            : Theme.of(sheetContext)
                .colorScheme
                .surfaceVariant
                .withOpacity(0.22),
        border: Border.all(
          color: Theme.of(sheetContext).dividerColor.withOpacity(0.35),
        ),
      ),
      child: Row(
        children: [
          Checkbox(
            value: active,
            onChanged: saving ? null : (value) => onChanged(value ?? false),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    decoration: active ? null : TextDecoration.lineThrough,
                  ),
                ),
                if (key.isNotEmpty)
                  Text(
                    'key: $key',
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit label template',
            onPressed: saving ? null : onEdit,
            icon: Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Hapus template dari daftar tambah produksi',
            onPressed: saving ? null : onDelete,
            icon: Icon(
              Icons.delete_outline,
              color: Theme.of(sheetContext).colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _defaultProductionStages() {
    return <Map<String, dynamic>>[
      <String, dynamic>{'key': 'potong_kain', 'label': 'Potong Kain'},
      <String, dynamic>{'key': 'jahit', 'label': 'Jahit'},
      <String, dynamic>{'key': 'lubang_kancing', 'label': 'Lubang Kancing'},
      <String, dynamic>{'key': 'finishing', 'label': 'Finishing'},
      <String, dynamic>{'key': 'packing', 'label': 'Packing'},
    ];
  }

  List<Map<String, dynamic>> _defaultCreateStageTemplates() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'key': 'potong_kain',
        'label': 'Potong Kain',
        'active': true
      },
      <String, dynamic>{'key': 'jahit', 'label': 'Jahit', 'active': true},
      <String, dynamic>{
        'key': 'lubang_kancing',
        'label': 'Lubang Kancing',
        'active': false
      },
      <String, dynamic>{
        'key': 'finishing',
        'label': 'Finishing',
        'active': true
      },
      <String, dynamic>{'key': 'packing', 'label': 'Packing', 'active': true},
    ];
  }

  Future<List<Map<String, dynamic>>> _loadStageTemplatesForCreate() async {
    final fallbackRows = _defaultCreateStageTemplates()
        .map((stage) => Map<String, dynamic>.from(stage))
        .toList();
    if (_currentTenantId.isEmpty) return fallbackRows;

    try {
      final response =
          await _client.rpc('list_production_stage_templates_for_app');
      final templates = _mapList(response);
      if (templates.isEmpty) return fallbackRows;

      return templates
          .map((row) {
            final key = AppUi.text(row['stage_key'] ?? row['key']).trim();
            if (key.isEmpty) return <String, dynamic>{};
            final rawLabel =
                AppUi.text(row['stage_label'] ?? row['label']).trim();
            final label = rawLabel.isEmpty ? _stageLabel(key) : rawLabel;
            return <String, dynamic>{
              'key': key,
              'label': label,
              'active':
                  row['default_selected'] == true || row['active'] == true,
            };
          })
          .where((row) => AppUi.text(row['key']).isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Error loading production stage templates: $e');
    }

    return fallbackRows;
  }

  List<Map<String, dynamic>> _buildEditableStageRows(
    List<Map<String, dynamic>> dbStages,
  ) {
    final rows = _defaultProductionStages().map((stage) {
      final key = AppUi.text(stage['key']);
      final label = AppUi.text(stage['label'], _stageLabel(key));
      return <String, dynamic>{
        'key': key,
        'label': label,
        'active': false,
        'persisted': false,
        'originalLabel': label,
        'originalActive': false,
      };
    }).toList();

    for (final dbStage in dbStages) {
      final key = AppUi.text(dbStage['stage_key']).trim();
      if (key.isEmpty) continue;
      final rawLabel = AppUi.text(dbStage['stage_label']).trim();
      final label = rawLabel.isEmpty ? _stageLabel(key) : rawLabel;
      final isActive = dbStage['is_active'] == true;
      final existing = rows.firstWhereOrNull(
        (stage) => AppUi.text(stage['key']) == key,
      );
      final row = <String, dynamic>{
        'key': key,
        'label': label,
        'active': isActive,
        'persisted': true,
        'originalLabel': label,
        'originalActive': isActive,
      };
      if (existing == null) {
        rows.add(row);
      } else {
        existing
          ..['label'] = label
          ..['active'] = isActive
          ..['persisted'] = true
          ..['originalLabel'] = label
          ..['originalActive'] = isActive;
      }
    }

    return rows;
  }

  String _editableStageLabel(Map<String, dynamic> stage) {
    final key = AppUi.text(stage['key']);
    final label = AppUi.text(stage['label']).trim();
    return label.isEmpty ? _stageLabel(key) : label;
  }

  Future<String?> _editStageLabelDialog(String currentLabel) async {
    final controller = TextEditingController(text: currentLabel);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Edit label progress'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Label progress',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext),
            child: Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              AppUi.safePop(dialogContext, value);
            },
            icon: Icon(Icons.save_outlined),
            label: Text('Simpan'),
          ),
        ],
      ),
    );
    Future<void>.delayed(
      const Duration(milliseconds: 300),
      controller.dispose,
    );
    return result;
  }

  String _stageLabel(String stageKey) {
    switch (stageKey) {
      case 'potong_kain':
        return 'Potong Kain';
      case 'jahit':
        return 'Jahit';
      case 'lubang_kancing':
        return 'Lubang Kancing';
      case 'finishing':
        return 'Finishing';
      case 'packing':
        return 'Packing';
      default:
        return stageKey
            .split('_')
            .map((str) =>
                str.isEmpty ? '' : '${str[0].toUpperCase()}${str.substring(1)}')
            .join(' ');
    }
  }

  String _getPaymentDisplayLabel(Map<String, dynamic> payment) {
    String clean(dynamic val) {
      if (val == null) return '';
      final s = val.toString().trim();
      if (s == '-' || s == '--') return '';
      return s;
    }

    final paymentLabel = clean(payment['payment_label']);
    if (paymentLabel.isNotEmpty) {
      return paymentLabel;
    }

    final stageKey = clean(payment['stage_key']);
    if (stageKey.isNotEmpty) {
      return _stageLabel(stageKey);
    }

    final paymentType = clean(payment['payment_type']);
    if (paymentType.isNotEmpty) {
      return _paymentTypeLabel(paymentType);
    }

    final note = clean(payment['note']);
    if (note.isNotEmpty) {
      return note;
    }

    return 'Pembayaran';
  }

  String _paymentTypeLabel(String paymentType) {
    switch (paymentType) {
      case 'deposit':
        return 'Saldo deposit';
      case 'sewing_payment':
        return 'Ongkos jahit';
      case 'kasbon':
        return 'Kasbon';
      case 'kasbon_repayment':
        return 'Bayar kasbon';
      default:
        return paymentType;
    }
  }

  String _normalizeStageKey(String input) {
    return input
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  Map<String, dynamic> _map(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> _showStageSelectionForPayment(Map<String, dynamic> item) async {
    final stages = _mapList(item['stages']);
    final payableStages = stages.where((stage) {
      final status = AppUi.text(stage['status']);
      final skipped =
          status == 'skipped' || AppUi.text(stage['is_skipped']) == 'true';
      return !skipped;
    }).toList();

    if (payableStages.isEmpty) {
      AppUi.showSnack('Tidak ada progress aktif yang bisa dibayar.');
      return;
    }

    final selectedStageKey = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Pilih Progress Pembayaran'),
        content: SizedBox(
          width: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: payableStages.length,
            itemBuilder: (ctx, index) {
              final stage = payableStages[index];
              final key = AppUi.text(stage['stage_key']);
              final label = _stageLabel(key);
              final worker = AppUi.text(stage['tailor_name'], '');
              final total = AppUi.toNum(stage['total_amount']);

              // Calculate paid amount
              final paymentsList = _mapList(item['payments']);
              final paid = paymentsList
                  .where((p) =>
                      AppUi.text(p['stage_key']) == key &&
                      AppUi.text(p['payment_status']) == 'sudah_bayar')
                  .fold<num>(0, (sum, p) => sum + AppUi.toNum(p['amount']));

              final unpaid = total - paid;
              final unpaidText =
                  unpaid > 0 ? ' - Sisa: ${AppUi.rupiah(unpaid)}' : ' (Lunas)';

              return ListTile(
                title: Text(worker.isNotEmpty ? '$label ($worker)' : label),
                subtitle: Text('Total: ${AppUi.rupiah(total)}$unpaidText'),
                onTap: () => Navigator.pop(dialogContext, key),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Batal'),
          ),
        ],
      ),
    );

    if (selectedStageKey != null) {
      _showPaymentSheet(progress: item, initialStageKey: selectedStageKey);
    }
  }
}

class _ProductionLineInput {
  Product? product;
  MarketplaceSkuMap? skuMap;
  final TextEditingController qtyController = TextEditingController();
  final TextEditingController priceController = TextEditingController();

  num get qty => AppUi.parseMoneyInput(qtyController.text);
  num get price => AppUi.parseMoneyInput(priceController.text);
  num get total => qty * price;
  String? get productId => product?.productId ?? skuMap?.productId;
  String? get marketplaceSkuMapId => skuMap?.marketplaceSkuMapId;

  String? get selectedValue {
    final map = skuMap;
    if (map != null) return 'map:${map.marketplaceSkuMapId}';
    final localProduct = product;
    if (localProduct != null) return 'local:${localProduct.productId}';
    return null;
  }

  String get sizeLabel {
    final map = skuMap;
    if (map != null) {
      final localSku = map.localSku.trim();
      if (localSku.isNotEmpty && localSku != '-') return localSku;
      final localName = map.localProductName.trim();
      if (localName.isNotEmpty) return localName;
    }
    final item = product;
    if (item == null) return '';
    return item.kodeSku.trim().isNotEmpty
        ? item.kodeSku.trim()
        : item.namaBarang;
  }

  void dispose() {
    qtyController.dispose();
    priceController.dispose();
  }
}

class _MaterialPurchaseLineInput {
  Product? product;
  bool stockIn = false;
  final TextEditingController nameController = TextEditingController();
  final TextEditingController qtyController = TextEditingController();
  final TextEditingController satuanController =
      TextEditingController(text: 'pcs');
  final TextEditingController priceController = TextEditingController();
  final TextEditingController noteController = TextEditingController();

  num get qty => AppUi.parseMoneyInput(qtyController.text);
  num get price => AppUi.parseMoneyInput(priceController.text);
  num get total => qty * price;

  void dispose() {
    nameController.dispose();
    qtyController.dispose();
    satuanController.dispose();
    priceController.dispose();
    noteController.dispose();
  }
}
