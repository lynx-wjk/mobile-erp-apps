import 'package:flutter/material.dart';

import '../../../core/constants/marketplace_providers.dart';
import '../../../core/ui/app_ui.dart';
import '../../../models/app_user.dart';
import '../models/marketplace_account_public.dart';
import '../models/marketplace_stock_difference_item.dart';
import '../services/marketplace_service.dart';

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

class MarketplaceStockDifferencePage extends StatefulWidget {
  final AppUser currentUser;

  const MarketplaceStockDifferencePage({
    super.key,
    required this.currentUser,
  });

  @override
  State<MarketplaceStockDifferencePage> createState() =>
      _MarketplaceStockDifferencePageState();
}

class _MarketplaceStockDifferencePageState
    extends State<MarketplaceStockDifferencePage> {
  final MarketplaceService _service = MarketplaceService();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  bool _isSinkronkaning = false;
  String? _errorMessage;

  List<MarketplaceAccountPublic> _accounts = const [];
  List<MarketplaceStockDifferenceItem> _items = const [];
  String _filterMarketplace = 'all';
  String _filterAccountId = 'all';
  String _filterStatus = 'different';

  static const List<MapEntry<String, String>> _statuses = [
    MapEntry('all', 'All'),
    MapEntry('different', 'Different'),
    MapEntry('matched', 'Matched'),
    MapEntry('unknown_marketplace_stock', 'Stok Belum Terbaca'),
    MapEntry('not_mapped', 'Not Mapped'),
    MapEntry('sync_disabled', 'Sinkron Nonaktif'),
    MapEntry('marketplace_inactive', 'Marketplace Inactive'),
    MapEntry('local_inactive', 'Local Inactive'),
  ];

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final accounts =
          await _service.listAccounts(tenantId: widget.currentUser.tenantId);
      if (!mounted) return;
      setState(() => _accounts = accounts);
      await _loadItems();
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _cleanError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadItems() async {
    try {
      final items = await _service.listStockDifferences(
        tenantId: widget.currentUser.tenantId,
        marketplace: _filterMarketplace,
        marketplaceAccountId: _filterAccountId,
        status: _filterStatus,
        search: _searchController.text,
        limit: 250,
      );

      if (!mounted) return;
      setState(() {
        _items = items;
        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _cleanError(error));
    }
  }

  List<MarketplaceAccountPublic> get _filteredAccounts {
    if (_filterMarketplace == 'all') return _accounts;
    return _accounts
        .where((account) =>
            MarketplaceProviders.normalize(account.marketplace) ==
            _filterMarketplace)
        .toList(growable: false);
  }

  Future<void> _queueOne(MarketplaceStockDifferenceItem item) async {
    if (_isSinkronkaning) return;
    setState(() => _isSinkronkaning = true);

    try {
      await _service.queueStockSyncForMapping(
        tenantId: widget.currentUser.tenantId,
        marketplaceSkuMapId: item.marketplaceSkuMapId,
        reason: 'stock_difference_selected_from_app',
      );
      if (!mounted) return;
      AppUi.showSnack('${item.localSku} siap disinkronkan.');
      await _loadItems();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal menyiapkan sinkron: ${_cleanError(error)}');
    } finally {
      if (mounted) setState(() => _isSinkronkaning = false);
    }
  }

  Future<void> _queueAllDifferent() async {
    if (_isSinkronkaning) return;

    final candidates =
        _items.where((item) => item.canSync).toList(growable: false);
    if (candidates.isEmpty) {
      AppUi.showSnack('Tidak ada selisih stok yang perlu disinkronkan.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sinkronkan semua selisih stok?'),
        content:
            Text('${candidates.length} SKU akan disiapkan untuk sinkronisasi.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sinkronkan Semua'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() => _isSinkronkaning = true);

    var success = 0;
    var failed = 0;
    for (final item in candidates) {
      try {
        await _service.queueStockSyncForMapping(
          tenantId: widget.currentUser.tenantId,
          marketplaceSkuMapId: item.marketplaceSkuMapId,
          reason: 'stock_difference_bulk_from_app',
        );
        success++;
      } catch (_) {
        failed++;
      }
    }

    if (!mounted) return;
    setState(() => _isSinkronkaning = false);
    AppUi.showSnack('Selesai. Berhasil: $success, gagal: $failed.');
    await _loadItems();
  }

  @override
  Widget build(BuildContext context) {
    final differentCount =
        _items.where((item) => item.differenceStatus == 'different').length;
    final matchedCount =
        _items.where((item) => item.differenceStatus == 'matched').length;
    final unknownCount = _items
        .where((item) => item.differenceStatus == 'unknown_marketplace_stock')
        .length;
    final attentionCount = _items.where((item) => item.needsAttention).length;

    return Theme(
      data: _safeFiniteButtonTheme(context),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Selisih Stok'),
          actions: [
            IconButton(
              onPressed: _isLoading ? null : _loadInitial,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh',
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _loadInitial,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _summaryHeader(
                        total: _items.length,
                        different: differentCount,
                        matched: matchedCount,
                        unknown: unknownCount,
                        attention: attentionCount,
                      ),
                      const SizedBox(height: 12),
                      _filters(),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _loadItems,
                              icon: const Icon(Icons.search_rounded),
                              label: const Text('Terapkan Filter'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed:
                                  _isSinkronkaning ? null : _queueAllDifferent,
                              icon: _isSinkronkaning
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(
                                      Icons.playlist_add_check_rounded),
                              label: const Text('Sinkronkan'),
                            ),
                          ),
                        ],
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 12),
                        _errorBox(_errorMessage!),
                      ],
                      const SizedBox(height: 12),
                      _resultHeader(),
                      const SizedBox(height: 8),
                      if (_items.isEmpty)
                        _emptyBox()
                      else
                        ..._items.map(_itemCard),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _summaryHeader({
    required int total,
    required int different,
    required int matched,
    required int unknown,
    required int attention,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.35),
        border:
            Border.all(color: Theme.of(context).dividerColor.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Selisih Stok Marketplace',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
            'Bandingkan stok lokal dengan stok marketplace terbaru.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statChip('Total', total.toString(), Icons.inventory_2_outlined),
              _statChip('Different', different.toString(),
                  Icons.compare_arrows_rounded),
              _statChip('Matched', matched.toString(),
                  Icons.check_circle_outline_rounded),
              _statChip(
                  'Unknown', unknown.toString(), Icons.help_outline_rounded),
              _statChip('Need Check', attention.toString(),
                  Icons.warning_amber_rounded),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultHeader() {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Menampilkan ${_items.length} data selisih stok',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (_filterStatus != 'all')
          Text(
            _filterStatus.replaceAll('_', ' '),
            style: Theme.of(context).textTheme.labelMedium,
          ),
      ],
    );
  }

  Widget _filters() {
    final accounts = _filteredAccounts;
    return Column(
      children: [
        DropdownButtonFormField<String>(
          value: _filterMarketplace,
          decoration: const InputDecoration(
            labelText: 'Marketplace',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(
                value: 'all', child: Text('Semua marketplace')),
            ...MarketplaceProviders.active.map(
              (provider) => DropdownMenuItem(
                value: provider.id,
                child: Text(provider.label),
              ),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _filterMarketplace = value;
              _filterAccountId = 'all';
            });
            _loadItems();
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _filterAccountId,
          decoration: const InputDecoration(
            labelText: 'Akun Marketplace',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: 'all', child: Text('All accounts')),
            ...accounts.map(
              (account) => DropdownMenuItem(
                value: account.marketplaceAccountId,
                child: Text(
                    '${account.marketplaceLabel} · ${account.safeStoreName}'),
              ),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() => _filterAccountId = value);
            _loadItems();
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _filterStatus,
          decoration: const InputDecoration(
            labelText: 'Status',
            border: OutlineInputBorder(),
          ),
          items: _statuses
              .map((item) =>
                  DropdownMenuItem(value: item.key, child: Text(item.value)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _filterStatus = value);
            _loadItems();
          },
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            labelText: 'Cari SKU or product',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              onPressed: () {
                _searchController.clear();
                _loadItems();
              },
              icon: const Icon(Icons.clear_rounded),
            ),
          ),
          onSubmitted: (_) => _loadItems(),
        ),
      ],
    );
  }

  Widget _itemCard(MarketplaceStockDifferenceItem item) {
    final color = _statusColor(item.differenceStatus);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${item.localSku} · ${item.localProductName}',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                _statusBadge(item.differenceLabel, color),
              ],
            ),
            const SizedBox(height: 8),
            Text('${item.marketplaceLabel} · ${item.safeAccountName}'),
            const SizedBox(height: 4),
            Text(
                '${item.marketplaceProductName} · ${item.marketplaceVariantText}'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _miniMetric('Local', item.localStockText)),
                Expanded(
                    child:
                        _miniMetric('Marketplace', item.marketplaceStockText)),
                Expanded(child: _miniMetric('Diff', item.differenceText)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Product: ${item.productStatus ?? '-'} · SKU: ${item.skuStatus ?? '-'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (item.canSync)
                  FilledButton.tonalIcon(
                    onPressed: _isSinkronkaning ? null : () => _queueOne(item),
                    icon: const Icon(Icons.sync_rounded),
                    label: const Text('Sinkronkan'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniMetric(String label, String value) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.65),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.65),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(value),
        ],
      ),
    );
  }

  Widget _statusBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(
        text,
        style:
            TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }

  Color _statusColor(String status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case 'matched':
        return Colors.green.shade700;
      case 'different':
      case 'unknown_marketplace_stock':
        return scheme.error;
      case 'sync_disabled':
      case 'not_mapped':
      case 'marketplace_inactive':
      case 'local_inactive':
        return Colors.orange.shade800;
      default:
        return scheme.onSurfaceVariant;
    }
  }

  Widget _errorBox(String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.errorContainer,
      ),
      child: Text(text,
          style:
              TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
    );
  }

  Widget _emptyBox() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: const Text('No data matches the current filter.'),
    );
  }

  String _cleanError(Object error) {
    var text = error.toString().trim();
    text = text.replaceFirst(RegExp(r'^Exception:\s*'), '');
    return text;
  }
}
