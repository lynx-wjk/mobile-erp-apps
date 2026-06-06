import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_ui.dart';

class MarketplaceJobMonitorPage extends StatefulWidget {
  const MarketplaceJobMonitorPage({super.key});

  @override
  State<MarketplaceJobMonitorPage> createState() =>
      _MarketplaceJobMonitorPageState();
}

class _MarketplaceJobMonitorPageState extends State<MarketplaceJobMonitorPage> {
  final SupabaseClient _client = Supabase.instance.client;
  bool _loading = true;
  bool _busy = false;
  Map<String, dynamic> _data = const {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer =
        Timer.periodic(const Duration(seconds: 20), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final result =
          await _client.rpc('marketplace_job_monitor_snapshot_v24_6_9');
      if (!mounted) return;
      setState(() {
        _data = Map<String, dynamic>.from(result as Map);
      });
    } catch (e) {
      if (mounted && !silent) AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resetStuck(String kind, {bool retryFailed = false}) async {
    final counts = _map(kind == 'finance' ? 'finance_counts' : 'order_counts');
    if (_hasActiveRunning(counts)) {
      AppUi.safeSnack(context,
          '${kind == 'finance' ? 'Payout' : 'Order'} masih diproses. Pakai Refresh untuk cek progres.');
      return;
    }
    if (!retryFailed && _count(counts, 'stale_running') <= 0) {
      AppUi.safeSnack(context,
          'Tidak ada antrean yang terlalu lama. Tombol ini aktif kalau proses berhenti lebih dari 20 menit.');
      return;
    }
    if (retryFailed &&
        _count(counts, 'failed') <= 0 &&
        _count(counts, 'retry') <= 0) {
      AppUi.safeSnack(context, 'Tidak ada antrean gagal yang perlu diulang.');
      return;
    }

    setState(() => _busy = true);
    try {
      final result = await _client.rpc(
        'marketplace_job_reset_stuck_v24_6_9',
        params: {
          'p_kind': kind,
          'p_retry_failed': retryFailed,
          'p_stale_minutes': 20,
        },
      );
      await _load();
      if (!mounted) return;
      final map = result is Map
          ? Map<String, dynamic>.from(result)
          : const <String, dynamic>{};
      AppUi.safeSnack(
          context,
          _txt(
              map['message'],
              retryFailed
                  ? 'Antrean gagal dijadwalkan ulang.'
                  : 'Antrean lama dijadwalkan ulang.'));
    } catch (e) {
      if (mounted) AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueFinance() async {
    final counts = _map('finance_counts');
    if (_hasActiveRunning(counts)) {
      AppUi.safeSnack(
          context, 'Payout masih diproses. Pakai Refresh untuk cek progres.');
      return;
    }
    if (_count(counts, 'pending') <= 0 && _count(counts, 'retry') <= 0) {
      AppUi.safeSnack(
          context, 'Tidak ada antrean payout yang perlu dilanjutkan.');
      return;
    }

    final platform = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pilih Platform Payout'),
        content: Text('Marketplace mana yang ingin dilanjutkan antrean payout-nya?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'tiktok'),
            child: Text('TikTok'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'shopee'),
            child: Text('Shopee'),
          ),
        ],
      ),
    );

    if (platform == null) return;

    setState(() => _busy = true);
    try {
      final functionName = platform == 'shopee' ? 'marketplace-order-sync-jobs' : 'marketplace-tiktok-service';
      final action = platform == 'shopee' ? 'process_shopee_finance_sync_jobs' : 'process_finance_sync_jobs';

      final response = await _client.functions.invoke(
        functionName,
        body: {
          'action': action,
          'params': {
            'marketplace': platform,
            'enqueue': false,
            'max_jobs': 1,
            'max_orders': 10,
            'max_batches_per_job': 1,
            'block_if_running': true,
            'source': 'job_monitor_finance_v24_6_9',
          },
        },
      );
      if (response.status < 200 || response.status >= 300) {
        throw Exception('Pembaruan payout belum bisa diproses.');
      }
      await _load();
      if (!mounted) return;
      AppUi.safeSnack(context,
          'Pembaruan payout dimulai. Refresh tetap bisa dipakai untuk cek data masuk.');
    } catch (e) {
      if (mounted) AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueOrder() async {
    final counts = _map('order_counts');
    if (_hasActiveRunning(counts)) {
      AppUi.safeSnack(
          context, 'Order masih diproses. Pakai Refresh untuk cek progres.');
      return;
    }
    if (_count(counts, 'pending') <= 0 && _count(counts, 'retry') <= 0) {
      AppUi.safeSnack(
          context, 'Tidak ada antrean order yang perlu dilanjutkan.');
      return;
    }

    setState(() => _busy = true);
    try {
      final response = await _client.functions.invoke(
        'marketplace-order-sync-jobs',
        body: {
          'mode': 'process_pending',
          'process': true,
          'enqueue': false,
          'max_jobs': 1,
          'page_size': 50,
          'max_pages': 1,
          'max_details': 50,
          'refresh_existing_status': true,
          'status_range_days': 14,
          'max_existing_orders': 80,
          'skip_completed_status_refresh': true,
          'skip_completed_order_pull': true,
          'background': true,
          'block_if_running': true,
          'source': 'job_monitor_order_v24_6_9',
        },
      );
      if (response.status < 200 || response.status >= 300) {
        throw Exception('Pembaruan order belum bisa diproses.');
      }
      await _load();
      if (!mounted) return;
      AppUi.safeSnack(context,
          'Pembaruan order dimulai. Refresh tetap bisa dipakai untuk cek data masuk.');
    } catch (e) {
      if (mounted) AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _cleanError(Object e) {
    final text = e.toString().replaceFirst('Exception: ', '').trim();
    if (text.contains('Failed host lookup') ||
        text.contains('SocketException') ||
        text.contains('ClientException')) {
      return 'Koneksi gagal. Cek internet/DNS/VPN, lalu refresh ulang. Data database tidak rusak.';
    }
    return text.isEmpty ? 'Operasi gagal.' : AppUi.userMessage(text);
  }

  List<Map<String, dynamic>> _list(String key) {
    final raw = _data[key];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  Map<String, dynamic> _map(String key) {
    final raw = _data[key];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  int _count(Map<String, dynamic> counts, String key) {
    final value = counts[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _hasActiveRunning(Map<String, dynamic> counts) {
    final active = _count(counts, 'active_running');
    if (active > 0) return true;

    final running = _count(counts, 'running');
    final stale = _count(counts, 'stale_running');
    return running > stale;
  }

  String _txt(dynamic value, [String fallback = '-']) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  String _statusLabel(String value, bool isStale) {
    final clean = value.toLowerCase();
    if (isStale) return 'Perlu dicek';
    if (clean == 'done' || clean == 'success') return 'Selesai';
    if (clean == 'running') return 'Berjalan';
    if (clean == 'pending') return 'Menunggu';
    if (clean == 'failed') return 'Gagal';
    if (clean == 'retry') return 'Ulangi';
    if (clean == 'cancelled') return 'Dibatalkan';
    return AppUi.userMessage(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final orderCounts = _map('order_counts');
    final financeCounts = _map('finance_counts');
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.cardColor,
        foregroundColor: theme.textTheme.titleLarge?.color,
        title: const Text('Monitor Pembaruan Marketplace'),
        actions: [
          IconButton(
            tooltip: 'Refresh data/job',
            onPressed: _loading ? null : () => _load(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  _infoBox(theme),
                  const SizedBox(height: 14),
                  _summaryCard(
                    theme: theme,
                    title: 'Pembaruan Order',
                    subtitle:
                        'Antrean membaca order terbaru dan memperbarui status pesanan yang belum selesai.',
                    counts: orderCounts,
                    onContinue: _continueOrder,
                    onReset: () => _resetStuck('order'),
                    onRetryFailed: () =>
                        _resetStuck('order', retryFailed: true),
                  ),
                  const SizedBox(height: 14),
                  _jobList(theme, 'Riwayat Order Terbaru', _list('recent_order_jobs')),
                  const SizedBox(height: 14),
                  _summaryCard(
                    theme: theme,
                    title: 'Pembaruan Payout',
                    subtitle:
                        'Antrean membaca payout terbaru dan melengkapi laporan finance.',
                    counts: financeCounts,
                    onContinue: _continueFinance,
                    onReset: () => _resetStuck('finance'),
                    onRetryFailed: () =>
                        _resetStuck('finance', retryFailed: true),
                  ),
                  const SizedBox(height: 14),
                  _jobList(theme,
                      'Riwayat Payout Terbaru', _list('recent_finance_jobs')),
                  const SizedBox(height: 14),
                  _jobList(theme,
                      'Riwayat Sinkron Terbaru', _list('recent_sync_logs')),
                ],
              ),
            ),
    );
  }

  Widget _infoBox(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.dividerColor.withOpacity(0.2))),
      child: Text(
        'Refresh membaca status terbaru. Aksi lanjutkan, ulangi, atau siapkan ulang dikunci saat proses masih berjalan agar data tidak diproses dua kali.',
        style: TextStyle(color: theme.textTheme.bodySmall?.color),
      ),
    );
  }

  Widget _summaryCard({
    required ThemeData theme,
    required String title,
    required String subtitle,
    required Map<String, dynamic> counts,
    required VoidCallback onContinue,
    required VoidCallback onReset,
    required VoidCallback onRetryFailed,
  }) {
    final hasActiveRunning = _hasActiveRunning(counts);
    final hasPending =
        _count(counts, 'pending') > 0 || _count(counts, 'retry') > 0;
    final hasFailed =
        _count(counts, 'failed') > 0 || _count(counts, 'retry') > 0;
    final hasStale = _count(counts, 'stale_running') > 0;

    final canContinue = !_busy && !hasActiveRunning && hasPending;
    final canReset = !_busy && !hasActiveRunning && hasStale;
    final canRetry = !_busy && !hasActiveRunning && hasFailed;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.dividerColor.withOpacity(0.2))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                      color: theme.textTheme.titleLarge?.color,
                      fontWeight: FontWeight.w800)
                  .copyWith(fontSize: 18)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(color: theme.textTheme.bodySmall?.color)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pill(theme, 'Menunggu', counts['pending']),
              _pill(theme, 'Berjalan', counts['running']),
              _pill(theme, 'Aktif', counts['active_running']),
              _pill(theme, 'Terlalu lama', counts['stale_running']),
              _pill(theme, 'Selesai', counts['done']),
              _pill(theme, 'Gagal', counts['failed']),
              _pill(theme, 'Ulangi', counts['retry']),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: canContinue ? onContinue : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Lanjutkan'),
              ),
              OutlinedButton.icon(
                onPressed: canReset ? onReset : null,
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Siapkan ulang'),
              ),
              OutlinedButton.icon(
                onPressed: canRetry ? onRetryFailed : null,
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Ulangi gagal'),
              ),
            ],
          ),
          if (hasActiveRunning) ...[
            const SizedBox(height: 10),
            Text(
                'Proses masih berjalan. Gunakan Refresh untuk cek progres/data masuk.',
                style: TextStyle(color: theme.textTheme.bodySmall?.color)),
          ],
        ],
      ),
    );
  }

  Widget _pill(ThemeData theme, String label, dynamic value) {
    final color = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Text('$label: ${_txt(value, '0')}',
          style: TextStyle(color: theme.textTheme.bodyLarge?.color)
              .copyWith(fontWeight: FontWeight.w700)),
    );
  }

  Widget _jobList(ThemeData theme, String title, List<Map<String, dynamic>> rows) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.dividerColor.withOpacity(0.2))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                      color: theme.textTheme.titleLarge?.color,
                      fontWeight: FontWeight.w800)
                  .copyWith(fontSize: 16)),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Text('Belum ada log.',
                style: TextStyle(color: theme.textTheme.bodySmall?.color))
          else
            ...rows.take(12).map((row) => _jobTile(theme, row)),
        ],
      ),
    );
  }

  Widget _jobTile(ThemeData theme, Map<String, dynamic> row) {
    final isStale = row['is_stale'] == true;
    final status = _statusLabel(_txt(row['status']), isStale);
    final title = AppUi.userMessage(
        _txt(row['title'] ?? row['job_type'] ?? row['sync_type'], 'Pembaruan'));
    final message =
        AppUi.userMessage(_txt(row['message'] ?? row['last_message'], '-'));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(title,
                      style: TextStyle(color: theme.textTheme.bodyLarge?.color)
                          .copyWith(fontWeight: FontWeight.w800))),
              Text(status,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)
                      .copyWith(color: _statusColor(status))),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${_txt(row['updated_at_wib'] ?? row['created_at_wib'])} · umur ${_txt(row['age_minutes'], '0')} mnt · cek ${_txt(row['checked'] ?? row['checked_count'] ?? row['order_count'], '0')} · sukses ${_txt(row['success'] ?? row['success_count'] ?? row['item_count'], '0')} · gagal ${_txt(row['failed'] ?? row['failed_count'], '0')}',
            style: TextStyle(color: theme.textTheme.bodySmall?.color),
          ),
          const SizedBox(height: 4),
          Text(message, style: TextStyle(color: theme.textTheme.bodySmall?.color)),
        ],
      ),
    );
  }


  Color _statusColor(String status) {
    final s = status.toLowerCase();
    if (s == 'done' || s == 'success' || s == 'selesai')
      return Colors.greenAccent;
    if (s == 'running' || s == 'berjalan') return Theme.of(context).colorScheme.primary;
    if (s == 'failed' || s == 'gagal') return Colors.redAccent;
    if (s == 'retry' || s == 'ulangi' || s == 'perlu dicek')
      return Colors.orangeAccent;
    return Theme.of(context).colorScheme.outline;
  }
}
