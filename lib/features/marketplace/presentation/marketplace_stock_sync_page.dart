import 'package:flutter/material.dart';

import '../../../core/constants/marketplace_providers.dart';
import '../../../core/ui/app_ui.dart';
import '../../../models/app_user.dart';
import '../models/marketplace_account_public.dart';
import '../models/marketplace_stock_sync_item.dart';
import '../services/marketplace_service.dart';
import 'marketplace_sync_monitor_page.dart';
import 'marketplace_stock_difference_page.dart';
import '../../subscription/presentation/feature_gate_page.dart';

class MarketplaceStockSyncPage extends StatefulWidget {
  final AppUser currentUser;

  const MarketplaceStockSyncPage({
    super.key,
    required this.currentUser,
  });

  @override
  State<MarketplaceStockSyncPage> createState() =>
      _MarketplaceStockSyncPageState();
}

class _MarketplaceStockSyncPageState extends State<MarketplaceStockSyncPage> {
  final MarketplaceService _service = MarketplaceService();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  bool _isQueueing = false;
  bool _isProcessingWorker = false;
  bool _isLoadingAutoSync = false;
  bool _isSavingAutoSync = false;
  bool _autoSyncEnabled = false;
  int _autoSyncIntervalMinutes = 10;
  String? _errorMessage;

  List<MarketplaceAccountPublic> _accounts = const [];
  List<MarketplaceStockSyncItem> _items = const [];
  String _filterMarketplace = 'all';
  String _filterAccountId = 'all';

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
      setState(() {
        _accounts = accounts;
        _filterAccountId =
            accounts.isEmpty ? 'all' : accounts.first.marketplaceAccountId;
      });

      await _loadAutoSyncSetting(showError: false);
      await _loadItems();
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadItems() async {
    try {
      final items = await _service.listStockSyncItems(
        tenantId: widget.currentUser.tenantId,
        marketplace: _filterMarketplace,
        marketplaceAccountId: _filterAccountId,
        search: _searchController.text,
      );

      if (!mounted) return;
      setState(() {
        _items = items;
        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    }
  }

  Future<void> _loadAutoSyncSetting({bool showError = true}) async {
    setState(() => _isLoadingAutoSync = true);

    try {
      final setting = await _service.getAutoSyncSetting(
        tenantId: widget.currentUser.tenantId,
      );

      if (!mounted) return;
      setState(() {
        _autoSyncEnabled = setting.enabled;
        _autoSyncIntervalMinutes =
            setting.intervalMinutes <= 0 ? 10 : setting.intervalMinutes;
      });
    } catch (error) {
      if (!mounted) return;
      if (showError) {
        AppUi.showSnack('Gagal membaca pengaturan sinkron otomatis: $error');
      }
    } finally {
      if (mounted) setState(() => _isLoadingAutoSync = false);
    }
  }

  List<MarketplaceAccountPublic> get _filteredAccounts =>
      _filteredAccountsFor(_filterMarketplace, _accounts);

  List<MarketplaceAccountPublic> _filteredAccountsFor(
    String marketplace,
    List<MarketplaceAccountPublic> accounts,
  ) {
    if (marketplace == 'all') return accounts;
    return accounts
        .where((account) =>
            MarketplaceProviders.normalize(account.marketplace) == marketplace)
        .toList(growable: false);
  }

  Future<void> _setAutoSyncEnabled(bool enabled) async {
    if (_isSavingAutoSync) return;

    final previous = _autoSyncEnabled;
    setState(() {
      _autoSyncEnabled = enabled;
      _isSavingAutoSync = true;
    });

    try {
      final setting = await _service.setAutoSyncEnabled(
        tenantId: widget.currentUser.tenantId,
        enabled: enabled,
      );

      if (!mounted) return;
      setState(() {
        _autoSyncEnabled = setting.enabled;
        _autoSyncIntervalMinutes =
            setting.intervalMinutes <= 0 ? 10 : setting.intervalMinutes;
      });

      AppUi.showSnack(setting.enabled
          ? 'Sinkron stok otomatis aktif setiap ${setting.intervalMinutes <= 0 ? 10 : setting.intervalMinutes} menit.'
          : 'Sinkron stok otomatis dimatikan. Data yang menunggu tetap aman.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _autoSyncEnabled = previous);
      AppUi.showSnack('Gagal mengubah pengaturan sinkron otomatis: $error');
    } finally {
      if (mounted) setState(() => _isSavingAutoSync = false);
    }
  }

  Future<void> _queueOne(MarketplaceStockSyncItem item) async {
    setState(() => _isQueueing = true);

    try {
      await _service.queueStockSyncForMapping(
        tenantId: widget.currentUser.tenantId,
        marketplaceSkuMapId: item.marketplaceSkuMapId,
        reason: 'manual_from_stock_sync_page',
      );

      if (!mounted) return;
      AppUi.showSnack(item.apiReady
          ? '${item.localSku} siap disinkronkan.'
          : 'Mapping ${item.localSku} belum lengkap. Lengkapi produk dan varian marketplace.');

      await _loadItems();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal menyiapkan sinkron: $error');
    } finally {
      if (mounted) setState(() => _isQueueing = false);
    }
  }

  Future<void> _queueAccount() async {
    if (_items.isEmpty) {
      AppUi.showSnack('Belum ada mapping untuk disinkronkan.');
      return;
    }

    setState(() => _isQueueing = true);

    try {
      final count = await _service.queueStockSyncForAccount(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _filterAccountId,
        reason: 'manual_account_queue_from_app',
      );

      if (!mounted) return;
      AppUi.showSnack('$count mapping siap disinkronkan.');
      await _loadItems();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal menyiapkan sinkron toko: $error');
    } finally {
      if (mounted) setState(() => _isQueueing = false);
    }
  }

  Future<void> _processQueueDryRun() async {
    await _processQueue(dryRun: true);
  }

  Future<void> _processQueueRealSync() async {
    if (_items.isEmpty) {
      AppUi.showSnack(
          'Belum ada mapping SKU. Buat mapping dulu sebelum sinkron stok.');
      return;
    }

    if (_queuedCount == 0 && _dryRunOkCount == 0) {
      AppUi.showSnack(
          'Belum ada data siap sinkron. Klik Sinkronkan Sesuai Filter terlebih dahulu.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Kirim stock ke marketplace?'),
        content: Text(
          'Aksi ini akan mengirim stok lokal ke TikTok/Shopee. Pastikan mapping produk dan varian sudah benar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Kirim Sinkron'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _processQueue(dryRun: false);
  }

  Future<void> _processQueue({required bool dryRun}) async {
    if (_items.isEmpty) {
      AppUi.showSnack(
          'Belum ada SKU mapping. Buat SKU Mapping dulu sebelum sync.');
      return;
    }

    if (_queuedCount == 0) {
      if (dryRun || _dryRunOkCount == 0) {
        AppUi.showSnack(
            'Belum ada data siap sinkron. Klik Sinkronkan Sesuai Filter terlebih dahulu.');
        return;
      }
    }

    setState(() => _isProcessingWorker = true);

    try {
      if (!dryRun && _queuedCount == 0 && _dryRunOkCount > 0) {
        await _service.queueStockSyncForAccount(
          tenantId: widget.currentUser.tenantId,
          marketplaceAccountId: _filterAccountId,
          reason: 'real_sync_after_dry_run_ok',
        );
      }
      final result = await _service.processStockSyncQueue(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _filterAccountId,
        limit: 20,
        dryRun: dryRun,
      );

      if (!mounted) return;
      AppUi.showSnack(result.summary);
      await _loadItems();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Sinkron gagal: $error');
    } finally {
      if (mounted) setState(() => _isProcessingWorker = false);
    }
  }

  int get _apiReadyCount =>
      _items.where((item) => item.apiReady && item.canQueue).length;

  int get _waitingIdCount =>
      _items.where((item) => !item.apiReady && item.canQueue).length;

  int get _queuedCount =>
      _items.where((item) => item.lastSyncStatus == 'queued').length;

  int get _dryRunOkCount =>
      _items.where((item) => item.lastSyncStatus == 'dry_run_success').length;

  int get _syncOkCount =>
      _items.where((item) => item.lastSyncStatus == 'success').length;

  Widget _header() {
    return FuturisticHeader(
      icon: Icons.sync_alt_rounded,
      title: 'Sinkron Stok',
      subtitle:
          'Stok lokal menjadi acuan. Sinkronisasi bisa dijalankan manual atau otomatis setiap 10 menit.',
      stats: [
        StatPill(label: 'Auto', value: _autoSyncEnabled ? 'ON' : 'OFF'),
        StatPill(label: 'Mapping', value: _items.length.toString()),
        StatPill(label: 'API Ready', value: _apiReadyCount.toString()),
        StatPill(label: 'Need ID', value: _waitingIdCount.toString()),
        StatPill(label: 'Menunggu', value: _queuedCount.toString()),
        StatPill(label: 'Cek OK', value: _dryRunOkCount.toString()),
        StatPill(label: 'Sinkron OK', value: _syncOkCount.toString()),
      ],
    );
  }

  Widget _autoSyncCard() {
    final statusColor = _autoSyncEnabled ? AppUi.green : AppUi.orange;

    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: statusColor.withOpacity(0.28)),
                ),
                child: Icon(
                  _autoSyncEnabled
                      ? Icons.timer_rounded
                      : Icons.timer_off_rounded,
                  color: statusColor,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Auto Kirim Sinkron Stok',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      _autoSyncEnabled
                          ? 'Aktif. Stok akan disinkronkan otomatis setiap $_autoSyncIntervalMinutes menit saat runner aktif.'
                          : 'Nonaktif. Data siap sinkron tetap bisa diproses manual.',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isLoadingAutoSync || _isSavingAutoSync)
                Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Switch.adaptive(
                  value: _autoSyncEnabled,
                  onChanged: _setAutoSyncEnabled,
                ),
            ],
          ),
          SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceVariant
                  .withOpacity(0.30),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              'Catatan: mematikan sinkron otomatis tidak menghapus data. Saat diaktifkan lagi, data akan diproses pada jadwal berikutnya.',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _monitorShortcutCard() {
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => FeatureGatePage(
                          featureKey: 'marketplace_stock_sync',
                          featureLabel: 'Riwayat sync stock',
                          child: MarketplaceSyncMonitorPage(
                            currentUser: widget.currentUser,
                          ),
                        ),
                      ),
                    );
                  },
                  icon: Icon(Icons.monitor_heart_outlined),
                  label: Text('Riwayat Sinkron'),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => FeatureGatePage(
                          featureKey: 'marketplace_stock_sync',
                          featureLabel: 'Selisih stok marketplace',
                          child: MarketplaceStockDifferencePage(
                            currentUser: widget.currentUser,
                          ),
                        ),
                      ),
                    );
                  },
                  icon: Icon(Icons.compare_arrows_rounded),
                  label: Text('Selisih Stok'),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'Buka Riwayat Sinkron untuk melihat hasil sinkron. Buka Selisih Stok untuk membandingkan stok lokal dan marketplace.',
            style: TextStyle(
              color: Theme.of(context).textTheme.bodySmall?.color,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterCard() {
    final accounts = _filteredAccounts;
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            value: _filterMarketplace,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Marketplace',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String>(
                value: 'all',
                child: Text('Semua marketplace'),
              ),
              ...MarketplaceProviders.active.map((provider) {
                return DropdownMenuItem<String>(
                  value: provider.id,
                  child: Text(provider.label),
                );
              }),
            ],
            onChanged: (value) async {
              if (value == null) return;
              final scopedAccounts = _filteredAccountsFor(value, _accounts);
              setState(() {
                _filterMarketplace = value;
                _filterAccountId = value == 'all'
                    ? 'all'
                    : scopedAccounts.isEmpty
                        ? 'all'
                        : scopedAccounts.first.marketplaceAccountId;
              });
              await _loadItems();
            },
          ),
          SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _filterAccountId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Marketplace Account',
              border: OutlineInputBorder(),
            ),
            items: [
              if (_filterMarketplace == 'all' || accounts.isEmpty)
                const DropdownMenuItem<String>(
                  value: 'all',
                  child: Text('Semua account'),
                ),
              ...accounts.map((account) {
                return DropdownMenuItem<String>(
                  value: account.marketplaceAccountId,
                  child: Text(
                    '${account.safeStoreName} · ${account.marketplaceLabel} · ${account.shopRegion}',
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }),
            ],
            onChanged: (value) async {
              if (value == null) return;
              setState(() => _filterAccountId = value);
              await _loadItems();
            },
          ),
          SizedBox(height: 12),
          SearchBox(
            controller: _searchController,
            hint: 'Cari SKU / produk / marketplace SKU',
            onChanged: (_) => _loadItems(),
          ),
          SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isQueueing || _items.isEmpty ? null : _queueAccount,
            icon: _isQueueing
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.playlist_add_check_rounded),
            label:
                Text(_isQueueing ? 'Memproses...' : 'Sinkronkan Sesuai Filter'),
          ),
          SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed:
                _isProcessingWorker || _items.isEmpty || _queuedCount == 0
                    ? null
                    : _processQueueDryRun,
            icon: _isProcessingWorker
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.science_outlined),
            label: Text(
                _isProcessingWorker ? 'Sedang diproses...' : 'Cek Sinkron'),
          ),
          SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: _isProcessingWorker ||
                    _items.isEmpty ||
                    (_queuedCount == 0 && _dryRunOkCount == 0)
                ? null
                : _processQueueRealSync,
            icon: _isProcessingWorker
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.cloud_sync_rounded),
            label: Text('Kirim Kirim Sinkron Stok'),
          ),
          SizedBox(height: 8),
          Text(
            _items.isEmpty
                ? 'Belum ada mapping SKU untuk toko ini. Ambil produk marketplace lalu hubungkan variannya ke SKU lokal.'
                : _queuedCount == 0
                    ? _dryRunOkCount > 0
                        ? 'Cek sinkron berhasil. Tombol Kirim Sinkron Stok akan menyiapkan data otomatis sebelum dikirim.'
                        : 'Belum ada data siap sinkron. Klik Sinkronkan Sesuai Filter terlebih dahulu.'
                    : 'Cek Sinkron hanya validasi. Kirim Sinkron Stok akan mengirim stok lokal ke TikTok/Shopee. Jika otomatis aktif, proses berjalan setiap 10 menit.',
            style: TextStyle(
              color: Theme.of(context).textTheme.bodySmall?.color,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemCard(MarketplaceStockSyncItem item) {
    final status = item.lastSyncStatus ?? (item.apiReady ? 'ready' : 'need_id');
    final statusColor = _statusColor(status);
    final error = item.visibleError;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: NiceCard(
        padding: const EdgeInsets.all(0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
                color: item.marketplace == 'shopee'
                    ? Theme.of(context).colorScheme.primary.withOpacity(0.08)
                    : Theme.of(context).colorScheme.secondary.withOpacity(0.08),
                border: Border(
                    bottom: BorderSide(
                        color: Theme.of(context)
                            .colorScheme
                            .outlineVariant
                            .withOpacity(0.5),
                        width: 0.8)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.14),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      item.marketplace == 'shopee'
                          ? Icons.shopping_bag_outlined
                          : Icons.music_note_rounded,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.localSku,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '${item.safeAccountName} · ${item.marketplaceLabel} · ${item.shopRegion}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.78),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 8),
                  _StatusPill(label: _statusLabel(status), color: statusColor),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _InfoBlock(
                    title: 'Local',
                    lines: [
                      item.localProductName,
                      'SKU: ${item.localSku} · Stock: ${item.stockText} · ${item.localProductStatus}',
                    ],
                  ),
                  SizedBox(height: 10),
                  _InfoBlock(
                    title: 'Marketplace',
                    lines: [
                      item.marketplaceProductWithVariant,
                      'Varian: ${item.marketplaceVariantText}',
                      'Seller/SKU: ${item.marketplaceSkuIdentity}',
                      item.apiIdentityText,
                    ],
                  ),
                  SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MiniChip(
                        label: item.syncEnabled ? 'Aktif' : 'Nonaktif',
                        color: item.syncEnabled ? AppUi.green : AppUi.red,
                      ),
                      _MiniChip(
                        label: item.apiReady ? 'API Ready' : 'Need ID',
                        color: item.apiReady ? AppUi.green : AppUi.orange,
                      ),
                      _MiniChip(
                        label: item.nextAction,
                        color: statusColor,
                      ),
                    ],
                  ),
                  if (item.lastQueuedAt != null) ...[
                    SizedBox(height: 8),
                    Text(
                      'Terakhir siap sinkron: ${AppUi.dateTime(item.lastQueuedAt)}',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (error != null) ...[
                    SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: AppUi.orange.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(16),
                        border:
                            Border.all(color: AppUi.orange.withOpacity(0.28)),
                      ),
                      child: Text(
                        error,
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                  SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _isQueueing || !item.canQueue
                          ? null
                          : () => _queueOne(item),
                      icon: Icon(Icons.sync_rounded),
                      label: Text('Sinkronkan'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'success':
      case 'dry_run_success':
        return AppUi.green;
      case 'failed':
        return AppUi.red;
      case 'waiting_marketplace_ids':
      case 'need_id':
        return AppUi.orange;
      case 'queued':
      case 'processing':
        return AppUi.blue;
      case 'skipped':
        return AppUi.orange;
      default:
        return AppUi.teal;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'waiting_marketplace_ids':
      case 'need_id':
        return 'NEED ID';
      case 'success':
        return 'SUCCESS';
      case 'dry_run_success':
        return 'CEK OK';
      case 'failed':
        return 'GAGAL';
      case 'queued':
        return 'MENUNGGU';
      case 'processing':
        return 'PROCESSING';
      case 'skipped':
        return 'SKIPPED';
      default:
        return 'READY';
    }
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();

    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadInitial);
    }

    return RefreshIndicator(
      onRefresh: _loadItems,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
        children: [
          _header(),
          SizedBox(height: 14),
          _autoSyncCard(),
          SizedBox(height: 14),
          _monitorShortcutCard(),
          SizedBox(height: 14),
          _filterCard(),
          SizedBox(height: 16),
          SectionTitle(
              title: 'Daftar Sinkron',
              actionText: 'Refresh',
              onAction: _loadItems),
          SizedBox(height: 8),
          if (_items.isEmpty)
            const EmptyState(
              title: 'Belum ada SKU mapping',
              subtitle:
                  'Buat Mapping SKU terlebih dahulu agar sinkron stok memiliki tujuan produk dan varian marketplace yang benar.',
              icon: Icons.link_off_rounded,
            )
          else
            ..._items.map(_itemCard),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Sinkron Stok'),
        actions: [
          IconButton(
            onPressed: _loadItems,
            icon: Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(),
    );
  }
}

class _InfoBlock extends StatelessWidget {
  final String title;
  final List<String> lines;

  const _InfoBlock({
    required this.title,
    required this.lines,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.28),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 94,
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines
                  .map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        line,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusPill({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.50)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String label;
  final Color color;

  const _MiniChip({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.28)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}
