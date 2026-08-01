import 'package:flutter/material.dart';
import '../../../core/ui/app_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/product.dart';
import '../repositories/product_repository.dart';

class ProductFormPage extends StatefulWidget {
  final Product? product;

  const ProductFormPage({
    super.key,
    this.product,
  });

  @override
  State<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends State<ProductFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _repository = ProductRepository();

  final _kodeSkuController = TextEditingController();
  final _kodeBarcodeController = TextEditingController();
  final _namaBarangController = TextEditingController();
  final _kategoriController = TextEditingController();
  final _satuanController = TextEditingController();
  final _stockAwalController = TextEditingController();
  final _lowStockController = TextEditingController();
  final _lokasiRakController = TextEditingController();

  bool _isSaving = false;
  String _status = 'active';

  bool get _isEdit => widget.product != null;

  @override
  void initState() {
    super.initState();

    final product = widget.product;

    if (product != null) {
      _kodeSkuController.text = product.kodeSku;
      _kodeBarcodeController.text = product.kodeBarcode ?? product.kodeSku;
      _namaBarangController.text = product.namaBarang;
      _kategoriController.text = product.kategori ?? '';
      _satuanController.text = product.satuan;
      _stockAwalController.text = product.stockAwal.toString();
      _lowStockController.text = product.lowStockLimit.toString();
      _lokasiRakController.text = product.lokasiRak ?? '';
      _status = product.status;
    } else {
      _kodeSkuController.text = '';
      _kodeBarcodeController.text = '';
      _namaBarangController.text = '';
      _kategoriController.text = '';
      _satuanController.text = 'pcs';
      _stockAwalController.text = '0';
      _lowStockController.text = '0';
      _lokasiRakController.text = '';
      _status = 'active';
    }
  }

  @override
  void dispose() {
    _kodeSkuController.dispose();
    _kodeBarcodeController.dispose();
    _namaBarangController.dispose();
    _kategoriController.dispose();
    _satuanController.dispose();
    _stockAwalController.dispose();
    _lowStockController.dispose();
    _lokasiRakController.dispose();
    super.dispose();
  }

  double _parseDouble(String value) {
    return AppUi.parseMoneyInput(value).toDouble();
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Wajib diisi';
    }

    return null;
  }

  String? _validateNumber(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Wajib diisi';
    }

    final number = double.tryParse(
      value.trim().replaceAll('.', '').replaceAll(',', '.'),
    );

    if (number == null) {
      return 'Harus angka';
    }

    if (number < 0) {
      return 'Tidak boleh minus';
    }

    return null;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) {
      return;
    }

    final kodeSku = _kodeSkuController.text.trim();
    final kodeBarcode = _kodeBarcodeController.text.trim();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_isEdit ? 'Update Barang?' : 'Tambah Barang?'),
          content: Text(
            _isEdit
                ? 'Data barang akan diperbarui.'
                : 'Barang baru akan ditambahkan ke master SKU.',
          ),
          actions: [
            TextButton(
              onPressed: () => AppUi.safePop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => AppUi.safePop(context, true),
              child: const Text('Simpan'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    var success = false;

    try {
      if (_isEdit) {
        await _repository.updateProduct(
          productId: widget.product!.productId,
          kodeSku: kodeSku,
          kodeBarcode: kodeBarcode,
          namaBarang: _namaBarangController.text,
          kategori: _kategoriController.text,
          satuan: _satuanController.text,
          lowStockLimit: _parseDouble(_lowStockController.text),
          lokasiRak: _lokasiRakController.text,
          status: _status,
        );
      } else {
        await _repository.createProduct(
          kodeSku: kodeSku,
          kodeBarcode: kodeBarcode,
          namaBarang: _namaBarangController.text,
          kategori: _kategoriController.text,
          satuan: _satuanController.text,
          stockAwal: _parseDouble(_stockAwalController.text),
          lowStockLimit: _parseDouble(_lowStockController.text),
          lokasiRak: _lokasiRakController.text,
        );
      }

      if (!mounted) return;

      success = true;
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PostgrestException catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(error.message),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Gagal simpan barang: $error'),
        ),
      );
    } finally {
      if (!success && mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _isEdit ? 'Edit Barang' : 'Tambah Barang';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            NiceCard(
              padding: const EdgeInsets.all(18),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _kodeSkuController,
                      validator: _required,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Kode SKU',
                        hintText: 'Contoh: 11ACS',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _kodeBarcodeController,
                      validator: _required,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Kode Barcode',
                        hintText: 'Contoh: 11ACS',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _namaBarangController,
                      validator: _required,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Nama Barang',
                        hintText: 'Contoh: STRIPPED SHIRT MOCCA S',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _kategoriController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Kategori',
                        hintText: 'Contoh: Fashion',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _satuanController,
                      validator: _required,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Satuan',
                        hintText: 'Contoh: pcs',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _stockAwalController,
                      enabled: !_isEdit,
                      validator: _validateNumber,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: _isEdit
                            ? 'Stock Awal tidak bisa diedit di sini'
                            : 'Stock Awal',
                        hintText: 'Contoh: 0',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (_isEdit) ...[
                      const SizedBox(height: 6),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Stock diubah lewat Stok Masuk / Stok Keluar, bukan dari edit barang.',
                          style: TextStyle(
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _lowStockController,
                      validator: _validateNumber,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Low Stock Limit',
                        hintText: 'Contoh: 5',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _lokasiRakController,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'Lokasi Rak / Gudang',
                        hintText: 'Contoh: Rak A1',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_isEdit) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _status,
                        decoration: const InputDecoration(
                          labelText: 'Status',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'active',
                            child: Text('Aktif'),
                          ),
                          DropdownMenuItem(
                            value: 'inactive',
                            child: Text('Nonaktif'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;

                          setState(() {
                            _status = value;
                          });
                        },
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(
                        _isSaving ? 'Menyimpan...' : 'Simpan',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
