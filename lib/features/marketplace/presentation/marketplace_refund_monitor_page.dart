import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/marketplace_providers.dart';
import '../../../core/sound/scan_feedback_service.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../../../models/app_user.dart';
import '../../stock/presentation/qr_scan_page.dart';
import '../models/marketplace_account_public.dart';
import '../models/marketplace_return_review_item.dart';
import '../services/marketplace_service.dart';
import '../services/marketplace_order_pick_service.dart';

class MarketplaceRefundMonitorPage extends StatefulWidget {
  final AppUser? currentUser;
  final List<MarketplaceAccountPublic> accounts;
  final String? initialAccountId;

  const MarketplaceRefundMonitorPage({
    super.key,
    this.currentUser,
    this.accounts = const <MarketplaceAccountPublic>[],
    this.initialAccountId,
  });

  @override
  State<MarketplaceRefundMonitorPage> createState() =>
      _MarketplaceRefundMonitorPageState();
}

class _MarketplaceRefundMonitorPageState
    extends State<MarketplaceRefundMonitorPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final MarketplaceOrderPickService _pickService =
      MarketplaceOrderPickService();
  final MarketplaceService _marketplaceService = MarketplaceService();
  final TextEditingController _searchController = TextEditingController();

  DateTime _startDate = DateTime(
      DateTime.now().year, DateTime.now().month - 3, DateTime.now().day);
  DateTime _endDate = DateTime.now();
  String _marketplace = 'all';
  String _actionFilter = 'ALL';
  String _accountId = 'all';
  bool _itemCheckMode = false;
  int _page = 1;
  static const int _pageSize = 20;

  bool _loading = false;
  String? _error;
  String _version = '-';
  int _total = 0;
  List<MarketplaceAccountPublic> _accounts = const <MarketplaceAccountPublic>[];
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  List<MarketplaceReturnReviewItem> _reviewItems =
      <MarketplaceReturnReviewItem>[];

  Timer? _debounce;

  Color get _premiumAccent => Theme.of(context).colorScheme.primary;

  @override
  void initState() {
    super.initState();
    _accountId = _initialAccountId();
    _loadAccounts();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  String _dateParam(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _dateLabel(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  String _asText(dynamic value, {String fallback = '-'}) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  String _initialAccountId() {
    final initial = widget.initialAccountId?.trim() ?? '';
    if (initial.isEmpty || initial.toLowerCase() == 'all') return 'all';

    if (widget.accounts.isEmpty) return initial;

    final exists = widget.accounts
        .any((account) => account.marketplaceAccountId == initial);
    return exists ? initial : 'all';
  }

  List<MarketplaceAccountPublic> get _availableAccounts =>
      (widget.accounts.isNotEmpty ? widget.accounts : _accounts)
          .where((account) =>
              _marketplace == 'all' ||
              MarketplaceProviders.normalize(account.marketplace) ==
                  _marketplace)
          .toList(growable: false);

  String? get _selectedMarketplaceParam =>
      _marketplace == 'all' ? null : _marketplace;

  Future<void> _loadAccounts() async {
    if (widget.accounts.isNotEmpty) return;
    final tenantId = widget.currentUser?.tenantId.trim() ?? '';
    if (tenantId.isEmpty) return;

    try {
      final accounts =
          await _marketplaceService.listAccounts(tenantId: tenantId);
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        if (_accountId != 'all' &&
            !accounts
                .any((account) => account.marketplaceAccountId == _accountId)) {
          _accountId = 'all';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _accounts = const <MarketplaceAccountPublic>[]);
    }
  }

  String? get _selectedAccountParam => _accountId == 'all' ? null : _accountId;

  Map<String, dynamic> _normalizeRpc(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);

    // SQL editor often shows: [{"function_name": {...}}]. Supabase rpc normally does not,
    // but this guard keeps the app alive if PostgREST returns a wrapped payload.
    if (raw is List && raw.isNotEmpty) {
      final first = raw.first;
      if (first is Map) {
        if (first.length == 1 && first.values.first is Map) {
          return Map<String, dynamic>.from(first.values.first as Map);
        }
        return Map<String, dynamic>.from(first);
      }
    }
    return <String, dynamic>{'ok': false, 'rows': <dynamic>[], 'total': 0};
  }

  Future<Map<String, dynamic>> _callReviewRpc(String functionName) async {
    final search = _searchController.text.trim();
    final tenantId = widget.currentUser?.tenantId.trim() ?? '';
    final result = await _client.rpc(
      functionName,
      params: <String, dynamic>{
        'p_start': _dateParam(_startDate),
        'p_end': _dateParam(_endDate),
        'p_marketplace': _selectedMarketplaceParam,
        'p_account_id': _selectedAccountParam,
        'p_search': search.isEmpty ? null : search,
        'p_action': _actionFilter == 'ALL' ? null : _actionFilter,
        'p_page': _page,
        'p_page_size': _pageSize,
        if (tenantId.isNotEmpty) 'p_tenant_id': tenantId,
      },
    );
    return _normalizeRpc(result);
  }

  Future<void> _load({bool resetPage = false}) async {
    if (resetPage) _page = 1;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_itemCheckMode) {
        await _loadReviewItems();
        return;
      }

      final payload = await _callReviewRpc('marketplace_refund_cancel_review');

      final safePayload = payload;
      final rawRows = safePayload['rows'];
      final rows = <Map<String, dynamic>>[];
      if (rawRows is List) {
        for (final item in rawRows) {
          if (item is Map) rows.add(Map<String, dynamic>.from(item));
        }
      }

      const nextVersion = 'data terbaru';
      final nextTotal =
          int.tryParse('${safePayload['total'] ?? rows.length}') ?? rows.length;

      if (!mounted) return;
      setState(() {
        _version = nextVersion;
        _total = nextTotal;
        _rows = rows;
        _reviewItems = <MarketplaceReturnReviewItem>[];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _rows = <Map<String, dynamic>>[];
        _total = 0;
        _error = AppUi.userMessage(e.toString());
      });
    }
  }

  Future<void> _loadReviewItems() async {
    final tenantId = widget.currentUser?.tenantId.trim() ?? '';
    if (tenantId.isEmpty) {
      throw Exception(
          'Data tenant belum tersedia. Login ulang lalu coba lagi.');
    }

    final items = await _pickService.listReturnReviews(
      tenantId: tenantId,
      marketplaceAccountId: _selectedAccountParam,
      marketplace: _selectedMarketplaceParam,
      startDate: _dateParam(_startDate),
      endDate: _dateParam(_endDate),
      search: _searchController.text.trim(),
      page: _page,
      status: 'all',
      limit: _pageSize,
    );

    final offset = (_page - 1) * _pageSize;
    final totalEstimate =
        offset + items.length + (items.length == _pageSize ? 1 : 0);

    if (!mounted) return;
    setState(() {
      _version = 'cek item';
      _total = totalEstimate;
      _rows = <Map<String, dynamic>>[];
      _reviewItems = items;
      _loading = false;
    });
  }

  Future<void> _pickDateRange() async {
    final today = DateTime.now();
    final firstDate = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 90));
    final lastDate = DateTime(today.year, today.month, today.day)
        .add(const Duration(days: 365));
    DateTime clampDate(DateTime value) {
      final date = DateTime(value.year, value.month, value.day);
      if (date.isBefore(firstDate)) return firstDate;
      if (date.isAfter(lastDate)) return lastDate;
      return date;
    }

    final initialStart = clampDate(_startDate);
    var initialEnd = clampDate(_endDate);
    if (initialEnd.isBefore(initialStart)) initialEnd = initialStart;
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: initialStart, end: initialEnd),
      firstDate: firstDate,
      lastDate: lastDate,
      builder: (BuildContext context, Widget? child) {
        return Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 420,
              maxHeight: 560,
            ),
            child: Material(
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: child,
            ),
          ),
        );
      },
    );
    if (picked == null) return;
    setState(() {
      _startDate = picked.start;
      _endDate = picked.end;
    });
    await _load(resetPage: true);
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 450), () => _load(resetPage: true));
  }

  Future<String?> _openScanner({
    required String title,
    required String instruction,
  }) async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => QrScanPage(
          title: title,
          instruction: instruction,
          scanMode: ScanMode.barcode,
        ),
      ),
    );

    final code = result?.trim();
    if (code == null || code.isEmpty) return null;
    return code;
  }

  Future<void> _scanReturnResi() async {
    final code = await _openScanner(
      title: 'Scan Resi Return',
      instruction:
          'Arahkan kamera ke barcode resi / tracking number paket return.',
    );
    if (code == null) return;

    try {
      final matches = await _pickService.findReturnByResi(
        resi: code,
        tenantId: widget.currentUser?.tenantId,
      );
      if (matches.isEmpty) {
        ScanFeedbackService.instance.playScanError();
        setState(() {
          _itemCheckMode = true;
          _searchController.text = code;
        });
        await _load(resetPage: true);
        AppUi.showSnack(
            'Resi belum ditemukan di database global. Pencarian list dibuka: $code');
        return;
      }

      AppUi.showSnack('Resi berhasil dipindai: $code');
      await _openGlobalReturnScanResult(code, matches);
    } catch (e) {
      setState(() {
        _itemCheckMode = true;
        _searchController.text = code;
      });
      await _load(resetPage: true);
      AppUi.showSnack(AppUi.userMessage(e.toString()));
    }
  }

  Future<void> _openGlobalReturnScanResult(
    String code,
    List<Map<String, dynamic>> matches,
  ) async {
    Map<String, dynamic>? selected;
    if (matches.length == 1) {
      selected = matches.first;
    } else {
      selected = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).cardColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (sheetContext) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(18),
              children: [
                Text(
                  'Pilih data return',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                ),
                SizedBox(height: 6),
                Text('Resi: $code',
                    style: TextStyle(color: AppUi.mutedText(context, 0.90))),
                SizedBox(height: 12),
                ...matches.map((row) {
                  final source = _asText(row['source'], fallback: 'database');
                  final shop =
                      _asText(row['shop_name'], fallback: 'Semua toko');
                  final resi = _asText(row['tracking_number'] ??
                      row['return_tracking_number'] ??
                      row['label_code']);
                  return Card(
                    color: Theme.of(context).cardColor,
                    shape: AppUi.modernShape(context, radius: 14),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(14),
                      title: Text(
                        _asText(row['external_order_id']),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        '$shop - ${_asText(row['marketplace'])} - $resi ($source)',
                        style: TextStyle(color: AppUi.mutedText(context, 0.90)),
                      ),
                      trailing: Icon(Icons.chevron_right,
                          color: AppUi.mutedText(context, 0.90)),
                      onTap: () => Navigator.pop(sheetContext, row),
                    ),
                  );
                }),
              ],
            ),
          );
        },
      );
    }

    if (selected == null) return;

    final itemId = _asText(selected['marketplace_order_item_id'], fallback: '');
    if (itemId.isNotEmpty) {
      setState(() {
        _itemCheckMode = true;
        _searchController.text = code;
      });
      final item = MarketplaceReturnReviewItem.fromMap(selected);
      await _showItemReview(item);
      await _load(resetPage: true);
      return;
    }

    await _showDetail(selected);
  }

  bool get _hasNextPage => _page * _pageSize < _total;

  Color _actionColor(String action) {
    switch (action) {
      case 'AUTO_DONE_NO_STOCK_IN':
        return Colors.greenAccent;
      case 'REVIEW_CANCEL_WITH_REAL_RESI':
        return Colors.orangeAccent;
      case 'REVIEW_REFUND_RETURN':
        return Colors.redAccent;
      case 'REVIEW_AWAITING_COLLECTION':
        return Colors.amberAccent;
      default:
        return Colors.lightBlueAccent;
    }
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'AUTO_DONE_NO_STOCK_IN':
        return 'Auto selesai tanpa stock masuk';
      case 'REVIEW_CANCEL_WITH_REAL_RESI':
        return 'Review cancel dengan resi asli';
      case 'REVIEW_REFUND_RETURN':
        return 'Review refund/return';
      case 'REVIEW_AWAITING_COLLECTION':
        return 'Review awaiting collection';
      default:
        return action.isEmpty ? 'Review' : action;
    }
  }

  Future<void> _showDetail(Map<String, dynamic> row) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final action = _asText(row['recommended_action'], fallback: 'REVIEW');
        final color = _actionColor(action);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.78,
          minChildSize: 0.45,
          maxChildSize: 0.94,
          builder: (context, controller) {
            return ListView(
              controller: controller,
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Detail Refund / Cancel',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close,
                          color: AppUi.mutedText(context, 0.90)),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                _detailLine(
                    'Tanggal order',
                    _asText(row['order_date'] ??
                        row['order_created_at'] ??
                        row['created_at'])),
                _detailLine('Order ID', _asText(row['external_order_id'])),
                _detailLine('Order SN', _asText(row['order_sn'])),
                _detailLine('Status', _asText(row['order_status'])),
                _detailLine(
                    'Buyer / penerima',
                    _asText(row['buyer_username'] ??
                        row['recipient_name'] ??
                        row['buyer_name'])),
                _detailLine(
                    'Toko',
                    _asText(row['shop_name'] ??
                        row['store_name'] ??
                        row['account_name'])),
                _detailLine(
                    'Resi',
                    _asText(
                        row['real_tracking_number'] ?? row['tracking_number'],
                        fallback: 'Belum ada resi')),
                _detailLine('Label pengiriman', _asText(row['label_code'])),
                _detailLine('Marketplace', _asText(row['marketplace'])),
                _detailLine('Jumlah item', _asText(row['item_count'])),
                _detailLine(
                    'Item',
                    _asText(row['item_names'] ??
                        row['product_names'] ??
                        row['product_name'] ??
                        row['marketplace_product_name'])),
                _detailLine('SKU lokal',
                    _asText(row['local_sku'] ?? row['mapped_local_sku'])),
                _detailLine(
                    'SKU marketplace',
                    _asText(row['marketplace_sku'] ??
                        row['marketplace_sku_id'] ??
                        row['seller_sku'])),
                _detailLine('Qty',
                    _asText(row['qty'] ?? row['quantity'] ?? row['item_qty'])),
                _detailLine(
                    'Status stok',
                    _asText(row['stock_action_status'] ??
                        row['item_stock_action_status'])),
                SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: color.withOpacity(0.24), width: 0.8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _actionLabel(action),
                        style: TextStyle(
                            color: color, fontWeight: FontWeight.w800),
                      ),
                      SizedBox(height: 8),
                      Text(
                        _asText(row['note']),
                        style: TextStyle(
                            color: AppUi.mutedText(context, 0.90),
                            height: 1.35),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 14),
                Text(
                  'Gunakan detail ini untuk mencocokkan resi, status pesanan, dan item sebelum keputusan stok.',
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.54),
                      height: 1.35),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _detailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.onSurface.withOpacity(0.38),
                  fontSize: 12)),
          SizedBox(height: 3),
          SelectableText(value,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _pill(
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: _premiumAccent.withOpacity(0.14),
        backgroundColor: Theme.of(context).cardColor,
        labelStyle: TextStyle(
            color: selected ? _premiumAccent : AppUi.mutedText(context, 0.90)),
        side: BorderSide(
            color: selected
                ? _premiumAccent
                : Theme.of(context).colorScheme.onSurface.withOpacity(0.12)),
      ),
    );
  }

  Widget _card(Map<String, dynamic> row) {
    final action = _asText(row['recommended_action'], fallback: 'REVIEW');
    final color = _actionColor(action);
    final resi =
        _asText(row['real_tracking_number'], fallback: 'Belum ada resi asli');
    final rawResi = _asText(row['tracking_number'], fallback: '-');

    return Card(
      color: Theme.of(context).cardColor,
      shape: AppUi.modernShape(context, radius: 18),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _showDetail(row),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      _asText(row['external_order_id']),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: color.withOpacity(0.24), width: 0.8),
                    ),
                    child: Text(
                      _actionLabel(action),
                      style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Text(
                '${_asText(row['marketplace'])} • ${_asText(row['order_status'])}',
                style: TextStyle(color: AppUi.mutedText(context, 0.90)),
              ),
              SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _mini('Resi asli', resi),
                  _mini('Tracking mentah', rawResi),
                  _mini('Label', _asText(row['label_code'])),
                  _mini('Item', _asText(row['item_count'])),
                ],
              ),
              SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: _premiumAccent.withOpacity(0.16), width: 0.8),
                ),
                child: Text(_asText(row['note']),
                    style: TextStyle(
                        color: AppUi.mutedText(context, 0.90), height: 1.3)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showItemReview(MarketplaceReturnReviewItem item) async {
    final tenantId = widget.currentUser?.tenantId.trim() ?? '';
    if (tenantId.isEmpty) {
      AppUi.showSnack(
          'Data tenant belum tersedia. Login ulang lalu coba lagi.');
      return;
    }

    String packageStatus =
        item.packageMatchStatus == 'tidak_sesuai' ? 'tidak_sesuai' : 'sesuai';
    String condition = ['baik', 'rusak', 'hilang'].contains(item.itemCondition)
        ? item.itemCondition
        : 'baik';
    bool canRestock = item.canRestock ?? item.canStockIn;
    final note = TextEditingController(text: item.note ?? '');
    String scannedProductCode = '';
    bool? productBarcodeMatched;
    bool saving = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> submit() async {
              try {
                setSheetState(() => saving = true);
                final wantsStockIn = canRestock;
                final stockInAllowed = productBarcodeMatched == true &&
                    packageStatus == 'sesuai' &&
                    condition == 'baik' &&
                    item.canStockIn;
                if (wantsStockIn && !stockInAllowed) {
                  AppUi.showSnack(
                    'Stock-in return wajib scan barcode produk yang cocok, kondisi baik, dan item pernah stock-out.',
                  );
                  return;
                }
                final result = await _pickService.submitReturnItemReview(
                  tenantId: tenantId,
                  marketplaceOrderItemId: item.marketplaceOrderItemId,
                  packageMatchStatus: packageStatus,
                  itemCondition: condition,
                  canRestock: stockInAllowed && canRestock,
                  note: note.text.trim(),
                );
                AppUi.showSnack(result.message);
                if (sheetContext.mounted) AppUi.safePop(sheetContext, true);
              } catch (e) {
                AppUi.showSnack(AppUi.userMessage(e.toString()));
              } finally {
                if (sheetContext.mounted) {
                  setSheetState(() => saving = false);
                }
              }
            }

            Future<void> scanReturnedProduct() async {
              final code = await _openScanner(
                title: 'Scan Produk Return',
                instruction:
                    'Scan barcode/SKU produk yang diterima agar cocok dengan SKU lokal return.',
              );
              if (code == null) return;

              final cleanCode = code.trim().toLowerCase();
              final expectedCodes = [
                item.localBarcode,
                item.mappedLocalSku,
                item.sellerSku,
              ]
                  .whereType<String>()
                  .map((value) => value.trim().toLowerCase())
                  .where((value) => value.isNotEmpty && value != '-')
                  .toSet();
              final matched = expectedCodes.contains(cleanCode);

              setSheetState(() {
                scannedProductCode = code;
                productBarcodeMatched = matched;
                if (matched) {
                  packageStatus = 'sesuai';
                  condition = 'baik';
                  canRestock = item.canStockIn;
                } else {
                  packageStatus = 'tidak_sesuai';
                  canRestock = false;
                }
              });

              AppUi.showSnack(matched
                  ? 'Barcode produk cocok. Kondisi bisa dilanjutkan cek baik/restock.'
                  : 'Barcode produk tidak cocok dengan SKU lokal return.');
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 18,
                right: 18,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 18,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Cek Item Return',
                          style: Theme.of(sheetContext)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => AppUi.safePop(sheetContext, false),
                        icon: Icon(Icons.close,
                            color: AppUi.mutedText(context, 0.90)),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(item.marketplaceItemTitle,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w800)),
                  SizedBox(height: 4),
                  Text(item.localItemTitle,
                      style: TextStyle(color: AppUi.mutedText(context, 0.90))),
                  SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: (productBarcodeMatched == false
                                  ? Theme.of(context).colorScheme.error
                                  : _premiumAccent)
                              .withOpacity(0.22),
                          width: 0.8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          productBarcodeMatched == null
                              ? 'Scan produk untuk mencocokkan SKU lokal'
                              : productBarcodeMatched == true
                                  ? 'Produk cocok dengan SKU lokal'
                                  : 'Produk tidak cocok',
                          style: TextStyle(
                            color: productBarcodeMatched == false
                                ? Colors.redAccent
                                : _premiumAccent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'SKU/Barcode lokal: ${item.localBarcode ?? item.mappedLocalSku ?? '-'}',
                          style:
                              TextStyle(color: AppUi.mutedText(context, 0.90)),
                        ),
                        if (scannedProductCode.isNotEmpty) ...[
                          SizedBox(height: 4),
                          Text(
                            'Scan terakhir: $scannedProductCode',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withOpacity(0.54)),
                          ),
                        ],
                        SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: saving ? null : scanReturnedProduct,
                          icon: Icon(Icons.barcode_reader),
                          label: Text('Scan Barcode Produk'),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: packageStatus,
                    dropdownColor: Theme.of(context).cardColor,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface),
                    decoration: _darkInput('Kecocokan barang'),
                    items: const [
                      DropdownMenuItem(value: 'sesuai', child: Text('Cocok')),
                      DropdownMenuItem(
                          value: 'tidak_sesuai', child: Text('Tidak cocok')),
                    ],
                    onChanged: saving
                        ? null
                        : (value) => setSheetState(() {
                              packageStatus = value ?? 'sesuai';
                              if (packageStatus != 'sesuai') canRestock = false;
                            }),
                  ),
                  SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: condition,
                    dropdownColor: Theme.of(context).cardColor,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface),
                    decoration: _darkInput('Kondisi barang'),
                    items: const [
                      DropdownMenuItem(value: 'baik', child: Text('Baik')),
                      DropdownMenuItem(value: 'rusak', child: Text('Rusak')),
                      DropdownMenuItem(value: 'hilang', child: Text('Hilang')),
                    ],
                    onChanged: saving
                        ? null
                        : (value) => setSheetState(() {
                              condition = value ?? 'baik';
                              if (condition != 'baik') canRestock = false;
                            }),
                  ),
                  SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: canRestock,
                    activeColor: _premiumAccent,
                    title: Text('Bisa restock',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface)),
                    subtitle: Text(
                      productBarcodeMatched == true
                          ? 'Barcode cocok. Jika kondisi baik dan stok fisik pernah keluar, backend akan stock-in.'
                          : 'Scan barcode produk yang cocok dulu sebelum stock-in return.',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.54)),
                    ),
                    onChanged: saving ||
                            productBarcodeMatched != true ||
                            packageStatus != 'sesuai' ||
                            condition != 'baik' ||
                            !item.canStockIn
                        ? null
                        : (value) => setSheetState(() => canRestock = value),
                  ),
                  SizedBox(height: 12),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface),
                    decoration: _darkInput('Catatan'),
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
                        : Icon(Icons.fact_check_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Submit Cek Item'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 500), note.dispose);
    if (saved == true) _load();
  }

  InputDecoration _darkInput(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: AppUi.mutedText(context, 0.90)),
      filled: true,
      fillColor: Theme.of(context).cardColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: _premiumAccent),
      ),
    );
  }

  Widget _itemReviewCard(MarketplaceReturnReviewItem item) {
    final isDone = item.reviewStatus != 'pending' &&
        item.reviewStatus != 'not_required' &&
        item.reviewStatus != '-';
    final color = isDone ? AppUi.green : AppUi.orange;

    return Card(
      color: Theme.of(context).cardColor,
      shape: AppUi.modernShape(context, radius: 18),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.externalOrderId,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                    border:
                        Border.all(color: color.withOpacity(0.24), width: 0.8),
                  ),
                  child: Text(
                    item.reviewStatus,
                    style: TextStyle(color: color, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(item.marketplaceItemTitle,
                style: TextStyle(color: AppUi.mutedText(context, 0.90))),
            SizedBox(height: 4),
            Text('Lokal: ${item.localItemTitle}',
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.54))),
            SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _mini('Qty', item.qtyText),
                _mini('Stock out', item.stockOutText),
                _mini('Return', item.returnedText),
                _mini('Stok lokal', item.localStockText),
                _mini('Resi', item.trackingNumber ?? '-'),
              ],
            ),
            SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _showItemReview(item),
              icon: Icon(Icons.fact_check_outlined),
              label: Text('Cek Item'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeChip(String label, bool selected, bool targetMode) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      selectedColor: _premiumAccent.withOpacity(0.14),
      backgroundColor: Theme.of(context).cardColor,
      labelStyle: TextStyle(
          color: selected ? _premiumAccent : AppUi.mutedText(context, 0.90)),
      side: BorderSide(
          color: selected
              ? _premiumAccent
              : Theme.of(context).colorScheme.onSurface.withOpacity(0.12)),
      onSelected: (_) {
        setState(() => _itemCheckMode = targetMode);
        _load(resetPage: true);
      },
    );
  }

  Widget _mini(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: _premiumAccent.withOpacity(0.16), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.onSurface.withOpacity(0.38),
                  fontSize: 11)),
          SizedBox(height: 3),
          Text(value,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _availableAccounts;
    return WebResponsiveScaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Refund / Cancel Monitor'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => _load(),
            icon: Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _load(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withOpacity(
                              Theme.of(context).brightness == Brightness.dark
                                  ? 0.3
                                  : 0.5),
                      width: 0.8),
                ),
                child: Text(
                  'Gunakan halaman ini untuk mengecek refund, cancel, return, dan status stok per pesanan. Scan resi mencari seluruh database tenant, bukan hanya data yang tampil di list.',
                  style: TextStyle(
                      color: AppUi.mutedText(context, 0.90), height: 1.35),
                ),
              ),
              SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _modeChip('Ringkasan order', !_itemCheckMode, false),
                  _modeChip('Cek Per Item', _itemCheckMode, true),
                ],
              ),
              SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _pickDateRange,
                  icon: Icon(Icons.calendar_month, size: 16),
                  label: Text(
                      'Periode: ${_dateLabel(_startDate)} - ${_dateLabel(_endDate)}'),
                ),
              ),
              SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _marketplace,
                dropdownColor: Theme.of(context).cardColor,
                style:
                    TextStyle(color: Theme.of(context).colorScheme.onSurface),
                decoration: InputDecoration(
                  labelText: 'Marketplace',
                  labelStyle: TextStyle(color: AppUi.mutedText(context, 0.90)),
                  filled: true,
                  fillColor: Theme.of(context).cardColor,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.12))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.12))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: _premiumAccent)),
                ),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(
                      value: 'all', child: Text('Semua marketplace')),
                  ...MarketplaceProviders.active
                      .where((provider) => provider.supportsRefundCancelMonitor)
                      .map(
                        (provider) => DropdownMenuItem<String>(
                          value: provider.id,
                          child: Text(provider.label),
                        ),
                      ),
                ],
                onChanged: _loading
                    ? null
                    : (value) {
                        setState(() {
                          _marketplace = value ?? 'all';
                          _accountId = 'all';
                        });
                        _load(resetPage: true);
                      },
              ),
              SizedBox(height: 12),
              if (accounts.isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  value: _accountId,
                  dropdownColor: Theme.of(context).cardColor,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.onSurface),
                  decoration: InputDecoration(
                    labelText: 'Toko',
                    labelStyle:
                        TextStyle(color: AppUi.mutedText(context, 0.90)),
                    filled: true,
                    fillColor: Theme.of(context).cardColor,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.12))),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.12))),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: _premiumAccent)),
                  ),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(
                        value: 'all', child: Text('Semua toko')),
                    ...accounts.map((account) {
                      final label =
                          '${account.marketplaceLabel} • ${account.safeStoreName}';
                      return DropdownMenuItem<String>(
                        value: account.marketplaceAccountId,
                        child: Text(label, overflow: TextOverflow.ellipsis),
                      );
                    }),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          setState(() => _accountId = value ?? 'all');
                          _load(resetPage: true);
                        },
                ),
                SizedBox(height: 12),
              ],
              TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                style:
                    TextStyle(color: Theme.of(context).colorScheme.onSurface),
                decoration: InputDecoration(
                  hintText: 'Cari order ID / resi / label / barcode',
                  hintStyle: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.38)),
                  prefixIcon: Icon(Icons.search, color: _premiumAccent),
                  suffixIcon: _searchController.text.trim().isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _searchController.clear();
                            _load(resetPage: true);
                          },
                          icon: Icon(Icons.clear,
                              color: AppUi.mutedText(context, 0.90)),
                        ),
                  filled: true,
                  fillColor: Theme.of(context).cardColor,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.12))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.12))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: _premiumAccent)),
                ),
              ),
              SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _scanReturnResi,
                  icon: Icon(Icons.qr_code_scanner_rounded),
                  label: Text('Scan Resi Return'),
                ),
              ),
              SizedBox(height: 12),
              if (!_itemCheckMode)
                Wrap(
                  children: [
                    _pill(
                        label: 'Semua',
                        selected: _actionFilter == 'ALL',
                        onTap: () {
                          setState(() => _actionFilter = 'ALL');
                          _load(resetPage: true);
                        }),
                    _pill(
                        label: 'Auto no stock',
                        selected: _actionFilter == 'AUTO_DONE_NO_STOCK_IN',
                        onTap: () {
                          setState(
                              () => _actionFilter = 'AUTO_DONE_NO_STOCK_IN');
                          _load(resetPage: true);
                        }),
                    _pill(
                        label: 'Cancel + resi',
                        selected:
                            _actionFilter == 'REVIEW_CANCEL_WITH_REAL_RESI',
                        onTap: () {
                          setState(() =>
                              _actionFilter = 'REVIEW_CANCEL_WITH_REAL_RESI');
                          _load(resetPage: true);
                        }),
                    _pill(
                        label: 'Refund/return',
                        selected: _actionFilter == 'REVIEW_REFUND_RETURN',
                        onTap: () {
                          setState(
                              () => _actionFilter = 'REVIEW_REFUND_RETURN');
                          _load(resetPage: true);
                        }),
                    _pill(
                        label: 'Awaiting',
                        selected: _actionFilter == 'REVIEW_AWAITING_COLLECTION',
                        onTap: () {
                          setState(() =>
                              _actionFilter = 'REVIEW_AWAITING_COLLECTION');
                          _load(resetPage: true);
                        }),
                  ],
                ),
              SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _itemCheckMode
                          ? 'Total $_total item - $_version'
                          : 'Total $_total data • halaman $_page • $_version',
                      style: TextStyle(color: AppUi.mutedText(context, 0.90)),
                    ),
                  ),
                  if (_loading)
                    SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
              if (_error != null) ...[
                SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .error
                            .withOpacity(0.24),
                        width: 0.8),
                  ),
                  child: Text(_error!,
                      style: TextStyle(color: Colors.redAccent, height: 1.35)),
                ),
              ],
              SizedBox(height: 14),
              if (!_loading &&
                  (_itemCheckMode ? _reviewItems.isEmpty : _rows.isEmpty))
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outlineVariant
                            .withOpacity(
                                Theme.of(context).brightness == Brightness.dark
                                    ? 0.3
                                    : 0.5),
                        width: 0.8),
                  ),
                  child: Text(
                    'Belum ada data untuk filter ini. Ubah tanggal, toko, atau kata kunci lalu coba lagi.',
                    style: TextStyle(
                        color: AppUi.mutedText(context, 0.90), height: 1.35),
                  ),
                )
              else if (_itemCheckMode)
                ..._reviewItems.map(_itemReviewCard)
              else
                ..._rows.map(_card),
              SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _page <= 1 || _loading
                          ? null
                          : () {
                              setState(() => _page -= 1);
                              _load();
                            },
                      icon: Icon(Icons.chevron_left),
                      label: Text('Sebelumnya'),
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: !_hasNextPage || _loading
                          ? null
                          : () {
                              setState(() => _page += 1);
                              _load();
                            },
                      icon: Icon(Icons.chevron_right),
                      label: Text('Berikutnya'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
