import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../models/marketplace_account_public.dart';
import '../services/marketplace_service.dart';
import 'marketplace_dispatcher_monitor_page.dart';

class MarketplaceJobMonitorPage extends StatefulWidget {
  const MarketplaceJobMonitorPage({super.key});

  @override
  State<MarketplaceJobMonitorPage> createState() =>
      _MarketplaceJobMonitorPageState();
}

class _MarketplaceJobMonitorPageState extends State<MarketplaceJobMonitorPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final MarketplaceService _service = MarketplaceService();
  bool _loading = false;
  bool _busy = false;
  Map<String, dynamic> _data = const {};
  Map<String, dynamic> _financeRetryHealth = const {};
  String? _tenantId;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _data = _emptyMonitorSnapshot();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_load(silent: true));
    });
    _timer =
        Timer.periodic(const Duration(seconds: 20), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _data = _mergeSnapshot(_data, _emptyMonitorSnapshot());
        _loading = false;
      });
    }

    final safeSnapshot = await _buildTimeoutSafeSnapshot().timeout(
      const Duration(seconds: 4),
      onTimeout: () => _timeoutFallbackSnapshot(),
    );
    if (!mounted) return;
    setState(() {
      _data = _mergeSnapshot(_data, safeSnapshot);
      _loading = false;
    });
    unawaited(_loadRichSnapshot(silent: true, baseSnapshot: safeSnapshot));
  }

  Map<String, dynamic> _emptyMonitorSnapshot() {
    return const {
      'account_auth': <Map<String, dynamic>>[],
      'order_counts': <String, dynamic>{},
      'finance_counts': <String, dynamic>{},
      'recent_order_jobs': <Map<String, dynamic>>[],
      'recent_finance_jobs': <Map<String, dynamic>>[],
      'recent_marketplace_logs': <Map<String, dynamic>>[],
      'recent_sync_logs': <Map<String, dynamic>>[],
      'warnings': <Map<String, dynamic>>[],
    };
  }

  Map<String, dynamic> _timeoutFallbackSnapshot() {
    return {
      ..._emptyMonitorSnapshot(),
      'warnings': const [
        {
          'section': 'monitor',
          'error':
              'Monitor belum selesai dimuat. Data ringan tetap ditampilkan.',
        }
      ],
    };
  }

  Future<void> _loadRichSnapshot({
    bool silent = false,
    Map<String, dynamic>? baseSnapshot,
  }) async {
    try {
      final result = await _client
          .rpc('marketplace_job_monitor_snapshot_light')
          .timeout(const Duration(seconds: 5));
      var snapshot = _coerceSnapshot(result);
      snapshot = await _withAccountAuthFallback(snapshot);

      Map<String, dynamic> health = const {};
      try {
        final healthResponse = await _client
            .rpc('marketplace_failed_finance_jobs_90d_health')
            .timeout(const Duration(seconds: 4));
        health = healthResponse is Map
            ? Map<String, dynamic>.from(healthResponse)
            : const {};
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _data = _mergeSnapshot(baseSnapshot ?? _data, snapshot);
        _financeRetryHealth = health;
      });
    } catch (e) {
      if (mounted && !silent) AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, dynamic>> _buildTimeoutSafeSnapshot() async {
    final warnings = <Map<String, dynamic>>[];
    final accountAuth = await _loadAccountAuthRows();
    var orderJobs = <Map<String, dynamic>>[];
    var financeJobs = <Map<String, dynamic>>[];

    final tenantId = await _currentTenantId();
    if (tenantId == null || tenantId.trim().isEmpty) {
      warnings.add({
        'section': 'monitor',
        'error':
            'Profil tenant belum terbaca. Login ulang bila data tetap kosong.',
      });
    } else {
      try {
        orderJobs = await _loadRecentOrderJobRows(tenantId);
      } catch (_) {
        warnings.add({
          'section': 'order',
          'error': 'Ringkasan antrean order belum bisa dibaca.',
        });
      }

      try {
        financeJobs = await _loadRecentFinanceJobRows(tenantId);
      } catch (_) {
        warnings.add({
          'section': 'payout',
          'error': 'Ringkasan antrean payout belum bisa dibaca.',
        });
      }
    }

    return {
      'account_auth': accountAuth,
      'order_counts': _countsFromJobRows(orderJobs),
      'finance_counts': _countsFromJobRows(financeJobs),
      'recent_order_jobs': orderJobs,
      'recent_finance_jobs': financeJobs,
      'recent_marketplace_logs': const <Map<String, dynamic>>[],
      'recent_sync_logs': const <Map<String, dynamic>>[],
      'warnings': warnings,
    };
  }

  Future<String?> _currentTenantId() async {
    final cached = _tenantId?.trim();
    if (cached != null && cached.isNotEmpty) return cached;

    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;

    final profile = await _client
        .from('users')
        .select('tenant_id')
        .eq('user_id', authUser.id)
        .maybeSingle();
    final tenantId = profile?['tenant_id']?.toString().trim();
    if (tenantId != null && tenantId.isNotEmpty) _tenantId = tenantId;
    return _tenantId;
  }

  Future<Map<String, dynamic>> _withAccountAuthFallback(
      Map<String, dynamic> snapshot) async {
    final currentRows = snapshot['account_auth'];
    if (currentRows is List && currentRows.isNotEmpty) return snapshot;

    final fallbackRows = await _loadAccountAuthRows();
    if (fallbackRows.isEmpty) return snapshot;

    return {
      ...snapshot,
      'account_auth': fallbackRows,
    };
  }

  Future<List<Map<String, dynamic>>> _loadAccountAuthRows() async {
    final tenantId = await _currentTenantId();
    if (tenantId == null || tenantId.trim().isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    try {
      final accounts = await _service
          .listAccounts(tenantId: tenantId)
          .timeout(const Duration(seconds: 4));
      return accounts
          .where((account) => account.status.toLowerCase().trim() != 'deleted')
          .map(_accountAuthRow)
          .toList(growable: false);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Map<String, dynamic> _accountAuthRow(MarketplaceAccountPublic account) {
    final status = _tokenStatusFor(account);
    return {
      'marketplace_account_id': account.marketplaceAccountId,
      'marketplace': account.marketplaceLabel,
      'store_name': account.safeStoreName,
      'shop_name': account.shopName,
      'environment': account.environmentLabel,
      'status': account.status,
      'token_status': status,
      'access_token_expired_at':
          account.accessTokenExpiredAt?.toIso8601String(),
      'refresh_token_expired_at':
          account.refreshTokenExpiredAt?.toIso8601String(),
      'access_token_expired_at_wib': _wibText(account.accessTokenExpiredAt),
      'refresh_token_expired_at_wib': _wibText(account.refreshTokenExpiredAt),
      'last_checked_at_wib': _wibText(account.updatedAt ?? account.connectedAt),
      'last_refreshed_at_wib':
          _wibText(account.reauthorizedAt ?? account.connectedAt),
      'last_error': account.lastError ?? '',
    };
  }

  String _tokenStatusFor(MarketplaceAccountPublic account) {
    final accountStatus = account.status.toLowerCase().trim();
    if (accountStatus.isNotEmpty && accountStatus != 'active') {
      return 'inactive';
    }

    final now = DateTime.now().toUtc();
    final refreshExpiry = account.refreshTokenExpiredAt?.toUtc();
    if (refreshExpiry != null && !refreshExpiry.isAfter(now)) {
      return 'refresh_expired_reconnect';
    }

    final accessExpiry = account.accessTokenExpiredAt?.toUtc();
    if (accessExpiry == null) return 'token_present';
    if (!accessExpiry.isAfter(now)) return 'access_expired_needs_refresh';
    if (!accessExpiry.isAfter(now.add(const Duration(days: 3)))) {
      return 'access_expiring_soon';
    }
    return 'token_present';
  }

  Future<List<Map<String, dynamic>>> _loadRecentOrderJobRows(
      String tenantId) async {
    final rows = await _client
        .from('marketplace_order_pull_jobs')
        .select(
            'order_pull_job_id, status, attempts, order_count, item_count, warning_count, last_message, job_type, marketplace, window_label, locked_at, last_run_at, created_at, updated_at')
        .eq('tenant_id', tenantId)
        .order('updated_at', ascending: false)
        .range(0, 49);
    return _jobRowsFromRaw(rows, fallbackTitle: 'Pembaruan order otomatis');
  }

  Future<List<Map<String, dynamic>>> _loadRecentFinanceJobRows(
      String tenantId) async {
    final rows = await _client
        .from('finance_sync_jobs')
        .select('*')
        .eq('tenant_id', tenantId)
        .order('updated_at', ascending: false)
        .range(0, 49);
    return _jobRowsFromRaw(rows, fallbackTitle: 'Pembaruan payout otomatis');
  }

  List<Map<String, dynamic>> _jobRowsFromRaw(
    Object? rows, {
    required String fallbackTitle,
  }) {
    if (rows is! List) return const <Map<String, dynamic>>[];
    return rows.whereType<Map>().map((raw) {
      final row = Map<String, dynamic>.from(raw);
      final status = _normalizedJobStatus(row['status']);
      final ts = _jobTimestamp(row);
      return {
        ...row,
        'title': _txt(row['window_label'] ?? row['job_type'], fallbackTitle),
        'status': status,
        'updated_at_wib': _wibText(ts),
        'created_at_wib': _wibText(_parseDate(row['created_at'])),
        'age_minutes': _ageMinutes(ts),
        'checked': _countFromAny([
          row['checked'],
          row['checked_count'],
          row['order_count'],
          row['transaction_count'],
        ]),
        'success': _countFromAny([
          row['success'],
          row['success_count'],
          row['item_count'],
          row['transaction_count'],
        ]),
        'failed': _countFromAny([
          row['failed'],
          row['failed_count'],
          status == 'failed' ? 1 : 0,
        ]),
        'message': _txt(row['last_message'], 'Status terakhir belum tersedia.'),
        'is_stale': _isStaleRunning(status, ts),
      };
    }).toList(growable: false);
  }

  Map<String, dynamic> _countsFromJobRows(List<Map<String, dynamic>> rows) {
    final counts = <String, int>{
      'pending': 0,
      'running': 0,
      'active_running': 0,
      'stale_running': 0,
      'done': 0,
      'failed': 0,
      'retry': 0,
      'cancelled': 0,
    };

    for (final row in rows) {
      final status = _normalizedJobStatus(row['status']);
      if (counts.containsKey(status)) counts[status] = counts[status]! + 1;
      if (status == 'running') {
        if (row['is_stale'] == true) {
          counts['stale_running'] = counts['stale_running']! + 1;
        } else {
          counts['active_running'] = counts['active_running']! + 1;
        }
      }
    }
    return counts;
  }

  Map<String, dynamic> _mergeSnapshot(
    Map<String, dynamic> base,
    Map<String, dynamic> overlay,
  ) {
    final merged = <String, dynamic>{...base, ...overlay};
    const listKeys = [
      'account_auth',
      'recent_order_jobs',
      'recent_finance_jobs',
      'recent_marketplace_logs',
      'recent_sync_logs',
      'warnings',
    ];
    for (final key in listKeys) {
      final overlayRows = overlay[key];
      final baseRows = base[key];
      if (overlayRows is List &&
          overlayRows.isEmpty &&
          baseRows is List &&
          baseRows.isNotEmpty) {
        merged[key] = baseRows;
      }
    }

    const mapKeys = [
      'order_counts',
      'finance_counts',
      'nonfinal_order_refresh_candidates',
    ];
    for (final key in mapKeys) {
      final overlayMap = overlay[key];
      final baseMap = base[key];
      if (overlayMap is Map &&
          overlayMap.isEmpty &&
          baseMap is Map &&
          baseMap.isNotEmpty) {
        merged[key] = baseMap;
      }
    }
    return merged;
  }

  String _normalizedJobStatus(dynamic value) {
    final status = value?.toString().toLowerCase().trim() ?? '';
    if (status == 'queued') return 'pending';
    if (status == 'success' || status == 'completed') return 'done';
    if (status == 'error') return 'failed';
    if (status == 'canceled') return 'cancelled';
    if (status.isEmpty) return 'done';
    return status;
  }

  DateTime? _jobTimestamp(Map<String, dynamic> row) {
    return _parseDate(row['updated_at'] ??
        row['last_run_at'] ??
        row['locked_at'] ??
        row['created_at']);
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }

  bool _isStaleRunning(String status, DateTime? ts) {
    if (status != 'running' || ts == null) return false;
    return ts.toUtc().isBefore(
          DateTime.now().toUtc().subtract(const Duration(minutes: 20)),
        );
  }

  int _ageMinutes(DateTime? ts) {
    if (ts == null) return 0;
    final diff = DateTime.now().toUtc().difference(ts.toUtc()).inMinutes;
    return diff < 0 ? 0 : diff;
  }

  int _countFromAny(List<dynamic> values) {
    for (final value in values) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return 0;
  }

  String _wibText(DateTime? value) {
    if (value == null) return '-';
    final wib = value.toUtc().add(const Duration(hours: 7));
    final day = wib.day.toString().padLeft(2, '0');
    final month = wib.month.toString().padLeft(2, '0');
    final hour = wib.hour.toString().padLeft(2, '0');
    final minute = wib.minute.toString().padLeft(2, '0');
    return '$day/$month/${wib.year} $hour:$minute';
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
        'marketplace_job_reset_stuck',
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
        content:
            Text('Marketplace mana yang ingin dilanjutkan antrean payout-nya?'),
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
      final functionName = platform == 'shopee'
          ? 'marketplace-order-sync-jobs'
          : 'marketplace-tiktok-service';
      final action = platform == 'shopee'
          ? 'process_shopee_finance_sync_jobs'
          : 'process_finance_sync_jobs';

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
    final lower = text.toLowerCase();
    if (text.contains('57014') ||
        lower.contains('statement timeout') ||
        lower.contains('canceling statement due to statement timeout') ||
        lower.contains('postgrestexception')) {
      return 'Monitor sedang memakai mode ringkas karena server terlalu lama merespons. Tekan Refresh lagi beberapa saat lagi.';
    }
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

  Map<String, dynamic> _coerceSnapshot(Object? result) {
    if (result is Map) return Map<String, dynamic>.from(result);
    return const <String, dynamic>{};
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
            tooltip: 'Monitor Dispatcher',
            icon: const Icon(Icons.route_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const MarketplaceDispatcherMonitorPage(),
                ),
              );
            },
          ),
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
                  _financeRetryHealthBannerWidget(theme),
                  if (_list('warnings').isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _warningsCard(theme, _list('warnings')),
                  ],
                  const SizedBox(height: 14),
                  _accountAuthCard(theme, _list('account_auth')),
                  const SizedBox(height: 14),
                  _refreshCandidateCard(
                      theme, _map('nonfinal_order_refresh_candidates')),
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
                  _jobList(theme, 'Riwayat Order Terbaru',
                      _list('recent_order_jobs')),
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
                  _jobList(theme, 'Riwayat Payout Terbaru',
                      _list('recent_finance_jobs')),
                  const SizedBox(height: 14),
                  _jobList(theme, 'Riwayat Refresh Status Marketplace',
                      _list('recent_marketplace_logs')),
                  const SizedBox(height: 14),
                  _jobList(theme, 'Riwayat Sinkron Terbaru',
                      _list('recent_sync_logs')),
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
          borderRadius: AppTheme.radiusMd,
          border: Border.all(
            color: theme.colorScheme.outlineVariant
                .withOpacity(theme.brightness == Brightness.dark ? 0.3 : 0.5),
            width: 0.8,
          )),
      child: Text(
        'Refresh membaca status terbaru. Aksi lanjutkan, ulangi, atau siapkan ulang dikunci saat proses masih berjalan agar data tidak diproses dua kali.',
        style: TextStyle(color: theme.textTheme.bodySmall?.color),
      ),
    );
  }

  Widget _warningsCard(ThemeData theme, List<Map<String, dynamic>> rows) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Colors.orangeAccent.withOpacity(0.08),
          borderRadius: AppTheme.radiusMd,
          border: Border.all(
            color: Colors.orangeAccent.withOpacity(0.22),
            width: 0.8,
          )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Warning Monitor',
              style: TextStyle(
                      color: theme.textTheme.titleLarge?.color,
                      fontWeight: FontWeight.w800)
                  .copyWith(fontSize: 16)),
          const SizedBox(height: 8),
          ...rows.take(5).map((row) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${_txt(row['section'], 'monitor')}: ${_cleanError(_txt(row['error'], '-'))}',
                  style: TextStyle(color: theme.textTheme.bodySmall?.color),
                ),
              )),
        ],
      ),
    );
  }

  Widget _accountAuthCard(ThemeData theme, List<Map<String, dynamic>> rows) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: AppTheme.radiusMd,
          border: Border.all(
            color: theme.colorScheme.outlineVariant
                .withOpacity(theme.brightness == Brightness.dark ? 0.3 : 0.5),
            width: 0.8,
          )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Status Token Marketplace',
              style: TextStyle(
                      color: theme.textTheme.titleLarge?.color,
                      fontWeight: FontWeight.w800)
                  .copyWith(fontSize: 16)),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text('Belum ada akun marketplace pada tenant ini.',
                style: TextStyle(color: theme.textTheme.bodySmall?.color))
          else
            ...rows.map((row) {
              final status = _txt(row['token_status'], 'unknown');
              final danger =
                  status.contains('expired') || status.contains('missing');
              final warning =
                  status.contains('soon') || status.contains('no_expiry');
              final color = danger
                  ? Colors.redAccent
                  : warning
                      ? Colors.orangeAccent
                      : Colors.greenAccent;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.08),
                  borderRadius: AppTheme.radiusSm,
                  border:
                      Border.all(color: color.withOpacity(0.22), width: 0.8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            "${_txt(row['store_name'])} - ${_txt(row['marketplace'])} - ${_txt(row['environment'])}",
                            style: TextStyle(
                                    color: theme.textTheme.bodyLarge?.color)
                                .copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Text(AppUi.userMessage(status),
                            style: TextStyle(color: color)
                                .copyWith(fontWeight: FontWeight.w800)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      "Access exp: ${_txt(row['access_token_expired_at_wib'])} - Refresh exp: ${_txt(row['refresh_token_expired_at_wib'])} - Last checked: ${_txt(row['last_checked_at_wib'])} - Last refreshed: ${_txt(row['last_refreshed_at_wib'])}",
                      style: TextStyle(color: theme.textTheme.bodySmall?.color),
                    ),
                    if (_txt(row['last_error'], '').trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text("Error: ${_txt(row['last_error'])}",
                          style: TextStyle(color: Colors.redAccent)),
                    ],
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _refreshCandidateCard(
      ThemeData theme, Map<String, dynamic> refreshCandidates) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: AppTheme.radiusMd,
          border: Border.all(
            color: theme.colorScheme.outlineVariant
                .withOpacity(theme.brightness == Brightness.dark ? 0.3 : 0.5),
            width: 0.8,
          )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Target Refresh Status Non-final',
              style: TextStyle(
                      color: theme.textTheme.titleLarge?.color,
                      fontWeight: FontWeight.w800)
                  .copyWith(fontSize: 16)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pill(theme, 'Non-final 90 hari',
                  refreshCandidates['total_nonfinal_90d']),
              _pill(theme, 'Prioritas payout masuk',
                  refreshCandidates['payout_positive_priority']),
              _pill(theme, 'Terakhir dicek',
                  refreshCandidates['last_checked_at_wib']),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Status order tetap diambil dari API marketplace. Payout hanya dipakai untuk prioritas refresh dan warning di detail SKU.',
            style: TextStyle(color: theme.textTheme.bodySmall?.color),
          ),
        ],
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
          borderRadius: AppTheme.radiusMd,
          border: Border.all(
            color: theme.colorScheme.outlineVariant
                .withOpacity(theme.brightness == Brightness.dark ? 0.3 : 0.5),
            width: 0.8,
          )),
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
        border: Border.all(color: color.withOpacity(0.18), width: 0.8),
      ),
      child: Text('$label: ${_txt(value, '0')}',
          style: TextStyle(color: theme.textTheme.bodyLarge?.color)
              .copyWith(fontWeight: FontWeight.w700)),
    );
  }

  Widget _jobList(
      ThemeData theme, String title, List<Map<String, dynamic>> rows) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: AppTheme.radiusMd,
          border: Border.all(
            color: theme.colorScheme.outlineVariant
                .withOpacity(theme.brightness == Brightness.dark ? 0.3 : 0.5),
            width: 0.8,
          )),
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
        borderRadius: AppTheme.radiusSm,
        border: Border.all(
          color: theme.colorScheme.outlineVariant
              .withOpacity(theme.brightness == Brightness.dark ? 0.2 : 0.35),
          width: 0.8,
        ),
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
                  style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant)
                      .copyWith(color: _statusColor(status))),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${_txt(row['updated_at_wib'] ?? row['created_at_wib'])} - umur ${_txt(row['age_minutes'], '0')} mnt - cek ${_txt(row['checked'] ?? row['checked_count'] ?? row['order_count'], '0')} - sukses ${_txt(row['success'] ?? row['success_count'] ?? row['item_count'], '0')} - gagal ${_txt(row['failed'] ?? row['failed_count'], '0')}',
            style: TextStyle(color: theme.textTheme.bodySmall?.color),
          ),
          const SizedBox(height: 4),
          Text(message,
              style: TextStyle(color: theme.textTheme.bodySmall?.color)),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    final s = status.toLowerCase();
    if (s == 'done' || s == 'success' || s == 'selesai')
      return Colors.greenAccent;
    if (s == 'running' || s == 'berjalan')
      return Theme.of(context).colorScheme.primary;
    if (s == 'failed' || s == 'gagal') return Colors.redAccent;
    if (s == 'retry' || s == 'ulangi' || s == 'perlu dicek')
      return Colors.orangeAccent;
    return Theme.of(context).colorScheme.outline;
  }

  double _num(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  Widget _bootstrapFinanceChipWidget(
      ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.dividerColor.withOpacity(.08),
        borderRadius: AppTheme.radiusSm,
        border: Border.all(
          color: theme.colorScheme.outlineVariant
              .withOpacity(theme.brightness == Brightness.dark ? 0.3 : 0.5),
          width: 0.8,
        ),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: theme.textTheme.bodyMedium?.color,
        ),
      ),
    );
  }

  Widget _financeRetryHealthBannerWidget(ThemeData theme) {
    final retryHealth = _financeRetryHealth;
    final pendingRetry = _num(retryHealth['pending_retry']).toInt();
    final embeddedFailures =
        _num(retryHealth['done_with_embedded_failures']).toInt();
    final staleRunning = _num(retryHealth['running_stale']).toInt();
    final hasRetryHealth =
        pendingRetry > 0 || embeddedFailures > 0 || staleRunning > 0;
    if (!hasRetryHealth) {
      return const SizedBox.shrink();
    }

    final accent =
        staleRunning > 0 ? theme.colorScheme.error : theme.colorScheme.tertiary;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withOpacity(.12),
          theme.cardColor,
        ),
        border: Border.all(color: accent.withOpacity(.24), width: 0.8),
        borderRadius: AppTheme.radiusMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sync_problem_rounded, color: accent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PAYOUT 90 HARI SEDANG DIRETRY',
                  style: TextStyle(
                    color: theme.textTheme.bodyLarge?.color,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    letterSpacing: .8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Sebagian payout masih menunggu API marketplace/rate-limit. Halaman boleh ditutup; retry backend berjalan otomatis dengan batch kecil.',
                  style: TextStyle(
                    color: theme.textTheme.bodyMedium?.color,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _bootstrapFinanceChipWidget(
                        theme, 'Retry antre', pendingRetry.toString()),
                    _bootstrapFinanceChipWidget(
                        theme, 'Embedded gagal', embeddedFailures.toString()),
                    if (staleRunning > 0)
                      _bootstrapFinanceChipWidget(
                          theme, 'Running stale', staleRunning.toString()),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
