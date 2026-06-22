// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../../core/constants/app_roles.dart';
import '../../../models/app_user.dart';

class ProductListPage extends StatefulWidget {
  final AppUser? currentUser;

  const ProductListPage({
    super.key,
    this.currentUser,
  });

  @override
  State<ProductListPage> createState() => _ProductListPageState();
}

class _ProductListPageState extends State<ProductListPage> {
  final SupabaseClient _client = Supabase.instance.client;

  String? _profileRoleId;

  String get _roleId =>
      (widget.currentUser?.role.roleId ?? _profileRoleId ?? '')
          .trim()
          .toLowerCase();
  bool get _isDemoSuperAdmin => _roleId == 'demo_super_admin';
  bool get _isSuperAdmin => _roleId == 'super_admin';
  bool get _canSeeFinanceSkuFields => _isSuperAdmin;
  bool get _canEditFinanceSkuFields => _isSuperAdmin;

  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  String? _errorMessage;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _filtered = [];

  @override
  void initState() {
    super.initState();
    _loadData();
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
      if (widget.currentUser == null) {
        final authUser = _client.auth.currentUser;
        if (authUser != null) {
          final profile = await _client
              .from('users')
              .select('role_id')
              .eq('user_id', authUser.id)
              .maybeSingle();
          _profileRoleId = profile == null
              ? null
              : Map<String, dynamic>.from(profile as Map)['role_id']
                  ?.toString();
        }
      }

      final data = await _client
          .from('products')
          .select(
              'product_id, kode_sku, kode_barcode, nama_barang, kategori, satuan, stock_saat_ini, low_stock_limit, lokasi_rak, status, created_at')
          .order('nama_barang', ascending: true);

      final items =
          (data as List).map((e) => Map<String, dynamic>.from(e)).toList();

      if (!mounted) return;

      setState(() {
        _items = items;
        _applyFilter(_searchController.text, notify: false);
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

  void _applyFilter(String value, {bool notify = true}) {
    final keyword = value.trim().toLowerCase();

    final result = _items.where((item) {
      return AppUi.text(item['nama_barang']).toLowerCase().contains(keyword) ||
          AppUi.text(item['kode_sku']).toLowerCase().contains(keyword) ||
          AppUi.text(item['kode_barcode']).toLowerCase().contains(keyword) ||
          AppUi.text(item['kategori']).toLowerCase().contains(keyword);
    }).toList();

    if (notify) {
      setState(() => _filtered = result);
    } else {
      _filtered = result;
    }
  }

  num _numOr(dynamic value, num fallback) {
    final parsed = AppUi.toNum(value);
    return parsed == 0 && value == null ? fallback : parsed;
  }

  void _showDemoBlocked() {
    AppUi.safeSnack(context,
        'Mode demo hanya bisa melihat data. Aksi tambah, edit, dan simpan dikunci.');
  }

  Future<void> _openForm([Map<String, dynamic>? product]) async {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return;
    }
    final skuController =
        TextEditingController(text: AppUi.text(product?['kode_sku'], ''));
    final barcodeController =
        TextEditingController(text: AppUi.text(product?['kode_barcode'], ''));
    final nameController =
        TextEditingController(text: AppUi.text(product?['nama_barang'], ''));
    final categoryController =
        TextEditingController(text: AppUi.text(product?['kategori'], ''));
    final unitController =
        TextEditingController(text: AppUi.text(product?['satuan'], 'pcs'));
    final stockController = TextEditingController(
        text: AppUi.toNum(product?['stock_saat_ini']).toStringAsFixed(0));
    final lowController = TextEditingController(
        text: AppUi.toNum(product?['low_stock_limit']).toStringAsFixed(0));
    final locationController =
        TextEditingController(text: AppUi.text(product?['lokasi_rak'], ''));
    String status = AppUi.text(product?['status'], 'active') == 'inactive'
        ? 'inactive'
        : 'active';
    bool saving = false;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      barrierColor: Colors.black.withOpacity(0.72),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> submit() async {
              final name = nameController.text.trim();
              final sku = skuController.text.trim();
              final barcode = barcodeController.text.trim();

              if (name.isEmpty) {
                AppUi.safeSnack(sheetContext, 'Nama barang wajib diisi');
                return;
              }

              if (barcode.isEmpty) {
                AppUi.safeSnack(sheetContext, 'Barcode wajib diisi');
                return;
              }

              var success = false;
              try {
                setSheetState(() => saving = true);

                final payload = <String, dynamic>{
                  if (product != null) 'product_id': product['product_id'],
                  'nama_barang': name,
                  'kode_sku': sku.isEmpty ? barcode : sku,
                  'kode_barcode': barcode,
                  'kategori': categoryController.text.trim(),
                  'satuan': unitController.text.trim().isEmpty
                      ? 'pcs'
                      : unitController.text.trim(),
                  'stock_saat_ini': num.tryParse(
                          stockController.text.trim().replaceAll(',', '.')) ??
                      0,
                  'low_stock_limit': num.tryParse(
                          lowController.text.trim().replaceAll(',', '.')) ??
                      0,
                  'lokasi_rak': locationController.text.trim(),
                  'status': status,
                  'updated_at': DateTime.now().toIso8601String(),
                  if (product == null)
                    'created_at': DateTime.now().toIso8601String(),
                };

                await _client.from('products').upsert(payload);

                success = true;
                AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (error) {
                AppUi.safeSnack(sheetContext, error.message);
              } catch (error) {
                AppUi.safeSnack(sheetContext, 'Gagal simpan produk: $error');
              } finally {
                if (!success && sheetContext.mounted) {
                  setSheetState(() => saving = false);
                }
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
                    product == null
                        ? 'Tambah SKU / Barang'
                        : 'Edit SKU / Barang',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                          labelText: 'Nama Barang',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  TextField(
                      controller: skuController,
                      decoration: const InputDecoration(
                          labelText: 'Kode SKU', border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  TextField(
                      controller: barcodeController,
                      decoration: const InputDecoration(
                          labelText: 'Kode Barcode / QR',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: categoryController,
                            decoration: const InputDecoration(
                                labelText: 'Kategori',
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
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: stockController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'Stock Saat Ini',
                                border: OutlineInputBorder()))),
                    const SizedBox(width: 10),
                    Expanded(
                        child: TextField(
                            controller: lowController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'Low Stock Limit',
                                border: OutlineInputBorder()))),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                      controller: locationController,
                      decoration: const InputDecoration(
                          labelText: 'Lokasi Rak / Gudang',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: status,
                    decoration: const InputDecoration(
                        labelText: 'Status', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'active', child: Text('Active')),
                      DropdownMenuItem(
                          value: 'inactive', child: Text('Inactive')),
                    ],
                    onChanged: saving
                        ? null
                        : (value) {
                            if (value == null) return;
                            setSheetState(() => status = value);
                          },
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.save_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Simpan'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      skuController.dispose();
      barcodeController.dispose();
      nameController.dispose();
      categoryController.dispose();
      unitController.dispose();
      stockController.dispose();
      lowController.dispose();
      locationController.dispose();
    });

    if (result == true) await _loadData();
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();

    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadData);
    }

    final lowStock = _items.where((item) {
      return AppUi.toNum(item['stock_saat_ini']) <=
          AppUi.toNum(item['low_stock_limit']);
    }).length;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          FuturisticHeader(
            icon: Icons.inventory_2_outlined,
            title: 'Master Barang',
            subtitle: _isDemoSuperAdmin
                ? 'Mode demo: data produk hanya bisa dilihat. Tambah, edit, dan simpan dikunci.'
                : 'Edit stok, barcode, lokasi rak, dan batas minimum per SKU.',
            stats: [
              StatPill(label: 'Produk', value: _items.length.toString()),
              StatPill(label: 'Low Stock', value: lowStock.toString()),
              StatPill(label: 'Filtered', value: _filtered.length.toString()),
            ],
          ),
          const SizedBox(height: 14),
          SearchBox(
            controller: _searchController,
            onChanged: _applyFilter,
            hint: 'Cari nama, SKU, barcode',
          ),
          const SizedBox(height: 14),
          if (_filtered.isEmpty)
            const EmptyState(
              title: 'Produk kosong',
              subtitle: 'Tambahkan SKU/barang untuk transaksi stock.',
            )
          else
            ..._filtered.map((item) {
              final stock = AppUi.toNum(item['stock_saat_ini']);
              final limit = AppUi.toNum(item['low_stock_limit']);
              final isLow = stock <= limit;
              final color = isLow ? AppUi.red : AppUi.green;
              return NiceCard(
                padding: EdgeInsets.zero,
                onTap: _isDemoSuperAdmin
                    ? _showDemoBlocked
                    : () => _openForm(item),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: CircleAvatar(
                    backgroundColor: color.withOpacity(0.13),
                    child: Icon(Icons.inventory_2_outlined, color: color),
                  ),
                  title: Text(
                    AppUi.text(item['nama_barang']),
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    'SKU: ${AppUi.text(item['kode_sku'])}\n'
                    'Barcode: ${AppUi.text(item['kode_barcode'])}\n'
                    'Stock: ${stock.toStringAsFixed(0)} ${AppUi.text(item['satuan'], 'pcs')} • Limit: ${limit.toStringAsFixed(0)}\n'
                    'Lokasi: ${AppUi.text(item['lokasi_rak'])}',
                  ),
                  isThreeLine: true,
                  trailing: Icon(_isDemoSuperAdmin
                      ? Icons.visibility_outlined
                      : Icons.edit_outlined),
                ),
              );
            }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Master SKU'),
        actions: [
          IconButton(onPressed: _loadData, icon: Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: _isDemoSuperAdmin
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: Icon(Icons.add),
              label: Text('Produk'),
            ),
      body: _body(),
    );
  }
}
