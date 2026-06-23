import 'package:flutter/material.dart';
import '../../../core/ui/app_ui.dart';
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
      child: Wrap(
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Master Barang'),
      ),
      body: _body(),
    );
  }
}

class _ProductItem {
  final String productId;
  final String kodeSku;
  final String kodeBarcode;
  final String namaBarang;
  final num stockSaatIni;
  final num lowStockLimit;

  const _ProductItem({
    required this.productId,
    required this.kodeSku,
    required this.kodeBarcode,
    required this.namaBarang,
    required this.stockSaatIni,
    required this.lowStockLimit,
  });

  factory _ProductItem.fromMap(Map<String, dynamic> map) {
    return _ProductItem(
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
