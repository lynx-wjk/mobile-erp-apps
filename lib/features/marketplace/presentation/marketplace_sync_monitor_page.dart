import 'package:flutter/material.dart';

import '../../../core/ui/app_ui.dart';
import '../../../models/app_user.dart';
import '../models/marketplace_account_public.dart';
import '../models/marketplace_sync_log_item.dart';
import '../services/marketplace_service.dart';

class MarketplaceSyncMonitorPage extends StatefulWidget {
  final AppUser currentUser;

  const MarketplaceSyncMonitorPage({
    super.key,
    required this.currentUser,
  });

  @override
  State<MarketplaceSyncMonitorPage> createState() =>
      _MarketplaceSyncMonitorPageState();
}

class _MarketplaceSyncMonitorPageState
    extends State<MarketplaceSyncMonitorPage> {
  final MarketplaceService _service = MarketplaceService();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  bool _isRetrying = false;
  bool _isDeleting = false;
  String? _errorMessage;

  List<MarketplaceAccountPublic> _accounts = const [];
  List<MarketplaceSyncLogItem> _logs = const [];
  String _filterAccountId = 'all';
  String _filterStatus = 'all';

  static const List<MapEntry<String, String>> _statuses = [
    MapEntry('all', 'Semua'),
    MapEntry('queued', 'Menunggu'),
    MapEntry('processing', 'Diproses'),
    MapEntry('success', 'Berhasil'),
    MapEntry('failed_group', 'Gagal'),
    MapEntry('auth_required', 'Perlu Hubungkan Ulang'),
    MapEntry('waiting_marketplace_ids', 'Belum Lengkap'),
    MapEntry('skipped', 'Dilewati'),
    MapEntry('dry_run_success', 'Cek OK'),
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
      await _loadLogs();
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _cleanError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadLogs() async {
    try {
      final logs = await _service.listSyncLogs(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _filterAccountId,
        status: _filterStatus,
        search: _searchController.text,
        limit: 150,
      );

      if (!mounted) return;
      setState(() {
        _logs = logs;
        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _cleanError(error));
    }
  }

  Future<void> _retryOne(MarketplaceSyncLogItem item) async {
    if (_isRetrying) return;
    setState(() => _isRetrying = true);

    try {
      final updated = await _service.retryStockSyncLog(
        tenantId: widget.currentUser.tenantId,
        marketplaceStockSyncLogId: item.marketplaceStockSyncLogId,
      );
      if (!mounted) return;
      AppUi.showSnack(updated > 0
          ? 'Data akan dicoba ulang.'
          : 'Tidak ada log yang diubah.');
      await _loadLogs();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal retry sync: ${_cleanError(error)}');
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Future<void> _retryAllFailed() async {
    if (_isRetrying) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Coba ulang semua yang gagal?'),
        content: const Text(
          'Data gagal akan dicoba ulang melalui sinkron otomatis atau manual.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Coba Ulang'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() => _isRetrying = true);

    try {
      final updated = await _service.retryFailedStockSyncLogs(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _filterAccountId,
      );
      if (!mounted) return;
      AppUi.showSnack('$updated data gagal siap dicoba ulang.');
      await _loadLogs();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal mencoba ulang: ${_cleanError(error)}');
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Future<void> _deleteOne(MarketplaceSyncLogItem item) async {
    if (_isDeleting) return;
    if (!item.canHapus) {
      AppUi.showSnack('Data yang sedang diproses belum bisa dihapus.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus log sync?'),
        content: Text(
          'Riwayat SKU ${item.localSku} akan dihapus permanen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() => _isDeleting = true);

    try {
      final deleted = await _service.deleteStockSyncLog(
        tenantId: widget.currentUser.tenantId,
        marketplaceStockSyncLogId: item.marketplaceStockSyncLogId,
      );
      if (!mounted) return;
      AppUi.showSnack(deleted > 0
          ? 'Riwayat sinkron berhasil dihapus.'
          : 'Tidak ada riwayat yang dihapus.');
      await _loadLogs();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal menghapus log: ${_cleanError(error)}');
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  Future<void> _deleteFilteredFinished() async {
    if (_isDeleting) return;

    final statusLabel = _statuses
        .firstWhere((item) => item.key == _filterStatus,
            orElse: () => const MapEntry('all', 'Semua'))
        .value;
    var accountLabel = 'semua marketplace account';
    if (_filterAccountId != 'all') {
      for (final account in _accounts) {
        if (account.marketplaceAccountId == _filterAccountId) {
          accountLabel =
              '${account.marketplaceLabel} · ${account.safeStoreName}';
          break;
        }
      }
      if (accountLabel == 'semua marketplace account') {
        accountLabel = 'account terpilih';
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus log sesuai filter?'),
        content: Text(
          'Riwayat selesai untuk $accountLabel dengan status $statusLabel akan dihapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Hapus Log'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() => _isDeleting = true);

    try {
      final deleted = await _service.deleteFinishedStockSyncLogs(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _filterAccountId,
        status: _filterStatus,
      );
      if (!mounted) return;
      AppUi.showSnack('$deleted log sync dihapus.');
      await _loadLogs();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal menghapus log: ${_cleanError(error)}');
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  Future<void> _pruneOldLogs() async {
    if (_isDeleting) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus log lama?'),
        content: const Text(
          'Riwayat lama yang sudah selesai akan dihapus. Data yang masih diproses tetap disimpan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Hapus 30+ Hari'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() => _isDeleting = true);

    try {
      final deleted = await _service.pruneOldStockSyncLogs(
        tenantId: widget.currentUser.tenantId,
        keepDays: 30,
        keepFailed: true,
      );
      if (!mounted) return;
      AppUi.showSnack('$deleted log lama dihapus.');
      await _loadLogs();
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Gagal menghapus log lama: ${_cleanError(error)}');
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  void _openDetail(MarketplaceSyncLogItem item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Sync Detail',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                _detailRow('Status', item.statusLabel),
                _detailRow('Account', item.safeAccountName),
                _detailRow('Marketplace', item.marketplaceLabel),
                _detailRow('Local SKU', item.localSku),
                _detailRow('Local Product', item.localProductName),
                _detailRow('Requested Stock', item.stockText),
                _detailRow('Marketplace Product', item.marketplaceProductName),
                _detailRow('Marketplace Variant', item.marketplaceVariantText),
                _detailRow('Marketplace SKU', item.marketplaceIdentity),
                _detailRow('Product ID', item.marketplaceProductId ?? '-'),
                _detailRow('SKU ID', item.marketplaceSkuId ?? '-'),
                _detailRow('Attempt', item.attemptCount.toString()),
                _detailRow('Created', item.createdText),
                _detailRow('Finished', item.finishedText),
                _detailRow('Proses', AppUi.userMessage(item.workerName ?? '-')),
                const SizedBox(height: 10),
                Text('Message',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                SelectableText(AppUi.userMessage(item.visibleError)),
                if (item.canRetry) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isRetrying
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              _retryOne(item);
                            },
                      icon: const Icon(Icons.replay_rounded),
                      label: const Text('Coba Ulang'),
                    ),
                  ),
                ],
                if (item.canHapus) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isDeleting
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              _deleteOne(item);
                            },
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Hapus Log'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gagalCount = _logs.where((item) => item.canRetry).length;
    final menungguCount =
        _logs.where((item) => item.syncStatus == 'queued').length;
    final berhasilCount = _logs.where((item) => item.isSuccess).length;
    final authCount = _logs
        .where((item) => item.syncStatus == 'perlu hubungkan ulang')
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitor Sinkron Marketplace'),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _loadInitial,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'delete_filtered') {
                _deleteFilteredFinished();
              } else if (value == 'prune_old') {
                _pruneOldLogs();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'delete_filtered',
                child: Text('Hapus log sesuai filter'),
              ),
              PopupMenuItem(
                value: 'prune_old',
                child: Text('Hapus log lama 30+ hari'),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadInitial,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Pantau hasil sinkron stok marketplace dan coba ulang data yang gagal.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _statChip('Total', _logs.length.toString(),
                          Icons.list_alt_rounded),
                      _statChip('Menunggu', menungguCount.toString(),
                          Icons.schedule_rounded),
                      _statChip('Berhasil', berhasilCount.toString(),
                          Icons.check_circle_outline_rounded),
                      _statChip('Perlu Ulang', gagalCount.toString(),
                          Icons.error_outline_rounded),
                      _statChip('Perlu Hubungkan Ulang', authCount.toString(),
                          Icons.lock_outline_rounded),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _filters(),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _loadLogs,
                        icon: const Icon(Icons.search_rounded),
                        label: const Text('Terapkan Filter'),
                      ),
                      FilledButton.icon(
                        onPressed: _isRetrying || gagalCount == 0
                            ? null
                            : _retryAllFailed,
                        icon: _isRetrying
                            ? const SizedBox.square(
                                dimension: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.replay_rounded),
                        label: const Text('Coba Ulang'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isDeleting ||
                                _logs.where((item) => item.canHapus).isEmpty
                            ? null
                            : _deleteFilteredFinished,
                        icon: _isDeleting
                            ? const SizedBox.square(
                                dimension: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_sweep_outlined),
                        label: const Text('Hapus Filter'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isDeleting ? null : _pruneOldLogs,
                        icon: const Icon(Icons.auto_delete_outlined),
                        label: const Text('Hapus 30+ Hari'),
                      ),
                    ],
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    _errorBox(_errorMessage!),
                  ],
                  const SizedBox(height: 12),
                  if (_logs.isEmpty) _emptyBox() else ..._logs.map(_logCard),
                ],
              ),
            ),
    );
  }

  Widget _filters() {
    return Column(
      children: [
        DropdownButtonFormField<String>(
          value: _filterAccountId,
          decoration: const InputDecoration(
            labelText: 'Akun Marketplace',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: 'all', child: Text('Semua account')),
            ..._accounts.map(
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
            _loadLogs();
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
            _loadLogs();
          },
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            labelText: 'Cari SKU / product / error',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              onPressed: () {
                _searchController.clear();
                _loadLogs();
              },
              icon: const Icon(Icons.clear_rounded),
            ),
          ),
          onSubmitted: (_) => _loadLogs(),
        ),
      ],
    );
  }

  Widget _logCard(MarketplaceSyncLogItem item) {
    final color = _statusColor(item.syncStatus);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NiceCard(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: AppTheme.radiusMd,
          onTap: () => _openDetail(item),
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
                    _statusBadge(item.statusLabel, color),
                  ],
                ),
                const SizedBox(height: 8),
                Text('${item.marketplaceLabel} · ${item.safeAccountName}'),
                const SizedBox(height: 4),
                Text(
                    '${item.marketplaceProductName} · ${item.marketplaceVariantText}'),
                const SizedBox(height: 4),
                Text(
                    'Qty: ${item.stockText} · Attempt: ${item.attemptCount} · ${item.finishedText}'),
                if (item.isFailed) ...[
                  const SizedBox(height: 6),
                  Text(
                    item.visibleError,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => _openDetail(item),
                      icon: const Icon(Icons.info_outline_rounded),
                      label: const Text('Detail'),
                    ),
                    const Spacer(),
                    if (item.canRetry)
                      FilledButton.tonalIcon(
                        onPressed: _isRetrying ? null : () => _retryOne(item),
                        icon: const Icon(Icons.replay_rounded),
                        label: const Text('Coba Lagi'),
                      ),
                    if (item.canHapus) ...[
                      const SizedBox(width: 6),
                      IconButton(
                        onPressed: _isDeleting ? null : () => _deleteOne(item),
                        icon: const Icon(Icons.delete_outline_rounded),
                        tooltip: 'Hapus log',
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
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
      case 'success':
      case 'dry_run_success':
        return Colors.green.shade700;
      case 'queued':
      case 'processing':
        return scheme.primary;
      case 'auth_required':
      case 'failed':
      case 'failed_retryable':
      case 'failed_final':
        return scheme.error;
      case 'waiting_marketplace_ids':
      case 'skipped':
        return Colors.orange.shade800;
      default:
        return scheme.onSurfaceVariant;
    }
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 130,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
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
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
                Theme.of(context).brightness == Brightness.dark ? 0.28 : 0.44,
              ),
          width: 0.8,
        ),
      ),
      child: const Text('Belum ada log sesuai filter.'),
    );
  }

  String _cleanError(Object error) {
    var text = error.toString().trim();
    text = text.replaceFirst(RegExp(r'^Exception:\s*'), '');
    return text;
  }
}
