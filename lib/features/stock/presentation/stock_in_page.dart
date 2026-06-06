import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import 'qr_scan_page.dart';

class StockInPage extends StatefulWidget {
  const StockInPage({super.key});

  @override
  State<StockInPage> createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _qtyController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isDemoSuperAdmin = false;
  String? _errorMessage;
  String _sumber = 'produksi selesai';
  Map<String, dynamic>? _selectedProduct;
  List<Map<String, dynamic>> _products = [];

  final List<String> _sumberOptions = const [
    'produksi selesai',
    'retur',
    'pembelian',
    'adjustment',
  ];

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authUser = _client.auth.currentUser;
      if (authUser != null) {
        final profile = await _client
            .from('users')
            .select('role_id, is_demo_account, username, email')
            .eq('user_id', authUser.id)
            .maybeSingle();
        final role = profile?['role_id']?.toString().toLowerCase().trim() ?? '';
        final username = profile?['username']?.toString().toLowerCase().trim() ?? '';
        final email = profile?['email']?.toString().toLowerCase().trim() ?? '';
        _isDemoSuperAdmin = role == 'demo_super_admin' ||
            profile?['is_demo_account'] == true ||
            username == 'demo_super_admin' ||
            email.contains('demo_super_admin');
      }

      final data = await _client
          .from('products')
          .select('product_id, kode_sku, kode_barcode, nama_barang, stock_saat_ini, satuan, status')
          .eq('status', 'active')
          .order('nama_barang', ascending: true);

      if (!mounted) return;

      setState(() {
        _products = (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
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


  Future<void> _scanProduct() async {
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const QrScanPage(
          title: 'Scan Barcode Produk',
          instruction: 'Arahkan kamera ke barcode produk. Area scan dibuat melebar agar barcode lebih mudah terbaca.',
          scanMode: ScanMode.barcode,
        ),
      ),
    );

    if (value == null || value.trim().isEmpty) return;

    final code = value.trim().toLowerCase();
    final matches = _products.where((item) {
      return AppUi.text(item['kode_barcode']).toLowerCase() == code ||
          AppUi.text(item['kode_sku']).toLowerCase() == code;
    }).toList();

    if (matches.isEmpty) {
      AppUi.showSnack('Barcode/SKU tidak ditemukan di master barang: $value');
      return;
    }

    setState(() => _selectedProduct = matches.first);
    AppUi.showSnack('Produk dipilih: ${AppUi.text(matches.first['nama_barang'])}');
  }


  Future<int> _queueMarketplaceSyncForProduct(String productId) async {
    try {
      final response = await _client.rpc(
        'marketplace_queue_stock_sync_for_product_change',
        params: {
          'p_product_id': productId,
          'p_reason': 'stock_in',
        },
      );

      if (response is num) return response.toInt();
      return int.tryParse(response?.toString() ?? '0') ?? 0;
    } catch (_) {
      // Stock in tidak boleh gagal hanya karena sync queue marketplace error.
      // Manusia gudang butuh proses jalan dulu, bukan disandera API.
      return 0;
    }
  }

  Future<void> _save() async {
    if (_isDemoSuperAdmin) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Mode demo hanya bisa melihat data. Simpan stok masuk dikunci.')),
      );
      return;
    }
    final product = _selectedProduct;
    final qty = num.tryParse(_qtyController.text.trim()) ?? 0;

    if (product == null) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Pilih produk dulu')),
      );
      return;
    }

    if (qty <= 0) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Qty harus lebih dari 0')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      await _client.rpc('stock_in_for_app', params: {
        'p_product_id': product['product_id'],
        'p_qty': qty,
        'p_sumber': _sumber,
        'p_catatan': _noteController.text.trim(),
      });

      final syncQueued = await _queueMarketplaceSyncForProduct(
        product['product_id'].toString(),
      );

      if (!mounted) return;

      _qtyController.clear();
      _noteController.clear();
      setState(() => _selectedProduct = null);

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            syncQueued > 0
                ? 'Stok masuk berhasil. $syncQueued SKU siap disinkronkan ke marketplace.'
                : 'Stok masuk berhasil. Belum ada mapping marketplace aktif untuk produk ini.',
          ),
        ),
      );

      _loadProducts();
    } on PostgrestException catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Gagal stock in: $error')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();

    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadProducts);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        FuturisticHeader(
          icon: Icons.input_outlined,
          title: 'Stok Masuk',
          subtitle: 'Input stock masuk berdasarkan produk aktif. Staff warehouse bisa pilih produk manual atau scan barcode.',
          stats: [
            StatPill(label: 'Produk Aktif', value: _products.length.toString()),
            StatPill(label: 'Sumber', value: _sumber),
          ],
        ),
        const SizedBox(height: 16),
        NiceCard(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: _isDemoSuperAdmin ? null : _scanProduct,
                  icon: const Icon(Icons.barcode_reader),
                  label: const Text('Scan Barcode'),
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: _selectedProduct?['product_id']?.toString(),
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Produk',
                  border: OutlineInputBorder(),
                ),
                items: _products.map((product) {
                  final stock = AppUi.toNum(product['stock_saat_ini']);
                  return DropdownMenuItem(
                    value: product['product_id'].toString(),
                    child: Text(
                      '${AppUi.text(product['nama_barang'])} • ${AppUi.text(product['kode_barcode'])} • Stock ${stock.toStringAsFixed(0)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _selectedProduct = _products.firstWhere(
                      (item) => item['product_id'].toString() == value,
                    );
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _qtyController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Qty Masuk',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _sumber,
                decoration: const InputDecoration(
                  labelText: 'Sumber Masuk',
                  border: OutlineInputBorder(),
                ),
                items: _sumberOptions
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _sumber = value);
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
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_isSaving || _isDemoSuperAdmin) ? null : _save,
                  icon: _isSaving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: Text(_isSaving ? 'Menyimpan...' : 'Simpan Stok Masuk'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stok Masuk'),
        actions: [
          IconButton(onPressed: _loadProducts, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _body(),
    );
  }
}
