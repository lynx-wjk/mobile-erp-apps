// ignore_for_file: unused_local_variable
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_roles.dart';
import '../../../core/constants/marketplace_providers.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../../../models/app_user.dart';
import '../../stock/presentation/stock_out_page.dart';
import '../../subscription/presentation/feature_gate_page.dart';
import '../models/marketplace_account_public.dart';
import '../models/marketplace_order_item.dart';
import '../models/marketplace_order_summary.dart';
import '../models/marketplace_sync_progress_info.dart';
import '../services/marketplace_service.dart';
import 'marketplace_refund_monitor_page.dart';

class MarketplaceOrdersPage extends StatefulWidget {
  final AppUser currentUser;

  const MarketplaceOrdersPage({
    super.key,
    required this.currentUser,
  });

  @override
  State<MarketplaceOrdersPage> createState() => _MarketplaceOrdersPageState();
}

class _MarketplaceOrdersPageState extends State<MarketplaceOrdersPage> {
  final MarketplaceService _service = MarketplaceService();
  final TextEditingController _searchController = TextEditingController();

  static String _cachedPullProgressTitle = '';
  static final List<String> _cachedPullProgressLines = <String>[];

  bool _isLoading = true;
  bool _isPulling = false;
  bool _pullProgressFromServerActive = false;
  Timer? _autoSyncPollTimer;
  double? _syncProgressPercentage;
  String _pullProgressTitle = _cachedPullProgressTitle;
  final List<String> _pullProgressLines =
      List<String>.from(_cachedPullProgressLines);
  bool _isProcessing = false;
  bool _isLoadingAutoPullSetting = false;
  bool _isSavingAutoPullSetting = false;
  MarketplaceOrderAutoPullSetting? _autoPullSetting;
  MarketplaceOrderPullJobDigest? _orderJobDigest;
  DateTime? _orderDispatcherLastSuccessAt;
  String? _autoPullSettingWarning;
  String? _errorMessage;
  int _backgroundRefreshToken = 0;
  int _ordersLoadToken = 0;
  String _lastOrderDigestSignature = '';
  bool get _canDeleteBusinessData =>
      AppRolePermissions.canDeleteBusinessData(widget.currentUser.role.roleId);

  static String? _savedFilterAccountId;
  static String? _savedFilterMarketplace;
  static String? _savedFilterStatus;
  static DateTime? _savedPullStartDate;
  static DateTime? _savedPullEndDate;

  List<MarketplaceAccountPublic> _accounts = [];
  List<MarketplaceOrderSummary> _orders = [];
  static const int _ordersPageSize = 100;
  bool _hasMoreOrders = false;
  bool _isLoadingMoreOrders = false;
  String _filterMarketplace = _savedFilterMarketplace ?? 'all';
  String _filterAccountId = _savedFilterAccountId ?? 'all';
  String _filterStatus = _savedFilterStatus ?? 'all';
  int _daysBack = 1;
  DateTime _pullStartDate = _savedPullStartDate ??
      DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _pullEndDate = _savedPullEndDate ??
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  static const List<MapEntry<String, String>> _statuses = [
    MapEntry('all', 'All'),
    MapEntry('ready_to_pick', 'Siap Pick'),
    MapEntry('reserved', 'Disiapkan'),
    MapEntry('partial_scanned', 'Partial Scanned'),
    MapEntry('scanned_done', 'Scanned Done'),
    MapEntry('unmapped', 'Belum Mapping SKU'),
    MapEntry('stock_out_done', 'Stock Out Done'),
    MapEntry('reserve_failed', 'Reserve Failed'),
    MapEntry('stock_out_failed', 'Stock Out Failed'),
    MapEntry('cancel_review_required', 'Cancel Review'),
    MapEntry('return_review_required', 'Return Review'),
    MapEntry('ignored_status', 'Ignored Status'),
  ];

  @override
  void initState() {
    super.initState();
    _daysBack = _selectedPullDays.clamp(1, 90).toInt();
    _loadInitial();
  }

  void _rememberFilters() {
    _savedFilterMarketplace = _filterMarketplace;
    _savedFilterAccountId = _filterAccountId;
    _savedFilterStatus = _filterStatus;
    _savedPullStartDate = _dateOnly(_pullStartDate);
    _savedPullEndDate = _dateOnly(_pullEndDate);
  }

  @override
  void dispose() {
    _autoSyncPollTimer?.cancel();
    _backgroundRefreshToken += 1;
    _ordersLoadToken += 1;
    _searchController.dispose();
    super.dispose();
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

  Future<void> _refreshOrdersAfterBackgroundJob() async {
    final token = ++_backgroundRefreshToken;
    const delays = [
      Duration(seconds: 6),
      Duration(seconds: 12),
      Duration(seconds: 24)
    ];
    for (final delay in delays) {
      await Future<void>.delayed(delay);
      if (!mounted || token != _backgroundRefreshToken) return;

      await _refreshPersistentOrderPullLog();
      if (!mounted || token != _backgroundRefreshToken) return;

      await _loadOrders(showLoader: false);
      if (!mounted || token != _backgroundRefreshToken) return;

      final stillActive = _pullProgressFromServerActive ||
          (_orderJobDigest?.hasActive ?? false);
      if (!stillActive) return;
    }
  }

  void _cachePullProgress() {
    _cachedPullProgressTitle = _pullProgressTitle;
    _cachedPullProgressLines
      ..clear()
      ..addAll(_pullProgressLines.take(12));
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await Future.wait([
        _service
            .listAccounts(tenantId: widget.currentUser.tenantId)
            .then((accounts) {
          if (!mounted) return;
          setState(() {
            _accounts = accounts;
            if (_filterAccountId != 'all' &&
                !_filteredAccountsFor(_filterMarketplace, accounts)
                    .any((item) => item.marketplaceAccountId == _filterAccountId)) {
              _filterAccountId = 'all';
              _rememberFilters();
            }
          });
        }),
        _loadOrderAutoPullSetting(showSnack: false),
        _refreshPersistentOrderPullLog(),
        _loadOrders(showLoader: false),
      ]);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _cleanError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadOrders({bool showLoader = true}) async {
    final requestToken = ++_ordersLoadToken;
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final data = await _service.listMarketplaceOrders(
        tenantId: widget.currentUser.tenantId,
        marketplace: _filterMarketplace,
        marketplaceAccountId: _filterAccountId,
        status: _filterStatus,
        search: _searchController.text,
        startDate: _dateParam(_pullStartDate),
        endDate: _dateParam(_pullEndDate),
        limit: _ordersPageSize + 1,
        offset: 0,
      );

      final hasMore = data.length > _ordersPageSize;
      final visible = hasMore ? data.take(_ordersPageSize).toList() : data;

      if (!mounted || requestToken != _ordersLoadToken) return;
      setState(() {
        _orders = visible;
        _hasMoreOrders = hasMore;
      });
    } catch (error) {
      if (!mounted || requestToken != _ordersLoadToken) return;
      setState(() => _errorMessage = _cleanError(error));
    } finally {
      if (mounted && showLoader && requestToken == _ordersLoadToken) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadMoreOrders() async {
    if (_isLoadingMoreOrders || !_hasMoreOrders) return;
    if (!mounted) return;
    final requestToken = _ordersLoadToken;
    setState(() => _isLoadingMoreOrders = true);

    try {
      final data = await _service.listMarketplaceOrders(
        tenantId: widget.currentUser.tenantId,
        marketplace: _filterMarketplace,
        marketplaceAccountId: _filterAccountId,
        status: _filterStatus,
        search: _searchController.text,
        startDate: _dateParam(_pullStartDate),
        endDate: _dateParam(_pullEndDate),
        limit: _ordersPageSize + 1,
        offset: _orders.length,
      );

      final hasMore = data.length > _ordersPageSize;
      final visible = hasMore ? data.take(_ordersPageSize).toList() : data;
      if (!mounted || requestToken != _ordersLoadToken) return;
      setState(() {
        _orders = [..._orders, ...visible];
        _hasMoreOrders = hasMore;
      });
    } catch (error) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(error));
    } finally {
      if (mounted) setState(() => _isLoadingMoreOrders = false);
    }
  }

  Future<void> _loadOrderAutoPullSetting({bool showSnack = true}) async {
    if (!mounted) return;
    setState(() {
      _isLoadingAutoPullSetting = true;
      _autoPullSettingWarning = null;
    });

    try {
      final setting = await _service.getOrderAutoPullSetting(
        tenantId: widget.currentUser.tenantId,
      );
      if (!mounted) return;
      setState(() => _autoPullSetting = setting);
    } catch (error) {
      final message = _cleanError(error);
      if (!mounted) return;
      setState(() => _autoPullSettingWarning = message);
      if (showSnack) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
              content: Text('Gagal membaca pengaturan auto pull: $message')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingAutoPullSetting = false);
    }
  }

  Future<void> _setOrderAutoPullEnabled(bool enabled) async {
    if (_isSavingAutoPullSetting) return;

    final previous = _autoPullSetting;
    setState(() {
      _isSavingAutoPullSetting = true;
      _autoPullSetting = MarketplaceOrderAutoPullSetting(
        enabled: enabled,
        intervalMinutes: previous?.intervalMinutes ?? 10,
        daysBack: previous?.daysBack ?? 90,
        previousUnpackedDays: previous?.previousUnpackedDays ?? 90,
        updatedAt: previous?.updatedAt,
      );
    });

    try {
      final setting = await _service.setOrderAutoPullEnabled(
        tenantId: widget.currentUser.tenantId,
        enabled: enabled,
      );
      if (!mounted) return;
      setState(() {
        _autoPullSetting = setting;
        _autoPullSettingWarning = null;
      });
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            setting.enabled
                ? 'Auto pull order aktif setiap ${setting.intervalMinutes} menit.'
                : 'Auto pull order dimatikan.',
          ),
        ),
      );
      await _refreshPersistentOrderPullLog();
      await _loadOrders(showLoader: false);
      if (setting.enabled) unawaited(_refreshOrdersAfterBackgroundJob());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _autoPullSetting = previous;
        _autoPullSettingWarning = _cleanError(error);
      });
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
            content: Text('Gagal mengubah auto pull: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isSavingAutoPullSetting = false);
    }
  }

  // ignore: unused_element
  Future<String?> _refreshReturnCancelFlags({
    required String marketplaceAccountId,
  }) async {
    final reviewDaysBack = _selectedPullDays < 90 ? 90 : _selectedPullDays;
    return _service.refreshMarketplaceReturnCancelFlags(
      tenantId: widget.currentUser.tenantId,
      marketplaceAccountId: marketplaceAccountId,
      daysBack: reviewDaysBack,
    );
  }

  Future<bool> _refreshPersistentOrderPullLog() async {
    final tenantId = widget.currentUser.tenantId;
    final results = await Future.wait([
      _service.getLatestOrderDispatcherSuccessAt(tenantId: tenantId),
      _service.getRecentOrderPullJobDigest(tenantId: tenantId, limit: 20),
      _service.getAutomaticOrderSyncStates(tenantId: tenantId),
    ]);

    if (!mounted) return false;
    final dispatcherLastSuccess = results[0] as DateTime?;
    final digest = results[1] as MarketplaceOrderPullJobDigest;
    final syncStates = results[2] as List<Map<String, dynamic>>;

    _orderDispatcherLastSuccessAt = dispatcherLastSuccess;

    // Detect automatic background sync / bootstrap with unified calculation
    final syncSummary = MarketplaceSyncProgressSummary.fromRawStates(
      syncStates,
      filterMarketplace: _filterMarketplace,
      filterAccountId: _filterAccountId,
    );

    final hasActiveAutoSync = syncSummary.hasActiveSync;
    final overallPct = syncSummary.overallProgressPercent;
    final calculatedPercentage =
        hasActiveAutoSync ? (overallPct / 100.0).clamp(0.02, 1.0) : null;

    final channelBadges = syncSummary.accounts.map((a) {
      final statusLabel =
          a.isActive ? '${a.progressPercent.toInt()}%' : 'Selesai';
      return '${a.displayName}: $statusLabel';
    }).join(' · ');

    final activeMarketplaces = syncSummary.accounts
        .where((a) => a.isActive)
        .map((a) => a.displayName)
        .toSet()
        .join(' & ');

    final pctLabel = calculatedPercentage != null
        ? ' (${(calculatedPercentage * 100).toInt()}%)'
        : '';
    final autoSyncTitle =
        'Sinkronisasi Otomatis Pesanan $activeMarketplaces Sedang Berjalan$pctLabel';
    final autoSyncDetail = channelBadges.isNotEmpty
        ? 'Progress per kanal: $channelBadges · Data otomatis diperbarui.'
        : 'Menarik riwayat pesanan di background. Data otomatis diperbarui.';

    final hasActiveManualJob = digest?.hasActive ?? false;
    final isAnyActive = hasActiveAutoSync || hasActiveManualJob;

    if (isAnyActive) {
      if (_autoSyncPollTimer == null || !_autoSyncPollTimer!.isActive) {
        _autoSyncPollTimer =
            Timer.periodic(const Duration(seconds: 4), (_) async {
          if (!mounted) return;
          final stillRunning = await _refreshPersistentOrderPullLog();
          if (stillRunning) {
            await _loadOrders(showLoader: false);
          } else {
            _autoSyncPollTimer?.cancel();
            _autoSyncPollTimer = null;
            await _loadOrders(showLoader: false);
          }
        });
      }
    } else {
      _autoSyncPollTimer?.cancel();
      _autoSyncPollTimer = null;
    }

    final updatedLabel = digest?.latestUpdatedAt == null
        ? '-'
        : _dateTimeWib(digest!.latestUpdatedAt);
    final active = isAnyActive;
    final header = hasActiveAutoSync
        ? autoSyncTitle
        : (active ? 'Pembaruan order masih berjalan' : 'Riwayat pembaruan order');
    final friendlySummary = hasActiveAutoSync
        ? autoSyncDetail
        : (digest != null
            ? 'Berjalan ${digest.running} · Menunggu ${digest.pending} · Selesai ${digest.done} · Gagal ${digest.failed} · Update $updatedLabel'
            : '');

    setState(() {
      _orderJobDigest = digest;
      _orderDispatcherLastSuccessAt = dispatcherLastSuccess;
      _syncProgressPercentage = calculatedPercentage;
      _lastOrderDigestSignature =
          digest != null ? _orderDigestSignature(digest) : '';
      _pullProgressFromServerActive = active;
      _pullProgressTitle = header;
      _pullProgressLines
        ..clear()
        ..add(friendlySummary);
      _cachePullProgress();
    });
    return active;
  }

  String _orderDigestSignature(MarketplaceOrderPullJobDigest digest) {
    return [
      digest.running,
      digest.pending,
      digest.done,
      digest.failed,
      digest.latestUpdatedAt?.toUtc().toIso8601String() ?? '',
      ...digest.lines.take(3),
    ].join('|');
  }

  Future<void> _pullOrders() async {
    if (_filterAccountId == 'all') {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
            content: Text('Pilih akun marketplace terlebih dahulu.')),
      );
      return;
    }

    await _refreshPersistentOrderPullLog();
    final activeDigest = _orderJobDigest;
    if (activeDigest != null && activeDigest.hasActive) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Masih ada pembaruan order berjalan: ${activeDigest.running} aktif, ${activeDigest.pending} menunggu. Sistem tidak membuat antrean baru agar data tidak diproses dua kali.',
          ),
        ),
      );
      await _loadOrders(showLoader: false);
      unawaited(_refreshOrdersAfterBackgroundJob());
      return;
    }

    final today = _dateOnly(DateTime.now());
    final confirmed = await _confirm(
      title: 'Ambil Order Terbaru',
      message:
          'Sistem akan mengambil order hari ini dan memperbarui status pesanan aktif. Filter tanggal di layar tetap dipakai hanya untuk melihat data.',
      actionText: 'Sinkron Hari Ini',
    );
    if (!confirmed) return;

    setState(() {
      _isPulling = true;
      _pullProgressFromServerActive = true;
      _pullProgressTitle = 'Menjalankan pembaruan order terbaru';
      _pullProgressLines
        ..clear()
        ..add(
            'Menyiapkan order terbaru hari ini (${_dateLabel(today)}) dan memperbarui status pesanan aktif.');
      _cachePullProgress();
    });

    try {
      final result = await _service.processMarketplaceOrderPullJobs(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _filterAccountId,
        mode: 'today',
        startDate: _dateParam(today),
        endDate: _dateParam(today),
        enqueue: true,
        process: true,
        maxJobs: 1,
        windowMinutes: 120,
        pageSize: 50,
        maxPages: 1,
        maxDetails: 50,
        includeUpdateTimeSearch: true,
        refreshExistingStatus: true,
        statusRangeDays: 14,
        maxExistingOrders: 80,
        skipCompletedStatusRefresh: true,
        skipCompletedOrderPull: true,
        background: true,
        rejectIfActive: true,
      );

      if (!mounted) return;
      setState(() {
        _pullProgressTitle = 'Pembaruan order terbaru sedang berjalan';
        _pullProgressLines
          ..clear()
          ..add(
              'Antrean baru ${result.queued}, sisa proses ${result.remaining}. Proses tetap berjalan walaupun menu ditutup.')
          ..add('Pesanan yang sudah selesai tidak diubah.');
        _pullProgressFromServerActive =
            result.remaining > 0 || result.queued > 0;
        _cachePullProgress();
      });

      await _refreshPersistentOrderPullLog();
      await _loadOrders(showLoader: false);
      unawaited(_refreshOrdersAfterBackgroundJob());

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(AppUi.userMessage(result.summary))),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _pullProgressTitle = 'Gagal memulai pembaruan order';
          _pullProgressLines.insert(0,
              'Gagal: ${AppUi.userMessage(_shortMessage(_cleanError(error)))}');
          if (_pullProgressLines.length > 10) _pullProgressLines.removeLast();
          _pullProgressFromServerActive = false;
          _cachePullProgress();
        });
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(AppUi.userMessage(_cleanError(error)))),
        );
      }
    } finally {
      if (mounted) setState(() => _isPulling = false);
    }
  }

  Widget _pullProgressCard() {
    final bool active = _isPulling ||
        _pullProgressFromServerActive ||
        (_orderJobDigest?.hasActive ?? false);
    if (!active) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final title = _pullProgressTitle.trim().isNotEmpty
        ? _pullProgressTitle.trim()
        : 'Sedang menyinkronkan data pesanan marketplace...';
    final latestDetail = _pullProgressLines.isNotEmpty
        ? _pullProgressLines.first.trim()
        : 'Memproses penarikan order terbaru & riwayat dari Shopee / TikTok...';

    final progress = _syncProgressPercentage;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  progress != null ? '${(progress * 100).toInt()}%' : 'SYNCING',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: theme.colorScheme.primary,
            ),
          ),
          if (latestDetail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              latestDetail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  String _shortMessage(String value) {
    final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= 120) return clean;
    return '${clean.substring(0, 120)}...';
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  int get _selectedPullDays {
    final start = _dateOnly(_pullStartDate);
    final end = _dateOnly(_pullEndDate);
    if (end.isBefore(start)) return 1;
    return end.difference(start).inDays + 1;
  }

  String _dateParam(DateTime value) {
    final date = _dateOnly(value);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String _dateLabel(DateTime value) {
    final date = _dateOnly(value);
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '$day/$month/${date.year}';
  }

  String _dateTimeWib(dynamic value) {
    return AppUi.formatWibDateTime(value);
  }

  Future<void> _pickPullDateRange() async {
    final firstDate = _dateOnly(
      DateTime.now().subtract(const Duration(days: 90)),
    );
    final lastDate = _dateOnly(DateTime.now().add(const Duration(days: 1)));
    final picked = await _showCompactPullDateRangePicker(
      initialStart: _pullStartDate,
      initialEnd: _pullEndDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null) return;
    setState(() {
      _pullStartDate = _dateOnly(picked.start);
      _pullEndDate = _dateOnly(picked.end);
      _daysBack = _selectedPullDays.clamp(1, 90).toInt();
      _rememberFilters();
    });
    await _loadOrders(showLoader: false);
  }

  Future<DateTimeRange?> _showCompactPullDateRangePicker({
    required DateTime initialStart,
    required DateTime initialEnd,
    required DateTime firstDate,
    required DateTime lastDate,
  }) {
    var draftStart =
        _clampPullDate(_dateOnly(initialStart), firstDate, lastDate);
    var draftEnd = _clampPullDate(_dateOnly(initialEnd), firstDate, lastDate);
    if (draftEnd.isBefore(draftStart)) draftEnd = draftStart;
    var visibleMonth = DateTime(draftStart.year, draftStart.month);
    var pickingStart = true;

    const monthNames = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    const weekdayNames = <String>[
      'Sen',
      'Sel',
      'Rab',
      'Kam',
      'Jum',
      'Sab',
      'Min'
    ];
    final firstVisibleMonth = DateTime(firstDate.year, firstDate.month);
    final lastVisibleMonth = DateTime(lastDate.year, lastDate.month);

    return showDialog<DateTimeRange>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final colorScheme = Theme.of(context).colorScheme;

          String monthTitle(DateTime value) =>
              '${monthNames[value.month - 1]} ${value.year}';

          void setDraftRange(DateTime start, DateTime end) {
            draftStart = _clampPullDate(_dateOnly(start), firstDate, lastDate);
            draftEnd = _clampPullDate(_dateOnly(end), firstDate, lastDate);
            if (draftEnd.isBefore(draftStart)) draftEnd = draftStart;
            visibleMonth = DateTime(draftStart.year, draftStart.month);
            pickingStart = false;
          }

          void selectDay(DateTime value) {
            final picked =
                _clampPullDate(_dateOnly(value), firstDate, lastDate);
            setSheetState(() {
              if (pickingStart) {
                draftStart = picked;
                if (draftEnd.isBefore(draftStart)) draftEnd = draftStart;
                pickingStart = false;
              } else {
                draftEnd = picked;
                if (draftStart.isAfter(draftEnd)) draftStart = draftEnd;
              }
            });
          }

          Widget dayCell(int index) {
            final firstOfMonth =
                DateTime(visibleMonth.year, visibleMonth.month);
            final daysInMonth =
                DateTime(visibleMonth.year, visibleMonth.month + 1, 0).day;
            final day = index - (firstOfMonth.weekday - DateTime.monday) + 1;
            if (day < 1 || day > daysInMonth) {
              return const SizedBox(width: 40, height: 36);
            }

            final date =
                _dateOnly(DateTime(visibleMonth.year, visibleMonth.month, day));
            final disabled = date.isBefore(firstDate) || date.isAfter(lastDate);
            final isStart = DateUtils.isSameDay(date, draftStart);
            final isEnd = DateUtils.isSameDay(date, draftEnd);
            final inRange = date.isAfter(draftStart) && date.isBefore(draftEnd);
            final selected = isStart || isEnd;

            Color? backgroundColor;
            Color? foregroundColor;
            if (selected) {
              backgroundColor =
                  isStart ? colorScheme.primary : colorScheme.secondary;
              foregroundColor = colorScheme.onPrimary;
            } else if (inRange) {
              backgroundColor = colorScheme.primary.withValues(alpha: 0.10);
              foregroundColor = colorScheme.onSurface;
            } else if (disabled) {
              foregroundColor = colorScheme.onSurface.withValues(alpha: 0.38);
            } else {
              foregroundColor = colorScheme.onSurface;
            }

            return SizedBox(
              width: 40,
              height: 36,
              child: TextButton(
                onPressed: disabled ? null : () => selectDay(date),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(40, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: foregroundColor,
                  backgroundColor: backgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text('$day'),
              ),
            );
          }

          Widget calendarGrid() {
            final firstOfMonth =
                DateTime(visibleMonth.year, visibleMonth.month);
            final daysInMonth =
                DateTime(visibleMonth.year, visibleMonth.month + 1, 0).day;
            final leading = firstOfMonth.weekday - DateTime.monday;
            final totalCells = ((leading + daysInMonth + 6) ~/ 7) * 7;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final weekday in weekdayNames)
                      SizedBox(
                        width: 40,
                        height: 24,
                        child: Center(
                          child: Text(
                            weekday,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (var i = 0; i < totalCells; i++) dayCell(i),
                  ],
                ),
              ],
            );
          }

          return AlertDialog(
            title: const Text('Pilih periode penarikan'),
            content: SizedBox(
              width: 332,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: Text('Dari ${_dateLabel(draftStart)}'),
                        selected: pickingStart,
                        onSelected: (_) =>
                            setSheetState(() => pickingStart = true),
                      ),
                      ChoiceChip(
                        label: Text('Sampai ${_dateLabel(draftEnd)}'),
                        selected: !pickingStart,
                        onSelected: (_) =>
                            setSheetState(() => pickingStart = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Bulan sebelumnya',
                        onPressed: visibleMonth.isAfter(firstVisibleMonth)
                            ? () => setSheetState(() {
                                  visibleMonth = DateTime(visibleMonth.year,
                                      visibleMonth.month - 1);
                                })
                            : null,
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            monthTitle(visibleMonth),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Bulan berikutnya',
                        onPressed: visibleMonth.isBefore(lastVisibleMonth)
                            ? () => setSheetState(() {
                                  visibleMonth = DateTime(visibleMonth.year,
                                      visibleMonth.month + 1);
                                })
                            : null,
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                  calendarGrid(),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('Hari ini'),
                        onPressed: () => setSheetState(() {
                          final today = _dateOnly(DateTime.now());
                          setDraftRange(today, today);
                        }),
                      ),
                      ActionChip(
                        label: const Text('Bulan ini'),
                        onPressed: () => setSheetState(() {
                          final now = DateTime.now();
                          setDraftRange(
                            DateTime(now.year, now.month),
                            _dateOnly(now),
                          );
                        }),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(
                    dialogContext,
                    DateTimeRange(start: draftStart, end: draftEnd),
                  );
                },
                child: const Text('Terapkan'),
              ),
            ],
          );
        },
      ),
    );
  }

  DateTime _clampPullDate(
    DateTime value,
    DateTime firstDate,
    DateTime lastDate,
  ) {
    final date = _dateOnly(value);
    if (date.isBefore(firstDate)) return firstDate;
    if (date.isAfter(lastDate)) return lastDate;
    return date;
  }

  Widget _dateRangePickerField({
    required String label,
    required DateTime startDate,
    required DateTime endDate,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: Icon(Icons.calendar_month_rounded, size: 18),
        ),
        child: Text(
          '${_dateLabel(startDate)} - ${_dateLabel(endDate)}',
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  // ignore: unused_element
  int get _orderPullMaxPages {
    if (_daysBack <= 1) return 10;
    if (_daysBack <= 3) return 16;
    if (_daysBack <= 7) return 30;
    if (_daysBack <= 14) return 50;
    return 80;
  }

  Future<void> _reserveSiapOrders() async {
    final confirmed = await _confirm(
      title: 'Siapkan Order Siap Proses',
      message:
          'Order siap proses akan masuk daftar picking. Stok baru berkurang setelah item discan dan disimpan.',
      actionText: 'Reserve',
    );
    if (!confirmed) return;

    setState(() => _isProcessing = true);
    try {
      final result = await _service.processSiapMarketplaceOrdersStockOut(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _filterAccountId,
      );
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(result.message)),
      );
      await _loadOrders(showLoader: false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _pullProgressLines.insert(
              0, 'Gagal: ${_shortMessage(_cleanError(error))}');
          if (_pullProgressLines.length > 8) _pullProgressLines.removeLast();
          _cachePullProgress();
        });
      }
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
            content: Text('Gagal menyiapkan order: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _reserveOne(MarketplaceOrderSummary order) async {
    final confirmed = await _confirm(
      title: 'Siapkan Order',
      message:
          'Order ${order.externalOrderId} akan masuk daftar picking. Stok baru berkurang setelah barcode discan dan disimpan.',
      actionText: 'Reserve',
    );
    if (!confirmed) return;

    setState(() => _isProcessing = true);
    try {
      final result = await _service.processMarketplaceOrderStockOut(
        tenantId: widget.currentUser.tenantId,
        marketplaceOrderId: order.marketplaceOrderId,
      );
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(result.message)),
      );
      await _loadOrders(showLoader: false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _pullProgressLines.insert(
              0, 'Gagal: ${_shortMessage(_cleanError(error))}');
          if (_pullProgressLines.length > 8) _pullProgressLines.removeLast();
          _cachePullProgress();
        });
      }
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
            content: Text('Gagal menyiapkan order: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _openStockOut() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FeatureGatePage(
          featureKey: 'stock_basic',
          featureLabel: 'Stock Out',
          child: StockOutPage(),
        ),
      ),
    );
    await _loadOrders(showLoader: false);
  }

  Future<void> _openRefundMonitor() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FeatureGatePage(
          featureKey: 'marketplace_return_refund',
          featureLabel: 'Refund / retur marketplace',
          child: MarketplaceRefundMonitorPage(
            currentUser: widget.currentUser,
            accounts: _accounts,
            initialAccountId: _filterAccountId,
          ),
        ),
      ),
    );
    await _loadOrders(showLoader: false);
  }

  Future<void> _copyValue(String label, String value) async {
    final clean = value.trim();
    if (clean.isEmpty || clean == '-') {
      AppUi.safeSnack(context, '$label kosong.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: clean));
    if (mounted) AppUi.safeSnack(context, '$label disalin: $clean');
  }

  Future<void> _openDetail(MarketplaceOrderSummary order) async {
    final items = await _service.listMarketplaceOrderItems(
      tenantId: widget.currentUser.tenantId,
      marketplaceOrderId: order.marketplaceOrderId,
    );
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: (Theme.of(context).cardColor),
      showDragHandle: false,
      builder: (context) {
        final scheme = (Theme.of(context).colorScheme);
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: ColoredBox(
            color: scheme.surface,
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.84,
              minChildSize: 0.45,
              maxChildSize: 0.95,
              builder: (context, controller) {
                return ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                  children: [
                    Text(
                      'Order ${order.externalOrderId}',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 8),
                    _detailRow('Marketplace',
                        '${order.marketplace} · ${order.accountName}'),
                    _detailRow('Order ID', order.externalOrderId),
                    _detailRow('Internal ID', order.marketplaceOrderId),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () =>
                              _copyValue('Order ID', order.externalOrderId),
                          icon: Icon(Icons.copy_rounded, size: 18),
                          label: Text('Copy Order ID'),
                        ),
                        if (order.resiText != '-')
                          OutlinedButton.icon(
                            onPressed: () => _copyValue('Resi Fisik Stock Out',
                                order.stockOutReferenceText),
                            icon: Icon(Icons.copy_rounded, size: 18),
                            label: Text('Copy Resi'),
                          ),
                      ],
                    ),
                    SizedBox(height: 6),
                    _detailRow('Order status', order.orderStatusLabel),
                    _detailRow(
                        'Pick status',
                        order.hasPendingReturnReview
                            ? order.reviewBadgeLabel
                            : order.stockActionLabel),
                    _detailRow(
                        'Tracking Marketplace', order.trackingDisplayText),
                    _detailRow(
                        'Resi Fisik Stock Out', order.stockOutReferenceText),
                    _detailRow('Sumber resi', order.resiSourceText),
                    _detailRow('Order time', order.orderTimeText),
                    _detailRow('Diambil', order.pulledTimeText),
                    if (order.hasCancelRequest) ...[
                      SizedBox(height: 10),
                      _warningBox(
                        'Pengajuan cancel buyer terdeteksi',
                        order.cancelRequestSummary,
                      ),
                      _detailRow(
                          'Cancel status', order.cancelRequestStatusText),
                      _detailRow(
                          'Cancel reason',
                          order.cancelRequestReason.trim().isEmpty
                              ? '-'
                              : order.cancelRequestReason),
                      _detailRow(
                          'Cancel requested', order.cancelRequestedTimeText),
                      if (order.cancelRequestNote.trim().isNotEmpty)
                        _detailRow('Buyer note', order.cancelRequestNote),
                    ],
                    if (order.hasPendingReturnReview) ...[
                      SizedBox(height: 10),
                      _warningBox(
                        'Perlu cek refund/cancel',
                        order.pendingReturnReviewSummary,
                      ),
                    ],
                    if ((order.lastError ?? '').trim().isNotEmpty)
                      _errorBox(order.lastError!),
                    SizedBox(height: 14),
                    Text('Items',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    SizedBox(height: 8),
                    if (items.isEmpty)
                      _emptyBox('Belum ada item order.')
                    else
                      ...items.map(_itemCard),
                    SizedBox(height: 16),
                    if (order.canProcessStockOut)
                      FilledButton.icon(
                        onPressed: _isProcessing
                            ? null
                            : () {
                                AppUi.safePop(context);
                                _reserveOne(order);
                              },
                        icon: Icon(Icons.inventory_2_outlined),
                        label: Text('Reserve / Pick List'),
                      ),
                    if (order.canOpenPickScan || order.canFinalizeStockOut) ...[
                      SizedBox(height: 10),
                      FilledButton.tonalIcon(
                        onPressed: _isProcessing
                            ? null
                            : () {
                                AppUi.safePop(context);
                                _openStockOut();
                              },
                        icon: Icon(Icons.output_outlined),
                        label: Text('Buka Stock Out'),
                      ),
                    ],
                    if (order.needsReturnReview) ...[
                      SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () {
                          AppUi.safePop(context);
                          _openRefundMonitor();
                        },
                        icon: Icon(Icons.assignment_return_outlined),
                        label: Text('Open Refund/Cancel Monitor'),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _clearOrderFinanceData() async {
    if (!_canDeleteBusinessData) {
      AppUi.safeSnack(context,
          'Hapus data order dan finance hanya tersedia untuk Super Admin.');
      return;
    }
    if (_isPulling || _isProcessing) return;

    final accountId = _filterAccountId == 'all' ? null : _filterAccountId;
    final scope = accountId == null
        ? 'semua akun marketplace'
        : 'akun marketplace yang sedang dipilih';
    final ok = await _confirm(
      title: 'Hapus data order + finance?',
      message:
          'Ini akan menghapus data order marketplace, item order, scan item, finance report, finance item, abnormal, refund/cancel review, dan log sync untuk $scope. Mapping SKU lokal dan master SKU tidak akan dihapus. Pakai ini untuk uji ulang dari awal.',
      actionText: 'Hapus data',
      danger: true,
    );
    if (!ok) return;

    if (!mounted) return;
    setState(() {
      _isProcessing = true;
      _pullProgressTitle = 'Menghapus data order + finance';
      _pullProgressLines
        ..clear()
        ..add('Scope: $scope')
        ..add('Mapping SKU lokal tetap aman.');
      _errorMessage = null;
    });

    try {
      final result = await _service.resetMarketplaceOrderFinanceData(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
      );
      await _loadOrders(showLoader: false);
      if (!mounted) return;
      setState(() {
        _pullProgressLines
          ..add('Order terhapus: ${_asInt(result['orders_deleted'])}')
          ..add('Item order terhapus: ${_asInt(result['order_items_deleted'])}')
          ..add(
              'Finance report terhapus: ${_asInt(result['finance_reports_deleted'])}')
          ..add(
              'Finance item terhapus: ${_asInt(result['finance_items_deleted'])}');
      });
      AppUi.safeSnack(
        context,
        'Order + finance berhasil dihapus. Order: ${_asInt(result['orders_deleted'])}, item: ${_asInt(result['order_items_deleted'])}, finance report: ${_asInt(result['finance_reports_deleted'])}. Mapping SKU aman.',
      );
    } catch (error) {
      if (!mounted) return;
      final message = _cleanError(error);
      setState(() => _errorMessage = message);
      AppUi.safeSnack(context, 'Gagal hapus order + finance: $message');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String actionText,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
                onPressed: () => AppUi.safePop(context, false),
                child: Text('Batal')),
            FilledButton(
              style: danger
                  ? FilledButton.styleFrom(
                      backgroundColor: (Theme.of(context).colorScheme).error,
                      foregroundColor: (Theme.of(context).colorScheme).onError,
                    )
                  : null,
              onPressed: () => AppUi.safePop(context, true),
              child: Text(actionText),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _isPulling || _isProcessing;
    final orderJobActive =
        _pullProgressFromServerActive || (_orderJobDigest?.hasActive ?? false);
    final pullDisabled = disabled || orderJobActive;

    return WebResponsiveScaffold(
      title: 'Order Marketplace',
      actions: [
        if (_canDeleteBusinessData)
          IconButton(
            onPressed: disabled ? null : _clearOrderFinanceData,
            icon: Icon(Icons.delete_sweep_outlined),
            tooltip: 'Hapus order + finance untuk uji ulang',
          ),
        IconButton(
          onPressed: disabled ? null : _openRefundMonitor,
          icon: Icon(Icons.assignment_return_outlined),
          tooltip: 'Refund/Cancel Monitor',
        ),
        IconButton(
          onPressed: disabled ? null : _loadInitial,
          icon: Icon(Icons.refresh_rounded),
          tooltip: 'Refresh',
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Ambil order marketplace di sini. Scan resi dan produk dari menu Stok Keluar sebelum stok dikurangi.',
              style: (Theme.of(context).textTheme).bodyMedium,
            ),
            SizedBox(height: 12),
            _summaryChips(),
            SizedBox(height: 14),
            _filterBox(),
            SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: pullDisabled ? null : _pullOrders,
                    icon: _isPulling
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.cloud_download_outlined),
                    label: Text(_isPulling
                        ? 'Memulai...'
                        : orderJobActive
                            ? 'Order Sedang Diproses'
                            : 'Ambil Order Hari Ini'),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: disabled ? null : _reserveSiapOrders,
                    icon: _isProcessing
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.inventory_2_outlined),
                    label: Text('Reserve Siap'),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10),
            _serverAutoPullControl(disabled),
            SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: disabled ? null : _openRefundMonitor,
              icon: Icon(Icons.assignment_return_outlined),
              label: Text('Refund / Cancel Monitor'),
            ),
            _pullProgressCard(),
            SizedBox(height: 16),
            if (_errorMessage != null) _errorBox(_errorMessage!),
            if (_isLoading)
              Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_orders.isEmpty)
              _emptyBox(
                  'Belum ada order sesuai filter. Pilih akun, pilih periode hari, lalu tekan Ambil Order Hari Ini.')
            else ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Menampilkan ${_orders.length} order sesuai filter. Data dimuat bertahap agar aplikasi tetap ringan.',
                  style: (Theme.of(context).textTheme).bodySmall,
                ),
              ),
              ..._orders.map(_orderCard),
              if (_hasMoreOrders)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: OutlinedButton.icon(
                    onPressed: _isLoadingMoreOrders ? null : _loadMoreOrders,
                    icon: _isLoadingMoreOrders
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.expand_more_rounded),
                    label: Text(_isLoadingMoreOrders
                        ? 'Memuat...'
                        : 'Muat 300 order berikutnya'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _serverAutoPullControl(bool disabled) {
    final setting = _autoPullSetting;
    final enabled = setting?.enabled ?? false;
    final interval = setting?.intervalMinutes ?? 10;
    final busy = _isLoadingAutoPullSetting || _isSavingAutoPullSetting;
    final jobDigest = _orderJobDigest;
    final settingUpdatedAt = setting?.lastAutoRunAt ?? setting?.updatedAt;
    final jobUpdatedAt = jobDigest?.latestUpdatedAt;
    final latestUpdatedAt = _orderDispatcherLastSuccessAt ??
        (jobUpdatedAt != null &&
                (settingUpdatedAt == null ||
                    jobUpdatedAt.isAfter(settingUpdatedAt))
            ? jobUpdatedAt
            : settingUpdatedAt);
    final updatedText = latestUpdatedAt == null
        ? 'Last order pull: -'
        : 'Last order pull: ${_dateTimeWib(latestUpdatedAt)}';
    final jobSummary = jobDigest == null
        ? null
        : 'Antrean: menunggu ${jobDigest.pending}, berjalan ${jobDigest.running}, selesai ${jobDigest.done}, gagal ${jobDigest.failed}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
                Theme.of(context).brightness == Brightness.dark ? 0.3 : 0.5,
              ),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.cloud_sync_rounded : Icons.sync_disabled_rounded,
            color: enabled
                ? (Theme.of(context).colorScheme).primary
                : (Theme.of(context).colorScheme).onSurfaceVariant,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Auto Pull Order',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                SizedBox(height: 2),
                Text(
                  _autoPullSettingWarning != null
                      ? 'Setting belum siap: $_autoPullSettingWarning'
                      : enabled
                          ? 'Aktif. Order diperbarui otomatis setiap $interval menit.${jobSummary == null ? '' : '\n$jobSummary'}'
                          : 'Nonaktif. Order hanya diambil manual.',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: (Theme.of(context).textTheme).bodySmall,
                ),
                SizedBox(height: 2),
                Text(
                  updatedText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (Theme.of(context).textTheme).bodySmall?.copyWith(
                      color: (Theme.of(context).colorScheme).onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (busy) ...[
            SizedBox(width: 8),
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ] else
            Switch(
              value: enabled,
              onChanged: disabled ? null : _setOrderAutoPullEnabled,
            ),
        ],
      ),
    );
  }

  Widget _summaryChips() {
    final total = _orders.length;
    final ready = _orders.where((item) => item.canProcessStockOut).length;
    final reserved =
        _orders.where((item) => item.stockActionStatus == 'reserved').length;
    final scanned = _orders
        .where((item) => item.stockActionStatus == 'scanned_done')
        .length;
    final review = _orders.where((item) => item.needsReturnReview).length;
    final done = _orders.where((item) => item.isDone).length;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _statChip('Total', total.toString(), Icons.receipt_long_outlined),
        _statChip('Siap', ready.toString(), Icons.inventory_2_outlined),
        _statChip(
            'Disiapkan', reserved.toString(), Icons.bookmark_added_outlined),
        _statChip('Scanned', scanned.toString(), Icons.qr_code_scanner_rounded),
        _statChip(
            'Review', review.toString(), Icons.assignment_return_outlined),
        _statChip('Done', done.toString(), Icons.check_circle_outline_rounded),
      ],
    );
  }

  Widget _filterBox() {
    // 1. Guard marketplace filter value
    final activeMarketplaces =
        MarketplaceProviders.active.map((p) => p.id).toSet();
    if (_filterMarketplace != 'all' &&
        !activeMarketplaces.contains(_filterMarketplace)) {
      _filterMarketplace = 'all';
    }

    // 2. Deduplicate accounts list and guard account filter value
    final uniqueAccountsMap = <String, MarketplaceAccountPublic>{};
    for (final account in _filteredAccounts) {
      final key = account.marketplaceAccountId.trim();
      if (key.isNotEmpty) {
        uniqueAccountsMap.putIfAbsent(key, () => account);
      }
    }
    final accounts = uniqueAccountsMap.values.toList();
    final matchedAccountCount = accounts
        .where((item) => item.marketplaceAccountId == _filterAccountId)
        .length;
    if (_filterAccountId != 'all' && matchedAccountCount != 1) {
      _filterAccountId = 'all';
    }

    // 3. Guard status filter value
    final validStatuses = _statuses.map((item) => item.key).toSet();
    if (!validStatuses.contains(_filterStatus)) {
      _filterStatus = _statuses.isNotEmpty ? _statuses.first.key : 'all';
    }

    return Column(
      children: [
        DropdownButtonFormField<String>(
          value: _filterMarketplace,
          decoration: const InputDecoration(
              labelText: 'Marketplace', border: OutlineInputBorder()),
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
              _rememberFilters();
            });
            _loadOrders();
          },
        ),
        SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _filterAccountId,
          decoration: const InputDecoration(
              labelText: 'Marketplace Account', border: OutlineInputBorder()),
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
            setState(() {
              _filterAccountId = value;
              _rememberFilters();
            });
            _loadOrders();
          },
        ),
        SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _filterStatus,
          decoration: const InputDecoration(
              labelText: 'Status', border: OutlineInputBorder()),
          items: _statuses
              .map((item) =>
                  DropdownMenuItem(value: item.key, child: Text(item.value)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _filterStatus = value;
              _rememberFilters();
            });
            _loadOrders();
          },
        ),
        SizedBox(height: 10),
        _dateRangePickerField(
          label: 'Periode Penarikan',
          startDate: _pullStartDate,
          endDate: _pullEndDate,
          onTap: _pickPullDateRange,
        ),
        SizedBox(height: 10),
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            labelText: 'Search order / buyer / recipient',
            border: const OutlineInputBorder(),
            prefixIcon: Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              onPressed: () {
                _searchController.clear();
                _loadOrders();
              },
              icon: Icon(Icons.clear_rounded),
            ),
          ),
          onSubmitted: (_) => _loadOrders(),
        ),
      ],
    );
  }

  Widget _orderCard(MarketplaceOrderSummary order) {
    final hasPendingReview = order.hasPendingReturnReview;
    final color = hasPendingReview
        ? (Theme.of(context).colorScheme).error
        : _statusColor(order.stockActionStatus);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NiceCard(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: AppTheme.radiusMd,
          onTap: () => _openDetail(order),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        order.externalOrderId,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    _statusBadge(
                        hasPendingReview
                            ? order.reviewBadgeLabel
                            : order.stockActionLabel,
                        color),
                  ],
                ),
                SizedBox(height: 8),
                Text('${order.marketplace} · ${order.accountName}'),
                SizedBox(height: 4),
                Text(
                    'Order: ${order.orderStatusLabel} · ${order.orderTimeText}'),
                if (order.hasCancelRequest) ...[
                  SizedBox(height: 6),
                  _warningBox(
                    'Cancel request',
                    order.cancelRequestSummary,
                    compact: true,
                  ),
                ],
                if (order.hasPendingReturnReview) ...[
                  SizedBox(height: 6),
                  _warningBox(
                    'Perlu cek refund/cancel',
                    order.pendingReturnReviewSummary,
                    compact: true,
                  ),
                ],
                if (order.resiText != '-') ...[
                  SizedBox(height: 4),
                  Text('Resi: ${order.resiText}'),
                ],
                SizedBox(height: 4),
                Text(
                    'Item: ${order.itemCount} · Qty: ${order.qtyTotal.toStringAsFixed(0)} · Mapping: ${order.mappedItemCount} · Belum Mapping: ${order.unmappedItemCount}'),
                if (order.reservedItemCount > 0 ||
                    order.scannedDoneItemCount > 0) ...[
                  SizedBox(height: 4),
                  Text(
                      'Disiapkan item: ${order.reservedItemCount} · Selesai scan: ${order.scannedDoneItemCount}'),
                ],
                if ((order.lastError ?? '').trim().isNotEmpty) ...[
                  SizedBox(height: 6),
                  Text(order.lastError!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: (Theme.of(context).colorScheme).error)),
                ],
                SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                        onPressed: () => _openDetail(order),
                        icon: Icon(Icons.info_outline_rounded),
                        label: Text('Detail')),
                    if (order.canProcessStockOut)
                      FilledButton.tonalIcon(
                        onPressed:
                            _isProcessing ? null : () => _reserveOne(order),
                        icon: Icon(Icons.inventory_2_outlined),
                        label: Text('Reserve'),
                      ),
                    if (order.canOpenPickScan || order.canFinalizeStockOut)
                      FilledButton.tonalIcon(
                        onPressed: _isProcessing ? null : _openStockOut,
                        icon: Icon(Icons.output_outlined),
                        label: Text('Stock Out'),
                      ),
                    if (order.needsReturnReview)
                      OutlinedButton.icon(
                        onPressed: _openRefundMonitor,
                        icon: Icon(Icons.assignment_return_outlined),
                        label: Text('Review'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _itemCard(MarketplaceOrderItem item) {
    final color = item.isMapped
        ? Colors.green.shade700
        : (Theme.of(context).colorScheme).error;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
                Theme.of(context).brightness == Brightness.dark ? 0.3 : 0.5,
              ),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(item.productName,
                      style: TextStyle(fontWeight: FontWeight.w800))),
              _statusBadge(item.mappingLabel, color),
            ],
          ),
          SizedBox(height: 6),
          Text('Variant: ${item.variantName}'),
          Text('Seller SKU: ${item.sellerSku}'),
          Text('Marketplace SKU ID: ${item.marketplaceSkuId}'),
          Text('Qty order: ${item.qtyText}'),
          Text('Local SKU: ${item.mappedLocalSku}'),
          Text('Barcode lokal: ${item.localBarcode}'),
          Text(
              'Disiapkan: ${item.reserveText} · Scanned: ${item.scanProgressText}'),
          Text(
              'Stok lokal: ${item.localStock.toStringAsFixed(0)} · Tersedia: ${item.availableStockText}'),
          Text('Pick status: ${item.stockActionLabel}'),
          if ((item.lastError ?? '').trim().isNotEmpty) ...[
            SizedBox(height: 6),
            Text(item.lastError!,
                style: TextStyle(color: (Theme.of(context).colorScheme).error)),
          ],
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: (Theme.of(context).colorScheme).surfaceVariant.withOpacity(0.65),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          SizedBox(width: 8),
          Text('$label: ', style: TextStyle(fontWeight: FontWeight.w700)),
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
        border: Border.all(color: color.withOpacity(0.22), width: 0.8),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }

  Color _statusColor(String status) {
    final scheme = (Theme.of(context).colorScheme);
    switch (status) {
      case 'ready_to_pick':
      case 'ready_stock_out':
        return scheme.primary;
      case 'reserved':
      case 'partial_scanned':
        return Colors.blue.shade700;
      case 'scanned_done':
        return Colors.teal.shade700;
      case 'stock_out_done':
      case 'return_review_done':
      case 'cancelled_released':
        return Colors.green.shade700;
      case 'unmapped':
      case 'stock_out_failed':
      case 'reserve_failed':
      case 'insufficient_stock':
      case 'return_review_required':
      case 'cancel_review_required':
        return scheme.error;
      case 'ignored_status':
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
              width: 120,
              child:
                  Text(label, style: TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  Widget _warningBox(String title, String message, {bool compact = false}) {
    final color = Colors.orange.shade800;
    return Container(
      margin: EdgeInsets.only(bottom: compact ? 2 : 10),
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withOpacity(0.10),
        border: Border.all(color: color.withOpacity(0.22), width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.report_problem_outlined,
              color: color, size: compact ? 18 : 20),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w800)),
                if (message.trim().isNotEmpty) ...[
                  SizedBox(height: 3),
                  Text(
                    message,
                    maxLines: compact ? 2 : null,
                    overflow:
                        compact ? TextOverflow.ellipsis : TextOverflow.visible,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBox(String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: (Theme.of(context).colorScheme).errorContainer),
      child: Text(text,
          style: TextStyle(
              color: (Theme.of(context).colorScheme).onErrorContainer)),
    );
  }

  Widget _emptyBox(String text) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
                  Theme.of(context).brightness == Brightness.dark ? 0.3 : 0.5,
                ),
            width: 0.8,
          )),
      child: Text(text),
    );
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _cleanError(Object error) {
    var text = error.toString().trim();
    final lower = text.toLowerCase();
    if (lower.contains('failed host lookup') ||
        lower.contains('socketexception') ||
        lower.contains('no address associated with hostname')) {
      return 'Koneksi ke Supabase gagal. Cek internet/DNS/VPN, lalu coba lagi. Ini gagal konek dari perangkat, bukan data order rusak.';
    }
    text = text.replaceFirst(RegExp(r'^Exception:\s*'), '');
    return text;
  }
}
