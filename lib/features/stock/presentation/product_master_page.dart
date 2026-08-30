import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../../../core/utils/file_download.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProductMasterPage extends StatefulWidget {
  const ProductMasterPage({super.key});

  @override
  State<ProductMasterPage> createState() => _ProductMasterPageState();
}

class _ProductMasterPageState extends State<ProductMasterPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  bool _isExporting = false;
  String? _errorMessage;
  List<_ProductItem> _allItems = [];

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await _client.from('products').select('*');

      if (!mounted) return;

      final items = List<Map<String, dynamic>>.from(data)
          .map(_ProductItem.fromMap)
          .toList();

      items.sort((a, b) => a.namaBarang.compareTo(b.namaBarang));

      setState(() {
        _allItems = items;
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<_ProductItem> get _filteredItems {
    final keyword = _searchController.text.trim().toLowerCase();

    if (keyword.isEmpty) return _allItems;

    return _allItems.where((item) {
      return item.namaBarang.toLowerCase().contains(keyword) ||
          item.kodeSku.toLowerCase().contains(keyword) ||
          item.kodeBarcode.toLowerCase().contains(keyword);
    }).toList();
  }

  Future<void> _editStock(_ProductItem item) async {
    final stockController = TextEditingController(
      text: item.stockSaatIni.toStringAsFixed(0),
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit Stock'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(item.namaBarang),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: stockController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Stock Saat Ini',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
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

    final newStock = num.tryParse(stockController.text.trim());
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      stockController.dispose();
    });

    if (result != true) return;

    if (newStock == null) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Stock tidak valid')),
      );
      return;
    }

    try {
      await _client.from('products').update({
        'stock_saat_ini': newStock,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('product_id', item.productId);

      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Stok berhasil diupdate')),
      );

      _loadData();
    } on PostgrestException catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Gagal update stock: $error')),
      );
    }
  }

  Future<void> _downloadSemuaStockData() async {
    if (_allItems.isEmpty) {
      if (!mounted) return;
      AppUi.showSnack('Tidak ada data produk untuk di-download');
      return;
    }

    setState(() => _isExporting = true);

    try {
      final progressResponse =
          await _client.from('production_progress').select('*');
      final itemsResponse =
          await _client.from('production_progress_items').select('*');

      final progressList =
          List<Map<String, dynamic>>.from(progressResponse);
      final itemsList =
          List<Map<String, dynamic>>.from(itemsResponse);

      final Map<String, double> prodQtyByProductId = {};
      final Map<String, double> prodQtyByNameSku = {};
      final Map<String, double> prodQtyBySku = {};
      final Set<String> progressIdsWithItems = {};

      for (final row in itemsList) {
        final progressId = row['progress_id']?.toString().trim();
        if (progressId != null && progressId.isNotEmpty) {
          progressIdsWithItems.add(progressId);
        }

        final qty = AppUi.toNum(row['qty']).toDouble();
        if (qty <= 0) continue;

        final productId = row['product_id']?.toString().trim();
        final name = (row['local_product_name'] ?? row['product_name'] ?? row['nama_barang'])
            ?.toString()
            .trim()
            .toLowerCase();
        final sku = (row['local_sku'] ?? row['sku'] ?? row['kode_sku'])
            ?.toString()
            .trim()
            .toLowerCase();

        if (productId != null && productId.isNotEmpty) {
          prodQtyByProductId[productId] =
              (prodQtyByProductId[productId] ?? 0.0) + qty;
        }

        if (name != null && name.isNotEmpty && sku != null && sku.isNotEmpty && sku != '-') {
          final nameSkuKey = '$name|$sku';
          prodQtyByNameSku[nameSkuKey] = (prodQtyByNameSku[nameSkuKey] ?? 0.0) + qty;
        } else if (sku != null && sku.isNotEmpty && sku != '-') {
          prodQtyBySku[sku] = (prodQtyBySku[sku] ?? 0.0) + qty;
        }
      }

      for (final row in progressList) {
        final progressId = row['progress_id']?.toString().trim();
        if (progressId != null && progressIdsWithItems.contains(progressId)) {
          continue;
        }

        final qty = AppUi.toNum(row['qty']).toDouble();
        if (qty <= 0) continue;

        final productId = row['product_id']?.toString().trim();
        final name = (row['product_name'] ?? row['nama_barang'] ?? row['local_product_name'])
            ?.toString()
            .trim()
            .toLowerCase();
        final sku = (row['sku'] ?? row['kode_sku'] ?? row['local_sku'])
            ?.toString()
            .trim()
            .toLowerCase();

        if (productId != null && productId.isNotEmpty) {
          prodQtyByProductId[productId] =
              (prodQtyByProductId[productId] ?? 0.0) + qty;
        }

        if (name != null && name.isNotEmpty && sku != null && sku.isNotEmpty && sku != '-') {
          final nameSkuKey = '$name|$sku';
          prodQtyByNameSku[nameSkuKey] = (prodQtyByNameSku[nameSkuKey] ?? 0.0) + qty;
        } else if (sku != null && sku.isNotEmpty && sku != '-') {
          prodQtyBySku[sku] = (prodQtyBySku[sku] ?? 0.0) + qty;
        }
      }

      final workbook = Excel.createExcel();
      final Sheet sheet = workbook['Semua Stock Data'];
      final defaultSheet = workbook.getDefaultSheet();
      if (defaultSheet != null && workbook.tables.length > 1) {
        workbook.delete(defaultSheet);
      }

      final headers = <String>[
        'Tenant ID',
        'Product ID',
        'Kode SKU',
        'Nama Barang',
        'Stok Saat Ini',
        'Qty Produksi Berjalan',
        'Total Stok Akhir',
      ];

      sheet.appendRow(
          headers.map<CellValue>((h) => TextCellValue(h)).toList());

      for (final item in _allItems) {
        final skuKey = item.kodeSku.trim().toLowerCase();
        final nameKey = item.namaBarang.trim().toLowerCase();
        final prodIdKey = item.productId.trim();
        final nameSkuKey = '$nameKey|$skuKey';

        double qtyProduksiBerjalan = 0.0;
        if (prodIdKey.isNotEmpty &&
            prodQtyByProductId.containsKey(prodIdKey)) {
          qtyProduksiBerjalan = prodQtyByProductId[prodIdKey]!;
        } else if (skuKey.isNotEmpty &&
            skuKey != '-' &&
            prodQtyByNameSku.containsKey(nameSkuKey)) {
          qtyProduksiBerjalan = prodQtyByNameSku[nameSkuKey]!;
        }

        final totalStokAkhir = item.stockSaatIni + qtyProduksiBerjalan;

        sheet.appendRow([
          TextCellValue(item.tenantId),
          TextCellValue(item.productId),
          TextCellValue(item.kodeSku),
          TextCellValue(item.namaBarang),
          DoubleCellValue(item.stockSaatIni.toDouble()),
          DoubleCellValue(qtyProduksiBerjalan),
          DoubleCellValue(totalStokAkhir.toDouble()),
        ]);
      }

      final bytes = workbook.encode();
      if (bytes == null) throw Exception('Gagal membuat file XLSX.');

      final data = Uint8List.fromList(bytes);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final fileName = 'semua_stock_data_$stamp.xlsx';
      const mimeType =
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

      final downloaded = await downloadBytesAsFile(
        bytes: data,
        fileName: fileName,
        mimeType: mimeType,
      );

      if (downloaded) {
        if (!mounted) return;
        AppUi.showSnack('Download dimulai: $fileName');
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      if (!mounted) return;
      AppUi.showSnack('File Excel berhasil dibuat: $fileName');

      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Download Semua Stock Data',
        text: 'File export stok master dan produksi berjalan.',
      );
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal export stock data: $error');
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Widget _summaryCard() {
    final totalSku = _allItems.length;
    final totalStock = _allItems.fold<num>(
      0,
      (sum, item) => sum + item.stockSaatIni,
    );
    final lowStock = _allItems
        .where((item) => item.stockSaatIni <= item.lowStockLimit)
        .length;

    return NiceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _miniStat(
                  'Total SKU', totalSku.toString(), Icons.inventory_2_outlined),
              _miniStat('Total Stock', totalStock.toStringAsFixed(0),
                  Icons.warehouse_outlined),
              _miniStat(
                  'Low Stock', lowStock.toString(), Icons.warning_amber_rounded),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isExporting ? null : _downloadSemuaStockData,
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _isExporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.file_download_outlined),
              label: Text(
                  _isExporting ? 'Memproses Export...' : 'Download Semua Stock Data'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, IconData icon) {
    final theme = Theme.of(context);
    return Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: AppUi.tintedDecoration(
        context,
        color: theme.colorScheme.primary,
        radius: 14,
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppUi.mutedText(context, 0.66),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return const LoadingState();
    }

    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadData);
    }

    final items = _filteredItems;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _summaryCard(),
          const SizedBox(height: 12),
          SearchBox(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            hint: 'Cari SKU, barcode, atau nama barang',
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'Barang tidak ditemukan',
              subtitle: 'Coba kata kunci lain atau tambahkan SKU baru.',
            )
          else
            ...items.map((item) {
              final isLow = item.stockSaatIni <= item.lowStockLimit;
              final color =
                  isLow ? AppUi.orange : Theme.of(context).colorScheme.primary;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: NiceCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(14),
                    leading: Container(
                      width: 42,
                      height: 42,
                      decoration: AppUi.tintedDecoration(
                        context,
                        color: color,
                        radius: 12,
                      ),
                      child: Icon(
                        isLow
                            ? Icons.warning_amber_outlined
                            : Icons.inventory_2_outlined,
                        color: color,
                      ),
                    ),
                    title: Text(
                      item.namaBarang,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'SKU: ${item.kodeSku}\n'
                      'Barcode: ${item.kodeBarcode}\n'
                      'Stock: ${item.stockSaatIni.toStringAsFixed(0)} | Low: ${item.lowStockLimit.toStringAsFixed(0)}',
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _editStock(item),
                    ),
                  ),
                ),
              );
            }),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WebResponsiveScaffold(
      title: 'Master Barang',
      actions: [
        IconButton(
          icon: _isExporting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.file_download_outlined),
          tooltip: 'Download Semua Stock Data',
          onPressed: _isExporting ? null : _downloadSemuaStockData,
        ),
      ],
      body: _body(),
    );
  }
}

class _ProductItem {
  final String tenantId;
  final String productId;
  final String kodeSku;
  final String kodeBarcode;
  final String namaBarang;
  final num stockSaatIni;
  final num lowStockLimit;

  const _ProductItem({
    required this.tenantId,
    required this.productId,
    required this.kodeSku,
    required this.kodeBarcode,
    required this.namaBarang,
    required this.stockSaatIni,
    required this.lowStockLimit,
  });

  factory _ProductItem.fromMap(Map<String, dynamic> map) {
    return _ProductItem(
      tenantId: map['tenant_id']?.toString() ?? '',
      productId: map['product_id']?.toString() ?? '',
      kodeSku: map['kode_sku']?.toString() ??
          map['sku']?.toString() ??
          map['kodeSku']?.toString() ??
          '-',
      kodeBarcode: map['kode_barcode']?.toString() ??
          map['qr_code_value']?.toString() ??
          map['barcode']?.toString() ??
          '-',
      namaBarang: map['nama_barang']?.toString() ??
          map['nama_sku']?.toString() ??
          map['name']?.toString() ??
          '-',
      stockSaatIni: _toNum(
        map['stock_saat_ini'] ?? map['stock'] ?? map['current_stock'],
      ),
      lowStockLimit: _toNum(
        map['low_stock_limit'] ?? map['limit_low_stock'] ?? 0,
      ),
    );
  }

  static num _toNum(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value;
    return num.tryParse(value.toString()) ?? 0;
  }
}
