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
      final tenantId = AppUi.text(userRow['tenant_id'], '');
      _isSuperAdmin = AppUi.text(userRow['role_id']) == 'super_admin';

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

      final products = tenantId.isEmpty
          ? <Product>[]
          : await _marketplaceService.listLocalProducts(
              tenantId: tenantId,
              limit: 200,
            );
      final skuMaps = tenantId.isEmpty
          ? <MarketplaceSkuMap>[]
          : await _marketplaceService.listSkuMaps(
              tenantId: tenantId,
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
    final tailorName = TextEditingController();
    final patternCode = TextEditingController();
    final note = TextEditingController();
    final lines = <_ProductionLineInput>[_ProductionLineInput()];
    String? selectedTailorId;
    String? selectedPatternCode;

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
            num totalAmount() =>
                lines.fold<num>(0, (sum, line) => sum + line.total);

            Future<void> submit() async {
              final validLines = lines
                  .where((line) =>
                      (line.productId ?? '').trim().isNotEmpty && line.qty > 0)
                  .toList();
              if (validLines.isEmpty) {
                AppUi.showSnack('Pilih minimal satu SKU lokal dan qty jahit.');
                return;
              }
              if ((selectedTailorId ?? '').isEmpty &&
                  tailorName.text.trim().isEmpty) {
                AppUi.showSnack('Penjahit wajib dipilih atau ditambahkan.');
                return;
              }

              try {
                setSheetState(() => saving = true);
                await _client.rpc(
                  'create_production_progress_full_for_app',
                  params: <String, dynamic>{
                    'p_tailor_id': selectedTailorId,
                    'p_tailor_name': tailorName.text.trim(),
                    'p_pattern_code': patternCode.text.trim(),
                    'p_production_date': _dateOnly(productionDate),
                    'p_target_finish_date':
                        targetDate == null ? null : _dateOnly(targetDate!),
                    'p_items': validLines.map((line) {
                      return <String, dynamic>{
                        'marketplace_sku_map_id': line.marketplaceSkuMapId,
                        'product_id': line.productId,
                        'size_label': line.sizeLabel,
                        'qty': line.qty,
                        'sewing_price_per_pcs': line.price,
                        'sort_order': lines.indexOf(line) + 1,
                      };
                    }).toList(),
                    'p_deposit_amount': null,
                    'p_deposit_date': null,
                    'p_deposit_payment_status': null,
                    'p_surat_jalan_url': suratJalanUrl,
                    'p_catatan': note.text.trim(),
                    'p_proof_url': proofEvidence?.publicUrl,
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
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: selectedTailorId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Penjahit',
                      border: OutlineInputBorder(),
                    ),
                    items: _tailors.map((tailor) {
                      return DropdownMenuItem<String>(
                        value: AppUi.text(tailor['tailor_id'], ''),
                        child: Text(
                          AppUi.text(tailor['tailor_name']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: saving
                        ? null
                        : (value) {
                            setSheetState(() {
                              selectedTailorId = value;
                              tailorName.clear();
                            });
                          },
                  ),
                  SizedBox(height: 10),
                  TextField(
                    controller: tailorName,
                    enabled: selectedTailorId == null && !saving,
                    decoration: const InputDecoration(
                      labelText: 'Tambah penjahit manual',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 10),
                  Autocomplete<String>(
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      if (textEditingValue.text.isEmpty) {
                        return uniquePatternCodes;
                      }
                      return uniquePatternCodes.where((String option) {
                        return option.toLowerCase().contains(textEditingValue.text.toLowerCase());
                      });
                    },
                    onSelected: (String selection) {
                      patternCode.text = selection;
                    },
                    fieldViewBuilder: (context, controller, focusNode, onEditingComplete) {
                      controller.addListener(() {
                        patternCode.text = controller.text;
                      });
                      if (controller.text.isEmpty && patternCode.text.isNotEmpty) {
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
                  SizedBox(height: 10),
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
                      SizedBox(width: 10),
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
                  SizedBox(height: 14),
                  Text('Breakdown Size',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w900)),
                  SizedBox(height: 8),
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
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _miniMetric('Total qty', totalQty().toStringAsFixed(0)),
                      _miniMetric('Total ongkos', AppUi.rupiah(totalAmount())),
                    ],
                  ),
                  SizedBox(height: 14),
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
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.attach_file_outlined),
                    label: Text(suratJalanUrl == null
                        ? 'Upload surat jalan'
                        : 'Surat jalan tersimpan'),
                  ),
                  SizedBox(height: 12),
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
                  SizedBox(height: 12),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Catatan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? SizedBox(
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
      tailorName.dispose();
      patternCode.dispose();
      note.dispose();
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
    final mappedOptions = _skuMaps
        .where((item) => (item.productId ?? '').trim().isNotEmpty)
        .toList();
    final mappedProductIds = mappedOptions.map((e) => e.productId).toSet();
    final unmappedProducts = _localProducts
        .where((p) => !mappedProductIds.contains(p.productId))
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: line.selectedValue,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Pilih SKU Master / Produk',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      ..._localProducts.map((product) {
                        return DropdownMenuItem<String>(
                          value: 'local:${product.productId}',
                          child: Text(
                            '${product.kodeSku} - ${product.namaBarang} - Stok ${AppUi.money(product.stockSaatIni)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }),
                    ],
                    onChanged: saving
                        ? null
                        : (value) {
                            if (value == null) return;
                            final productId = value.substring(6);
                            line.skuMap = null;
                            line.product = _localProducts.firstWhere(
                              (product) => product.productId == productId,
                            );
                            onChanged();
                          },
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
            SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: line.qtyController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Qty jahit',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: line.priceController,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [AppMoneyInputFormatter()],
                    decoration: const InputDecoration(
                      labelText: 'Harga/pcs',
                      prefixText: 'Rp ',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Total ${AppUi.rupiah(line.total)}',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPaymentSheet({
    Map<String, dynamic>? progress,
    Map<String, dynamic>? tailor,
    Map<String, dynamic>? payment,
    String initialType = 'sewing_payment',
  }) async {
    final existingType = AppUi.text(payment?['payment_type'], initialType);
    final depositOnly = existingType == 'deposit' ||
        (progress == null && tailor == null && initialType == 'deposit');
    final amount = TextEditingController(
      text: payment != null
          ? AppUi.moneyInput(AppUi.toNum(payment['amount']))
          : initialType == 'sewing_payment' && progress != null
              ? AppUi.moneyInput(AppUi.toNum(progress['payment_unpaid_amount']))
              : '',
    );
    final note = TextEditingController(
      text: AppUi.text(
          payment?['note'], depositOnly ? 'Deposit awal produksi' : ''),
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
              final nominal = AppUi.parseMoneyInput(amount.text);
              if (nominal <= 0) {
                AppUi.showSnack(depositOnly
                    ? 'Nominal deposit wajib lebih dari 0.'
                    : 'Nominal pembayaran wajib lebih dari 0.');
                return;
              }
              if (paymentStatus == 'sudah_bayar' &&
                  proofEvidence == null &&
                  initialProofUrl.isEmpty) {
                AppUi.showSnack(
                    'Bukti foto/galeri wajib diisi untuk status sudah bayar.');
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
                    },
                  );
                } else {
                  await _client.rpc(
                    'upsert_production_tailor_payment_for_app',
                    params: <String, dynamic>{
                      'p_payment_id': payment?['payment_id'],
                      'p_progress_id': progress?['progress_id'],
                      'p_tailor_id': tailor?['tailor_id'] ??
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
                            : 'Edit Pembayaran Penjahit')
                        : (depositOnly
                            ? 'Tambah Deposit Awal'
                            : 'Pembayaran Penjahit'),
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 12),
                  if (depositOnly)
                    LayoutBuilder(
                      builder: (context, constraints) => DropdownMenu<String>(
                        width: constraints.maxWidth,
                        initialSelection: note.text,
                        label: const Text('Jenis / Deskripsi'),
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
                  else
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
                                  child: Text('Pembayaran ongkos jahit')),
                              DropdownMenuItem(
                                  value: 'kasbon',
                                  child: Text('Kasbon penjahit')),
                            ]
                          : const [
                              DropdownMenuItem(
                                  value: 'kasbon',
                                  child: Text('Kasbon penjahit')),
                            ],
                      onChanged: saving
                          ? null
                          : (value) => setSheetState(
                              () => paymentType = value ?? 'sewing_payment'),
                    ),
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
                  SizedBox(height: 10),
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
                      SizedBox(width: 10),
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
                  SizedBox(height: 10),
                  EvidenceCameraField(
                    label: 'Bukti pembayaran',
                    moduleName: depositOnly
                        ? 'production_deposit'
                        : 'production_payment',
                    purpose: '${paymentType}_proof',
                    referenceId: payment?['payment_id']?.toString(),
                    initialPhotoUrl: initialProofUrl,
                    helperText:
                        'Bisa ambil kamera atau pilih dari galeri. Wajib untuk status sudah bayar.',
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
                        ? SizedBox(
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
    });
    if (saved == true) _load();
  }

  Future<void> _deletePayment(Map<String, dynamic> payment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Hapus pembayaran produksi?'),
        content: Text(
          '${_paymentTypeLabel(AppUi.text(payment['payment_type']))} - ${AppUi.rupiah(AppUi.toNum(payment['amount']))}',
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

  Future<void> _updateStage(Map<String, dynamic> item, String stageKey) async {
    String status = 'done';
    final note = TextEditingController();
    PhotoEvidence? proofEvidence;
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
                await _client.rpc(
                  'update_production_progress_status_full_for_app',
                  params: <String, dynamic>{
                    'p_progress_id': item['progress_id'],
                    'p_status': status,
                    'p_stage_key': stageKey,
                    'p_proof_url': proofEvidence?.publicUrl,
                    'p_catatan': note.text.trim(),
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
                    _stageLabel(stageKey),
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: status,
                    decoration: const InputDecoration(
                      labelText: 'Status stage',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                          value: 'progress', child: Text('Progress')),
                      DropdownMenuItem(value: 'done', child: Text('Done')),
                      DropdownMenuItem(
                          value: 'cancelled', child: Text('Dibatalkan')),
                    ],
                    onChanged: saving
                        ? null
                        : (value) =>
                            setSheetState(() => status = value ?? 'done'),
                  ),
                  SizedBox(height: 12),
                  EvidenceCameraField(
                    label: 'Foto update stage',
                    moduleName: 'production_progress',
                    purpose: 'stage_$stageKey',
                    referenceId: item['progress_id']?.toString(),
                    allowGallery: true,
                    onUploaded: (evidence) {
                      proofEvidence = evidence;
                      if (sheetContext.mounted) setSheetState(() {});
                    },
                  ),
                  SizedBox(height: 12),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Catatan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.task_alt_outlined),
                    label: Text(stageKey == 'finishing' && status == 'done'
                        ? 'Done dan Masuk Stock'
                        : 'Simpan Stage'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), note.dispose);
    if (saved == true) _load();
  }

  Future<void> _markDone(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Selesaikan produksi?'),
        content: Text(
          'Saat Done, stock lokal bertambah per baris size dari SKU Mapping. Proses ini dicegah dobel oleh backend.',
        ),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext, false),
            child: Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => AppUi.safePop(dialogContext, true),
            icon: Icon(Icons.inventory_2_outlined),
            label: Text('Done'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
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
      AppUi.showSnack('Produksi selesai dan stock lokal sudah ditambah.');
      await _load();
    } on PostgrestException catch (e) {
      AppUi.showSnack(e.message);
    } catch (e) {
      AppUi.showSnack(AppUi.userMessage(e.toString()));
    }
  }

  Future<void> _deleteProgress(Map<String, dynamic> item) async {
    if (!_isSuperAdmin) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Hapus progress produksi?'),
        content: Text(AppUi.text(item['product_name'], 'Progress ini')),
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
                        ?.copyWith(fontWeight: FontWeight.w900),
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
                        ?.copyWith(fontWeight: FontWeight.w900),
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
                          ?.copyWith(fontWeight: FontWeight.w900)),
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
                    referenceId: purchase?['purchase_id']?.toString(),
                    initialPhotoUrl: initialPhotoUrl,
                    helperText: 'Bisa foto kamera atau pilih dari galeri.',
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
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
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
                style: TextStyle(fontWeight: FontWeight.w900),
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
          'Type': _paymentTypeLabel(AppUi.text(payment['payment_type'])),
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

    return Scaffold(
      appBar: AppBar(
        title: Text('Produksi Berjalan'),
        actions: [
          IconButton(onPressed: _load, icon: Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createProgress,
        icon: Icon(Icons.add),
        label: Text('Progress'),
      ),
      body: RefreshIndicator(
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
                    value:
                        AppUi.toNum(_summary['done_count']).toStringAsFixed(0)),
                StatPill(
                    label: 'Kasbon',
                    value: AppUi.rupiah(
                        AppUi.toNum(_summary['kasbon_active_total']))),
              ],
            ),
            SizedBox(height: 14),
            _monthToolbar(),
            SizedBox(height: 14),
            _summaryGrid(),
            SizedBox(height: 14),
            _depositLedger(),
            SizedBox(height: 14),
            _materialPurchaseSection(),
            SizedBox(height: 14),
            SearchBox(
              controller: _searchController,
              onChanged: _onSearchChanged,
              hint: 'Cari produk, SKU, kode pola, penjahit',
            ),
            SizedBox(height: 12),
            _filters(),
            SizedBox(height: 14),
            _tailorDashboard(),
            SizedBox(height: 14),
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
                          ?.copyWith(fontWeight: FontWeight.w900),
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
                onPressed: () => _showTailorSheet(),
                icon: Icon(Icons.person_add_alt_1_outlined),
                label: Text('Penjahit'),
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
        Theme.of(context).colorScheme.outline,
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
                                        fontWeight: FontWeight.w900,
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
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.zero,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppUi.teal.withOpacity(0.12),
                        border: Border.all(color: Colors.black, width: 1.5),
                      ),
                      child:
                          const Icon(Icons.savings_outlined, color: AppUi.teal),
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
                              style: const TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 12)),
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
                        borderRadius: BorderRadius.zero,
                        border: Border.all(color: statusColor.withOpacity(0.3)),
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
                  borderRadius: BorderRadius.zero,
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
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.10),
                            borderRadius: BorderRadius.zero,
                            border:
                                Border.all(color: statusColor.withOpacity(0.3)),
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
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0), isDense: true,
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
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0), isDense: true,
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
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0), isDense: true,
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
    if (visibleTailors.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Rekap Penjahit',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w900)),
        SizedBox(height: 8),
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
                          style: TextStyle(fontWeight: FontWeight.w900)),
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
                SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _miniMetric('Total jahit',
                        AppUi.toNum(tailor['total_jahit']).toStringAsFixed(0)),
                    _miniMetric('Ongkos',
                        AppUi.rupiah(AppUi.toNum(tailor['total_ongkos']))),
                    _miniMetric('Sudah',
                        AppUi.rupiah(AppUi.toNum(tailor['sudah_bayar']))),
                    _miniMetric('Belum',
                        AppUi.rupiah(AppUi.toNum(tailor['belum_bayar']))),
                    _miniMetric(
                        'Kasbon', AppUi.rupiah(AppUi.toNum(tailor['kasbon']))),
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
                      AppUi.text(item['pattern_code'],
                          AppUi.text(item['product_name'])),
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    SizedBox(height: 4),
                    Text(
                        'Penjahit: ${AppUi.text(item['tailor_name'])} - Tanggal: ${AppUi.date(item['production_date'])}'),
                    Text(
                        'Qty ${AppUi.toNum(item['qty']).toStringAsFixed(0)} - Status $status - Bayar ${AppUi.text(item['payment_status'])}'),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'pay') _showPaymentSheet(progress: item);
                  if (value == 'kasbon') {
                    _showPaymentSheet(progress: item, initialType: 'kasbon');
                  }
                  if (value == 'done') _markDone(item);
                  if (value == 'delete') _deleteProgress(item);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'pay',
                    child: Text('Bayar ongkos jahit'),
                  ),
                  const PopupMenuItem(
                    value: 'kasbon',
                    child: Text('Kasbon penjahit'),
                  ),
                  const PopupMenuItem(
                    value: 'done',
                    child: Text('Done masuk stock'),
                  ),
                  if (_isSuperAdmin)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Hapus'),
                    ),
                ],
              ),
            ],
          ),
          SizedBox(height: 12),
          if (payments.isNotEmpty) ...[
            Text('Rincian pembayaran',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w900)),
            SizedBox(height: 6),
            ...payments.map((payment) {
              final statusText = AppUi.text(payment['payment_status']);
              final statusColor = AppUi.statusColor(statusText);
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_paymentTypeLabel(AppUi.text(payment['payment_type']))} - ${AppUi.date(payment['payment_date'])}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.10),
                        borderRadius: BorderRadius.zero,
                        border: Border.all(
                          color: statusColor.withOpacity(0.28),
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
                    SizedBox(width: 8),
                    Text(
                      AppUi.rupiah(AppUi.toNum(payment['amount'])),
                      style: TextStyle(fontWeight: FontWeight.w900),
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
            SizedBox(height: 8),
          ],
          SizedBox(height: 12),
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
          SizedBox(height: 12),
          if (items.isNotEmpty) ...[
            Text('Size breakdown',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w900)),
            SizedBox(height: 6),
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
                      '${AppUi.toNum(row['qty']).toStringAsFixed(0)} x ${AppUi.rupiah(AppUi.toNum(row['sewing_price_per_pcs']))}',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              );
            }),
            SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final stageKey in const [
                'potong_kain',
                'jahit',
                'finishing',
              ])
                _stageButton(
                  item: item,
                  stageKey: stageKey,
                  stage: stages.firstWhere(
                    (stage) => AppUi.text(stage['stage_key']) == stageKey,
                    orElse: () => <String, dynamic>{'status': 'pending'},
                  ),
                ),
            ],
          ),
          SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: status == 'done' ? null : () => _markDone(item),
                  icon: Icon(Icons.inventory_2_outlined),
                  label: Text('Done / Stock In'),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _showPaymentSheet(progress: item),
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

  Widget _stageButton({
    required Map<String, dynamic> item,
    required String stageKey,
    required Map<String, dynamic> stage,
  }) {
    final status = AppUi.text(stage['status'], 'pending');
    final color = AppUi.statusColor(status);
    return ActionChip(
      avatar: Icon(Icons.task_alt_outlined, color: color, size: 18),
      label: Text('${_stageLabel(stageKey)}: $status'),
      onPressed: AppUi.text(item['status']) == 'done'
          ? null
          : () => _updateStage(item, stageKey),
      backgroundColor: color.withOpacity(0.10),
      side: BorderSide(color: color.withOpacity(0.35)),
    );
  }

  Widget _miniMetric(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.zero,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          SizedBox(height: 2),
          Text(value, style: TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  String _stageLabel(String stageKey) {
    switch (stageKey) {
      case 'potong_kain':
        return 'Potong Kain';
      case 'jahit':
        return 'Proses Jahit';
      case 'finishing':
        return 'Finishing';
      default:
        return stageKey;
    }
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
