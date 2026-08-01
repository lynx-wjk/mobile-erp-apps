import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/evidence/models/photo_evidence.dart';
import '../../../core/evidence/widgets/evidence_camera_field.dart';
import '../../../core/ui/app_ui.dart';

class PurchaseRequestPage extends StatefulWidget {
  const PurchaseRequestPage({super.key});

  @override
  State<PurchaseRequestPage> createState() => _PurchaseRequestPageState();
}

class _PurchaseRequestPageState extends State<PurchaseRequestPage> {
  final SupabaseClient _client = Supabase.instance.client;

  final TextEditingController _supplierManualController =
      TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  List<Map<String, dynamic>> _suppliers = [];
  Map<String, dynamic>? _selectedSupplier;
  PhotoEvidence? _notaEvidence;
  final List<_PurchaseItemDraft> _items = [];

  @override
  void initState() {
    super.initState();
    _loadMasterData();
  }

  @override
  void dispose() {
    _supplierManualController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadMasterData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await _client
          .from('suppliers')
          .select('supplier_id, nama_supplier, nama, status')
          .order('created_at', ascending: false);

      if (!mounted) return;

      setState(() {
        _suppliers =
            (data as List).map((e) => Map<String, dynamic>.from(e)).where((e) {
          final status = AppUi.text(e['status'], 'active').toLowerCase();
          return status == 'active' || status == '-';
        }).toList();
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  num get _total => _items.fold<num>(0, (sum, item) => sum + item.subtotal);

  String _supplierName(Map<String, dynamic> supplier) {
    return AppUi.text(supplier['nama_supplier'] ?? supplier['nama']);
  }

  Future<void> _openItemForm([int? editIndex]) async {
    final current = editIndex == null ? null : _items[editIndex];

    final nameController =
        TextEditingController(text: current?.namaBarang ?? '');
    final qtyController = TextEditingController(
        text: current == null ? '' : current.qty.toStringAsFixed(0));
    final unitController =
        TextEditingController(text: current?.satuan ?? 'pcs');
    final priceController = TextEditingController(
        text: current == null ? '' : AppUi.moneyInput(current.hargaItem));
    final noteController = TextEditingController(text: current?.catatan ?? '');
    String? formError;

    final result = await showDialog<_PurchaseItemDraft>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            void submit() {
              final name = nameController.text.trim();
              final qty = num.tryParse(
                      qtyController.text.trim().replaceAll(',', '.')) ??
                  0;
              final price = AppUi.parseMoneyInput(priceController.text);

              if (name.isEmpty || qty <= 0) {
                setDialogState(
                    () => formError = 'Nama barang dan qty wajib valid');
                return;
              }

              AppUi.safePop(
                dialogContext,
                _PurchaseItemDraft(
                  namaBarang: name,
                  qty: qty,
                  satuan: unitController.text.trim().isEmpty
                      ? 'pcs'
                      : unitController.text.trim(),
                  hargaItem: price,
                  catatan: noteController.text.trim(),
                ),
              );
            }

            return AlertDialog(
              title: Text(editIndex == null
                  ? 'Tambah Item Pembelian'
                  : 'Edit Item Pembelian'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                        'Barang/bahan pembelian tidak harus berasal dari Master SKU.'),
                    const SizedBox(height: 14),
                    TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                            labelText: 'Nama Barang / Bahan',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: qtyController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Qty',
                                  border: OutlineInputBorder()))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: TextField(
                              controller: unitController,
                              decoration: const InputDecoration(
                                  labelText: 'Satuan',
                                  border: OutlineInputBorder()))),
                    ]),
                    const SizedBox(height: 12),
                    TextField(
                      controller: priceController,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [AppMoneyInputFormatter()],
                      decoration: const InputDecoration(
                          labelText: 'Harga per Item',
                          prefixText: 'Rp ',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                        controller: noteController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                            labelText: 'Catatan Item',
                            border: OutlineInputBorder())),
                    if (formError != null) ...[
                      const SizedBox(height: 10),
                      Text(formError!,
                          style: const TextStyle(
                              color: Colors.red, fontWeight: FontWeight.w700)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => AppUi.safePop(dialogContext),
                    child: const Text('Batal')),
                FilledButton.icon(
                    onPressed: submit,
                    icon: const Icon(Icons.add),
                    label: Text(editIndex == null ? 'Tambah' : 'Update')),
              ],
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      nameController.dispose();
      qtyController.dispose();
      unitController.dispose();
      priceController.dispose();
      noteController.dispose();
    });

    if (result != null && mounted) {
      setState(() {
        if (editIndex == null) {
          _items.add(result);
        } else {
          _items[editIndex] = result;
        }
      });
    }
  }

  Future<void> _save() async {
    if (_items.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Minimal tambah 1 item pembelian')),
      );
      return;
    }

    final evidence = _notaEvidence;
    if (evidence == null || evidence.publicUrl.trim().isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Foto nota wajib diambil dari kamera')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final manualSupplier = _supplierManualController.text.trim();
      final selectedSupplierName =
          _selectedSupplier == null ? '' : _supplierName(_selectedSupplier!);
      final supplierName =
          manualSupplier.isNotEmpty ? manualSupplier : selectedSupplierName;

      final items = _items.map((item) => item.toJson()).toList();

      await _client.rpc('create_purchase_with_items', params: {
        'p_supplier_id': _selectedSupplier?['supplier_id'],
        'p_supplier_name': supplierName,
        'p_catatan': _noteController.text.trim(),
        'p_photo_url': evidence.publicUrl,
        'p_latitude': evidence.latitude,
        'p_longitude': evidence.longitude,
        'p_items': items,
      });

      if (!mounted) return;

      setState(() {
        _items.clear();
        _selectedSupplier = null;
        _notaEvidence = null;
      });
      _supplierManualController.clear();
      _noteController.clear();

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Pembelian berhasil disimpan')),
      );
    } on PostgrestException catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState
          ?.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Gagal menyimpan pembelian: $error')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();

    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadMasterData);
    }

    return RefreshIndicator(
      onRefresh: _loadMasterData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          FuturisticHeader(
            icon: Icons.shopping_cart_checkout_outlined,
            title: 'Pembelian',
            subtitle:
                'Item pembelian bebas, tidak wajib Master SKU. Foto nota pakai kamera, GPS, tanggal, dan jam otomatis.',
            stats: [
              StatPill(label: 'Item', value: _items.length.toString()),
              StatPill(label: 'Total', value: 'Rp ${AppUi.money(_total)}'),
            ],
          ),
          const SizedBox(height: 16),
          NiceCard(
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  value: _selectedSupplier?['supplier_id']?.toString(),
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Supplier dari Master (opsional)',
                    border: OutlineInputBorder(),
                  ),
                  hint: const Text('Kosong / pakai supplier manual'),
                  items: [
                    const DropdownMenuItem<String>(
                      value: '',
                      child: Text('Kosong / supplier manual'),
                    ),
                    ..._suppliers.map((supplier) {
                      return DropdownMenuItem<String>(
                        value: supplier['supplier_id'].toString(),
                        child: Text(
                          _supplierName(supplier),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    setState(() {
                      if (value == null || value.isEmpty) {
                        _selectedSupplier = null;
                      } else {
                        _selectedSupplier = _suppliers.firstWhere(
                          (item) => item['supplier_id'].toString() == value,
                        );
                        _supplierManualController.clear();
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _supplierManualController,
                  enabled: _selectedSupplier == null,
                  decoration: const InputDecoration(
                    labelText: 'Supplier Manual (opsional)',
                    hintText: 'Isi kalau supplier belum ada di master',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                EvidenceCameraField(
                  label: 'Foto Nota',
                  moduleName: 'purchase',
                  purpose: 'nota_pembelian',
                  allowGallery: true,
                  onUploaded: (evidence) {
                    setState(() => _notaEvidence = evidence);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _noteController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Catatan',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _openItemForm(),
                    icon: const Icon(Icons.add),
                    label: const Text('Tambah Item Pembelian'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_items.isEmpty)
            const EmptyState(
              title: 'Item pembelian kosong',
              subtitle: 'Tambahkan barang/bahan yang dibeli.',
            )
          else
            ..._items.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;

              return NiceCard(
                padding: EdgeInsets.zero,
                onTap: () => _openItemForm(index),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: CircleAvatar(child: Text('${index + 1}')),
                  title: Text(item.namaBarang,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(
                    '${item.qty.toStringAsFixed(0)} ${item.satuan} x Rp ${AppUi.money(item.hargaItem)}\n'
                    'Subtotal: Rp ${AppUi.money(item.subtotal)}',
                  ),
                  trailing: IconButton(
                    onPressed: () => setState(() => _items.removeAt(index)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              );
            }),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: Text(_isSaving ? 'Menyimpan...' : 'Submit Pembelian'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pembelian'),
        actions: [
          IconButton(
              onPressed: _loadMasterData, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _body(),
    );
  }
}

class _PurchaseItemDraft {
  final String namaBarang;
  final num qty;
  final String satuan;
  final num hargaItem;
  final String catatan;

  const _PurchaseItemDraft({
    required this.namaBarang,
    required this.qty,
    required this.satuan,
    required this.hargaItem,
    required this.catatan,
  });

  num get subtotal => qty * hargaItem;

  Map<String, dynamic> toJson() {
    return {
      'product_id': null,
      'kode_sku': null,
      'kode_barcode': null,
      'nama_barang': namaBarang,
      'qty': qty,
      'satuan': satuan,
      'harga_item': hargaItem,
      'catatan': catatan,
    };
  }
}
