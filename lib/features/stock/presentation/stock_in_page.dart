import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../../marketplace/models/marketplace_return_review_item.dart';
import '../../marketplace/services/marketplace_order_pick_service.dart';
import 'qr_scan_page.dart';

class StockInPage extends StatefulWidget {
  const StockInPage({super.key});

  @override
  State<StockInPage> createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final MarketplaceOrderPickService _returnPickService =
      MarketplaceOrderPickService();
  final TextEditingController _qtyController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _returnMode = false;
  bool _returnBusy = false;
  bool _isDemoSuperAdmin = false;
  String _tenantId = '';
  String? _errorMessage;
  String _sumber = 'produksi selesai';
  Map<String, dynamic>? _selectedProduct;
  Map<String, dynamic>? _lastReturnMatch;
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
            .select('tenant_id, role_id, is_demo_account, username, email')
            .eq('user_id', authUser.id)
            .maybeSingle();
        _tenantId = profile?['tenant_id']?.toString().trim() ?? '';
        final role = profile?['role_id']?.toString().toLowerCase().trim() ?? '';
        final username =
            profile?['username']?.toString().toLowerCase().trim() ?? '';
        final email = profile?['email']?.toString().toLowerCase().trim() ?? '';
        _isDemoSuperAdmin = role == 'demo_super_admin' ||
            profile?['is_demo_account'] == true ||
            username == 'demo_super_admin' ||
            email.contains('demo_super_admin');
      }

      dynamic query = _client
          .from('products')
          .select(
              'product_id, kode_sku, kode_barcode, nama_barang, stock_saat_ini, satuan, status')
          .eq('status', 'active');
      if (_tenantId.isNotEmpty) query = query.eq('tenant_id', _tenantId);
      final data = await query.order('nama_barang', ascending: true);

      if (!mounted) return;

      setState(() {
        _products =
            (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
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
          instruction:
              'Arahkan kamera ke barcode produk. Area scan dibuat melebar agar barcode lebih mudah terbaca.',
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
    AppUi.showSnack(
        'Produk dipilih: ${AppUi.text(matches.first['nama_barang'])}');
  }

  bool _isBlank(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty || text == '-';
  }

  String _returnSourceLabel(Map<String, dynamic> row) {
    final source = AppUi.text(row['source']).toLowerCase();
    final action = AppUi.text(row['recommended_action']).toUpperCase();
    final status =
        AppUi.text(row['order_status'] ?? row['case_status']).toUpperCase();
    if (action.contains('CANCEL') || status.contains('CANCEL')) {
      return 'cancel';
    }
    if (source.contains('refund') ||
        source.contains('return') ||
        action.contains('REFUND') ||
        action.contains('RETURN')) {
      return 'refund/return';
    }
    return 'order';
  }

  String _returnRowTitle(Map<String, dynamic> row) {
    final order = AppUi.text(row['external_order_id'] ?? row['order_sn']);
    final product = AppUi.text(row['local_product_name'] ??
        row['marketplace_product_name'] ??
        row['marketplace_variant_name']);
    if (!_isBlank(product)) return product;
    return _isBlank(order) ? 'Data return' : order;
  }

  String _returnRowSubtitle(Map<String, dynamic> row) {
    final parts = <String>[
      _returnSourceLabel(row),
      AppUi.text(row['marketplace']),
      AppUi.text(row['shop_name'] ?? row['account_shop_name']),
      'Order ${AppUi.text(row['external_order_id'] ?? row['order_sn'])}',
      'Resi ${AppUi.text(row['matched_resi'] ?? row['tracking_number'])}',
    ].where((part) => !_isBlank(part)).toList();
    return parts.join(' · ');
  }

  MarketplaceReturnReviewItem _returnReviewItemFromRow(
      Map<String, dynamic> row) {
    return MarketplaceReturnReviewItem.fromMap(row);
  }

  num _returnQtyFromRow(
      Map<String, dynamic> row, MarketplaceReturnReviewItem item) {
    final values = [
      item.itemReturnedQty,
      row['qty_return'],
      row['return_qty'],
      row['returned_qty'],
      row['item_returned_qty'],
      row['return_quantity'],
      row['refund_quantity'],
    ];
    for (final value in values) {
      final qty = AppUi.toNum(value);
      if (qty > 0) return qty;
    }
    return 0;
  }

  ({bool canStockIn, String reason, num qty}) _returnStockEligibility(
    Map<String, dynamic> row,
    MarketplaceReturnReviewItem item,
  ) {
    final returnQty = _returnQtyFromRow(row, item);

    if (_isBlank(item.marketplaceOrderItemId)) {
      return (
        canStockIn: false,
        reason: 'Item order belum tersedia untuk dicatat.',
        qty: returnQty,
      );
    }
    if (_isBlank(item.mappedProductId)) {
      return (
        canStockIn: false,
        reason: 'SKU lokal belum mapping, stock tidak bisa ditambah otomatis.',
        qty: returnQty,
      );
    }
    if (!item.isPending) {
      return (
        canStockIn: false,
        reason: 'Review return item ini sudah diproses.',
        qty: returnQty,
      );
    }

    final qty = returnQty > 0
        ? returnQty
        : (item.qtyTotal > 0
            ? item.qtyTotal
            : AppUi.toNum(row['quantity'] ?? row['item_qty'] ?? row['qty']));

    if (qty <= 0) {
      return (
        canStockIn: false,
        reason: 'Qty return 0 atau barang fisik belum diterima.',
        qty: qty,
      );
    }

    return (
      canStockIn: true,
      reason: 'Barang fisik diterima, siap dimasukkan ke stok.',
      qty: qty,
    );
  }

  Future<Map<String, dynamic>?> _pickReturnMatch(
      List<Map<String, dynamic>> rows) async {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      useSafeArea: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Pilih Data Return',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => AppUi.safePop(sheetContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, index) {
                  final row = rows[index];
                  return Card(
                    margin: EdgeInsets.zero,
                    shape: AppUi.modernShape(context, radius: 14),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(14),
                      title: Text(_returnRowTitle(row)),
                      subtitle: Text(_returnRowSubtitle(row)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => AppUi.safePop(sheetContext, row),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanReturnResi() async {
    if (_isDemoSuperAdmin) {
      AppUi.showSnack('Mode demo hanya bisa melihat data.');
      return;
    }
    if (_tenantId.trim().isEmpty) {
      AppUi.showSnack('Tenant belum terbaca. Login ulang lalu coba lagi.');
      return;
    }

    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const QrScanPage(
          title: 'Scan Resi Return',
          instruction:
              'Arahkan kamera ke barcode resi paket return/cancel/refund.',
          scanMode: ScanMode.barcode,
        ),
      ),
    );
    if (value == null || value.trim().isEmpty) return;

    setState(() => _returnBusy = true);
    try {
      final rows = await _returnPickService.findReturnByResi(
        resi: value,
        tenantId: _tenantId,
      );
      if (!mounted) return;
      if (rows.isEmpty) {
        AppUi.showSnack(
            'Tidak ada data return/cancel/refund tenant ini untuk resi $value.');
        return;
      }
      final selected =
          rows.length == 1 ? rows.first : await _pickReturnMatch(rows);
      if (selected == null) return;
      setState(() => _lastReturnMatch = selected);
      await _confirmReturnStockDecision(selected, value.trim());
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack(AppUi.userMessage(error.toString()));
    } finally {
      if (mounted) setState(() => _returnBusy = false);
    }
  }

  Future<void> _confirmReturnStockDecision(
      Map<String, dynamic> row, String scannedResi) async {
    final item = _returnReviewItemFromRow(row);
    final hasItemId = !_isBlank(item.marketplaceOrderItemId);
    final eligibility = _returnStockEligibility(row, item);
    final canStockIn = eligibility.canStockIn;
    final qty = eligibility.qty > 0
        ? eligibility.qty
        : (item.qtyTotal > 0
            ? item.qtyTotal
            : AppUi.toNum(row['quantity'] ?? row['item_qty'] ?? row['qty']));
    final source = _returnSourceLabel(row);

    final decision = await showDialog<_ReturnStockDecision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Konfirmasi Stock In Return'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_returnRowTitle(row),
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(_returnRowSubtitle(row)),
            const SizedBox(height: 12),
            Text('Qty return: ${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2)}'),
            Text('SKU lokal: ${item.localItemTitle}'),
            Text('Sumber: $source'),
            const SizedBox(height: 12),
            Text(
              canStockIn
                  ? 'Pilih "Masukkan stok" hanya jika barang fisik benar diterima dan kondisinya layak masuk stok.'
                  : 'Tidak memenuhi syarat stock-in. ${eligibility.reason}',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext),
            child: const Text('Batal'),
          ),
          OutlinedButton(
            onPressed: hasItemId
                ? () =>
                    AppUi.safePop(dialogContext, _ReturnStockDecision.noStockIn)
                : null,
            child: const Text('Jangan masukkan'),
          ),
          FilledButton(
            onPressed: canStockIn
                ? () =>
                    AppUi.safePop(dialogContext, _ReturnStockDecision.stockIn)
                : null,
            child: const Text('Masukkan stok'),
          ),
        ],
      ),
    );

    if (decision == null) return;
    if (!hasItemId) {
      AppUi.showSnack(
          'Data resi ditemukan, tetapi item order belum tersedia untuk dicatat.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      final stockIn = decision == _ReturnStockDecision.stockIn;
      final note = [
        'Stock In Return mode',
        'legacy_mode=true',
        'source=$source',
        'resi=$scannedResi',
        'order=${AppUi.text(row['external_order_id'] ?? row['order_sn'])}',
        stockIn ? 'decision=stock_in' : 'decision=no_stock_in',
        _noteController.text.trim(),
      ].where((part) => part.trim().isNotEmpty).join(' | ');

      final result = await _returnPickService.submitReturnItemReview(
        tenantId: _tenantId,
        marketplaceOrderItemId: item.marketplaceOrderItemId,
        packageMatchStatus: stockIn ? 'sesuai' : 'tidak_sesuai',
        itemCondition: stockIn ? 'baik' : 'rusak',
        canRestock: stockIn,
        note: note,
      );

      AppUi.showSnack(result.message);
      _noteController.clear();
      await _loadProducts();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack(AppUi.userMessage(error.toString()));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
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
        const SnackBar(
            content: Text(
                'Mode demo hanya bisa melihat data. Simpan stok masuk dikunci.')),
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
          subtitle: _returnMode
              ? 'Mode return mengambil sumber dari data refund, cancel, return, dan order tenant 90 hari. Scan resi lalu pilih keputusan stock.'
              : 'Input stock masuk berdasarkan produk aktif. Staff warehouse bisa pilih produk manual atau scan barcode.',
          stats: [
            StatPill(label: 'Produk Aktif', value: _products.length.toString()),
            StatPill(
                label: 'Mode',
                value: _returnMode ? 'Stock In Return' : 'Normal Stock In'),
          ],
        ),
        const SizedBox(height: 16),
        NiceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Mode Stok Masuk',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Normal Stock In'),
                    selected: !_returnMode,
                    onSelected: _isSaving || _returnBusy
                        ? null
                        : (_) => setState(() {
                              _returnMode = false;
                              _lastReturnMatch = null;
                            }),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                      side: AppUi.softBorderSide(context),
                    ),
                  ),
                  ChoiceChip(
                    label: const Text('Stock In Return'),
                    selected: _returnMode,
                    onSelected: _isSaving || _returnBusy
                        ? null
                        : (_) => setState(() {
                              _returnMode = true;
                              _selectedProduct = null;
                              _qtyController.clear();
                              _sumber = 'retur';
                            }),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                      side: AppUi.softBorderSide(context),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (_returnMode)
          NiceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Stock In Return',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Scan resi fisik return/cancel/refund. Sistem mencari data tenant 90 hari, lalu meminta keputusan sebelum stok ditambahkan.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _noteController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Catatan keputusan',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_lastReturnMatch != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outlineVariant
                            .withOpacity(
                              Theme.of(context).brightness == Brightness.dark
                                  ? 0.3
                                  : 0.5,
                            ),
                        width: 0.8,
                      ),
                      borderRadius: AppTheme.radiusMd,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _returnRowTitle(_lastReturnMatch!),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(_returnRowSubtitle(_lastReturnMatch!)),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: (_returnBusy || _isSaving || _isDemoSuperAdmin)
                        ? null
                        : _scanReturnResi,
                    icon: _returnBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.qr_code_scanner_rounded),
                    label: Text(
                      _returnBusy
                          ? 'Mencari data return...'
                          : 'Scan Resi Return',
                    ),
                  ),
                ),
              ],
            ),
          )
        else
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
                  onTap: AppUi.selectOnTap(_qtyController),
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
                  onTap: AppUi.selectOnTap(_noteController),
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
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined),
                    label:
                        Text(_isSaving ? 'Menyimpan...' : 'Simpan Stok Masuk'),
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
    return WebResponsiveScaffold(
      title: 'Stok Masuk',
      actions: [
        IconButton(onPressed: _loadProducts, icon: const Icon(Icons.refresh)),
      ],
      body: _body(),
    );
  }
}

enum _ReturnStockDecision { stockIn, noStockIn }
