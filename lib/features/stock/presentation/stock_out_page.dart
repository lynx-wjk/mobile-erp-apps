import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../marketplace/services/marketplace_order_pick_service.dart';
import 'qr_scan_page.dart';

// V11 targeted fix: keep the current UI, but neutralize global button themes
// that may use Size(double.infinity, ...). That global style breaks buttons
// inside Row/scroll layouts with: BoxConstraints forces an infinite width.
ThemeData _safeFiniteButtonTheme(BuildContext context) {
  final base = Theme.of(context);
  final colorScheme = base.colorScheme;

  final filledStyle = FilledButton.styleFrom(
    minimumSize: const Size(0, 48),
    maximumSize: const Size(10000, 64),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  final outlinedStyle = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 48),
    maximumSize: const Size(10000, 64),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  final textStyle = TextButton.styleFrom(
    minimumSize: const Size(0, 44),
    maximumSize: const Size(10000, 60),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  final elevatedStyle = ElevatedButton.styleFrom(
    minimumSize: const Size(0, 48),
    maximumSize: const Size(10000, 64),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  return base.copyWith(
    colorScheme: colorScheme,
    filledButtonTheme: FilledButtonThemeData(style: filledStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedStyle),
    textButtonTheme: TextButtonThemeData(style: textStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: elevatedStyle),
  );
}

bool _stockOutMarketplaceResiMatchEnabledMemory = false;

class StockOutPage extends StatefulWidget {
  const StockOutPage({super.key});

  @override
  State<StockOutPage> createState() => _StockOutPageState();
}

class _StockOutPageState extends State<StockOutPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final MarketplaceOrderPickService _marketplacePickService =
      MarketplaceOrderPickService();
  final TextEditingController _resiController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isCheckingResi = false;
  String? _errorMessage;
  String? _tenantId;

  String _tujuan = 'penjualan';
  List<_ProductItem> _products = [];
  final List<_StockOutDraftItem> _items = [];

  bool _requireMarketplaceResiMatch =
      _stockOutMarketplaceResiMatchEnabledMemory;
  String? _verifiedResi;
  String? _marketplaceOrderId;
  String? _marketplaceName;
  String? _marketplaceAccountName;
  String? _marketplaceOrderNumber;
  String? _marketplaceTrackingNumber;
  String? _marketplaceOrderMessage;
  String? _marketplaceNote;
  List<_MarketplacePickItem> _marketplacePickItems = [];

  final List<String> _tujuanOptions = const [
    'penjualan',
    'produksi',
    'rusak',
    'sample',
    'adjustment',
  ];

  bool get _isMarketplaceVerificationActive => _requireMarketplaceResiMatch;

  @override
  void initState() {
    super.initState();
    _resiController.addListener(_handleResiChanged);
    _loadInitial();
  }

  @override
  void dispose() {
    _resiController.removeListener(_handleResiChanged);
    _resiController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _handleResiChanged() {
    final current = _resiController.text.trim();
    if (_verifiedResi != null && current != _verifiedResi) {
      setState(() {
        _verifiedResi = null;
        _marketplaceOrderId = null;
        _marketplaceName = null;
        _marketplaceAccountName = null;
        _marketplaceOrderNumber = null;
        _marketplaceTrackingNumber = null;
        _marketplaceOrderMessage = null;
        _marketplaceNote = null;
        _marketplacePickItems = [];
      });
    }
  }

  bool _validatePhysicalResi(String resi) {
    final clean = resi.trim();
    if (clean.isEmpty) return false;
    final upper = clean.toUpperCase();
    if (upper.startsWith('SPX')) return true;
    if (upper.startsWith('OFG')) return false;
    if (upper.startsWith('PG')) return false;
    if (upper.startsWith('PACKAGE')) return false;
    if (upper.startsWith('ORDER')) return false;
    if (RegExp(r'^PG\d+$', caseSensitive: false).hasMatch(clean)) return false;
    if (RegExp(r'^1200\d{6,}$').hasMatch(clean)) return false;
    if (RegExp(r'^\d{16,}$').hasMatch(clean)) return false;
    return true;
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _loadTenantId();
      await _loadProducts(showLoader: false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _cleanError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadTenantId() async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) {
      throw Exception('User belum login.');
    }

    final data = await _client
        .from('users')
        .select('tenant_id')
        .eq('user_id', authUser.id)
        .maybeSingle();

    final tenantId = data == null ? '' : (data['tenant_id']?.toString() ?? '');
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    _tenantId = tenantId;
  }

  Future<void> _loadProducts({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final data = await _client
          .from('products')
          .select(
            'product_id, kode_sku, kode_barcode, nama_barang, stock_saat_ini, satuan, status',
          )
          .or('status.eq.active,status.is.null')
          .order('nama_barang', ascending: true);

      if (!mounted) return;

      setState(() {
        _products = (data as List)
            .map(
                (item) => _ProductItem.fromMap(Map<String, dynamic>.from(item)))
            .toList();
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _cleanError(error));
    } finally {
      if (mounted && showLoader) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<String?> _openScanner({
    required String title,
    required String instruction,
    ScanMode scanMode = ScanMode.auto,
  }) async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => QrScanPage(
          title: title,
          instruction: instruction,
          scanMode: scanMode,
        ),
      ),
    );

    final code = result?.trim();
    if (code == null || code.isEmpty) return null;
    return code;
  }

  Future<void> _scanResi() async {
    final code = await _openScanner(
      title: 'Scan Resi Marketplace',
      instruction:
          'Arahkan kamera ke barcode resi / tracking number pada label pengiriman.',
      scanMode: ScanMode.barcode,
    );
    if (code == null) return;

    setState(() {
      _resiController.text = code;
    });

    if (_requireMarketplaceResiMatch) {
      await _verifyMarketplaceResi();
    }
  }

  Future<bool> _verifyMarketplaceResi() async {
    final tenantId = _tenantId;
    final resi = _resiController.text.trim();

    if (!_requireMarketplaceResiMatch) return true;

    if (tenantId == null || tenantId.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
            content: Text(
                'Data akun belum terbaca. Refresh halaman lalu coba lagi.')),
      );
      return false;
    }

    if (resi.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Scan atau input resi marketplace dulu.')),
      );
      return false;
    }

    if (!_validatePhysicalResi(resi)) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
            content: Text(
                'Resi fisik tidak valid. Pastikan Anda men-scan AWB/Resi di label pengiriman fisik, bukan nomor pesanan (Order SN) atau package ID.')),
      );
      return false;
    }

    setState(() => _isCheckingResi = true);
    try {
      final result = await _marketplacePickService.findOrderByResi(
        tenantId: tenantId,
        resiCode: resi,
      );

      if (!result.ok || result.marketplaceOrderId == null) {
        setState(() {
          _verifiedResi = null;
          _marketplaceOrderId = null;
          _marketplaceName = null;
          _marketplaceAccountName = null;
          _marketplaceOrderNumber = null;
          _marketplaceTrackingNumber = null;
          _marketplaceOrderMessage = result.message;
          _marketplaceNote = null;
          _marketplacePickItems = [];
        });
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(result.message)),
        );
        return false;
      }

      var finalMessage = result.message;

      setState(() {
        _verifiedResi = resi;
        _marketplaceOrderId = result.marketplaceOrderId;
        _marketplaceName = result.marketplace;
        _marketplaceAccountName = result.accountName;
        _marketplaceOrderNumber = result.externalOrderId;
        _marketplaceTrackingNumber = result.trackingNumber;
        _marketplaceOrderMessage = result.message;
        _marketplaceNote = result.marketplaceNote;
        _items.clear();
      });

      // Normalisasi status item lama seperti ignored_status / ready_stock_out
      // ke waiting_scan langsung dari app. Jadi user tidak perlu utak-atik SQL.
      try {
        final activation =
            await _marketplacePickService.activateOrderForScanByResi(
          tenantId: tenantId,
          resiCode: resi,
        );
        if (activation.ok) {
          finalMessage = activation.message;
          setState(() => _marketplaceOrderMessage = finalMessage);
        }
      } catch (_) {
        // Kalau normalisasi gagal, order tetap ditampilkan. Scan/finalize akan memberi error spesifik.
      }

      await _loadMarketplacePickItems();

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(finalMessage)),
      );
      return true;
    } catch (error) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Cek resi gagal: ${_cleanError(error)}')),
      );
      return false;
    } finally {
      if (mounted) setState(() => _isCheckingResi = false);
    }
  }

  Future<void> _loadMarketplacePickItems() async {
    final orderId = _marketplaceOrderId;
    final tenantId = _tenantId;
    if (orderId == null || tenantId == null) return;

    final data = await _client
        .from('marketplace_order_items_public')
        .select()
        .eq('tenant_id', tenantId)
        .eq('marketplace_order_id', orderId)
        .order('created_at', ascending: true);

    if (!mounted) return;
    setState(() {
      _marketplacePickItems = (data as List)
          .map((item) => _MarketplacePickItem.fromMap(
              Map<String, dynamic>.from(item as Map)))
          .toList();
    });
  }

  Future<void> _activateMarketplaceOrderForScan() async {
    final tenantId = _tenantId;
    final resi = _resiController.text.trim();

    if (tenantId == null || tenantId.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
            content: Text(
                'Data akun belum terbaca. Refresh halaman lalu coba lagi.')),
      );
      return;
    }

    if (resi.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Scan atau input resi marketplace dulu.')),
      );
      return;
    }

    if (!_validatePhysicalResi(resi)) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
            content: Text(
                'Resi fisik tidak valid. Pastikan Anda men-scan AWB/Resi di label pengiriman fisik, bukan nomor pesanan (Order SN) atau package ID.')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final result = await _marketplacePickService.activateOrderForScanByResi(
        tenantId: tenantId,
        resiCode: resi,
      );

      if (!result.ok) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(result.message)),
        );
        return;
      }

      setState(() {
        _verifiedResi = resi;
        _marketplaceOrderId = result.marketplaceOrderId ?? _marketplaceOrderId;
        _marketplaceName = result.marketplace ?? _marketplaceName;
        _marketplaceAccountName = result.accountName ?? _marketplaceAccountName;
        _marketplaceOrderNumber =
            result.externalOrderId ?? _marketplaceOrderNumber;
        _marketplaceTrackingNumber =
            result.trackingNumber ?? _marketplaceTrackingNumber;
        _marketplaceOrderMessage = result.message;
        _marketplaceNote = result.marketplaceNote ?? _marketplaceNote;
      });

      await _loadMarketplacePickItems();

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    } catch (error) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
            content: Text(
                'Gagal mengaktifkan order untuk scan: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _scanProduct() async {
    if (_isMarketplaceVerificationActive) {
      final verified = _marketplaceOrderId != null &&
              _verifiedResi == _resiController.text.trim()
          ? true
          : await _verifyMarketplaceResi();
      if (!verified) return;

      final code = await _openScanner(
        title: 'Scan Produk Pesanan',
        instruction:
            'Scan barcode/QR produk. Sistem akan mencocokkan item dengan order berdasarkan resi yang sudah discan.',
        scanMode: ScanMode.barcode,
      );
      if (code == null) return;

      await _scanMarketplaceProduct(code);
      return;
    }

    final code = await _openScanner(
      title: 'Scan QR / Barcode Produk',
      instruction:
          'Arahkan kamera ke QR code/barcode produk. Bisa switch Auto, Barcode, atau QR Code dari menu kanan atas.',
      scanMode: ScanMode.barcode,
    );
    if (code == null) return;

    final product = _findProductByCode(code);

    if (product == null) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Produk tidak ditemukan untuk kode: $code')),
      );
      return;
    }

    _addOrMergeItem(product: product, qty: 1);
  }

  Future<void> _scanMarketplaceProduct(String code) async {
    final tenantId = _tenantId;
    final resi = _resiController.text.trim();
    if (tenantId == null || tenantId.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final result = await _marketplacePickService.scanOrderItemByResi(
        tenantId: tenantId,
        resiCode: resi,
        scanCode: code,
      );

      if (!result.ok) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(result.message)),
        );
        return;
      }

      setState(() {
        _marketplaceOrderId = result.marketplaceOrderId ?? _marketplaceOrderId;
        _marketplaceName = result.marketplace ?? _marketplaceName;
        _marketplaceAccountName = result.accountName ?? _marketplaceAccountName;
        _marketplaceOrderNumber =
            result.externalOrderId ?? _marketplaceOrderNumber;
        _marketplaceTrackingNumber =
            result.trackingNumber ?? _marketplaceTrackingNumber;
        _marketplaceNote = result.marketplaceNote ?? _marketplaceNote;
        _verifiedResi = resi;
      });

      await _loadMarketplacePickItems();

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(result.message)),
      );

      if (result.orderReadyToFinalize) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
              content: Text(
                  'Semua item order sudah discan. Tekan Simpan untuk Final Stok Keluar.')),
        );
      }
    } catch (error) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
            content: Text('Scan produk pesanan gagal: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  _ProductItem? _findProductByCode(String rawCode) {
    final code = _normalize(rawCode);

    for (final product in _products) {
      final values = [
        product.productId,
        product.kodeSku,
        product.kodeBarcode,
      ].map(_normalize).toList();

      if (values.contains(code)) {
        return product;
      }
    }

    return null;
  }

  String _normalize(String value) {
    return value.trim().toLowerCase();
  }

  Future<num?> _askQty({
    required _ProductItem product,
    num? initialQty,
  }) async {
    final controller = TextEditingController(
      text: initialQty == null ? '1' : initialQty.toStringAsFixed(0),
    );

    final result = await showDialog<num>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Qty Stok Keluar'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.namaBarang,
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 4),
              Text('SKU: ${product.kodeSku}'),
              Text('Barcode: ${product.kodeBarcode}'),
              Text(
                  'Stock tersedia: ${product.stockSaatIni.toStringAsFixed(0)} ${product.satuan}'),
              SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Qty keluar',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => AppUi.safePop(context),
              child: Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                final qty = num.tryParse(controller.text.trim()) ?? 0;

                if (qty <= 0) {
                  rootScaffoldMessengerKey.currentState?.showSnackBar(
                    const SnackBar(content: Text('Qty harus lebih dari 0')),
                  );
                  return;
                }

                AppUi.safePop(context, qty);
              },
              child: Text('OK'),
            ),
          ],
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      controller.dispose();
    });
    return result;
  }

  void _addOrMergeItem({
    required _ProductItem product,
    required num qty,
  }) {
    final existingIndex = _items.indexWhere(
      (item) => item.product.productId == product.productId,
    );

    final existingQty = existingIndex >= 0 ? _items[existingIndex].qty : 0;
    final finalQty = existingQty + qty;

    if (finalQty > product.stockSaatIni) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Qty melebihi stock. Stock ${product.namaBarang}: ${product.stockSaatIni.toStringAsFixed(0)}',
          ),
        ),
      );
      return;
    }

    setState(() {
      if (existingIndex >= 0) {
        _items[existingIndex] = _StockOutDraftItem(
          product: product,
          qty: finalQty,
        );
      } else {
        _items.add(
          _StockOutDraftItem(
            product: product,
            qty: qty,
          ),
        );
      }
    });
  }

  Future<void> _pickProductManually() async {
    if (_isMarketplaceVerificationActive) {
      await _pickMarketplaceItemManually();
      return;
    }

    final product = await _showProductPicker();
    if (product == null) return;

    final qty = await _askQty(product: product);
    if (qty == null) return;

    _addOrMergeItem(product: product, qty: qty);
  }

  Future<void> _pickMarketplaceItemManually() async {
    final verified = _marketplaceOrderId != null &&
            _verifiedResi == _resiController.text.trim()
        ? true
        : await _verifyMarketplaceResi();
    if (!verified) return;
    if (!mounted) return;

    if (_marketplacePickItems.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
            content: Text(
                'Item pesanan belum terbaca. Ambil Order ulang atau refresh halaman.')),
      );
      return;
    }

    final selectable = _marketplacePickItems
        .where((item) =>
            item.marketplaceOrderItemId.trim().isNotEmpty &&
            item.scannedQty < item.quantity)
        .toList();

    if (selectable.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Semua item pesanan sudah discan.')),
      );
      return;
    }

    final actualProduct = await _showProductPicker(
      title: 'Pilih SKU Aktual',
      searchLabel: 'Cari SKU aktual / nama / barcode',
      helperText:
          'Mode manual marketplace memakai daftar semua SKU tenant. QR/barcode tetap harus cocok dengan item order.',
    );
    if (actualProduct == null) return;
    if (!mounted) return;

    final selected = await showModalBottomSheet<_MarketplacePickItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.42,
          maxChildSize: 0.94,
          builder: (context, scrollController) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pilih Item Pesanan',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                      SizedBox(height: 6),
                      Text(
                          'SKU aktual sudah dipilih dari daftar semua produk tenant. Pilih item order/resi yang dipenuhi SKU ini.'),
                      SizedBox(height: 6),
                      Text(
                        'SKU aktual: ${actualProduct.kodeSku} - ${actualProduct.namaBarang}',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                    itemCount: selectable.length,
                    itemBuilder: (context, index) {
                      final item = selectable[index];
                      return Card(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(14),
                          leading: const CircleAvatar(
                              child: Icon(Icons.playlist_add_check_rounded)),
                          title: Text(item.productName,
                              style: TextStyle(fontWeight: FontWeight.w900)),
                          subtitle: Text(
                            'Varian: ${item.variantName}\n'
                            'Mapping order: ${item.mappedLocalSku}\n'
                            'Barcode mapping: ${item.localBarcode}\n'
                            'Scan: ${item.scannedQtyText}/${item.quantityText}'
                            '${item.fulfillmentOverrideQty > 0 ? '\nOverride ke: ${item.fulfillmentOverrideLocalSkus}' : ''}',
                          ),
                          isThreeLine: true,
                          onTap: () => AppUi.safePop(context, item),
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

    if (selected == null) return;

    final isOverride = !_sameProductForMarketplace(selected, actualProduct);
    String? overrideNote;
    if (isOverride) {
      overrideNote = await _confirmMarketplaceManualOverride(
        orderItem: selected,
        actualProduct: actualProduct,
      );
      if (overrideNote == null) return;
    }

    await _manualScanMarketplaceItem(
      item: selected,
      actualProduct: actualProduct,
      overrideNote: overrideNote,
    );
  }

  bool _sameProductForMarketplace(
    _MarketplacePickItem item,
    _ProductItem product,
  ) {
    final mappedProductId = item.mappedProductId.trim();
    if (mappedProductId.isNotEmpty && mappedProductId == product.productId) {
      return true;
    }
    return _normalize(item.mappedLocalSku) == _normalize(product.kodeSku);
  }

  Future<String?> _confirmMarketplaceManualOverride({
    required _MarketplacePickItem orderItem,
    required _ProductItem actualProduct,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final note = controller.text.trim();
            return AlertDialog(
              title: const Text('Konfirmasi Override SKU'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SKU aktual berbeda dari item order/resi.',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    SizedBox(height: 10),
                    Text('Item order: ${orderItem.productName}'),
                    Text('Varian order: ${orderItem.variantName}'),
                    Text('SKU mapping order: ${orderItem.mappedLocalSku}'),
                    SizedBox(height: 8),
                    Text('SKU aktual: ${actualProduct.kodeSku}'),
                    Text('Produk aktual: ${actualProduct.namaBarang}'),
                    Text('Barcode aktual: ${actualProduct.kodeBarcode}'),
                    if ((_marketplaceNote ?? '').trim().isNotEmpty) ...[
                      SizedBox(height: 12),
                      Text(
                        'Catatan Marketplace',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                      SizedBox(height: 4),
                      Text(_marketplaceNote!.trim()),
                    ],
                    SizedBox(height: 14),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      maxLines: 3,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Alasan/catatan user wajib',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => AppUi.safePop(context),
                  child: Text('Batal'),
                ),
                FilledButton(
                  onPressed:
                      note.isEmpty ? null : () => AppUi.safePop(context, note),
                  child: Text('Simpan Override'),
                ),
              ],
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      controller.dispose();
    });
    return result?.trim().isEmpty == true ? null : result?.trim();
  }

  Future<void> _manualScanMarketplaceItem({
    required _MarketplacePickItem item,
    required _ProductItem actualProduct,
    String? overrideNote,
  }) async {
    final tenantId = _tenantId;
    final resi = _resiController.text.trim();
    if (tenantId == null || tenantId.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final result =
          await _marketplacePickService.scanOrderItemManualOverrideByResi(
        tenantId: tenantId,
        resiCode: resi,
        marketplaceOrderItemId: item.marketplaceOrderItemId,
        actualProductId: actualProduct.productId,
        overrideNote: overrideNote,
      );

      if (!result.ok) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(result.message)),
        );
        return;
      }

      setState(() {
        _marketplaceOrderId = result.marketplaceOrderId ?? _marketplaceOrderId;
        _marketplaceName = result.marketplace ?? _marketplaceName;
        _marketplaceAccountName = result.accountName ?? _marketplaceAccountName;
        _marketplaceOrderNumber =
            result.externalOrderId ?? _marketplaceOrderNumber;
        _marketplaceTrackingNumber =
            result.trackingNumber ?? _marketplaceTrackingNumber;
        _marketplaceNote = result.marketplaceNote ?? _marketplaceNote;
        _verifiedResi = resi;
      });

      await _loadMarketplacePickItems();

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    } catch (error) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
            content: Text('Pilih item pesanan gagal: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<_ProductItem?> _showProductPicker({
    String title = 'Pilih Produk',
    String searchLabel = 'Cari nama / SKU / barcode',
    String? helperText,
  }) async {
    final searchController = TextEditingController();
    List<_ProductItem> filtered = List<_ProductItem>.from(_products);

    final result = await showModalBottomSheet<_ProductItem>(
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
                filtered = _products.where((product) {
                  return product.namaBarang.toLowerCase().contains(keyword) ||
                      product.kodeSku.toLowerCase().contains(keyword) ||
                      product.kodeBarcode.toLowerCase().contains(keyword);
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
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                          SizedBox(height: 12),
                          TextField(
                            controller: searchController,
                            onChanged: filter,
                            decoration: InputDecoration(
                              labelText: searchLabel,
                              prefixIcon: const Icon(Icons.search),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          if ((helperText ?? '').trim().isNotEmpty) ...[
                            SizedBox(height: 8),
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
                          ? Center(child: Text('Produk tidak ditemukan'))
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final product = filtered[index];

                                return Card(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.zero,
                                  ),
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

  Future<void> _editItemQty(int index) async {
    final item = _items[index];
    final qty = await _askQty(
      product: item.product,
      initialQty: item.qty,
    );

    if (qty == null) return;

    if (qty > item.product.stockSaatIni) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Qty melebihi stock. Stock ${item.product.namaBarang}: ${item.product.stockSaatIni.toStringAsFixed(0)}',
          ),
        ),
      );
      return;
    }

    setState(() {
      _items[index] = _StockOutDraftItem(
        product: item.product,
        qty: qty,
      );
    });
  }

  Future<int> _createManualMarketplaceReview({
    required List<Map<String, dynamic>> payload,
    required String tujuan,
    required String? nomorResi,
    required String? catatan,
  }) async {
    if (_requireMarketplaceResiMatch) return 0;

    final tenantId = _tenantId;
    if (tenantId == null || tenantId.trim().isEmpty) return 0;

    final cleanTujuan = tujuan.trim().toLowerCase();
    final cleanResi = nomorResi?.trim();

    // Review ini hanya dibuat untuk stock out penjualan/manual marketplace.
    // Adjustment atau transaksi non-penjualan tanpa resi tidak perlu masuk queue review.
    if (cleanTujuan != 'penjualan' &&
        (cleanResi == null || cleanResi.isEmpty)) {
      return 0;
    }

    try {
      final response = await _client.rpc(
        'marketplace_create_stock_out_manual_review',
        params: {
          'p_tenant_id': tenantId,
          'p_nomor_resi':
              cleanResi == null || cleanResi.isEmpty ? null : cleanResi,
          'p_tujuan': tujuan,
          'p_items': payload,
          'p_catatan': catatan,
        },
      );

      if (response is Map) {
        final inserted = response['inserted'];
        if (inserted is num) return inserted.toInt();
        return int.tryParse(inserted?.toString() ?? '0') ?? 0;
      }
    } catch (_) {
      // Jangan batalkan stock out hanya karena tabel/RPC review belum dipasang.
      // SQL patch bisa dipasang terpisah tanpa mengganggu transaksi stock out.
    }

    return 0;
  }

  Future<int> _queueMarketplaceSyncForProducts(List<String> productIds) async {
    int totalQueued = 0;

    for (final productId in productIds.toSet()) {
      try {
        final response = await _client.rpc(
          'marketplace_queue_stock_sync_for_product_change',
          params: {
            'p_product_id': productId,
            'p_reason': 'stock_out',
          },
        );

        if (response is num) {
          totalQueued += response.toInt();
        } else {
          totalQueued += int.tryParse(response?.toString() ?? '0') ?? 0;
        }
      } catch (_) {
        // Stock out sudah tersimpan. Jangan rollback hanya karena queue sync marketplace error.
      }
    }

    return totalQueued;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();

    if (_isMarketplaceVerificationActive) {
      await _finalizeMarketplaceOrderStockOut();
      return;
    }

    if (_items.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Minimal tambah 1 barang keluar')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final selectedTujuan = _tujuan;
      final nomorResi = _resiController.text.trim().isEmpty
          ? null
          : _resiController.text.trim();
      final catatan = _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim();

      final List<Map<String, dynamic>> payload =
          _items.map<Map<String, dynamic>>((item) {
        return {
          'product_id': item.product.productId,
          'qty': item.qty,
        };
      }).toList();

      await _client.rpc(
        'stock_out_for_app_guarded',
        params: {
          'p_items': payload,
          'p_tujuan': selectedTujuan,
          'p_nomor_resi': nomorResi,
          'p_catatan': catatan,
        },
      );

      final reviewQueued = await _createManualMarketplaceReview(
        payload: payload,
        tujuan: selectedTujuan,
        nomorResi: nomorResi,
        catatan: catatan,
      );

      final syncQueued = await _queueMarketplaceSyncForProducts(
        _items.map((item) => item.product.productId).toList(),
      );

      if (!mounted) return;

      setState(() {
        _items.clear();
        _tujuan = 'penjualan';
      });

      _resiController.clear();
      _noteController.clear();

      final reviewInfo = reviewQueued > 0
          ? ' $reviewQueued item perlu review marketplace.'
          : '';

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            syncQueued > 0
                ? 'Stok keluar berhasil. $syncQueued SKU siap disinkronkan ke marketplace.$reviewInfo'
                : 'Stok keluar berhasil. Belum ada mapping marketplace aktif untuk item ini.$reviewInfo',
          ),
        ),
      );

      await _loadProducts();
    } on PostgrestException catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Gagal stock out: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _finalizeMarketplaceOrderStockOut() async {
    final tenantId = _tenantId;
    final resi = _resiController.text.trim();

    if (tenantId == null || tenantId.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
            content: Text(
                'Data akun belum terbaca. Refresh halaman lalu coba lagi.')),
      );
      return;
    }

    final verified = _marketplaceOrderId != null && _verifiedResi == resi
        ? true
        : await _verifyMarketplaceResi();
    if (!verified) return;

    final allScanned = _marketplacePickItems.isNotEmpty &&
        _marketplacePickItems.every(
            (item) => item.scannedQty >= item.quantity && item.quantity > 0);

    if (!allScanned) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
            content: Text(
                'Belum semua item pesanan discan. Final stock out diblokir.')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final result =
          await _marketplacePickService.finalizeScannedOrderStockOutByResi(
        tenantId: tenantId,
        resiCode: resi,
      );

      if (!result.ok) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(result.message)),
        );
        return;
      }

      setState(() {
        _marketplaceOrderId = null;
        _marketplaceName = null;
        _marketplaceAccountName = null;
        _marketplaceOrderNumber = null;
        _marketplaceTrackingNumber = null;
        _marketplaceOrderMessage = null;
        _marketplaceNote = null;
        _marketplacePickItems = [];
        _verifiedResi = null;
        _tujuan = 'penjualan';
      });
      _resiController.clear();
      _noteController.clear();

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(result.message)),
      );

      await _loadProducts();
    } catch (error) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
            content: Text(
                'Final stock out marketplace gagal: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _headerCard() {
    final totalQty = _isMarketplaceVerificationActive
        ? _marketplacePickItems.fold<num>(
            0, (sum, item) => sum + item.scannedQty)
        : _items.fold<num>(0, (sum, item) => sum + item.qty);

    return FuturisticHeader(
      icon: Icons.output_outlined,
      title: 'Stok Keluar',
      subtitle: _isMarketplaceVerificationActive
          ? 'Scan resi marketplace, lalu scan produk. Produk harus sesuai dengan item pesanan.'
          : 'Scan QR/barcode produk dan resi. Kode produk yang sama otomatis menambah qty.',
      stats: [
        StatPill(
            label: 'Mode',
            value: _isMarketplaceVerificationActive ? 'Marketplace' : 'Manual'),
        StatPill(
            label: 'Item',
            value: _isMarketplaceVerificationActive
                ? _marketplacePickItems.length.toString()
                : _items.length.toString()),
        StatPill(label: 'Qty Scan', value: totalQty.toStringAsFixed(0)),
        StatPill(
            label: 'Resi',
            value: _resiController.text.trim().isEmpty
                ? '-'
                : _resiController.text.trim()),
      ],
    );
  }

  Widget _statPill(String label, String value) {
    return Container(
      width: 132,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.11),
        borderRadius: BorderRadius.zero,
        border: Border.all(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.72),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _formCard() {
    final isMarketplaceActive = _isMarketplaceVerificationActive;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text('Mode marketplace: cocokkan resi'),
              subtitle: Text(
                  'OFF: stock out manual normal. ON: wajib scan resi marketplace dan produk harus sesuai item pesanan.'),
              value: _requireMarketplaceResiMatch,
              onChanged: (value) {
                _stockOutMarketplaceResiMatchEnabledMemory = value;
                setState(() {
                  _requireMarketplaceResiMatch = value;
                  _items.clear();
                  _marketplaceOrderMessage = null;
                  _marketplacePickItems = [];
                  _marketplaceOrderId = null;
                  _marketplaceName = null;
                  _marketplaceAccountName = null;
                  _marketplaceOrderNumber = null;
                  _marketplaceTrackingNumber = null;
                  _marketplaceNote = null;
                  _verifiedResi = null;
                });
              },
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _resiController,
                    decoration: InputDecoration(
                      labelText: isMarketplaceActive
                          ? 'Nomor Resi Marketplace'
                          : 'Nomor Resi / Referensi',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(width: 10),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: _scanResi,
                    child: Icon(Icons.qr_code_scanner_outlined),
                  ),
                ),
              ],
            ),
            if (_requireMarketplaceResiMatch) ...[
              SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _isCheckingResi ? null : _verifyMarketplaceResi,
                icon: _isCheckingResi
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.fact_check_outlined),
                label: Text(
                    _isCheckingResi ? 'Mengecek...' : 'Cek Resi Marketplace'),
              ),
              if ((_marketplaceOrderMessage ?? '').trim().isNotEmpty) ...[
                SizedBox(height: 10),
                _marketplaceInfoBox(),
              ],
            ],
            SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _tujuanOptions.contains(_tujuan)
                  ? _tujuan
                  : _tujuanOptions.first,
              decoration: const InputDecoration(
                labelText: 'Tujuan Keluar',
                border: OutlineInputBorder(),
              ),
              items: _tujuanOptions.toSet().map((item) {
                return DropdownMenuItem<String>(
                  value: item,
                  child: Text(item),
                );
              }).toList(),
              onChanged: isMarketplaceActive
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _tujuan = value);
                    },
            ),
            SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLines: 3,
              enabled: !isMarketplaceActive,
              decoration: const InputDecoration(
                labelText: 'Catatan',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isSaving ? null : _scanProduct,
                    icon: Icon(Icons.qr_code_scanner_rounded),
                    label: Text(isMarketplaceActive
                        ? 'Scan Produk Pesanan'
                        : 'Scan QR/Barcode Produk'),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isSaving ? null : _pickProductManually,
                    icon: Icon(isMarketplaceActive
                        ? Icons.playlist_add_check_rounded
                        : Icons.add),
                    label: Text(isMarketplaceActive
                        ? 'Pilih Manual SKU'
                        : 'Pilih Manual'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _marketplaceInfoBox() {
    final ok = _marketplaceOrderId != null;
    final color =
        ok ? Colors.green.shade700 : Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: color.withOpacity(0.10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ok ? 'Order marketplace ditemukan' : 'Resi belum cocok',
            style: TextStyle(color: color, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 4),
          Text(_marketplaceOrderMessage ?? '-'),
          if ((_marketplaceName ?? '').trim().isNotEmpty)
            Text('Marketplace: $_marketplaceName'),
          if ((_marketplaceAccountName ?? '').trim().isNotEmpty)
            Text('Toko/Penjual: $_marketplaceAccountName'),
          if ((_marketplaceOrderNumber ?? '').trim().isNotEmpty)
            Text('Order: $_marketplaceOrderNumber'),
          if ((_marketplaceTrackingNumber ?? '').trim().isNotEmpty)
            Text('Resi: $_marketplaceTrackingNumber'),
          if ((_marketplaceNote ?? '').trim().isNotEmpty) ...[
            SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withOpacity(0.75),
                border: Border.all(color: color.withOpacity(0.22)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Catatan Marketplace',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  SizedBox(height: 4),
                  Text(_marketplaceNote!.trim()),
                ],
              ),
            ),
          ],
          if (ok) ...[
            SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _isSaving ? null : _activateMarketplaceOrderForScan,
              icon: Icon(Icons.sync_problem_rounded),
              label: Text('Aktifkan Item untuk Scan'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _itemsCard() {
    if (_isMarketplaceVerificationActive) {
      return _marketplaceItemsCard();
    }

    if (_items.isEmpty) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Text(
              'Belum ada item. Scan QR/barcode produk atau pilih manual dulu.'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Daftar Barang Keluar',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
        ),
        SizedBox(height: 8),
        ..._items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;

          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: ListTile(
              contentPadding: const EdgeInsets.all(14),
              leading: CircleAvatar(
                child: Text('${index + 1}'),
              ),
              title: Text(
                item.product.namaBarang,
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text(
                'SKU: ${item.product.kodeSku}\n'
                'Barcode: ${item.product.kodeBarcode}\n'
                'Qty keluar: ${item.qty.toStringAsFixed(0)} ${item.product.satuan}',
              ),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    _editItemQty(index);
                  }

                  if (value == 'delete') {
                    setState(() => _items.removeAt(index));
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('Edit Qty'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Hapus'),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _marketplaceItemsCard() {
    if (_marketplaceOrderId == null) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Text(
              'Scan atau cek resi marketplace dulu. Setelah resi cocok, item pesanan akan tampil di sini.'),
        ),
      );
    }

    if (_marketplacePickItems.isEmpty) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Text(
              'Item pesanan belum terbaca. Ambil Order ulang jika data item belum masuk.'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Item Pesanan Marketplace',
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(fontWeight: FontWeight.w900),
        ),
        SizedBox(height: 8),
        ..._marketplacePickItems.map((item) {
          final done = item.scannedQty >= item.quantity && item.quantity > 0;
          final color = done
              ? Colors.green.shade700
              : Theme.of(context).colorScheme.primary;
          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: ListTile(
              contentPadding: const EdgeInsets.all(14),
              leading: CircleAvatar(
                backgroundColor: color.withOpacity(0.12),
                child: Icon(
                    done ? Icons.check_rounded : Icons.qr_code_scanner_rounded,
                    color: color),
              ),
              title: Text(item.productName,
                  style: TextStyle(fontWeight: FontWeight.w900)),
              subtitle: Text(
                'Varian: ${item.variantName}\n'
                'SKU lokal: ${item.mappedLocalSku}\n'
                'Barcode lokal: ${item.localBarcode}\n'
                'Scan: ${item.scannedQtyText}/${item.quantityText} · Status: ${item.displayStatusLabel}'
                '${item.fulfillmentOverrideQty > 0 ? '\nOverride ke: ${item.fulfillmentOverrideLocalSkus}' : ''}',
              ),
              isThreeLine: true,
            ),
          );
        }),
      ],
    );
  }

  Widget _body() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 42),
              SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loadInitial,
                icon: Icon(Icons.refresh),
                label: Text('Coba Lagi'),
              ),
            ],
          ),
        ),
      );
    }

    // V10 targeted render fix: keep the original Stok Keluar UI, but avoid
    // top-level ListView/sliver rendering. The previous UI rewrite made the
    // page open with only the header or blank body on some Android builds.
    return RefreshIndicator(
      onRefresh: _loadInitial,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _headerCard(),
            SizedBox(height: 14),
            _formCard(),
            SizedBox(height: 16),
            _itemsCard(),
          ],
        ),
      ),
    );
  }

  String get _saveLabel {
    if (_isSaving) return 'Menyimpan...';
    if (_isMarketplaceVerificationActive) return 'Final Stok Keluar Pesanan';
    return 'Simpan Stok Keluar';
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _safeFiniteButtonTheme(context),
      child: Scaffold(
        appBar: AppBar(
          title: Text('Stok Keluar'),
          actions: [
            IconButton(
              onPressed: _loadInitial,
              icon: Icon(Icons.refresh),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor.withOpacity(0.18),
                ),
              ),
            ),
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.save_outlined),
              label: Text(_saveLabel),
            ),
          ),
        ),
        body: _body(),
      ),
    );
  }
}

class _ProductItem {
  final String productId;
  final String kodeSku;
  final String kodeBarcode;
  final String namaBarang;
  final String satuan;
  final num stockSaatIni;

  const _ProductItem({
    required this.productId,
    required this.kodeSku,
    required this.kodeBarcode,
    required this.namaBarang,
    required this.satuan,
    required this.stockSaatIni,
  });

  factory _ProductItem.fromMap(Map<String, dynamic> map) {
    return _ProductItem(
      productId: _asText(map['product_id']),
      kodeSku: _asText(map['kode_sku'], '-'),
      kodeBarcode: _asText(map['kode_barcode'], '-'),
      namaBarang: _asText(map['nama_barang'], '-'),
      satuan: _asText(map['satuan'], 'pcs'),
      stockSaatIni: _asNum(map['stock_saat_ini']),
    );
  }
}

class _StockOutDraftItem {
  final _ProductItem product;
  final num qty;

  const _StockOutDraftItem({
    required this.product,
    required this.qty,
  });
}

class _MarketplacePickItem {
  final String marketplaceOrderItemId;
  final String mappedProductId;
  final String productName;
  final String variantName;
  final String mappedLocalSku;
  final String localBarcode;
  final num quantity;
  final num scannedQty;
  final String stockActionLabel;
  final num fulfillmentOverrideQty;
  final String fulfillmentOverrideLocalSkus;
  final String fulfillmentOverrideProductNames;
  final String fulfillmentOverrideNote;

  const _MarketplacePickItem({
    required this.marketplaceOrderItemId,
    required this.mappedProductId,
    required this.productName,
    required this.variantName,
    required this.mappedLocalSku,
    required this.localBarcode,
    required this.quantity,
    required this.scannedQty,
    required this.stockActionLabel,
    required this.fulfillmentOverrideQty,
    required this.fulfillmentOverrideLocalSkus,
    required this.fulfillmentOverrideProductNames,
    required this.fulfillmentOverrideNote,
  });

  factory _MarketplacePickItem.fromMap(Map<String, dynamic> map) {
    return _MarketplacePickItem(
      marketplaceOrderItemId: _asText(map['marketplace_order_item_id']),
      mappedProductId: _asText(map['mapped_product_id']),
      productName: _asText(map['product_name'], '-'),
      variantName: _asText(map['variant_name'], '-'),
      mappedLocalSku: _asText(map['mapped_local_sku'], '-'),
      localBarcode: _asText(map['local_barcode'], '-'),
      quantity: _asNum(map['quantity']),
      scannedQty: _asNum(map['scanned_qty']),
      stockActionLabel: _asText(map['stock_action_label'], '-'),
      fulfillmentOverrideQty: _asNum(map['fulfillment_override_qty']),
      fulfillmentOverrideLocalSkus:
          _asText(map['fulfillment_override_local_skus']),
      fulfillmentOverrideProductNames:
          _asText(map['fulfillment_override_product_names']),
      fulfillmentOverrideNote: _asText(map['fulfillment_override_note']),
    );
  }

  String get displayStatusLabel {
    final value = stockActionLabel.trim();
    if (value.toLowerCase().contains('ignored')) return 'Waiting Scan';
    return value.isEmpty || value == '-' ? 'Waiting Scan' : value;
  }

  String get quantityText => _qtyText(quantity);

  String get scannedQtyText => _qtyText(scannedQty);

  static String _qtyText(num value) {
    if (value % 1 == 0) return value.toStringAsFixed(0);
    return value.toString();
  }
}

String _asText(dynamic value, [String fallback = '']) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return fallback;
  return text;
}

num _asNum(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  return num.tryParse(value.toString()) ?? 0;
}

String _cleanError(Object error) {
  var text = error.toString().trim();
  text = text.replaceFirst(RegExp(r'^Exception:\s*'), '');
  text = text.replaceFirst(RegExp(r'^PostgrestException\(message:\s*'), '');
  return text;
}
