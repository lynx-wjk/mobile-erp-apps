import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/app_roles.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../../../core/utils/file_download.dart';
import '../services/finance_local_cache.dart';

class FinanceReportPage extends StatefulWidget {
  final int initialTabIndex;

  const FinanceReportPage({
    super.key,
    this.initialTabIndex = 0,
  });

  @override
  State<FinanceReportPage> createState() => _FinanceReportPageState();
}

class _FinanceReportPageState extends State<FinanceReportPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _loading = true;
  bool _processing = false;
  bool _skuLoaded = false;
  bool _skuLoadingFirstPage = false;
  bool _isSyncingHpp = false;
  bool _sampleFreeLoaded = false;
  bool _sampleFreeLoading = false;
  String? _sampleFreeError;
  bool _operationalCostsLoaded = false;
  bool _operationalCostsLoading = false;
  String? _operationalCostsError;
  bool _profitLossLoaded = false;
  bool _profitLossLoading = false;
  String? _profitLossError;
  bool _financeAutoSyncEnabled = false;
  bool _financeAutoSyncBusy = false;
  bool _filterExpanded = false;
  String _financeAutoSyncMessage = '';
  DateTime? _financeAutoSyncLastRunAt;
  static String _cachedProgressTitle = '';
  static final List<String> _cachedProgressLines = <String>[];

  String _progressTitle = _cachedProgressTitle;
  final List<String> _progressLines = List<String>.from(_cachedProgressLines);
  String _abnormalStatusFilter = 'all';
  final TextEditingController _abnormalSearchController =
      TextEditingController();
  List<Map<String, dynamic>> _serverAbnormales = [];
  bool _abnormalServerLoaded = false;
  bool _abnormalSearchBusy = false;
  String? _abnormalLoadError;
  int _abnormalPage = 1;
  int _abnormalTotal = 0;
  static const int _abnormalPageSize = 20;
  String? _error;
  String _currentRoleId = '';
  String _currentTenantId = '';
  String _currentUserId = '';
  String _currentUserName = '';
  String _currentUserEmail = '';
  String _lastSnapshotStats = '';
  static const bool _enableSkuDebugLogs = false;
  String _lastSkuDebugProof = '';
  String _marketplaceFinanceGapMessage = '';
  int _lastSkuRpcRowCount = 0;
  int _lastSkuParsedRowCount = 0;
  int _lastSkuMergedRowCount = 0;
  int _lastSkuRenderedRowCount = 0;
  Map<String, dynamic> _marketplaceBootstrapUiStatus =
      const <String, dynamic>{};
  Map<String, dynamic> _dispatcherSnapshot = const <String, dynamic>{};
  int _financeLoadSerial = 0;
  final Map<String, Future<dynamic>> _activeFinanceRequests = {};
  final Map<String, dynamic> _financeLoadCache = {};
  Map<String, dynamic> _skuPayoutCountSummaryMap = {};

  bool _isCurrentFilter(
      String startKey, String endKey, String mktKey, String accKey) {
    return mounted &&
        _toDateParam(_start) == startKey &&
        _toDateParam(_end) == endKey &&
        (_normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all') == mktKey &&
        _accountFilter == accKey;
  }

  bool _sampleFreeDetailsLoaded = false;
  bool _sampleFreeDetailsLoading = false;
  String? _sampleFreeDetailsError;
  final Set<String> _expandedReconciliations = {};
  static const String _financeCacheVersion =
      'finance_live_20260727_v56_timeout_90s';
  static const List<String> _financeCacheVersionFallbacks = <String>[
    _financeCacheVersion,
  ];

  bool get _isDemoSuperAdmin =>
      AppRolePermissions.isDemoSuperAdminId(_currentRoleId);
  bool get _canAccessFinance =>
      AppRolePermissions.canAccessFinance(_currentRoleId);
  bool get _canWriteFinance =>
      _canAccessFinance &&
      !_isDemoSuperAdmin &&
      _currentTenantId.trim().isNotEmpty;

  static DateTime? _savedStartDate;
  static DateTime? _savedEndDate;
  static String? _savedMarketplaceFilter;
  static String? _savedAccountFilter;

  DateTime _start =
      _savedStartDate ?? DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _end = _savedEndDate ?? DateTime.now();
  String _marketplaceFilter = _savedMarketplaceFilter ?? 'all';
  String _accountFilter = _savedAccountFilter ?? 'all';

  Map<String, dynamic> _summary = {};
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _sources = [];
  List<Map<String, dynamic>> _approvedPurchases = [];
  List<Map<String, dynamic>> _byMarketplace = [];
  List<Map<String, dynamic>> _bySku = [];
  int _skuPage = 1;
  int _skuServerPageLoaded = 1;
  bool _skuHasMoreServerRows = true;
  bool _skuLoadingMore = false;
  int _skuServerTotalPages = 1;
  int _skuServerTotalCount = 0;
  static const int _skuPageSize = 100;
  static const int _skuDetailPageSize = 25;
  String? _skuDetailBusyKey;
  final Map<String, int> _skuUnpaidCountMap = {};
  final Map<String, int> _skuPaidCountMap = {};
  final Map<String, int> _skuReturnedCountMap = {};
  List<Map<String, dynamic>> _cashFlow = [];
  List<Map<String, dynamic>> _cashOpeningBalances = [];
  List<Map<String, dynamic>> _cashAdjustments = [];
  List<Map<String, dynamic>> _marketplaceWithdrawals = [];
  List<Map<String, dynamic>> _withdrawalAllocations = [];
  List<Map<String, dynamic>> _expenses = [];
  List<Map<String, dynamic>> _profitLoss = [];
  List<Map<String, dynamic>> _profitLossByMarketplace = [];
  List<Map<String, dynamic>> _abnormals = [];
  List<Map<String, dynamic>> _sampleFreeOrders = [];

  static const List<String> _baseExpenseCategories = [
    'Salary',
    'Utilitas',
    'Operasional',
    'Ongkos Produksi',
  ];
  List<String> _expenseCategoryOptions =
      List<String>.from(_baseExpenseCategories);

  void _rememberFilters() {
    _savedStartDate = DateTime(_start.year, _start.month, _start.day);
    _savedEndDate = DateTime(_end.year, _end.month, _end.day, 23, 59, 59);
    _savedMarketplaceFilter = _marketplaceFilter;
    _savedAccountFilter = _accountFilter;
  }

  void _normalizeCurrentFinanceFilters() {
    _marketplaceFilter =
        _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
    if (_accountFilter != 'all' && !_isUuid(_accountFilter)) {
      _accountFilter = 'all';
    }
    _rememberFilters();
  }

  @override
  void initState() {
    super.initState();
    _normalizeCurrentFinanceFilters();
    _load();
  }

  @override
  void dispose() {
    _abnormalSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentRole() async {
    try {
      final authUser = _client.auth.currentUser;
      if (authUser == null) return;
      _currentUserId = authUser.id;
      final user = await _client
          .from('users')
          .select('role_id, tenant_id, nama, email')
          .eq('user_id', authUser.id)
          .maybeSingle();
      if (!mounted) return;
      _currentRoleId = user?['role_id']?.toString() ?? '';
      _currentTenantId = user?['tenant_id']?.toString() ?? '';
      _currentUserName = user?['nama']?.toString() ?? '';
      _currentUserEmail = user?['email']?.toString() ?? authUser.email ?? '';
    } catch (_) {
      _currentRoleId = '';
      _currentTenantId = '';
      _currentUserId = '';
      _currentUserName = '';
      _currentUserEmail = '';
    }
  }

  void _showDemoBlocked() {
    AppUi.safeSnack(context,
        'Mode demo hanya bisa melihat laporan. Tambah, edit, hapus, dan simpan dikunci.');
  }

  Future<void> _loadFinanceAutoSyncSetting({bool showError = true}) async {
    if (_currentTenantId.trim().isEmpty) return;
    try {
      final response = await _client.rpc('finance_get_auto_sync_setting');
      if (response is Map) {
        final map = Map<String, dynamic>.from(response);
        if (!mounted) return;
        setState(() {
          _financeAutoSyncEnabled = map['auto_finance_sync_enabled'] == true;
          _financeAutoSyncMessage =
              AppUi.userMessage(_text(map['last_auto_run_message']));
          _financeAutoSyncLastRunAt = _parseDate(map['last_auto_run_at']);
        });
      }
    } catch (e) {
      if (showError && mounted) {
        AppUi.safeSnack(context,
            'Pengaturan auto payout belum siap. Perbarui database lalu buka ulang halaman ini.');
      }
    }
  }

  Future<void> _loadMarketplaceBootstrapUiStatus(
      {bool showError = false}) async {
    try {
      final response = await _client.rpc('marketplace_bootstrap_ui_status');
      if (!mounted) return;
      setState(() {
        _marketplaceBootstrapUiStatus = response is Map
            ? Map<String, dynamic>.from(response)
            : const <String, dynamic>{};
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _marketplaceBootstrapUiStatus = const <String, dynamic>{};
      });
      if (showError) {
        AppUi.safeSnack(
          context,
          'Status sinkron marketplace belum tersedia. Perbarui database lalu buka ulang halaman ini.',
        );
      }
    }
  }

  Future<void> _loadDispatcherSnapshot({bool showError = false}) async {
    if (_currentTenantId.trim().isEmpty) return;
    try {
      final response = await _client
          .rpc('marketplace_dispatcher_pull_state')
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      final snapshot = _asMap(response);
      final orderStates = _asList(snapshot['order_states'])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      final financeStates = _asList(snapshot['finance_states'])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      setState(() {
        _dispatcherSnapshot = <String, dynamic>{
          'order_states': orderStates,
          'finance_states': financeStates,
          'source': snapshot['source'] ?? 'marketplace_dispatcher_pull_state',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _dispatcherSnapshot = const <String, dynamic>{};
      });
      if (showError) {
        AppUi.safeSnack(
          context,
          'Status dispatcher marketplace belum tersedia.',
        );
      }
    }
  }

  DateTime? _maxDate(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b.isAfter(a) ? b : a;
  }

  DateTime? _parseServerInstant(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    final raw = value.toString().trim();
    if (raw.isEmpty || raw == '-') return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    final hasExplicitZone =
        RegExp(r'(z|[+-]\d{2}(:?\d{2})?)$', caseSensitive: false).hasMatch(raw);
    if (hasExplicitZone) return parsed.toUtc();
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }

  DateTime? _latestDispatcherTimestamp(
    String listKey,
    List<String> fields,
  ) {
    DateTime? latest;
    for (final row in _asList(_dispatcherSnapshot[listKey])) {
      for (final field in fields) {
        latest = _maxDate(latest, _parseServerInstant(row[field]));
      }
    }
    return latest;
  }

  String _syncTimestampText(DateTime? value) {
    if (value == null) return 'Belum tersedia';
    final rawDiff = DateTime.now().toUtc().difference(value.toUtc());
    final diff = rawDiff.isNegative ? Duration.zero : rawDiff;
    String relative;
    if (diff.inMinutes < 1) {
      relative = 'baru saja';
    } else if (diff.inHours < 1) {
      relative = '${diff.inMinutes} menit lalu';
    } else if (diff.inDays < 1) {
      relative = '${diff.inHours} jam lalu';
    } else {
      relative = '${diff.inDays} hari lalu';
    }
    return '${_dateTime(value)} ($relative)';
  }

  Future<void> _setFinanceAutoSyncEnabled(bool enabled) async {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return;
    }
    if (_financeAutoSyncBusy) return;
    if (!mounted) return;
    setState(() {
      _financeAutoSyncBusy = true;
      _financeAutoSyncEnabled = enabled;
    });
    try {
      final response = await _client.rpc(
        'finance_set_auto_sync_enabled',
        params: {
          'p_enabled': enabled,
          'p_interval_minutes': 10,
        },
      );
      if (response is Map) {
        final map = Map<String, dynamic>.from(response);
        if (!mounted) return;
        setState(() {
          _financeAutoSyncEnabled = map['auto_finance_sync_enabled'] == true;
          _financeAutoSyncMessage =
              AppUi.userMessage(_text(map['last_auto_run_message']));
          _financeAutoSyncLastRunAt = _parseDate(map['last_auto_run_at']);
        });
      }
      if (mounted) {
        AppUi.safeSnack(
            context, enabled ? 'Auto payout aktif.' : 'Auto payout dimatikan.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _financeAutoSyncEnabled = !enabled);
        AppUi.safeSnack(
            context, 'Gagal mengubah pengaturan: ${_cleanError(e)}');
      }
    } finally {
      if (mounted) setState(() => _financeAutoSyncBusy = false);
    }
  }

  Future<dynamic> _loadFinanceSnapshot(Map<String, dynamic> baseParams) async {
    dynamic normalizeAccount(dynamic value) {
      final text = value?.toString().trim();
      if (text == null ||
          text.isEmpty ||
          text == '-' ||
          text.toLowerCase() == 'all') {
        return null;
      }
      return value;
    }

    String? normalizeMarketplace(dynamic value) {
      final text = value?.toString().trim();
      if (text == null ||
          text.isEmpty ||
          text == '-' ||
          text.toLowerCase() == 'all') {
        return null;
      }
      return text;
    }

    final params = <String, dynamic>{
      'p_start': baseParams['p_start'] ??
          baseParams['p_start_date'] ??
          _toDateParam(_start),
      'p_end':
          baseParams['p_end'] ?? baseParams['p_end_date'] ?? _toDateParam(_end),
      'p_marketplace': normalizeMarketplace(
        baseParams['p_marketplace'] ?? baseParams['p_marketplace_filter'],
      ),
      'p_account_id': normalizeAccount(
        baseParams['p_account_id'] ?? baseParams['p_account_id_filter'],
      ),
    };

    final candidates = <String>[
      'finance_dashboard_snapshot',
    ];

    Object? lastError;
    dynamic firstEmptyResponse;

    for (final rpcName in candidates) {
      final safeRpcName = rpcName.trim();
      if (safeRpcName.isEmpty) continue;

      try {
        final response = await _client
            .rpc(safeRpcName, params: params)
            .timeout(const Duration(seconds: 90));
        final enrichedResponse = response;
        _lastSnapshotStats =
            '$safeRpcName · ${_snapshotStats(enrichedResponse)}';

        if (!_isFinanceSnapshotEmpty(enrichedResponse) &&
            !_isLegacySkuOnlySnapshot(enrichedResponse)) {
          return enrichedResponse;
        }

        firstEmptyResponse ??= enrichedResponse;
      } catch (e) {
        lastError = e;
        debugPrint('FINANCE_SNAPSHOT_RPC_FAILED $safeRpcName: $e');
      }
    }

    if (firstEmptyResponse != null) {
      return firstEmptyResponse;
    }

    // Removed fallback month-to-date query to respect dynamic selected range

    if (lastError != null) {
      throw lastError;
    }

    throw Exception('Belum ada data pada filter ini.');
  }

  Future<dynamic> _buildFallbackFinanceSnapshot(
      Map<String, dynamic> params) async {
    final mktFilter = params['p_marketplace']?.toString().trim().toLowerCase();

    try {
      final accountsResponse = await _client
          .from('marketplace_accounts')
          .select(
              'marketplace_account_id, tenant_id, marketplace, store_alias, shop_name, status, is_active')
          .eq('tenant_id', _currentTenantId);
      final accountsList = accountsResponse is List
          ? accountsResponse.map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];

      final dashboard = await _client.rpc(
        'dashboard_marketplace_order_analytics_90d',
        params: {
          'p_marketplace':
              (mktFilter == null || mktFilter.isEmpty) ? null : mktFilter,
          'p_days': 20,
        },
      ).timeout(const Duration(seconds: 5));
      final dashboardMap = _asMap(dashboard);
      final summary = _asMap(dashboardMap['summary']);

      return <String, dynamic>{
        'source': 'finance_dashboard_snapshot_fallback',
        'source_table': 'dashboard_marketplace_order_analytics_90d',
        'daily': dashboardMap['daily'] ?? const <dynamic>[],
        'by_marketplace': dashboardMap['by_marketplace'] ?? const <dynamic>[],
        'accounts': accountsList,
        'summary': summary,
        'abnormal_aggregates': <String, dynamic>{
          'abnormal_count': summary['abnormal_count'] ?? 0,
          'negative_payout_total_abs':
              summary['negative_payout_total_abs'] ?? 0,
        },
        'expenses': const <dynamic>[],
        'approved_purchases': const <dynamic>[],
        'skus': const <dynamic>[],
        'sku_rows': const <dynamic>[],
      };
    } catch (e) {
      debugPrint('Finance snapshot fallback query failed: $e');
      return null;
    }
  }

  Future<dynamic> _withMarketplaceReconciliation(
    dynamic response,
    Map<String, dynamic> params,
  ) async {
    return response;
  }

  List<Map<String, dynamic>> _snapshotParamVariantsForRpc(
      String rpcName, Map<String, dynamic> params) {
    final out = Map<String, dynamic>.from(params)..remove('p_store_name');
    if (rpcName == '') {
      return [
        {
          'p_start': out['p_start'],
          'p_end': out['p_end'],
          'p_marketplace': out['p_marketplace'],
          'p_account_id': out['p_account_id'],
        },
        {
          'p_start_date': out['p_start'],
          'p_end_date': out['p_end'],
          'p_marketplace_filter': out['p_marketplace'],
          'p_account_id_filter': out['p_account_id'],
        },
      ];
    }
    return [out];
  }

  bool _isRpcParamMismatch(Object e) {
    final lower = e.toString().toLowerCase();
    return lower.contains('could not find the function') ||
        lower.contains('function public.') ||
        lower.contains('does not exist') ||
        lower.contains('pgrst202') ||
        lower.contains('pgrst204') ||
        lower.contains('pgrst301');
  }

  String _financeSnapshotLocalKey() {
    return _financeSnapshotLocalKeys().first;
  }

  List<String> _financeSnapshotLocalKeys() {
    return _financeCacheVersionFallbacks
        .map((version) => FinanceLocalCache.snapshotKey(
              start: _start,
              end: _end,
              marketplace: _marketplaceFilter,
              accountId: _accountFilter,
              tenantId: _currentTenantId.trim().isEmpty
                  ? 'unknown'
                  : _currentTenantId,
              tab: 'dashboard',
              page: 1,
              cacheVersion: version,
            ))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>?> _readFinanceSnapshotLocalAny() async {
    for (final key in _financeSnapshotLocalKeys()) {
      final cached = await FinanceLocalCache.readJson(key, ttlDays: 2);
      if (cached != null && !_isFinanceSnapshotEmpty(cached)) return cached;
    }
    return null;
  }

  Future<void> _refreshFinanceCacheForSelectedPeriod() async {
    _financeLoadCache.clear();
    _activeFinanceRequests.clear();
    _operationalCostsLoaded = false;
    _operationalCostsLoading = false;
    await _clearFinanceLocalCacheForSelectedPeriod();
    try {
      await _client.rpc('finance_fix_exact_cache_settled_hpp', params: {
        'p_start': _toDateParam(_start),
        'p_end': _toDateParam(_end),
        'p_marketplace': _marketplaceParam() ?? 'all',
        'p_account_id': _accountUuidParam(),
      });
    } catch (_) {
      // Cache exact bisa belum ada. Reader tetap mengambil latest cache / live overlay dari SQL.
    }
  }

  Future<void> _clearFinanceLocalCacheForSelectedPeriod() async {
    for (final key in _financeSnapshotLocalKeys()) {
      await FinanceLocalCache.remove(key);
    }
  }

  String _skuDebugPeriodLabel() {
    final marketplace = _marketplaceRpcParam() ?? 'all';
    final account = _accountUuidParam() ?? 'all';
    return '${_toDateParam(_start)}..${_toDateParam(_end)}'
        ' marketplace=$marketplace account=$account';
  }

  int _skuRenderedCountForRows(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return 0;
    final safePage = _skuPage < 1 ? 1 : _skuPage;
    final start = (safePage - 1) * _skuPageSize;
    if (start >= rows.length) return 0;
    final end = (start + _skuPageSize) > rows.length
        ? rows.length
        : start + _skuPageSize;
    return end - start;
  }

  void _recordSkuRenderProof({
    required String source,
    required String payoutFilter,
    required int rpcRowCount,
    required int parsedRowCount,
    required int filteredRowCount,
    required int normalizedRowCount,
    required int mergedRowCount,
    required int renderedRowCount,
  }) {
    final proof = 'period=${_skuDebugPeriodLabel()} '
        'source=$source filter=$payoutFilter '
        'rpc=$rpcRowCount parsed=$parsedRowCount filtered=$filteredRowCount '
        'normalized=$normalizedRowCount merged=$mergedRowCount '
        'rendered=$renderedRowCount';
    _lastSkuDebugProof = proof;
    _lastSkuRpcRowCount = rpcRowCount;
    _lastSkuParsedRowCount = parsedRowCount;
    _lastSkuMergedRowCount = mergedRowCount;
    _lastSkuRenderedRowCount = renderedRowCount;
  }

  Future<void> _safeRefreshFinanceView() async {
    // Refresh UI tidak boleh membuang data yang sedang tampil.
    // _load() kadang tidak throw, tapi langsung set _error dan mengosongkan state.
    // Jadi setelah _load selesai pun state tetap harus dicek dan direstore bila perlu.
    final keepSummary = Map<String, dynamic>.from(_summary);
    final keepSources = List<Map<String, dynamic>>.from(_sources);
    final keepApprovedPurchases =
        List<Map<String, dynamic>>.from(_approvedPurchases);
    final keepByMarketplace = List<Map<String, dynamic>>.from(_byMarketplace);
    final keepBySku = List<Map<String, dynamic>>.from(_bySku);
    final keepCashFlow = List<Map<String, dynamic>>.from(_cashFlow);
    final keepExpenses = List<Map<String, dynamic>>.from(_expenses);
    final keepProfitLoss = List<Map<String, dynamic>>.from(_profitLoss);
    final keepAbnormals = List<Map<String, dynamic>>.from(_abnormals);
    final keepServerAbnormales =
        List<Map<String, dynamic>>.from(_serverAbnormales);
    final keepError = _error;

    final hadVisibleData = keepSummary.isNotEmpty ||
        keepSources.isNotEmpty ||
        keepByMarketplace.isNotEmpty ||
        keepBySku.isNotEmpty ||
        keepCashFlow.isNotEmpty ||
        keepExpenses.isNotEmpty ||
        keepProfitLoss.isNotEmpty ||
        keepAbnormals.isNotEmpty ||
        keepServerAbnormales.isNotEmpty;

    var restored = false;

    try {
      await _load(ignoreLocalCache: true);
    } catch (_) {
      restored = true;
    }

    if (!mounted) return;

    final nowHasVisibleData = _summary.isNotEmpty ||
        _sources.isNotEmpty ||
        _byMarketplace.isNotEmpty ||
        _bySku.isNotEmpty ||
        _cashFlow.isNotEmpty ||
        _expenses.isNotEmpty ||
        _profitLoss.isNotEmpty ||
        _abnormals.isNotEmpty ||
        _serverAbnormales.isNotEmpty;

    final nowHasError = _text(_error, '').trim().isNotEmpty;

    if (hadVisibleData && (restored || nowHasError || !nowHasVisibleData)) {
      setState(() {
        _summary = keepSummary;
        _sources = keepSources;
        _approvedPurchases = keepApprovedPurchases;
        _byMarketplace = keepByMarketplace;
        _bySku = keepBySku;
        _skuHasMoreServerRows = false;
        _skuLoadingMore = false;
        _cashFlow = keepCashFlow;
        _expenses = keepExpenses;
        _profitLoss = keepProfitLoss;
        _abnormals = keepAbnormals;
        _serverAbnormales = keepServerAbnormales;
        _error = keepError;
        _loading = false;
      });

      AppUi.safeSnack(
        context,
        'Data terakhir tetap ditampilkan. Refresh server masih diproses otomatis.',
      );
    }
  }

  Future<void> _hardReloadFinanceView() async {
    await _safeRefreshFinanceView();
  }

  bool _isPurchaseExpenseRow(Map<String, dynamic> row) {
    final text =
        '${row['source']} ${row['type']} ${row['category']} ${row['title']} ${row['label']}'
            .toLowerCase();
    return text.contains('purchase') || text.contains('pembelian');
  }

  bool _isSyntheticExpenseRow(Map<String, dynamic> row) {
    final id = _text(row['expense_id'] ?? row['id'], '').toLowerCase();
    final source = _text(row['source'], '').toLowerCase();
    final category = _text(row['category'] ?? row['label'] ?? row['title'], '')
        .toLowerCase();
    return id.startsWith('summary_') ||
        source == 'finance_report' ||
        category.contains('total biaya');
  }

  double _sumAmountRows(List<Map<String, dynamic>> rows) {
    return rows.fold<double>(0, (sum, row) {
      final amount = _purchaseAmount(row);
      return sum + amount.abs();
    });
  }

  bool _isProductionPaymentExpenseRow(Map<String, dynamic> row) {
    final haystack = [
      row['source_table'],
      row['source_module'],
      row['source_ref'],
      row['payment_type'],
      row['payment_method'],
      row['category'],
      row['title'],
      row['label'],
      row['description'],
    ].map((value) => _text(value, '').toLowerCase()).join(' ');
    return haystack.contains('production_tailor_payments') ||
        haystack.contains('ongkos jahit') ||
        haystack.contains('ongkos produksi') ||
        (haystack.contains('production') &&
            (haystack.contains('sewing_payment') ||
                haystack.contains('kasbon') ||
                haystack.contains('penjahit')));
  }

  String _firstStableText(List<dynamic> values) {
    for (final value in values) {
      final text = _text(value, '').trim();
      if (text.isNotEmpty && text != '-') return text;
    }
    return '';
  }

  String _expenseDedupeKey(Map<String, dynamic> row) {
    final sourceId = _firstStableText([
      row['source_id'],
      row['payment_id'],
      row['reference_id'],
      row['source_reference_id'],
      row['adjustment_id'],
      row['cash_adjustment_id'],
    ]);
    if (sourceId.isNotEmpty && _isProductionPaymentExpenseRow(row)) {
      return 'source:production_tailor_payments:${sourceId.toLowerCase()}';
    }

    final sourceTable = _firstStableText([
      row['source_table'],
      row['source_module'],
      row['source'],
    ]);
    if (sourceTable.isNotEmpty && sourceId.isNotEmpty) {
      return 'source:${sourceTable.toLowerCase()}:${sourceId.toLowerCase()}';
    }

    final paymentId = _firstStableText([row['payment_id']]);
    if (paymentId.isNotEmpty) return 'payment:${paymentId.toLowerCase()}';

    final rawId = _firstStableText([
      row['expense_id'],
      row['id'],
      row['finance_operational_expense_id'],
      row['operational_expense_id'],
      row['purchase_id'],
      row['request_id'],
      row['adjustment_id'],
      row['cash_adjustment_id'],
    ]);
    if (rawId.isNotEmpty) return 'id:${rawId.toLowerCase()}';

    return 'row:${identityHashCode(row)}';
  }

  List<String> _productionExpenseAliases(Map<String, dynamic> row) {
    if (!_isProductionPaymentExpenseRow(row)) return const <String>[];
    final aliases = <String>{};

    void add(dynamic value) {
      final clean = _text(value, '').trim().toLowerCase();
      if (clean.isEmpty || clean == '-') return;
      aliases.add('production_expense:$clean');
    }

    add(row['source_id']);
    add(row['payment_id']);
    add(row['production_payment_id']);
    add(row['finance_expense_id']);
    add(row['expense_id']);
    add(row['finance_operational_expense_id']);
    add(row['operational_expense_id']);
    add(row['id']);
    return aliases.toList(growable: false);
  }

  bool _isProductionTailorFallbackExpense(Map<String, dynamic> row) {
    if (!_isProductionPaymentExpenseRow(row)) return false;
    final sourceTable = _text(row['source_table'], '').toLowerCase().trim();
    final paymentType = _text(row['payment_type'], '').toLowerCase().trim();
    final paymentMethod = _text(row['payment_method'], '').toLowerCase().trim();
    return sourceTable == 'production_tailor_payments' &&
        paymentType.isNotEmpty &&
        paymentMethod.isEmpty;
  }

  int _productionExpensePriority(Map<String, dynamic> row) {
    if (!_isProductionPaymentExpenseRow(row)) return 0;
    // The finance operational expense mirror is the canonical finance row.
    // Raw production_tailor_payments is only a fallback when the mirror does not exist.
    if (_isProductionTailorFallbackExpense(row)) return 1;
    if (_firstStableText([
      row['expense_id'],
      row['finance_operational_expense_id'],
      row['operational_expense_id'],
    ]).isNotEmpty) return 3;
    return 2;
  }

  List<Map<String, dynamic>> _dedupeProductionExpenseRows(
      List<Map<String, dynamic>> rows) {
    final out = <Map<String, dynamic>>[];
    final aliasIndex = <String, int>{};
    final seenGeneric = <String>{};

    for (final raw in rows) {
      final row =
          _normalizeProductionExpenseRow(Map<String, dynamic>.from(raw));
      final aliases = _productionExpenseAliases(row);
      if (aliases.isEmpty) {
        final key = _expenseDedupeKey(row);
        if (seenGeneric.add(key)) out.add(row);
        continue;
      }

      int? existingIndex;
      for (final alias in aliases) {
        final index = aliasIndex[alias];
        if (index != null) {
          existingIndex = index;
          break;
        }
      }

      if (existingIndex == null) {
        final index = out.length;
        out.add(row);
        for (final alias in aliases) {
          aliasIndex[alias] = index;
        }
        continue;
      }

      final existing = out[existingIndex];
      if (_productionExpensePriority(row) >
          _productionExpensePriority(existing)) {
        out[existingIndex] = row;
      }
      for (final alias in aliases) {
        aliasIndex[alias] = existingIndex;
      }
    }

    return out;
  }

  List<Map<String, dynamic>> _dedupeByStableKey(
      List<Map<String, dynamic>> rows) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final row in rows) {
      final map =
          _normalizeProductionExpenseRow(Map<String, dynamic>.from(row));
      if (seen.add(_expenseDedupeKey(map))) out.add(map);
    }
    return out;
  }

  Map<String, dynamic> _normalizeProductionExpenseRow(
      Map<String, dynamic> row) {
    if (!_isProductionPaymentExpenseRow(row)) return row;

    final sourceId = _firstStableText([
      row['source_id'],
      row['payment_id'],
      row['reference_id'],
      row['source_reference_id'],
    ]);
    if (sourceId.isNotEmpty) {
      final existingSourceTable = _firstStableText([row['source_table']]);
      if (existingSourceTable.isEmpty) {
        row['source_table'] = 'production_tailor_payments';
      }
      row['source_module'] = 'production';
      row['source_id'] = sourceId;
      row['production_payment_id'] = sourceId;
      row['payment_id'] = _firstStableText([row['payment_id'], sourceId]);
    }
    row['category'] = 'Ongkos Produksi';
    row['title'] = 'Ongkos Produksi';
    row['label'] = 'Ongkos Produksi';
    return row;
  }

  Map<String, dynamic> _productionPaymentExpenseFromRow(
      Map<String, dynamic> row) {
    final paymentId = _text(row['payment_id'], '').trim();
    final financeExpenseId = _text(row['finance_expense_id'], '').trim();
    final expenseId = _isUuid(financeExpenseId)
        ? financeExpenseId
        : 'production_tailor_payment:$paymentId';

    return _normalizeProductionExpenseRow(<String, dynamic>{
      ...row,
      'expense_id': expenseId,
      'payment_id': paymentId,
      'source_table': 'production_tailor_payments',
      'source_module': 'production',
      'source_id': paymentId,
      'source_ref': row['payment_type'],
      'expense_date': row['payment_date'],
      'paid_at': row['payment_date'],
      'category': 'Ongkos Produksi',
      'title': 'Ongkos Produksi',
      'label': 'Ongkos Produksi',
      'amount': AppUi.toNum(row['amount']),
      'note': AppUi.text(row['note'], 'Bayar Ongkos Produksi'),
      'created_at': row['created_at'],
    });
  }

  Map<String, dynamic> _summaryWithLiveCosts(
    Map<String, dynamic> summary,
    List<Map<String, dynamic>> manualExpenses,
    List<Map<String, dynamic>> approvedPurchases,
  ) {
    final out = Map<String, dynamic>.from(summary);
    final payout = _numFirstNonZero([
      out['payout_total'],
      out['payout_amount'],
      out['received_amount'],
      out['net_received'],
      out['net_settlement']
    ]);
    final hpp = _numFirstNonZero([
      out['paid_hpp_total'],
      out['settled_hpp_total'],
      out['hpp_total'],
      out['total_hpp']
    ]);
    final productionExpenses = manualExpenses
        .where(_isProductionPaymentExpenseRow)
        .toList(growable: false);
    final operationalExpenses = manualExpenses
        .where((row) => !_isProductionPaymentExpenseRow(row))
        .toList(growable: false);
    final manual = operationalExpenses.isEmpty
        ? _numFirstNonZero([
            out['manual_expense_total'],
            out['manual_operational_expense'],
            out['operational_expense'],
            out['operational_cost_total'],
            out['expense_total'],
          ])
        : _sumAmountRows(operationalExpenses);
    final production = productionExpenses.isEmpty
        ? _numFirstNonZero([
            out['production_paid_total'],
            out['paid_production_total'],
            out['production_tailor_paid_total'],
          ])
        : _sumAmountRows(productionExpenses);
    final purchases = approvedPurchases.isEmpty
        ? _numFirstNonZero([
            out['approved_purchase_total'],
            out['purchase_cashout'],
            out['approved_purchase_cashout'],
          ])
        : _sumAmountRows(approvedPurchases);
    final expenseTotal = manual + production + purchases;
    final grossProfit = payout - hpp;
    final profit = grossProfit - expenseTotal;
    final margin = payout > 0
        ? (profit / payout) * 100
        : _numFirstNonZero([out['net_margin_percent'], out['margin_percent']]);
    out['manual_expense_total'] = manual;
    out['manual_operational_expense'] = manual;
    out['production_paid_total'] = production;
    out['paid_production_total'] = production;
    out['production_tailor_paid_total'] = production;
    out['approved_purchase_total'] = purchases;
    out['purchase_cashout'] = purchases;
    out['operational_expense'] = expenseTotal;
    out['operational_cost_total'] = expenseTotal;
    out['expense_total'] = expenseTotal;
    out['paid_hpp_total'] = hpp;
    out['settled_hpp_total'] = hpp;
    out['hpp_total'] = hpp;
    out['total_hpp'] = hpp;
    out['gross_profit'] = grossProfit;
    out['profit_before_expense'] = grossProfit;
    out['profit'] = profit;
    out['net_profit'] = profit;
    out['margin_percent'] = margin;
    out['net_margin_percent'] = margin;
    out['summary_policy'] = _text(out['summary_policy'],
        'settled_payout_only_no_pending_hpp_dynamic_cost');
    return out;
  }

  void _setMessage(String message) {
    if (!mounted) return;
    setState(() {
      _progressTitle = 'Status laporan';
      _progressLines
        ..clear()
        ..add(AppUi.userMessage(message));
    });
  }

  Future<List<Map<String, dynamic>>> _fetchOperationalExpensesPeriod() async {
    List<Map<String, dynamic>> results = [];
    try {
      final rpcRes = await _client.rpc(
        'finance_list_manual_operational_expenses',
        params: {
          'p_start': _toDateParam(_start),
          'p_end': _toDateParam(_end),
          'p_marketplace': _marketplaceRpcParam(),
          'p_account_id': _accountUuidParam(),
        },
      );
      final rawList = rpcRes is Map ? _asList(rpcRes['rows'] ?? rpcRes['data']) : _asList(rpcRes);
      if (rawList.isNotEmpty) {
        results = rawList.map((e) {
          final map = Map<String, dynamic>.from(e as Map);
          map['source'] = _text(map['source'], '').trim().isEmpty ||
                  _text(map['source'], '') == '-'
              ? 'finance_operational_expenses'
              : map['source'];
          map['source_label'] = 'Biaya operasional disetujui';
          return _normalizeProductionExpenseRow(map);
        }).toList();
      }
    } catch (_) {}

    if (results.isEmpty) {
      try {
        dynamic query = _client
            .from('finance_operational_expenses')
            .select()
            .gte('expense_date', _toDateParam(_start))
            .lte('expense_date', _toDateParam(_end));
        if (_currentTenantId.trim().isNotEmpty) {
          query = query.eq('tenant_id', _currentTenantId);
        }
        final res = await query
            .order('expense_date', ascending: false)
            .order('created_at', ascending: false)
            .range(0, 199);
        results = _asList(res).map((e) {
          final map = Map<String, dynamic>.from(e as Map);
          map['source'] = _text(map['source'], '').trim().isEmpty ||
                  _text(map['source'], '') == '-'
              ? 'finance_operational_expenses'
              : map['source'];
          map['source_label'] = 'Biaya operasional disetujui';
          return _normalizeProductionExpenseRow(map);
        }).toList();
      } catch (_) {}
    }

    try {
      dynamic manualQuery = _client
          .from('finance_company_cash_adjustments')
          .select()
          .gte('adjustment_date', _toDateParam(_dateOnly(_start)))
          .lte('adjustment_date', _toDateParam(_dateOnly(_end)));
      if (_currentTenantId.trim().isNotEmpty) {
        manualQuery = manualQuery.eq('tenant_id', _currentTenantId);
      }
      final manualRes = await manualQuery
          .eq('direction', 'out')
          .order('adjustment_date', ascending: false)
          .range(0, 199);
      final manualExpenses = _asList(manualRes).map((e) {
        final map = Map<String, dynamic>.from(e as Map);
        return {
          ...map,
          'adjustment_id': map['cash_adjustment_id'],
          'expense_date': map['adjustment_date'],
          'amount': _num(map['amount']).abs(),
          'description': map['category'] ?? map['note'] ?? 'Kas keluar manual',
          'source': 'finance_company_cash_adjustments',
          'source_label': 'Kas keluar manual',
        };
      }).toList();
      results.addAll(manualExpenses);
    } catch (_) {}

    try {
      dynamic tailorQuery = _client
          .from('production_tailor_payments')
          .select()
          .gte('payment_date', _toDateParam(_start))
          .lte('payment_date', _toDateParam(_end));
      if (_currentTenantId.trim().isNotEmpty) {
        tailorQuery = tailorQuery.eq('tenant_id', _currentTenantId);
      }
      final tailorRes = await tailorQuery
          .eq('payment_status', 'sudah_bayar')
          .inFilter('payment_type', ['sewing_payment', 'kasbon']);

      final mirroredProductionIds = <String>{};
      for (final row in results) {
        if (!_isProductionPaymentExpenseRow(row)) continue;
        for (final alias in _productionExpenseAliases(row)) {
          mirroredProductionIds.add(alias);
        }
      }

      final tailorPayments = _asList(tailorRes).map((e) {
        final map = Map<String, dynamic>.from(e as Map);
        final normalized = _productionPaymentExpenseFromRow(map);
        normalized['source_label'] = 'Ongkos produksi terbayar';
        return normalized;
      }).where((row) {
        if (row['is_voided'] == true) return false;
        final aliases = _productionExpenseAliases(row);
        return aliases.every((alias) => !mirroredProductionIds.contains(alias));
      }).toList();

      results.addAll(tailorPayments);
    } catch (_) {}

    try {
      dynamic prodQuery = _client
          .from('production_progress')
          .select()
          .eq('payment_status', 'sudah_bayar');
      if (_currentTenantId.trim().isNotEmpty) {
        prodQuery = prodQuery.eq('tenant_id', _currentTenantId);
      }
      final prodRes = await prodQuery.range(0, 199);
      final prodRows = _asList(prodRes).map((e) {
        final map = Map<String, dynamic>.from(e as Map);
        final statusStr = _text(map['payment_status'] ?? map['status'], '').toLowerCase();
        if (statusStr == 'belum_bayar' || statusStr == 'unpaid' || statusStr == 'pending') return null;
        final amt = _num(map['sewing_total_amount']) > 0
            ? _num(map['sewing_total_amount'])
            : (_num(map['payment_paid_amount']) > 0
                ? _num(map['payment_paid_amount'])
                : _num(map['deposit_amount']));
        if (amt <= 0) return null;
        final dateStr = map['production_date'] ?? map['tanggal_mulai'] ?? map['created_at'];
        final pDate = _parseDate(dateStr);
        if (pDate != null) {
          final d = _dateOnly(pDate);
          if (d.isBefore(_dateOnly(_start)) || d.isAfter(_dateOnly(_end))) return null;
        }
        final title = _text(map['product_name'] ?? map['nama_barang'] ?? map['sku'], 'Produksi');
        final sj = _text(map['surat_jalan_number'], '');
        final labelNote = sj.isNotEmpty ? 'Produksi SJ: $sj' : 'Produksi $title';
        return {
          'expense_id': 'prod_progress_${map['progress_id']}',
          'category': 'Ongkos Produksi',
          'amount': amt,
          'expense_date': _isoDate(pDate ?? _start),
          'note': '$labelNote - Qty ${_num(map['qty']).toStringAsFixed(0)}',
          'status': 'paid',
          'source': 'production_progress',
          'source_label': 'Ongkos produksi (Page Produksi)',
          'source_module': 'production',
          'type': 'production_progress',
          'flow': 'OUT',
        };
      }).whereType<Map<String, dynamic>>().toList();
      results.addAll(prodRows);
    } catch (_) {}

    try {
      dynamic stageQuery = _client
          .from('production_progress_stages')
          .select()
          .eq('payment_status', 'sudah_bayar');
      if (_currentTenantId.trim().isNotEmpty) {
        stageQuery = stageQuery.eq('tenant_id', _currentTenantId);
      }
      final stageRes = await stageQuery.range(0, 199);
      final stageRows = _asList(stageRes).map((e) {
        final map = Map<String, dynamic>.from(e as Map);
        final statusStr = _text(map['payment_status'] ?? map['status'], '').toLowerCase();
        if (statusStr != 'sudah_bayar' && statusStr != 'paid' && statusStr != 'lunas') return null;
        final amt = _num(map['total_amount']) > 0
            ? _num(map['total_amount'])
            : (_num(map['price_per_pcs']) * _num(map['qty_out'] > 0 ? map['qty_out'] : map['qty_in']));
        if (amt <= 0) return null;
        final dateStr = map['process_date'] ?? map['started_at'] ?? map['created_at'];
        final pDate = _parseDate(dateStr);
        if (pDate != null) {
          final d = _dateOnly(pDate);
          if (d.isBefore(_dateOnly(_start)) || d.isAfter(_dateOnly(_end))) return null;
        }
        final label = _text(map['stage_label'] ?? map['stage_key'], 'Tahap Produksi');
        final qty = _num(map['qty_out'] > 0 ? map['qty_out'] : map['qty_in']).toStringAsFixed(0);
        return {
          'expense_id': 'prod_stage_${map['progress_stage_id']}',
          'category': 'Ongkos Produksi',
          'amount': amt,
          'expense_date': _isoDate(pDate ?? _start),
          'note': 'Tahap $label - Qty $qty',
          'status': 'paid',
          'source': 'production_progress_stages',
          'source_label': 'Tahap produksi (Page Produksi)',
          'source_module': 'production',
          'type': 'production_stage',
          'flow': 'OUT',
        };
      }).whereType<Map<String, dynamic>>().toList();
      results.addAll(stageRows);
    } catch (_) {}

    results.sort((a, b) {
      final dateA = a['expense_date']?.toString() ?? '';
      final dateB = b['expense_date']?.toString() ?? '';
      return dateB.compareTo(dateA);
    });

    return results;
  }

  Future<Map<String, List<Map<String, dynamic>>>>
      _fetchCashWalletPeriodData() async {
    if (_currentTenantId.trim().isEmpty) {
      return <String, List<Map<String, dynamic>>>{
        'opening': <Map<String, dynamic>>[],
        'adjustments': <Map<String, dynamic>>[],
        'withdrawals': <Map<String, dynamic>>[],
        'allocations': <Map<String, dynamic>>[],
      };
    }

    final startMonth = _monthStart(_start);
    final endMonth = _monthStart(_end);
    final accountId = _accountUuidParam();
    final marketplace = _marketplaceRpcParam();

    Future<List<Map<String, dynamic>>> safeRows(
        Future<dynamic> Function() action) async {
      try {
        final res = await action();
        return _asList(res)
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    }

    final opening = await safeRows(() {
      return _client
          .from('finance_company_cash_opening_balances')
          .select()
          .eq('tenant_id', _currentTenantId)
          .gte('period_month', _toDateParam(startMonth))
          .lte('period_month', _toDateParam(endMonth))
          .order('period_month', ascending: false)
          .range(0, 119);
    });

    final adjustments = await safeRows(() {
      return _client
          .from('finance_company_cash_adjustments')
          .select()
          .eq('tenant_id', _currentTenantId)
          .gte('adjustment_date', _toDateParam(_dateOnly(_start)))
          .lte('adjustment_date', _toDateParam(_dateOnly(_end)))
          .order('adjustment_date', ascending: false)
          .order('created_at', ascending: false)
          .range(0, 499);
    });
    for (final row in adjustments) {
      row['source_table'] = 'finance_company_cash_adjustments';
    }

    final withdrawals = await safeRows(() {
      dynamic query = _client
          .from('finance_marketplace_withdrawals')
          .select()
          .eq('tenant_id', _currentTenantId)
          .gte('withdrawal_date', _toDateParam(_dateOnly(_start)))
          .lte('withdrawal_date', _toDateParam(_dateOnly(_end)));
      if (accountId != null)
        query = query.eq('marketplace_account_id', accountId);
      if (marketplace != null) query = query.eq('marketplace', marketplace);
      return query
          .order('withdrawal_date', ascending: false)
          .order('created_at', ascending: false)
          .range(0, 499);
    });

    final allocations = await safeRows(() {
      dynamic query = _client
          .from('finance_marketplace_withdrawal_allocations')
          .select()
          .eq('tenant_id', _currentTenantId)
          .gte('source_period_month', _toDateParam(startMonth))
          .lte('source_period_month', _toDateParam(endMonth));
      if (accountId != null)
        query = query.eq('marketplace_account_id', accountId);
      if (marketplace != null) query = query.eq('marketplace', marketplace);
      return query
          .order('source_period_month', ascending: false)
          .order('created_at', ascending: false)
          .range(0, 499);
    });

    return <String, List<Map<String, dynamic>>>{
      'opening': opening,
      'adjustments': adjustments,
      'withdrawals': withdrawals,
      'allocations': allocations,
    };
  }

  List<Map<String, dynamic>> _cashWalletRowsForDisplay({
    required List<Map<String, dynamic>> opening,
    required List<Map<String, dynamic>> adjustments,
    required List<Map<String, dynamic>> withdrawals,
  }) {
    final rows = <Map<String, dynamic>>[];

    for (final row in opening) {
      rows.add({
        ...row,
        '_cash_wallet_kind': 'opening',
        'source': 'Saldo awal kas',
        'category': 'Saldo awal kas',
        'cash_type': 'in',
        'type': 'in',
        'date': row['period_month'],
        'amount': _num(row['amount']),
      });
    }

    for (final row in adjustments) {
      final direction = _text(row['direction'], 'in').toLowerCase();
      final amount = _num(row['amount']).abs();
      rows.add({
        ...row,
        '_cash_wallet_kind': 'adjustment',
        'source_table': 'finance_company_cash_adjustments',
        'source': direction == 'out' ? 'Kas keluar manual' : 'Kas masuk manual',
        'category': row['category'],
        'cash_type': direction,
        'type': direction,
        'date': row['adjustment_date'],
        'amount': direction == 'out' ? -amount : amount,
      });
    }

    for (final row in withdrawals) {
      rows.add({
        ...row,
        '_cash_wallet_kind': 'withdrawal',
        'source': 'Penarikan marketplace',
        'category': 'Penarikan marketplace',
        'cash_type': 'in',
        'type': 'in',
        'date': row['withdrawal_date'],
        'amount': _num(row['amount']),
      });
    }

    rows.sort((a, b) {
      final aDate = _parseDate(a['date'] ?? a['created_at']) ?? DateTime(1970);
      final bDate = _parseDate(b['date'] ?? b['created_at']) ?? DateTime(1970);
      return bDate.compareTo(aDate);
    });
    return rows;
  }

  // ignore: unused_element
  Future<List<Map<String, dynamic>>> _fetchSkuOrderDetailsPeriod() async {
    // Initial load hanya ambil ringkasan SKU ringan.
    // Detail order/resi/statement diambil saat tombol detail SKU dibuka.
    final params = {
      'p_start': _toDateParam(_start),
      'p_end': _toDateParam(_end),
      'p_marketplace': _marketplaceRpcParam(),
      'p_account_id': _accountUuidParam(),
    };
    try {
      final candidates = <String>[
        'finance_sku_summary_rows',
        'finance_sku_summary_rows',
      ];
      final response = await _rpcWithFallback(candidates, params);
      final map = _asMap(response);
      final rows = _asList(map['rows'] ?? map['sku'] ?? map['by_sku']);
      return rows.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<Map<String, dynamic>> _fetchSkuOrderDetailsForRow(
      Map<String, dynamic> row) async {
    final skuCandidates = <String>[
      _text(row['local_sku'] ?? row['sku'], ''),
      _text(row['marketplace_sku_id'], ''),
      _text(row['marketplace_sku'], ''),
      _text(row['marketplace_seller_sku'] ?? row['seller_sku'], ''),
    ]
        .where((value) => value.trim().isNotEmpty && value.trim() != '-')
        .toSet()
        .toList();

    for (final sku in skuCandidates) {
      final detailKey = FinanceLocalCache.skuDetailKey(
        start: _start,
        end: _end,
        marketplace: _marketplaceFilter,
        accountId: _accountFilter,
        tenantId:
            _currentTenantId.trim().isEmpty ? 'unknown' : _currentTenantId,
        tab: 'sku_detail',
        page: 1,
        cacheVersion: _financeCacheVersion,
        sku: sku,
      );
      final cachedRows = await FinanceLocalCache.readRows(detailKey);
      if (cachedRows != null && cachedRows.isNotEmpty) {
        if (!_detailRowsLookAggregated(row, cachedRows)) {
          return _rowWithSkuDetails(row, cachedRows);
        }
      }

      try {
        final response = await _client.rpc(
          'finance_sku_order_detail_lines',
          params: {
            'p_start': _toDateParam(_start),
            'p_end': _toDateParam(_end),
            'p_marketplace': _marketplaceRpcParam(),
            'p_account_id': _accountUuidParam(),
            'p_sku': sku,
            'p_limit': 200,
            'p_offset': 0,
          },
        );
        final rows = _asList(_asMap(response)['rows'])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (rows.isEmpty) continue;
        await FinanceLocalCache.writeRows(detailKey, rows);
        return _rowWithSkuDetails(row, rows);
      } catch (_) {
        // Detail SKU tetap bisa dicoba lagi setelah koneksi pulih.
      }
    }
    return row;
  }

  Map<String, dynamic> _rowWithSkuDetails(
      Map<String, dynamic> row, List<Map<String, dynamic>> rows) {
    final copy = Map<String, dynamic>.from(row);
    copy['order_details'] = rows;
    final first = rows.isEmpty ? <String, dynamic>{} : rows.first;
    for (final field in const [
      'product_name',
      'variant_name',
      'marketplace_sku',
      'marketplace_sku_id',
      'marketplace_seller_sku',
      'local_sku',
      'target_margin_percent',
      'hpp_per_item',
    ]) {
      if (_text(copy[field]).trim().isEmpty || _text(copy[field]) == '-')
        copy[field] = first[field];
    }
    return copy;
  }

  Future<List<Map<String, dynamic>>> _fetchSkuRowsByPayoutFilterPage(
    String payoutFilter, {
    int page = 1,
    bool ignoreCache = false,
  }) async {
    final cacheKey = FinanceLocalCache.skuPageKey(
      start: _start,
      end: _end,
      marketplace: _marketplaceFilter,
      accountId: _accountFilter,
      tenantId: _currentTenantId.trim().isEmpty ? 'unknown' : _currentTenantId,
      payoutFilter: payoutFilter,
      page: page,
      cacheVersion: _financeCacheVersion,
    );

    if (!ignoreCache) {
      final cachedData = await FinanceLocalCache.readJson(cacheKey, ttlDays: 2);
      if (cachedData != null) {
        final cachedRows = (cachedData['rows'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (cachedRows != null && (cachedRows.isNotEmpty || page > 1)) {
          if (payoutFilter == 'all') {
            setState(() {
              _skuServerTotalPages = cachedData['total_pages'] ?? 1;
              _skuServerTotalCount =
                  cachedData['total_count'] ?? cachedRows.length;
            });
            if (page == 1) {
              _lastSkuRpcRowCount = cachedRows.length;
              _lastSkuParsedRowCount = cachedRows.length;
            }
          }
          return cachedRows;
        }
      }
    }

    final params = {
      'p_start': _toDateParam(_start),
      'p_end': _toDateParam(_end),
      'p_marketplace': _marketplaceRpcParam(),
      'p_account_id': _accountUuidParam(),
      'p_search': null,
      'p_payout_filter': payoutFilter,
      'p_page': page,
      'p_page_size': _skuPageSize,
    };

    try {
      final response = await _client.rpc(
        'finance_sku_order_details_group_20260625',
        params: params,
      );
      List<dynamic> rawRowsList = [];
      int totalCount = 0;
      int totalPages = 1;
      if (response is List) {
        if (response.isNotEmpty &&
            response.first is Map &&
            (response.first as Map).containsKey('rows')) {
          final firstMap = response.first as Map;
          rawRowsList = _asList(firstMap['rows']);
          totalCount = firstMap['total_count'] ??
              firstMap['total'] ??
              rawRowsList.length;
          totalPages = firstMap['total_pages'] ?? 1;
        } else {
          rawRowsList = response;
          totalCount = rawRowsList.length;
          totalPages = 1;
        }
      } else if (response is Map) {
        rawRowsList = _asList(
            response['data'] ??
            response['items'] ??
            response['rows'] ??
            response['by_sku'] ??
            response['sku']);
        totalCount = response['total_sku_count'] ??
            response['total_count'] ??
            response['total'] ??
            rawRowsList.length;
        final calcPages = (totalCount / _skuPageSize).ceil();
        totalPages = response['total_pages'] ?? (calcPages < 1 ? 1 : calcPages);
      }
      final rows = rawRowsList
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (payoutFilter == 'all') {
        if (page == 1) {
          _lastSkuRpcRowCount = rawRowsList.length;
          _lastSkuParsedRowCount = rows.length;
        }
        setState(() {
          _skuServerTotalPages = totalPages;
          _skuServerTotalCount = totalCount;
        });
      }
      await FinanceLocalCache.writeJson(cacheKey, {
        'rows': rows,
        'total_count': totalCount,
        'total_pages': totalPages,
      });
      return rows;
    } catch (error) {
      debugPrint('FINANCE_SKU_${payoutFilter}_PAGE_$page failed: $error');
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _loadNextSkuPage() async {
    if (_skuLoadingMore || !_skuHasMoreServerRows) return;
    setState(() => _skuLoadingMore = true);
    final nextPage = _skuServerPageLoaded + 1;
    try {
      final parsedRows =
          await _fetchSkuRowsByPayoutFilterPage('all', page: nextPage);
      final filteredRows = _filterSkuRowsBySelectedScope(parsedRows);
      final rows = filteredRows.isNotEmpty || parsedRows.isEmpty
          ? filteredRows
          : parsedRows;
      if (filteredRows.isEmpty && parsedRows.isNotEmpty) {
        debugPrint(
            'FINANCE_SKU_SCOPE_FALLBACK: page=$nextPage parsed=${parsedRows.length} '
            'filtered=0; using parsed rows because RPC was already scoped.');
      }
      final normalized = _normalizeSkuRows(<Map<String, dynamic>>[
        ..._bySku,
        ...rows,
      ]);
      final merged = _mergeSkuRows(
        normalized,
        const <Map<String, dynamic>>[],
      );
      final sorted = _sortSkuRowsForDisplay(merged);
      _recordSkuRenderProof(
        source: 'next_page',
        payoutFilter: 'all',
        rpcRowCount: parsedRows.length,
        parsedRowCount: parsedRows.length,
        filteredRowCount: filteredRows.length,
        normalizedRowCount: normalized.length,
        mergedRowCount: sorted.length,
        renderedRowCount: _skuRenderedCountForRows(sorted),
      );
      if (!mounted) return;
      setState(() {
        _bySku = sorted;
        _skuServerPageLoaded = nextPage;
        _skuHasMoreServerRows = rows.length >= _skuPageSize;
        _skuPage = nextPage;
      });
      unawaited(_overlaySkuPayoutCountSummaryFromServer());
    } finally {
      if (mounted) setState(() => _skuLoadingMore = false);
    }
  }

  Future<void> _lazyLoadSkuFirstPage() async {
    if (_skuLoaded) return;
    setState(() {
      _skuLoadingFirstPage = true;
    });
    try {
      final parsedRows = await _fetchSkuRowsByPayoutFilterPage(
        'all',
        page: 1,
        ignoreCache: true,
      );
      final filteredRows = _filterSkuRowsBySelectedScope(parsedRows);
      final rows = filteredRows.isNotEmpty || parsedRows.isEmpty
          ? filteredRows
          : parsedRows;
      if (filteredRows.isEmpty && parsedRows.isNotEmpty) {
        debugPrint(
            'FINANCE_SKU_SCOPE_FALLBACK: page=1 parsed=${parsedRows.length} '
            'filtered=0; using parsed rows because RPC was already scoped.');
      }
      final normalized = _normalizeSkuRows(rows);
      final merged = _mergeSkuRows(
        normalized,
        const <Map<String, dynamic>>[],
      );
      final sorted = _sortSkuRowsForDisplay(merged);
      _recordSkuRenderProof(
        source: 'first_page',
        payoutFilter: 'all',
        rpcRowCount: _lastSkuRpcRowCount,
        parsedRowCount: parsedRows.length,
        filteredRowCount: filteredRows.length,
        normalizedRowCount: normalized.length,
        mergedRowCount: sorted.length,
        renderedRowCount: _skuRenderedCountForRows(sorted),
      );
      if (!mounted) return;
      setState(() {
        _bySku = sorted;
        _skuServerPageLoaded = 1;
        _skuHasMoreServerRows = rows.length >= _skuPageSize;
        _skuLoaded = true;
      });
      unawaited(_overlaySkuPayoutCountSummaryFromServer());
    } catch (e) {
      debugPrint('Error lazy loading SKU first page: $e');
    } finally {
      if (mounted) {
        setState(() {
          _skuLoadingFirstPage = false;
        });
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchSkuRowsByPayoutFilter(
      String payoutFilter) async {
    final params = {
      'p_start': _toDateParam(_start),
      'p_end': _toDateParam(_end),
      'p_marketplace': _marketplaceRpcParam(),
      'p_account_id': _accountUuidParam(),
      'p_search': null,
      'p_payout_filter': payoutFilter,
      'p_page': 1,
      'p_page_size': _skuPageSize * 2,
    };
    try {
      final response = await _client.rpc(
        'finance_sku_order_details_group_20260625',
        params: params,
      );
      final map = _asMap(response);
      final rows = _asList(map['rows'] ?? map['by_sku'] ?? map['sku']);
      return rows
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (error) {
      debugPrint('FINANCE_SKU_$payoutFilter failed: $error');
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchUnpaidSkuRowsPeriod() async {
    final params = {
      'p_start': _toDateParam(_start),
      'p_end': _toDateParam(_end),
      'p_marketplace': _marketplaceRpcParam(),
      'p_account_id': _accountUuidParam(),
    };
    try {
      final candidates = <String>[
        'finance_unpaid_sku_rows',
        'finance_unpaid_sku_rows',
      ];
      final res = await _rpcWithFallback(candidates, params);
      final rows = _asList(_asMap(res)['rows'] ?? res);
      return rows.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<dynamic> _rpcWithFallback(
      List<String> names, Map<String, dynamic> params) async {
    Object? lastError;
    for (final name in names) {
      try {
        return await _client.rpc(name, params: params);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('Proses gagal.');
  }

  Map<String, dynamic> _extractSummaryMap(dynamic response) {
    final data = _asMap(response);
    if (data.isEmpty) return <String, dynamic>{};
    final nested = _asMap(data['summary']);
    if (nested.isNotEmpty) return nested;
    return data;
  }

  String _snapshotStats(dynamic response) {
    final data = _asMap(response);
    final summary = _extractSummaryMap(response);
    final bySku =
        _asList(data['by_sku'] ?? data['sku_margin'] ?? data['sku']).length;
    final paidListCount = _asList(data['paid_orders']).length +
        _asList(data['settled_orders']).length;
    final unpaidListCount = _asList(data['unpaid_orders']).length +
        _asList(data['pending_orders']).length +
        _asList(data['missing_payout_orders']).length;
    final paidFromSummary = _numFirstNonZero([
      summary['paid_qty_total'],
      summary['settled_qty_total'],
      summary['paid_orders_count'],
      summary['paid_order_count'],
      summary['settled_order_count'],
    ]).round();
    final unpaidFromSummary = _numFirstNonZero([
      summary['unpaid_qty_total'],
      summary['pending_payout_qty_total'],
      summary['unpaid_order_count'],
      summary['pending_payout_order_count'],
    ]).round();
    final paid = paidListCount > 0 ? paidListCount : paidFromSummary;
    final unpaid = unpaidListCount > 0 ? unpaidListCount : unpaidFromSummary;
    final market =
        _asList(data['by_marketplace'] ?? data['marketplaces']).length;
    final abnormal = _asList(data['abnormals']).length;
    final gross = _num(summary['gross_sales'] ??
        summary['gross_total'] ??
        summary['omzet_total'] ??
        summary['omzet']);
    final payout = _num(summary['payout_total'] ??
        summary['payout_amount'] ??
        summary['received_amount'] ??
        summary['net_settlement']);
    final orders = _num(summary['finance_order_count'] ??
        summary['finance_orders_count'] ??
        summary['order_count'] ??
        summary['orders_count']);
    return 'Data: ${orders.toStringAsFixed(0)} pesanan · $bySku SKU · $paid settled · $unpaid belum payout · $market sumber · $abnormal abnormal · omzet ${_money(gross)} · payout ${_money(payout)}';
  }

  bool _isFinanceSnapshotEmpty(dynamic response) {
    final data = _asMap(response);
    if (data.isEmpty) return true;
    if (_hasUsableFinanceSummary(response)) return false;

    for (final key in const [
      'paid_orders',
      'settled_orders',
      'orders',
    ]) {
      if (_asList(data[key]).isNotEmpty) return false;
    }

    final bySku = _asList(data['by_sku'] ?? data['sku_margin'] ?? data['sku']);
    if (bySku.isNotEmpty) {
      final hasSettledFinance = bySku.any((row) {
        final map = _asMap(row);
        return _numFirstNonZero([
              map['payout_total'],
              map['total_payout'],
              map['gross_settled_total'],
              map['settled_gross_total'],
              map['qty_settled'],
              map['settled_count'],
              map['paid_orders'],
            ]).abs() >
            0;
      });
      if (hasSettledFinance) return false;

      final days = _dateOnly(_end).difference(_dateOnly(_start)).inDays.abs();
      if (days <= 1) return false;
    }

    return true;
  }

  bool _hasUsableFinanceSummary(dynamic response) {
    final summary = _extractSummaryMap(response);
    for (final key in const [
      'gross_sales',
      'gross_total',
      'gross_amount',
      'omzet',
      'omzet_total',
      'payout_total',
      'payout_amount',
      'received_amount',
      'net_received',
      'net_settlement',
      'hpp_total',
      'total_hpp',
      'operational_cost_total',
      'operational_expense',
      'expense_total',
      'net_profit',
      'profit',
      'order_count',
      'finance_order_count',
      'paid_order_count',
      'orders_count',
      'finance_orders_count',
      'all_orders_count',
    ]) {
      if (_num(summary[key]).abs() > 0) return true;
    }
    return false;
  }

  bool _isLegacySkuOnlySnapshot(dynamic response) {
    final data = _asMap(response);
    if (data.isEmpty) return false;

    // Snapshot finance aktif boleh membawa summary + sku.
    // Jangan tolak snapshot valid hanya karena ada list SKU.
    final summary = _extractSummaryMap(response);
    if (summary.isNotEmpty) return false;

    final hasDashboardRows = _asList(data['by_marketplace']).isNotEmpty ||
        _asList(data['cash_flow']).isNotEmpty ||
        _asList(data['expenses']).isNotEmpty ||
        _asList(data['profit_loss']).isNotEmpty ||
        _asList(data['abnormal']).isNotEmpty ||
        _asList(data['abnormals']).isNotEmpty ||
        _asList(data['sources']).isNotEmpty ||
        _asList(data['accounts']).isNotEmpty;

    if (hasDashboardRows) return false;

    return _asList(data['by_sku'] ?? data['sku_margin'] ?? data['sku'])
        .isNotEmpty;
  }

  Future<void> _saveFinanceRuntimeProgress({
    required String status,
    required String title,
    required List<String> lines,
    int? checked,
    int? success,
    int? failed,
    int? skipped,
  }) async {
    try {
      await _client.rpc(
        'finance_upsert_runtime_progress',
        params: {
          'p_sync_type': 'manual_period_progress',
          'p_status': status,
          'p_start': _toDateParam(_start),
          'p_end': _toDateParam(_end),
          'p_marketplace': _marketplaceRpcParam(),
          'p_account_id': _accountUuidParam(),
          'p_checked': checked ?? 0,
          'p_success': success ?? 0,
          'p_failed': failed ?? 0,
          'p_skipped': skipped ?? 0,
          'p_message': ([title, ...lines.take(8)]
              .where((item) => item.trim().isNotEmpty)
              .join('\n')),
        },
      );
    } catch (_) {
      // Riwayat progres bersifat tambahan. Proses utama tetap lanjut.
    }
  }

  Future<void> _loadPersistedFinanceProgressFromDb() async {
    if (_processing || !mounted) return;
    try {
      final candidates = <String>[
        'finance_get_latest_runtime_progress',
        'finance_get_latest_runtime_progress',
      ];
      final response = await _rpcWithFallback(candidates, {});
      if (!mounted || response is! Map) return;
      final map = Map<String, dynamic>.from(response);
      final message = _text(map['message']);
      if (message.trim().isEmpty) return;
      final status = _text(map['status'], 'log');
      final updatedAt = _parseDate(map['updated_at']);
      final lines = message
          .split('\n')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .map(AppUi.userMessage)
          .toList();
      final title = status == 'running'
          ? 'Tarik data belum selesai'
          : status == 'failed'
              ? 'Tarik data gagal'
              : 'Status auto finance';
      final updatedLine =
          updatedAt == null ? null : 'Update terakhir: ${_dateTime(updatedAt)}';
      setState(() {
        _progressTitle = title;
        _progressLines
          ..clear()
          ..addAll([
            if (updatedLine != null) updatedLine,
            if (lines.isNotEmpty) lines.first,
          ]);
        _cacheFinanceProgress();
      });
    } catch (_) {
      // Kalau riwayat server belum tersedia, UI tetap memakai log lokal.
    }
  }

  List<Map<String, dynamic>> _marketplaceRowsWithFinanceAliases(
      List<Map<String, dynamic>> rows) {
    return rows.map((row) {
      final out = Map<String, dynamic>.from(row);
      final gross = _numFirstNonZero([
        out['gross_sales'],
        out['omzet_total'],
        out['gross_total'],
        out['gross_amount'],
        out['omzet'],
      ]);
      final payout = _numFirstNonZero([
        out['payout_total'],
        out['payout_amount'],
        out['received_amount'],
        out['net_settlement'],
        out['net_received'],
      ]);
      final hpp = _numFirstNonZero([
        out['hpp_total'],
        out['total_hpp'],
        out['settled_hpp_total'],
        out['paid_hpp_total'],
        out['hpp'],
      ]);
      final profit = _numFirstNonZero([
        out['net_profit'],
        out['profit'],
      ]);
      final discount = _numFirstNonZero([
        out['discount_amount'],
        out['voucher_amount'],
        out['discount'],
        out['voucher'],
        out['shopee_discount'],
        out['tiktok_discount'],
        out['seller_discount'],
        out['platform_discount'],
        out['seller_voucher'],
        out['platform_voucher'],
      ]);
      final refund = _numFirstNonZero([
        out['refund_amount'],
        out['return_refund_amount'],
        out['refund'],
        out['retur'],
        out['buyer_refund_amount'],
      ]);
      final adjustment = _numFirstNonZero([
        out['adjustment_amount'],
        out['adjustment'],
        out['koreksi'],
        out['settlement_correction'],
      ]);
      final platformFee = _numFirstNonZero([
        out['platform_fee'],
        out['service_fee'],
        out['biaya_layanan'],
        out['platform_service_fee'],
        out['service_fee_amount'],
      ]);
      final commissionFee = _numFirstNonZero([
        out['commission_fee'],
        out['commission'],
        out['biaya_komisi'],
        out['total_commission'],
        out['commission_fee_amount'],
      ]);
      final affiliateFee = _numFirstNonZero([
        out['affiliate_fee'],
        out['affiliate_commission'],
        out['biaya_afiliasi'],
        out['affiliate_cost'],
        out['affiliate_commission_amount'],
      ]);
      final shippingFee = _numFirstNonZero([
        out['shipping_fee'],
        out['shipping_cost'],
        out['biaya_pengiriman'],
        out['ongkir_seller'],
      ]);
      final feeAmount = _numFirstNonZero([
        out['fee_amount'],
        out['total_fees'],
        out['total_deductions'],
        out['biaya'],
        out['deductions'],
      ]);

      out['gross_sales'] = gross;
      out['omzet_total'] = gross;
      out['gross_total'] = gross;
      out['payout_total'] = payout;
      out['received_amount'] = payout;
      out['net_settlement'] = payout;
      out['hpp_total'] = hpp;
      out['total_hpp'] = hpp;
      out['hpp'] = hpp;
      out['net_profit'] = profit != 0 ? profit : payout - hpp;
      out['profit'] = out['net_profit'];
      out['discount_amount'] = discount;
      out['voucher_amount'] = discount;
      out['refund_amount'] = refund;
      out['adjustment_amount'] = adjustment;
      out['platform_fee'] = platformFee;
      out['commission_fee'] = commissionFee;
      out['affiliate_fee'] = affiliateFee;
      out['shipping_fee'] = shippingFee;
      if (feeAmount != 0) out['fee_amount'] = feeAmount;
      out['account_name'] = _text(
        out['account_name'] ?? out['shop_name'] ?? out['store_alias'],
        '-',
      );
      out['shop_name'] = _text(out['shop_name'] ?? out['account_name'], '-');
      return out;
    }).toList(growable: false);
  }

  List<Map<String, dynamic>> _enrichMarketplaceRowsHppFromSku(
    List<Map<String, dynamic>> mktRows,
    List<Map<String, dynamic>> skuRows, {
    Map<String, dynamic>? summary,
  }) {
    if (mktRows.isEmpty) return mktRows;

    final targetSummary = summary ?? _summary;

    final skuHppByMkt = <String, double>{};
    final skuHppByAccount = <String, double>{};
    var totalSkuHpp = 0.0;

    for (final sku in skuRows) {
      final mkt = _text(sku['marketplace'] ?? sku['platform'])
          .trim()
          .toLowerCase()
          .replaceAll('_shop', '')
          .replaceAll(' ', '');
      final accId = _text(sku['marketplace_account_id'] ?? sku['account_id']).trim();
      final hpp = _numFirstNonZero([
        sku['paid_hpp_total'],
        sku['settled_hpp_total'],
        sku['hpp_total'],
        sku['total_hpp'],
        sku['hpp_cair'],
        sku['hpp_settled'],
        sku['hpp_amount'],
        sku['hpp'],
      ]);

      if (hpp > 0) {
        totalSkuHpp += hpp;
        if (mkt.isNotEmpty) {
          skuHppByMkt[mkt] = (skuHppByMkt[mkt] ?? 0.0) + hpp;
        }
        if (accId.isNotEmpty) {
          skuHppByAccount[accId] = (skuHppByAccount[accId] ?? 0.0) + hpp;
        }
      }
    }

    final summaryHpp = _numFirstNonZero([
      targetSummary['hpp_total'],
      targetSummary['total_hpp'],
      targetSummary['paid_hpp_total'],
      targetSummary['settled_hpp_total'],
      targetSummary['hpp_cair'],
      targetSummary['hpp'],
    ]);

    final totalMktGross = mktRows.fold<double>(
      0.0,
      (sum, r) => sum + _num(r['gross_sales'] ?? r['gross'] ?? r['omzet_total']),
    );

    return mktRows.map((source) {
      final row = Map<String, dynamic>.from(source);
      var currentHpp = _numFirstNonZero([
        row['paid_hpp_total'],
        row['settled_hpp_total'],
        row['hpp_total'],
        row['total_hpp'],
        row['hpp_cair'],
        row['hpp_settled'],
        row['hpp_amount'],
        row['hpp'],
      ]);

      if (currentHpp == 0) {
        final mktKey = _text(row['marketplace'] ?? row['platform'] ?? row['marketplace_label'])
            .trim()
            .toLowerCase()
            .replaceAll('_shop', '')
            .replaceAll(' ', '');
        final accId = _text(row['marketplace_account_id'] ?? row['account_id']).trim();
        double? skuHpp;

        if (accId.isNotEmpty && skuHppByAccount.containsKey(accId)) {
          skuHpp = skuHppByAccount[accId];
        } else if (mktKey.isNotEmpty) {
          for (final entry in skuHppByMkt.entries) {
            if (mktKey.contains(entry.key) || entry.key.contains(mktKey)) {
              skuHpp = (skuHpp ?? 0.0) + entry.value;
            }
          }
        }

        if ((skuHpp == null || skuHpp == 0) && (summaryHpp > 0 || totalSkuHpp > 0)) {
          final targetTotalHpp = summaryHpp > 0 ? summaryHpp : totalSkuHpp;
          final gross = _num(row['gross_sales'] ?? row['gross'] ?? row['omzet_total']);
          if (totalMktGross > 0 && gross > 0) {
            skuHpp = (gross / totalMktGross) * targetTotalHpp;
          }
        }

        if (skuHpp != null && skuHpp > 0) {
          currentHpp = skuHpp;
          row['hpp_total'] = currentHpp;
          row['total_hpp'] = currentHpp;
          row['hpp'] = currentHpp;
          row['paid_hpp_total'] = currentHpp;
          row['settled_hpp_total'] = currentHpp;

          final payout = _numFirstNonZero([
            row['payout_total'],
            row['payout_amount'],
            row['received_amount'],
            row['net_settlement'],
            row['payout'],
          ]);
          final profit = payout - currentHpp;
          row['net_profit'] = profit;
          row['profit'] = profit;
          row['margin_percent'] = payout > 0 ? (profit / payout) * 100 : 0.0;
          row['net_margin_percent'] = row['margin_percent'];
        }
      }
      return row;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchCashAdjustmentsPeriod() async {
    final start = _toDateParam(_start);
    final end = _toDateParam(_end);
    final tenantId = _currentTenantId.trim();

    try {
      var query = _client
          .from('finance_company_cash_adjustments')
          .select('*')
          .gte('adjustment_date', start)
          .lte('adjustment_date', end);

      if (tenantId.isNotEmpty && _isUuid(tenantId)) {
        query = query.eq('tenant_id', tenantId);
      }

      final response = await query.order('adjustment_date', ascending: false);
      return _asList(response)
          .map((row) => {
                ...Map<String, dynamic>.from(row),
                'source_table': 'finance_company_cash_adjustments',
              })
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _applyFinanceSnapshotData(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> fallbackAccounts, {
    required bool includeOperationalExpenses,
    required bool includeSupplementalSku,
  }) async {
    final mergedAccounts =
        _mergeAccounts(_asList(data['accounts']), fallbackAccounts);
    final activeAccountIds =
        mergedAccounts.map(_accountId).where(_isUuid).toSet();
    if (_accountFilter != 'all' && !activeAccountIds.contains(_accountFilter)) {
      _accountFilter = 'all';
      _rememberFilters();
    }

    if (!mounted) return;
    final normalizedSummary = _normalizeFinanceSummary(_extractSummaryMap(data));
    final abnormalAggregates = _asMap(data['abnormal_aggregates'] ??
        data['abnormal_summary'] ??
        data['aggregates']);
    if (abnormalAggregates.isNotEmpty) {
      for (final key in const [
        'abnormal_count',
        'negative_payout_count',
        'negative_payout_total_abs',
        'minus_payout_total_abs',
        'payout_minus_total_abs',
        'negative_payout_total',
        'minus_payout_total',
        'payout_minus_total',
        'total_negative_payout',
        'missing_payout_count',
        'pending_payout_count',
        'cancel_refund_count',
        'cancel_refund_total',
      ]) {
        final value = abnormalAggregates[key];
        if (value != null &&
            (_num(normalizedSummary[key]) == 0 || key.contains('count'))) {
          normalizedSummary[key] = value;
        }
      }
    }
    final backendExpenses = _asList(data['expenses'] ?? data['biaya'])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final backendPurchases =
        _asList(data['approved_purchases'] ?? data['purchases_approved'])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
    final liveExpenses = includeOperationalExpenses
        ? await _fetchOperationalExpensesPeriod()
        : <Map<String, dynamic>>[];
    final livePurchases = includeOperationalExpenses
        ? await _fetchApprovedPurchasesPeriod()
        : <Map<String, dynamic>>[];
    final normalizedExpenses = _dedupeExpenseRows(<Map<String, dynamic>>[
      ...backendExpenses.where((row) => !_isPurchaseExpenseRow(row)),
      ...liveExpenses,
    ]).where((row) => !_isSyntheticExpenseRow(row)).toList(growable: false);
    final approvedPurchases = _dedupeByStableKey(<Map<String, dynamic>>[
      ...backendPurchases,
      ...backendExpenses.where(_isPurchaseExpenseRow),
      ...livePurchases,
    ]);

    final backendCashAdjustments = _asList(data['cash_adjustments'] ??
            data['company_cash_adjustments'] ??
            data['cash_in_out'] ??
            data['cash_adjustment_rows'])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    final liveCashAdjustments = includeOperationalExpenses
        ? await _fetchCashAdjustmentsPeriod()
        : <Map<String, dynamic>>[];

    final normalizedCashAdjustments = _dedupeByStableKey(<Map<String, dynamic>>[
      ...backendCashAdjustments.map((row) => {
            ...row,
            'source_table': 'finance_company_cash_adjustments',
          }),
      ...liveCashAdjustments,
    ]);

    final snapshotSkuRows = _skuRowsFromSnapshot(data);
    final initialSkuRows = snapshotSkuRows.take(_skuPageSize).toList();
    final liveSettledSkuRows = includeSupplementalSku
        ? _filterSkuRowsBySelectedScope(
            await _fetchSkuRowsByPayoutFilterPage('settled'),
          )
        : <Map<String, dynamic>>[];
    final liveUnpaidSkuRows = includeSupplementalSku
        ? _filterSkuRowsBySelectedScope(
            await _fetchSkuRowsByPayoutFilterPage('unpaid'),
          )
        : <Map<String, dynamic>>[];

    // Tag rows with their payout filter source so _normalizeSkuRows can
    // avoid misclassifying unpaid rows as fully paid when payout_total > 0.
    final liveSkuRows = _filterSkuRowsBySelectedScope(<Map<String, dynamic>>[
      ...liveSettledSkuRows.map((r) => {...r, '_payout_filter': 'settled'}),
      ...liveUnpaidSkuRows.map((r) => {...r, '_payout_filter': 'unpaid'}),
    ]);

    // Live finance SKU order details is the row-level source of truth for
    // settled/unpaid SKU metrics and HPP. Snapshot SKU rows are fallback only.
    // Mixing snapshot rows first can keep old HPP 0 rows visible on page 1.
    var rawSkuRows = liveSkuRows.isNotEmpty
        ? liveSkuRows
        : _filterSkuRowsBySelectedScope(initialSkuRows);

    // Backend snapshot/RPC already receives p_marketplace and p_account_id.
    // Some legacy snapshot rows do not carry marketplace/account per row.
    if (rawSkuRows.isEmpty && initialSkuRows.isNotEmpty) {
      rawSkuRows = initialSkuRows;
    }

    final normalizedSku = _mergeSkuRows(
      _normalizeSkuRows(rawSkuRows),
      const <Map<String, dynamic>>[],
    );
    final hasMoreLiveSkuRows = includeSupplementalSku &&
        (liveSettledSkuRows.length >= _skuPageSize ||
            liveUnpaidSkuRows.length >= _skuPageSize);

    var displaySummary = _summaryForDisplay(
      normalizedSummary,
      normalizedSku,
      normalizedExpenses,
      forceFromSku: false,
      includeUnpaidGross: false,
    );
    displaySummary = _summaryWithLiveCosts(
        displaySummary, normalizedExpenses, approvedPurchases);

    final cashWalletData = await _fetchCashWalletPeriodData();
    final rawMarketplaceRows = _normalizeMarketplaceRows(
        _asList(data['by_marketplace'] ?? data['marketplaces']));
    final normalizedMarketplace =
        _text(data['reconciliation_source']).trim().isNotEmpty &&
                rawMarketplaceRows.isNotEmpty
            ? rawMarketplaceRows
            : _reconciledMarketplaceRows(
                rawMarketplaceRows,
                normalizedSku,
                displaySummary,
                mergedAccounts,
              );
    final backendCashFlow = _asList(data['cash_flow'] ?? data['cashflow'])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final useBackendCashFlow = backendCashFlow.isNotEmpty;
    final normalizedCashFlow = useBackendCashFlow
        ? _dedupeCashFlowRows(backendCashFlow)
        : _cashFlowRowsFromSummary(displaySummary);
    final walletCashAdjustments =
        cashWalletData['adjustments'] ?? <Map<String, dynamic>>[];
    final cashAdjustmentsForState = _dedupeByStableKey(<Map<String, dynamic>>[
      ...normalizedCashAdjustments,
      ...walletCashAdjustments.map((row) => {
            ...row,
            'source_table': 'finance_company_cash_adjustments',
          }),
    ]);
    final breakdown = _asList(data['profit_loss_breakdown'])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final normalizedProfitLoss = <Map<String, dynamic>>[
      ..._profitLossRowsFromSummary(displaySummary, breakdown)
          .where((row) => !_isBackendGeneratedProfitLossBreakdownRow(row)),
      ..._profitLossExpenseDetailRows(normalizedExpenses),
    ];
    final normalizedMarketplaceForDisplay = _enrichMarketplaceRowsHppFromSku(
        _marketplaceRowsWithFinanceAliases(normalizedMarketplace),
        normalizedSku,
        summary: displaySummary);
    setState(() {
      _accounts = mergedAccounts;
      _summary = displaySummary;
      _sources = _asList(data['sources'].toString() == 'null'
          ? data['notes']
          : data['sources']);
      _approvedPurchases = approvedPurchases;
      _byMarketplace = normalizedMarketplaceForDisplay;
      _bySku = _sortSkuRowsForDisplay(normalizedSku);
      _skuPage = 1;
      _skuServerPageLoaded = 1;
      _skuHasMoreServerRows = hasMoreLiveSkuRows;
      _skuLoadingMore = false;
      _cashFlow = <Map<String, dynamic>>[
        ...normalizedCashFlow,
        ...normalizedCashAdjustments,
      ];
      // Opening balances are independent from backend marketplace cashflow.
      // Keep them visible even when backend cashflow rows are present.
      _cashOpeningBalances =
          cashWalletData['opening'] ?? <Map<String, dynamic>>[];
      _cashAdjustments = cashAdjustmentsForState;
      _marketplaceWithdrawals = useBackendCashFlow
          ? <Map<String, dynamic>>[]
          : cashWalletData['withdrawals'] ?? <Map<String, dynamic>>[];
      _withdrawalAllocations = useBackendCashFlow
          ? <Map<String, dynamic>>[]
          : cashWalletData['allocations'] ?? <Map<String, dynamic>>[];
      _expenses = normalizedExpenses;
      _operationalCostsLoaded = true;
      _operationalCostsLoading = false;
      _operationalCostsError = null;
      _profitLoss = normalizedProfitLoss;
      _profitLossLoaded = true;
      _profitLossLoading = false;
      _profitLossError = null;
      final rawProfitLossMarketplace = _asList(
        data['profit_loss_by_marketplace'] ??
            data['by_marketplace'] ??
            data['marketplaces'],
      );
      _profitLossByMarketplace = _enrichMarketplaceRowsHppFromSku(
        _marketplaceRowsWithFinanceAliases(
          rawProfitLossMarketplace
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList(),
        ),
        normalizedSku,
        summary: displaySummary,
      );
      _abnormals = _normalizeAbnormalRows(_asList(data['abnormals']));
      _sampleFreeOrders = _normalizeAbnormalRows(
        _asList(data['sample_orders']).whereType<Map>().map((item) {
          final row = Map<String, dynamic>.from(item);
          row['abnormal_status'] = 'SAMPLE_FREE';
          row['payout_status'] = row['payout_status'] ?? 'SAMPLE_FREE';
          row['finance_status'] = row['finance_status'] ?? 'SAMPLE_FREE';
          row['message'] = _text(
            row['message'] ?? row['note'],
            'Sample/gratis sesuai filter. Tidak masuk omzet normal.',
          );
          row['category'] = row['category'] ?? 'sample_zero_payment';
          return row;
        }).toList(),
      );
      if (_progressTitle.trim().isEmpty && _progressLines.isEmpty) {
        final lastMessage = _text(
            _summary['last_manual_finance_sync_message'] ??
                _summary['last_finance_sync_message']);
        if (lastMessage.trim().isNotEmpty) {
          _progressTitle = 'Status auto finance';
          _progressLines.add(
            AppUi.userMessage(lastMessage.split('\n').first.trim()),
          );
          _cacheFinanceProgress();
        }
      }
      _expenseCategoryOptions = _mergeExpenseCategories(normalizedExpenses);
    });
    unawaited(_loadMarketplaceFinanceGapHint());
  }

  Future<void> _loadMarketplaceFinanceGapHint() async {
    final startKey = _toDateParam(_start);
    final endKey = _toDateParam(_end);
    final mktKey = _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
    final accKey = _accountFilter;
    if (mktKey != 'all' && !mktKey.contains('tiktok')) {
      if (mounted && _marketplaceFinanceGapMessage.isNotEmpty) {
        setState(() => _marketplaceFinanceGapMessage = '');
      }
      return;
    }

    final cacheKey = 'marketplace_gap:$startKey:$endKey:$mktKey:$accKey';
    if (_financeLoadCache.containsKey(cacheKey)) {
      final cached = _text(_financeLoadCache[cacheKey], '');
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _marketplaceFinanceGapMessage = cached);
      }
      return;
    }

    try {
      final nextDate =
          _toDateParam(_dateOnly(_end).add(const Duration(days: 1)));
      final startWib = '${_toDateParam(_dateOnly(_start))}T00:00:00+07:00';
      final nextWib = '${nextDate}T00:00:00+07:00';
      final accountId = _accountUuidParam();

      dynamic orderQuery = _client
          .from('marketplace_orders')
          .select('marketplace_order_id')
          .gte('order_created_at', startWib)
          .lt('order_created_at', nextWib);
      if (mktKey != null && mktKey != 'all') {
        orderQuery = orderQuery.eq('marketplace', mktKey);
      }
      if (accountId != null) {
        orderQuery = orderQuery.eq('marketplace_account_id', accountId);
      }
      orderQuery = orderQuery.limit(1);
      final orderRows = _asList(await orderQuery);

      dynamic financeQuery = _client
          .from('marketplace_finance_reports')
          .select('finance_report_id')
          .gte('period_start', startKey)
          .lte('period_start', endKey);
      if (mktKey != null && mktKey != 'all') {
        financeQuery = financeQuery.eq('marketplace', mktKey);
      }
      if (accountId != null) {
        financeQuery = financeQuery.eq('marketplace_account_id', accountId);
      }
      financeQuery = financeQuery.limit(1);
      final financeRows = _asList(await financeQuery);

      final message = orderRows.isNotEmpty && financeRows.isEmpty
          ? '${mktKey != null ? mktKey.toUpperCase() : "Marketplace"}: order ada, settlement finance belum masuk'
          : '';
      _financeLoadCache[cacheKey] = message;
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _marketplaceFinanceGapMessage = message);
      }
    } catch (error) {
      debugPrint('Finance marketplace gap hint failed: $error');
    }
  }

  Future<void> _load({bool ignoreLocalCache = false}) async {
    if (!mounted) return;
    _normalizeCurrentFinanceFilters();

    if (ignoreLocalCache) {
      _activeFinanceRequests.clear();
      _financeLoadCache.clear();
    }

    final loadSerial = ++_financeLoadSerial;
    final requestStartKey = _toDateParam(_start);
    final requestEndKey = _toDateParam(_end);
    final requestMarketplaceKey =
        _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
    final requestAccountKey = _accountFilter;

    bool isCurrentFinanceLoad() {
      return mounted &&
          loadSerial == _financeLoadSerial &&
          _toDateParam(_start) == requestStartKey &&
          _toDateParam(_end) == requestEndKey &&
          (_normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all') ==
              requestMarketplaceKey &&
          _accountFilter == requestAccountKey;
    }

    setState(() {
      _loading = true;
      _error = null;
      _lastSnapshotStats = '';
      _lastSkuDebugProof = '';
      _lastSkuRpcRowCount = 0;
      _lastSkuParsedRowCount = 0;
      _lastSkuMergedRowCount = 0;
      _lastSkuRenderedRowCount = 0;
      _marketplaceFinanceGapMessage = '';
      _sampleFreeLoaded = false;
      _sampleFreeLoading = false;
      _sampleFreeError = null;
      _sampleFreeDetailsLoaded = false;
      _sampleFreeDetailsLoading = false;
      _sampleFreeDetailsError = null;
      _expandedReconciliations.clear();
      _operationalCostsLoaded = false;
      _operationalCostsLoading = false;
      _operationalCostsError = null;
      _profitLossLoaded = false;
      _profitLossLoading = false;
      _profitLossError = null;
      _abnormalLoadError = null;

      // Jangan tampilkan angka periode lama ketika user ganti filter.
      // Lebih baik kosong saat loading daripada laporan keuangan periode lain.
      _summary = <String, dynamic>{};
      _sources = [];
      _approvedPurchases = [];
      _byMarketplace = [];
      _bySku = [];
      _skuPage = 1;
      _skuServerPageLoaded = 1;
      _skuLoaded = false;
      _skuLoadingFirstPage = false;
      _skuHasMoreServerRows = true;
      _skuLoadingMore = false;
      _skuUnpaidCountMap.clear();
      _skuPaidCountMap.clear();
      _skuReturnedCountMap.clear();
      _cashFlow = [];
      _cashOpeningBalances = [];
      _cashAdjustments = [];
      _marketplaceWithdrawals = [];
      _withdrawalAllocations = [];
      _expenses = [];
      _profitLoss = [];
      _sampleFreeOrders = [];
      _serverAbnormales = [];
      _abnormalTotal = 0;
    });

    var hasLocalSnapshot = false;
    try {
      await FinanceLocalCache.cleanup();
      await _loadCurrentRole();
      if (!isCurrentFinanceLoad()) return;
      await _loadMarketplaceBootstrapUiStatus();
      if (!isCurrentFinanceLoad()) return;
      if (!_canAccessFinance) {
        if (!mounted) return;
        setState(() {
          _error = 'Akses finance hanya untuk Finance dan Super Admin.';
          _loading = false;
        });
        return;
      }
      await _loadFinanceAutoSyncSetting(showError: false);
      if (!isCurrentFinanceLoad()) return;
      await _loadDispatcherSnapshot();
      if (!isCurrentFinanceLoad()) return;

      _marketplaceFilter =
          _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
      final fallbackAccounts = await _fetchMarketplaceAccounts();
      if (!isCurrentFinanceLoad()) return;
      final localKey = _financeSnapshotLocalKey();
      final cached =
          ignoreLocalCache ? null : await _readFinanceSnapshotLocalAny();
      if (!isCurrentFinanceLoad()) return;
      if (cached != null && mounted && !_isFinanceSnapshotEmpty(cached)) {
        hasLocalSnapshot = true;
        if (!isCurrentFinanceLoad()) return;
        await _applyFinanceSnapshotData(
          cached,
          fallbackAccounts,
          includeOperationalExpenses: false,
          includeSupplementalSku: false,
        );
        setState(() => _loading = false);
      }

      final snapshotParams = {
        'p_start': _toDateParam(_start),
        'p_end': _toDateParam(_end),
        'p_marketplace': _marketplaceRpcParam(accounts: fallbackAccounts),
        'p_account_id': _accountUuidParam(),
      };
      unawaited(_loadMarketplaceFinanceGapHint());

      if (!hasLocalSnapshot) {
        // No local cache: run sync refresh
        await _refreshFinanceCacheForSelectedPeriod();
        var response = await _loadFinanceSnapshot(snapshotParams);
        var data = _asMap(response);
        if (_isFinanceSnapshotEmpty(data)) {
          if (mounted) {
            _setMessage(
                'Data laporan periode ini belum siap. Auto finance sedang mengejar data periode ini di background.');
          }
          await _loadPersistedFinanceProgressFromDb();
          return;
        }
        await FinanceLocalCache.writeJson(localKey, data);
        if (!isCurrentFinanceLoad()) return;
        await _applyFinanceSnapshotData(
          data,
          fallbackAccounts,
          includeOperationalExpenses: false,
          includeSupplementalSku: false,
        );
      } else {
        // Has local cache: load background refresh
        unawaited(Future(() async {
          try {
            await _refreshFinanceCacheForSelectedPeriod();
            final response = await _loadFinanceSnapshot(snapshotParams);
            final data = _asMap(response);
            if (!_isFinanceSnapshotEmpty(data)) {
              await FinanceLocalCache.writeJson(localKey, data);
              if (!isCurrentFinanceLoad()) return;
              await _applyFinanceSnapshotData(
                data,
                fallbackAccounts,
                includeOperationalExpenses: false,
                includeSupplementalSku: false,
              );
              if (mounted) {
                setState(() {});
              }
            }
          } catch (_) {}
        }));
      }

      if (!isCurrentFinanceLoad() || !mounted) return;
      await _loadPersistedFinanceProgressFromDb();
      await _loadOperationalCostsSupplemental();
      unawaited(_loadAbnormalesPage(silent: true, resetPage: true));
      unawaited(_loadSampleFreeOrdersSupplemental());
      unawaited(_loadSampleFreeOrdersDetails(force: true));
    } catch (e) {
      if (!isCurrentFinanceLoad()) return;
      if (!mounted) return;
      if (!hasLocalSnapshot) {
        setState(() => _error = _cleanError(e));
      } else {
        _setMessage(
            'Cache lokal dipakai. Update server gagal: ${_cleanError(e)}');
      }
    } finally {
      if (isCurrentFinanceLoad()) setState(() => _loading = false);
    }
  }

  Future<void> _loadSampleFreeOrdersSupplemental() async {
    final startKey = _toDateParam(_start);
    final endKey = _toDateParam(_end);
    final mktKey = _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
    final accKey = _accountFilter;
    final cacheKey =
        'sample_free_supplemental:$startKey:$endKey:$mktKey:$accKey';

    if (_financeLoadCache.containsKey(cacheKey)) {
      final cachedData = _financeLoadCache[cacheKey];
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() {
          final nextSummary = Map<String, dynamic>.from(_summary);
          final summary = _asMap(cachedData['summary']);
          final sourceBreakdown = _asMap(summary['source_breakdown']);
          summary.forEach((key, value) {
            if (value != null) nextSummary[key] = value;
          });
          sourceBreakdown.forEach((key, value) {
            if (value != null) nextSummary[key] = value;
          });
          if (summary['sample_order_count'] != null) {
            nextSummary['abnormal_sample_count'] =
                summary['sample_order_count'];
          }
          _summary = nextSummary;
          _sampleFreeOrders = [];
          _sampleFreeLoaded = true;
          _sampleFreeLoading = false;
          _sampleFreeError = null;
        });
      }
      return;
    }

    if (_activeFinanceRequests.containsKey(cacheKey)) {
      await _activeFinanceRequests[cacheKey];
      return;
    }

    if (mounted) {
      setState(() {
        _sampleFreeLoading = true;
        _sampleFreeError = null;
      });
    }

    final future = () async {
      try {
        final response = await _client.rpc(
          'finance_sample_order_counts',
          params: {
            'p_start': startKey,
            'p_end': endKey,
            'p_marketplace': _marketplaceRpcParam(),
            'p_account_id': _accountUuidParam(),
            'p_count_only': true,
          },
        ).timeout(const Duration(seconds: 20));
        return response;
      } catch (e) {
        debugPrint('finance_sample_order_counts RPC error: $e');
        rethrow;
      }
    }();

    _activeFinanceRequests[cacheKey] = future;

    try {
      final response = await future;
      final data = _asMap(response);
      _financeLoadCache[cacheKey] = data;

      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        final summary = _asMap(data['summary']);
        final sourceBreakdown = _asMap(summary['source_breakdown']);
        setState(() {
          final nextSummary = Map<String, dynamic>.from(_summary);
          summary.forEach((key, value) {
            if (value != null) nextSummary[key] = value;
          });
          sourceBreakdown.forEach((key, value) {
            if (value != null) nextSummary[key] = value;
          });
          if (summary['sample_order_count'] != null) {
            nextSummary['abnormal_sample_count'] =
                summary['sample_order_count'];
          }
          _summary = nextSummary;
          _sampleFreeOrders = [];
          _sampleFreeLoaded = true;
          _sampleFreeError = null;
        });
      }
    } catch (error) {
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _sampleFreeError = _cleanError(error));
      }
      debugPrint('Finance sample/free supplemental load failed: $error');
    } finally {
      _activeFinanceRequests.remove(cacheKey);
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _sampleFreeLoading = false);
      }
    }
  }

  Future<void> _loadSampleFreeOrdersDetails({bool force = false}) async {
    final startKey = _toDateParam(_start);
    final endKey = _toDateParam(_end);
    final mktKey = _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
    final accKey = _accountFilter;
    final cacheKey = 'sample_free_details:$startKey:$endKey:$mktKey:$accKey';

    if (!force && _financeLoadCache.containsKey(cacheKey)) {
      final cachedRows =
          _financeLoadCache[cacheKey] as List<Map<String, dynamic>>;
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() {
          _sampleFreeOrders = cachedRows;
          _sampleFreeDetailsLoaded = true;
          _sampleFreeDetailsLoading = false;
          _sampleFreeDetailsError = null;
        });
      }
      return;
    }

    if (_activeFinanceRequests.containsKey(cacheKey)) {
      await _activeFinanceRequests[cacheKey];
      return;
    }

    if (mounted) {
      setState(() {
        _sampleFreeDetailsLoading = true;
        _sampleFreeDetailsError = null;
      });
    }

    final future = () async {
      try {
        final response = await _client.rpc(
          'finance_sample_order_counts',
          params: {
            'p_start': startKey,
            'p_end': endKey,
            'p_marketplace': _marketplaceRpcParam(),
            'p_account_id': _accountUuidParam(),
            'p_count_only': false,
            'p_page': 1,
            'p_page_size': 200,
          },
        ).timeout(const Duration(seconds: 20));
        return response;
      } catch (e) {
        debugPrint('finance_sample_order_counts details RPC error: $e');
        rethrow;
      }
    }();

    _activeFinanceRequests[cacheKey] = future;

    try {
      final response = await future;
      final data = _asMap(response);
      final rows = _normalizeAbnormalRows(
        _asList(data['sample_orders'] ?? data['rows'])
            .whereType<Map>()
            .map((item) {
          final row = Map<String, dynamic>.from(item);
          row['abnormal_status'] = 'SAMPLE_FREE';
          row['payout_status'] = row['payout_status'] ?? 'SAMPLE_FREE';
          row['finance_status'] = row['finance_status'] ?? 'SAMPLE_FREE';
          row['message'] = _text(
            row['message'] ?? row['note'],
            'Sample/gratis sesuai filter. Tidak masuk omzet normal.',
          );
          row['category'] = row['category'] ?? 'sample_free';
          return row;
        }).toList(),
      );

      _financeLoadCache[cacheKey] = rows;

      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() {
          _sampleFreeOrders = rows;
          _sampleFreeDetailsLoaded = true;
          _sampleFreeDetailsError = null;
        });
      }
    } catch (error) {
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _sampleFreeDetailsError = _cleanError(error));
      }
      debugPrint('Finance sample/free details load failed: $error');
    } finally {
      _activeFinanceRequests.remove(cacheKey);
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _sampleFreeDetailsLoading = false);
      }
    }
  }

  Future<void> _loadOperationalCostsSupplemental() async {
    final startKey = _toDateParam(_start);
    final endKey = _toDateParam(_end);
    final mktKey = _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
    final accKey = _accountFilter;
    final cacheKey =
        'operational_costs_supplemental:$startKey:$endKey:$mktKey:$accKey';

    if (_financeLoadCache.containsKey(cacheKey)) {
      final cached = _financeLoadCache[cacheKey] as Map<String, dynamic>;
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() {
          _expenses = cached['expenses'] as List<Map<String, dynamic>>;
          _approvedPurchases =
              cached['approvedPurchases'] as List<Map<String, dynamic>>;
          _summary = cached['summary'] as Map<String, dynamic>;
          _cashFlow = cached['cashFlow'] as List<Map<String, dynamic>>;
          _profitLoss = cached['profitLoss'] as List<Map<String, dynamic>>;
          _expenseCategoryOptions =
              cached['expenseCategoryOptions'] as List<String>;
          _operationalCostsLoaded = true;
          _operationalCostsLoading = false;
          _operationalCostsError = null;
        });
      }
      return;
    }

    if (_activeFinanceRequests.containsKey(cacheKey)) {
      try {
        await _activeFinanceRequests[cacheKey];
      } catch (_) {}
      if (_financeLoadCache.containsKey(cacheKey)) {
        final cached = _financeLoadCache[cacheKey] as Map<String, dynamic>;
        if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
          setState(() {
            _expenses = cached['expenses'] as List<Map<String, dynamic>>;
            _approvedPurchases =
                cached['approvedPurchases'] as List<Map<String, dynamic>>;
            _summary = cached['summary'] as Map<String, dynamic>;
            _cashFlow = cached['cashFlow'] as List<Map<String, dynamic>>;
            _profitLoss = cached['profitLoss'] as List<Map<String, dynamic>>;
            _expenseCategoryOptions =
                cached['expenseCategoryOptions'] as List<String>;
            _operationalCostsLoaded = true;
            _operationalCostsLoading = false;
            _operationalCostsError = null;
          });
        }
      }
      return;
    }

    if (mounted) {
      setState(() {
        _operationalCostsLoading = true;
        _operationalCostsError = null;
      });
    }

    final future = () async {
      try {
        final liveExpenses = await _fetchOperationalExpensesPeriod()
            .timeout(const Duration(seconds: 12));
        final livePurchases = await _fetchApprovedPurchasesPeriod()
            .timeout(const Duration(seconds: 12));
        return {
          'liveExpenses': liveExpenses,
          'livePurchases': livePurchases,
        };
      } catch (e) {
        debugPrint('Fetch operational expenses / purchases failed: $e');
        rethrow;
      }
    }();

    _activeFinanceRequests[cacheKey] = future;

    try {
      final results = await future;
      final liveExpenses =
          results['liveExpenses'] as List<Map<String, dynamic>>;
      final livePurchases =
          results['livePurchases'] as List<Map<String, dynamic>>;

      if (!mounted) return;

      final normalizedExpenses = _dedupeExpenseRows(<Map<String, dynamic>>[
        ..._expenses,
        ...liveExpenses,
      ]).where((row) => !_isSyntheticExpenseRow(row)).toList(growable: false);
      final approvedPurchases = _dedupeByStableKey(livePurchases);
      final nextSummary = _summaryWithLiveCosts(
        _summary,
        normalizedExpenses,
        approvedPurchases,
      );

      final cashFlowData = _cashFlowRowsFromSummary(nextSummary);
      final profitLossData = <Map<String, dynamic>>[
        ..._profitLossRowsFromSummary(nextSummary, _profitLoss)
            .where((row) => !_isBackendGeneratedProfitLossBreakdownRow(row)),
        ..._profitLossExpenseDetailRows(normalizedExpenses),
      ];
      final categoryOptions = _mergeExpenseCategories(normalizedExpenses);

      final cacheEntry = {
        'expenses': normalizedExpenses,
        'approvedPurchases': approvedPurchases,
        'summary': nextSummary,
        'cashFlow': cashFlowData,
        'profitLoss': profitLossData,
        'expenseCategoryOptions': categoryOptions,
      };

      _financeLoadCache[cacheKey] = cacheEntry;

      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() {
          _expenses = normalizedExpenses;
          _approvedPurchases = approvedPurchases;
          _summary = nextSummary;
          _cashFlow = cashFlowData;
          _profitLoss = profitLossData;
          _expenseCategoryOptions = categoryOptions;
          _operationalCostsLoaded = true;
          _operationalCostsError = null;
        });
      }
    } catch (error) {
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _operationalCostsError = _cleanError(error));
      }
      debugPrint('Finance operational costs supplemental load failed: $error');
    } finally {
      _activeFinanceRequests.remove(cacheKey);
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _operationalCostsLoading = false);
      }
    }
  }

  Future<void> _loadProfitLossSupplemental() async {
    final startKey = _toDateParam(_start);
    final endKey = _toDateParam(_end);
    final mktKey = _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
    final accKey = _accountFilter;
    final cacheKey =
        'profit_loss_supplemental:$startKey:$endKey:$mktKey:$accKey';

    if (_financeLoadCache.containsKey(cacheKey)) {
      final cached = _financeLoadCache[cacheKey] as Map<String, dynamic>;
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() {
          _summary = cached['summary'] as Map<String, dynamic>;
          _profitLoss = cached['profitLoss'] as List<Map<String, dynamic>>;
          _profitLossByMarketplace =
              cached['profitLossByMarketplace'] as List<Map<String, dynamic>>;
          _profitLossLoaded = true;
          _profitLossLoading = false;
          _profitLossError = null;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _profitLossLoading = true;
        _profitLossError = null;
      });
    }

    try {
      if (!mounted) return;
      var expenseRows = List<Map<String, dynamic>>.from(_expenses);
      var purchaseRows = List<Map<String, dynamic>>.from(_approvedPurchases);
      if (!_operationalCostsLoaded) {
        try {
          final liveExpenses = await _fetchOperationalExpensesPeriod()
              .timeout(const Duration(seconds: 12));
          final livePurchases = await _fetchApprovedPurchasesPeriod()
              .timeout(const Duration(seconds: 12));
          expenseRows = _dedupeExpenseRows(liveExpenses)
              .where((row) => !_isSyntheticExpenseRow(row))
              .toList(growable: false);
          purchaseRows = _dedupeByStableKey(livePurchases);
        } catch (error) {
          debugPrint('Profit/Loss live cost refresh skipped: $error');
        }
      }
      final displaySummary = _summaryWithLiveCosts(
        _summary,
        expenseRows,
        purchaseRows,
      );
      final byMarketplace = _enrichMarketplaceRowsHppFromSku(
        _marketplaceRowsWithFinanceAliases(
          _profitLossByMarketplace.isNotEmpty
              ? _profitLossByMarketplace
              : _byMarketplace,
        ),
        _bySku,
        summary: displaySummary,
      );
      final profitLossData = <Map<String, dynamic>>[
        ..._profitLossRowsFromSummary(displaySummary)
            .where((row) => !_isBackendGeneratedProfitLossBreakdownRow(row)),
        ..._profitLossExpenseDetailRows(_expenses),
      ];

      final cacheEntry = {
        'summary': displaySummary,
        'profitLoss': profitLossData,
        'profitLossByMarketplace': byMarketplace,
      };

      _financeLoadCache[cacheKey] = cacheEntry;

      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() {
          _summary = displaySummary;
          if (expenseRows.isNotEmpty) _expenses = expenseRows;
          if (purchaseRows.isNotEmpty) _approvedPurchases = purchaseRows;
          _profitLoss = profitLossData;
          if (byMarketplace.isNotEmpty) {
            _profitLossByMarketplace = byMarketplace;
          }
          _profitLossLoaded = true;
          _profitLossError = null;
        });
      }
    } catch (error) {
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _profitLossError = _cleanError(error));
      }
      debugPrint('FINANCE_PROFIT_LOSS_SUMMARY_REFRESH_FAILED: $error');
    } finally {
      if (mounted && _isCurrentFilter(startKey, endKey, mktKey, accKey)) {
        setState(() => _profitLossLoading = false);
      }
    }
  }

  void _navigateToSampleFreeAbnormal(BuildContext context) {
    setState(() {
      _abnormalStatusFilter = 'sample_free';
      _abnormalPage = 1;
    });
    _refreshAbnormalTab(resetPage: true);
    DefaultTabController.maybeOf(context)?.animateTo(6);
  }

  String _skuPayoutCountCleanKey(dynamic value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text == '-' || text == 'null') return '';
    return text;
  }

  String _skuPayoutCountCompositeKey(dynamic marketplaceSku, dynamic localSku) {
    final sku = _skuPayoutCountCleanKey(marketplaceSku);
    final local = _skuPayoutCountCleanKey(localSku);
    return '$sku|$local';
  }

  dynamic _firstSkuPayoutCountValue(
    Map<String, dynamic> row,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = row[key];
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != '-' && text.toLowerCase() != 'null') {
        return value;
      }
    }
    return null;
  }

  Future<Map<String, Map<String, dynamic>>>
      _fetchSkuPayoutCountSummaryMap() async {
    try {
      final response = await _client.rpc(
        'finance_sku_payout_count_summary',
        params: {
          'p_start': _toDateParam(_start),
          'p_end': _toDateParam(_end),
          'p_marketplace': _marketplaceRpcParam(),
          'p_account_id': _accountUuidParam(),
        },
      );

      if (response is! Map) return <String, Map<String, dynamic>>{};

      final map = Map<String, dynamic>.from(response);
      final rawRows = map['rows'];
      if (rawRows is! List) return <String, Map<String, dynamic>>{};

      final out = <String, Map<String, dynamic>>{};

      void addToMapKey(String key, Map<String, dynamic> row) {
        final cleanKey = key.trim().toLowerCase();
        if (cleanKey.isEmpty || cleanKey == '|' || cleanKey == '-') return;

        final existing = out[cleanKey];
        if (existing == null) {
          out[cleanKey] = Map<String, dynamic>.from(row);
        } else {
          existing['paid_qty'] = _num(existing['paid_qty']) + _num(row['paid_qty']);
          existing['settled_qty'] = _num(existing['settled_qty']) + _num(row['settled_qty']);
          existing['paid_rows'] = _num(existing['paid_rows']) + _num(row['paid_rows']);
          existing['unpaid_qty'] = _num(existing['unpaid_qty']) + _num(row['unpaid_qty']);
          existing['qty_unpaid'] = _num(existing['qty_unpaid']) + _num(row['qty_unpaid']);
          existing['unpaid_rows'] = _num(existing['unpaid_rows']) + _num(row['unpaid_rows']);
          existing['unpaid_count'] = _num(existing['unpaid_count']) + _num(row['unpaid_count']);
          existing['qty_returned'] = _num(existing['qty_returned']) + _num(row['qty_returned'] ?? row['returned_qty']);
          existing['returned_qty'] = _num(existing['returned_qty']) + _num(row['returned_qty'] ?? row['qty_returned']);
          existing['hpp_return'] = _num(existing['hpp_return']) + _num(row['hpp_return'] ?? row['hpp_retur'] ?? row['return_hpp']);
          existing['all_qty'] = _num(existing['all_qty']) + _num(row['all_qty']);
          existing['qty_total'] = _num(existing['qty_total']) + _num(row['qty_total']);
          existing['order_count'] = _num(existing['order_count']) + _num(row['order_count']);
          existing['payout_total'] = _num(existing['payout_total']) + _num(row['payout_total']);
          existing['payout_amount'] = _num(existing['payout_amount']) + _num(row['payout_amount']);
          existing['gross_sales'] = _num(existing['gross_sales']) + _num(row['gross_sales']);
          existing['hpp_total'] = _num(existing['hpp_total']) +
              _numFirstNonZero([
                row['paid_hpp_total'],
                row['settled_hpp_total'],
                row['hpp_total'],
                row['total_hpp'],
                row['hpp_cair'],
                row['hpp_settled'],
                row['hpp_amount'],
                row['hpp'],
              ]);
        }
      }

      for (final item in rawRows) {
        if (item is! Map) continue;
        final row = Map<String, dynamic>.from(item);

        final marketplaceSku = _firstSkuPayoutCountValue(row, const [
          'marketplace_sku_id',
          'marketplace_sku',
          'sku_marketplace',
        ]);

        final localSku = _firstSkuPayoutCountValue(row, const [
          'local_sku',
          'sku_local',
          'sku',
        ]);

        final skuKey = _skuPayoutCountCleanKey(marketplaceSku);
        final localKey = _skuPayoutCountCleanKey(localSku);
        final compositeKey =
            _skuPayoutCountCompositeKey(marketplaceSku, localSku);

        if (compositeKey.trim() != '|') {
          addToMapKey(compositeKey, row);
        }
        if (skuKey.isNotEmpty) {
          addToMapKey('$skuKey|', row);
        }
        if (localKey.isNotEmpty) {
          addToMapKey('|$localKey', row);
          addToMapKey(localKey, row);
        }
      }

      return out;
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  Map<String, dynamic> _mergeSkuPayoutCountSummaryRow(
    Map<String, dynamic> row,
    Map<String, Map<String, dynamic>> summaryMap,
  ) {
    final marketplaceSku = _firstSkuPayoutCountValue(row, const [
      'marketplace_sku_id',
      'marketplace_sku',
      'sku_marketplace',
    ]);

    final localSku = _firstSkuPayoutCountValue(row, const [
      'local_sku',
      'sku_local',
      'sku',
    ]);

    final compositeKey = _skuPayoutCountCompositeKey(marketplaceSku, localSku);
    final skuOnlyKey = '${_skuPayoutCountCleanKey(marketplaceSku)}|';
    final localOnlyKey = '|${_skuPayoutCountCleanKey(localSku)}';
    final localKey = _skuPayoutCountCleanKey(localSku);

    final summary = summaryMap[compositeKey] ??
        summaryMap[skuOnlyKey] ??
        summaryMap[localOnlyKey] ??
        summaryMap[localKey];
    if (summary == null) return row;

    final paidQty = _numFirstNonZero([
      summary['paid_qty'],
      summary['settled_qty'],
      summary['paid_rows'],
      summary['paid_total'],
    ]).round();

    final unpaidQty = _numFirstNonZero([
      summary['unpaid_qty'],
      summary['qty_unpaid'],
      summary['unpaid_rows'],
      summary['unpaid_total'],
    ]).round();

    final returnedQty = _numFirstNonZero([
      summary['qty_returned'],
      summary['returned_qty'],
      summary['qty_batal'],
      summary['batal_qty'],
      summary['returned_rows'],
      summary['returned_total'],
    ]).round();

    final visibleQty = paidQty + unpaidQty + returnedQty;
    final merged = Map<String, dynamic>.from(row);

    merged['paid_qty'] = paidQty;
    merged['settled_qty'] = paidQty;
    merged['qty_paid'] = paidQty;
    merged['positive_payout_qty'] = paidQty;

    merged['unpaid_qty'] = unpaidQty;
    merged['qty_unpaid'] = unpaidQty;
    merged['pending_payout_qty'] = unpaidQty;
    merged['pending_payout_qty_total'] = unpaidQty;

    if (returnedQty > 0) {
      merged['qty_returned'] = returnedQty;
      merged['returned_qty'] = returnedQty;
    }

    if (visibleQty > 0) {
      merged['qty'] = visibleQty;
      merged['quantity'] = visibleQty;
      merged['qty_total'] = visibleQty;
      merged['total_qty'] = visibleQty;
    }

    merged['sku_count_source'] = 'finance_sku_payout_count_summary';

    return merged;
  }

  Future<void> _overlaySkuPayoutCountSummaryFromServer() async {
    if (_bySku.isEmpty) return;

    try {
      final summaryMap = await _fetchSkuPayoutCountSummaryMap();
      if (!mounted || summaryMap.isEmpty) return;

      final mergedRows = _bySku
          .map((row) => _mergeSkuPayoutCountSummaryRow(row, summaryMap))
          .toList(growable: false);

      if (!mounted) return;
      setState(() {
        _bySku = mergedRows;
        _skuPayoutCountSummaryMap = summaryMap;
      });
    } catch (e) {
      // Overlay hitungan settled/belum payout hanya data pendukung.
      // Jangan pernah bikin laporan utama gagal dimuat gara-gara RPC overlay
      // belum ada, beda signature, timeout, atau schema cache Supabase belum refresh.
      debugPrint('FINANCE_SKU_PAYOUT_COUNT_OVERLAY_SKIPPED: $e');
      return;
    }
  }

  double _numFirstNonZero(Iterable<dynamic> values) {
    for (final value in values) {
      final n = _num(value);
      if (n != 0) return n;
    }
    return 0;
  }

  int _qtyFromOrderRows(List<Map<String, dynamic>> rows) {
    var total = 0;
    for (final row in rows) {
      final qty = _numFirstNonZero([
        row['qty_order'],
        row['quantity'],
        row['qty'],
        row['item_qty'],
        row['qty_item'],
      ]).round();
      total += qty > 0 ? qty : 1;
    }
    return total;
  }

  double _purchaseAmount(Map<String, dynamic> row) => _numFirstNonZero([
        row['total_pembelian'],
        row['total_harga'],
        row['grand_total'],
        row['expense_total'],
        row['total_amount'],
        row['subtotal'],
        row['total_price'],
        row['amount_total'],
        row['nominal'],
        row['amount'],
        row['total'],
        _numFirstNonZero([row['harga'], row['harga_satuan'], row['price']]) *
            _numFirstNonZero([
              row['qty'],
              row['quantity'],
              row['jumlah'],
              row['qty_pembelian'],
              row['jumlah_barang'],
            ]),
      ]);

  int _purchaseQty(Map<String, dynamic> row) => _numFirstNonZero([
        row['qty'],
        row['quantity'],
        row['jumlah'],
        row['qty_pembelian'],
        row['jumlah_barang'],
        row['total_qty'],
      ]).round();

  double _negativePayoutTotal() {
    final absoluteDirect = _numFirstNonZero([
      _summary['payout_minus_total_abs'],
      _summary['negative_payout_total_abs'],
      _summary['minus_payout_total_abs'],
    ]);
    if (absoluteDirect != 0) return absoluteDirect.abs();

    final signedDirect = _numFirstNonZero([
      _summary['payout_minus_total'],
      _summary['negative_payout_total'],
      _summary['minus_payout_total'],
      _summary['total_negative_payout'],
    ]);
    if (signedDirect != 0) return signedDirect.abs();

    var total = 0.0;
    for (final row in _bySku) {
      final n = _numFirstNonZero([
        row['payout_minus_total_abs'],
        row['negative_payout_total_abs'],
        row['minus_payout_total_abs'],
      ]);
      if (n != 0) {
        total += n.abs();
        continue;
      }
      final signed = _num(row['negative_payout_total'] ??
          row['minus_payout_total'] ??
          row['payout_minus_total']);
      if (signed < 0) total += signed.abs();
    }
    if (total != 0) return total;

    for (final row in _abnormals) {
      final n = _numFirstNonZero([
        row['payout_minus_total_abs'],
        row['negative_payout_total_abs'],
        row['minus_payout_total_abs'],
        row['payout_delta'],
        row['difference_amount'],
        row['selisih'],
        row['payout_amount'],
        row['payout_total'],
        row['payout'],
      ]);
      if (n < 0) total += n.abs();
      if (n > 0 &&
          _text(row['abnormal_status'] ?? row['status'])
              .toUpperCase()
              .contains('NEGATIVE')) {
        total += n.abs();
      }
    }
    return total;
  }

  double _unpaidEstimatedHppTotal() {
    final direct = _numFirstNonZero([
      _summary['estimated_unpaid_hpp'],
      _summary['hpp_belum_payout'],
      _summary['unpaid_hpp'],
      _summary['unpaid_hpp_total'],
      _summary['unpaid_estimated_hpp_total'],
      _summary['pending_hpp_total'],
      _summary['hpp_unpaid_total'],
      _summary['estimated_unpaid_hpp_total'],
    ]);
    if (direct != 0) return direct;

    var total = 0.0;
    for (final row in _bySku) {
      final unpaidQty = _numFirstNonZero([
        row['unpaid_qty'],
        row['pending_payout_qty'],
        row['qty_belum_payout'],
      ]);
      if (unpaidQty <= 0) continue;
      final hpp = _numFirstNonZero([
        row['hpp_per_item'],
        row['hpp_item'],
        row['hpp_default'],
        row['hpp'],
      ]);
      total += unpaidQty * hpp;
    }
    if (total != 0) return total;

    final estimated = _numFirstNonZero([
      _summary['estimated_hpp_total'],
      _summary['hpp_estimated_total'],
      _summary['total_estimated_hpp'],
    ]);
    final settled = _numFirstNonZero([
      _summary['hpp_total'],
      _summary['settled_hpp_total'],
      _summary['total_hpp'],
    ]);
    final diff = estimated - settled;
    return diff > 0 ? diff : 0;
  }

  List<Map<String, dynamic>> _expenseRowsWithSummaryFallback(
      List<Map<String, dynamic>> rows, Map<String, dynamic> summary) {
    if (rows.isNotEmpty) return rows;
    final operational = _num(
        summary['operational_cost_total'] ?? summary['operational_expense']);
    if (operational <= 0) return rows;
    return [
      {
        'expense_id': 'summary_operational_total',
        'category': 'Biaya operasional',
        'description': 'Total biaya operasional periode ini',
        'amount': operational,
        'expense_date': _toDateParam(_end),
        'status': 'paid',
      }
    ];
  }

  List<Map<String, dynamic>> _dedupeExpenseRows(
      List<Map<String, dynamic>> rows) {
    final deduped = <String, Map<String, dynamic>>{};
    final seenIds = <String>{};
    final seenSignatures = <String>{};

    for (final source in rows) {
      if (_isPurchaseExpenseRow(source) || _isSyntheticExpenseRow(source)) {
        continue;
      }

      final row = Map<String, dynamic>.from(source);
      final amount = _numFirstNonZero(
          [row['amount'], row['total_amount'], row['expense_total']]);
      if (amount.abs() <= 0.49) continue;

      final expenseId = _expenseId(row).trim();
      if (expenseId.isNotEmpty && seenIds.contains(expenseId)) {
        continue;
      }

      final stableDate = _date(row['expense_date'] ??
          row['paid_at'] ??
          row['date'] ??
          row['created_at']);
      final category = _text(row['category'], '').trim().toLowerCase();
      final note =
          _text(row['note'] ?? row['description'], '').trim().toLowerCase();
      final signature =
          '$stableDate|$category|$note|${amount.toStringAsFixed(2)}';
      if (seenSignatures.contains(signature)) {
        continue;
      }

      final key = _isUuid(expenseId)
          ? 'id:$expenseId'
          : 'manual:$stableDate|$category|${amount.toStringAsFixed(0)}|$note';

      final existing = deduped[key];
      if (existing == null ||
          (!_isUuid(_expenseId(existing)) && _isUuid(expenseId))) {
        deduped[key] = row;
        if (expenseId.isNotEmpty) {
          seenIds.add(expenseId);
        }
        seenSignatures.add(signature);
      }
    }

    final out = deduped.values.toList();
    out.sort((a, b) {
      final ad =
          _parseDate(a['expense_date'] ?? a['paid_at'] ?? a['created_at']) ??
              DateTime.fromMillisecondsSinceEpoch(0);
      final bd =
          _parseDate(b['expense_date'] ?? b['paid_at'] ?? b['created_at']) ??
              DateTime.fromMillisecondsSinceEpoch(0);
      final cmp = bd.compareTo(ad);
      if (cmp != 0) return cmp;
      return _text(a['category']).compareTo(_text(b['category']));
    });
    return out;
  }

  List<Map<String, dynamic>> _skuRowsFromSnapshot(Map<String, dynamic> data) {
    final grouped = <String, Map<String, dynamic>>{};

    void mergeRow(Map<String, dynamic> source, {required String bucket}) {
      final row = Map<String, dynamic>.from(source);
      final key = _skuSnapshotKey(row);
      final target = grouped.putIfAbsent(key, () {
        final created = Map<String, dynamic>.from(row);
        created['order_details'] = <Map<String, dynamic>>[];
        return created;
      });

      for (final entry in row.entries) {
        final current = target[entry.key];
        if (current == null || (current is String && current.trim().isEmpty)) {
          target[entry.key] = entry.value;
        }
      }

      final existingDetails = target['order_details'];
      final details = existingDetails is List ? existingDetails : <dynamic>[];
      target['order_details'] = details;

      for (final detail in _asList(
          row['order_details'] ?? row['orders'] ?? row['order_refs'])) {
        details.add(detail);
      }

      const orderBuckets = {
        'paid_orders',
        'settled_orders',
        'unpaid_orders',
        'pending_orders',
        'missing_payout_orders'
      };
      for (final nestedBucket in orderBuckets) {
        for (final detail in _asList(row[nestedBucket])) {
          final mergedDetail = <String, dynamic>{
            ...row,
            ...detail,
          };
          details.add(_snapshotOrderDetail(mergedDetail, nestedBucket));
        }
      }

      if (orderBuckets.contains(bucket) || _rowLooksLikeOrderDetail(row)) {
        details.add(_snapshotOrderDetail(row, bucket));
      }
    }

    for (final key in const ['by_sku', 'sku_margin', 'sku']) {
      final rows = _asList(data[key]);
      if (rows.isEmpty) continue;
      for (final row in rows) {
        mergeRow(row, bucket: key);
      }
      break;
    }

    for (final key in const [
      'paid_orders',
      'settled_orders',
      'unpaid_orders',
      'pending_orders',
      'missing_payout_orders',
    ]) {
      for (final row in _asList(data[key])) {
        mergeRow(row, bucket: key);
      }
    }

    return grouped.values.toList();
  }

  String _skuSnapshotKey(Map<String, dynamic> row) {
    final sku = _text(
      row['local_sku'] ??
          row['sku'] ??
          row['product_sku'] ??
          row['seller_sku'] ??
          row['marketplace_seller_sku'],
      '',
    ).trim().toLowerCase();
    final marketplaceSku = _text(
            row['marketplace_sku_id'] ??
                row['marketplace_sku'] ??
                row['sku_id'] ??
                row['external_sku_id'],
            '')
        .trim()
        .toLowerCase();
    final variant = _text(
            row['variant_name'] ??
                row['marketplace_variation_name'] ??
                row['sku_name'],
            '')
        .trim()
        .toLowerCase();
    final product =
        _text(row['product_name'] ?? row['nama_barang'] ?? row['item_name'], '')
            .trim()
            .toLowerCase();
    final account =
        _text(row['marketplace_account_id'] ?? row['account_id'], '')
            .trim()
            .toLowerCase();
    final fallback = _text(
            row['order_id'] ??
                row['order_sn'] ??
                row['external_order_id'] ??
                row['tracking_number'],
            '')
        .trim()
        .toLowerCase();
    final identity = [account, sku, marketplaceSku, variant, product]
        .where((item) => item.isNotEmpty && item != '-')
        .join('|');
    return identity.isNotEmpty
        ? identity
        : (fallback.isNotEmpty ? fallback : 'unknown_sku_${groupedHash(row)}');
  }

  int groupedHash(Map<String, dynamic> row) => row.toString().hashCode;

  bool _rowLooksLikeOrderDetail(Map<String, dynamic> row) {
    for (final key in const [
      'order',
      'order_id',
      'order_sn',
      'external_order_id',
      'remote_order_id',
      'tracking_number',
      'resi',
      'awb',
      'statement_id',
      'statement',
      'finance_statement_id',
    ]) {
      if (_hasNonEmptyKey(row, [key])) return true;
    }
    return false;
  }

  Map<String, dynamic> _snapshotOrderDetail(
      Map<String, dynamic> source, String bucket) {
    final isUnpaidBucket = bucket == 'unpaid_orders' ||
        bucket == 'pending_orders' ||
        bucket == 'missing_payout_orders';
    final detail = Map<String, dynamic>.from(source);
    detail['order'] = source['order'] ??
        source['order_id'] ??
        source['order_sn'] ??
        source['external_order_id'] ??
        source['remote_order_id'];
    detail['resi'] = source['resi'] ??
        source['tracking_number'] ??
        source['tracking_no'] ??
        source['logistics_tracking_number'] ??
        source['tracking_number_from_settlement'] ??
        source['awb'] ??
        source['awb_number'] ??
        source['waybill_no'] ??
        source['shipping_document'];
    detail['order_date'] = source['order_date'] ??
        source['order_created_at'] ??
        source['transaction_time'] ??
        source['paid_at'] ??
        source['created_at'];
    detail['qty'] =
        source['qty'] ?? source['quantity'] ?? source['item_quantity'] ?? 1;
    detail['gross'] = source['gross'] ??
        source['gross_amount'] ??
        source['gross_sales'] ??
        source['gross_total'] ??
        source['expected_amount'] ??
        source['item_gross_amount'];
    detail['payout'] = isUnpaidBucket
        ? 0
        : (source['payout'] ??
            source['payout_amount'] ??
            source['payout_total'] ??
            source['received_amount'] ??
            source['net_received'] ??
            source['net_settlement'] ??
            source['settlement_amount'] ??
            source['paid_amount']);
    detail['hpp'] = source['hpp_total'] ??
        source['hpp_amount'] ??
        source['total_hpp'] ??
        source['hpp'];
    detail['hpp_per_item'] =
        source['hpp_per_item'] ?? source['unit_hpp'] ?? source['hpp_unit'];
    detail['gross_per_item'] =
        source['gross_per_item'] ?? source['unit_gross_amount'];
    detail['payout_per_item'] = isUnpaidBucket
        ? 0
        : (source['payout_per_item'] ??
            source['unit_paid_amount'] ??
            source['unit_payout_amount']);
    detail['source'] = source['source'] ?? bucket;
    detail['payout_status'] = isUnpaidBucket
        ? (bucket == 'missing_payout_orders' ? 'missing' : 'pending')
        : (source['payout_status'] ??
            source['settlement_status'] ??
            source['finance_status'] ??
            'settled');
    detail['payout_reason'] = source['payout_reason'] ??
        source['abnormal_status'] ??
        source['finance_status'];
    detail['statement_id'] = isUnpaidBucket
        ? null
        : (source['statement_id'] ??
            source['statement'] ??
            source['finance_statement_id'] ??
            source['statement_transaction_id'] ??
            source['settlement_id'] ??
            source['payment_id'] ??
            source['transaction_id']);
    detail['local_sku'] = source['local_sku'] ?? source['sku'];
    detail['marketplace_sku'] = source['marketplace_sku'] ??
        source['marketplace_sku_id'] ??
        source['sku_id'] ??
        source['external_sku_id'] ??
        source['remote_sku_id'];
    detail['marketplace_seller_sku'] =
        source['marketplace_seller_sku'] ?? source['seller_sku'];
    detail['variant_name'] = source['variant_name'] ??
        source['marketplace_variant_name'] ??
        source['marketplace_variation_name'] ??
        source['sku_name'];
    return detail;
  }

  Map<String, dynamic> _normalizeFinanceSummary(Map<String, dynamic> raw) {
    final map = Map<String, dynamic>.from(raw);
    final gross = _numFirstNonZero([
      map['gross_sales'],
      map['gross_total'],
      map['gross_amount'],
      map['gross'],
      map['omzet_total'],
      map['omzet'],
      map['paid_gross_total']
    ]);
    final payout = _numFirstNonZero([
      map['payout_total'],
      map['payout_amount'],
      map['received_amount'],
      map['payout'],
      map['net_received'],
      map['net_settlement']
    ]);
    final hpp = _numFirstNonZero([
      map['paid_hpp_total'],
      map['settled_hpp_total'],
      map['hpp_total'],
      map['total_hpp'],
      map['hpp_cair'],
      map['hpp_settled'],
      map['hpp_amount'],
      map['hpp']
    ]).abs();
    final operational = _numFirstNonZero([
      map['operational_cost_total'],
      map['operational_expense'],
      map['expense_total'],
      map['manual_expense_total']
    ]);
    final profit = payout - hpp - operational;
    final margin = payout > 0 ? ((profit / payout) * 100) : 0;
    map['gross_sales'] = gross;
    map['omzet'] = gross;
    map['omzet_total'] = gross;
    map['payout_total'] = payout;
    map['payout_amount'] = payout;
    map['received_amount'] = payout;
    map['net_received'] = payout;
    map['net_settlement'] = payout;
    map['hpp_total'] = hpp;
    map['total_hpp'] = hpp;
    map['operational_cost_total'] = operational;
    map['operational_expense'] = operational;
    map['expense_total'] = operational;
    map['net_profit'] = profit;
    map['profit'] = profit;
    map['net_margin_percent'] = _num(map['net_margin_percent']) == 0
        ? margin
        : _num(map['net_margin_percent']);
    final orders = _numFirstNonZero([
      map['finance_order_count'],
      map['finance_orders_count'],
      map['order_count'],
      map['orders_count'],
      map['all_orders_count']
    ]);
    map['finance_order_count'] = orders;
    map['finance_orders_count'] = orders;
    map['order_count'] = orders;
    map['orders_count'] = orders;
    return map;
  }

  String _accountNameById(String accountId) {
    final clean = accountId.trim();
    if (clean.isEmpty) return 'Semua toko';
    for (final row in _accounts) {
      if (_text(row['marketplace_account_id']) == clean) {
        return _text(
            row['shop_name'] ??
                row['seller_name'] ??
                row['account_name'] ??
                row['store_alias'],
            'Semua toko');
      }
    }
    return 'Semua toko';
  }

  List<Map<String, dynamic>> _normalizeMarketplaceRows(
      List<Map<String, dynamic>> rows) {
    return rows.map((source) {
      final row = Map<String, dynamic>.from(source);
      final gross = _numFirstNonZero([
        row['gross_sales'],
        row['gross_total'],
        row['gross_amount'],
        row['gross'],
        row['omzet'],
        row['paid_gross_total']
      ]);
      final payout = _numFirstNonZero([
        row['payout_total'],
        row['payout_amount'],
        row['received_amount'],
        row['net_settlement'],
        row['payout'],
        row['net_received']
      ]);
      final hpp = _numFirstNonZero([
        row['paid_hpp_total'],
        row['settled_hpp_total'],
        row['hpp_total'],
        row['total_hpp'],
        row['hpp_cair'],
        row['hpp_settled'],
        row['hpp_amount'],
        row['hpp']
      ]);
      final profit = _numFirstNonZero([
        row['net_profit'],
        row['profit'],
        row['payout_profit'],
        row['gross_profit'],
        payout - hpp
      ]);
      final margin = payout > 0 ? ((profit / payout) * 100) : 0;
      row['gross_sales'] = gross;
      row['payout_total'] = payout;
      row['payout_amount'] = payout;
      row['received_amount'] = payout;
      row['net_received'] = payout;
      row['net_settlement'] = payout;
      row['hpp_total'] = hpp;
      row['profit'] = profit;
      row['net_profit'] = profit;
      row['net_margin_percent'] = _num(row['net_margin_percent']) == 0
          ? margin
          : _num(row['net_margin_percent']);
      row['shop_name'] = _text(
          row['shop_name'] ?? row['seller_name'] ?? row['account_name'],
          _accountNameById(_text(row['marketplace_account_id'])));
      return row;
    }).toList();
  }

  // ignore: unused_element
  double _sumRows(List<Map<String, dynamic>> rows, List<String> keys) {
    double total = 0;
    for (final row in rows) {
      total += _numFirstNonZero(keys.map((key) => row[key]));
    }
    return total;
  }

  // ignore: unused_element
  bool _totalsMismatch(double left, double right) {
    final base = left.abs() > right.abs() ? left.abs() : right.abs();
    if (base <= 0) return false;
    return (left - right).abs() > (base * 0.03) && (left - right).abs() > 1000;
  }

  String _accountNameFromRows(
      String accountId, List<Map<String, dynamic>> accounts) {
    final clean = accountId.trim();
    if (clean.isEmpty) return 'Semua toko';
    for (final row in accounts) {
      if (_text(row['marketplace_account_id'] ??
              row['account_id'] ??
              row['id']) ==
          clean) {
        return _text(
            row['shop_name'] ??
                row['seller_name'] ??
                row['account_name'] ??
                row['store_alias'],
            'Semua toko');
      }
    }
    return 'Semua toko';
  }

  // ignore: unused_element
  List<Map<String, dynamic>> _marketplaceRowsFromSku(
    List<Map<String, dynamic>> skuRows,
    Map<String, dynamic> summary,
    List<Map<String, dynamic>> accounts,
  ) {
    final grouped = <String, Map<String, dynamic>>{};
    for (final row in skuRows) {
      final accountId =
          _text(row['marketplace_account_id'] ?? row['account_id']);
      final key = accountId.isEmpty ? '__all__' : accountId;
      final qty = _numFirstNonZero([
        row['qty_settled'],
        row['paid_qty'],
        row['qty_payout'],
        row['qty_total'],
        row['quantity']
      ]);
      final gross = _numFirstNonZero([
        row['paid_gross_total'],
        row['gross_total'],
        row['gross_sales'],
        row['gross_amount']
      ]);
      final payout = _numFirstNonZero([
        row['payout_total'],
        row['settlement_total'],
        row['payout_amount'],
        row['received_amount']
      ]);
      final hpp = _numFirstNonZero([
        row['paid_hpp_total'],
        row['hpp_total'],
        row['hpp_amount'],
        row['total_hpp']
      ]);
      final marketplace = _text(row['marketplace'], 'Marketplace');
      final target = grouped.putIfAbsent(
          key,
          () => <String, dynamic>{
                'marketplace_account_id': accountId,
                'marketplace': marketplace,
                'shop_name': _accountNameFromRows(accountId, accounts),
                'order_count': 0.0,
                'finance_order_count': 0.0,
                'qty_total': 0.0,
                'gross_sales': 0.0,
                'payout_total': 0.0,
                'payout_amount': 0.0,
                'hpp_total': 0.0,
                'profit': 0.0,
                'net_profit': 0.0,
                'net_margin_percent': 0.0,
              });
      target['order_count'] = _num(target['order_count']) +
          _numFirstNonZero(
              [row['order_count'], row['orders'], row['total_orders']]);
      target['finance_order_count'] = _num(target['finance_order_count']) +
          _numFirstNonZero([
            row['settled_order_count'],
            row['finance_order_count'],
            row['paid_order_count']
          ]);
      target['qty_total'] = _num(target['qty_total']) + qty;
      target['gross_sales'] = _num(target['gross_sales']) + gross;
      target['payout_total'] = _num(target['payout_total']) + payout;
      target['payout_amount'] = _num(target['payout_amount']) + payout;
      target['hpp_total'] = _num(target['hpp_total']) + hpp;
      target['profit'] = _num(target['profit']) + (payout - hpp);
      target['net_profit'] = _num(target['net_profit']) + (payout - hpp);
    }
    final rows = grouped.values.map((row) {
      final payout = _num(row['payout_total']);
      final profit = _num(row['net_profit']);
      row['net_margin_percent'] = payout > 0 ? (profit / payout) * 100 : 0.0;
      return row;
    }).toList();

    final summaryGross = _num(summary['gross_sales'] ?? summary['omzet']);
    final summaryPayout = _num(summary['payout_total'] ??
        summary['payout_amount'] ??
        summary['received_amount']);
    final summaryHpp = _num(summary['hpp_total'] ?? summary['total_hpp']);
    if (rows.isEmpty &&
        (summaryGross > 0 || summaryPayout > 0 || summaryHpp > 0)) {
      final accountId = _accountUuidParam() ?? '';
      final payout = summaryPayout;
      final hpp = summaryHpp;
      final profit =
          _num(summary['net_profit'] ?? summary['profit'] ?? (payout - hpp));
      return [
        <String, dynamic>{
          'marketplace_account_id': accountId,
          'marketplace':
              _marketplaceFilter == 'all' ? 'Marketplace' : _marketplaceFilter,
          'shop_name': _accountNameFromRows(accountId, accounts),
          'order_count':
              _num(summary['order_count'] ?? summary['finance_order_count']),
          'finance_order_count':
              _num(summary['finance_order_count'] ?? summary['order_count']),
          'qty_total': _num(summary['qty_total']),
          'gross_sales': summaryGross,
          'payout_total': payout,
          'payout_amount': payout,
          'hpp_total': hpp,
          'profit': profit,
          'net_profit': profit,
          'net_margin_percent': payout > 0 ? (profit / payout) * 100 : 0.0,
        }
      ];
    }
    return rows;
  }

  bool _selectedScopeIsSpecific() =>
      _marketplaceParam() != null || _accountUuidParam() != null;

  bool _shouldIncludeUnpaidGrossInSummary() {
    final days = _dateOnly(_end).difference(_dateOnly(_start)).inDays.abs();
    return days <= 1;
  }

  Set<String> _scopeValues(Map<String, dynamic> row, List<String> keys,
      {bool marketplace = false}) {
    final values = <String>{};
    void addValue(dynamic value) {
      final text = _text(value, '').trim();
      if (text.isEmpty || text == '-') return;
      values.add(marketplace
          ? (_normalizeMarketplaceFilter(text) ?? text.toLowerCase())
          : text.toLowerCase());
    }

    for (final key in keys) {
      addValue(row[key]);
    }
    for (final nestedKey in const [
      'order_details',
      'orders',
      'order_refs',
      'paid_orders',
      'settled_orders',
      'unpaid_orders',
      'pending_orders',
      'missing_payout_orders'
    ]) {
      for (final detail in _asList(row[nestedKey])) {
        for (final key in keys) {
          addValue(detail[key]);
        }
      }
    }
    return values;
  }

  bool _rowMatchesSelectedScope(Map<String, dynamic> row) {
    final selectedMarketplace = _marketplaceParam();
    final selectedAccount = _accountUuidParam()?.toLowerCase();

    if (selectedMarketplace != null) {
      final values = _scopeValues(row, ['marketplace', 'platform', 'channel'],
          marketplace: true);
      if (values.isNotEmpty && !values.contains(selectedMarketplace))
        return false;
    }

    if (selectedAccount != null) {
      final values = _scopeValues(row, [
        'marketplace_account_id',
        'account_id',
        'seller_account_id',
        'shop_id'
      ]);
      if (values.isNotEmpty && !values.contains(selectedAccount)) return false;
    }

    return true;
  }

  List<Map<String, dynamic>> _filterSkuRowsBySelectedScope(
      List<Map<String, dynamic>> rows) {
    if (!_selectedScopeIsSpecific()) return rows;
    final filtered = rows.where(_rowMatchesSelectedScope).toList();
    // Aggregated SKU RPC rows already filter by marketplace/account on database level,
    // so if client-side filtering yields 0 rows due to missing row metadata, preserve server rows.
    return (filtered.isEmpty && rows.isNotEmpty) ? rows : filtered;
  }

  Future<List<Map<String, dynamic>>> _fetchApprovedPurchasesPeriod() async {
    final start = _dateOnly(_start);
    final end = _dateOnly(_end);

    bool isApproved(Map<String, dynamic> row) {
      final status = (row['status'] ??
              row['approval_status'] ??
              row['finance_status'] ??
              '')
          .toString()
          .toLowerCase()
          .trim();
      if (status.contains('rejected') ||
          status.contains('canceled') ||
          status.contains('cancelled') ||
          status.contains('void') ||
          status.contains('draft') ||
          status.contains('pending') ||
          status.contains('submitted') ||
          status.contains('waiting') ||
          status.contains('menunggu')) {
        return false;
      }
      return status.contains('approved') ||
          status.contains('disetujui') ||
          status.contains('verified') ||
          status.contains('accepted') ||
          status.contains('approve') ||
          status == 'done' ||
          status == 'paid' ||
          status == 'completed' ||
          status.isEmpty;
    }

    double amountOf(Map<String, dynamic> row) {
      for (final key in [
        'total_pembelian',
        'total_amount',
        'total_price',
        'total_harga',
        'purchase_total',
        'subtotal',
        'total',
        'grand_total',
        'amount',
        'nominal',
        'harga_total',
      ]) {
        final value = _num(row[key]);
        if (value > 0) return value;
      }
      final qty =
          _num(row['qty']) > 0 ? _num(row['qty']) : _num(row['quantity']);
      final price = _num(row['harga']) > 0
          ? _num(row['harga'])
          : (_num(row['price']) > 0
              ? _num(row['price'])
              : _num(row['unit_price']));
      if (qty > 0 && price > 0) return qty * price;
      return 0;
    }

    List<Map<String, dynamic>> normalizeRows(dynamic raw, String source) {
      return _asList(raw)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) {
            if (!isApproved(row)) return false;
            final date = _purchaseDate(row);
            if (date == null) return true;
            final d = _dateOnly(date);
            return !d.isBefore(start) && !d.isAfter(end);
          })
          .map((row) {
            final total = amountOf(row);
            final date = _purchaseDate(row) ?? DateTime.now();
            return {
              ...row,
              'title': row['nomor_pembelian'] ??
                  row['nomor_nota'] ??
                  row['purchase_number'] ??
                  row['request_number'] ??
                  row['supplier_name'] ??
                  row['item_name'] ??
                  row['item'] ??
                  row['nama_barang'] ??
                  row['name'] ??
                  'Pembelian disetujui',
              'description': row['supplier_name'] ??
                  row['catatan'] ??
                  row['note'] ??
                  row['description'] ??
                  '',
              'amount': total,
              'date': _isoDate(date),
              'expense_date': _isoDate(date),
              'type': 'purchase_approved',
              'flow': 'OUT',
              'source': source,
              'source_label': 'Pembelian disetujui',
            };
          })
          .where((row) => _num(row['amount']) > 0)
          .toList();
    }

    final merged = <Map<String, dynamic>>[];
    try {
      merged.addAll(normalizeRows(await _client.rpc('list_purchase_requests'),
          'list_purchase_requests'));
    } catch (_) {}

    for (final table in ['purchase_requests', 'purchases']) {
      try {
        final dateCol =
            table == 'purchase_requests' ? 'tanggal_beli' : 'tanggal';
        dynamic query = _client.from(table).select('*');
        if (_currentTenantId.trim().isNotEmpty) {
          query = query.eq('tenant_id', _currentTenantId);
        }
        query = query
            .gte(dateCol, _toDateParam(_start))
            .lte(dateCol, _toDateParam(_end))
            .order(dateCol, ascending: false);
        final rows = await query.range(0, 499);
        merged.addAll(normalizeRows(rows, table));
      } catch (_) {}
    }

    final deduped = <String, Map<String, dynamic>>{};
    for (final row in merged) {
      final key =
          '${row['id'] ?? row['purchase_id'] ?? row['request_id'] ?? row['title']}_${row['expense_date']}_${_num(row['amount'])}';
      deduped[key] = row;
    }
    return deduped.values.toList();
  }

  DateTime? _purchaseDate(Map<String, dynamic> row) {
    for (final key in [
      'tanggal',
      'tanggal_beli',
      'purchase_date',
      'receipt_date',
      'expense_date',
      'date',
      'paid_at',
      'approved_at',
      'verified_at',
      'updated_at',
      'created_at',
    ]) {
      final raw = row[key];
      if (raw == null) continue;
      final parsed = DateTime.tryParse(raw.toString());
      if (parsed != null) return parsed;
    }
    return null;
  }

  String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  List<Map<String, dynamic>> _expenseRowsFromApprovedPurchases(
      List<dynamic> rows) {
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => _num(row['amount']) > 0)
        .map((row) => {
              'title': row['title'] ?? 'Pembelian disetujui',
              'category': row['category'] ?? 'Pembelian disetujui',
              'description': row['description'] ?? row['note'] ?? '',
              'amount': _num(row['amount']).abs(),
              'expense_date': row['expense_date'] ??
                  row['date'] ??
                  _isoDate(DateTime.now()),
              'created_at': row['created_at'],
              'source': row['source'] ?? 'purchase_requests',
              'source_label': row['source_label'] ?? 'Pembelian disetujui',
            })
        .toList();
  }

  List<Map<String, dynamic>> _cashFlowRowsFromApprovedPurchases(
      List<dynamic> rows) {
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => _num(row['amount']) > 0)
        .map((row) => {
              'title': row['title'] ?? 'Pembelian disetujui',
              'date': row['expense_date'] ??
                  row['date'] ??
                  _isoDate(DateTime.now()),
              'type': 'OUT',
              'amount': -_num(row['amount']).abs(),
              'source': row['source'] ?? 'purchase_requests',
            })
        .toList();
  }

  List<Map<String, dynamic>> _mergeCashFlowRows(
    List<Map<String, dynamic>> primary,
    List<Map<String, dynamic>> extra,
  ) {
    if (extra.isEmpty) return primary;
    return <Map<String, dynamic>>[...primary, ...extra];
  }

  Map<String, dynamic> _summaryForDisplay(
    Map<String, dynamic> summary,
    List<Map<String, dynamic>> skuRows,
    List<Map<String, dynamic>> expenseRows, {
    bool forceFromSku = false,
    bool includeUnpaidGross = false,
  }) {
    final out = Map<String, dynamic>.from(summary);

    final rawGross = _numFirstNonZero([
      summary['gross_sales'],
      summary['gross_total'],
      summary['gross_amount'],
      summary['omzet_total'],
      summary['omzet'],
      summary['paid_gross_total'],
    ]);
    final rawPayout = _numFirstNonZero([
      summary['payout_total'],
      summary['payout_amount'],
      summary['received_amount'],
      summary['net_received'],
      summary['net_settlement'],
      summary['payout'],
    ]);
    final rawHpp = _numFirstNonZero([
      summary['hpp_total'],
      summary['total_hpp'],
      summary['hpp_amount'],
      summary['hpp'],
    ]);
    final rawOrders = _numFirstNonZero([
      summary['finance_order_count'],
      summary['finance_orders_count'],
      summary['orders_count'],
      summary['order_count'],
      summary['all_orders_count'],
    ]);

    var skuGross = 0.0;
    var skuUnpaidGross = 0.0;
    var skuPayout = 0.0;
    var skuHpp = 0.0;
    var skuPaidOrders = 0.0;
    var skuUnpaidOrders = 0.0;
    for (final row in skuRows) {
      final paidQty = _numFirstNonZero(
          [row['paid_qty'], row['settled_qty'], row['qty_settled']]);
      final unpaidQty =
          _numFirstNonZero([row['unpaid_qty'], row['pending_payout_qty']]);
      final rowPaidGross = _numFirstNonZero([
        row['paid_gross_total'],
        row['settled_gross_total'],
        if (paidQty > 0) row['gross_total'],
        if (paidQty > 0) row['gross_sales'],
      ]);
      final rowUnpaidGross = _numFirstNonZero([
        row['unpaid_gross_total'],
        row['pending_gross_total'],
        if (paidQty <= 0 && unpaidQty > 0) row['gross_total'],
        if (paidQty <= 0 && unpaidQty > 0) row['gross_sales'],
      ]);
      skuGross += rowPaidGross;
      skuUnpaidGross += rowUnpaidGross;
      if (paidQty > 0) {
        skuPayout += _num(row['payout_total'] ??
            row['payout_amount'] ??
            row['received_amount']);
        skuHpp +=
            _num(row['paid_hpp_total'] ?? row['hpp_total'] ?? row['total_hpp']);
        skuPaidOrders +=
            _num(row['paid_order_count'] ?? row['detail_order_count']);
      }
      skuUnpaidOrders += _num(row['unpaid_order_count']);
    }

    final expenseFromRows = expenseRows.fold<double>(
        0,
        (sum, row) =>
            sum +
            _num(row['amount'] ?? row['total_amount'] ?? row['expense_total']));
    final expense = expenseFromRows > 0
        ? expenseFromRows
        : _numFirstNonZero([
            summary['operational_cost_total'],
            summary['operational_expense'],
            summary['expense_total'],
            summary['manual_expense_total'],
          ]);

    final gross = forceFromSku
        ? (skuGross + (includeUnpaidGross ? skuUnpaidGross : 0))
        : (rawGross > 0 ? rawGross : skuGross);
    final payout =
        forceFromSku ? skuPayout : (rawPayout > 0 ? rawPayout : skuPayout);
    final hpp = forceFromSku ? skuHpp : (rawHpp > 0 ? rawHpp : skuHpp);
    final profit = payout - hpp - expense;
    final margin = payout > 0 ? profit / payout * 100 : 0.0;
    final orders = forceFromSku
        ? (skuPaidOrders + (includeUnpaidGross ? skuUnpaidOrders : 0))
        : (rawOrders > 0 ? rawOrders : skuPaidOrders);
    final sourceCount = skuRows
        .map((row) => _text(
            row['marketplace_account_id'] ??
                row['shop_name'] ??
                row['marketplace'],
            ''))
        .where((value) => value.trim().isNotEmpty && value != '-')
        .toSet()
        .length;

    out['gross_sales'] = gross;
    out['gross_total'] = gross;
    out['gross_amount'] = gross;
    out['omzet'] = gross;
    out['omzet_total'] = gross;
    out['payout_total'] = payout;
    out['payout_amount'] = payout;
    out['received_amount'] = payout;
    out['net_received'] = payout;
    out['net_settlement'] = payout;
    out['hpp_total'] = hpp;
    out['total_hpp'] = hpp;
    out['operational_cost_total'] = expense;
    out['operational_expense'] = expense;
    out['expense_total'] = expense;
    out['net_profit'] = profit;
    out['profit'] = profit;
    out['net_margin_percent'] = margin;
    out['margin_percent'] = margin;
    out['finance_order_count'] = orders;
    out['finance_orders_count'] = orders;
    out['order_count'] = orders;
    out['orders_count'] = orders;
    if (sourceCount > 0) {
      out['source_count'] = sourceCount;
      out['marketplace_count'] = sourceCount;
    }
    return out;
  }

  List<Map<String, dynamic>> _reconciledMarketplaceRows(
    List<Map<String, dynamic>> rawRows,
    List<Map<String, dynamic>> skuRows,
    Map<String, dynamic> summary,
    List<Map<String, dynamic>> accounts,
  ) {
    final label = rawRows.isNotEmpty ? rawRows.first : <String, dynamic>{};
    final gross = _num(
        summary['gross_sales'] ?? summary['omzet'] ?? summary['gross_total']);
    final payout = _num(summary['payout_total'] ??
        summary['payout_amount'] ??
        summary['received_amount']);
    final hpp = _num(summary['hpp_total'] ?? summary['total_hpp']);
    final profit =
        _num(summary['net_profit'] ?? summary['profit'] ?? (payout - hpp));
    final margin = payout > 0 ? profit / payout * 100 : 0.0;
    final orders = _num(summary['finance_order_count'] ??
            summary['finance_orders_count'] ??
            summary['order_count'] ??
            summary['orders_count'])
        .toInt();

    final commission = _num(summary['commission_fee'] ?? summary['commission'] ?? label['commission_fee'] ?? label['commission']);
    final platform = _num(summary['platform_fee'] ?? summary['platform'] ?? label['platform_fee'] ?? label['platform']);
    final affiliate = _num(summary['affiliate_fee'] ?? summary['affiliate'] ?? label['affiliate_fee'] ?? label['affiliate']);
    final shipping = _num(summary['shipping_fee'] ?? summary['shipping'] ?? summary['ongkir'] ?? label['shipping_fee'] ?? label['shipping']);
    final discount = _num(summary['discount_amount'] ?? summary['voucher_amount'] ?? summary['discount'] ?? summary['voucher'] ?? label['discount_amount'] ?? label['voucher_amount']);
    final refund = _num(summary['refund_amount'] ?? summary['return_refund_amount'] ?? summary['refund'] ?? label['refund_amount'] ?? label['return_refund_amount']);
    final adjustment = _num(summary['adjustment_amount'] ?? summary['adjustment'] ?? label['adjustment_amount'] ?? label['adjustment']);
    final totalDeductions = _num(summary['total_fees'] ?? summary['fee_amount'] ?? summary['biaya'] ?? summary['deductions'] ?? label['total_fees'] ?? label['fee_amount'] ?? label['biaya']);

    // v24.6.60: tab Marketplace wajib mengikuti Ringkasan/SKU.
    // Aggregate mentah dari RPC lama bisa terduplikasi dari join item/HPP, jadi angka nominal utama tidak diambil dari rawRows.
    return [
      {
        'marketplace': _text(
            label['marketplace'] ?? label['platform'] ?? 'tiktok_shop',
            'Marketplace'),
        'marketplace_label': _text(
            label['marketplace_label'] ??
                label['platform_label'] ??
                label['marketplace'] ??
                'TikTok Shop',
            'Marketplace'),
        'shop_name': _text(
            label['shop_name'] ??
                label['store_name'] ??
                label['seller_name'] ??
                _accountNameFromRows('', accounts),
            '-'),
        'store_name': _text(
            label['store_name'] ??
                label['shop_name'] ??
                label['seller_name'] ??
                _accountNameFromRows('', accounts),
            '-'),
        'order_count': orders,
        'finance_order_count': orders,
        'gross_sales': gross,
        'gross_total': gross,
        'omzet': gross,
        'payout_total': payout,
        'payout_amount': payout,
        'received_amount': payout,
        'hpp_total': hpp,
        'total_hpp': hpp,
        'profit': profit,
        'net_profit': profit,
        'net_margin_percent': margin,
        'margin_percent': margin,
        'commission_fee': commission,
        'platform_fee': platform,
        'affiliate_fee': affiliate,
        'shipping_fee': shipping,
        'discount_amount': discount,
        'voucher_amount': discount,
        'refund_amount': refund,
        'return_refund_amount': refund,
        'adjustment_amount': adjustment,
        'fee_amount': totalDeductions,
        'total_fees': totalDeductions,
        'biaya': totalDeductions,
        'deductions': totalDeductions,
      },
    ];
  }

  List<Map<String, dynamic>> _dedupeCashFlowRows(
      List<Map<String, dynamic>> rows) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final row in rows) {
      final source =
          _text(row['source'] ?? row['category'] ?? row['type'], '-');
      final date =
          _text(row['date'] ?? row['created_at'] ?? row['period_start'], '-');
      final amount = _num(row['amount']);
      final key = '${source.toLowerCase()}|$date|${amount.toStringAsFixed(2)}';

      if (seen.add(key)) {
        out.add(row);
      }
    }

    return out;
  }

  List<Map<String, dynamic>> _cashFlowRowsFromSummary(
      Map<String, dynamic> summary) {
    final gross = _num(
        summary['gross_sales'] ?? summary['omzet'] ?? summary['gross_total']);
    final payout = _numFirstNonZero([
      summary['payout_total'],
      summary['payout_amount'],
      summary['received_amount'],
      summary['net_received'],
      summary['net_settlement']
    ]);
    final manual = _numFirstNonZero([
      summary['manual_expense_total'],
      summary['manual_operational_expense']
    ]);
    final production = _numFirstNonZero([
      summary['production_paid_total'],
      summary['paid_production_total'],
      summary['production_tailor_paid_total']
    ]);
    final purchases = _numFirstNonZero([
      summary['approved_purchase_total'],
      summary['purchase_cashout'],
      summary['approved_purchase_cashout']
    ]);
    final netCash = payout - manual - production - purchases;
    final today = _toDateParam(_end);
    final rows = <Map<String, dynamic>>[];
    if (payout > 0 || gross > 0)
      rows.add({
        'source': 'Marketplace',
        'category': 'Payout marketplace',
        'type': 'in',
        'cash_type': 'in',
        'amount': payout,
        'date': today
      });
    if (manual > 0)
      rows.add({
        'source': 'Biaya operasional',
        'category': 'Biaya operasional',
        'type': 'out',
        'cash_type': 'out',
        'amount': -manual.abs(),
        'date': today
      });
    if (purchases > 0)
      rows.add({
        'source': 'Pembelian disetujui',
        'category': 'Pembelian disetujui',
        'type': 'out',
        'cash_type': 'out',
        'amount': -purchases.abs(),
        'date': today
      });
    if (production > 0)
      rows.add({
        'source': 'Produksi paid',
        'category': 'Produksi paid',
        'type': 'out',
        'cash_type': 'out',
        'amount': -production.abs(),
        'date': today
      });
    if (payout > 0 || manual > 0 || production > 0 || purchases > 0)
      rows.add({
        'source': 'Arus kas bersih',
        'category': 'Arus kas bersih',
        'type': netCash >= 0 ? 'in' : 'out',
        'cash_type': netCash >= 0 ? 'in' : 'out',
        'amount': netCash,
        'date': today
      });
    return rows;
  }

  bool _isSettlementDetailProfitLossRow(Map<String, dynamic> row) {
    final type = _text(row['type']).toLowerCase();
    final key = _text(row['key']).toLowerCase();
    final label = _text(row['label'] ?? row['name']).toLowerCase();

    const settlementKeys = <String>{
      'total_fees',
      'platform_fee',
      'commission_fee',
      'affiliate_fee',
      'shipping_fee',
      'discount_amount',
      'refund_amount',
      'adjustment_amount',
      'fee_amount',
    };

    if (type == 'settlement_detail') return true;
    if (settlementKeys.contains(key)) return true;

    return label == 'marketplace' ||
        label.contains('fee marketplace') ||
        label.contains('platform fee') ||
        label.contains('commission fee') ||
        label.contains('affiliate fee') ||
        label.contains('shipping fee') ||
        label.contains('diskon / voucher') ||
        label.contains('refund') ||
        label.contains('adjustment') ||
        label.contains('fee amount');
  }

  bool _isBackendGeneratedProfitLossBreakdownRow(Map<String, dynamic> row) {
    if (_isSettlementDetailProfitLossRow(row)) return true;

    final description =
        _text(row['description'] ?? row['subtitle'] ?? row['note'])
            .toLowerCase();
    final type = _text(row['type']).toLowerCase();
    final key = _text(row['key']).toLowerCase();

    const backendKeys = <String>{
      'gross_sales',
      'payout_total',
      'hpp_total',
      'manual_expense_total',
      'purchase_cashout',
      'net_profit',
    };

    if (description.contains('rincian dari data settlement marketplace')) {
      return true;
    }

    if (backendKeys.contains(key) &&
        (type == 'income' || type == 'cost' || type == 'profit')) {
      return true;
    }

    return false;
  }

  List<Map<String, dynamic>> _profitLossExpenseDetailRows(
      List<Map<String, dynamic>> expenses) {
    // Detail biaya sudah tampil di tab Biaya. Jangan render ulang di Laba Rugi
    // karena akan menduplikasi total Biaya Operasional / Pembelian Disetujui.
    return const <Map<String, dynamic>>[];
  }

  List<Map<String, dynamic>> _profitLossRowsFromSummary(
    Map<String, dynamic> summary, [
    List<Map<String, dynamic>> marketplaceDeductions = const [],
  ]) {
    final gross = _num(summary['gross_sales'] ?? summary['omzet']);
    final payout = _num(summary['payout_total'] ??
        summary['payout_amount'] ??
        summary['received_amount']);
    final hpp = _num(summary['hpp_total'] ?? summary['total_hpp']);
    final manual = _numFirstNonZero([
      summary['manual_expense_total'],
      summary['manual_operational_expense']
    ]);
    final production = _numFirstNonZero([
      summary['production_paid_total'],
      summary['paid_production_total'],
      summary['production_tailor_paid_total']
    ]);
    final purchases = _numFirstNonZero([
      summary['approved_purchase_total'],
      summary['purchase_cashout'],
      summary['approved_purchase_cashout']
    ]);
    final ops = manual + production + purchases;
    // Gross-vs-payout gap is reconciliation diagnostic, not P&L expense.
    final marketplaceCut = 0.0;
    final profit = payout - hpp - ops;
    final margin = payout > 0 ? (profit / payout) * 100 : 0.0;

    final rows = <Map<String, dynamic>>[
      {
        'name': 'Omzet',
        'description': 'Total nilai order dari marketplace',
        'amount': gross,
        'format': 'money'
      },
    ];

    if (marketplaceCut > 0 && marketplaceDeductions.isEmpty) {
      rows.add({
        'name': 'Potongan marketplace',
        'description':
            'Selisih omzet dan payout. Termasuk komisi, biaya layanan, subsidi/voucher, pajak, refund, atau koreksi settlement.',
        'amount': -marketplaceCut,
        'format': 'money'
      });
    }

    for (final item in marketplaceDeductions) {
      final amount = _num(item['amount'] ?? item['total']);
      if (amount == 0) continue;
      final label = _text(item['label'] ?? item['name'] ?? item['category'],
          'Rincian potongan');
      final cleanLabel = label.toLowerCase().trim();
      final isBaseRow = cleanLabel.contains('omzet') ||
          cleanLabel.contains('payout') ||
          cleanLabel == 'hpp' ||
          cleanLabel.contains('harga pokok') ||
          cleanLabel.contains('biaya operasional') ||
          cleanLabel.contains('laba') ||
          cleanLabel.contains('margin') ||
          cleanLabel.contains('potongan marketplace');
      if (isBaseRow) continue;
      rows.add({
        'name': label,
        'description': _text(
            item['description'], 'Rincian dari data settlement marketplace'),
        'amount': amount < 0 ? amount : -amount,
        'format': 'money',
      });
    }

    rows.addAll([
      {
        'name': 'Payout diterima',
        'description': 'Dana marketplace yang sudah release',
        'amount': payout,
        'format': 'money'
      },
      {
        'name': 'HPP',
        'description': 'Modal barang dari mapping SKU/HPP',
        'amount': -hpp.abs(),
        'format': 'money'
      },
      if (manual > 0)
        {
          'name': 'Biaya operasional',
          'description': 'Biaya manual periode ini',
          'amount': -manual.abs(),
          'format': 'money'
        },
      if (purchases > 0)
        {
          'name': 'Pembelian disetujui',
          'description': 'Pembelian yang sudah disetujui finance',
          'amount': -purchases.abs(),
          'format': 'money'
        },
      if (production > 0)
        {
          'name': 'Produksi paid',
          'description': 'Pembayaran produksi/tailor yang sudah dibayar',
          'amount': -production.abs(),
          'format': 'money'
        },
      {
        'name': 'Laba bersih',
        'description':
            'Payout - HPP - biaya operasional - pembelian disetujui - produksi paid',
        'amount': profit,
        'format': 'money'
      },
      {
        'name': 'Margin net',
        'description': 'Laba bersih dibanding payout',
        'amount': margin,
        'format': 'percent'
      },
    ]);
    return rows;
  }

  double _normalizeHppPerItemValue({
    required double hppPerItemRaw,
    required double hppTotalRaw,
    required double qty,
    required double grossPerItem,
  }) {
    var hpp = hppPerItemRaw;
    if (hpp <= 0 && hppTotalRaw > 0 && qty > 0) {
      hpp = hppTotalRaw / qty;
    }
    if (hpp <= 0) return 0.0;

    if (qty > 1 && hppTotalRaw > 0) {
      final fromTotal = hppTotalRaw / qty;
      if (fromTotal > 0 && hpp >= hppTotalRaw * 0.98) {
        return fromTotal;
      }
    }

    // HPP mapping/SKU mapping nilainya adalah HPP per SKU/unit.
    // Kalau cache lama sudah telanjur menyimpan total SKU sebagai hpp_per_item,
    // pecah balik ke unit agar HPP/item tidak jadi jutaan dan margin tidak minus palsu.
    if (qty > 1 && grossPerItem > 0) {
      final divided = hpp / qty;
      final looksMultiplied = hpp > grossPerItem * 3;
      final dividedLooksLikeUnit = divided > 0 && divided <= grossPerItem * 2.2;
      if (looksMultiplied && dividedLooksLikeUnit) {
        return divided;
      }
    }

    return hpp;
  }

  double _targetMarginFromRow(Map<String, dynamic> row) {
    return _numFirstNonZero([
      row['target_margin_percent'],
      row['target_margin'],
      row['margin_target_percent'],
      row['target_net_margin_percent'],
      row['hpp_target_margin_percent'],
      row['sku_target_margin_percent'],
      row['default_target_margin_percent'],
      row['mapped_target_margin_percent'],
    ]);
  }

  bool _isBackendSettledSkuRow(Map<String, dynamic> row) {
    final policy =
        '${row['finance_calc_policy']} ${row['hpp_calc_policy']} ${row['summary_policy']}'
            .toLowerCase();
    if (policy.contains('settled_payout_only') ||
        policy.contains('paid_qty_only')) return true;
    return _numFirstNonZero([
          row['paid_hpp_total'],
          row['settled_hpp_total'],
          row['paid_qty'],
          row['settled_qty'],
          row['qty_settled'],
        ]) >
        0;
  }

  Map<String, dynamic> _normalizeBackendSettledSkuRow(
      Map<String, dynamic> source) {
    final row = Map<String, dynamic>.from(source);

    double exact(List<String> keys) =>
        _numFirstNonZero(keys.map((key) => row[key]));

    var settledQty = exact(const [
      'paid_qty_total',
      'settled_qty_total',
      'paid_qty',
      'settled_qty',
      'qty_settled',
      'qty_payout',
      'paid_quantity',
      'settled_quantity',
    ]);
    var totalQty = exact(const [
      'all_qty_total',
      'qty_all',
      'total_qty',
      'qty_total',
      'qty',
      'quantity',
    ]);
    var unpaidQty = exact(const [
      'unpaid_qty_total',
      'unpaid_qty',
      'qty_unpaid',
      'pending_payout_qty',
      'qty_belum_payout',
    ]);

    var positivePayout = exact(const [
      'positive_payout_total',
      'paid_positive_payout_total',
      'payout_positive_total',
    ]);
    var signedPayout = exact(const [
      'payout_total',
      'payout_amount',
      'received_amount',
      'net_received',
      'net_settlement',
      'payout',
    ]);
    var negativePayout = exact(const [
      'negative_payout_total',
      'minus_payout_total',
      'payout_minus_total',
    ]);
    if (positivePayout <= 0 && signedPayout > 0) positivePayout = signedPayout;
    if (negativePayout == 0 && signedPayout < 0) negativePayout = signedPayout;
    if (signedPayout == 0) signedPayout = positivePayout + negativePayout;

    var positiveQty = exact(const ['positive_payout_qty', 'paid_positive_qty']);
    var negativeQty = exact(const ['negative_payout_qty', 'minus_payout_qty']);

    if (totalQty <= 0) totalQty = settledQty + unpaidQty;
    if (settledQty <= 0 && positivePayout > 0) {
      settledQty = positiveQty > 0 ? positiveQty : totalQty;
    }
    if (settledQty <= 0 && signedPayout != 0 && unpaidQty <= 0) {
      settledQty = totalQty;
    }
    if (totalQty > 0 && settledQty > totalQty) settledQty = totalQty;
    if (unpaidQty <= 0 && totalQty > 0) unpaidQty = totalQty - settledQty;
    if (unpaidQty < 0) unpaidQty = 0;
    if (totalQty <= 0) totalQty = settledQty + unpaidQty;
    if (positiveQty <= 0 && positivePayout > 0) positiveQty = settledQty;
    if (negativeQty <= 0 && negativePayout < 0) negativeQty = settledQty;
    if (settledQty > 0 && positiveQty > settledQty) positiveQty = settledQty;
    if (settledQty > 0 && negativeQty > settledQty) negativeQty = settledQty;

    final explicitPaidGross = exact(const [
      'paid_gross_total',
      'settled_gross_total',
      'gross_settled_total',
    ]);
    final explicitUnpaidGross = exact(const [
      'unpaid_gross_total',
      'gross_unpaid_total',
      'pending_gross_total',
    ]);
    var grossTotal = exact(const [
      'all_gross_total',
      'gross_all_total',
      'gross_total',
      'gross_sales',
      'gross_amount',
      'omzet_total',
      'omzet',
    ]);
    if (grossTotal <= 0) grossTotal = explicitPaidGross + explicitUnpaidGross;
    var paidGross = explicitPaidGross;
    if (paidGross <= 0 && grossTotal > 0 && settledQty > 0 && totalQty > 0) {
      paidGross = grossTotal * (settledQty / totalQty);
    }
    var unpaidGross = explicitUnpaidGross;
    if (unpaidGross <= 0 && grossTotal > 0) {
      unpaidGross =
          (grossTotal - paidGross).clamp(0.0, double.infinity).toDouble();
    }

    final grossPerItem = totalQty > 0
        ? grossTotal / totalQty
        : exact(const ['gross_per_item', 'unit_gross_amount']);

    final hppRaw = exact(const [
      'hpp_per_item',
      'unit_hpp',
      'hpp_unit',
      'hpp_item',
    ]);
    final explicitSettledHpp = exact(const [
      'paid_hpp_total',
      'settled_hpp_total',
      'hpp_settled_total',
    ]);
    final explicitAllHpp = exact(const [
      'all_hpp_total',
      'hpp_all_total',
      'hpp_total',
      'total_hpp',
    ]);
    var hppPerItem = _normalizeHppPerItemValue(
      hppPerItemRaw: hppRaw,
      hppTotalRaw: explicitAllHpp > 0 ? explicitAllHpp : explicitSettledHpp,
      qty: totalQty > 0 ? totalQty : settledQty,
      grossPerItem: grossPerItem,
    );
    if (hppPerItem <= 0 && explicitSettledHpp > 0 && settledQty > 0) {
      hppPerItem = explicitSettledHpp / settledQty;
    }
    if (hppPerItem <= 0 && explicitAllHpp > 0 && totalQty > 0) {
      hppPerItem = explicitAllHpp / totalQty;
    }

    final settledHppTotal = hppPerItem * settledQty;
    final unpaidHppTotal = hppPerItem * unpaidQty;
    final allHppTotal = settledHppTotal + unpaidHppTotal;
    final payoutForMargin = positivePayout > 0 ? positivePayout : 0.0;
    final payoutPerSettledItem =
        settledQty > 0 ? payoutForMargin / settledQty : 0.0;
    final netPayoutPerSettledItem =
        settledQty > 0 ? signedPayout / settledQty : 0.0;
    final profit = payoutForMargin - settledHppTotal;
    final settledMargin =
        payoutForMargin > 0 ? (profit / payoutForMargin) * 100 : 0.0;
    final estimatedProfit = grossTotal - allHppTotal;
    final estimatedMargin =
        grossTotal > 0 ? (estimatedProfit / grossTotal) * 100 : 0.0;

    row['qty'] = totalQty;
    row['qty_total'] = totalQty;
    row['quantity'] = totalQty;
    row['all_qty_total'] = totalQty;
    row['paid_qty'] = settledQty;
    row['settled_qty'] = settledQty;
    row['qty_settled'] = settledQty;
    row['qty_payout'] = settledQty;
    row['unpaid_qty'] = unpaidQty;
    row['qty_unpaid'] = unpaidQty;
    row['pending_payout_qty'] = unpaidQty;
    row['gross_total'] = grossTotal;
    row['gross_sales'] = grossTotal;
    row['gross_amount'] = grossTotal;
    row['all_gross_total'] = grossTotal;
    row['paid_gross_total'] = paidGross;
    row['settled_gross_total'] = paidGross;
    row['unpaid_gross_total'] = unpaidGross;
    row['payout_total'] = payoutForMargin;
    row['payout_amount'] = payoutForMargin;
    row['received_amount'] = payoutForMargin;
    row['net_received'] = payoutForMargin;
    row['net_settlement'] = payoutForMargin;
    row['payout'] = payoutForMargin;
    row['positive_payout_total'] = positivePayout;
    row['negative_payout_total'] = negativePayout;
    row['positive_payout_qty'] = positiveQty;
    row['negative_payout_qty'] = negativeQty;
    row['hpp_per_item'] = hppPerItem;
    row['unit_hpp'] = hppPerItem;
    row['hpp'] = hppPerItem;
    row['paid_hpp_total'] = settledHppTotal;
    row['settled_hpp_total'] = settledHppTotal;
    row['unpaid_hpp_total'] = unpaidHppTotal;
    row['all_hpp_total'] = allHppTotal;
    row['hpp_total'] = allHppTotal;
    row['total_hpp'] = allHppTotal;
    row['gross_per_item'] = grossPerItem;
    row['payout_per_item'] = payoutPerSettledItem;
    row['payout_per_item_paid'] = payoutPerSettledItem;
    row['positive_payout_per_item'] = payoutPerSettledItem;
    row['net_payout_per_item_paid'] = netPayoutPerSettledItem;
    row['net_profit'] = profit;
    row['profit'] = profit;
    row['gross_profit'] = profit;
    row['net_margin_percent'] = settledMargin;
    row['margin_percent'] = settledMargin;
    row['margin_settled_percent'] = settledMargin;
    row['margin_estimated_percent'] = estimatedMargin;
    row['paid_order_count'] = exact(const [
      'paid_order_count',
      'settled_order_count',
      'finance_order_count'
    ]).toInt();
    row['unpaid_order_count'] =
        exact(const ['unpaid_order_count', 'pending_payout_order_count'])
            .toInt();
    if (_text(row['local_sku']).isEmpty || _text(row['local_sku']) == '-')
      row['local_sku'] = _text(row['sku'] ?? row['marketplace_sku_id'], '-');
    if (_text(row['sku']).isEmpty || _text(row['sku']) == '-')
      row['sku'] = _text(row['local_sku'] ?? row['marketplace_sku_id'], '-');
    return row;
  }

  List<Map<String, dynamic>> _normalizeSkuRows(
      List<Map<String, dynamic>> rows) {
    return rows.map((item) {
      final row = Map<String, dynamic>.from(item);
      if (_isBackendSettledSkuRow(row))
        return _normalizeBackendSettledSkuRow(row);
      final marketplaceSkuId = _text(
          row['marketplace_sku_id'] ?? row['remote_sku_id'] ?? row['sku_id'],
          '');
      final marketplaceSku = _text(
          row['marketplace_sku'] ??
              row['marketplace_sku_code'] ??
              row['remote_sku_id'] ??
              marketplaceSkuId,
          '');
      final sellerSku = _text(
          row['marketplace_seller_sku'] ??
              row['seller_sku'] ??
              row['remote_seller_sku'],
          '');
      final marketplaceVariant = _text(
          row['marketplace_variation_name'] ??
              row['marketplace_variant_name'] ??
              row['remote_sku_name'] ??
              row['variant_name'],
          '');
      if (_text(row['marketplace_sku']).isEmpty)
        row['marketplace_sku'] = marketplaceSku;
      if (_text(row['marketplace_sku_id']).isEmpty)
        row['marketplace_sku_id'] = marketplaceSkuId;
      if (_text(row['marketplace_seller_sku']).isEmpty)
        row['marketplace_seller_sku'] = sellerSku;
      if (_text(row['variant_name']).isEmpty)
        row['variant_name'] = marketplaceVariant;
      if (_text(row['marketplace_variation_name']).isEmpty)
        row['marketplace_variation_name'] = marketplaceVariant;
      final details = _safeOrderRefRows(row);
      var totalQty = 0.0;
      var paidQty = 0.0;
      var unpaidQty = 0.0;
      var positivePayoutQty = 0.0;
      var negativePayoutQty = 0.0;
      var zeroReleasedQty = 0.0;
      var grossTotal = 0.0;
      var paidGross = 0.0;
      var unpaidGross = 0.0;
      var paidPayout = 0.0;
      var positivePayout = 0.0;
      var negativePayout = 0.0;
      var hppTotal = 0.0;
      var paidHppTotal = 0.0;
      final paidOrders = <String>{};
      final unpaidOrders = <String>{};

      final rowQtyCandidate = _num(row['qty_total'] ??
          row['qty_settled'] ??
          row['settled_qty'] ??
          row['qty'] ??
          row['quantity'] ??
          row['orders_count']);
      final rowHppPerItemRaw = _num(row['hpp_per_item'] ?? row['hpp']);
      final rowHppTotalRaw =
          _num(row['hpp_total'] ?? row['hpp_amount'] ?? row['total_hpp']);
      final rowGrossTotalRaw = _num(row['gross_total'] ??
          row['gross_sales'] ??
          row['gross'] ??
          row['gross_amount']);
      final rowGrossPerItemRaw =
          rowQtyCandidate > 0 ? rowGrossTotalRaw / rowQtyCandidate : 0.0;
      final rowHppPerItemFallback = _normalizeHppPerItemValue(
        hppPerItemRaw: rowHppPerItemRaw,
        hppTotalRaw: rowHppTotalRaw,
        qty: rowQtyCandidate,
        grossPerItem: rowGrossPerItemRaw,
      );
      final targetMargin = _targetMarginFromRow(row);

      for (final detail in details) {
        final qty = _num(detail['qty']);
        final safeQty = qty > 0 ? qty : 1.0;
        final gross = _num(detail['gross']) > 0
            ? _num(detail['gross'])
            : (_num(detail['gross_per_item']) * safeQty);
        final payout = _linePayoutAmount(detail, defaultQty: safeQty);
        final detailGrossPerItem =
            safeQty > 0 ? gross / safeQty : _num(detail['gross_per_item']);
        final detailHppPerItem = _normalizeHppPerItemValue(
          hppPerItemRaw: _num(detail['hpp_per_item'] ??
              detail['hpp_unit'] ??
              detail['unit_hpp']),
          hppTotalRaw: _num(detail['hpp']),
          qty: safeQty,
          grossPerItem: detailGrossPerItem,
        );
        final hpp = detailHppPerItem > 0
            ? detailHppPerItem * safeQty
            : (rowHppPerItemFallback * safeQty);
        final orderKey = _text(detail['order'], '').trim();
        totalQty += safeQty;
        grossTotal += gross;
        hppTotal += hpp;
        final isReleased = _hasReleasedPayout(detail);
        if (isReleased) {
          paidQty += safeQty;
          paidGross += gross;
          paidPayout += payout;
          paidHppTotal += hpp;
          if (payout > 0) {
            positivePayoutQty += safeQty;
            positivePayout += payout;
          } else if (payout < 0) {
            negativePayoutQty += safeQty;
            negativePayout += payout;
          } else {
            zeroReleasedQty += safeQty;
          }
          if (orderKey.isNotEmpty && orderKey != '-') paidOrders.add(orderKey);
        } else {
          unpaidQty += safeQty;
          unpaidGross += gross;
          if (orderKey.isNotEmpty && orderKey != '-')
            unpaidOrders.add(orderKey);
        }
      }

      if (details.isEmpty) {
        totalQty =
            _num(row['qty_total'] ?? row['qty'] ?? row['quantity']).toDouble();
        grossTotal =
            _num(row['gross_total'] ?? row['gross_sales'] ?? row['gross'])
                .toDouble();
        paidPayout = _num(row['payout_total'] ??
                row['payout_amount'] ??
                row['received_amount'] ??
                row['net_settlement'] ??
                row['payout'] ??
                row['net_received'])
            .toDouble();
        hppTotal = _num(row['hpp_total'] ?? row['hpp_amount'] ?? row['hpp'])
            .toDouble();
        paidQty = _num(row['paid_qty'] ?? row['settled_qty']).toDouble();
        unpaidQty = _num(row['unpaid_qty']).toDouble();
        positivePayout = _num(row['positive_payout_total'] ??
                row['paid_positive_payout_total'])
            .toDouble();
        negativePayout =
            _num(row['negative_payout_total'] ?? row['minus_payout_total'])
                .toDouble();
        positivePayoutQty = _num(row['positive_payout_qty']).toDouble();
        negativePayoutQty = _num(row['negative_payout_qty']).toDouble();
        if (positivePayout == 0 && paidPayout > 0) positivePayout = paidPayout;
        if (negativePayout == 0 && paidPayout < 0) negativePayout = paidPayout;
        // Only treat payout_total as evidence of settled qty when the row is
        // NOT tagged as an unpaid row. Rows from p_payout_filter='unpaid' carry
        // a non-zero payout_total (accumulated), but all their qty is unpaid.
        final isTaggedUnpaid =
            _text(row['_payout_filter'], '').toLowerCase() == 'unpaid';
        if (!isTaggedUnpaid && paidQty <= 0 && paidPayout != 0)
          paidQty = totalQty;
        if (positivePayoutQty <= 0 && positivePayout > 0)
          positivePayoutQty = paidQty > 0 ? paidQty : totalQty;
        if (negativePayoutQty <= 0 && negativePayout < 0)
          negativePayoutQty = paidQty > 0 ? paidQty : totalQty;
        if (unpaidQty <= 0)
          unpaidQty = (totalQty - paidQty).clamp(0, 999999999).toDouble();
        paidGross = _num(row['paid_gross_total']).toDouble();
        if (paidGross <= 0)
          paidGross = unpaidQty > 0 && totalQty > 0
              ? grossTotal * (paidQty / totalQty)
              : grossTotal;
        paidHppTotal = _num(row['paid_hpp_total']).toDouble();
        if (hppTotal <= 0 && rowHppPerItemFallback > 0 && totalQty > 0)
          hppTotal = rowHppPerItemFallback * totalQty;
        if (paidHppTotal <= 0 && paidQty > 0)
          paidHppTotal = rowHppPerItemFallback > 0
              ? rowHppPerItemFallback * paidQty
              : (totalQty > 0 ? hppTotal * (paidQty / totalQty) : hppTotal);
      }

      final qtyForGross =
          totalQty > 0 ? totalQty : _num(row['qty_total'] ?? row['qty'] ?? 1);
      final grossPerItem = qtyForGross > 0
          ? grossTotal / qtyForGross
          : _num(row['gross_per_item']);
      final hppPerItem = rowHppPerItemFallback > 0
          ? rowHppPerItemFallback
          : (qtyForGross > 0 ? hppTotal / qtyForGross : 0.0);
      final settledHppTotal = hppPerItem * paidQty;
      final unpaidHppTotal = hppPerItem * unpaidQty;
      final allHppTotal = settledHppTotal + unpaidHppTotal;
      final payoutForMargin = positivePayout > 0
          ? positivePayout
          : (paidPayout > 0 ? paidPayout : 0.0);
      final payoutPerSettledItem =
          paidQty > 0 ? payoutForMargin / paidQty : 0.0;
      final netPayoutPerSettledItem = paidQty > 0 ? paidPayout / paidQty : 0.0;
      final profit = payoutForMargin - settledHppTotal;
      final settledMargin =
          payoutForMargin > 0 ? ((profit / payoutForMargin) * 100) : 0.0;
      final estimatedProfit = grossTotal - allHppTotal;
      final estimatedMargin =
          grossTotal > 0 ? ((estimatedProfit / grossTotal) * 100) : 0.0;

      row['qty_total'] = qtyForGross;
      row['qty'] = qtyForGross;
      row['quantity'] = qtyForGross;
      row['all_qty_total'] = qtyForGross;
      row['paid_qty'] = paidQty;
      row['settled_qty'] = paidQty;
      row['qty_settled'] = paidQty;
      row['qty_payout'] = paidQty;
      row['unpaid_qty'] = unpaidQty;
      row['qty_unpaid'] = unpaidQty;
      row['pending_payout_qty'] = unpaidQty;
      row['positive_payout_qty'] = positivePayoutQty;
      row['negative_payout_qty'] = negativePayoutQty;
      row['zero_released_qty'] = zeroReleasedQty;
      row['gross_total'] = grossTotal;
      row['gross_sales'] = grossTotal;
      row['gross_amount'] = grossTotal;
      row['all_gross_total'] = grossTotal;
      row['paid_gross_total'] = paidGross;
      row['settled_gross_total'] = paidGross;
      row['unpaid_gross_total'] = unpaidGross;
      row['hpp_per_item'] = hppPerItem;
      row['unit_hpp'] = hppPerItem;
      row['hpp'] = hppPerItem;
      row['paid_hpp_total'] = settledHppTotal;
      row['settled_hpp_total'] = settledHppTotal;
      row['unpaid_hpp_total'] = unpaidHppTotal;
      row['all_hpp_total'] = allHppTotal;
      row['hpp_total'] = allHppTotal;
      row['total_hpp'] = allHppTotal;
      row['payout_total'] = payoutForMargin;
      row['payout_amount'] = payoutForMargin;
      row['received_amount'] = payoutForMargin;
      row['net_settlement'] = payoutForMargin;
      row['payout'] = payoutForMargin;
      row['net_received'] = payoutForMargin;
      row['positive_payout_total'] = positivePayout;
      row['negative_payout_total'] = negativePayout;
      row['gross_per_item'] = grossPerItem;
      row['payout_per_item'] = payoutPerSettledItem;
      row['payout_per_item_paid'] = payoutPerSettledItem;
      row['positive_payout_per_item'] = payoutPerSettledItem;
      row['net_payout_per_item_paid'] = netPayoutPerSettledItem;
      row['net_profit'] = profit;
      row['profit'] = profit;
      row['gross_profit'] = profit;
      row['net_margin_percent'] = settledMargin;
      row['margin_percent'] = settledMargin;
      row['margin_settled_percent'] = settledMargin;
      row['margin_estimated_percent'] = estimatedMargin;
      row['target_margin_percent'] = targetMargin;
      row['detail_order_count'] = details.isNotEmpty
          ? details.length
          : _num(row['detail_order_count']).toInt();
      if (_text(row['sku']).isEmpty || _text(row['sku']) == '-')
        row['sku'] = _text(
            row['local_sku'] ??
                row['marketplace_sku_id'] ??
                row['marketplace_sku'] ??
                row['marketplace_seller_sku'],
            '-');
      return row;
    }).toList();
  }

  List<Map<String, dynamic>> _aggregateSkuRowsByLocalSku(
      List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return rows;
    final map = <String, Map<String, dynamic>>{};
    final order = <String>[];

    for (final item in rows) {
      final row = Map<String, dynamic>.from(item);
      final localSku = _text(row['local_sku'] ?? row['sku'], '').trim();
      final key = localSku.isNotEmpty && localSku != '-'
          ? localSku.toUpperCase()
          : 'UNMAPPED_${_text(row['marketplace_sku_id'] ?? row['marketplace_sku'] ?? row['product_name'])}';

      final existing = map[key];
      if (existing == null) {
        row['local_sku'] = localSku.isNotEmpty ? localSku : key;
        row['sku'] = localSku.isNotEmpty ? localSku : key;
        map[key] = row;
        order.add(key);
      } else {
        existing['qty'] = _num(existing['qty']) + _num(row['qty']);
        existing['qty_total'] = _num(existing['qty_total']) + _num(row['qty_total']);
        existing['total_qty'] = _num(existing['total_qty']) + _num(row['total_qty']);
        existing['all_qty'] = _num(existing['all_qty']) + _num(row['all_qty']);
        existing['paid_qty'] = _num(existing['paid_qty']) + _num(row['paid_qty']);
        existing['settled_qty'] = _num(existing['settled_qty']) + _num(row['settled_qty']);
        existing['qty_settled'] = _num(existing['qty_settled']) + _num(row['qty_settled']);
        existing['unpaid_qty'] = _num(existing['unpaid_qty']) + _num(row['unpaid_qty']);
        existing['qty_unpaid'] = _num(existing['qty_unpaid']) + _num(row['qty_unpaid']);
        existing['pending_payout_qty'] = _num(existing['pending_payout_qty']) + _num(row['pending_payout_qty']);
        existing['qty_belum_payout'] = _num(existing['qty_belum_payout']) + _num(row['qty_belum_payout']);
        existing['belum_payout_qty'] = _num(existing['belum_payout_qty']) + _num(row['belum_payout_qty']);
        existing['payout_total'] = _num(existing['payout_total']) + _num(row['payout_total']);
        existing['payout_amount'] = _num(existing['payout_amount']) + _num(row['payout_amount']);
        existing['gross_sales'] = _num(existing['gross_sales']) + _num(row['gross_sales']);
        existing['gross_total'] = _num(existing['gross_total']) + _num(row['gross_total']);
        existing['hpp_total'] = _num(existing['hpp_total']) + _num(row['hpp_total']);
        existing['order_count'] = _num(existing['order_count']) + _num(row['order_count']);
        existing['paid_order_count'] = _num(existing['paid_order_count']) + _num(row['paid_order_count']);
        existing['unpaid_order_count'] = _num(existing['unpaid_order_count']) + _num(row['unpaid_order_count']);
        existing['unpaid_rows'] = _num(existing['unpaid_rows']) + _num(row['unpaid_rows']);
        existing['unpaid_count'] = _num(existing['unpaid_count']) + _num(row['unpaid_count']);
      }
    }

    return order.map((k) => map[k]!).toList();
  }

  List<Map<String, dynamic>> _sortSkuRowsForDisplay(
      List<Map<String, dynamic>> rows) {
    final out = rows.map((row) => Map<String, dynamic>.from(row)).toList();
    out.sort((a, b) {
      final aSettled =
          _num(a['paid_qty'] ?? a['settled_qty'] ?? a['qty_settled']);
      final bSettled =
          _num(b['paid_qty'] ?? b['settled_qty'] ?? b['qty_settled']);
      final aPayout = _num(a['payout_total'] ?? a['payout_amount']);
      final bPayout = _num(b['payout_total'] ?? b['payout_amount']);
      final settledCmp = bSettled.compareTo(aSettled);
      if (settledCmp != 0) return settledCmp;
      final payoutCmp = bPayout.compareTo(aPayout);
      if (payoutCmp != 0) return payoutCmp;
      final aUnpaid = _num(a['unpaid_qty'] ?? a['qty_unpaid']);
      final bUnpaid = _num(b['unpaid_qty'] ?? b['qty_unpaid']);
      return bUnpaid.compareTo(aUnpaid);
    });
    return out;
  }

  List<Map<String, dynamic>> _mergeSkuRows(
      List<Map<String, dynamic>> base, List<Map<String, dynamic>> extra) {
    final out = <Map<String, dynamic>>[];
    final byKey = <String, Map<String, dynamic>>{};

    List<String> keysOf(Map<String, dynamic> row) {
      final local =
          _text(row['local_sku'] ?? row['sku'], '').trim().toLowerCase();
      if (local.isNotEmpty && local != '-' && local != 'unmapped') {
        return [local];
      }

      final account =
          _text(row['marketplace_account_id'] ?? row['account_id'], '')
              .trim()
              .toLowerCase();
      final prefix = account.isEmpty || account == '-' ? '' : '$account|';
      for (final value in [
        row['marketplace_sku_id'],
        row['sku_id'],
        row['remote_sku_id']
      ]) {
        final text = _text(value, '').trim().toLowerCase();
        if (text.isNotEmpty && text != '-') return ['$prefix$text'];
      }
      for (final value in [
        row['marketplace_sku'],
        row['marketplace_seller_sku'],
        row['seller_sku']
      ]) {
        final text = _text(value, '').trim().toLowerCase();
        if (text.isNotEmpty && text != '-') return ['$prefix$text'];
      }
      return ['${prefix}row_${row.hashCode}'];
    }

    void addRow(Map<String, dynamic> row) {
      final keys = keysOf(row);
      Map<String, dynamic>? existing;
      for (final key in keys) {
        existing = byKey[key];
        if (existing != null) break;
      }
      if (existing == null) {
        final copy = Map<String, dynamic>.from(row);
        out.add(copy);
        for (final key in keys) {
          byKey[key] = copy;
        }
        return;
      }

      final detailOnly = _text(row['detail_source'], '').contains('_detail') ||
          _text(row['source'], '').contains('_detail');
      if (!detailOnly) {
        existing['qty'] = _num(existing['qty']) + _num(row['qty']);
        existing['qty_total'] =
            _num(existing['qty_total']) + _num(row['qty_total']);
        existing['all_qty_total'] =
            _num(existing['all_qty_total']) + _num(row['all_qty_total']);
        existing['paid_qty'] =
            _num(existing['paid_qty']) + _num(row['paid_qty']);
        existing['settled_qty'] =
            _num(existing['settled_qty']) + _num(row['settled_qty']);
        existing['qty_settled'] =
            _num(existing['qty_settled']) + _num(row['qty_settled']);
        existing['qty_payout'] =
            _num(existing['qty_payout']) + _num(row['qty_payout']);
        existing['unpaid_qty'] =
            _num(existing['unpaid_qty']) + _num(row['unpaid_qty']);
        existing['qty_unpaid'] =
            _num(existing['qty_unpaid']) + _num(row['qty_unpaid']);
        existing['pending_payout_qty'] = _num(existing['pending_payout_qty']) +
            _num(row['pending_payout_qty']);
        existing['paid_gross_total'] =
            _num(existing['paid_gross_total']) + _num(row['paid_gross_total']);
        existing['settled_gross_total'] =
            _num(existing['settled_gross_total']) +
                _num(row['settled_gross_total']);
        existing['unpaid_gross_total'] = _num(existing['unpaid_gross_total']) +
            _num(row['unpaid_gross_total']);
        existing['payout_total'] =
            _num(existing['payout_total']) + _num(row['payout_total']);
        existing['payout_amount'] =
            _num(existing['payout_amount']) + _num(row['payout_amount']);
        existing['received_amount'] =
            _num(existing['received_amount']) + _num(row['received_amount']);
        existing['positive_payout_total'] =
            _num(existing['positive_payout_total']) +
                _num(row['positive_payout_total']);
        existing['negative_payout_total'] =
            _num(existing['negative_payout_total']) +
                _num(row['negative_payout_total']);
        existing['paid_hpp_total'] =
            _num(existing['paid_hpp_total']) + _num(row['paid_hpp_total']);
        existing['settled_hpp_total'] = _num(existing['settled_hpp_total']) +
            _num(row['settled_hpp_total']);
        existing['unpaid_hpp_total'] =
            _num(existing['unpaid_hpp_total']) + _num(row['unpaid_hpp_total']);
        existing['hpp_total'] =
            _num(existing['hpp_total']) + _num(row['hpp_total']);
        existing['total_hpp'] =
            _num(existing['total_hpp']) + _num(row['total_hpp']);
        final paidQty = _num(existing['paid_qty']);
        final payout = _num(existing['payout_total']);
        final hpp = _num(existing['paid_hpp_total']);
        existing['payout_per_item'] = paidQty > 0 ? payout / paidQty : 0;
        existing['payout_per_item_paid'] = existing['payout_per_item'];
        existing['hpp_per_item'] = paidQty > 0 && hpp > 0
            ? hpp / paidQty
            : _numFirstNonZero([existing['hpp_per_item'], row['hpp_per_item']]);
        existing['net_profit'] = payout - hpp;
        existing['profit'] = existing['net_profit'];
        existing['net_margin_percent'] =
            payout > 0 ? ((payout - hpp) / payout * 100) : 0;
        existing['margin_percent'] = existing['net_margin_percent'];
      }
      existing['order_details'] = <dynamic>[
        ..._asList(existing['order_details']),
        ..._asList(row['order_details']),
      ];
      for (final field in const [
        'marketplace_account_id',
        'account_id',
        'marketplace_sku',
        'marketplace_sku_id',
        'marketplace_seller_sku',
        'seller_sku',
        'variant_name',
        'marketplace_variation_name',
        'product_name',
        'target_margin_percent',
      ]) {
        if (_text(existing[field]).isEmpty || _text(existing[field]) == '-')
          existing[field] = row[field];
      }
      for (final key in keys) {
        byKey[key] = existing;
      }
    }

    for (final row in base) addRow(row);
    for (final row in extra) addRow(row);
    return out;
  }

  List<Map<String, dynamic>> _normalizeAbnormalRows(
      List<Map<String, dynamic>> rows) {
    return rows.map((item) {
      final row = Map<String, dynamic>.from(item);
      final details = _safeOrderRefRows(row);
      final firstDetail =
          details.isNotEmpty ? details.first : const <String, dynamic>{};
      var qty = 0.0;
      var gross = 0.0;
      var payout = 0.0;
      for (final detail in details) {
        final safeQty = _num(detail['qty']) > 0 ? _num(detail['qty']) : 1.0;
        final lineGross = _num(detail['gross']) > 0
            ? _num(detail['gross'])
            : (_num(detail['gross_per_item']) * safeQty);
        final linePayout = _linePayoutAmount(detail, defaultQty: safeQty);
        qty += safeQty;
        gross += lineGross;
        payout += linePayout;
      }
      if (details.isEmpty) {
        qty = _num(row['qty'] ?? row['quantity']).toDouble();
        gross = _num(row['expected_amount'] ??
                row['expected_payout'] ??
                row['gross'] ??
                row['gross_amount'])
            .toDouble();
        payout = _num(row['payout_amount'] ??
                row['received_amount'] ??
                row['net_settlement'] ??
                row['payout'])
            .toDouble();
      }
      final hpp = _num(row['hpp'] ?? firstDetail['hpp']);
      final expected = gross > 0 ? gross : hpp;
      final diff = _num(row['difference_amount'] ?? row['gap_amount']) != 0
          ? _num(row['difference_amount'] ?? row['gap_amount'])
          : (expected - payout).abs();
      row['title'] = _text(
          row['title'] ??
              row['product_name'] ??
              row['message'] ??
              row['sku'] ??
              row['local_sku'] ??
              row['order'] ??
              row['order_id'],
          'Abnormal');
      row['marketplace'] = _text(
          row['marketplace'] ?? firstDetail['marketplace'],
          _marketplaceFilter == 'all' ? 'all' : _marketplaceFilter);
      row['status'] = _text(
          row['status'] ?? row['order_status'] ?? firstDetail['order_status'],
          'Perlu cek');
      row['difference_amount'] = diff;
      row['payout_amount'] = payout;
      row['expected_amount'] = expected;
      row['order_id'] = _text(
          row['order_id'] ??
              row['order'] ??
              row['order_sn'] ??
              firstDetail['order'],
          '-');
      row['order_sn'] = _text(
          row['order_sn'] ??
              row['order'] ??
              row['order_id'] ??
              firstDetail['order'],
          '-');
      row['resi'] = _text(
          row['resi'] ?? row['tracking_number'] ?? firstDetail['resi'], '-');
      row['local_sku'] = _text(
          row['local_sku'] ?? row['sku'] ?? firstDetail['local_sku'], '-');
      row['order_status'] = _text(
          row['order_status'] ?? row['status'] ?? firstDetail['status'], '-');
      row['qty'] = qty;
      row['order_date'] = row['order_date'] ?? firstDetail['order_date'];
      row['payout_reason'] =
          _text(row['payout_reason'] ?? firstDetail['payout_reason'], '');
      row['resi_reason'] =
          _text(row['resi_reason'] ?? firstDetail['resi_reason'], '');
      row['detail_order_count'] = details.isNotEmpty
          ? details.length
          : _num(row['detail_order_count']).toInt();
      return row;
    }).toList();
  }

  String _abnormalSubtitle(Map<String, dynamic> row) {
    final marketplace = _marketplaceName(_text(row['marketplace'], 'all'));
    final accountName = _accountNameById(_text(row['marketplace_account_id']));
    final count = _num(row['detail_order_count']).toInt();
    final date =
        _dateTime(row['created_at'] ?? row['updated_at'] ?? row['order_date']);
    final parts = <String>[
      marketplace,
      if (accountName != 'Semua toko') accountName,
      if (count > 1) '$count detail order',
      if (date != '-') date,
    ];
    return parts.join(' · ');
  }

  void _cacheFinanceProgress() {
    _cachedProgressTitle = _progressTitle;
    _cachedProgressLines
      ..clear()
      ..addAll(_progressLines.take(12));
  }

  List<String> _abnormalStatusOptions() {
    return const [
      'all',
      'sample_free',
      'no_payout',
      'payout_minus',
      'low_margin',
    ];
  }

  String _abnormalFilterLabel(String value) {
    switch (value.toLowerCase()) {
      case 'all':
        return 'Semua';
      case 'sample_free':
        return 'Sample/Gratis';
      case 'no_payout':
        return 'No Payout';
      case 'payout_minus':
        return 'Payout Minus';
      case 'low_margin':
        return 'Low Margin';
      default:
        return value;
    }
  }

  String? _abnormalServerStatusParam(String value) {
    switch (value.toLowerCase()) {
      case 'payout_minus':
        return 'NEGATIVE_PAYOUT';
      case 'all':
      case 'sample_free':
      case 'no_payout':
      case 'low_margin':
      default:
        return null;
    }
  }

  bool _abnormalUsesClientPaging([String? value]) {
    switch ((value ?? _abnormalStatusFilter).toLowerCase()) {
      case 'sample_free':
      case 'no_payout':
      case 'low_margin':
        return true;
      default:
        return false;
    }
  }

  bool _abnormalRowMatchesSearch(Map<String, dynamic> row, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final haystack = [
      row['order_id'],
      row['external_order_id'],
      row['order_sn'],
      row['resi'],
      row['tracking_number'],
      row['local_sku'],
      row['seller_sku'],
      row['sku'],
      row['marketplace_sku'],
      row['variant_name'],
      row['marketplace_variant_name'],
      row['title'],
      row['product_name'],
      row['message'],
      row['note'],
    ].map((item) => _text(item, '').toLowerCase()).join(' ');
    return haystack.contains(q);
  }

  bool _isSampleFreeAbnormalRow(Map<String, dynamic> row) {
    final status = _text(
            row['abnormal_status'] ??
                row['finance_status'] ??
                row['payout_status'] ??
                row['category'] ??
                row['source'],
            '')
        .toLowerCase();
    final evidence = _text(
            row['sample_evidence_source'] ??
                row['sample_source'] ??
                row['sample_free_source'],
            '')
        .toLowerCase();
    final searchable = [
      row['message'],
      row['note'],
      row['description'],
      row['payment_status'],
      row['payment_text'],
      row['order_status'],
      row['title'],
    ].map((item) => _text(item, '').toLowerCase()).join(' ');
    return row['is_sample_order'] == true ||
        evidence.contains('sample') ||
        evidence.contains('discount_100') ||
        evidence.contains('finance_flag') ||
        status.contains('sample') ||
        status.contains('gratis') ||
        status.contains('free') ||
        searchable.contains('sample') ||
        searchable.contains('gratis') ||
        searchable.contains('free');
  }

  bool _hasPayoutMinusSettlementReason(Map<String, dynamic> row) {
    final payout = _num(row['payout_amount'] ??
        row['payout_total'] ??
        row['payout'] ??
        row['received_amount'] ??
        row['net_settlement']);
    final diff = _num(row['difference_amount'] ?? row['gap_amount']);
    final status = _text(
            row['abnormal_status'] ??
                row['finance_status'] ??
                row['payout_status'] ??
                row['status'],
            '')
        .toLowerCase();
    final reason = _text(
            row['payout_reason'] ??
                row['abnormal_reason'] ??
                row['message'] ??
                row['note'],
            '')
        .toLowerCase();
    return payout < 0 ||
        diff < 0 ||
        status.contains('negative') ||
        status.contains('payout_minus') ||
        status.contains('negative_payout') ||
        reason.contains('settlement') ||
        reason.contains('negative payout') ||
        reason.contains('payout minus dari settlement');
  }

  bool _isNoPayoutAbnormalRow(Map<String, dynamic> row) {
    if (_isSampleFreeAbnormalRow(row) &&
        !_hasPayoutMinusSettlementReason(row)) {
      return false;
    }
    final payout = _num(row['payout_amount'] ??
        row['payout_total'] ??
        row['payout'] ??
        row['received_amount'] ??
        row['net_settlement']);
    final status = _text(
            row['abnormal_status'] ??
                row['finance_status'] ??
                row['payout_status'] ??
                row['status'],
            '')
        .toLowerCase();
    final orderStatus = _text(
            row['order_status'] ??
                row['status_order'] ??
                row['live_status'] ??
                row['marketplace_order_status'],
            '')
        .toUpperCase();
    const activeStatuses = [
      'AWAITING_SHIPMENT',
      'READY_TO_SHIP',
      'AWAITING_COLLECTION',
      'IN_TRANSIT',
      'TO_SHIP',
      'TO_PACK',
      'PROCESSED',
      'UNSHIPPED',
    ];
    if (activeStatuses.any(orderStatus.contains)) return false;
    final resi =
        _text(row['resi'] ?? row['tracking_number'] ?? row['awb'], '').trim();
    if (resi.isEmpty || resi == '-') return false;
    final orderDate = _parseDate(row['order_date'] ??
        row['order_created_at'] ??
        row['created_at'] ??
        row['date']);
    if (orderDate != null && DateTime.now().difference(orderDate).inDays < 7) {
      return false;
    }
    return payout == 0 &&
        (status.contains('missing_payout_final') ||
            status.contains('no_payout_eligible') ||
            status.contains('no_payout') ||
            status.contains('missing payout'));
  }

  bool _isLowMarginAbnormalRow(Map<String, dynamic> row) {
    if (_isSampleFreeAbnormalRow(row)) return false;
    final payout = _num(row['payout_amount'] ??
        row['payout_total'] ??
        row['payout'] ??
        row['received_amount'] ??
        row['net_settlement']);
    final hpp = _num(row['hpp'] ?? row['hpp_total'] ?? row['total_hpp']);
    final explicitMargin =
        _num(row['net_margin_percent'] ?? row['margin_percent']);
    final margin = explicitMargin != 0
        ? explicitMargin
        : payout > 0
            ? ((payout - hpp) / payout * 100)
            : 0;
    final target = _numFirstNonZero([
      row['target_margin_percent'],
      row['margin_target_percent'],
      row['target_net_margin_percent'],
    ]);
    final hppMapped = hpp > 0 ||
        _text(row['hpp_status'] ?? row['hpp_source'] ?? row['mapping_status'])
            .toLowerCase()
            .contains('mapped');
    return payout > 0 && hppMapped && target > 0 && margin < target;
  }

  List<Map<String, dynamic>> _abnormalFilterSource() {
    final byKey = <String, Map<String, dynamic>>{};
    void add(Map<String, dynamic> row) {
      if (!_rowMatchesSelectedScope(row)) return;
      final key = [
        _text(row['marketplace_order_item_id'], ''),
        _text(row['marketplace_order_id'], ''),
        _text(
            row['order_id'] ?? row['order_sn'] ?? row['external_order_id'], ''),
        _text(row['local_sku'] ?? row['sku'], ''),
        _text(row['abnormal_status'] ?? row['category'], ''),
      ].where((part) => part.trim().isNotEmpty && part != '-').join('|');
      byKey[key.isEmpty ? 'row_${byKey.length}' : key] = row;
    }

    for (final row in _abnormalServerLoaded ? _serverAbnormales : _abnormals) {
      add(row);
    }
    for (final row in _sampleFreeOrders) {
      add(row);
    }
    return byKey.values.toList();
  }

  List<Map<String, dynamic>> _filteredAbnormales({bool paged = true}) {
    final source = _abnormalFilterSource();
    final filter = _abnormalStatusFilter.trim().toLowerCase();
    final query = _abnormalSearchController.text.trim();
    final filtered = source.where((row) {
      if (!_abnormalRowMatchesSearch(row, query)) return false;
      if (!_abnormalServerLoaded && _shouldHideZeroCancelAbnormal(row))
        return false;
      if (filter.isEmpty || filter == 'all') {
        if (_isSampleFreeAbnormalRow(row)) return false;
        final isPayoutMinus = _hasPayoutMinusSettlementReason(row);
        if (isPayoutMinus) return true;
        final orderStatus = _text(
                row['order_status'] ?? row['status'] ?? row['live_status'], '')
            .toUpperCase();
        if (_isCancelLikeStatus(orderStatus)) return false;
        const activeStatuses = [
          'AWAITING_SHIPMENT',
          'READY_TO_SHIP',
          'AWAITING_COLLECTION',
          'IN_TRANSIT',
          'TO_SHIP',
          'TO_PACK',
          'PROCESSED',
          'UNSHIPPED',
        ];
        if (activeStatuses.any(orderStatus.contains)) return false;
        final resi =
            _text(row['resi'] ?? row['tracking_number'] ?? row['awb'], '')
                .trim();
        if (resi.isEmpty || resi == '-') return false;
        return true;
      }
      if (filter == 'sample_free') return _isSampleFreeAbnormalRow(row);
      if (filter == 'no_payout') return _isNoPayoutAbnormalRow(row);
      if (filter == 'payout_minus') {
        return _hasPayoutMinusSettlementReason(row);
      }
      if (filter == 'low_margin') return _isLowMarginAbnormalRow(row);
      final status = _text(row['abnormal_status'] ??
              row['payout_status'] ??
              row['order_status'] ??
              row['status'])
          .trim()
          .toUpperCase();
      return status == filter.toUpperCase() ||
          _text(row['order_status'] ?? row['status']).trim().toUpperCase() ==
              filter.toUpperCase();
    }).toList();
    if (!paged) return filtered;
    if (_abnormalUsesClientPaging()) {
      final page = _abnormalPage <= 1 ? 1 : _abnormalPage;
      return filtered
          .skip((page - 1) * _abnormalPageSize)
          .take(_abnormalPageSize)
          .toList();
    }
    return filtered.take(_abnormalPageSize).toList();
  }

  int _visibleAbnormalTotal() {
    if (_abnormalUsesClientPaging()) {
      return _filteredAbnormales(paged: false).length;
    }
    return _abnormalTotal;
  }

  //  Abnormal reader
  // True duplicate check: marketplace_account_id + external_order_id + external_order_item_id.
  // Status mapping:
  //   PENDING_PAYOUT        ->  waiting, not error, not refresh-payout data.
  //   MISSING_PAYOUT_FINAL  ->  real abnormal, COMPLETED order without payout.
  //   NO_PAYOUT_EXPECTED    ->  excluded from payout refresh, show as greyed-out.
  //   CANCEL_OR_RETURN_DONE ->  finished without stock-in (cancelled before packing).
  //   DELIVERED w/o payout  ->  not a final abnormal unless status COMPLETED.

  static const _abnormalRpcV82 = 'finance_abnormal_search';
  String _activeAbnormalRpc = _abnormalRpcV82;

  Future<List<Map<String, dynamic>>> _fetchRawNegativePayoutRowsPage(
      {required int page}) async {
    final startDate = _toDateParam(_start);
    final endDate = _toDateParam(_end);
    final marketplace = _marketplaceParam();
    final accountId = _accountUuidParam();
    final from = ((page <= 1 ? 1 : page) - 1) * _abnormalPageSize;
    final to = from + _abnormalPageSize - 1;

    try {
      dynamic query = _client
          .from('marketplace_finance_reports')
          .select(
              'finance_report_id, order_id, marketplace_order_id, marketplace_account_id, marketplace, period_start, gross_amount, gross_sales, payout_amount, received_amount, net_settlement, total_hpp')
          .gte('period_start', startDate)
          .lte('period_start', endDate)
          .or('payout_amount.lt.0,received_amount.lt.0,net_settlement.lt.0');
      if (marketplace != null) query = query.eq('marketplace', marketplace);
      if (accountId != null)
        query = query.eq('marketplace_account_id', accountId);
      final response =
          await query.order('period_start', ascending: false).range(from, to);
      final rows = _asList(response)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      return rows.map((row) {
        final payout = _numFirstNonZero([
          row['payout_amount'],
          row['received_amount'],
          row['net_settlement'],
        ]);
        final gross = _numFirstNonZero([
          row['gross_amount'],
          row['gross_sales'],
        ]);
        final orderId =
            _text(row['order_id'] ?? row['marketplace_order_id'], '-');
        final periodStart = _text(row['period_start'], '');
        final orderDate = periodStart.length >= 10
            ? periodStart.substring(0, 10)
            : periodStart;
        final detail = <String, dynamic>{
          'gross': gross,
          'payout': payout,
          'order_id': orderId,
          'order_date': orderDate,
          'statement_id': null,
          'net_settlement': payout,
          'received_amount': payout,
          'settlement_date': null,
          'finance_report_id': row['finance_report_id'],
          'marketplace_order_id': row['marketplace_order_id'],
        };
        return <String, dynamic>{
          'hpp': _num(row['total_hpp']),
          'resi': '-',
          'gross': gross,
          'title': orderId,
          'status': 'NEGATIVE_PAYOUT',
          'message': 'Payout minus berdasarkan raw finance period_start',
          'order_id': orderId,
          'order_sn': orderId,
          'hpp_total': _num(row['total_hpp']),
          'order_date': orderDate,
          'marketplace': _text(row['marketplace'], 'marketplace'),
          'gross_amount': gross,
          'order_status': 'FINANCE_REPORT',
          'payout_total': payout,
          'statement_id': null,
          'order_details': [detail],
          'payout_amount': payout,
          'payout_status': 'NEGATIVE_PAYOUT',
          'finance_status': 'NEGATIVE_PAYOUT',
          'abnormal_status': 'NEGATIVE_PAYOUT',
          'difference_amount': payout,
          'external_order_id': orderId,
          'detail_order_count': 1,
          'marketplace_order_id': row['marketplace_order_id'],
          'marketplace_account_id': row['marketplace_account_id'],
        };
      }).toList();
    } catch (e) {
      debugPrint('Raw negative payout fallback failed: $e');
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _loadAbnormalesPage(
      {bool silent = false, bool resetPage = false}) async {
    if (!mounted) return;
    final page = resetPage ? 1 : _abnormalPage;
    if (!silent) setState(() => _abnormalSearchBusy = true);

    final params = <String, dynamic>{
      'p_start': _toDateParam(_start),
      'p_end': _toDateParam(_end),
      'p_marketplace': _marketplaceRpcParam(),
      'p_account_id': _accountUuidParam(),
      'p_search': _abnormalSearchController.text.trim().isEmpty
          ? null
          : _abnormalSearchController.text.trim(),
      'p_status': _abnormalServerStatusParam(_abnormalStatusFilter),
      'p_page': page,
      'p_page_size': _abnormalPageSize,
    };

    try {
      final selectedRes = await _client.rpc(_abnormalRpcV82, params: params);
      const selectedRpc = _abnormalRpcV82;
      final map = _asMap(selectedRes);
      if (!mounted) return;
      var rawRows =
          _asList(map['rows']).where(_rowMatchesSelectedScope).toList();
      final aggregates = _asMap(map['aggregates']);
      // RPC adalah source of truth. Jangan fallback ke raw finance saat RPC sukses tapi rows kosong.
      // Jangan fallback ke cache lokal saat RPC sukses. Cache lama bisa membawa abnormal kosong/ngaco.

      setState(() {
        _activeAbnormalRpc = rawRows.isNotEmpty && _asList(map['rows']).isEmpty
            ? 'marketplace_finance_reports_raw_negative_payout'
            : selectedRpc;
        _serverAbnormales = rawRows;
        _abnormalTotal = _num(map['total']).toInt();
        _abnormalPage = _num(map['page']).toInt().clamp(1, 999999).toInt();
        _abnormalLoadError = null;

        if (aggregates.isNotEmpty) {
          final nextSummary = Map<String, dynamic>.from(_summary);
          for (final key in const [
            'total',
            'abnormal_count',
            'negative_payout_count',
            'negative_payout_total',
            'negative_payout_total_abs',
            'minus_payout_total',
            'minus_payout_total_abs',
            'payout_minus_total',
            'payout_minus_total_abs',
            'low_margin_count',
          ]) {
            final value = aggregates[key];
            if (value != null) nextSummary[key] = value;
          }
          if (nextSummary['abnormal_count'] == null &&
              aggregates['total'] != null) {
            nextSummary['abnormal_count'] = aggregates['total'];
          }
          _summary = nextSummary;
        }

        _abnormalServerLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      var fallbackRows = await _fetchRawNegativePayoutRowsPage(page: page);
      if (fallbackRows.isEmpty && _abnormals.isNotEmpty) {
        fallbackRows = _abnormals
            .where(_rowMatchesSelectedScope)
            .skip(((page <= 1 ? 1 : page) - 1) * _abnormalPageSize)
            .take(_abnormalPageSize)
            .toList();
      }
      if (fallbackRows.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _activeAbnormalRpc =
              'marketplace_finance_reports_raw_negative_payout';
          _serverAbnormales = fallbackRows;
          final fallbackTotal = _numFirstNonZero([
            _summary['negative_payout_count'],
            _summary['abnormal_count'],
          ]).toInt();
          _abnormalTotal =
              fallbackTotal > 0 ? fallbackTotal : fallbackRows.length;
          _abnormalPage = page;
          _abnormalServerLoaded = true;
          _abnormalLoadError = null;
        });
      } else if (!silent) {
        setState(() {
          _serverAbnormales = [];
          _abnormalTotal = 0;
          _abnormalServerLoaded = false;
          _abnormalLoadError = _cleanError(error);
        });
      }
    } finally {
      if (mounted && !silent) setState(() => _abnormalSearchBusy = false);
    }
  }

  //  Abnormal status helpers

  /// Human-readable badge for abnormal status.
  /// Returns (label, color, isExcluded, isPending, isFinal)
  ({
    String label,
    Color color,
    bool isExcluded,
    bool isPending,
    bool isCancelDone
  }) _abnormalStatusInfo(Map<String, dynamic> row) {
    final financeStatus = _text(
            row['abnormal_status'] ??
                row['finance_status'] ??
                row['payout_status'],
            '')
        .toUpperCase();
    final orderStatus =
        _text(row['order_status'] ?? row['status'], '').toUpperCase();
    // Semua payout minus tetap dianggap abnormal. Tidak ada no payout exclusion di tab ini.
    if (financeStatus == 'SAFE_CANCEL_UNPAID' ||
        financeStatus == 'CANCEL_OR_RETURN_DONE' ||
        (orderStatus.contains('CANCEL') &&
            _text(row['tracking_number'], '').isEmpty)) {
      return (
        label: 'Cancel/unpaid aman',
        color: Theme.of(context).colorScheme.primary,
        isExcluded: false,
        isPending: false,
        isCancelDone: true
      );
    }
    if (financeStatus == 'PENDING_PAYOUT') {
      return (
        label: 'Menunggu payout',
        color: Theme.of(context).colorScheme.secondary,
        isExcluded: false,
        isPending: true,
        isCancelDone: false
      );
    }
    if (financeStatus == 'PENDING_SETTLEMENT') {
      return (
        label: 'Belum final',
        color: Theme.of(context).colorScheme.secondary,
        isExcluded: false,
        isPending: true,
        isCancelDone: false
      );
    }
    if (financeStatus == 'MISSING_PAYOUT_FINAL') {
      return (
        label: 'Belum payout (final)',
        color: Theme.of(context).colorScheme.error,
        isExcluded: false,
        isPending: false,
        isCancelDone: false
      );
    }
    if (financeStatus == 'OK') {
      return (
        label: 'Payout OK',
        color: Theme.of(context).colorScheme.primary,
        isExcluded: false,
        isPending: false,
        isCancelDone: false
      );
    }

    // Payout minus
    final payout =
        _num(row['payout_amount'] ?? row['payout_total'] ?? row['payout']);
    if (payout < 0) {
      return (
        label: 'Payout minus/koreksi',
        color: Theme.of(context).colorScheme.secondary,
        isExcluded: false,
        isPending: false,
        isCancelDone: false
      );
    }
    if (payout > 0) {
      // Payout ada tapi mungkin lebih besar dari gross
      final gross =
          _num(row['expected_amount'] ?? row['gross'] ?? row['gross_amount']);
      if (gross > 0 && payout > gross * 1.05) {
        return (
          label: 'Payout lebih besar',
          color: Theme.of(context).colorScheme.secondary,
          isExcluded: false,
          isPending: false,
          isCancelDone: false
        );
      }
    }
    if (payout <= 0 && orderStatus == 'COMPLETED') {
      return (
        label: 'Belum payout',
        color: Theme.of(context).colorScheme.error,
        isExcluded: false,
        isPending: false,
        isCancelDone: false
      );
    }
    return (
      label: 'Perlu cek',
      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.82),
      isExcluded: false,
      isPending: false,
      isCancelDone: false
    );
  }

  /// Whether an order is a TRUE refresh-payout data:
  /// Only COMPLETED orders without payout, not excluded, not pending.
  bool _isRefreshPayoutCandidate(Map<String, dynamic> row) {
    final orderStatus =
        _text(row['order_status'] ?? row['status'], '').toUpperCase();
    final financeStatus = _text(
            row['abnormal_status'] ??
                row['finance_status'] ??
                row['payout_status'],
            '')
        .toUpperCase();
    if (financeStatus == 'PENDING_PAYOUT' ||
        financeStatus == 'PENDING_SETTLEMENT' ||
        financeStatus == 'OK') return false;
    if (financeStatus == 'MISSING_PAYOUT_FINAL') return true;
    if (orderStatus != 'COMPLETED') return false;
    final payout =
        _num(row['payout_amount'] ?? row['payout_total'] ?? row['payout']);
    return payout <= 0;
  }

  /// Unmark no-payout exclusion.
  Future<void> _unmarkNoPayoutExclusion(Map<String, dynamic> row) async {
    if (_processing) return;
    final orderId =
        _text(row['order_id'] ?? row['external_order_id'] ?? row['order_sn']);
    final accountId = _text(row['marketplace_account_id']);
    if (orderId.trim().isEmpty || !_isUuid(accountId)) {
      AppUi.safeSnack(context, 'Order/account tidak valid untuk di-unmark.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: (Theme.of(context).cardColor),
        title: Text('Hapus tanda no payout?'),
        content: Text(
            'Order $orderId akan masuk kembali ke kandidat payout otomatis.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Unmark')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _processing = true);
    try {
      await _client.rpc('finance_unmark_no_payout_order', params: {
        'p_order_id': orderId,
        'p_account_id': accountId,
      });
      if (!mounted) return;
      AppUi.safeSnack(context,
          'Tanda no payout dihapus. Order kembali masuk kandidat refresh.');
      await _loadAbnormalesPage(resetPage: true);
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  /// Tandai cancel/unpaid orders as no-payout for the current period.
  Future<void> _autoMarkCancelNoPayoutForPeriod() async {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return;
    }
    if (_processing) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: (Theme.of(context).cardColor),
        title: Text('Tandai order batal/unpaid?'),
        content: Text(
          'Semua order cancel dan unpaid tanpa settlement pada periode ini akan ditandai sebagai "no payout expected" secara otomatis. Lanjutkan?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Tandai')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _processing = true);
    try {
      final res =
          await _client.rpc('finance_auto_mark_cancel_no_payout', params: {
        'p_start': _toDateParam(_start),
        'p_end': _toDateParam(_end),
        'p_account_id': _accountUuidParam(),
      });
      final map = _asMap(res);
      final marked = _num(map['marked']).toInt();
      if (!mounted) return;
      AppUi.safeSnack(
          context, '$marked order berhasil ditandai no payout expected.');
      await _loadAbnormalesPage(resetPage: true);
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _refreshAbnormalTab({bool resetPage = false}) async {
    if (resetPage) _abnormalPage = 1;
    if (_abnormalUsesClientPaging() && _abnormalServerLoaded) {
      if (mounted) setState(() {});
      return;
    }
    await _loadAbnormalesPage(resetPage: resetPage);
  }

  Future<void> _markNoPayoutExclusion(Map<String, dynamic> row) async {
    if (_processing) return;
    final orderId =
        _text(row['order_id'] ?? row['external_order_id'] ?? row['order_sn']);
    final accountId = _text(row['marketplace_account_id']);
    if (orderId.trim().isEmpty || !_isUuid(accountId)) {
      AppUi.safeSnack(context, 'Order/account tidak valid untuk ditandai.');
      return;
    }
    // Jangan tandai PENDING_PAYOUT  payout-nya mungkin masih akan cair.
    final finStatus = _text(
            row['abnormal_status'] ??
                row['finance_status'] ??
                row['payout_status'],
            '')
        .toUpperCase();
    if (finStatus == 'PENDING_PAYOUT') {
      AppUi.safeSnack(context,
          'Order masih menunggu payout (PENDING). Tandai no payout hanya untuk order yang memang tidak akan ada settlement.');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: (Theme.of(context).cardColor),
        title: Text('Tandai no payout expected?'),
        content: Text(
          'Order $orderId akan dikeluarkan dari kandidat payout otomatis. Pakai untuk order cancel/return yang memang tidak akan ada settlement.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Tandai')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _processing = true);
    try {
      final candidates = <String>[
        'finance_mark_no_payout_order',
        'finance_mark_no_payout_order',
      ];
      await _rpcWithFallback(candidates, {
        'p_order_id': orderId,
        'p_account_id': accountId,
        'p_reason': 'manual_no_payout_expected',
        'p_note': 'Ditandai dari tab Abnormal Laporan Keuangan',
      });
      if (!mounted) return;
      AppUi.safeSnack(context,
          'Order ditandai no payout expected dan tidak akan muncul di kandidat refresh.');
      await _loadAbnormalesPage(resetPage: true);
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _clearMarketplaceFinanceData() async {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return;
    }
    if (_processing) return;

    final selectedAccountId = _accountUuidParam();
    final scope = selectedAccountId == null
        ? 'semua akun marketplace'
        : 'akun toko yang sedang dipilih';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: (Theme.of(context).cardColor),
        title: Text('Bersihkan tampilan laporan?'),
        content: Text(
          'Sistem akan memuat ulang laporan untuk $scope dan menjaga data order, payout, mapping SKU, serta biaya manual tetap aman.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Muat ulang'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    if (!mounted) return;
    setState(() => _processing = true);
    try {
      await _client.rpc(
        'marketplace_reset_order_finance_data',
        params: {
          'p_account_id': selectedAccountId,
        },
      );
      await _load(ignoreLocalCache: true);
      if (!mounted) return;
      AppUi.safeSnack(
        context,
        'Laporan dimuat ulang. Data order, payout, mapping SKU, dan biaya manual tetap aman.',
      );
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(
          context, 'Laporan belum bisa dimuat ulang: ${_cleanError(e)}');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _pullFinanceReportForSelectedPeriod() async {
    if (_isDemoSuperAdmin) {
      await _load();
      return;
    }

    if (!mounted) return;
    setState(() {
      _processing = true;
      _progressTitle = 'Tarik data finance';
      _progressLines
        ..clear()
        ..add(
            'Menyiapkan pembaruan finance ${_date(_start)} s/d ${_date(_end)}.');
      _cacheFinanceProgress();
    });
    await _saveFinanceRuntimeProgress(
        status: 'running', title: _progressTitle, lines: _progressLines);

    var checked = 0;
    var success = 0;
    var failed = 0;
    var skipped = 0;
    var requeued = 0;

    try {
      await _loadCurrentRole();
      if (_currentTenantId.trim().isEmpty) {
        throw Exception('Sesi akun tidak lengkap. Login ulang.');
      }

      final selectedMarketplace = _marketplaceParam();
      if (selectedMarketplace != null && selectedMarketplace != 'tiktok_shop') {
        await _load();
        if (!mounted) return;
        AppUi.safeSnack(context,
            'Tarik data finance otomatis baru tersedia untuk TikTok Shop.');
        return;
      }

      final selectedAccountId = _accountUuidParam();
      final response = await _client.functions.invoke(
        'marketplace-tiktok-service',
        body: {
          'action': 'process_finance_sync_jobs',
          'params': {
            'tenant_id': _currentTenantId,
            if (selectedAccountId != null) 'account_id': selectedAccountId,
            'mode': 'period',
            'start_date': _toDateParam(_dateOnly(_start)),
            'end_date': _toDateParam(_dateOnly(_end)),
            'enqueue': true,
            'force_requeue': true,
            'missing_only': true,
            'max_jobs': 1,
            'max_orders': 10,
            'max_batches_per_job': 3,
            'source': 'finance_page_manual',
          },
        },
      );

      final raw = response.data;
      if (response.status < 200 ||
          response.status >= 300 ||
          raw is! Map ||
          raw['ok'] == false) {
        final msg = raw is Map
            ? _text(raw['message'], raw.toString())
            : 'Respons pembaruan finance belum sesuai.';
        throw Exception(msg);
      }

      final map = Map<String, dynamic>.from(raw);
      checked = _num(map['checked'] ?? map['transactions']).toInt();
      success = _num(map['payout_success'] ?? map['items']).toInt();
      failed = _num(map['failed']).toInt();
      skipped = _num(map['skipped']).toInt();
      requeued = _num(map['requeued']).toInt();

      if (mounted) {
        setState(() {
          _progressTitle = 'Tarik data finance sedang diproses';
          _progressLines
            ..clear()
            ..add(
                'Pembaruan dikirim. Dicek $checked, berhasil $success, gagal $failed.')
            ..add(requeued > 0
                ? 'Sisa data akan dilanjutkan otomatis.'
                : 'Data terbaru akan dimuat ulang.');
          _cacheFinanceProgress();
        });
      }

      await _saveFinanceRuntimeProgress(
        status: failed > 0 ? 'partial' : (requeued > 0 ? 'running' : 'success'),
        title: _progressTitle,
        lines: _progressLines,
        checked: checked,
        success: success,
        failed: failed,
        skipped: skipped,
      );

      await _recordManualFinanceSyncLog(
        success: success,
        failed: failed,
        skipped: skipped,
        checked: checked,
        message:
            'Tarik data finance ${_date(_start)} s/d ${_date(_end)}. Dicek $checked, berhasil $success, gagal $failed.',
      );

      await _refreshFinanceCacheForSelectedPeriod();
      await _load(ignoreLocalCache: true);
      if (!mounted) return;
      AppUi.safeSnack(
        context,
        'Tarik data finance diproses. Dicek $checked, berhasil $success, gagal $failed. Sisa data akan diproses otomatis.',
      );
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
      await _load();
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          if (_progressTitle.trim().isEmpty)
            _progressTitle = 'Status auto finance';
          _cacheFinanceProgress();
        });
      }
    }
  }

  Future<void> _refreshFinanceDataForSelectedPeriod() async {
    if (_isDemoSuperAdmin) {
      await _load();
      return;
    }

    if (!mounted) return;
    setState(() {
      _processing = true;
      _progressTitle = 'Perbarui payout';
      _progressLines
        ..clear()
        ..add(
            'Memproses data yang belum punya payout ${_date(_start)} s/d ${_date(_end)}.');
      _cacheFinanceProgress();
    });
    await _saveFinanceRuntimeProgress(
        status: 'running', title: _progressTitle, lines: _progressLines);

    var checked = 0;
    var success = 0;
    var failed = 0;
    var skipped = 0;
    var requeued = 0;

    try {
      await _loadCurrentRole();
      if (_currentTenantId.trim().isEmpty) {
        throw Exception('Sesi akun tidak lengkap. Login ulang.');
      }

      final selectedMarketplace = _marketplaceParam();
      if (selectedMarketplace != null && selectedMarketplace != 'tiktok_shop') {
        await _load();
        if (!mounted) return;
        AppUi.safeSnack(
            context, 'Auto payout sementara baru aktif untuk TikTok Shop.');
        return;
      }

      final selectedAccountId = _accountUuidParam();
      final response = await _client.functions.invoke(
        'marketplace-tiktok-service',
        body: {
          'action': 'process_finance_sync_jobs',
          'params': {
            'tenant_id': _currentTenantId,
            if (selectedAccountId != null) 'account_id': selectedAccountId,
            'mode': 'period',
            'start_date': _toDateParam(_dateOnly(_start)),
            'end_date': _toDateParam(_dateOnly(_end)),
            'enqueue': true,
            'force_requeue': true,
            'missing_only': true,
            'max_jobs': 1,
            'max_orders': 10,
            'max_batches_per_job': 3,
            'source': 'refresh_payout_manual',
          },
        },
      );

      final raw = response.data;
      if (response.status < 200 ||
          response.status >= 300 ||
          raw is! Map ||
          raw['ok'] == false) {
        final msg = raw is Map
            ? _text(raw['message'], raw.toString())
            : 'Data payout belum bisa diproses.';
        throw Exception(msg);
      }

      final map = Map<String, dynamic>.from(raw);
      checked = _num(map['checked'] ?? map['transactions']).toInt();
      success = _num(map['payout_success'] ?? map['items']).toInt();
      failed = _num(map['failed']).toInt();
      skipped = _num(map['skipped']).toInt();
      requeued = _num(map['requeued']).toInt();

      if (mounted) {
        setState(() {
          _progressTitle = 'Payout sedang diperbarui';
          _progressLines
            ..clear()
            ..add(
                'Pembaruan dikirim. Dicek $checked, berhasil $success, gagal $failed.')
            ..add(
                'Halaman boleh ditutup. Sisa data yang belum selesai akan diproses otomatis.');
          _cacheFinanceProgress();
        });
      }

      await _saveFinanceRuntimeProgress(
        status: failed > 0 ? 'partial' : (requeued > 0 ? 'running' : 'success'),
        title: _progressTitle,
        lines: _progressLines,
        checked: checked,
        success: success,
        failed: failed,
        skipped: skipped,
      );

      await _recordManualFinanceSyncLog(
        success: success,
        failed: failed,
        skipped: skipped,
        checked: checked,
        message:
            'Perbarui payout ${_date(_start)} s/d ${_date(_end)}. Dicek $checked, berhasil $success, gagal $failed.',
      );

      await _refreshFinanceCacheForSelectedPeriod();
      await _load(ignoreLocalCache: true);
      if (!mounted) return;
      final text = checked == 0
          ? 'Tidak ada data payout baru pada periode ini.'
          : 'Payout sedang diperbarui. Dicek $checked, berhasil $success, gagal $failed. Sisa data diproses otomatis.';
      AppUi.safeSnack(context, text);
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
      await _load();
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          if (_progressTitle.trim().isEmpty)
            _progressTitle = 'Status auto finance';
          _cacheFinanceProgress();
        });
      }
    }
  }

  Future<void> _recordManualFinanceSyncLog({
    required int success,
    required int failed,
    required int skipped,
    required int checked,
    String? message,
  }) async {
    try {
      await _client.rpc(
        'finance_record_sync_log',
        params: {
          'p_sync_type': 'manual_period',
          'p_start': _toDateParam(_start),
          'p_end': _toDateParam(_end),
          'p_marketplace': _marketplaceRpcParam(),
          'p_account_id': _accountUuidParam(),
          'p_checked': checked,
          'p_success': success,
          'p_failed': failed,
          'p_skipped': skipped,
          'p_message': message ??
              'Auto payout periode ${_date(_start)} s/d ${_date(_end)}',
        },
      );
    } catch (_) {
      // Log bersifat tambahan. Jangan bikin refresh gagal hanya karena tabel log belum ada.
    }
  }

  Future<void> _exportAllMarketplaceFinanceReport() async {
    if (!mounted) return;
    setState(() => _processing = true);

    try {
      await _loadCurrentRole();

      final params = {
        'p_start': _toDateParam(_start),
        'p_end': _toDateParam(_end),
        // Export harus mencakup semua marketplace dan semua akun toko pada periode ini.
        'p_marketplace': null,
        'p_account_id': null,
      };

      final response = await _loadFinanceSnapshot(params);

      final data = _asMap(response);
      final workbook = Excel.createExcel();

      _appendKeyValueSheet(workbook, 'RINGKASAN', _asMap(data['summary']));
      _appendMapSheet(
          workbook, 'HARIAN', _asList(data['daily'] ?? data['by_date']));
      _appendMapSheet(
          workbook, 'PER_MARKETPLACE', _asList(data['by_marketplace']));
      _appendMapSheet(workbook, 'PER_SKU', _asList(data['by_sku']));
      _appendMapSheet(workbook, 'ARUS_KAS', _asList(data['cash_flow']));
      _appendMapSheet(workbook, 'BIAYA_OPERASIONAL', _asList(data['expenses']));
      _appendMapSheet(workbook, 'LABA_RUGI', _asList(data['profit_loss']));
      _appendMapSheet(workbook, 'ABNORMAL', _asList(data['abnormals']));
      _appendMapSheet(workbook, 'AKUN_MARKETPLACE', _asList(data['accounts']));
      _appendMapSheet(workbook, 'SUMBER_DATA', _asList(data['sources']));
      _appendMapSheet(
          workbook, 'PEMBELIAN_APPROVED', _asList(data['approved_purchases']));
      _appendMapSheet(
          workbook, 'BIAYA_RINGKASAN', _asList(data['operational_summary']));

      final info = workbook['INFO'];
      info.appendRow(
          <CellValue>[TextCellValue('field'), TextCellValue('value')]);
      info.appendRow(<CellValue>[
        TextCellValue('periode_mulai'),
        TextCellValue(_toDateParam(_start))
      ]);
      info.appendRow(<CellValue>[
        TextCellValue('periode_selesai'),
        TextCellValue(_toDateParam(_end))
      ]);
      info.appendRow(<CellValue>[
        TextCellValue('scope'),
        TextCellValue('semua marketplace dan semua toko')
      ]);
      info.appendRow(<CellValue>[
        TextCellValue('dibuat_pada'),
        TextCellValue(DateTime.now().toIso8601String())
      ]);

      final defaultSheet = workbook.getDefaultSheet();
      if (defaultSheet != null && workbook.tables.length > 1) {
        workbook.delete(defaultSheet);
      }

      final bytes = workbook.save();
      if (bytes == null) throw Exception('Gagal membuat file XLSX.');

      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final fileName = 'laporan_keuangan_semua_marketplace_$stamp.xlsx';
      final fileBytes = Uint8List.fromList(bytes);
      const mimeType =
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

      final downloaded = await downloadBytesAsFile(
        bytes: fileBytes,
        fileName: fileName,
        mimeType: mimeType,
      );
      if (downloaded) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Export laporan semua marketplace berhasil diunduh: $fileName')),
        );
        return;
      }

      await Share.shareXFiles(
        [
          XFile.fromData(
            fileBytes,
            name: fileName,
            mimeType: mimeType,
          ),
        ],
        subject: 'Laporan keuangan semua marketplace',
        text:
            'Export laporan keuangan semua marketplace periode ${_toDateParam(_start)} s/d ${_toDateParam(_end)}.',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Export laporan semua marketplace berhasil dibuat.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal export laporan: ${_cleanError(e)}')),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _pickDateRange() async {
    final firstDate = _dateOnly(
      DateTime.now().subtract(const Duration(days: 90)),
    );
    final lastDate = _dateOnly(
      DateTime.now().add(const Duration(days: 365)),
    );
    final picked = await _showCompactDateRangePicker(
      initialStart: _start,
      initialEnd: _end,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null) return;
    setState(() {
      _start =
          DateTime(picked.start.year, picked.start.month, picked.start.day);
      _end = DateTime(
          picked.end.year, picked.end.month, picked.end.day, 23, 59, 59);
      _rememberFilters();
    });
    await _clearFinanceLocalCacheForSelectedPeriod();
    await _load();
  }

  Future<DateTimeRange?> _showCompactDateRangePicker({
    required DateTime initialStart,
    required DateTime initialEnd,
    required DateTime firstDate,
    required DateTime lastDate,
  }) {
    var draftStart = _clampDate(_dateOnly(initialStart), firstDate, lastDate);
    var draftEnd = _clampDate(_dateOnly(initialEnd), firstDate, lastDate);
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
            draftStart = _clampDate(_dateOnly(start), firstDate, lastDate);
            draftEnd = _clampDate(_dateOnly(end), firstDate, lastDate);
            if (draftEnd.isBefore(draftStart)) draftEnd = draftStart;
            visibleMonth = DateTime(draftStart.year, draftStart.month);
            pickingStart = false;
          }

          void selectDay(DateTime value) {
            final picked = _clampDate(_dateOnly(value), firstDate, lastDate);
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
            title: Text('Pilih periode'),
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
                        label: Text('Dari ${_date(draftStart)}'),
                        selected: pickingStart,
                        onSelected: (_) =>
                            setSheetState(() => pickingStart = true),
                      ),
                      ChoiceChip(
                        label: Text('Sampai ${_date(draftEnd)}'),
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
                        icon: Icon(Icons.chevron_left_rounded),
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
                        icon: Icon(Icons.chevron_right_rounded),
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
                        label: Text('Hari ini'),
                        onPressed: () => setSheetState(() {
                          final today = _dateOnly(DateTime.now());
                          setDraftRange(today, today);
                        }),
                      ),
                      ActionChip(
                        label: Text('Bulan ini'),
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
                child: Text('Batal'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(
                    dialogContext,
                    DateTimeRange(start: draftStart, end: draftEnd),
                  );
                },
                child: Text('Terapkan'),
              ),
            ],
          );
        },
      ),
    );
  }

  DateTime _clampDate(DateTime value, DateTime firstDate, DateTime lastDate) {
    final date = _dateOnly(value);
    if (date.isBefore(firstDate)) return firstDate;
    if (date.isAfter(lastDate)) return lastDate;
    return date;
  }

  Future<void> _applyDatePreset(String preset) async {
    final now = DateTime.now();
    DateTime start;
    DateTime end = DateTime(now.year, now.month, now.day, 23, 59, 59);

    switch (preset) {
      case 'today':
        start = DateTime(now.year, now.month, now.day);
        break;
      case '7d':
        start = DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 6));
        break;
      case '30d':
        start = DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 29));
        break;
      case '90d':
        start = DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 89));
        break;
      case 'month':
      default:
        start = DateTime(now.year, now.month, 1);
        break;
    }

    setState(() {
      _start = start;
      _end = end;
      _rememberFilters();
    });
    await _clearFinanceLocalCacheForSelectedPeriod();
    await _load();
  }

  Future<void> _editTargetMargin(Map<String, dynamic> row) async {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return;
    }

    final sku = _text(row['sku']);
    if (sku == '-') return;

    final controller = TextEditingController(
      text: _num(row['target_margin_percent']).toStringAsFixed(2),
    );

    final result = await showDialog<num>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Target margin $sku'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Margin target (%)',
            helperText: 'Dipakai untuk membandingkan margin aktual per SKU.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text('Batal')),
          FilledButton(
            onPressed: () => Navigator.pop(
                context, num.tryParse(controller.text.replaceAll(',', '.'))),
            child: Text('Simpan'),
          ),
        ],
      ),
    );

    if (result == null) return;
    setState(() => _processing = true);
    try {
      await _client.rpc(
        'finance_upsert_sku_target_margin',
        params: {
          'p_sku': sku,
          'p_target_margin_percent': result,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Target margin disimpan.')));
      await _load(ignoreLocalCache: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_cleanError(e))));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _addManualExpense() async {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return;
    }

    await _refreshExpenseCategories();

    final manualCategory = TextEditingController();
    final note = TextEditingController();
    final amount = TextEditingController();
    DateTime expenseDate = DateTime.now();
    String selectedCategory = _expenseCategoryOptions.isEmpty
        ? 'Salary'
        : _expenseCategoryOptions.first;
    bool useManualCategory = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final maxHeight = (MediaQuery.of(context).size.height -
                  MediaQuery.of(context).viewInsets.bottom) *
              0.58;
          return AlertDialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            title: Text('Tambah biaya operasional'),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: maxHeight.clamp(260.0, 520.0).toDouble()),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      value:
                          useManualCategory ? '__manual__' : selectedCategory,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Kategori',
                        helperText:
                            'Contoh: Modal tambahan, Refund, Kas keluar.',
                      ),
                      items: [
                        ..._expenseCategoryOptions.map(
                          (item) => DropdownMenuItem<String>(
                              value: item, child: Text(item)),
                        ),
                        const DropdownMenuItem<String>(
                          value: '__manual__',
                          child: Text('Tambah kategori manual'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          useManualCategory = value == '__manual__';
                          if (!useManualCategory) selectedCategory = value;
                        });
                      },
                    ),
                    if (useManualCategory) ...[
                      SizedBox(height: 12),
                      TextField(
                        controller: manualCategory,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                            labelText: 'Nama kategori baru'),
                      ),
                    ],
                    SizedBox(height: 12),
                    TextField(
                      controller: amount,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      inputFormatters: const [_ThousandsInputFormatter()],
                      decoration: const InputDecoration(
                        labelText: 'Nominal',
                        prefixText: 'Rp ',
                        helperText: 'Contoh: 20.000.000',
                      ),
                    ),
                    SizedBox(height: 12),
                    TextField(
                      controller: note,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'Catatan'),
                    ),
                    SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Tanggal'),
                      subtitle: Text(_date(expenseDate)),
                      trailing: Icon(Icons.calendar_month),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: expenseDate,
                          firstDate:
                              DateTime.now().subtract(const Duration(days: 90)),
                          lastDate:
                              DateTime.now().add(const Duration(days: 365)),
                        );
                        if (picked == null) return;
                        setDialogState(() => expenseDate = picked);
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Batal')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text('Simpan')),
            ],
          );
        },
      ),
    );

    if (ok != true) return;
    final selected = useManualCategory
        ? manualCategory.text.trim()
        : selectedCategory.trim();
    final parsed =
        num.tryParse(amount.text.replaceAll('.', '').replaceAll(',', '.')) ?? 0;
    if (parsed <= 0 || selected.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kategori dan nominal wajib diisi.')));
      return;
    }

    setState(() => _processing = true);
    try {
      await _rpcWithFallback(
        const [
          'finance_insert_manual_operational_expense',
        ],
        {
          'p_category': selected,
          'p_amount': parsed,
          'p_expense_date': _toDateParam(expenseDate),
          'p_note': note.text.trim().isEmpty ? selected : note.text.trim(),
        },
      );
      await _refreshFinanceCacheForSelectedPeriod();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Biaya operasional tersimpan.')));
      await _load(ignoreLocalCache: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_cleanError(e))));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _editManualExpense(Map<String, dynamic> row) async {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return;
    }

    final expenseId = _expenseId(row);
    if (!_isUuid(expenseId)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('ID biaya tidak valid, data tidak bisa diedit.')));
      return;
    }

    await _refreshExpenseCategories();

    final currentCategory = _text(row['category'], 'Operasional');
    final options = _mergeExpenseCategories(_expenses,
        extra: [currentCategory, ..._expenseCategoryOptions]);
    final manualCategory = TextEditingController();
    final note = TextEditingController(text: _text(row['note'], ''));
    final amount =
        TextEditingController(text: _moneyInput(_num(row['amount'])));
    DateTime expenseDate = _parseDate(
            row['paid_at'] ?? row['expense_date'] ?? row['created_at']) ??
        DateTime.now();
    bool useManualCategory = !options
        .any((item) => item.toLowerCase() == currentCategory.toLowerCase());
    String selectedCategory = useManualCategory
        ? (options.isEmpty ? 'Salary' : options.first)
        : options.firstWhere(
            (item) => item.toLowerCase() == currentCategory.toLowerCase());
    if (useManualCategory) manualCategory.text = currentCategory;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          title: Text('Edit biaya operasional'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: useManualCategory ? '__manual__' : selectedCategory,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Kategori',
                    helperText: 'Contoh: Modal tambahan, Refund, Kas keluar.',
                  ),
                  items: [
                    ...options.map(
                      (item) => DropdownMenuItem<String>(
                          value: item, child: Text(item)),
                    ),
                    const DropdownMenuItem<String>(
                      value: '__manual__',
                      child: Text('Tambah kategori manual'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() {
                      useManualCategory = value == '__manual__';
                      if (!useManualCategory) selectedCategory = value;
                    });
                  },
                ),
                if (useManualCategory) ...[
                  SizedBox(height: 12),
                  TextField(
                    controller: manualCategory,
                    textInputAction: TextInputAction.next,
                    decoration:
                        const InputDecoration(labelText: 'Nama kategori'),
                  ),
                ],
                SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  inputFormatters: const [_ThousandsInputFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'Nominal',
                    prefixText: 'Rp ',
                    helperText: 'Contoh: 20.000.000',
                  ),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Catatan'),
                ),
                SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Tanggal'),
                  subtitle: Text(_date(expenseDate)),
                  trailing: Icon(Icons.calendar_month),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: expenseDate,
                      firstDate:
                          DateTime.now().subtract(const Duration(days: 90)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked == null) return;
                    setDialogState(() => expenseDate = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Simpan')),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final selected = useManualCategory
        ? manualCategory.text.trim()
        : selectedCategory.trim();
    final parsed =
        num.tryParse(amount.text.replaceAll('.', '').replaceAll(',', '.')) ?? 0;
    if (parsed <= 0 || selected.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kategori dan nominal wajib diisi.')));
      return;
    }

    setState(() => _processing = true);
    try {
      await _rpcWithFallback(
        const [
          'finance_update_manual_operational_expense',
        ],
        {
          'p_expense_id': expenseId,
          'p_category': selected,
          'p_amount': parsed,
          'p_expense_date': _toDateParam(expenseDate),
          'p_note': note.text.trim().isEmpty ? selected : note.text.trim(),
        },
      );
      await _refreshFinanceCacheForSelectedPeriod();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Biaya operasional diperbarui.')));
      await _load(ignoreLocalCache: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_cleanError(e))));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _deleteManualExpense(Map<String, dynamic> row) async {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return;
    }

    final expenseId = _expenseId(row);
    if (!_isUuid(expenseId)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('ID biaya tidak valid, data tidak bisa dihapus.')));
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus biaya operasional?'),
        content: Text(
            'Biaya "${_text(row['category'], 'Operasional')}" akan dihapus dari laporan periode ini.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Hapus'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    setState(() => _processing = true);
    try {
      await _rpcWithFallback(
        const [
          'finance_delete_manual_operational_expense',
        ],
        {'p_expense_id': expenseId},
      );
      await _refreshFinanceCacheForSelectedPeriod();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Biaya operasional dihapus.')));
      await _load(ignoreLocalCache: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_cleanError(e))));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  bool _ensureCanWriteCashWallet() {
    if (_isDemoSuperAdmin) {
      _showDemoBlocked();
      return false;
    }
    if (!_canWriteFinance) {
      AppUi.safeSnack(context, 'Akses tulis Arus Kas tidak tersedia.');
      return false;
    }
    return true;
  }

  Map<String, dynamic> _cashWalletActorPayload() {
    return {
      'created_by': _isUuid(_currentUserId) ? _currentUserId : null,
      'created_by_name': _currentUserName.trim().isEmpty
          ? _currentUserEmail
          : _currentUserName.trim(),
      'created_by_email': _currentUserEmail.trim(),
      'created_by_role': _currentRoleId.trim(),
    };
  }

  Future<void> _refreshAfterCashWalletWrite(String message) async {
    await _refreshFinanceCacheForSelectedPeriod();
    if (!mounted) return;
    AppUi.safeSnack(context, message);
    await _load(ignoreLocalCache: true);
  }

  num _moneyFromController(TextEditingController controller) {
    return num.tryParse(
          controller.text.replaceAll('.', '').replaceAll(',', '.'),
        ) ??
        0;
  }

  String _marketplaceByAccountId(String? accountId) {
    final clean = accountId?.trim() ?? '';
    if (clean.isEmpty) return _marketplaceRpcParam() ?? 'marketplace';
    for (final account in _accounts) {
      if (_accountId(account) == clean) {
        final marketplace = _text(account['marketplace'], '').trim();
        if (marketplace.isNotEmpty && marketplace != '-') return marketplace;
      }
    }
    return _marketplaceRpcParam() ?? 'marketplace';
  }

  String _bankLabel(String bank, String reference) {
    final parts = <String>[
      bank.trim(),
      if (reference.trim().isNotEmpty) reference.trim(),
    ].where((part) => part.isNotEmpty && part != '-').toList();
    return parts.isEmpty ? '-' : parts.join(' / ');
  }

  List<String> _knownBankAccounts({String? include}) {
    final values = <String>{
      for (final row in _marketplaceWithdrawals)
        _text(row['bank_account_name'], '').trim(),
      if ((include ?? '').trim().isNotEmpty) include!.trim(),
    };
    values.removeWhere((item) => item.isEmpty || item == '-');
    final list = values.toList()..sort();
    return list;
  }

  Future<void> _editCashOpeningBalance([Map<String, dynamic>? row]) async {
    if (!_ensureCanWriteCashWallet()) return;
    final fallbackMonth = _monthStart(_start);
    DateTime period = _parseDate(row?['period_month']) ?? fallbackMonth;
    Map<String, dynamic>? existing = row;
    if (existing == null) {
      for (final item in _cashOpeningBalances) {
        final itemMonth = _parseDate(item['period_month']);
        if (itemMonth != null &&
            itemMonth.year == period.year &&
            itemMonth.month == period.month) {
          existing = item;
          break;
        }
      }
    }

    final amount =
        TextEditingController(text: _moneyInput(_num(existing?['amount'])));
    final note = TextEditingController(text: _text(existing?['note'], ''));

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          title: Text('Edit saldo awal bulan'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Bulan'),
                  subtitle: Text(_monthLabel(period)),
                  trailing: Icon(Icons.calendar_month_rounded),
                  onTap: () async {
                    final picked = await _pickMonth(period);
                    if (picked == null) return;
                    setDialogState(() => period = picked);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  inputFormatters: const [_ThousandsInputFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'Saldo awal bulan',
                    prefixText: 'Rp ',
                    helperText:
                        'Edit saldo awal bulan ini, bukan tambah saldo baru.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Catatan'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Simpan')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final parsed = _moneyFromController(amount);
    if (parsed < 0) {
      AppUi.safeSnack(context, 'Saldo awal tidak valid.');
      return;
    }

    setState(() => _processing = true);
    try {
      final monthParam = _toDateParam(_monthStart(period));
      Map<String, dynamic>? target = existing;
      if (target == null) {
        final rows = await _client
            .from('finance_company_cash_opening_balances')
            .select()
            .eq('tenant_id', _currentTenantId)
            .eq('period_month', monthParam)
            .limit(1);
        final found = _asList(rows);
        if (found.isNotEmpty) target = found.first;
      }
      final id = _text(target?['cash_opening_balance_id'], '');
      final payload = {
        'tenant_id': _currentTenantId,
        'period_month': monthParam,
        'amount': parsed,
        'note': note.text.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (_isUuid(id)) {
        await _client
            .from('finance_company_cash_opening_balances')
            .update(payload)
            .eq('tenant_id', _currentTenantId)
            .eq('cash_opening_balance_id', id);
      } else {
        await _client.from('finance_company_cash_opening_balances').insert({
          ...payload,
          ..._cashWalletActorPayload(),
        });
      }
      if (!mounted) return;
      await _refreshAfterCashWalletWrite(
          'Saldo awal ${_monthLabel(period)} disimpan.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _resetCashOpeningBalance(Map<String, dynamic> row) async {
    if (!_ensureCanWriteCashWallet()) return;
    final id = _text(row['cash_opening_balance_id'], '');
    if (!_isUuid(id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reset saldo awal?'),
        content: Text(
            'Saldo awal ${_monthLabel(_parseDate(row['period_month']) ?? _start)} akan diatur menjadi Rp0.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _processing = true);
    try {
      await _client
          .from('finance_company_cash_opening_balances')
          .update({'amount': 0, 'updated_at': DateTime.now().toIso8601String()})
          .eq('tenant_id', _currentTenantId)
          .eq('cash_opening_balance_id', id);
      if (!mounted) return;
      await _refreshAfterCashWalletWrite('Saldo awal direset menjadi Rp0.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _deleteCashOpeningBalance(Map<String, dynamic> row) async {
    if (!_ensureCanWriteCashWallet()) return;
    final id = _text(row['cash_opening_balance_id'], '');
    if (!_isUuid(id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus saldo awal?'),
        content: Text(
            'Saldo awal ${_monthLabel(_parseDate(row['period_month']) ?? _start)} akan dihapus dari Arus Kas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _processing = true);
    try {
      await _client
          .from('finance_company_cash_opening_balances')
          .delete()
          .eq('tenant_id', _currentTenantId)
          .eq('cash_opening_balance_id', id);
      if (!mounted) return;
      await _refreshAfterCashWalletWrite('Saldo awal dihapus.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _editCashAdjustment({
    Map<String, dynamic>? row,
    String direction = 'in',
  }) async {
    if (!_ensureCanWriteCashWallet()) return;
    String selectedDirection =
        _text(row?['direction'], direction).toLowerCase() == 'out'
            ? 'out'
            : 'in';
    DateTime adjustmentDate =
        _parseDate(row?['adjustment_date']) ?? DateTime.now();
    final amount =
        TextEditingController(text: _moneyInput(_num(row?['amount'])));
    final category = TextEditingController(
        text: _text(row?['category'],
            selectedDirection == 'out' ? 'Kas keluar' : 'Kas masuk'));
    final note = TextEditingController(text: _text(row?['note'], ''));

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          title: Text(row == null ? 'Tambah kas manual' : 'Edit kas manual'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'in',
                        label: Text('Masuk'),
                        icon: Icon(Icons.south_west_rounded)),
                    ButtonSegment(
                        value: 'out',
                        label: Text('Keluar'),
                        icon: Icon(Icons.north_east_rounded)),
                  ],
                  selected: {selectedDirection},
                  onSelectionChanged: (value) {
                    setDialogState(() => selectedDirection = value.first);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  inputFormatters: const [_ThousandsInputFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'Nominal',
                    prefixText: 'Rp ',
                    helperText: 'Format titik ditambahkan otomatis.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: category,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Kategori',
                    helperText: 'Contoh: Modal tambahan, Refund, Kas keluar.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Catatan'),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Tanggal transaksi'),
                  subtitle: Text(_date(adjustmentDate)),
                  trailing: Icon(Icons.calendar_month_rounded),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: adjustmentDate,
                      firstDate:
                          DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked == null) return;
                    setDialogState(() => adjustmentDate = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Simpan')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final parsed = _moneyFromController(amount);
    if (parsed <= 0 || category.text.trim().isEmpty) {
      AppUi.safeSnack(context, 'Kategori dan nominal wajib diisi.');
      return;
    }

    setState(() => _processing = true);
    try {
      final id = _text(row?['cash_adjustment_id'], '');
      final payload = {
        'adjustment_date': _toDateParam(adjustmentDate),
        'direction': selectedDirection,
        'amount': parsed,
        'category': category.text.trim(),
        'note': note.text.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (_isUuid(id)) {
        await _client
            .from('finance_company_cash_adjustments')
            .update(payload)
            .eq('tenant_id', _currentTenantId)
            .eq('cash_adjustment_id', id);
      } else {
        await _client.from('finance_company_cash_adjustments').insert({
          'tenant_id': _currentTenantId,
          ...payload,
          ..._cashWalletActorPayload(),
        });
      }
      if (!mounted) return;
      await _refreshAfterCashWalletWrite('Kas manual disimpan.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _deleteCashAdjustment(Map<String, dynamic> row) async {
    if (!_ensureCanWriteCashWallet()) return;
    final id = _text(row['cash_adjustment_id'], '');
    if (!_isUuid(id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus kas manual?'),
        content: Text(
            '${_text(row['category'], 'Kas manual')} akan dihapus dari Arus Kas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _processing = true);
    try {
      await _client
          .from('finance_company_cash_adjustments')
          .delete()
          .eq('tenant_id', _currentTenantId)
          .eq('cash_adjustment_id', id);
      if (!mounted) return;
      await _refreshAfterCashWalletWrite('Kas manual dihapus.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _editMarketplaceWithdrawal([Map<String, dynamic>? row]) async {
    if (!_ensureCanWriteCashWallet()) return;
    DateTime withdrawalDate =
        _parseDate(row?['withdrawal_date']) ?? DateTime.now();
    final amount =
        TextEditingController(text: _moneyInput(_num(row?['amount'])));
    final reference =
        TextEditingController(text: _text(row?['bank_reference'], ''));
    final note = TextEditingController(text: _text(row?['note'], ''));

    final accountOptions = _accounts.where((account) {
      final id = _accountId(account);
      if (!_isUuid(id)) return false;
      final marketplace = _marketplaceRpcParam();
      return marketplace == null ||
          _text(account['marketplace']).toLowerCase() ==
              marketplace.toLowerCase();
    }).toList();
    String? selectedAccountId =
        _isUuid(_text(row?['marketplace_account_id'], ''))
            ? _text(row?['marketplace_account_id'], '')
            : _accountUuidParam();
    if (selectedAccountId == null && accountOptions.isNotEmpty) {
      selectedAccountId = _accountId(accountOptions.first);
    }

    final bankOptions =
        _knownBankAccounts(include: _text(row?['bank_account_name'], ''));
    String selectedBank =
        bankOptions.contains(_text(row?['bank_account_name'], ''))
            ? _text(row?['bank_account_name'], '')
            : (bankOptions.isEmpty ? '__manual__' : bankOptions.first);
    final manualBank = TextEditingController(
        text: selectedBank == '__manual__' ? '' : selectedBank);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          title: Text(row == null
              ? 'Tambah penarikan marketplace'
              : 'Edit penarikan marketplace'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: selectedAccountId,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(labelText: 'Toko marketplace'),
                  items: accountOptions.map((account) {
                    final id = _accountId(account);
                    final name = _text(
                      account['store_label'] ??
                          account['shop_name'] ??
                          account['store_alias'] ??
                          account['seller_name'],
                      id,
                    );
                    return DropdownMenuItem<String>(
                      value: id,
                      child: Text(
                        '${_marketplaceName(_text(account['marketplace']))} - $name',
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (value) =>
                      setDialogState(() => selectedAccountId = value),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  inputFormatters: const [_ThousandsInputFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'Nominal penarikan',
                    prefixText: 'Rp ',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedBank,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Rekening bank'),
                  items: [
                    ...bankOptions.map((item) => DropdownMenuItem<String>(
                        value: item, child: Text(item))),
                    const DropdownMenuItem<String>(
                      value: '__manual__',
                      child: Text('Tambah rekening baru'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() {
                      selectedBank = value;
                      if (value != '__manual__') manualBank.text = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: manualBank,
                  enabled: selectedBank == '__manual__',
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Nama/nomor rekening',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reference,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Reference / mutasi bank',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Catatan'),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Tanggal penarikan'),
                  subtitle: Text(_date(withdrawalDate)),
                  trailing: Icon(Icons.calendar_month_rounded),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: withdrawalDate,
                      firstDate:
                          DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked == null) return;
                    setDialogState(() => withdrawalDate = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Simpan')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final parsed = _moneyFromController(amount);
    final bank = manualBank.text.trim();
    if (parsed <= 0 || bank.isEmpty) {
      AppUi.safeSnack(context, 'Nominal dan rekening bank wajib diisi.');
      return;
    }

    setState(() => _processing = true);
    try {
      final id = _text(row?['marketplace_withdrawal_id'], '');
      final payload = {
        'tenant_id': _currentTenantId,
        'marketplace_account_id':
            _isUuid(selectedAccountId ?? '') ? selectedAccountId : null,
        'marketplace': _marketplaceByAccountId(selectedAccountId),
        'withdrawal_date': _toDateParam(withdrawalDate),
        'amount': parsed,
        'bank_account_name': bank,
        'bank_reference': reference.text.trim(),
        'note': note.text.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (_isUuid(id)) {
        await _client
            .from('finance_marketplace_withdrawals')
            .update(payload)
            .eq('tenant_id', _currentTenantId)
            .eq('marketplace_withdrawal_id', id);
      } else {
        await _client.from('finance_marketplace_withdrawals').insert({
          ...payload,
          ..._cashWalletActorPayload(),
        });
      }
      if (!mounted) return;
      await _refreshAfterCashWalletWrite('Penarikan marketplace disimpan.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _deleteMarketplaceWithdrawal(Map<String, dynamic> row) async {
    if (!_ensureCanWriteCashWallet()) return;
    final id = _text(row['marketplace_withdrawal_id'], '');
    if (!_isUuid(id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus penarikan marketplace?'),
        content:
            Text('Penarikan dan alokasi terkait akan dihapus dari Arus Kas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _processing = true);
    try {
      await _client
          .from('finance_marketplace_withdrawals')
          .delete()
          .eq('tenant_id', _currentTenantId)
          .eq('marketplace_withdrawal_id', id);
      if (!mounted) return;
      await _refreshAfterCashWalletWrite('Penarikan marketplace dihapus.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Map<String, dynamic>? _withdrawalById(String id) {
    if (!_isUuid(id)) return null;
    for (final row in _marketplaceWithdrawals) {
      if (_text(row['marketplace_withdrawal_id'], '') == id) return row;
    }
    return null;
  }

  Future<void> _editWithdrawalAllocation({
    Map<String, dynamic>? row,
    Map<String, dynamic>? withdrawal,
  }) async {
    if (!_ensureCanWriteCashWallet()) return;
    final withdrawalId = _text(
      row?['marketplace_withdrawal_id'] ??
          withdrawal?['marketplace_withdrawal_id'],
      '',
    );
    final parent = withdrawal ?? _withdrawalById(withdrawalId);
    if (!_isUuid(withdrawalId) || parent == null) {
      AppUi.safeSnack(context, 'Data penarikan tidak valid untuk alokasi.');
      return;
    }

    DateTime sourceMonth = _monthStart(
      _parseDate(row?['source_period_month'] ?? parent['withdrawal_date']) ??
          _start,
    );
    final amount = TextEditingController(
        text: _moneyInput(_num(row?['amount'] ?? parent['amount'])));
    final note = TextEditingController(text: _text(row?['note'], ''));
    String method = _text(row?['allocation_method'], 'manual').toLowerCase();
    if (!const ['manual', 'fifo', 'system'].contains(method)) method = 'manual';

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          title: Text(row == null
              ? 'Tambah alokasi penarikan'
              : 'Edit alokasi penarikan'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Bulan sumber'),
                  subtitle: Text(_monthLabel(sourceMonth)),
                  trailing: Icon(Icons.calendar_month_rounded),
                  onTap: () async {
                    final picked = await _pickMonth(sourceMonth);
                    if (picked == null) return;
                    setDialogState(() => sourceMonth = picked);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  inputFormatters: const [_ThousandsInputFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'Nominal alokasi',
                    prefixText: 'Rp ',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: method,
                  decoration:
                      const InputDecoration(labelText: 'Metode alokasi'),
                  items: const [
                    DropdownMenuItem(value: 'manual', child: Text('Manual')),
                    DropdownMenuItem(value: 'fifo', child: Text('FIFO')),
                    DropdownMenuItem(value: 'system', child: Text('System')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => method = value);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Catatan'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Simpan')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final parsed = _moneyFromController(amount);
    if (parsed <= 0) {
      AppUi.safeSnack(context, 'Nominal alokasi wajib diisi.');
      return;
    }

    setState(() => _processing = true);
    try {
      final id = _text(row?['marketplace_withdrawal_allocation_id'], '');
      final payload = {
        'marketplace_withdrawal_id': withdrawalId,
        'tenant_id': _currentTenantId,
        'marketplace_account_id':
            _isUuid(_text(parent['marketplace_account_id'], ''))
                ? _text(parent['marketplace_account_id'], '')
                : null,
        'marketplace':
            _text(parent['marketplace'], _marketplaceByAccountId(null)),
        'source_period_month': _toDateParam(sourceMonth),
        'amount': parsed,
        'allocation_method': method,
        'note': note.text.trim(),
      };
      if (_isUuid(id)) {
        await _client
            .from('finance_marketplace_withdrawal_allocations')
            .update(payload)
            .eq('tenant_id', _currentTenantId)
            .eq('marketplace_withdrawal_allocation_id', id);
      } else {
        await _client
            .from('finance_marketplace_withdrawal_allocations')
            .insert(payload);
      }
      if (!mounted) return;
      await _refreshAfterCashWalletWrite('Alokasi penarikan disimpan.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _deleteWithdrawalAllocation(Map<String, dynamic> row) async {
    if (!_ensureCanWriteCashWallet()) return;
    final id = _text(row['marketplace_withdrawal_allocation_id'], '');
    if (!_isUuid(id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus alokasi penarikan?'),
        content: Text(
            'Alokasi bulan ${_monthLabel(_parseDate(row['source_period_month']) ?? _start)} akan dihapus.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _processing = true);
    try {
      await _client
          .from('finance_marketplace_withdrawal_allocations')
          .delete()
          .eq('tenant_id', _currentTenantId)
          .eq('marketplace_withdrawal_allocation_id', id);
      if (!mounted) return;
      await _refreshAfterCashWalletWrite('Alokasi penarikan dihapus.');
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, _cleanError(e));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Widget _marketplaceBootstrapFinanceBanner() {
    final status = _marketplaceBootstrapUiStatus;
    if (status.isEmpty || status['show_banner'] != true) {
      return const SizedBox.shrink();
    }

    final severity = _text(status['severity'], 'info').toLowerCase();
    final summary = _asMap(status['summary']);
    final title = _text(status['title'], 'Data marketplace sedang diambil');
    final message = _text(
      status['message'],
      'Order, resi, refund/return, dan payout marketplace sedang disinkronkan.',
    );
    final accent = _bootstrapFinanceSeverityColor(severity);
    final eta = _dateTime(summary['estimated_finish_wib']);
    final done = _text(summary['done_jobs'], '0');
    final total = _text(summary['total_jobs'], '0');
    final retry = _text(summary['retry_jobs'], '0');
    final running = _text(summary['running_jobs'], '0');
    final failed = _text(summary['failed_jobs'], '0');
    final orders = _text(summary['orders_pulled'], '0');
    final items = _text(summary['items_pulled'], '0');
    final totalJobs = _num(summary['total_jobs']);
    final doneJobs = _num(summary['done_jobs']);
    final progress = totalJobs <= 0
        ? 0.0
        : (doneJobs / totalJobs).clamp(0.0, 1.0).toDouble();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withOpacity(0.08),
          Theme.of(context).cardColor,
        ),
        border: Border.all(color: accent.withOpacity(0.24), width: 0.8),
        borderRadius: BorderRadius.circular(10),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_bootstrapFinanceSeverityIcon(severity),
                  color: accent, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodyLarge?.color,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        letterSpacing: .8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$message Finance masih berstatus data sementara sampai proses selesai.',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodyMedium?.color,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress.isNaN ? null : progress,
            minHeight: 7,
            backgroundColor: Theme.of(context).dividerColor.withOpacity(.18),
            color: accent,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _bootstrapFinanceChip('Tahap', '$done/$total'),
              _bootstrapFinanceChip('Retry', retry),
              _bootstrapFinanceChip('Running', running),
              _bootstrapFinanceChip('Failed', failed),
              _bootstrapFinanceChip('Order', orders),
              _bootstrapFinanceChip('Item', items),
              if (eta != '-') _bootstrapFinanceChip('ETA', eta),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bootstrapFinanceChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.05),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.18),
          width: 0.8,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Color _bootstrapFinanceSeverityColor(String severity) {
    switch (severity) {
      case 'error':
        return AppUi.red;
      case 'warning':
        return AppUi.orange;
      case 'success':
        return AppUi.green;
      case 'info':
        return Theme.of(context).colorScheme.primary;
      default:
        return Theme.of(context).colorScheme.secondary;
    }
  }

  IconData _bootstrapFinanceSeverityIcon(String severity) {
    switch (severity) {
      case 'error':
        return Icons.error_outline_rounded;
      case 'warning':
        return Icons.warning_amber_rounded;
      case 'success':
        return Icons.verified_rounded;
      case 'info':
        return Icons.sync_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      const Tab(text: 'Ringkasan'),
      const Tab(text: 'Marketplace'),
      const Tab(text: 'SKU'),
      const Tab(text: 'Arus Kas'),
      const Tab(text: 'Biaya'),
      const Tab(text: 'Laba Rugi'),
      const Tab(text: 'Abnormal'),
    ];

    final safeInitialTab =
        widget.initialTabIndex.clamp(0, tabs.length - 1).toInt();

    return DefaultTabController(
      length: tabs.length,
      initialIndex: safeInitialTab,
      child: WebResponsiveScaffold(
        title: 'Laporan Keuangan',
        activeWebTitle: 'Laporan Keuangan & Margin',
        onBack: () => Navigator.of(context).maybePop(),
        actions: [
          if (_loading)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            )
          else if (_canAccessFinance) ...[
            IconButton(
              tooltip: 'Hapus data finance marketplace',
              onPressed: _processing ? null : _clearMarketplaceFinanceData,
              icon: const Icon(Icons.delete_sweep_rounded, size: 22),
            ),
            IconButton(
              tooltip: 'Export semua marketplace',
              onPressed:
                  _processing ? null : _exportAllMarketplaceFinanceReport,
              icon: const Icon(Icons.file_download_rounded, size: 22),
            ),
            IconButton(
              tooltip: 'Muat ulang tampilan',
              onPressed: _processing ? null : _hardReloadFinanceView,
              icon: const Icon(Icons.refresh_rounded, size: 22),
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorColor: Theme.of(context).colorScheme.primary,
            indicatorWeight: 2.5,
            labelColor: Theme.of(context).colorScheme.primary,
            unselectedLabelColor: AppUi.mutedText(context, 0.88),
            labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0),
            unselectedLabelStyle:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            tabs: tabs,
          ),
        ),
        floatingActionButton: Builder(
          builder: (fabContext) {
            final tabController = DefaultTabController.maybeOf(fabContext);
            if (tabController == null) return const SizedBox.shrink();

            return AnimatedBuilder(
              animation: tabController,
              builder: (context, _) {
                final isExpenseTab = tabController.index == 4;
                if (!_canAccessFinance ||
                    _isDemoSuperAdmin ||
                    !isExpenseTab) {
                  return const SizedBox.shrink();
                }

                if (_processing) {
                  return FloatingActionButton.small(
                    onPressed: null,
                    backgroundColor: Theme.of(context).cardColor,
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  );
                }

                return FloatingActionButton.extended(
                  onPressed: _addManualExpense,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('Biaya',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                );
              },
            );
          },
        ),
        body: SafeArea(
          child: Column(
            children: [
              _marketplaceBootstrapFinanceBanner(),
              _filterBar(),
              Expanded(
                child: _error != null
                    ? _errorState()
                    : TabBarView(
                        children: [
                          _summaryTab(),
                          _marketplaceTab(),
                          _skuTab(),
                          _cashFlowTab(),
                          _expensesTab(),
                          _profitLossTab(),
                          _abnormalTab(),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  //  Filter bar
  Widget _filterBar() {
    final marketplaceOptions = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: 'all', child: Text('Semua platform')),
      const DropdownMenuItem(value: 'tiktok_shop', child: Text('TikTok Shop')),
      const DropdownMenuItem(value: 'shopee', child: Text('Shopee')),
    ];

    final accountOptions = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: 'all', child: Text('Semua toko')),
      ..._accounts.map((account) {
        final id = _accountId(account);
        if (!_isUuid(id)) return null;
        final name = _text(
          account['store_label'] ??
              account['shop_name'] ??
              account['store_alias'] ??
              account['seller_name'],
          id,
        );
        final marketplace = _marketplaceName(_text(account['marketplace']));
        return DropdownMenuItem<String>(
          value: id,
          child: Text('$marketplace · $name', overflow: TextOverflow.ellipsis),
        );
      }).whereType<DropdownMenuItem<String>>(),
    ];

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withOpacity(isDark ? 0.25 : 0.45),
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _dateChip(
                        icon: Icons.calendar_today_rounded,
                        label: 'Periode',
                        value: '${_date(_start)} - ${_date(_end)}',
                        onTap: _pickDateRange,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 38,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () =>
                      setState(() => _filterExpanded = !_filterExpanded),
                  icon: Icon(
                      _filterExpanded ? Icons.expand_less : Icons.tune_rounded,
                      size: 18),
                  label: Text('Filter',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          if (_filterExpanded) ...[
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _periodShortcut('Hari ini', () => _applyDatePreset('today')),
                  const SizedBox(width: 6),
                  _periodShortcut('7d', () => _applyDatePreset('7d')),
                  const SizedBox(width: 6),
                  _periodShortcut('Bulan ini', () => _applyDatePreset('month')),
                  const SizedBox(width: 6),
                  _periodShortcut('30d', () => _applyDatePreset('30d')),
                  const SizedBox(width: 6),
                  _periodShortcut('90d', () => _applyDatePreset('90d')),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _compactDropdown<String>(
                    label: 'Platform',
                    value: marketplaceOptions
                            .any((item) => item.value == _marketplaceFilter)
                        ? _marketplaceFilter
                        : 'all',
                    items: marketplaceOptions,
                    onChanged: (value) async {
                      if (value == null) return;
                      setState(() {
                        _marketplaceFilter =
                            _normalizeMarketplaceFilter(value) ?? 'all';
                        _accountFilter = 'all';
                        _rememberFilters();
                      });
                      await _load();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _compactDropdown<String>(
                    label: 'Toko',
                    value: accountOptions
                            .any((item) => item.value == _accountFilter)
                        ? _accountFilter
                        : 'all',
                    items: accountOptions,
                    onChanged: (value) async {
                      if (value == null) return;
                      setState(() {
                        _accountFilter =
                            value == 'all' || _isUuid(value) ? value : 'all';
                        _rememberFilters();
                      });
                      await _load();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _financeSyncInfo(),
            const SizedBox(height: 8),
            _financeManualActions(),
            _progressCard(),
            const SizedBox(height: 8),
            _financeAutoSyncSwitch(),
          ],
        ],
      ),
    );
  }

  Widget _financeSyncInfo() {
    final period = '${_date(_start)} s/d ${_date(_end)}';
    final orderPullAt = _latestDispatcherTimestamp(
      'order_states',
      const ['last_success_at', 'last_order_updated_at'],
    );
    final financePullAt = _latestDispatcherTimestamp(
      'finance_states',
      const ['last_success_at'],
    );
    final payoutUpdateAt = _latestDispatcherTimestamp(
      'finance_states',
      const ['last_finance_updated_at'],
    );
    final latestSync =
        _maxDate(_maxDate(orderPullAt, financePullAt), payoutUpdateAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.18),
              width: 0.8,
            ),
          ),
          child: Text(
            'Periode data: $period',
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
                  Theme.of(context).brightness == Brightness.dark
                      ? 0.25
                      : 0.45),
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Terakhir sinkron: ${_syncTimestampText(latestSync)}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Order pull: ${_syncTimestampText(orderPullAt)}',
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.72),
                    fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                'Finance pull: ${_syncTimestampText(financePullAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.72),
                    fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                'Payout update: ${_syncTimestampText(payoutUpdateAt)}',
                style: TextStyle(
                    color: AppUi.mutedText(context, 0.88), fontSize: 10.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progressCard() {
    return const SizedBox.shrink();
  }

  Widget _financeManualActions() {
    return const SizedBox.shrink();
  }

  Widget _financeAutoSyncSwitch() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.payments_rounded,
              color: Theme.of(context).colorScheme.primary, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Auto finance aktif',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface)),
                SizedBox(height: 2),
                Text(
                    'Payout, missing payout, dan status order lama diproses otomatis di background.',
                    style: TextStyle(
                        fontSize: 11, color: AppUi.mutedText(context, 0.88))),
              ],
            ),
          ),
          if (_financeAutoSyncBusy)
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary))
          else
            Switch.adaptive(
              value: _financeAutoSyncEnabled,
              activeColor: Theme.of(context).colorScheme.primary,
              onChanged: _setFinanceAutoSyncEnabled,
            ),
        ],
      ),
    );
  }

  Widget _periodShortcut(String label, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.07),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.22),
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget _dateChip({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .outlineVariant
                  .withOpacity(isDark ? 0.28 : 0.5),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 86, maxWidth: 220),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: AppUi.mutedText(context, 0.88),
                            fontWeight: FontWeight.w500)),
                    Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compactDropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface),
          dropdownColor: Theme.of(context).cardColor,
          items: items,
          onChanged: onChanged,
          hint: Text(label,
              style: TextStyle(
                  fontSize: 11.5, color: AppUi.mutedText(context, 0.88))),
        ),
      ),
    );
  }

  Map<String, double> _totalsFromSkuRows({bool paidOnly = false}) {
    var gross = 0.0;
    var payout = 0.0;
    var hpp = 0.0;
    var orderCount = 0.0;
    final orders = <String>{};
    for (final row in _bySku) {
      final details = _safeOrderRefRows(row);
      if (details.isEmpty) {
        gross += _num(row['paid_gross_total'] ??
            row['gross_total'] ??
            row['gross_sales']);
        payout += _num(row['payout_total'] ?? row['payout']);
        hpp += _num(row['paid_hpp_total'] ?? row['hpp_total'] ?? row['hpp']);
        orderCount +=
            _num(row['paid_order_count'] ?? row['detail_order_count']);
        continue;
      }
      for (final detail in details) {
        final safeQty = _num(detail['qty']) > 0 ? _num(detail['qty']) : 1.0;
        final linePayout = _linePayoutAmount(detail, defaultQty: safeQty);
        final isReleased = _hasReleasedPayout(detail);
        if (paidOnly && !isReleased) continue;
        final order = _text(detail['order'], '').trim();
        if (order.isNotEmpty && order != '-') orders.add(order);
        final lineGross = _num(detail['gross']) > 0
            ? _num(detail['gross'])
            : (_num(detail['gross_per_item']) * safeQty);
        gross += lineGross;
        payout += linePayout;
        final lineGrossPerItem =
            safeQty > 0 ? lineGross / safeQty : _num(detail['gross_per_item']);
        final detailHppPerItem = _normalizeHppPerItemValue(
          hppPerItemRaw: _num(detail['hpp_per_item'] ??
              detail['hpp_unit'] ??
              detail['unit_hpp']),
          hppTotalRaw: _num(detail['hpp']),
          qty: safeQty,
          grossPerItem: lineGrossPerItem,
        );
        hpp += detailHppPerItem > 0
            ? detailHppPerItem * safeQty
            : (_num(row['hpp_per_item']) * safeQty);
      }
    }
    return {
      'gross': gross,
      'payout': payout,
      'hpp': hpp,
      'orders': orders.isNotEmpty ? orders.length.toDouble() : orderCount,
    };
  }

  //  Tabs
  Widget _summaryTab() {
    final paidSkuTotals = _totalsFromSkuRows(paidOnly: true);
    final summaryGross = _num(_summary['gross_sales'] ??
        _summary['gross_total'] ??
        _summary['gross'] ??
        _summary['omzet_total'] ??
        _summary['omzet']);
    final summaryPayout = _num(_summary['payout_total'] ??
        _summary['payout_amount'] ??
        _summary['payout'] ??
        _summary['received_amount'] ??
        _summary['net_received']);
    final summaryHpp =
        _num(_summary['hpp_total'] ?? _summary['hpp'] ?? _summary['total_hpp']);
    final operational = _num(_summary['operational_cost_total'] ??
        _summary['operational_expense'] ??
        _summary['expense_total']);

    // v24.6.74: kartu Ringkasan pakai summary final dari RPC/cache.
    // Detail SKU tetap ditampilkan di tab SKU, tapi tidak boleh mengubah total utama.
    final gross = summaryGross > 0 ? summaryGross : paidSkuTotals['gross']!;
    final payout = summaryPayout > 0 ? summaryPayout : paidSkuTotals['payout']!;
    final hpp = summaryHpp > 0 ? summaryHpp : paidSkuTotals['hpp']!;
    final profit = payout - hpp - operational;
    final margin = payout > 0 ? (profit / payout) * 100 : 0.0;
    final orderCount = _num(_summary['order_count'] ??
        _summary['orders_count'] ??
        _summary['all_orders_count']);
    final summaryFinanceOrderCount = _numFirstNonZero([
      _summary['finance_order_count'],
      _summary['finance_orders_count'],
      _summary['order_count_finance'],
      _summary['paid_order_count'],
      _summary['orders_count'],
    ]);
    final financeOrderCount = summaryFinanceOrderCount > 0
        ? summaryFinanceOrderCount
        : paidSkuTotals['orders']!;
    final orderSubtitle = financeOrderCount > 0
        ? '${financeOrderCount.toStringAsFixed(0)} pesanan finance'
        : '${orderCount.toStringAsFixed(0)} pesanan';
    final abnormalCount = (_abnormalServerLoaded && _abnormalTotal > 0)
        ? _abnormalTotal.toDouble()
        : _num(_summary['abnormal_count']);
    final sourceCount =
        _num(_summary['source_count'] ?? _summary['marketplace_count']);
    final displaySourceCount = sourceCount > 0
        ? sourceCount.toInt()
        : (_sources.isNotEmpty ? _sources.length : _byMarketplace.length);
    final negativePayout = _negativePayoutTotal();
    final unpaidEstimatedHpp = _unpaidEstimatedHppTotal();
    final abnormalSummarySource = _abnormalFilterSource();
    final localSampleCount =
        abnormalSummarySource.where(_isSampleFreeAbnormalRow).length;
    final localNoPayoutCount =
        abnormalSummarySource.where(_isNoPayoutAbnormalRow).length;
    final localPayoutMinusCount =
        abnormalSummarySource.where(_hasPayoutMinusSettlementReason).length;

    final sampleOrderCount = _numFirstNonZero([
      _summary['sample_order_count'],
      _summary['sample_free_count'],
      _summary['confirmed_sample_count'],
      localSampleCount,
    ]);

    final sampleHppTotal = _num(_summary['sample_hpp_total']);
    final samplePayoutMinusSigned = _num(_summary['sample_payout_minus_total']);
    final sampleNegativePayout = _numFirstNonZero([
      _summary['sample_payout_minus_total_abs'],
      _summary['sample_negative_payout_total'],
      samplePayoutMinusSigned.abs(),
    ]);
    final sampleLossEstimate = _numFirstNonZero([
      _summary['sample_loss_estimate'],
      sampleHppTotal + sampleNegativePayout,
    ]);
    final sampleTextCount = _numFirstNonZero([
      _summary['sample_text_marker_count'],
      _summary['confirmed_sample_text_count'],
    ]);
    final sampleLabelCount = _numFirstNonZero([
      _summary['sample_label_count'],
      _summary['confirmed_sample_label_count'],
    ]);
    final sampleDiscountCount = _numFirstNonZero([
      _summary['sample_discount_100_count'],
      _summary['confirmed_sample_discount_100_count'],
    ]);
    final sampleFinanceFlagCount = _numFirstNonZero([
      _summary['sample_finance_flag_count'],
      _summary['confirmed_sample_finance_flag_count'],
    ]);
    final sampleRawTikTokCount =
        _num(_summary['sample_raw_tiktok_order_count']);
    final sampleRawTikTokItems =
        _num(_summary['sample_raw_tiktok_item_row_count']);
    final sampleRawTikTokApiFlag =
        _num(_summary['sample_raw_tiktok_api_flag_count']);
    final sampleRawTikTokImport =
        _num(_summary['sample_raw_tiktok_import_count']);
    final sampleStatusBreakdown =
        _summaryBreakdownText(_summary['sample_status_breakdown']);
    final sampleSubstatusBreakdown =
        _summaryBreakdownText(_summary['sample_substatus_breakdown']);
    final classificationCancelledCount = _num(_summary['cancelled_count']);
    final classificationPendingCount = _num(_summary['pending_count']);
    final classificationNoPayoutCount =
        _num(_summary['no_payout_eligible_count']);
    final samplePayoutMinusSettlement =
        _num(_summary['sample_payout_minus_settlement_total']).abs();
    final samplePayoutMinusShipping = _num(
            _summary['sample_payout_minus_shipping_total'] ??
                _summary['sample_payout_minus_ongkir_total'])
        .abs();
    final samplePayoutMinusVoucher =
        _num(_summary['sample_payout_minus_voucher_total']).abs();
    final samplePayoutMinusPlatform =
        _num(_summary['sample_payout_minus_platform_total']).abs();
    final noPayoutCount = _numFirstNonZero([
      _summary['no_payout_eligible_count'],
      _summary['no_payout_count'],
      _summary['missing_payout_non_sample_count'],
      localNoPayoutCount,
    ]);
    final payoutMinusCount = _numFirstNonZero([
      _summary['payout_minus_count'],
      _summary['negative_payout_count'],
      _summary['minus_payout_count'],
      localPayoutMinusCount,
    ]);

    if (_loading) {
      return const Center(child: FuturisticLoader(message: 'MEMUAT DATA...'));
    }

    final isEmpty = gross == 0 && payout == 0 && profit == 0 && orderCount == 0;

    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 130),
        children: [
          if (_marketplaceFinanceGapMessage.trim().isNotEmpty) ...[
            _emptyCard(_marketplaceFinanceGapMessage),
            const SizedBox(height: 12),
          ],
          if (isEmpty) ...[
            _heroCard(
              title: 'DATA KOSONG',
              value: 'Rp 0',
              subtitle: 'Filter periode ini belum memiliki data finance.',
              icon: Icons.sync_problem_rounded,
              positive: false,
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: FilledButton.icon(
                onPressed: _hardReloadFinanceView,
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
                icon: Icon(Icons.refresh_rounded),
                label: Text('TARIK ULANG DATA'),
              ),
            ),
          ] else ...[
            _heroCard(
              title: payout > 0 ? 'LABA BERSIH' : 'ESTIMASI LABA',
              value: _money(profit),
              subtitle:
                  'Margin ${margin.toStringAsFixed(2)}%  ·  $orderSubtitle',
              icon: Icons.account_balance_wallet_rounded,
              positive: profit >= 0,
            ),
            const SizedBox(height: 12),
            if (!_sampleFreeLoaded) ...[
              if (_sampleFreeLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                      child: FuturisticLoader(
                          message: 'Memuat Ringkasan Sample/Gratis...')),
                )
              else ...[
                if (_sampleFreeError != null) ...[
                  _emptyCard('Gagal memuat sample/gratis: $_sampleFreeError'),
                  const SizedBox(height: 8),
                ],
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withOpacity(
                              Theme.of(context).brightness == Brightness.dark
                                  ? 0.25
                                  : 0.45),
                      width: 0.8,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Audit Sample & Gratis',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Theme.of(context).textTheme.bodyLarge?.color,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Audit data order sample, giveaway, tester, gratis dengan payout Rp 0 atau minus.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.82),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _loadSampleFreeOrdersSupplemental,
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.primary,
                            foregroundColor:
                                Theme.of(context).colorScheme.onPrimary,
                          ),
                          icon: Icon(Icons.card_giftcard_rounded),
                          label: Text('MUAT AUDIT SAMPLE/GRATIS'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ] else ...[
              if (sampleOrderCount > 0 ||
                  sampleHppTotal > 0 ||
                  sampleNegativePayout > 0) ...[
                _detailCard(
                  title: 'Sample / Gratis sesuai filter',
                  subtitle:
                      '${sampleOrderCount.toStringAsFixed(0)} order · HPP ${_money(sampleHppTotal)} · Payout minus ${_money(sampleNegativePayout)}',
                  children: [
                    if (_normalizeMarketplaceFilter(_marketplaceFilter) ==
                        'shopee')
                      _emptyOkCard(
                          'Shopee tidak ada Sample/Gratis terkonfirmasi')
                    else if (_normalizeMarketplaceFilter(_marketplaceFilter) ==
                        'all')
                      _emptyOkCard(
                          'Shopee tidak ada Sample/Gratis terkonfirmasi'),
                    if (sampleOrderCount > 0)
                      _miniMetric('Order', sampleOrderCount.toStringAsFixed(0)),
                    if (sampleTextCount > 0)
                      _miniMetric('Teks sample/free',
                          sampleTextCount.toStringAsFixed(0)),
                    if (sampleLabelCount > 0)
                      _miniMetric(
                          'Label produk', sampleLabelCount.toStringAsFixed(0)),
                    if (sampleDiscountCount > 0)
                      _miniMetric('Diskon 100%',
                          sampleDiscountCount.toStringAsFixed(0)),
                    if (sampleFinanceFlagCount > 0)
                      _miniMetric('Flag finance',
                          sampleFinanceFlagCount.toStringAsFixed(0)),
                    if (sampleRawTikTokCount > 0)
                      _miniMetric('Raw TikTok',
                          sampleRawTikTokCount.toStringAsFixed(0)),
                    if (sampleRawTikTokItems > 0)
                      _miniMetric('Item raw TikTok',
                          sampleRawTikTokItems.toStringAsFixed(0)),
                    if (sampleRawTikTokApiFlag > 0)
                      _miniMetric('Flag sample TikTok',
                          sampleRawTikTokApiFlag.toStringAsFixed(0)),
                    if (sampleRawTikTokImport > 0)
                      _miniMetric('Export TikTok',
                          sampleRawTikTokImport.toStringAsFixed(0)),
                    if (classificationCancelledCount > 0)
                      _miniMetric('Batal dipisah',
                          classificationCancelledCount.toStringAsFixed(0)),
                    if (classificationPendingCount > 0)
                      _miniMetric('Pending dipisah',
                          classificationPendingCount.toStringAsFixed(0)),
                    if (classificationNoPayoutCount > 0)
                      _miniMetric('No Payout eligible',
                          classificationNoPayoutCount.toStringAsFixed(0)),
                    if (_num(_summary['sample_gross_total']) > 0)
                      _miniMetric('Gross (Omzet)',
                          _money(_num(_summary['sample_gross_total']))),
                    if (_num(_summary['sample_payout_total']) > 0)
                      _miniMetric('Payout',
                          _money(_num(_summary['sample_payout_total']))),
                    if (sampleNegativePayout > 0)
                      _miniMetric('Payout Minus', _money(sampleNegativePayout),
                          warning: true),
                    if (samplePayoutMinusSettlement > 0)
                      _miniMetric('Payout minus dari settlement',
                          _money(samplePayoutMinusSettlement),
                          warning: true),
                    if (samplePayoutMinusShipping > 0)
                      _miniMetric('Payout minus ongkir',
                          _money(samplePayoutMinusShipping),
                          warning: true),
                    if (samplePayoutMinusVoucher > 0)
                      _miniMetric('Payout minus voucher',
                          _money(samplePayoutMinusVoucher),
                          warning: true),
                    if (samplePayoutMinusPlatform > 0)
                      _miniMetric('Payout minus fee platform',
                          _money(samplePayoutMinusPlatform),
                          warning: true),
                    if (_num(_summary['sample_discount_total']) > 0)
                      _miniMetric('Voucher/Diskon',
                          _money(_num(_summary['sample_discount_total']))),
                    if (_num(_summary['sample_shipping_total']) > 0)
                      _miniMetric('Ongkir (Kurir)',
                          _money(_num(_summary['sample_shipping_total']))),
                    if (_num(_summary['sample_fee_total']) > 0)
                      _miniMetric('Biaya Platform',
                          _money(_num(_summary['sample_fee_total']))),
                    if (_num(_summary['sample_refund_total']) > 0)
                      _miniMetric('Refund',
                          _money(_num(_summary['sample_refund_total']))),
                    if (_num(_summary['sample_adjustment_total']) > 0)
                      _miniMetric('Penyesuaian',
                          _money(_num(_summary['sample_adjustment_total']))),
                    if (sampleHppTotal > 0)
                      _miniMetric('HPP Sample', _money(sampleHppTotal))
                    else if (sampleOrderCount > 0)
                      _miniMetric('HPP Sample', 'Belum mapping', warning: true),
                    if (sampleLossEstimate > 0)
                      _miniMetric('Estimasi Dampak', _money(sampleLossEstimate),
                          warning: true)
                    else if (sampleOrderCount > 0 && sampleHppTotal <= 0)
                      _miniMetric('Estimasi Dampak', 'Menunggu HPP mapping',
                          warning: true),
                    if (sampleStatusBreakdown.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _emptyCard(
                          'Status Sample/Gratis: $sampleStatusBreakdown'),
                    ],
                    if (sampleSubstatusBreakdown.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _emptyCard(
                          'Substatus Sample/Gratis: $sampleSubstatusBreakdown'),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      'Rumus: Estimasi Dampak = HPP Sample + Payout Minus confirmed only',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        fontStyle: FontStyle.italic,
                        color: AppUi.mutedText(context, 0.90),
                      ),
                    ),
                    if (sampleNegativePayout > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '* Payout minus dilabeli sesuai sumber yang terbukti: settlement, ongkir, voucher, atau fee platform.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final tabController =
                              DefaultTabController.maybeOf(context);
                          if (tabController != null) {
                            tabController.animateTo(6);
                          }
                          _refreshAbnormalTab();
                        },
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 0.8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: Icon(Icons.arrow_forward_rounded, size: 16),
                        label: Text('LIHAT DAFTAR ORDER SAMPLE'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ] else ...[
                _detailCard(
                  title: 'Sample / Gratis sesuai filter',
                  subtitle: '0 order terkonfirmasi',
                  children: [
                    if (_normalizeMarketplaceFilter(_marketplaceFilter) ==
                        'shopee')
                      _emptyOkCard(
                          'Shopee tidak ada Sample/Gratis terkonfirmasi')
                    else ...[
                      _emptyOkCard(
                          'Tidak ada Sample/Gratis terkonfirmasi untuk filter ini.'),
                      if (_normalizeMarketplaceFilter(_marketplaceFilter) ==
                          'all')
                        _emptyOkCard(
                            'Shopee tidak ada Sample/Gratis terkonfirmasi'),
                    ],
                    if (sampleOrderCount > 0)
                      _miniMetric('Order', sampleOrderCount.toStringAsFixed(0)),
                    if (sampleTextCount > 0)
                      _miniMetric('Teks sample/free',
                          sampleTextCount.toStringAsFixed(0)),
                    if (sampleLabelCount > 0)
                      _miniMetric(
                          'Label produk', sampleLabelCount.toStringAsFixed(0)),
                    if (sampleDiscountCount > 0)
                      _miniMetric('Diskon 100%',
                          sampleDiscountCount.toStringAsFixed(0)),
                    if (sampleFinanceFlagCount > 0)
                      _miniMetric('Flag finance',
                          sampleFinanceFlagCount.toStringAsFixed(0)),
                    if (sampleRawTikTokCount > 0)
                      _miniMetric('Raw TikTok',
                          sampleRawTikTokCount.toStringAsFixed(0)),
                    if (sampleRawTikTokItems > 0)
                      _miniMetric('Item raw TikTok',
                          sampleRawTikTokItems.toStringAsFixed(0)),
                    if (classificationCancelledCount > 0)
                      _miniMetric('Batal dipisah',
                          classificationCancelledCount.toStringAsFixed(0)),
                    if (classificationPendingCount > 0)
                      _miniMetric('Pending dipisah',
                          classificationPendingCount.toStringAsFixed(0)),
                    if (classificationNoPayoutCount > 0)
                      _miniMetric('No Payout eligible',
                          classificationNoPayoutCount.toStringAsFixed(0)),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ],
            _metricGrid([
              _Metric('Omzet', _money(gross), Icons.sell_rounded),
              _Metric('Payout', _money(payout), Icons.payments_rounded),
              _Metric('HPP', _money(hpp), Icons.inventory_2_rounded),
              _Metric(
                  'Biaya Ops', _money(operational), Icons.receipt_long_rounded),
              _Metric(
                  'Sample/Gratis',
                  _sampleFreeLoaded
                      ? sampleOrderCount.toStringAsFixed(0)
                      : 'Belum dimuat',
                  Icons.card_giftcard_rounded),
              _Metric('No Payout', noPayoutCount.toStringAsFixed(0),
                  Icons.hourglass_empty_rounded),
              _Metric('Payout Minus', payoutMinusCount.toStringAsFixed(0),
                  Icons.remove_circle_outline),
              _Metric('Nominal Minus', _money(negativePayout),
                  Icons.money_off_rounded),
              _Metric('Est. HPP Belum Payout', _money(unpaidEstimatedHpp),
                  Icons.inventory_2_outlined),
              _Metric('Abnormal', abnormalCount.toStringAsFixed(0),
                  Icons.warning_amber_rounded),
              _Metric('Sumber', displaySourceCount.toString(),
                  Icons.dataset_rounded),
            ]),
            const SizedBox(height: 16),
            _emptyCard('Filter tanggal aktif untuk semua tab.'),
          ],
        ],
      ),
    );
  }

  Widget _marketplaceTab() {
    if (_loading)
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _sectionHeader('Per Marketplace'),
          SizedBox(height: 8),
          if (_byMarketplace.isEmpty)
            _emptyCard(
                'Data marketplace belum tersedia.\nTarik data finance untuk periode ini.')
          else
            ...() {
              final mktList = _byMarketplace;
              final summaryHpp = _numFirstNonZero([
                _summary['hpp_total'],
                _summary['total_hpp'],
                _summary['paid_hpp_total'],
                _summary['settled_hpp_total'],
                _summary['hpp_cair'],
                _summary['hpp'],
              ]);
              final totalMktGross = mktList.fold<double>(
                0.0,
                (sum, r) =>
                    sum +
                    _num(r['gross_sales'] ?? r['gross'] ?? r['omzet_total']),
              );

              return mktList.map((row) {
                final marketplace =
                    _marketplaceName(_text(row['marketplace']));
                final shop = _text(
                    row['shop_name'] ??
                        row['seller_name'] ??
                        row['account_name'],
                    _accountNameById(_text(row['marketplace_account_id'])));
                final gross =
                    _num(row['gross_sales'] ?? row['gross'] ?? row['omzet']);
                final payout = _num(row['payout_total'] ?? row['net_received']);
                var hpp = _numFirstNonZero([
                  row['hpp_total'],
                  row['total_hpp'],
                  row['paid_hpp_total'],
                  row['settled_hpp_total'],
                  row['hpp_cair'],
                  row['hpp_settled'],
                  row['hpp_amount'],
                  row['hpp'],
                ]);
                if (hpp == 0 &&
                    summaryHpp > 0 &&
                    totalMktGross > 0 &&
                    gross > 0) {
                  hpp = (gross / totalMktGross) * summaryHpp;
                }
                final profit = payout > 0 ? (payout - hpp) : 0.0;
                final margin = payout > 0 ? (profit / payout * 100) : 0.0;
                return _detailCard(
                  title: '$marketplace · $shop',
                  subtitle:
                      '${_num(row['order_count']).toStringAsFixed(0)} pesanan  ·  ${_dateTime(row['last_updated_at'] ?? row['updated_at'])}',
                  children: [
                    _miniMetric('Omzet', _money(gross)),
                    _miniMetric('Payout', _money(payout)),
                    _miniMetric('HPP', _money(hpp)),
                    _miniMetric('Laba', _money(profit)),
                    _miniMetric('Margin', '${margin.toStringAsFixed(2)}%'),
                  ],
                );
              });
            }(),
        ],
      ),
    );
  }

  int get _skuTotalPages {
    if (_skuServerTotalPages > 1) return _skuServerTotalPages;
    if (_bySku.isEmpty) return 1;
    return ((_bySku.length - 1) ~/ _skuPageSize) + 1;
  }

  int get _skuSafePage {
    final totalPages = _skuTotalPages;
    if (_skuPage < 1) return 1;
    if (_skuPage > totalPages) return totalPages;
    return _skuPage;
  }

  List<Map<String, dynamic>> get _skuVisibleRows {
    if (_bySku.isEmpty) return const <Map<String, dynamic>>[];
    final page = _skuSafePage;
    final start = (page - 1) * _skuPageSize;
    if (start >= _bySku.length) return const <Map<String, dynamic>>[];
    final end = (start + _skuPageSize) > _bySku.length
        ? _bySku.length
        : start + _skuPageSize;
    return _bySku.sublist(start, end);
  }

  Widget _skuPaginationControls() {
    if (_bySku.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final page = _skuSafePage;
    final totalPages = _skuTotalPages;
    final canLoadMore = _skuHasMoreServerRows && !_skuLoadingMore;
    final start = ((page - 1) * _skuPageSize) + 1;
    if (start > _bySku.length) return const SizedBox.shrink();
    final end = (page * _skuPageSize) > _bySku.length
        ? _bySku.length
        : page * _skuPageSize;
    final totalCount =
        _skuServerTotalCount > 0 ? _skuServerTotalCount : _bySku.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border.all(
          color: theme.colorScheme.outlineVariant
              .withOpacity(theme.brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'SKU $start–$end dari $totalCount · Page $page/$totalPages',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.75),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Page sebelumnya',
            onPressed:
                page > 1 ? () => setState(() => _skuPage = page - 1) : null,
            icon: Icon(Icons.chevron_left_rounded),
          ),
          IconButton(
            tooltip: 'Page berikutnya',
            onPressed: page < totalPages
                ? (_bySku.length > page * _skuPageSize
                    ? () => setState(() => _skuPage = page + 1)
                    : (canLoadMore ? _loadNextSkuPage : null))
                : null,
            icon: _skuLoadingMore
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildSkuSummaryCard() {
    double totalGross = _num(_summary['gross_sales'] ?? _summary['gross_total'] ?? _summary['gross'] ?? 0);
    double totalPayout = _num(_summary['net_received'] ?? _summary['payout_total'] ?? _summary['payout_amount'] ?? 0);
    double totalHpp = _num(_summary['hpp_total'] ?? _summary['paid_hpp_total'] ?? _summary['hpp'] ?? 0);
    int totalQty = 0;
    int totalSettledQty = 0;

    for (final v in _skuPayoutCountSummaryMap.values.toSet()) {
      totalQty += _num(v['all_qty'] ?? 0).round();
      totalSettledQty += _num(v['paid_qty'] ?? 0).round();
    }

    if (totalQty == 0) {
      totalQty = _numFirstNonZero([
        _summary['total_qty_count'],
        _summary['qty_total'],
        _summary['total_qty'],
        _bySku.fold<num>(0, (sum, row) => sum + _num(row['total_qty'] ?? row['qty_total'] ?? row['qty'])),
      ]).round();
    }
    if (totalSettledQty == 0) {
      totalSettledQty = _numFirstNonZero([
        _summary['settled_qty_count'],
        _summary['qty_settled'],
        totalQty,
      ]).round();
    }

    final double margin = totalPayout > 0 ? ((totalPayout - totalHpp) / totalPayout) * 100 : 0.0;
    final marketplaceName = _marketplaceFilter == 'all' ? 'Semua Platform' : _marketplaceName(_marketplaceFilter);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppUi.modernCardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.date_range_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${_date(_start)} - ${_date(_end)}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  marketplaceName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _isSyncingHpp ? null : _syncSkuHppFromMapping,
                icon: _isSyncingHpp 
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) 
                    : const Icon(Icons.sync_rounded, size: 16),
                label: const Text('Live Sync HPP', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                style: TextButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5),
                  foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _miniMetric('Total Omzet (SKU)', _money(totalGross)),
              _miniMetric('Total Payout (SKU)', _money(totalPayout)),
              _miniMetric('HPP Settled', _money(totalHpp)),
              _miniMetric('Margin Rata-rata', '${margin.toStringAsFixed(2)}%'),
              _miniMetric('Total Qty', '$totalQty'),
              _miniMetric('Qty Settled', '$totalSettledQty'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSkuRowCard(Map<String, dynamic> row) {
    final sku = _text(row['local_sku'] ?? row['sku']);
    final marketplaceSku = _text(
        row['marketplace_sku'] ??
            row['marketplace_sku_id'] ??
            row['marketplace_seller_sku'],
        '');
    final productName = _text(
        row['product_name'] ?? row['nama_barang'],
        'Produk belum diberi nama');
    final variantName = _text(
        row['variant_name'] ?? row['marketplace_variation_name'], '');
    var actualMargin = _num(row['net_margin_percent'] ??
        row['payout_margin_percent'] ??
        row['actual_margin_percent'] ??
        row['gross_margin_percent']);
    final targetMargin = _targetMarginFromRow(row);
    final skuDetailRows = _safeOrderRefRows(row);
    final paidDetailRows =
        _filteredSkuOrderRows(skuDetailRows, 'paid');
    final unpaidDetailRows =
        _filteredSkuOrderRows(skuDetailRows, 'unpaid');
    final returnedDetailRows =
        _filteredSkuOrderRows(skuDetailRows, 'returned');
    final rowTotalQty = _numFirstNonZero([
      row['qty'],
      row['qty_total'],
      row['total_qty'],
    ]).round();
    final paidKey = _skuDetailBusyKeyV82o(row, 'paid');
    final unpaidKey = _skuDetailBusyKeyV82o(row, 'unpaid');
    final returnedKey = _skuDetailBusyKeyV82o(row, 'returned');
    int paidQtyDisplay = _numFirstNonZero([
      row['paid_qty_total'],
      row['settled_qty_total'],
      row['paid_qty'],
      row['settled_qty'],
      row['qty_paid'],
      row['qty_settled'],
      row['settled_qty_count'],
      _skuPaidCountMap[paidKey],
      _qtyFromOrderRows(paidDetailRows),
    ]).round();
    int unpaidQtyDisplay = _numFirstNonZero([
      row['unpaid_qty'],
      row['qty_unpaid'],
      row['unpaid_qty_total'],
      row['pending_payout_qty'],
      row['pending_payout_qty_total'],
      row['qty_pending'],
      row['qty_belum_payout'],
      row['belum_payout_qty'],
      row['unpaid_order_count'],
      row['unpaid_rows'],
      row['unpaid_count'],
      _skuUnpaidCountMap[unpaidKey],
      _qtyFromOrderRows(unpaidDetailRows),
    ]).round();
    int returnedQtyDisplay = _numFirstNonZero([
      row['qty_returned'],
      row['returned_qty'],
      row['qty_batal'],
      row['batal_qty'],
      _skuReturnedCountMap[returnedKey],
      _qtyFromOrderRows(returnedDetailRows),
    ]).round();
    double hppReturnDisplay = _numFirstNonZero([
      row['hpp_return'],
      row['hpp_retur'],
      row['return_hpp'],
      row['batal_hpp'],
    ]);
    if (paidQtyDisplay == 0 && unpaidQtyDisplay == 0 && returnedQtyDisplay == 0 && rowTotalQty > 0) {
      final payoutVal = _num(row['total_payout'] ?? row['payout_total'] ?? row['payout_amount']);
      if (payoutVal > 0) {
        paidQtyDisplay = rowTotalQty;
      } else {
        unpaidQtyDisplay = rowTotalQty;
      }
    }
    final qtyTotalDisplay = _numFirstNonZero([
      rowTotalQty,
      paidQtyDisplay + unpaidQtyDisplay + returnedQtyDisplay,
    ]).round();
    final displayPayoutPerItem = _numFirstNonZero([
      row['payout_per_item_paid'],
      row['payout_per_item'],
      row['positive_payout_per_item'],
      paidQtyDisplay > 0
          ? (_num(row['total_payout'] ??
                  row['payout_total'] ??
                  row['payout_amount'] ??
                  row['received_amount']) /
              paidQtyDisplay)
          : 0,
    ]);
    final grossPerItem = _numFirstNonZero([
      row['gross_per_item'],
      row['unit_gross'],
      qtyTotalDisplay > 0
          ? (_num(row['total_omzet'] ?? row['gross_sales'] ?? row['gross_total']) / qtyTotalDisplay)
          : 0,
      displayPayoutPerItem,
    ]);
    final payoutRange = _positivePayoutRangeForSku(
      row: row,
      detailRows:
          paidDetailRows.isNotEmpty ? paidDetailRows : skuDetailRows,
      settledQty: paidQtyDisplay,
    );
    final highestPayout = payoutRange['highest'] ?? 0.0;
    final lowestPayout = payoutRange['lowest'] ?? 0.0;
    final showPayoutRange = paidDetailRows.isNotEmpty &&
        highestPayout > 0 &&
        lowestPayout > 0 &&
        (highestPayout - lowestPayout).abs() >= 0.5;
    final paidHppTotalForDisplay = _numFirstNonZero([
      row['paid_hpp_total'],
      row['settled_hpp_total'],
      row['hpp_total'],
      row['total_hpp'],
      row['hpp'],
    ]);
    final displayHppPerItem = _numFirstNonZero([
      row['hpp_per_item'],
      row['hpp_unit'],
      row['unit_hpp'],
      row['hpp_item'],
      paidQtyDisplay > 0
          ? paidHppTotalForDisplay / paidQtyDisplay
          : 0,
    ]);
    final hppStatusText = _text(row['hpp_status'], '').toLowerCase();
    final hppMissing =
        displayHppPerItem <= 0 || hppStatusText.contains('belum');
    if (displayPayoutPerItem > 0 && displayHppPerItem > 0) {
      actualMargin = ((displayPayoutPerItem - displayHppPerItem) /
              displayPayoutPerItem) *
          100;
    } else if (hppMissing) {
      actualMargin = 0;
    }
    final displayTargetMargin = targetMargin > 0 ? targetMargin : 30.0;
    final belowTarget = !hppMissing &&
        displayTargetMargin > 0 &&
        actualMargin < displayTargetMargin;
    final settledBusy =
        _skuDetailBusyKey == _skuDetailBusyKeyV82o(row, 'paid');
    final unpaidBusy =
        _skuDetailBusyKey == _skuDetailBusyKeyV82o(row, 'unpaid');
    final returnedBusy =
        _skuDetailBusyKey == _skuDetailBusyKeyV82o(row, 'returned');
    final detailBusy = _skuDetailBusyKey != null;
    return _detailCard(
      title: sku,
      subtitle: [
        productName,
        if (variantName.isNotEmpty) 'Varian: $variantName',
        if (marketplaceSku.isNotEmpty)
          'SKU marketplace: $marketplaceSku',
      ].join(' · '),
      trailing: Wrap(
        spacing: 6,
        children: [
          OutlinedButton.icon(
            onPressed: detailBusy
                ? null
                : () => _showSkuOrderRefsV82o(
                      row,
                      payoutFilter: 'all',
                    ),
            icon: const Icon(Icons.info_outline_rounded, size: 15),
            label: const Text('Detail SKU',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          TextButton.icon(
            onPressed: detailBusy
                ? null
                : () => _showSkuOrderRefsV82o(
                      row,
                      payoutFilter: 'paid',
                    ),
            icon: settledBusy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.receipt_long_rounded, size: 16),
            label: Text('Settled $paidQtyDisplay',
                style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          TextButton.icon(
            onPressed: detailBusy
                ? null
                : () => _showSkuOrderRefsV82o(
                      row,
                      payoutFilter: 'unpaid',
                    ),
            icon: unpaidBusy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.pending_actions_rounded, size: 16),
            label: Text('Belum payout $unpaidQtyDisplay',
                style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          if (returnedQtyDisplay > 0)
            TextButton.icon(
              onPressed: detailBusy
                  ? null
                  : () => _showSkuOrderRefsV82o(
                        row,
                        payoutFilter: 'returned',
                      ),
              icon: returnedBusy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.assignment_return_rounded, size: 16, color: Colors.red.shade600),
              label: Text('Retur/Batal $returnedQtyDisplay',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade600, fontWeight: FontWeight.w700)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
      children: [
        if (marketplaceSku.isNotEmpty)
          _miniMetric('SKU marketplace', marketplaceSku),
        if (variantName.isNotEmpty)
          _miniMetric('Varian', variantName),
        _miniMetric('Qty total', '$qtyTotalDisplay'),
        _miniMetric('Qty settled', '$paidQtyDisplay'),
        _miniMetric('Qty belum payout', '$unpaidQtyDisplay',
            warning: unpaidQtyDisplay > 0),
        if (returnedQtyDisplay > 0)
          _miniMetric('Qty retur/batal', '$returnedQtyDisplay', warning: true),
        if (hppReturnDisplay > 0)
          _miniMetric('HPP retur/batal', _money(hppReturnDisplay), warning: true),
        if (_num(row['positive_payout_qty']) > 0)
          _miniMetric('Qty payout +',
              _num(row['positive_payout_qty']).toStringAsFixed(0)),
        if (_num(row['negative_payout_qty']) > 0)
          _miniMetric('Qty koreksi -',
              _num(row['negative_payout_qty']).toStringAsFixed(0),
              warning: true),
        _miniMetric(
            'Gross/item', _money(grossPerItem)),
        if (showPayoutRange) ...[
          _miniMetric('Payout tertinggi', _money(highestPayout)),
          _miniMetric('Payout terendah', _money(lowestPayout)),
        ] else
          _miniMetric(
            'Payout settled/item',
            displayPayoutPerItem > 0
                ? _money(displayPayoutPerItem)
                : 'Belum ada payout',
          ),
        _miniMetric(
            'Total payout',
            _money(_num(row['total_payout'] ??
                row['payout_total'] ??
                row['payout_amount'] ??
                row['received_amount']))),
        if (_num(row['negative_payout_total']) < 0)
          _miniMetric('Koreksi minus',
              _money(_num(row['negative_payout_total'])),
              warning: true),
        _miniMetric(
            'HPP/item',
            hppMissing
                ? 'HPP belum mapping'
                : _money(displayHppPerItem),
            warning: hppMissing),
        _miniMetric(
            'Margin net',
            hppMissing
                ? 'HPP belum mapping'
                : '${actualMargin.toStringAsFixed(2)}%',
            warning: belowTarget),
        _miniMetric(
            'Target',
            '${displayTargetMargin.toStringAsFixed(2)}%'),
      ],
    );
  }

  Widget _skuTab() {
    if (_loading)
      return Center(child: FuturisticLoader(message: 'Memuat data...'));

    if (!_skuLoaded && !_skuLoadingFirstPage) {
      _skuLoadingFirstPage = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _lazyLoadSkuFirstPage();
      });
    }

    if ((_skuLoadingFirstPage || !_skuLoaded) && _bySku.isEmpty) {
      return Center(child: FuturisticLoader(message: 'Memuat data SKU...'));
    }

    final visibleRows = _skuVisibleRows;
    final parsedRowsExist = _lastSkuParsedRowCount > 0;
    final showEmptySkuState = visibleRows.isEmpty && !parsedRowsExist;

    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _buildSkuSummaryCard(),
          const SizedBox(height: 16),
          if (_enableSkuDebugLogs && _lastSkuDebugProof.trim().isNotEmpty) ...[
            _emptyCard('Debug SKU: $_lastSkuDebugProof'),
            const SizedBox(height: 8),
          ],
          if (_bySku.isNotEmpty) ...[
            _sectionHeader('Daftar SKU'),
            const SizedBox(height: 8),
            _skuPaginationControls(),
            const SizedBox(height: 10),
          ],
          if (showEmptySkuState)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(20),
              decoration: AppUi.modernCardDecoration(context),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shopping_bag_outlined,
                      size: 24, color: Theme.of(context).colorScheme.primary),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Belum ada data SKU finance.\nAuto finance sedang mengejar data periode ini di background. Pastikan mapping SKU lokal sudah benar agar HPP ikut terbaca.',
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.82),
                          height: 1.4),
                    ),
                  ),
                ],
              ),
            )
          else if (visibleRows.isEmpty && parsedRowsExist)
            _emptyCard(
                'Data SKU sudah diterima ($_lastSkuParsedRowCount parsed), sedang menunggu render ulang. Tekan muat ulang jika kartu belum muncul.')
          else
            ...visibleRows.map((row) => _buildSkuRowCard(row)),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _fallbackCashFlowRows() {
    final summaryPayout = _num(_summary['payout_total'] ??
        _summary['payout_amount'] ??
        _summary['payout'] ??
        _summary['received_amount'] ??
        _summary['net_received']);
    final manual = _numFirstNonZero([
      _summary['manual_expense_total'],
      _summary['manual_operational_expense']
    ]);
    final production = _numFirstNonZero([
      _summary['production_paid_total'],
      _summary['paid_production_total'],
      _summary['production_tailor_paid_total']
    ]);
    final purchases = _numFirstNonZero([
      _summary['approved_purchase_total'],
      _summary['purchase_cashout'],
      _summary['approved_purchase_cashout']
    ]);
    final netCash = summaryPayout - manual - production - purchases;
    if (summaryPayout == 0 &&
        manual == 0 &&
        production == 0 &&
        purchases == 0 &&
        netCash == 0) return <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      {
        'category': 'Marketplace',
        'type': 'in',
        'amount': summaryPayout,
        'description': 'Payout diterima'
      },
      if (manual > 0)
        {
          'category': 'Biaya Operasional',
          'type': 'out',
          'amount': -manual.abs(),
          'description': 'Biaya operasional manual'
        },
      if (purchases > 0)
        {
          'category': 'Pembelian Disetujui',
          'type': 'out',
          'amount': -purchases.abs(),
          'description': 'Pembelian yang sudah disetujui finance'
        },
      if (production > 0)
        {
          'category': 'Produksi Paid',
          'type': 'out',
          'amount': -production.abs(),
          'description': 'Pembayaran produksi/tailor yang sudah dibayar'
        },
      {
        'category': 'Jumlah Arus Kas',
        'type': netCash >= 0 ? 'in' : 'out',
        'amount': netCash,
        'description':
            'Payout - biaya manual - pembelian disetujui - produksi paid'
      },
    ];
  }

  List<Map<String, dynamic>> _fallbackProfitLossRows() {
    final paidSkuTotals = _totalsFromSkuRows(paidOnly: true);
    final summaryGross = _num(_summary['gross_sales'] ??
        _summary['gross_total'] ??
        _summary['gross'] ??
        _summary['omzet_total'] ??
        _summary['omzet']);
    final summaryPayout = _num(_summary['payout_total'] ??
        _summary['payout_amount'] ??
        _summary['payout'] ??
        _summary['received_amount'] ??
        _summary['net_received']);
    final summaryHpp =
        _num(_summary['hpp_total'] ?? _summary['hpp'] ?? _summary['total_hpp']);
    final gross =
        paidSkuTotals['gross']! > 0 ? paidSkuTotals['gross']! : summaryGross;
    final payout =
        paidSkuTotals['payout']! > 0 ? paidSkuTotals['payout']! : summaryPayout;
    final hpp = paidSkuTotals['hpp']! > 0 ? paidSkuTotals['hpp']! : summaryHpp;
    final manual = _numFirstNonZero([
      _summary['manual_expense_total'],
      _summary['manual_operational_expense']
    ]);
    final production = _numFirstNonZero([
      _summary['production_paid_total'],
      _summary['paid_production_total'],
      _summary['production_tailor_paid_total']
    ]);
    final purchases = _numFirstNonZero([
      _summary['approved_purchase_total'],
      _summary['purchase_cashout'],
      _summary['approved_purchase_cashout']
    ]);
    final profit = payout - hpp - manual - production - purchases;
    if (gross == 0 &&
        payout == 0 &&
        hpp == 0 &&
        manual == 0 &&
        production == 0 &&
        purchases == 0 &&
        profit == 0) return <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      {
        'label': 'Omzet',
        'amount': gross,
        'description': 'Total nilai order marketplace'
      },
      {
        'label': 'Payout',
        'amount': payout,
        'description': 'Dana marketplace yang sudah release'
      },
      {
        'label': 'HPP',
        'amount': -hpp.abs(),
        'description': 'Harga pokok penjualan dari SKU lokal'
      },
      if (manual > 0)
        {
          'label': 'Biaya Operasional',
          'amount': -manual.abs(),
          'description': 'Biaya operasional manual'
        },
      if (purchases > 0)
        {
          'label': 'Pembelian Disetujui',
          'amount': -purchases.abs(),
          'description': 'Pembelian yang sudah disetujui finance'
        },
      if (production > 0)
        {
          'label': 'Produksi Paid',
          'amount': -production.abs(),
          'description': 'Pembayaran produksi/tailor yang sudah dibayar'
        },
      {
        'label': 'Laba Bersih',
        'amount': profit,
        'description':
            'Payout - HPP - biaya manual - pembelian disetujui - produksi paid'
      },
    ];
  }

  bool _cashFlowRowIsOut(Map<String, dynamic> row) {
    final direction =
        _text(row['direction'] ?? row['cash_type'] ?? row['type'], '')
            .trim()
            .toLowerCase()
            .replaceAll('_', ' ');

    final source = _text(row['source'] ?? row['source_module'], '')
        .trim()
        .toLowerCase()
        .replaceAll('_', ' ');
    final category = _text(row['category'] ?? row['label'] ?? row['title'], '')
        .trim()
        .toLowerCase()
        .replaceAll('_', ' ');
    final description =
        _text(row['description'] ?? row['note'] ?? row['items'], '')
            .trim()
            .toLowerCase()
            .replaceAll('_', ' ');

    final text = '$direction $source $category $description';

    // Payout marketplace dan kas masuk manual adalah inflow.
    // Jangan pakai contains("out") karena kata "payout" mengandung "out".
    if (direction == 'in' ||
        direction == 'cash in' ||
        direction == 'masuk' ||
        category.contains('kas masuk') ||
        source.contains('marketplace payout') ||
        source.contains('marketplace payout') ||
        source.contains('marketplacepayout') ||
        source.contains('payout') ||
        category.contains('payout') ||
        description.contains('payout marketplace') ||
        description.contains('payout diterima')) {
      return false;
    }

    if (direction == 'out' ||
        direction == 'cash out' ||
        direction == 'keluar' ||
        direction == 'expense' ||
        direction == 'withdrawal') {
      return true;
    }

    return text.contains('biaya') ||
        text.contains('expense') ||
        text.contains('operasional') ||
        text.contains('pembelian') ||
        text.contains('purchase') ||
        text.contains('cashout') ||
        text.contains('cash out') ||
        text.contains('penarikan') ||
        text.contains('withdrawal');
  }

  num _cashFlowSignedAmount(Map<String, dynamic> row) {
    final raw = _num(row['amount'] ??
        row['value'] ??
        row['total'] ??
        row['nominal'] ??
        row['expense_amount'] ??
        row['purchase_amount']);

    if (raw == 0) return 0;
    return _cashFlowRowIsOut(row) ? -raw.abs() : raw.abs();
  }

  bool _isManualCashAdjustmentRow(Map<String, dynamic> row) {
    if (_isUuid(_text(row['cash_adjustment_id'], ''))) return true;

    final sourceText = [
      row['source_table'],
      row['source_module'],
      row['source'],
      row['table'],
      row['_cash_wallet_kind'],
    ].map((value) => _text(value, '').toLowerCase()).join(' ');

    return sourceText.contains('finance_company_cash_adjustments') ||
        sourceText.contains('cash_adjustment') ||
        sourceText.contains('cash adjustment') ||
        sourceText.contains('adjustment');
  }

  Map<String, dynamic>? _editableManualCashAdjustmentRow(
      Map<String, dynamic> row) {
    if (_isDemoSuperAdmin || !_canWriteFinance) return null;
    if (!_isManualCashAdjustmentRow(row)) return null;
    final id = _text(row['cash_adjustment_id'], '').trim();
    if (!_isUuid(id)) return null;
    return {
      ...row,
      'cash_adjustment_id': id,
      'source_table': 'finance_company_cash_adjustments',
    };
  }

  bool _financeSkuHasRealLocalMapping(
    Map<String, dynamic> row, [
    Map<String, dynamic>? detailRow,
  ]) {
    final local = _text(
      row['mapped_local_sku'] ??
          detailRow?['mapped_local_sku'] ??
          row['local_sku'] ??
          detailRow?['local_sku'],
      '',
    ).trim();

    if (local.isEmpty ||
        local == '-' ||
        local.toLowerCase() == 'null' ||
        local.toLowerCase() == 'unmapped' ||
        local.toLowerCase().contains('belum mapping')) {
      return false;
    }

    final mappingText = [
      row['mapping_status'],
      detailRow?['mapping_status'],
      row['hpp_status'],
      detailRow?['hpp_status'],
      row['hpp_label'],
      detailRow?['hpp_label'],
    ].map((value) => _text(value, '').toLowerCase()).join(' ');

    if (mappingText.contains('unmapped') ||
        mappingText.contains('not mapped') ||
        mappingText.contains('missing') ||
        mappingText.contains('pending') ||
        mappingText.contains('belum mapping') ||
        mappingText.contains('hpp belum mapping')) {
      return false;
    }

    final marketplaceValues = <String>[
      _text(row['sku'], ''),
      _text(row['marketplace_sku'], ''),
      _text(row['marketplace_sku_id'], ''),
      _text(row['marketplace_seller_sku'], ''),
      _text(row['seller_sku'], ''),
      _text(detailRow?['sku'], ''),
      _text(detailRow?['marketplace_sku'], ''),
      _text(detailRow?['marketplace_sku_id'], ''),
      _text(detailRow?['marketplace_seller_sku'], ''),
      _text(detailRow?['seller_sku'], ''),
    ]
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty && value != '-' && value != 'null')
        .toSet();

    final localLower = local.toLowerCase();
    final hppValue = _num(row['hpp_per_item'] ??
        row['unit_hpp'] ??
        row['hpp'] ??
        detailRow?['hpp_per_item'] ??
        detailRow?['unit_hpp'] ??
        detailRow?['hpp']);

    // Kalau local_sku sama dengan marketplace/seller SKU dan HPP belum ada,
    // itu fallback marketplace, bukan mapping SKU lokal.
    if (marketplaceValues.contains(localLower) && hppValue <= 0) return false;

    return true;
  }

  String _financeSkuLocalMappingLabel(
    Map<String, dynamic> item,
    Map<String, dynamic> detailRow,
  ) {
    if (!_financeSkuHasRealLocalMapping(item, detailRow)) {
      return 'Belum mapping';
    }
    return _cleanText(
      item['mapped_local_sku'] ??
          detailRow['mapped_local_sku'] ??
          item['local_sku'] ??
          detailRow['local_sku'] ??
          detailRow['sku'],
      'Belum mapping',
    );
  }

  List<Map<String, dynamic>> _normalizedCashFlowRows() {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addRow(Map<String, dynamic> row) {
      final amount = _cashFlowSignedAmount(row);
      if (amount == 0) return;

      final normalized = Map<String, dynamic>.from(row);
      normalized['amount'] = amount;
      normalized['type'] = amount < 0 ? 'out' : 'in';
      normalized['cash_type'] = normalized['type'];

      final key = _text(
          normalized['cash_adjustment_id'] ??
              normalized['marketplace_cashflow_key'] ??
              normalized['source_ref'] ??
              normalized['id'] ??
              '${normalized['source']}|${normalized['category']}|${normalized['date']}|${normalized['amount']}',
          '');
      if (seen.add(key)) out.add(normalized);
    }

    String marketplaceName(Map<String, dynamic> row) {
      final raw = _text(
          row['marketplace'] ??
              row['marketplace_group'] ??
              row['account_name'] ??
              row['shop_name'] ??
              row['store_alias'],
          '');
      final lower = raw.toLowerCase();
      if (lower.contains('tiktok')) return 'TikTok';
      if (lower.contains('shopee')) return 'Shopee';
      return raw.isEmpty ? 'Marketplace' : raw;
    }

    // 1. Marketplace payout = kas masuk.
    var hasMarketplacePayout = false;
    for (final row in _byMarketplace) {
      final payout = _numFirstNonZero([
        row['payout_total'],
        row['payout_amount'],
        row['received_amount'],
        row['net_received'],
        row['net_settlement'],
      ]);
      if (payout <= 0) continue;

      final name = marketplaceName(row);
      final marketplace =
          _text(row['marketplace'] ?? row['marketplace_group'], '');
      final accountId = _text(
        row['marketplace_account_id'] ?? row['account_id'] ?? row['id'],
        '',
      );

      addRow({
        'marketplace_cashflow_key':
            'marketplace_payout|$marketplace|$accountId',
        'date': _end,
        'source': '${name} Payout',
        'category': '${name} Payout',
        'title': '${name} Payout',
        'description':
            '${name} payout periode ${_date(_start)} - ${_date(_end)}',
        'type': 'in',
        'cash_type': 'in',
        'direction': 'in',
        'amount': payout,
        'marketplace': marketplace,
        'marketplace_account_id': accountId,
      });

      hasMarketplacePayout = true;
    }

    // Fallback kalau by_marketplace belum ada.
    if (!hasMarketplacePayout) {
      final payout = _numFirstNonZero([
        _summary['payout_total'],
        _summary['payout_amount'],
        _summary['received_amount'],
        _summary['net_received'],
        _summary['net_settlement'],
      ]);
      if (payout > 0) {
        addRow({
          'marketplace_cashflow_key': 'marketplace_payout|all',
          'date': _end,
          'source': 'Marketplace Payout',
          'category': 'Marketplace Payout',
          'title': 'Marketplace Payout',
          'description':
              'Marketplace payout periode ${_date(_start)} - ${_date(_end)}',
          'type': 'in',
          'cash_type': 'in',
          'direction': 'in',
          'amount': payout,
        });
      }
    }

    // 2. Kas masuk/keluar manual. HAR membuktikan data ini ada di
    // finance_company_cash_adjustments, jadi harus ikut.
    for (final row in _cashAdjustments) {
      addRow({
        ...row,
        'source_table': 'finance_company_cash_adjustments',
        'source': _text(row['category'], 'Kas manual'),
        'category': _text(row['category'], 'Kas manual'),
        'title': _text(row['category'], 'Kas manual'),
        'date': row['adjustment_date'] ?? row['date'] ?? row['created_at'],
      });
    }

    // Fallback manual cash dari _cashFlow, untuk case state _cashFlow sudah berisi
    // finance_company_cash_adjustments tapi _cashAdjustments belum keisi.
    for (final row in _cashFlow) {
      final hasCashAdjustmentId =
          _text(row['cash_adjustment_id'], '').trim().isNotEmpty;
      final category =
          _text(row['category'] ?? row['title'] ?? row['source'], '')
              .toLowerCase();
      final isMarketplacePayoutRow = category.contains('marketplace') ||
          category.contains('payout') ||
          category.contains('shopee') ||
          category.contains('tiktok');
      if (isMarketplacePayoutRow && hasMarketplacePayout) {
        continue;
      }

      final dir =
          _text(row['direction'] ?? row['cash_type'] ?? row['type'], '')
              .toLowerCase();

      if (hasCashAdjustmentId ||
          category.contains('kas masuk') ||
          category.contains('kas manual') ||
          (dir == 'in' && !isMarketplacePayoutRow)) {
        addRow({
          ...row,
          if (hasCashAdjustmentId)
            'source_table': 'finance_company_cash_adjustments',
          'source': _text(row['category'] ?? row['source'], 'Kas manual'),
          'category': _text(row['category'] ?? row['source'], 'Kas manual'),
          'title': _text(row['category'] ?? row['source'], 'Kas manual'),
          'date': row['adjustment_date'] ?? row['date'] ?? row['created_at'],
        });
      }
    }

    // 3. Saldo awal kalau ada.
    for (final row in _cashOpeningBalances) {
      addRow({
        ...row,
        'source': 'Saldo awal',
        'category': 'Saldo awal',
        'title': 'Saldo awal',
        'type': 'in',
        'cash_type': 'in',
        'direction': 'in',
        'date': row['balance_date'] ?? row['date'] ?? row['created_at'],
      });
    }

    // 4. Biaya Operasional & Pembelian Disetujui (Rincian per item jika ada).
    if (_expenses.isNotEmpty || _approvedPurchases.isNotEmpty) {
      for (final exp in _expenses) {
        final amount = _num(exp['amount']).abs();
        if (amount <= 0) continue;
        final title = _text(exp['title'] ?? exp['name'] ?? exp['category'], 'Biaya Operasional');
        addRow({
          'marketplace_cashflow_key':
              'expense_${exp['id'] ?? exp['expense_id'] ?? title}_${exp['expense_date']}_$amount',
          'date': exp['expense_date'] ?? exp['date'] ?? exp['created_at'] ?? _end,
          'source': 'Biaya Operasional',
          'category': 'Biaya Operasional',
          'title': title,
          'description':
              _text(exp['description'] ?? exp['notes'], 'Biaya operasional'),
          'type': 'out',
          'cash_type': 'out',
          'direction': 'out',
          'amount': -amount,
        });
      }
      for (final pur in _approvedPurchases) {
        final amount = _num(pur['amount'] ?? pur['total_harga'] ?? pur['total_pembelian']).abs();
        if (amount <= 0) continue;
        final title = _text(
          pur['title'] ??
              pur['item_name'] ??
              pur['nama_barang'] ??
              pur['supplier_name'] ??
              pur['nomor_pembelian'],
          'Pembelian Disetujui',
        );
        addRow({
          'marketplace_cashflow_key':
              'purchase_${pur['id'] ?? pur['purchase_id'] ?? title}_${pur['expense_date'] ?? pur['tanggal']}_$amount',
          'date': pur['expense_date'] ?? pur['tanggal'] ?? pur['date'] ?? _end,
          'source': 'Pembelian Disetujui',
          'category': 'Pembelian Disetujui',
          'title': title,
          'description': _text(
              pur['supplier_name'] ?? pur['description'] ?? pur['catatan'],
              'Pembelian disetujui'),
          'type': 'out',
          'cash_type': 'out',
          'direction': 'out',
          'amount': -amount,
        });
      }
    } else {
      final expenseTotal = _numFirstNonZero([
        _summary['operational_cost_total'],
        _summary['expense_total'],
      ]);
      final manualExpense = _numFirstNonZero([
        _summary['manual_expense_total'],
        _summary['manual_operational_expense'],
        _summary['operational_expense'],
      ]);
      final purchaseCashout = _numFirstNonZero([
        _summary['purchase_cashout'],
        _summary['approved_purchase_cashout'],
        _summary['approved_purchase_total'],
      ]);

      final mergedOut =
          expenseTotal > 0 ? expenseTotal : (manualExpense + purchaseCashout);

      if (mergedOut > 0) {
        addRow({
          'marketplace_cashflow_key': 'expense_purchase_merged',
          'date': _end,
          'source': 'Biaya & Pembelian',
          'category': 'Biaya & Pembelian',
          'title': 'Biaya & Pembelian',
          'description': 'Detail lihat tab Biaya',
          'type': 'out',
          'cash_type': 'out',
          'direction': 'out',
          'amount': -mergedOut.abs(),
        });
      }
    }

    out.sort((a, b) {
      final ad = _parseDate(a['date'] ??
              a['adjustment_date'] ??
              a['balance_date'] ??
              a['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bd = _parseDate(b['date'] ??
              b['adjustment_date'] ??
              b['balance_date'] ??
              b['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });

    return out;
  }

  Widget _cashFlowTab() {
    if (_loading) {
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
    }
    if (!_operationalCostsLoaded &&
        !_operationalCostsLoading &&
        _operationalCostsError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadOperationalCostsSupplemental());
      });
    }
    final cashRows = _normalizedCashFlowRows();
    final walletRows = _cashWalletRowsForDisplay(
      opening: _cashOpeningBalances,
      adjustments: _cashAdjustments,
      withdrawals: _marketplaceWithdrawals,
    );
    bool isNetRow(Map<String, dynamic> row) {
      final label = _text(row['source'] ?? row['category']).toLowerCase();
      return label.contains('arus kas bersih') ||
          label.contains('total arus kas') ||
          label.contains('jumlah arus kas');
    }

    final detailCashRows =
        cashRows.where((row) => !isNetRow(row)).toList(growable: false);

    num totalIn = 0;
    num totalOut = 0;
    for (final row in [
      ...cashRows.where((row) => !isNetRow(row)),
      ...walletRows,
    ]) {
      if (row['_cash_wallet_kind'] == 'withdrawal' ||
          row['_cash_wallet_kind'] == 'adjustment') {
        continue;
      }
      final amount = _cashFlowSignedAmount(row);
      if (amount >= 0) {
        totalIn += amount;
      } else {
        totalOut += amount.abs();
      }
    }
    final netCash = totalIn - totalOut;
    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _sectionHeader('Jumlah / Total Arus Kas'),
          SizedBox(height: 8),
          if (!_operationalCostsLoaded) ...[
            if (_operationalCostsLoading)
              _emptyCard('Memuat rincian biaya dan pembelian...')
            else ...[
              if (_operationalCostsError != null)
                _emptyCard(
                    'Rincian biaya belum termuat: $_operationalCostsError'),
              _emptyCard('Rincian biaya akan dimuat otomatis.'),
              const SizedBox(height: 12),
            ],
          ],
          _metricGrid([
            _Metric('Total Masuk', _money(totalIn), Icons.south_west_rounded),
            _Metric('Total Keluar', _money(totalOut), Icons.north_east_rounded),
            _Metric(
              'Jumlah Arus Kas',
              _money(netCash),
              Icons.account_balance_wallet_rounded,
            ),
          ]),
          SizedBox(height: 12),
          if (_canWriteFinance) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _processing ? null : _editCashOpeningBalance,
                  icon: Icon(Icons.account_balance_wallet_rounded, size: 18),
                  label: Text('Saldo awal'),
                ),
                OutlinedButton.icon(
                  onPressed: _processing
                      ? null
                      : () => _editCashAdjustment(direction: 'in'),
                  icon: Icon(Icons.south_west_rounded, size: 18),
                  label: Text('Kas masuk'),
                ),
                OutlinedButton.icon(
                  onPressed: _processing
                      ? null
                      : () => _editCashAdjustment(direction: 'out'),
                  icon: Icon(Icons.north_east_rounded, size: 18),
                  label: Text('Kas keluar'),
                ),
                OutlinedButton.icon(
                  onPressed: _processing ? null : _editMarketplaceWithdrawal,
                  icon: Icon(Icons.account_balance_rounded, size: 18),
                  label: Text('Penarikan'),
                ),
              ],
            ),
            SizedBox(height: 12),
          ],
          if (detailCashRows.isEmpty)
            _emptyCard('Belum ada arus kas pada periode ini.')
          else
            ...detailCashRows.map((row) {
              final type = _text(row['cash_type'] ?? row['type']);
              final amount = _cashFlowSignedAmount(row);
              final editableCashAdjustment =
                  _editableManualCashAdjustmentRow(row);
              return _simpleRowCard(
                title: _sourceLabel(_text(
                    row['title'] ?? row['category'] ?? row['source'] ?? type)),
                subtitle:
                    '${_date(row['date'] ?? row['created_at'])} - ${type.toUpperCase()}',
                trailing: (amount >= 0 ? '+ ' : '- ') + _money(amount.abs()),
                positive: amount >= 0,
                actions: editableCashAdjustment == null
                    ? const <Widget>[]
                    : [
                        _tinyActionButton(
                            Icons.edit_rounded,
                            'Edit',
                            () => _editCashAdjustment(
                                  row: editableCashAdjustment,
                                )),
                        _tinyActionButton(
                          Icons.delete_outline_rounded,
                          'Hapus',
                          () => _deleteCashAdjustment(editableCashAdjustment),
                          danger: true,
                        ),
                      ],
              );
            }),
          if (_cashOpeningBalances.isNotEmpty ||
              _cashAdjustments.isNotEmpty ||
              _marketplaceWithdrawals.isNotEmpty) ...[
            SizedBox(height: 16),
            _sectionHeader('Kelola Input Arus Kas'),
            SizedBox(height: 8),
            ...walletRows.map(_cashWalletInputRowCard),
          ],
          if (_withdrawalAllocations.isNotEmpty) ...[
            SizedBox(height: 16),
            _sectionHeader('Alokasi Penarikan'),
            SizedBox(height: 8),
            ..._withdrawalAllocations.map(_withdrawalAllocationRowCard),
          ],
        ],
      ),
    );
  }

  Widget _manualExpenseRowCard(Map<String, dynamic> row) {
    final amount = _numFirstNonZero(
      [row['amount'], row['total_amount'], row['expense_total']],
    );
    final editable =
        !_isDemoSuperAdmin && _isEditableOperationalExpenseRow(row);
    final sourceLabel = _expenseSourceLabel(row);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _text(row['category'] ?? row['title'], 'Operasional'),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    _date(row['expense_date'] ??
                        row['paid_at'] ??
                        row['created_at']),
                    sourceLabel,
                    _text(row['note'] ?? row['description'], '-'),
                  ]
                      .where((item) =>
                          item.trim().isNotEmpty && item.trim() != '-')
                      .join('  ·  '),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.82),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _money(amount),
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          if (editable) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Edit biaya',
              onPressed: _processing ? null : () => _editManualExpense(row),
              icon: Icon(Icons.edit_note_rounded, size: 20),
            ),
            IconButton(
              tooltip: 'Hapus biaya',
              onPressed: _processing ? null : () => _deleteManualExpense(row),
              icon: Icon(Icons.delete_outline_rounded, size: 20),
            ),
          ],
        ],
      ),
    );
  }

  Widget _expensesTab() {
    if (_loading)
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
    if (!_operationalCostsLoaded &&
        !_operationalCostsLoading &&
        _operationalCostsError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadOperationalCostsSupplemental());
      });
    }

    final summaryManualExpense = _num(_summary['manual_expense_total']);
    final summaryProductionPaid = _num(_summary['production_paid_total']);
    final summaryApprovedPurchase = _num(_summary['approved_purchase_total']);

    bool isNetRow(Map<String, dynamic> row) {
      final label = _text(row['source'] ?? row['category']).toLowerCase();
      return label.contains('arus kas bersih') ||
          label.contains('total arus kas') ||
          label.contains('jumlah arus kas');
    }

    final hasCashFlowOutflow = () {
      final cashRows =
          _cashFlow.isNotEmpty ? _cashFlow : _fallbackCashFlowRows();
      for (final row in cashRows) {
        if (isNetRow(row)) continue;
        final amount = _num(row['amount']);
        if (amount < 0) return true;
      }
      return false;
    }();

    final hasBiayaSummaryOrCashFlow = summaryManualExpense > 0 ||
        summaryProductionPaid > 0 ||
        summaryApprovedPurchase > 0 ||
        hasCashFlowOutflow;

    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 130),
        children: [
          _sectionHeader('Biaya Operasional'),
          const SizedBox(height: 8),
          if (!_operationalCostsLoaded) ...[
            if (_operationalCostsLoading)
              _emptyCard('Memuat rincian biaya dan pembelian...')
            else ...[
              if (_operationalCostsError != null)
                _emptyCard(
                    'Rincian biaya belum termuat: $_operationalCostsError'),
              _emptyCard('Rincian biaya akan dimuat otomatis.'),
            ],
          ] else ...[
            if (_expenses.isEmpty && _approvedPurchases.isEmpty) ...[
              if (hasBiayaSummaryOrCashFlow) ...[
                if (summaryManualExpense > 0)
                  _simpleRowCard(
                    title: 'Total Biaya Operasional',
                    subtitle: 'Berdasarkan data Ringkasan/Snapshot',
                    trailing: _money(summaryManualExpense),
                    positive: false,
                  ),
                if (summaryProductionPaid > 0)
                  _simpleRowCard(
                    title: 'Total Ongkos Produksi',
                    subtitle: 'Berdasarkan data Ringkasan/Snapshot',
                    trailing: _money(summaryProductionPaid),
                    positive: false,
                  ),
                if (summaryApprovedPurchase > 0)
                  _simpleRowCard(
                    title: 'Total Pembelian Disetujui',
                    subtitle: 'Berdasarkan data Ringkasan/Snapshot',
                    trailing: _money(summaryApprovedPurchase),
                    positive: false,
                  ),
                if (hasCashFlowOutflow &&
                    summaryManualExpense == 0 &&
                    summaryProductionPaid == 0 &&
                    summaryApprovedPurchase == 0)
                  _simpleRowCard(
                    title: 'Total Biaya (Arus Kas Keluar)',
                    subtitle: 'Berdasarkan data Arus Kas',
                    trailing: _money(
                      () {
                        num totalOut = 0;
                        final cashRows = _cashFlow.isNotEmpty
                            ? _cashFlow
                            : _fallbackCashFlowRows();
                        final walletRows = _cashWalletRowsForDisplay(
                          opening: _cashOpeningBalances,
                          adjustments: _cashAdjustments,
                          withdrawals: _marketplaceWithdrawals,
                        );
                        for (final row in [
                          ...cashRows.where((row) => !isNetRow(row)),
                          ...walletRows,
                        ]) {
                          if (row['_cash_wallet_kind'] == 'withdrawal' ||
                              row['_cash_wallet_kind'] == 'adjustment') {
                            continue;
                          }
                          final amount = _num(row['amount']);
                          if (amount < 0) {
                            totalOut += amount.abs();
                          }
                        }
                        return totalOut;
                      }(),
                    ),
                    positive: false,
                  ),
              ] else
                _emptyCard(
                    'Belum ada biaya operasional atau pembelian yang sudah disetujui.')
            ] else ...[
              ..._expenses.map(_manualExpenseRowCard),
              if (_approvedPurchases.isNotEmpty) ...[
                SizedBox(height: 14),
                _sectionHeader('Pembelian Disetujui'),
                SizedBox(height: 8),
                ..._approvedPurchases.map((row) => _simpleRowCard(
                      title: _text(
                          row['title'] ??
                              row['item'] ??
                              row['item_name'] ??
                              row['nama_barang'] ??
                              row['category'],
                          'Pembelian'),
                      subtitle: <String>[
                        _date(row['expense_date'] ??
                            row['date'] ??
                            row['tanggal'] ??
                            row['approved_at'] ??
                            row['created_at']),
                        _expenseSourceLabel(row),
                        _text(
                            row['supplier_name'] ??
                                row['description'] ??
                                row['source'],
                            ''),
                        if (_purchaseQty(row) > 0) 'Qty ${_purchaseQty(row)}',
                      ]
                          .where((item) =>
                              item.trim().isNotEmpty && item.trim() != '-')
                          .join('  ·  '),
                      trailing: _money(_purchaseAmount(row)),
                      positive: false,
                    )),
              ],
            ],
          ],
        ],
      ),
    );
  }

  bool _isGenericSettlementProfitLossRow(Map<String, dynamic> row) {
    final raw = _text(row['category'] ?? row['name'] ?? row['label']);
    final key = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

    if (key == 'omzet' ||
        key == 'gross_sales' ||
        key.contains('payout_diterima') ||
        key.contains('payout_received') ||
        key.contains('potongan_marketplace')) {
      return true;
    }
    return false;
  }

  Widget _profitLossMiniMetric(
    String label,
    String value, {
    bool positive = false,
    bool warning = false,
  }) {
    final color = warning
        ? Theme.of(context).colorScheme.error
        : positive
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).textTheme.bodyLarge?.color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: warning
              ? Theme.of(context).colorScheme.error.withOpacity(0.25)
              : Theme.of(context).colorScheme.primary.withOpacity(0.15),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.82),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _profitLossByMarketplaceCard() {
    if (_profitLossByMarketplace.isEmpty) return const SizedBox.shrink();

    Widget marketplaceCard(Map<String, dynamic> row) {
      final marketplace =
          _marketplaceName(_text(row['marketplace'], 'Marketplace'));
      final shop = _text(row['shop_name'] ?? row['account_name'], marketplace);
      final orderCount =
          _num(row['order_count'] ?? row['finance_order_count']).toInt();
      final grossOriginal = _num(row['gross_original'] ?? row['gross_sales'] ?? row['gross_total']);
      final sellerDiscount = _num(row['seller_discount'] ?? 0);
      final omzetPaid = _num(row['omzet_normal_paid'] ?? row['omzet_paid'] ?? (grossOriginal - sellerDiscount.abs()));
      final gross = grossOriginal;

      final payout = _num(row['payout_total'] ??
          row['received_amount'] ??
          row['net_settlement']);
      final hpp = _numFirstNonZero([
        row['paid_hpp_total'],
        row['settled_hpp_total'],
        row['hpp_total'],
        row['total_hpp'],
        row['hpp_cair'],
        row['hpp_settled'],
        row['hpp_amount'],
        row['hpp']
      ]);
      final profit = _num(row['net_profit'] ?? row['profit'] ?? (payout - hpp));
      final margin = payout > 0
          ? _num(row['margin_percent'] ??
              row['net_margin_percent'] ??
              (profit / payout * 100))
          : 0;
      final discount = _numFirstNonZero([
        row['discount_amount'],
        row['voucher_amount'],
        row['discount'],
        row['voucher'],
        row['shopee_discount'],
        row['tiktok_discount'],
        row['seller_discount'],
        row['platform_discount'],
        row['seller_voucher'],
        row['platform_voucher'],
      ]);
      final refund = _numFirstNonZero([
        row['refund_amount'],
        row['return_refund_amount'],
        row['refund'],
        row['retur'],
        row['buyer_refund_amount'],
      ]);
      final adjustment = _numFirstNonZero([
        row['adjustment_amount'],
        row['adjustment'],
        row['koreksi'],
        row['settlement_correction'],
      ]);
      final platformFee = _numFirstNonZero([
        row['platform_fee'],
        row['service_fee'],
        row['biaya_layanan'],
        row['platform_service_fee'],
        row['service_fee_amount'],
      ]);
      final commissionFee = _numFirstNonZero([
        row['commission_fee'],
        row['commission'],
        row['biaya_komisi'],
        row['total_commission'],
        row['commission_fee_amount'],
      ]);
      final affiliateFee = _numFirstNonZero([
        row['affiliate_fee'],
        row['affiliate_commission'],
        row['biaya_afiliasi'],
        row['affiliate_fee_amount'],
      ]);
      final shippingFee = _numFirstNonZero([
        row['shipping_fee'],
        row['ongkir'],
        row['biaya_ongkir'],
        row['shipping_fee_amount'],
      ]);
      final totalFees = _numFirstNonZero([
        row['total_fees'],
        row['fee_total'],
        row['marketplace_fee'],
        row['total_fee'],
      ]);
      final subFees = platformFee + commissionFee + affiliateFee + shippingFee;
      final otherFees =
          (totalFees.abs() - subFees.abs()) > 1.0 ? (totalFees.abs() - subFees.abs()) : 0.0;
      final calculatedPayout = omzetPaid - totalFees.abs() - refund.abs() + adjustment;
      final diff = (calculatedPayout - payout).abs();
      
      final subsidy = _num(row['subsidy_amount'] ??
          row['marketplace_subsidy'] ??
          row['seller_subsidy']);
      final sampleFree = _num(row['sample_order_count'] ??
          row['free_order_count'] ??
          row['gratis_order_count']);
      final payoutMinus = _num(row['sample_negative_payout_total'] ??
          row['negative_payout_total'] ??
          row['minus_payout_total']);
      final auditedFields = const [
        'platform_fee',
        'commission_fee',
        'affiliate_fee',
        'shipping_fee',
        'discount_amount',
        'voucher_amount',
        'refund_amount',
        'return_refund_amount',
        'adjustment_amount',
        'fee_amount',
        'total_fees',
        'subsidy_amount',
        'marketplace_subsidy',
        'seller_subsidy',
        'sample_order_count',
        'free_order_count',
        'gratis_order_count',
      ];
      final hasAuditedBreakdown =
          auditedFields.any((key) => row.containsKey(key));
      final breakdownWidgets = <Widget>[
        if (platformFee.abs() > 0.49)
          _profitLossMiniMetric('Platform fee', _money(platformFee.abs()),
              warning: true),
        if (commissionFee.abs() > 0.49)
          _profitLossMiniMetric('Komisi', _money(commissionFee.abs()),
              warning: true),
        if (affiliateFee.abs() > 0.49)
          _profitLossMiniMetric('Afiliasi', _money(affiliateFee.abs()),
              warning: true),
        if (shippingFee.abs() > 0.49)
          _profitLossMiniMetric('Ongkir', _money(shippingFee.abs()),
              warning: true),
        if (otherFees > 0.49)
          _profitLossMiniMetric('Biaya marketplace lainnya', _money(otherFees),
              warning: true),
        if (discount.abs() > 0.49)
          _profitLossMiniMetric('Voucher / diskon', _money(discount.abs()),
              warning: true),
        if (subsidy.abs() > 0.49)
          _profitLossMiniMetric('Subsidi', _money(subsidy.abs()),
              positive: subsidy > 0, warning: subsidy < 0),
        if (refund.abs() > 0.49)
          _profitLossMiniMetric('Refund / retur', _money(refund.abs()),
              warning: true),
        if (adjustment.abs() > 0.49)
          _profitLossMiniMetric('Koreksi settlement', _money(adjustment),
              warning: adjustment < 0),
        if (payoutMinus.abs() > 0.49)
          _profitLossMiniMetric('Payout minus', _money(payoutMinus.abs()),
              warning: true),
        if (sampleFree > 0)
          _profitLossMiniMetric(
              'Sample / gratis', sampleFree.toStringAsFixed(0),
              warning: true),
      ];

      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
                Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
            width: 0.8,
          ),
          boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$marketplace · $shop',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).textTheme.bodyLarge?.color,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '$orderCount pesanan · periode ${_date(_start)} - ${_date(_end)}',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color:
                    Theme.of(context).colorScheme.onSurface.withOpacity(0.82),
              ),
            ),
            const SizedBox(height: 10),
            // Primary Metrics Grid
            GridView.count(
              crossAxisCount: MediaQuery.of(context).size.width > 600 ? 5 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 2.3,
              children: [
                _profitLossMiniMetric('Omzet', _money(gross), positive: true),
                _profitLossMiniMetric('Payout', _money(payout), positive: true),
                _profitLossMiniMetric('HPP', _money(hpp), warning: hpp > 0),
                _profitLossMiniMetric('Laba', _money(profit),
                    positive: profit >= 0, warning: profit < 0),
                _profitLossMiniMetric(
                    'Margin', '${margin.toStringAsFixed(2)}%'),
              ],
            ),
            const SizedBox(height: 14),
            // Detailed Reconciliation Section
            () {
              Widget reconcileItemRow(String label, double val,
                  {bool bold = false, bool positiveColor = false, bool isDeduction = false}) {
                final clr = positiveColor
                    ? Colors.green
                    : ((val < 0 || isDeduction)
                        ? Colors.redAccent
                        : Theme.of(context).textTheme.bodyLarge?.color);
                final formattedVal = isDeduction
                    ? '- ${_money(val.abs())}'
                    : (val < 0 ? '- ${_money(val.abs())}' : _money(val));
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.82),
                        ),
                      ),
                      Text(
                        formattedVal,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
                          color: clr,
                        ),
                      ),
                    ],
                  ),
                );
              }

              final subFees = platformFee.abs() +
                  commissionFee.abs() +
                  affiliateFee.abs() +
                  shippingFee.abs() +
                  (otherFees > 0 ? otherFees.abs() : _num(row['other_fee']).abs());
              final totalFees = subFees > 0
                  ? subFees
                  : _num(row['biaya'] ?? row['total_deductions'] ?? row['deductions'] ?? (gross - payout)).abs();
              final calculatedPayout = gross -
                  discount.abs() -
                  totalFees.abs() -
                  refund.abs() +
                  adjustment;
              final diff = (calculatedPayout - payout).abs();

              final isExpanded = true;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.04),
                      border: Border.all(
                          color: Theme.of(context)
                              .dividerColor
                              .withOpacity(0.15)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Rincian Rekonsiliasi (Diaudit)',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color:
                                Theme.of(context).textTheme.bodyLarge?.color,
                          ),
                        ),
                        const SizedBox(height: 8),
                        reconcileItemRow('Gross Sales before discount', grossOriginal),
                        reconcileItemRow('Marketplace Voucher / Discount', discount.abs(), isDeduction: true),
                        reconcileItemRow('Customer Paid Omzet Normal', omzetPaid, bold: true),
                        reconcileItemRow('Biaya Komisi / Commission Fee', commissionFee.abs(), isDeduction: true),
                        reconcileItemRow('Biaya Layanan / Platform Fee', platformFee.abs(), isDeduction: true),
                        reconcileItemRow('Biaya Afiliasi / Affiliate Fee', affiliateFee.abs(), isDeduction: true),
                        reconcileItemRow('Biaya Pengiriman / Shipping Fee', shippingFee.abs(), isDeduction: true),
                        reconcileItemRow('Refund / Return Pembeli', refund.abs(), isDeduction: true),
                        reconcileItemRow('Settlement Correction / Gap', adjustment),
                        reconcileItemRow('Net Payout Received', payout, bold: true, positiveColor: true),
                        const SizedBox(height: 6),
                        Divider(height: 1, color: Theme.of(context).dividerColor.withOpacity(0.2)),
                        const SizedBox(height: 6),
                        reconcileItemRow('HPP Settled (COGS Lunas)', _num(row['hpp_settled']), isDeduction: true),
                        reconcileItemRow('Est HPP Belum Payout', _num(row['unpaid_hpp']), isDeduction: true),
                        reconcileItemRow('Marketplace Net Profit & Margin %', profit, bold: true, positiveColor: profit >= 0),
                      ],
                    ),
                  ),
                    const SizedBox(height: 8),
                    // Reconciliation Formula Note
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(0.06),
                        border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(0.2)),
                      ),
                      child: Text(
                        'Note Rekonsiliasi: Omzet Normal (${_money(gross - discount.abs())}) - Biaya (${_money(totalFees.abs())}) - Refund (${_money(refund.abs())}) ${adjustment >= 0 ? '+' : '-'} Koreksi (${_money(adjustment.abs())}) = ${_money(calculatedPayout)} vs Net Payout ${_money(payout)}.' +
                            (diff > 1.0
                                ? ' (Selisih Gap: ${_money(diff)})'
                                : ' (Tersegel Rekonsiliasi Cocok 100%)'),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                );
              }(),
          ],
        ),
      );
    }

    final totalGross = _profitLossByMarketplace.fold<num>(
        0, (sum, row) => sum + _num(row['gross_sales'] ?? row['omzet_total']));
    final totalPayout = _profitLossByMarketplace.fold<num>(
        0,
        (sum, row) =>
            sum + _num(row['payout_total'] ?? row['received_amount']));
    final totalHpp = _profitLossByMarketplace.fold<num>(
        0,
        (sum, row) =>
            sum +
            _numFirstNonZero([
              row['paid_hpp_total'],
              row['settled_hpp_total'],
              row['hpp_total'],
              row['total_hpp'],
              row['hpp_cair'],
              row['hpp_settled'],
              row['hpp_amount'],
              row['hpp']
            ]));
    final totalProfit = _profitLossByMarketplace.fold<num>(
        0,
        (sum, row) =>
            sum +
            _num(row['net_profit'] ??
                row['profit'] ??
                (_num(row['payout_total'] ??
                        row['received_amount'] ??
                        row['net_settlement']) -
                    _numFirstNonZero([
                      row['paid_hpp_total'],
                      row['settled_hpp_total'],
                      row['hpp_total'],
                      row['total_hpp'],
                      row['hpp_cair'],
                      row['hpp_settled'],
                      row['hpp_amount'],
                      row['hpp']
                    ]))));
    final totalMargin = totalPayout > 0 ? (totalProfit / totalPayout) * 100 : 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Breakdown Laba Rugi per Marketplace',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).textTheme.bodyLarge?.color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tampilan kartu. Bukan tabel rekonsiliasi panjang.',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.82),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _profitLossMiniMetric('Total omzet', _money(totalGross),
                  positive: true),
              _profitLossMiniMetric('Total payout', _money(totalPayout),
                  positive: true),
              _profitLossMiniMetric('Total HPP', _money(totalHpp),
                  warning: true),
              _profitLossMiniMetric('Total laba', _money(totalProfit),
                  positive: totalProfit >= 0, warning: totalProfit < 0),
              _profitLossMiniMetric(
                  'Margin total', '${totalMargin.toStringAsFixed(2)}%'),
            ],
          ),
          const SizedBox(height: 12),
          ..._profitLossByMarketplace.map(marketplaceCard),
        ],
      ),
    );
  }

  Widget _profitLossTab() {
    if (!_profitLossLoaded && !_profitLossLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadProfitLossSupplemental());
      });
    }

    final paidSkuTotals = _totalsFromSkuRows(paidOnly: true);
    final summaryGross = _num(_summary['gross_sales'] ??
        _summary['gross_total'] ??
        _summary['gross'] ??
        _summary['omzet_total'] ??
        _summary['omzet']);
    final summaryPayout = _num(_summary['payout_total'] ??
        _summary['payout_amount'] ??
        _summary['payout'] ??
        _summary['received_amount'] ??
        _summary['net_received']);
    final summaryHpp = _numFirstNonZero([
      _summary['hpp_total'],
      _summary['total_hpp'],
      _summary['paid_hpp_total'],
      _summary['settled_hpp_total'],
      _summary['hpp_cair'],
      _summary['hpp_settled'],
      _summary['hpp_amount'],
      _summary['hpp'],
    ]);
    final operational = _num(_summary['operational_cost_total'] ??
        _summary['operational_expense'] ??
        _summary['expense_total']);

    final mktGross = _profitLossByMarketplace.fold<double>(
        0.0, (sum, r) => sum + _num(r['gross_sales'] ?? r['omzet_total'] ?? r['gross_total'] ?? r['gross']));
    final mktPayout = _profitLossByMarketplace.fold<double>(
        0.0, (sum, r) => sum + _num(r['payout_total'] ?? r['payout_amount'] ?? r['received_amount'] ?? r['payout']));
    final mktHpp = _profitLossByMarketplace.fold<double>(
        0.0,
        (sum, r) =>
            sum +
            _numFirstNonZero([
              r['hpp_total'],
              r['total_hpp'],
              r['paid_hpp_total'],
              r['settled_hpp_total'],
              r['hpp_cair'],
              r['hpp_settled'],
              r['hpp_amount'],
              r['hpp'],
            ]));

    final gross = summaryGross > 0 ? summaryGross : (mktGross > 0 ? mktGross : paidSkuTotals['gross']!);
    final payout = summaryPayout > 0 ? summaryPayout : (mktPayout > 0 ? mktPayout : paidSkuTotals['payout']!);
    final hpp = summaryHpp > 0 ? summaryHpp : (mktHpp > 0 ? mktHpp : paidSkuTotals['hpp']!);
    final profit = payout - hpp - operational;
    final margin = payout > 0 ? (profit / payout) * 100 : 0.0;

    final rawProfitRows =
        _profitLoss.isNotEmpty ? _profitLoss : _fallbackProfitLossRows();
    final profitRows = _profitLossByMarketplace.isNotEmpty
        ? rawProfitRows
            .where((row) => !_isGenericSettlementProfitLossRow(row))
            .toList()
        : rawProfitRows;

    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _sectionHeader('Laba Rugi'),
          const SizedBox(height: 8),

          // Show Card Summary First
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
                    Theme.of(context).brightness == Brightness.dark
                        ? 0.25
                        : 0.45),
                width: 0.8,
              ),
              boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ringkasan Laba Rugi',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _profitLossMiniMetric('Total Omzet', _money(gross),
                        positive: true),
                    _profitLossMiniMetric('Total Payout', _money(payout),
                        positive: true),
                    _profitLossMiniMetric('Total HPP', _money(hpp),
                        warning: true),
                    _profitLossMiniMetric('Biaya Ops', _money(operational),
                        warning: true),
                    _profitLossMiniMetric('Estimasi Laba', _money(profit),
                        positive: profit >= 0, warning: profit < 0),
                    _profitLossMiniMetric(
                        'Margin Laba', '${margin.toStringAsFixed(2)}%'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          if (!_profitLossLoaded) ...[
            if (_profitLossLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: FuturisticLoader(
                      message: 'Memuat Rincian Rekonsiliasi...'),
                ),
              )
            else ...[
              if (_profitLossError != null) ...[
                _emptyCard(
                    'Gagal memuat rincian rekonsiliasi: $_profitLossError'),
                const SizedBox(height: 8),
              ],
              _emptyCard(
                  'Ringkasan laba rugi belum tersedia untuk filter ini.'),
            ],
          ] else ...[
            if (_profitLossByMarketplace.isNotEmpty) ...[
              _profitLossByMarketplaceCard(),
              const SizedBox(height: 8),
            ],
            if (profitRows.isEmpty)
              _emptyCard('Belum ada rincian laba rugi pada periode ini.')
            else
              ...profitRows.map((row) {
                final amount = _num(row['amount']);
                return _simpleRowCard(
                  title: _sourceLabel(
                      _text(row['name'] ?? row['label'] ?? row['category'])),
                  subtitle: _text(row['description'], 'Komponen laporan'),
                  trailing: _profitLossValue(row),
                  positive: amount >= 0,
                );
              }),
          ],
        ],
      ),
    );
  }

  Widget _abnormalTab() {
    if (!_abnormalServerLoaded && !_abnormalSearchBusy) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshAbnormalTab(resetPage: true));
      });
    }
    if (_abnormalStatusFilter == 'sample_free' &&
        !_sampleFreeDetailsLoaded &&
        !_sampleFreeDetailsLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadSampleFreeOrdersDetails());
      });
    }
    if (_loading)
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
    final visibleAbnormales = _filteredAbnormales();
    final visibleTotal = _visibleAbnormalTotal();
    final pageMax = (visibleTotal <= 0)
        ? 1
        : ((visibleTotal + _abnormalPageSize - 1) ~/ _abnormalPageSize);
    final startRow =
        visibleTotal <= 0 ? 0 : ((_abnormalPage - 1) * _abnormalPageSize) + 1;
    final endRow =
        (_abnormalPage * _abnormalPageSize).clamp(0, visibleTotal).toInt();

    // Count true refresh-payout datas for the info banner.
    final dataCount = visibleAbnormales.where(_isRefreshPayoutCandidate).length;

    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: () => _refreshAbnormalTab(resetPage: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _sectionHeader('Abnormal Payout & Margin'),
          SizedBox(height: 8),

          // Search bar
          TextField(
            controller: _abnormalSearchController,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface, fontSize: 13),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _refreshAbnormalTab(resetPage: true),
            decoration: InputDecoration(
              hintText: 'Cari resi, order ID, atau SKU',
              prefixIcon: Icon(Icons.search_rounded),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_abnormalSearchController.text.trim().isNotEmpty)
                    IconButton(
                      tooltip: 'Hapus',
                      onPressed: () {
                        _abnormalSearchController.clear();
                        _refreshAbnormalTab(resetPage: true);
                      },
                      icon: Icon(Icons.close_rounded),
                    ),
                  IconButton(
                    tooltip: 'Cari',
                    onPressed: () => _refreshAbnormalTab(resetPage: true),
                    icon: Icon(Icons.manage_search_rounded),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _abnormalStatusOptions().map((value) {
              final selected = _abnormalStatusFilter == value;
              return ChoiceChip(
                label: Text(_abnormalFilterLabel(value)),
                selected: selected,
                onSelected: _abnormalSearchBusy
                    ? null
                    : (_) {
                        setState(() {
                          _abnormalStatusFilter = value;
                          _abnormalPage = 1;
                        });
                        _refreshAbnormalTab(resetPage: true);
                      },
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withOpacity(0.5),
                    width: 0.8,
                  ),
                ),
              );
            }).toList(),
          ),

          // Action buttons row
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _processing || _isDemoSuperAdmin
                      ? null
                      : _autoMarkCancelNoPayoutForPeriod,
                  icon: Icon(Icons.auto_fix_high_rounded, size: 16),
                  label: Text('Tandai batal/unpaid',
                      style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8)),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),

          if (_abnormalSearchBusy ||
              (_abnormalStatusFilter == 'sample_free' &&
                  _sampleFreeDetailsLoading))
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                  child: FuturisticLoader(
                      message: _abnormalSearchBusy
                          ? 'Mencari abnormal...'
                          : 'Memuat detail order sample...')),
            )
          else ...[
            if (_abnormalLoadError != null) ...[
              _emptyCard('Data abnormal belum termuat: $_abnormalLoadError'),
              SizedBox(height: 8),
            ],
            if (_abnormalStatusFilter == 'sample_free' &&
                _sampleFreeDetailsError != null) ...[
              _emptyCard(
                  'Gagal memuat detail sample: $_sampleFreeDetailsError'),
              SizedBox(height: 8),
            ],
            // Info bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withOpacity(
                          Theme.of(context).brightness == Brightness.dark
                              ? 0.25
                              : 0.45),
                  width: 0.8,
                ),
              ),
              child: Text(
                _abnormalStatusFilter == 'sample_free' &&
                        !_sampleFreeDetailsLoaded
                    ? 'Memuat data...'
                    : (_abnormalServerLoaded
                        ? 'Hal $_abnormalPage/$pageMax · $startRow-$endRow dari $visibleTotal · $dataCount perlu cek payout'
                        : 'Belum ada hasil pencarian.'),
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.82),
                    fontWeight: FontWeight.w700),
              ),
            ),
            SizedBox(height: 8),

            if (visibleAbnormales.isEmpty)
              _emptyOkCard('Tidak ada abnormal pada filter/search ini.')
            else
              ...visibleAbnormales.map((row) {
                final refs = _orderRefs(row);
                final count = refs.isNotEmpty
                    ? refs.length
                    : _num(row['detail_order_count']).toInt();
                final orderId = _text(
                    row['order_id'] ??
                        row['external_order_id'] ??
                        row['order_sn'],
                    '-');
                final resi = _text(row['resi'] ?? row['tracking_number'], '-');
                final payout = _num(row['payout_amount'] ??
                    row['payout_total'] ??
                    row['payout']);
                final gross = _num(row['expected_amount'] ??
                    row['gross'] ??
                    row['gross_amount']);
                final hpp = _num(row['hpp'] ?? row['hpp_total']);
                final margin =
                    payout > 0 ? ((payout - hpp) / payout * 100) : 0.0;
                final statusInfo = _abnormalStatusInfo(row);
                final isCandidate = _isRefreshPayoutCandidate(row);
                final sampleFree = _isSampleFreeAbnormalRow(row);

                return _detailCard(
                  title: _text(
                      row['product_name'] ??
                          row['variant_name'] ??
                          row['title'] ??
                          row['sku'] ??
                          row['order_sn'] ??
                          row['order_id'],
                      'Abnormal'),
                  subtitle: _abnormalSubtitle(row),
                  trailing: TextButton.icon(
                    onPressed: () => _showAbnormalSingleDetail(
                      _text(
                        row['product_name'] ??
                            row['variant_name'] ??
                            row['sku'] ??
                            row['title'] ??
                            row['order_sn'] ??
                            row['order_id'],
                        'Detail abnormal',
                      ),
                      row,
                    ),
                    icon: Icon(Icons.receipt_long_rounded, size: 16),
                    label: Text(count > 1 ? 'Detail $count' : 'Detail',
                        style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                  children: [
                    // Status badge
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _abnormalStatusBadge(
                              statusInfo.label, statusInfo.color),
                          if (sampleFree)
                            _abnormalStatusBadge(
                                'Sample/Gratis - keluar dari omzet normal',
                                Colors.amberAccent),
                        ],
                      ),
                    ),
                    _miniMetric('Order ID',
                        count > 1 && orderId == '-' ? '$count order' : orderId),
                    _miniMetric('Resi',
                        resi == '-' || resi.isEmpty ? 'Belum ada resi' : resi),
                    _miniMetric('Marketplace',
                        _marketplaceName(_text(row['marketplace']))),
                    _miniMetric('Status Order',
                        _text(row['order_status'] ?? row['status'], '-'),
                        warning:
                            !statusInfo.isExcluded && !statusInfo.isCancelDone),
                    _miniMetric(
                        'SKU Lokal',
                        _text(
                            row['local_sku'] ?? row['seller_sku'] ?? row['sku'],
                            '-')),
                    _miniMetric(
                        'Varian',
                        _text(
                            row['variant_name'] ??
                                row['marketplace_variant_name'],
                            '-')),
                    _miniMetric('Qty', _num(row['qty']).toStringAsFixed(0)),
                    _miniMetric('Gross', _money(gross)),
                    _miniMetric('Payout', _money(payout), warning: payout < 0),
                    if (hpp > 0) _miniMetric('HPP', _money(hpp)),
                    if (hpp > 0)
                      _miniMetric('Margin', '${margin.toStringAsFixed(1)}%',
                          warning: margin < 0),
                    if (_text(
                            row['abnormal_reason'] ??
                                row['payout_reason'] ??
                                row['message'] ??
                                row['note'],
                            '')
                        .trim()
                        .isNotEmpty)
                      _miniMetric(
                          'Catatan',
                          AppUi.userMessage(_text(
                            row['abnormal_reason'] ??
                                row['payout_reason'] ??
                                row['message'] ??
                                row['note'],
                            '-',
                          )),
                          warning: !statusInfo.isExcluded),

                    // Action buttons
                    if (!statusInfo.isExcluded &&
                        !statusInfo.isCancelDone &&
                        isCandidate)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: const SizedBox.shrink(),
                      ),
                  ],
                );
              }),

            if (_abnormalServerLoaded && visibleTotal > _abnormalPageSize) ...[
              SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _abnormalPage <= 1 || _abnormalSearchBusy
                          ? null
                          : () {
                              setState(() => _abnormalPage -= 1);
                              _refreshAbnormalTab();
                            },
                      icon: Icon(Icons.chevron_left_rounded),
                      label: Text('Prev'),
                    ),
                  ),
                  SizedBox(width: 10),
                  Text('$_abnormalPage / $pageMax',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.82),
                          fontWeight: FontWeight.w800)),
                  SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _abnormalPage >= pageMax || _abnormalSearchBusy
                          ? null
                          : () {
                              setState(() => _abnormalPage += 1);
                              _refreshAbnormalTab();
                            },
                      icon: Icon(Icons.chevron_right_rounded),
                      label: Text('Next'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// Inline status badge widget for abnormal cards.
  Widget _abnormalStatusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: color.withOpacity(0.10),
        border: Border.all(color: color.withOpacity(0.22), width: 0.8),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w800, color: color)),
    );
  }

  //  Reusable UI
  Widget _sectionHeader(String text) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 16,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: AppUi.mutedText(context, 0.90),
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }

  Widget _heroCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required bool positive,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = positive
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Theme.of(context).cardColor,
        border: Border.all(
          color: Theme.of(context)
              .colorScheme
              .outlineVariant
              .withOpacity(isDark ? 0.25 : 0.45),
          width: 0.8,
        ),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withOpacity(isDark ? 0.12 : 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: color.withOpacity(isDark ? 0.22 : 0.14), width: 0.8),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                      fontSize: 12,
                      color: AppUi.mutedText(context, 0.88),
                      fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800, color: color),
                ),
                SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppUi.mutedText(context, 0.88),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricGrid(List<_Metric> metrics) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 900
            ? 3
            : width >= 520
                ? 3
                : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: metrics.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            mainAxisExtent: 82,
          ),
          itemBuilder: (context, index) {
            final metric = metrics[index];
            final isDark = Theme.of(context).brightness == Brightness.dark;

            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(context).cardColor,
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withOpacity(isDark ? 0.25 : 0.45),
                  width: 0.8,
                ),
                boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(isDark ? 0.12 : 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(isDark ? 0.2 : 0.12),
                        width: 0.8,
                      ),
                    ),
                    child: Icon(metric.icon,
                        color: Theme.of(context).colorScheme.primary, size: 19),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          metric.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: AppUi.mutedText(context, 0.88),
                              fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 3),
                        Text(
                          metric.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _emptyCard(String message) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: AppUi.modernCardDecoration(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.82)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: 13,
                  color:
                      Theme.of(context).colorScheme.onSurface.withOpacity(0.82),
                  height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyOkCard(String message) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
        border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.18),
            width: 0.8),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.8)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.9),
                  height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _simpleRowCard({
    required String title,
    required String subtitle,
    required String trailing,
    bool positive = true,
    List<Widget> actions = const <Widget>[],
  }) {
    final color = positive
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).cardColor,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
                SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.82)),
                ),
              ],
            ),
          ),
          SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 148),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  trailing,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 13, color: color),
                ),
                if (actions.isNotEmpty) ...[
                  SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cashWalletInputRowCard(Map<String, dynamic> row) {
    final kind = _text(row['_cash_wallet_kind'], '');
    final amount = _num(row['amount']);
    final positive = amount >= 0;
    final title = _sourceLabel(_text(row['source'] ?? row['category']));
    final subtitleParts = <String>[
      if (kind == 'opening')
        _monthLabel(_parseDate(row['period_month']) ?? _start)
      else
        _date(row['date'] ?? row['created_at']),
      if (kind == 'withdrawal')
        _bankLabel(_text(row['bank_account_name'], ''),
            _text(row['bank_reference'], '')),
      if (kind == 'withdrawal')
        _accountNameById(_text(row['marketplace_account_id'])),
      if (_text(row['note'], '').trim().isNotEmpty) _text(row['note'], ''),
    ].where((item) => item.trim().isNotEmpty && item != '-').toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).cardColor,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
                SizedBox(height: 3),
                Text(
                  subtitleParts.join(' - '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.82)),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                (positive ? '+ ' : '- ') + _money(amount.abs()),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: positive
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
              ),
              SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  _tinyActionButton(Icons.edit_rounded, 'Edit', () {
                    if (kind == 'opening') {
                      _editCashOpeningBalance(row);
                    } else if (kind == 'adjustment') {
                      _editCashAdjustment(row: row);
                    } else if (kind == 'withdrawal') {
                      _editMarketplaceWithdrawal(row);
                    }
                  }),
                  if (kind == 'opening')
                    _tinyActionButton(Icons.restart_alt_rounded, 'Reset',
                        () => _resetCashOpeningBalance(row)),
                  if (kind == 'withdrawal')
                    _tinyActionButton(Icons.account_tree_rounded, 'Alokasi',
                        () => _editWithdrawalAllocation(withdrawal: row)),
                  _tinyActionButton(Icons.delete_outline_rounded, 'Hapus', () {
                    if (kind == 'opening') {
                      _deleteCashOpeningBalance(row);
                    } else if (kind == 'adjustment') {
                      _deleteCashAdjustment(row);
                    } else if (kind == 'withdrawal') {
                      _deleteMarketplaceWithdrawal(row);
                    }
                  }, danger: true),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _withdrawalAllocationRowCard(Map<String, dynamic> row) {
    final parent = _withdrawalById(_text(row['marketplace_withdrawal_id'], ''));
    final bank = parent == null
        ? '-'
        : _bankLabel(_text(parent['bank_account_name'], ''),
            _text(parent['bank_reference'], ''));
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).cardColor,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Alokasi ${_monthLabel(_parseDate(row['source_period_month']) ?? _start)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
                SizedBox(height: 3),
                Text(
                  [
                    bank,
                    _text(row['allocation_method'], 'manual').toUpperCase(),
                    if (_text(row['note'], '').trim().isNotEmpty)
                      _text(row['note'], ''),
                  ]
                      .where((item) => item.trim().isNotEmpty && item != '-')
                      .join(' - '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.82)),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _money(_num(row['amount'])),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.primary),
              ),
              SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  _tinyActionButton(Icons.edit_rounded, 'Edit',
                      () => _editWithdrawalAllocation(row: row)),
                  _tinyActionButton(Icons.delete_outline_rounded, 'Hapus',
                      () => _deleteWithdrawalAllocation(row),
                      danger: true),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _expenseRowCard(Map<String, dynamic> row) {
    String firstUuid(List<dynamic> values) {
      for (final value in values) {
        final clean = _text(value, '').trim();
        if (_isUuid(clean)) return clean;
      }
      return '';
    }

    final realExpenseId = firstUuid([
      row['expense_id'],
      row['finance_operational_expense_id'],
      row['operational_expense_id'],
      row['finance_expense_id'],
      row['manual_expense_id'],
      row['id'],
    ]);
    final editableRow = realExpenseId.isEmpty
        ? row
        : <String, dynamic>{...row, 'expense_id': realExpenseId};
    final canEditExpense = realExpenseId.isNotEmpty &&
        !_isSyntheticExpenseRow(row) &&
        !_isPurchaseExpenseRow(row);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).cardColor,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _text(row['category'], 'Biaya operasional'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
                SizedBox(height: 3),
                Text(
                  '${_date(row['paid_at'] ?? row['expense_date'] ?? row['created_at'])}  ·  ${_text(row['note'], 'Tanpa catatan')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.82)),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 118),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    _money(_num(row['amount'])),
                    maxLines: 1,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.error),
                  ),
                ),
                SizedBox(height: 4),
                if (canEditExpense)
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    children: [
                      _tinyActionButton(Icons.edit_rounded, 'Edit',
                          () => _editManualExpense(editableRow)),
                      _tinyActionButton(Icons.delete_outline_rounded, 'Hapus',
                          () => _deleteManualExpense(editableRow),
                          danger: true),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tinyActionButton(IconData icon, String tooltip, VoidCallback onTap,
      {bool danger = false}) {
    final color = danger
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Material(
      color: color.withOpacity(0.08),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: _processing ? null : onTap,
        borderRadius: BorderRadius.circular(6),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 28,
            height: 26,
            child: Icon(icon, size: 15, color: color),
          ),
        ),
      ),
    );
  }

  Widget _detailCard({
    required String title,
    required String subtitle,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).cardColor,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
              Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.45),
          width: 0.8,
        ),
        boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: 12, color: AppUi.mutedText(context, 0.88)),
          ),
          SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: children),
        ],
      ),
    );
  }

  Future<void> _showAbnormalSingleDetail(
      String title, Map<String, dynamic> row) async {
    final detailRows = <MapEntry<String, String>>[
      MapEntry(
          'Order ID',
          _text(row['order_id'] ?? row['external_order_id'] ?? row['order_sn'],
              '-')),
      MapEntry(
          'Resi',
          _text(
              row['tracking_number'] ?? row['resi'] ?? row['label_code'], '-')),
      MapEntry('Marketplace', _text(row['marketplace'], '-')),
      MapEntry(
          'Toko',
          _text(row['shop_name'] ?? row['account_name'] ?? row['seller_name'],
              '-')),
      MapEntry('Status order', _text(row['order_status'], '-')),
      MapEntry('Status abnormal',
          _text(row['abnormal_status'] ?? row['status'], '-')),
      MapEntry('SKU lokal',
          _text(row['local_sku'] ?? row['sku'] ?? row['sku_key'], '-')),
      MapEntry(
          'Varian',
          _text(row['variant_name'] ?? row['variation_name'] ?? row['sku_name'],
              '-')),
      MapEntry('Qty', _text(row['quantity'] ?? row['qty'], '-')),
      MapEntry(
          'Gross',
          _money(_numAny(row, const [
            'gross_amount',
            'gross_sales',
            'total_amount',
            'amount'
          ]))),
      MapEntry(
          'Payout',
          _money(_numAny(row,
              const ['payout_amount', 'received_amount', 'net_settlement']))),
      MapEntry('Tanggal order',
          _dateTime(row['order_created_at'] ?? row['created_at'])),
      MapEntry('Update order',
          _dateTime(row['order_updated_at'] ?? row['updated_at'])),
      MapEntry(
          'Finance at',
          _dateTime(
              row['finance_at'] ?? row['pulled_at'] ?? row['settlement_date'])),
      MapEntry('Catatan',
          _text(row['note'] ?? row['message'] ?? row['exclusion_reason'], '-')),
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: (Theme.of(context).cardColor),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.86),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Theme.of(context).textTheme.bodyLarge?.color),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: Icon(Icons.close_rounded,
                        color: Theme.of(context).textTheme.bodyLarge?.color),
                  ),
                ],
              ),
              SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: detailRows.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 18, color: Color(0x2238BDF8)),
                  itemBuilder: (context, index) {
                    final item = detailRows[index];
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 118,
                          child: Text(item.key,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.color,
                                  fontWeight: FontWeight.w700)),
                        ),
                        Expanded(
                            child: Text(item.value,
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyLarge
                                        ?.color,
                                    fontWeight: FontWeight.w800))),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  num _skuOrderDetailPayoutValueV82o(Map<String, dynamic> row) {
    return _numFirstNonZero([
      row['payout'],
      row['payout_amount'],
      row['payout_total'],
      row['order_payout'],
      row['received_amount'],
      row['net_received'],
      row['net_settlement'],
      row['settlement_amount'],
      row['paid_amount'],
      row['payout_per_item'],
      row['unit_paid_amount'],
      row['unit_payout_amount'],
    ]);
  }

  num _skuOrderDetailPayoutPerItemValueV82o(Map<String, dynamic> row) {
    return _numFirstNonZero([
      row['payout_per_item'],
      row['unit_paid_amount'],
      row['unit_payout_amount'],
    ]);
  }

  Object? _skuOrderDetailTimestampValueV82o(Map<String, dynamic> row) {
    return row['order_created_at'] ??
        row['created_time'] ??
        row['transaction_time'] ??
        row['paid_at'] ??
        row['created_at'] ??
        row['order_date'] ??
        row['period_start'];
  }

  String _skuDetailOrderStatusV82o(Map<String, dynamic> row) {
    final status = _text(
      row['order_status'] ??
          row['status_order'] ??
          row['live_order_status'] ??
          row['raw_order_status'] ??
          row['status'],
      '',
    ).trim();
    return status.isEmpty || status == '-'
        ? 'Status order belum tersimpan'
        : status;
  }

  bool _skuDetailNeedsMarketplaceRefreshV82o(Map<String, dynamic> row) {
    final payout = _skuOrderDetailPayoutValueV82o(row);
    final status = _skuDetailOrderStatusV82o(row).toUpperCase();
    if (status.isEmpty || status == '-') return false;
    
    // If order is completed or delivered but payout is still 0/negative, we need to refresh.
    if (payout <= 0) {
      return status == 'COMPLETED' || status == 'DELIVERED';
    }
    
    const nonFinal = <String>{
      'AWAITING_SHIPMENT',
      'AWAITING_COLLECTION',
      'IN_TRANSIT',
      'DELIVERED',
      'READY_TO_SHIP',
      'TO_SHIP',
      'TO_PACK',
    };
    return nonFinal.contains(status);
  }

  Widget _skuRefreshWarningBannerV82o(Map<String, dynamic> item) {
    final status = _skuDetailOrderStatusV82o(item);
    final payout = _skuOrderDetailPayoutValueV82o(item);
    final String msg = payout <= 0
        ? 'Status order sudah $status, tetapi payout masih Rp 0. Perlu refresh marketplace.'
        : 'Payout sudah masuk, tetapi status order masih $status. Perlu refresh marketplace.';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withOpacity(0.28), width: 0.8),
      ),
      child: Text(
        msg,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: Colors.orange.shade800,
          height: 1.35,
        ),
      ),
    );
  }

  Map<String, dynamic> _normalizeSkuOrderDetailDisplayRowV82o(
      Map<String, dynamic> row) {
    final copy = Map<String, dynamic>.from(row);

    final preferredOrderDate =
        _text(_skuOrderDetailTimestampValueV82o(copy), '');
    if (preferredOrderDate.trim().isNotEmpty) {
      copy['order_date'] = preferredOrderDate;
    }

    final orderStatus = _skuDetailOrderStatusV82o(copy);
    if (orderStatus.isNotEmpty && orderStatus != '-') {
      copy['order_status'] = orderStatus;
    }

    var payout = _skuOrderDetailPayoutValueV82o(copy);
    final exactItemPayout = _numFirstNonZero([
      copy['exact_item_settlement'],
      copy['exact_item_payout'],
      copy['exact_line_settlement'],
      copy['exact_line_payout'],
    ]);
    final orderPayout = _numFirstNonZero([
      copy['order_payout'],
      copy['order_payout_total'],
      copy['order_settlement_total'],
      copy['order_net_settlement'],
    ]);
    final orderGross = _numFirstNonZero([
      copy['order_line_gross'],
      copy['order_gross_total'],
      copy['order_line_gross_total'],
    ]);
    final lineGross = _numFirstNonZero([
      copy['gross'],
      copy['gross_amount'],
      copy['gross_total'],
    ]);
    if (exactItemPayout != 0) {
      payout = exactItemPayout;
      copy['exact_item_settlement'] = exactItemPayout;
    } else if (orderPayout != 0 &&
        orderGross > 0 &&
        lineGross > 0 &&
        (orderGross - lineGross).abs() <= 0.01) {
      payout = orderPayout;
      copy['single_item_order_payout_exact'] = true;
    }
    copy['payout'] = payout;
    copy['payout_amount'] = payout;

    var payoutPerItem = _skuOrderDetailPayoutPerItemValueV82o(copy);
    final qty = _num(copy['qty'] ?? copy['quantity']);
    if (payoutPerItem == 0 && payout != 0) {
      payoutPerItem = payout / (qty > 0 ? qty : 1.0);
    }
    if (payoutPerItem != 0) {
      copy['payout_per_item'] = payoutPerItem;
    }

    final status = _text(
      copy['payout_status'] ??
          copy['finance_status'] ??
          copy['settlement_status'] ??
          copy['status'],
      '',
    ).toUpperCase();

    if (payout < 0) {
      copy['payout_status'] = 'PAYOUT_MINUS';
      copy['finance_status'] = 'NEGATIVE_PAYOUT';
    } else if (payout > 0) {
      copy['payout_status'] = 'SETTLED';
      copy['finance_status'] = 'SETTLED';
    } else if (status.contains('PENDING') ||
        status.contains('UNPAID') ||
        status.contains('MISSING') ||
        status.trim().isEmpty) {
      copy['payout_status'] = 'PENDING_PAYOUT';
      copy['finance_status'] = 'PENDING_PAYOUT';
    }

    if (_text(copy['order']).trim().isEmpty ||
        _text(copy['order']).trim() == '-') {
      copy['order'] = copy['order_id'] ??
          copy['order_sn'] ??
          copy['external_order_id'] ??
          copy['remote_order_id'];
    }

    if (_text(copy['resi']).trim().isEmpty ||
        _text(copy['resi']).trim() == '-') {
      copy['resi'] = copy['tracking_number'] ??
          copy['tracking_no'] ??
          copy['logistics_tracking_number'] ??
          copy['awb'] ??
          copy['waybill_no'];
    }

    final rawReference = copy['resi'] ??
        copy['tracking_number'] ??
        copy['tracking_no'] ??
        copy['logistics_tracking_number'] ??
        copy['awb'] ??
        copy['waybill_no'] ??
        copy['label_code'] ??
        copy['package_id'];
    final displayTracking =
        _cleanMarketplaceTrackingDisplayTextV82o(rawReference);
    copy['stockout_reference'] = _text(rawReference, '-');
    copy['resi'] = displayTracking;
    copy['tracking_display'] = displayTracking;

    return copy;
  }

  bool _skuDetailHasPayoutV82o(Map<String, dynamic> row) {

    final payout = _skuOrderDetailPayoutValueV82o(row);

    final rawStatus = _text(
      row['status'] ?? row['order_status'],
      '',
    ).toUpperCase();

    final financeStatus = _text(
      row['payout_status'] ?? row['finance_status'] ?? row['settlement_status'],
      '',
    ).toUpperCase();

    final joinedStatus = '$rawStatus $financeStatus';

    if (row['is_returned'] == true ||
        joinedStatus.contains('CANCEL') ||
        joinedStatus.contains('REFUND') ||
        joinedStatus.contains('RETURN') ||
        joinedStatus.contains('BATAL') ||
        joinedStatus.contains('RETUR')) {
      return false;
    }

    if (row.containsKey('has_payout') && row['has_payout'] != null) {
      return row['has_payout'] == true;
    }

    if (payout != 0) return true;

    if (row['positive_payout_exists'] == true) return true;

    return (financeStatus.contains('SETTLED') && !financeStatus.contains('UNSETTLED')) ||
        financeStatus.contains('PAID') ||
        financeStatus.contains('RELEASE') ||
        financeStatus.contains('PAYOUT_MINUS') ||
        financeStatus.contains('NEGATIVE_PAYOUT');
  }

  bool _skuDetailIsPendingPayoutV82o(Map<String, dynamic> row) {
    final payout = _skuOrderDetailPayoutValueV82o(row);

    final rawStatus = _text(
      row['status'] ?? row['order_status'],
      '',
    ).toUpperCase();

    final financeStatus = _text(
      row['payout_status'] ?? row['finance_status'] ?? row['settlement_status'],
      '',
    ).toUpperCase();

    final joinedStatus = '$rawStatus $financeStatus';

    if (row['is_returned'] == true ||
        joinedStatus.contains('CANCEL') ||
        joinedStatus.contains('REFUND') ||
        joinedStatus.contains('RETURN') ||
        joinedStatus.contains('BATAL') ||
        joinedStatus.contains('RETUR')) {
      return false;
    }

    if (row.containsKey('has_payout') && row['has_payout'] != null) {
      return row['has_payout'] == false;
    }

    if (payout != 0) return false;

    if (row['positive_payout_exists'] == true) return false;

    return financeStatus.contains('BELUM') ||
        financeStatus.contains('PENDING') ||
        financeStatus.contains('UNPAID') ||
        financeStatus.contains('MISSING') ||
        financeStatus.contains('UNSETTLED') ||
        financeStatus.trim().isEmpty;
  }

  List<Map<String, dynamic>> _filteredSkuOrderRowsV82o(
      List<Map<String, dynamic>> rows, String payoutFilter) {
    final normalized = rows
        .map(_normalizeSkuOrderDetailDisplayRowV82o)
        .toList(growable: false);
    final deduped = _dedupeSkuDetailRows(normalized);

    if (payoutFilter == 'paid') {
      return deduped.where(_skuDetailHasPayoutV82o).toList();
    }

    if (payoutFilter == 'unpaid') {
      return deduped.where(_skuDetailIsPendingPayoutV82o).toList();
    }

    if (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur') {
      return deduped.where((r) {
        if (r['is_returned'] == true) return true;
        final st = _text(r['settlement_status'], '').toLowerCase();
        if (st.contains('retur') || st.contains('batal')) return true;
        final os = _text(r['status'] ?? r['order_status'], '').toLowerCase();
        return RegExp(r'(cancel|batal|return|refund|rts|gagal|closed)').hasMatch(os);
      }).toList();
    }

    return deduped;
  }

  Widget _buildFeeBreakdownV82o(Map<String, dynamic> item) {
    final qty = _num(item['qty']);
    final divider = qty > 0 ? qty : 1;
    final platformFee = _numAny(item, ['admin_fee', 'platform_fee_item']) / divider;
    final commissionFee = _numAny(item, ['commission_fee', 'commission_fee_item']) / divider;
    final affiliateFee = _numAny(item, ['affiliate_fee', 'affiliate_fee_item']) / divider;
    final shippingFee = _numAny(item, ['shipping_fee', 'shipping_fee_item']) / divider;
    final discount = _numAny(item, ['discount_amount', 'discount_amount_item']) / divider;
    final voucher = _num(item['voucher_amount']) / divider;
    final refund = _numAny(item, ['refund_amount', 'refund_amount_item']) / divider;
    final adjustment = _numAny(item, ['adjustment_amount', 'adjustment_amount_item']) / divider;

    final list = <Widget>[];

    void addIfNonZero(String label, double val) {
      if (val != 0) {
        list.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 10, color: AppUi.mutedText(context, 0.90))),
                Text(_money(val),
                    style: TextStyle(
                        fontSize: 10,
                        color: val < 0 ? Colors.red : Colors.green)),
              ],
            ),
          ),
        );
      }
    }

    addIfNonZero('Admin Fee/item', platformFee);
    addIfNonZero('Komisi/item', commissionFee);
    addIfNonZero('Afiliasi/item', affiliateFee);
    addIfNonZero('Ongkir/item', shippingFee);
    addIfNonZero('Diskon/item', discount);
    addIfNonZero('Voucher/item', voucher);
    addIfNonZero('Refund/item', refund);
    addIfNonZero('Koreksi/item', adjustment);

    if (list.isEmpty) return const SizedBox.shrink();

    final recon = item['reconciliation_status'] as String?;
    final isMismatch = recon == 'MISMATCH';

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.44),
        borderRadius: BorderRadius.circular(12),
        border: Border.fromBorderSide(AppUi.softBorderSide(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Rincian Biaya/Item:',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppUi.mutedText(context, 0.90)),
              ),
              if (recon != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: isMismatch ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    recon,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: isMismatch ? Colors.red : Colors.green,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          ...list,
        ],
      ),
    );
  }

  List<dynamic> _extractSkuOrderDetailRowsV82o(Object? payload) {
    if (payload == null) return <dynamic>[];

    if (payload is String) {
      try {
        return _extractSkuOrderDetailRowsV82o(jsonDecode(payload));
      } catch (_) {
        return <dynamic>[];
      }
    }

    if (payload is List) return payload;

    if (payload is Map) {
      const keys = [
        'rows',
        'data',
        'order_details',
        'details',
        'orders',
        'items',
        'records',
        'result',
        'lines',
      ];

      for (final key in keys) {
        if (!payload.containsKey(key)) continue;
        final rows = _extractSkuOrderDetailRowsV82o(payload[key]);
        if (rows.isNotEmpty) return rows;
      }
    }

    return <dynamic>[];
  }

  int _intFromV82o(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  int _positiveIntV82o(Object? value, int fallback) {
    final parsed = _intFromV82o(value, fallback);
    return parsed > 0 ? parsed : fallback;
  }

  int _skuDetailTotalV82o(Object? payload, int fallback) {
    if (payload is String) {
      try {
        return _skuDetailTotalV82o(jsonDecode(payload), fallback);
      } catch (_) {
        return fallback;
      }
    }
    if (payload is! Map) return fallback;
    final map = Map<String, dynamic>.from(payload);
    final direct = _intFromV82o(
      map['total'] ??
          map['total_count'] ??
          map['filtered_count'] ??
          map['count'] ??
          map['records_total'],
      -1,
    );
    if (direct >= 0) return direct;
    for (final key in const ['pagination', 'meta', 'aggregates']) {
      final nested = map[key];
      if (nested is Map) {
        final nestedTotal = _intFromV82o(
          nested['total'] ?? nested['total_count'] ?? nested['count'],
          -1,
        );
        if (nestedTotal >= 0) return nestedTotal;
      }
    }
    return fallback;
  }

  int _skuDetailPageV82o(Object? payload, int fallback) {
    if (payload is! Map) return fallback;
    final direct =
        _positiveIntV82o(payload['page'] ?? payload['current_page'], fallback);
    if (direct != fallback) return direct;
    final nested = payload['pagination'] ?? payload['meta'];
    if (nested is Map)
      return _positiveIntV82o(
          nested['page'] ?? nested['current_page'], fallback);
    return fallback;
  }

  int _skuDetailPageSizeV82o(Object? payload, int fallback) {
    if (payload is! Map) return fallback;
    final direct = _positiveIntV82o(
        payload['page_size'] ?? payload['per_page'] ?? payload['limit'],
        fallback);
    if (direct != fallback) return direct;
    final nested = payload['pagination'] ?? payload['meta'];
    if (nested is Map)
      return _positiveIntV82o(
          nested['page_size'] ?? nested['per_page'] ?? nested['limit'],
          fallback);
    return fallback;
  }

  int _skuDetailTotalPagesV82o(Object? payload, int total, int pageSize) {
    if (payload is Map) {
      final direct = _positiveIntV82o(
        payload['total_pages'] ?? payload['pages'] ?? payload['last_page'],
        -1,
      );
      if (direct > 0) return direct;
      final nested = payload['pagination'] ?? payload['meta'];
      if (nested is Map) {
        final nestedPages = _positiveIntV82o(
          nested['total_pages'] ?? nested['pages'] ?? nested['last_page'],
          -1,
        );
        if (nestedPages > 0) return nestedPages;
      }
    }
    if (pageSize <= 0) return 1;
    return total <= 0 ? 1 : ((total + pageSize - 1) ~/ pageSize);
  }

  int _minIntV82o(int a, int b) => a < b ? a : b;

  String _skuDetailPageSummaryV82o({
    required int page,
    required int pageSize,
    required int total,
    required int totalPages,
    required int visibleCount,
  }) {
    if (total <= 0 || visibleCount <= 0) {
      return 'Menampilkan 0 dari $total · Hal $page/$totalPages';
    }
    final start = ((page - 1) * pageSize) + 1;
    final end = _minIntV82o(((page - 1) * pageSize) + visibleCount, total);
    return 'Menampilkan $start-$end dari $total · Hal $page/$totalPages';
  }

  String? _marketplaceForAccountId(
    String? accountId, {
    List<Map<String, dynamic>>? accounts,
  }) {
    final id = accountId?.trim().toLowerCase() ?? '';
    if (id.isEmpty) return null;
    final source = accounts ?? _accounts;
    for (final account in source) {
      final accountKey = _accountId(account).toLowerCase();
      if (accountKey != id) continue;
      final normalized = _normalizeMarketplaceFilter(
        _text(
            account['marketplace'] ?? account['platform'] ?? account['channel'],
            ''),
      );
      if (normalized != null && normalized != 'all') return normalized;
    }
    return null;
  }

  String? _marketplaceRpcParam({List<Map<String, dynamic>>? accounts}) {
    final value = _text(_marketplaceParam(), '').trim();
    if (value.isNotEmpty && value.toLowerCase() != 'all') return value;
    final inferred =
        _marketplaceForAccountId(_accountUuidParam(), accounts: accounts);
    if (inferred != null && inferred != 'all') return inferred;
    return null;
  }

  Map<String, String> _skuOrderLookupParamsV82o(Map<String, dynamic> row) {
    String valueOf(dynamic value) => _text(value, '').trim();

    bool isPseudoUnmapped(String value) {
      final clean = value.trim().toLowerCase().replaceAll('_', ' ');
      if (clean.isEmpty || clean == '-' || clean == 'null') return false;
      return clean == 'unmapped' ||
          clean == '__unmapped__' ||
          clean == 'belum mapping' ||
          clean == 'belum ada sku marketplace' ||
          clean == 'produk belum diberi nama' ||
          clean.contains('unmapped') ||
          clean.contains('belum mapping');
    }

    bool sameText(String a, String b) {
      final left = a.trim().toLowerCase();
      final right = b.trim().toLowerCase();
      return left.isNotEmpty && left != '-' && left == right;
    }

    final rowSku = valueOf(row['sku']);
    final title = valueOf(row['title']);
    final localSkuRaw = valueOf(row['local_sku'] ??
        row['product_sku'] ??
        row['local_product_sku'] ??
        row['mapped_local_sku']);
    final marketplaceSkuRaw = valueOf(row['marketplace_sku_id'] ??
        row['marketplace_sku'] ??
        row['marketplace_seller_sku'] ??
        row['seller_sku'] ??
        row['sku_marketplace'] ??
        row['external_sku_id'] ??
        row['remote_sku_id'] ??
        row['sku_id']);
    final marketplaceProductId = valueOf(row['marketplace_product_id']);
    final marketplaceSellerSku = valueOf(
      row['marketplace_seller_sku'] ?? row['seller_sku'],
    );
    final mappingStatus =
        valueOf(row['mapping_status'] ?? row['mapping_label']);
    final rowType = valueOf(row['row_type']);
    final hppStatus = valueOf(row['hpp_status'] ?? row['hpp_label']);
    final productName = valueOf(row['product_name'] ??
        row['marketplace_product_name'] ??
        row['nama_barang']);
    final variantName = valueOf(row['variant_name'] ??
        row['marketplace_variant_name'] ??
        row['marketplace_variation_name']);

    final marketplaceSku =
        isPseudoUnmapped(marketplaceSkuRaw) ? '' : marketplaceSkuRaw;

    final localLooksLikeMarketplaceFallback =
        sameText(localSkuRaw, marketplaceSkuRaw) ||
            sameText(localSkuRaw, marketplaceSellerSku) ||
            sameText(localSkuRaw, rowSku);

    final hppNotMapped = hppStatus.toLowerCase().contains('belum mapping') ||
        hppStatus.toLowerCase().contains('belum map') ||
        (_num(row['hpp_per_item'] ?? row['unit_hpp'] ?? row['hpp']) <= 0 &&
            _num(row['hpp_total'] ?? row['total_hpp'] ?? row['hpp_amount']) <=
                0);

    final missingMarketplaceIdentity = marketplaceProductId.isEmpty &&
        productName.isEmpty &&
        variantName.isEmpty;

    final isUnmappedBucket = rowType == 'unmapped_marketplace_sku' ||
        isPseudoUnmapped(rowSku) ||
        isPseudoUnmapped(title) ||
        isPseudoUnmapped(localSkuRaw) ||
        isPseudoUnmapped(mappingStatus) ||
        (localLooksLikeMarketplaceFallback && missingMarketplaceIdentity);

    if (isUnmappedBucket) {
      final specificMarketplaceKey = marketplaceSku.isNotEmpty
          ? marketplaceSku
          : marketplaceSellerSku.isNotEmpty
              ? marketplaceSellerSku
              : marketplaceProductId;

      return {
        'marketplace_sku': specificMarketplaceKey,
        'local_sku': 'unmapped',
        'fallback_search': [
          'unmapped',
          marketplaceProductId,
          marketplaceSku,
          marketplaceSellerSku,
          productName,
          variantName,
        ].where((part) => part.isNotEmpty && part != '-').join(' '),
      };
    }

    var localSku = isPseudoUnmapped(localSkuRaw) ? '' : localSkuRaw;
    if (localSku.isEmpty &&
        rowSku.isNotEmpty &&
        !isPseudoUnmapped(rowSku) &&
        rowSku != marketplaceSku) {
      localSku = rowSku;
    }

    final fallbackParts = <String>[
      productName,
      variantName,
      marketplaceProductId,
      valueOf(row['marketplace_sku_id']),
      marketplaceSellerSku,
    ].where((part) => part.isNotEmpty && part != '-').toList();

    return {
      'marketplace_sku': marketplaceSku,
      'local_sku': localSku,
      'fallback_search': fallbackParts.join(' ').trim(),
    };
  }

  String _canonicalSkuPayoutFilterV82o(String value) {
    final clean = value.trim().toLowerCase().replaceAll('_', ' ');
    if (clean == 'settled' ||
        clean == 'released' ||
        clean == 'release' ||
        clean == 'payout' ||
        clean == 'paid payout' ||
        clean == 'sudah payout' ||
        clean == 'paid') {
      return 'paid';
    }
    if (clean == 'pending' ||
        clean == 'belum payout' ||
        clean == 'no payout' ||
        clean == 'missing payout' ||
        clean == 'unpaid') {
      return 'unpaid';
    }
    if (clean == 'returned' ||
        clean == 'retur' ||
        clean == 'batal' ||
        clean == 'cancelled' ||
        clean == 'refund') {
      return 'returned';
    }
    return clean.isEmpty ? 'all' : value.trim().toLowerCase();
  }

  String _cleanMarketplaceTrackingDisplayTextV82o(Object? value) {
    final raw = _text(value, '').trim();
    if (raw.isEmpty || raw == '-') return '-';
    final upper = raw.toUpperCase();
    if (upper.startsWith('OFG')) return '-';
    if (RegExp(r'^\\d{16,}$').hasMatch(raw)) return '-';
    return raw;
  }

  Future<Map<String, dynamic>> _fetchSkuOrderDetailsV82oPageForRow(
    Map<String, dynamic> row,
    String payoutFilter, {
    int page = 1,
    int pageSize = _skuDetailPageSize,
    String keyword = '',
  }) async {
    final lookup = _skuOrderLookupParamsV82o(row);
    final marketplaceSku = lookup['marketplace_sku'] ?? '';
    final localSku = lookup['local_sku'] ?? '';
    final fallbackSearch = lookup['fallback_search'] ?? '';
    final searchText = keyword.trim().isNotEmpty
        ? keyword.trim()
        : (marketplaceSku.isEmpty && localSku.isEmpty ? fallbackSearch : '');

    if (marketplaceSku.isEmpty && localSku.isEmpty && searchText.isEmpty) {
      return {
        'rows': <Map<String, dynamic>>[],
        'page': 1,
        'page_size': pageSize,
        'total': 0,
        'total_pages': 1,
      };
    }

    final rpcPayoutFilter = _canonicalSkuPayoutFilterV82o(payoutFilter);
    final rowMarketplace = _text(row['marketplace'], '').trim();
    final rowAccountId = _text(
      row['marketplace_account_id'] ?? row['account_id'],
      '',
    ).trim();
    final detailMarketplace = _marketplaceRpcParam() ??
        (rowMarketplace.isEmpty ? null : rowMarketplace);
    final detailAccountId =
        _accountUuidParam() ?? (_isUuid(rowAccountId) ? rowAccountId : null);

    Future<Map<String, dynamic>> requestDetails({
      required String? marketplaceSkuParam,
      required String? localSkuParam,
      required String? searchParam,
    }) async {
      bool isPseudoUnmapped(String value) {
        final clean = value.trim().toLowerCase().replaceAll('_', ' ');
        if (clean.isEmpty || clean == '-' || clean == 'null') return false;
        return clean == 'unmapped' ||
            clean == '__unmapped__' ||
            clean == 'belum mapping' ||
            clean == 'belum ada sku marketplace' ||
            clean == 'produk belum diberi nama' ||
            clean.contains('unmapped') ||
            clean.contains('belum mapping');
      }

      bool sameText(String a, String b) {
        final left = a.trim().toLowerCase();
        final right = b.trim().toLowerCase();
        return left.isNotEmpty && left != '-' && left == right;
      }

      final String rowType = _text(row['row_type'], '').trim();
      final String title = _text(row['title'], '').trim();
      final String rowSku = _text(row['sku'], '').trim();
      final String localSkuRaw = _text(
              row['local_sku'] ??
                  row['product_sku'] ??
                  row['local_product_sku'] ??
                  row['mapped_local_sku'],
              '')
          .trim();
      final String canonicalLocalSku = _text(
              row['canonical_local_sku'] ??
                  row['canonical_sku'] ??
                  row['local_sku'],
              '')
          .trim();
      final String mappingStatus =
          _text(row['mapping_status'] ?? row['mapping_label'], '').trim();
      final String hppStatus =
          _text(row['hpp_status'] ?? row['hpp_label'], '').trim();
      final String mSkuRaw = _text(
              row['marketplace_sku_id'] ??
                  row['marketplace_sku'] ??
                  row['marketplace_seller_sku'] ??
                  row['seller_sku'] ??
                  row['sku_marketplace'] ??
                  row['external_sku_id'] ??
                  row['remote_sku_id'] ??
                  row['sku_id'],
              '')
          .trim();
      final String mProductId = _text(row['marketplace_product_id'], '').trim();
      final String mSellerSku =
          _text(row['marketplace_seller_sku'] ?? row['seller_sku'], '').trim();
      final String pName = _text(
              row['product_name'] ??
                  row['marketplace_product_name'] ??
                  row['nama_barang'],
              '')
          .trim();
      final String vName = _text(
              row['variant_name'] ??
                  row['marketplace_variant_name'] ??
                  row['marketplace_variation_name'],
              '')
          .trim();

      final bool localLooksLikeMarketplaceFallback =
          sameText(localSkuRaw, mSkuRaw) ||
              sameText(localSkuRaw, mSellerSku) ||
              sameText(localSkuRaw, rowSku);
      final bool missingMarketplaceIdentity =
          mProductId.isEmpty && pName.isEmpty && vName.isEmpty;

      final bool isUnmappedBucket = rowType == 'unmapped_marketplace_sku' ||
          isPseudoUnmapped(rowSku) ||
          isPseudoUnmapped(title) ||
          isPseudoUnmapped(localSkuRaw) ||
          isPseudoUnmapped(mappingStatus) ||
          (localLooksLikeMarketplaceFallback && missingMarketplaceIdentity);

      print('--- TRACE_CLICK_BEFORE_RPC ---');
      print('rowType: $rowType');
      print('title: $title');
      print('rowSku: $rowSku');
      print('localSkuRaw: $localSkuRaw');
      print('canonical_local_sku: $canonicalLocalSku');
      print('mappingStatus: $mappingStatus');
      print('hppStatus: $hppStatus');
      print('isUnmappedBucket: $isUnmappedBucket');
      print('--- RPC_PAYLOAD ---');
      print('p_local_sku: $localSkuParam');
      print('p_marketplace_sku: $marketplaceSkuParam');
      print('p_search: $searchParam');
      print('p_page: $page');
      print('p_limit: $pageSize');
      print('-------------------------------');

      final response = await _client.rpc(
        'finance_sku_order_line_details',
        params: {
          'p_start': _toDateParam(_start),
          'p_end': _toDateParam(_end),
          'p_marketplace': detailMarketplace,
          'p_account_id': detailAccountId,
          'p_marketplace_sku': marketplaceSkuParam,
          'p_local_sku': localSkuParam,
          'p_search': searchParam,
          'p_payout_filter': rpcPayoutFilter,
          'p_page': page,
          'p_page_size': pageSize,
        },
      );

      final rawRows = _extractSkuOrderDetailRowsV82o(response);
      final filteredRows = _filteredSkuOrderRowsV82o(
        rawRows
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
        payoutFilter,
      );
      final rows = _dedupeSkuDetailRows(filteredRows);
      final resolvedPage = _skuDetailPageV82o(response, page);
      final resolvedPageSize = _skuDetailPageSizeV82o(response, pageSize);
      final rawTotal = _skuDetailTotalV82o(response, rows.length);
      final total =
          rows.length < filteredRows.length && rawTotal <= filteredRows.length
              ? rows.length
              : rawTotal;
      final totalPages = _skuDetailTotalPagesV82o(
        response,
        total,
        resolvedPageSize <= 0 ? pageSize : resolvedPageSize,
      );
      return {
        'rows': rows,
        'page': resolvedPage,
        'page_size': resolvedPageSize <= 0 ? pageSize : resolvedPageSize,
        'total': total,
        'total_pages': totalPages,
      };
    }

    var result = await requestDetails(
      marketplaceSkuParam: marketplaceSku.isEmpty ? null : marketplaceSku,
      localSkuParam: localSku.isEmpty || localSku == '-' ? null : localSku,
      searchParam: searchText.isEmpty ? null : searchText,
    );

    final resultRows = result['rows'];
    if (keyword.trim().isEmpty &&
        fallbackSearch.isNotEmpty &&
        (marketplaceSku.isNotEmpty || localSku.isNotEmpty) &&
        resultRows is List &&
        resultRows.isEmpty) {
      result = await requestDetails(
        marketplaceSkuParam: null,
        localSkuParam: null,
        searchParam: fallbackSearch,
      );
    }

    return result;
  }

  Future<List<Map<String, dynamic>>> _fetchSkuOrderDetailsV82oForRow(
      Map<String, dynamic> row, String payoutFilter) async {
    try {
      final result = await _fetchSkuOrderDetailsV82oPageForRow(
        row,
        payoutFilter,
        page: 1,
        pageSize: _skuDetailPageSize,
      );
      final rows = result['rows'];
      if (rows is List<Map<String, dynamic>>) return rows;
      if (rows is List) {
        return rows
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
    } catch (_) {}
    return <Map<String, dynamic>>[];
  }

  String _skuDetailBusyKeyV82o(Map<String, dynamic> row, String payoutFilter) {
    final lookup = _skuOrderLookupParamsV82o(row);
    return [
      payoutFilter,
      lookup['marketplace_sku'] ?? '',
      lookup['local_sku'] ?? '',
      lookup['fallback_search'] ?? '',
    ].join('|');
  }

  Future<void> _showSkuOrderRefsV82o(Map<String, dynamic> row,
      {String payoutFilter = 'all'}) async {
    final busyKey = _skuDetailBusyKeyV82o(row, payoutFilter);
    if (_skuDetailBusyKey != null) return;
    if (mounted) setState(() => _skuDetailBusyKey = busyKey);

    final payoutLabel = payoutFilter == 'paid'
        ? 'sudah ada payout'
        : payoutFilter == 'unpaid'
            ? 'belum ada payout'
            : (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur')
                ? 'retur / batal'
                : 'semua status payout';

    Map<String, dynamic> pageResult;
    try {
      pageResult = await _fetchSkuOrderDetailsV82oPageForRow(
        row,
        payoutFilter,
        page: 1,
        pageSize: _skuDetailPageSize,
      );
    } catch (error) {
      if (mounted && _skuDetailBusyKey == busyKey) {
        setState(() => _skuDetailBusyKey = null);
      }
      _setMessage(
          'Detail order SKU ($payoutLabel) gagal dimuat: ${_cleanError(error)}');
      return;
    }

    var rows = (pageResult['rows'] as List?)
            ?.whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList() ??
        <Map<String, dynamic>>[];
    var page = _positiveIntV82o(pageResult['page'], 1);
    var pageSize =
        _positiveIntV82o(pageResult['page_size'], _skuDetailPageSize);
    var total = _intFromV82o(pageResult['total'], rows.length);
    var totalPages = _positiveIntV82o(pageResult['total_pages'], 1);

    if (payoutFilter == 'unpaid') {
      _skuUnpaidCountMap[busyKey] = total;
    } else if (payoutFilter == 'paid') {
      _skuPaidCountMap[busyKey] = total;
    } else if (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur') {
      _skuReturnedCountMap[busyKey] = total;
    }

    // Ensure detail modal always opens even if rows are empty
    if (rows.isEmpty && total <= 0) {
      // Keep going, do not return early so the modal sheet opens cleanly.
    }

    final detailRow = Map<String, dynamic>.from(row);
    final searchController = TextEditingController();
    var keyword = '';
    var loadingPage = false;
    String? pageError;
    var sheetOpen = true;

    Future<void> loadPage(
      int nextPage,
      String nextKeyword,
      StateSetter setSheetState,
    ) async {
      final cleanKeyword = nextKeyword.trim();
      setSheetState(() {
        loadingPage = true;
        pageError = null;
        keyword = cleanKeyword;
        page = nextPage < 1 ? 1 : nextPage;
      });
      try {
        final result = await _fetchSkuOrderDetailsV82oPageForRow(
          row,
          payoutFilter,
          page: nextPage < 1 ? 1 : nextPage,
          pageSize: _skuDetailPageSize,
          keyword: cleanKeyword,
        );
        if (!sheetOpen) return;
        final nextRows = (result['rows'] as List?)
                ?.whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList() ??
            <Map<String, dynamic>>[];
        setSheetState(() {
          rows = nextRows;
          page = _positiveIntV82o(result['page'], nextPage);
          pageSize = _positiveIntV82o(result['page_size'], _skuDetailPageSize);
          total = _intFromV82o(result['total'], nextRows.length);
          totalPages = _positiveIntV82o(result['total_pages'], 1);
          loadingPage = false;
        });
      } catch (error) {
        if (!sheetOpen) return;
        setSheetState(() {
          pageError = _cleanError(error);
          loadingPage = false;
        });
      }
    }

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
        builder: (sheetContext) {
          return StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              final totalSafe = total < rows.length ? rows.length : total;
              final totalPagesSafe = totalPages <= 0 ? 1 : totalPages;
              final canPrev = !loadingPage && page > 1;
              final canNext = !loadingPage && page < totalPagesSafe;
              final pageSummary = _skuDetailPageSummaryV82o(
                page: page,
                pageSize: pageSize,
                total: totalSafe,
                totalPages: totalPagesSafe,
                visibleCount: rows.length,
              );

              return Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight:
                          MediaQuery.of(sheetContext).size.height * 0.86),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _text(
                                      detailRow['local_sku'] ??
                                          detailRow['sku'],
                                      'Detail SKU'),
                                  style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  '${_text(detailRow['product_name'] ?? detailRow['nama_barang'], 'Produk')} · $pageSummary · $payoutLabel · Deduped by order line/facts',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.96)),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: Icon(Icons.close_rounded,
                                color: Theme.of(context).colorScheme.onSurface),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      TextField(
                        controller: searchController,
                        onChanged: (value) => loadPage(1, value, setSheetState),
                        decoration: InputDecoration(
                          hintText:
                              'Cari nomor pesanan, resi, tanggal, gross, atau payout',
                          prefixIcon: Icon(Icons.search_rounded),
                          suffixIcon: IconButton(
                            tooltip: 'Cari',
                            onPressed: loadingPage
                                ? null
                                : () => loadPage(
                                      1,
                                      searchController.text,
                                      setSheetState,
                                    ),
                            icon: Icon(Icons.search),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              keyword.isEmpty
                                  ? pageSummary
                                  : '$pageSummary · Filter: $keyword',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.96)),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: canPrev
                                ? () => loadPage(
                                      page - 1,
                                      searchController.text,
                                      setSheetState,
                                    )
                                : null,
                            icon: Icon(Icons.chevron_left_rounded),
                            label: Text('Sebelumnya'),
                          ),
                          SizedBox(width: 6),
                          TextButton.icon(
                            onPressed: canNext
                                ? () => loadPage(
                                      page + 1,
                                      searchController.text,
                                      setSheetState,
                                    )
                                : null,
                            icon: Icon(Icons.chevron_right_rounded),
                            label: Text('Berikutnya'),
                          ),
                        ],
                      ),
                      if (pageError != null) ...[
                        SizedBox(height: 8),
                        Text(
                          pageError!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w700),
                        ),
                      ],
                      SizedBox(height: 8),
                      Expanded(
                        child: loadingPage && rows.isEmpty
                            ? const Center(child: CircularProgressIndicator())
                            : rows.isEmpty
                                ? _emptyCard(
                                    'Detail pesanan belum tersedia untuk filter ini.')
                                : Stack(
                                    children: [
                                      ListView.separated(
                                        itemCount: rows.length,
                                        separatorBuilder: (_, __) =>
                                            SizedBox(height: 8),
                                        itemBuilder: (context, index) {
                                          final item = rows[index];
                                          return Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color:
                                                  (Theme.of(context).cardColor),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.22)),
                                            ),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Container(
                                                  width: 38,
                                                  height: 38,
                                                  decoration: BoxDecoration(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                        .withValues(
                                                            alpha: 0.22),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                  ),
                                                  child: Icon(
                                                      Icons
                                                          .receipt_long_rounded,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .primary,
                                                      size: 20),
                                                ),
                                                SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      SelectableText(
                                                        'Order: ${_cleanText(item['order'], 'Belum ada order')}',
                                                        style: TextStyle(
                                                            fontSize: 13.5,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .onSurface
                                                                .withValues(
                                                                    alpha:
                                                                        0.90)),
                                                      ),
                                                      SizedBox(height: 4),
                                                      SelectableText(
                                                        'Resi: ${_cleanText(item['resi'], 'Belum ada resi')}',
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .onSurface
                                                                .withValues(
                                                                    alpha:
                                                                        0.86),
                                                            height: 1.35),
                                                      ),
                                                      SizedBox(height: 4),
                                                      Text(
                                                        'Tanggal pesanan: ${_dateTime(item['order_date'])}',
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .onSurface
                                                                .withValues(
                                                                    alpha:
                                                                        0.86),
                                                            height: 1.35),
                                                      ),
                                                      SizedBox(height: 4),
                                                      Text(
                                                        'Status: ${_skuDetailOrderStatusV82o(item)}  ·  Payout: ${_payoutStatusText(item)}',
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .onSurface
                                                                .withValues(
                                                                    alpha:
                                                                        0.86),
                                                            height: 1.35),
                                                      ),
                                                      if (_skuDetailNeedsMarketplaceRefreshV82o(
                                                          item)) ...[
                                                        SizedBox(height: 6),
                                                        _skuRefreshWarningBannerV82o(
                                                            item),
                                                      ],
                                                      if (_payoutExplainText(
                                                                  item)
                                                              .trim()
                                                              .isNotEmpty ||
                                                          _text(item['resi_reason'],
                                                                  '')
                                                              .trim()
                                                              .isNotEmpty) ...[
                                                        SizedBox(height: 4),
                                                        Text(
                                                          '${_payoutExplainText(item)}${_payoutExplainText(item).trim().isNotEmpty && _text(item['resi_reason'], '').trim().isNotEmpty ? ' · ' : ''}${_text(item['resi_reason'], '')}',
                                                          style: TextStyle(
                                                              fontSize: 11.5,
                                                              color: _linePayoutAmount(
                                                                          item) <
                                                                      0
                                                                  ? Colors
                                                                      .redAccent
                                                                  : Theme.of(
                                                                          context)
                                                                      .colorScheme
                                                                      .secondary,
                                                              height: 1.35),
                                                        ),
                                                      ],
                                                      SizedBox(height: 4),
                                                      Text(
                                                        'ID produk: ${_cleanText(item['marketplace_product_id'], _cleanText(detailRow['marketplace_product_id'], 'Belum ada ID produk'))}  ·  ID SKU: ${_cleanText(item['marketplace_sku_id'] ?? item['marketplace_sku'], _cleanText(detailRow['marketplace_sku_id'] ?? detailRow['marketplace_sku'], 'Belum ada ID SKU'))}  ·  SKU lokal: ${_financeSkuLocalMappingLabel(item, detailRow)}  ·  Seller SKU: ${_cleanText(item['marketplace_seller_sku'], 'Belum ada seller SKU')}  ·  Varian: ${_cleanText(item['variant_name'] ?? item['marketplace_variation_name'], 'Belum ada varian')}',
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .onSurface
                                                                .withValues(
                                                                    alpha:
                                                                        0.86),
                                                            height: 1.35),
                                                      ),
                                                      SizedBox(height: 8),
                                                      Wrap(
                                                        spacing: 6,
                                                        runSpacing: 6,
                                                        children: [
                                                          _miniMetric(
                                                              'Qty',
                                                              _num(item['qty'])
                                                                  .toStringAsFixed(
                                                                      0)),
                                                          _miniMetric(
                                                              'Harga jual/item',
                                                              _skuDetailGrossPerItemText(
                                                                  item)),
                                                          _miniMetric(
                                                              'Payout order marketplace',
                                                              _skuDetailOrderPayoutText(
                                                                  item)),
                                                          _miniMetric(
                                                              _skuDetailPayoutItemLabel(
                                                                  item),
                                                              _skuDetailPayoutItemText(
                                                                  item)),
                                                          _miniMetric(
                                                              'HPP/item',
                                                              _skuDetailHppItemText(
                                                                  item)),
                                                        ],
                                                      ),
                                                      SizedBox(height: 6),
                                                      Text(
                                                        'Settlement: ${_skuDetailSettlementText(item)}',
                                                        style: TextStyle(
                                                            fontSize: 10.5,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .onSurface
                                                                .withValues(
                                                                    alpha:
                                                                        0.86),
                                                            height: 1.3),
                                                      ),
                                                      if (_skuDetailAllocationText(
                                                              item)
                                                          .isNotEmpty) ...[
                                                        SizedBox(height: 4),
                                                        Text(
                                                          _skuDetailAllocationText(
                                                              item),
                                                          style: TextStyle(
                                                              fontSize: 10.5,
                                                              color: Theme.of(
                                                                      context)
                                                                  .colorScheme
                                                                  .onSurface
                                                                  .withValues(
                                                                      alpha:
                                                                          0.86),
                                                              height: 1.3),
                                                        ),
                                                      ],
                                                      _buildFeeBreakdownV82o(
                                                          item),
                                                      SizedBox(height: 8),
                                                      Wrap(
                                                        spacing: 6,
                                                        runSpacing: 6,
                                                        children: [
                                                          _copyFieldButton(
                                                            sheetContext,
                                                            label:
                                                                'Copy Order ID',
                                                            icon: Icons
                                                                .receipt_long_rounded,
                                                            value:
                                                                item['order'],
                                                          ),
                                                          _copyFieldButton(
                                                            sheetContext,
                                                            label: 'Copy Resi',
                                                            icon: Icons
                                                                .local_shipping_rounded,
                                                            value: item['resi'],
                                                          ),
                                                          _copyFieldButton(
                                                            sheetContext,
                                                            label:
                                                                'Copy Settlement',
                                                            icon: Icons
                                                                .payments_rounded,
                                                            value: item[
                                                                    'statement_id'] ??
                                                                item[
                                                                    'settlement_ref'],
                                                          ),
                                                          _copyFieldButton(
                                                            sheetContext,
                                                            label: 'Copy SKU',
                                                            icon: Icons
                                                                .inventory_2_rounded,
                                                            value: item[
                                                                    'local_sku'] ??
                                                                item[
                                                                    'marketplace_sku'] ??
                                                                item[
                                                                    'marketplace_seller_sku'],
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                      if (loadingPage)
                                        Positioned.fill(
                                          child: ColoredBox(
                                            color: Theme.of(context)
                                                .cardColor
                                                .withValues(alpha: 0.22),
                                            child: const Center(
                                                child:
                                                    CircularProgressIndicator()),
                                          ),
                                        ),
                                    ],
                                  ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      sheetOpen = false;
      searchController.dispose();
      if (mounted && _skuDetailBusyKey == busyKey) {
        setState(() => _skuDetailBusyKey = null);
      }
    }
  }

  Future<void> _showSkuOrderRefs(Map<String, dynamic> row,
      {String payoutFilter = 'all'}) async {
    var detailRow = row;
    var allRows =
        _filteredSkuOrderRows(_safeOrderRefRows(detailRow), payoutFilter);
    final isV82oServerDetail =
        _text(detailRow['sku_detail_source'], '') == 'v82o' ||
            allRows.any((item) => _text(item['source'], '').contains(''));

    final needsLazyDetail = !isV82oServerDetail &&
        (allRows.isEmpty ||
            allRows.any((item) =>
                _text(item['resi'], '').trim().isEmpty ||
                _text(item['resi'], '') == '-' ||
                _text(item['variant_name'], '').trim().isEmpty ||
                _text(item['statement_id'], '').trim().isEmpty));
    if (needsLazyDetail) {
      detailRow = await _fetchSkuOrderDetailsForRow(row);
      allRows =
          _filteredSkuOrderRows(_safeOrderRefRows(detailRow), payoutFilter);
    }
    final payoutLabel = payoutFilter == 'paid'
        ? 'sudah ada payout'
        : payoutFilter == 'unpaid'
            ? 'belum ada payout'
            : (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur')
                ? 'retur / batal'
                : 'semua status payout';
    var keyword = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: (Theme.of(context).cardColor),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final filtered = allRows.where((item) {
              final q = keyword.toLowerCase().trim();
              if (q.isEmpty) return true;
              return _text(item['ref'], '').toLowerCase().contains(q) ||
                  _text(item['order'], '').toLowerCase().contains(q) ||
                  _text(item['resi'], '').toLowerCase().contains(q) ||
                  _text(item['order_date'], '').toLowerCase().contains(q) ||
                  _dateTime(item['order_date']).toLowerCase().contains(q) ||
                  _text(item['gross'], '').toLowerCase().contains(q) ||
                  _text(item['payout'], '').toLowerCase().contains(q) ||
                  _text(item['local_sku'], '').toLowerCase().contains(q) ||
                  _text(item['marketplace_sku'], '')
                      .toLowerCase()
                      .contains(q) ||
                  _text(item['marketplace_seller_sku'], '')
                      .toLowerCase()
                      .contains(q) ||
                  _text(item['order_status'], '').toLowerCase().contains(q) ||
                  _text(item['payout_reason'], '').toLowerCase().contains(q) ||
                  _text(item['resi_reason'], '').toLowerCase().contains(q);
            }).toList();

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.86),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _text(
                                    detailRow['local_sku'] ?? detailRow['sku'],
                                    'Detail SKU'),
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '${_text(detailRow['product_name'] ?? detailRow['nama_barang'], 'Produk')} · ${allRows.length} detail order SKU · $payoutLabel',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withOpacity(0.82)),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: Icon(Icons.close_rounded,
                              color: Theme.of(context).colorScheme.onSurface),
                        ),
                      ],
                    ),
                    SizedBox(height: 12),
                    TextField(
                      onChanged: (value) =>
                          setSheetState(() => keyword = value),
                      decoration: const InputDecoration(
                        hintText:
                            'Cari nomor pesanan, resi, tanggal, gross, atau payout',
                        prefixIcon: Icon(Icons.search_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    SizedBox(height: 12),
                    Expanded(
                      child: allRows.isEmpty
                          ? _emptyCard(
                              'Detail pesanan belum tersedia untuk periode ini.')
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final item = filtered[index];
                                return Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).cardColor,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outlineVariant
                                            .withOpacity(
                                                Theme.of(context).brightness ==
                                                        Brightness.dark
                                                    ? 0.25
                                                    : 0.45),
                                        width: 0.8),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withOpacity(0.08),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Icon(Icons.receipt_long_rounded,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            size: 20),
                                      ),
                                      SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            SelectableText(
                                              'Order: ${_cleanText(item['order'], 'Belum ada order')}',
                                              style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.90)),
                                            ),
                                            SizedBox(height: 4),
                                            SelectableText(
                                              'Resi: ${_cleanText(item['resi'], 'Belum ada resi')}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.90),
                                                  height: 1.35),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Tanggal pesanan: ${_dateTime(item['order_date'])}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.90),
                                                  height: 1.35),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Status: ${_skuDetailOrderStatusV82o(item)}  ·  Payout: ${_payoutStatusText(item)}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.90),
                                                  height: 1.35),
                                            ),
                                            if (_payoutExplainText(item)
                                                    .trim()
                                                    .isNotEmpty ||
                                                _text(item['resi_reason'], '')
                                                    .trim()
                                                    .isNotEmpty) ...[
                                              SizedBox(height: 4),
                                              Text(
                                                '${_payoutExplainText(item)}${_payoutExplainText(item).trim().isNotEmpty && _text(item['resi_reason'], '').trim().isNotEmpty ? ' · ' : ''}${_text(item['resi_reason'], '')}',
                                                style: TextStyle(
                                                    fontSize: 11.5,
                                                    color: _linePayoutAmount(
                                                                item) <
                                                            0
                                                        ? Colors.redAccent
                                                        : Theme.of(context)
                                                            .colorScheme
                                                            .secondary,
                                                    height: 1.35),
                                              ),
                                            ],
                                            SizedBox(height: 4),
                                            Text(
                                              'ID produk: ${_cleanText(item['marketplace_product_id'], _cleanText(detailRow['marketplace_product_id'], 'Belum ada ID produk'))}  ·  ID SKU: ${_cleanText(item['marketplace_sku_id'] ?? item['marketplace_sku'], _cleanText(detailRow['marketplace_sku_id'] ?? detailRow['marketplace_sku'], 'Belum ada ID SKU'))}  ·  SKU lokal: ${_financeSkuLocalMappingLabel(item, detailRow)}  ·  Seller SKU: ${_cleanText(item['marketplace_seller_sku'], 'Belum ada seller SKU')}  ·  Varian: ${_cleanText(item['variant_name'] ?? item['marketplace_variation_name'], 'Belum ada varian')}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.90),
                                                  height: 1.35),
                                            ),
                                            SizedBox(height: 8),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: [
                                                _miniMetric(
                                                    'Qty',
                                                    _num(item['qty'])
                                                        .toStringAsFixed(0)),
                                                _miniMetric(
                                                    'Harga jual/item',
                                                    _skuDetailGrossPerItemText(
                                                        item)),
                                                _miniMetric(
                                                    'Payout order marketplace',
                                                    _skuDetailOrderPayoutText(
                                                        item)),
                                                _miniMetric(
                                                    'HPP/item',
                                                    _skuDetailHppItemText(
                                                        item)),
                                              ],
                                            ),
                                            SizedBox(height: 6),
                                            Text(
                                              'Settlement: ${_skuDetailSettlementText(item)}',
                                              style: TextStyle(
                                                  fontSize: 10.5,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.90),
                                                  height: 1.3),
                                            ),
                                            if (_skuDetailAllocationText(item)
                                                .isNotEmpty) ...[
                                              SizedBox(height: 4),
                                              Text(
                                                _skuDetailAllocationText(item),
                                                style: TextStyle(
                                                    fontSize: 10.5,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(
                                                            alpha: 0.90),
                                                    height: 1.3),
                                              ),
                                            ],
                                            _buildFeeBreakdownV82o(item),
                                            SizedBox(height: 8),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: [
                                                _copyFieldButton(
                                                  sheetContext,
                                                  label: 'Copy Order ID',
                                                  icon: Icons
                                                      .receipt_long_rounded,
                                                  value: item['order'],
                                                ),
                                                _copyFieldButton(
                                                  sheetContext,
                                                  label: 'Copy Resi',
                                                  icon: Icons
                                                      .local_shipping_rounded,
                                                  value: item['resi'],
                                                ),
                                                _copyFieldButton(
                                                  sheetContext,
                                                  label: 'Copy Settlement',
                                                  icon: Icons.payments_rounded,
                                                  value: item['statement_id'] ??
                                                      item['settlement_ref'],
                                                ),
                                                _copyFieldButton(
                                                  sheetContext,
                                                  label: 'Copy SKU',
                                                  icon:
                                                      Icons.inventory_2_rounded,
                                                  value: item['local_sku'] ??
                                                      item['marketplace_sku'] ??
                                                      item[
                                                          'marketplace_seller_sku'],
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _miniMetric(String label, String value, {bool warning = false}) {
    final color = warning
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.15), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
                fontSize: 10,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.90),
                fontWeight: FontWeight.w500),
          ),
          SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: warning ? color : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _copyFieldButton(
    BuildContext targetContext, {
    required String label,
    required IconData icon,
    required dynamic value,
  }) {
    final clean = _cleanText(value, '');
    final enabled = clean.isNotEmpty;
    final scheme = Theme.of(targetContext).colorScheme;
    final foreground = enabled
        ? scheme.primary
        : Theme.of(targetContext).disabledColor.withValues(alpha: 0.75);
    return Tooltip(
      message: enabled ? label : '$label belum tersedia',
      child: InkWell(
        onTap: enabled
            ? () {
                Clipboard.setData(ClipboardData(text: clean));
                ScaffoldMessenger.of(targetContext).showSnackBar(
                  SnackBar(content: Text('$label disalin.')),
                );
              }
            : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: enabled
                ? scheme.primary.withValues(alpha: 0.08)
                : Theme.of(targetContext).disabledColor.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: enabled
                  ? scheme.primary.withValues(alpha: 0.28)
                  : Theme.of(targetContext)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: 0.45),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: foreground),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Theme.of(context).cardColor,
            border: Border.all(
                color: Theme.of(context).colorScheme.error.withOpacity(0.25),
                width: 0.8),
            boxShadow: AppTheme.softShadow(Theme.of(context).brightness),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color:
                          Theme.of(context).colorScheme.error.withOpacity(0.18),
                      width: 0.8),
                ),
                child: Icon(Icons.error_outline_rounded,
                    size: 28, color: Theme.of(context).colorScheme.error),
              ),
              SizedBox(height: 16),
              Text(
                'Laporan gagal dimuat',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurface),
              ),
              SizedBox(height: 8),
              Text(
                _error ?? '-',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.82),
                    height: 1.5),
              ),
              SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _load,
                icon: Icon(Icons.refresh_rounded, size: 18),
                label: Text('Coba Lagi'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  CellValue _excelCell(dynamic value) {
    if (value == null) return TextCellValue('');
    if (value is DateTime) return TextCellValue(value.toIso8601String());
    return TextCellValue(value.toString());
  }

  void _appendKeyValueSheet(
      Excel workbook, String sheetName, Map<String, dynamic> data) {
    final sheet = workbook[_safeSheetName(sheetName)];
    sheet.appendRow(<CellValue>[TextCellValue('key'), TextCellValue('value')]);
    if (data.isEmpty) {
      sheet.appendRow(<CellValue>[TextCellValue('empty'), TextCellValue('')]);
      return;
    }
    for (final entry in data.entries) {
      sheet.appendRow(
          <CellValue>[TextCellValue(entry.key), _excelCell(entry.value)]);
    }
  }

  void _appendMapSheet(
      Excel workbook, String sheetName, List<Map<String, dynamic>> rows) {
    final sheet = workbook[_safeSheetName(sheetName)];
    final headers = <String>[];
    for (final row in rows) {
      for (final key in row.keys) {
        if (!headers.contains(key)) headers.add(key);
      }
    }

    if (headers.isEmpty) {
      sheet.appendRow(<CellValue>[TextCellValue('empty')]);
      return;
    }

    sheet.appendRow(
        headers.map<CellValue>((header) => TextCellValue(header)).toList());
    for (final row in rows) {
      sheet.appendRow(
          headers.map<CellValue>((header) => _excelCell(row[header])).toList());
    }
  }

  String _safeSheetName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/*?:\[\]]'), '_');
    return cleaned.length > 31 ? cleaned.substring(0, 31) : cleaned;
  }

  //  Utilities
  bool _looksLikeAllMarketplaceFilter(String? value) {
    final raw = (value ?? '').trim().toLowerCase();
    final text = raw.replaceAll(RegExp(r'[\s\-]+'), '_');
    if (raw.isEmpty) return true;
    if (text == 'all' ||
        text == 'semua' ||
        text == 'semua_platform' ||
        text == 'semua_marketplace') return true;
    if (text == 'all_platform' ||
        text == 'all_platforms' ||
        text == 'all_marketplace' ||
        text == 'all_marketplaces') return true;
    return raw.contains('semua') &&
        (raw.contains('platform') ||
            raw.contains('marketplace') ||
            raw.contains('toko'));
  }

  String? _normalizeMarketplaceFilter(String? value) {
    final raw = (value ?? '').trim().toLowerCase();
    final text = raw.replaceAll(RegExp(r'[\s\-]+'), '_');
    if (_looksLikeAllMarketplaceFilter(value)) return 'all';
    if (text == 'tiktok' || text == 'tiktokshop' || text == 'tiktok_shop')
      return 'tiktok_shop';
    if (text == 'shopee' || text == 'shopee_shop') return 'shopee';
    return text;
  }

  String? _marketplaceParam() {
    final normalized = _normalizeMarketplaceFilter(_marketplaceFilter);
    if (normalized == null ||
        normalized == 'all' ||
        _looksLikeAllMarketplaceFilter(normalized)) return null;
    return normalized;
  }

  Future<List<Map<String, dynamic>>> _fetchMarketplaceAccounts() async {
    if (_currentTenantId.trim().isEmpty) return <Map<String, dynamic>>[];
    final marketplace = _marketplaceParam();

    try {
      final response = await _client.rpc(
        'marketplace_list_active_accounts_for_filter',
        params: {'p_marketplace': marketplace},
      );
      if (response is List) {
        return response
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
      }
    } catch (_) {
      // Fallback ke view lama supaya app tetap jalan kalau SQL patch belum di-apply.
    }

    try {
      dynamic query = _client
          .from('marketplace_accounts_public')
          .select(
              'marketplace_account_id, tenant_id, marketplace, store_alias, shop_name, status, updated_at, connected_at, reauthorized_at')
          .eq('tenant_id', _currentTenantId);
      if (marketplace != null) query = query.eq('marketplace', marketplace);
      final response = await query
          .order('updated_at', ascending: false)
          .range(0, 199) as List<dynamic>;
      return response
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) {
        final status = _text(row['status']).toLowerCase();
        return status != 'deleted' &&
            status != 'revoked' &&
            status != 'inactive_deleted';
      }).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  List<Map<String, dynamic>> _mergeAccounts(
    List<Map<String, dynamic>> primary,
    List<Map<String, dynamic>> fallback,
  ) {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};

    void add(Map<String, dynamic> row) {
      final id = _accountId(row);
      if (!_isUuid(id) || seen.contains(id)) return;
      final copy = Map<String, dynamic>.from(row);
      copy['marketplace_account_id'] = id;
      copy['store_label'] = _text(
        copy['store_label'] ??
            copy['store_alias'] ??
            copy['shop_name'] ??
            copy['seller_name'],
        id,
      );
      result.add(copy);
      seen.add(id);
    }

    for (final row in primary) add(row);
    for (final row in fallback) add(row);
    result.sort((a, b) {
      final left =
          '${_text(a['marketplace'])} ${_text(a['store_label'] ?? a['shop_name'])}'
              .toLowerCase();
      final right =
          '${_text(b['marketplace'])} ${_text(b['store_label'] ?? b['shop_name'])}'
              .toLowerCase();
      return left.compareTo(right);
    });
    return result;
  }

  String _expenseId(Map<String, dynamic> row) {
    final datas = [
      row['expense_id'],
      row['adjustment_id'],
      row['cash_adjustment_id'],
      row['finance_operational_expense_id'],
      row['operational_expense_id'],
      row['finance_expense_id'],
      row['manual_expense_id'],
      row['id'],
    ];
    for (final value in datas) {
      final text = value?.toString().trim() ?? '';
      if (_isUuid(text)) return text;
    }
    return '';
  }

  bool _isCashAdjustmentExpenseRow(Map<String, dynamic> row) {
    final haystack = [
      row['source'],
      row['source_table'],
      row['source_module'],
      row['type'],
    ].map((value) => _text(value, '').toLowerCase()).join(' ');
    return haystack.contains('finance_company_cash_adjustments') ||
        haystack.contains('cash_adjustment') ||
        row.containsKey('cash_adjustment_id') ||
        row.containsKey('adjustment_id');
  }

  bool _isEditableOperationalExpenseRow(Map<String, dynamic> row) {
    if (_isSyntheticExpenseRow(row) ||
        _isPurchaseExpenseRow(row) ||
        _isCashAdjustmentExpenseRow(row)) {
      return false;
    }
    final targetId = _firstStableText([
      row['expense_id'],
      row['finance_operational_expense_id'],
      row['operational_expense_id'],
      row['finance_expense_id'],
      row['manual_expense_id'],
    ]);
    if (!_isUuid(targetId)) return false;
    if (targetId.startsWith('prod_progress_') ||
        targetId.startsWith('prod_stage_') ||
        targetId.startsWith('summary_')) {
      return false;
    }
    return true;
  }

  String _expenseSourceLabel(Map<String, dynamic> row) {
    final explicit = _text(row['source_label'], '').trim();
    if (explicit.isNotEmpty && explicit != '-') return explicit;
    final haystack = [
      row['source'],
      row['source_table'],
      row['source_module'],
      row['type'],
      row['category'],
      row['title'],
      row['label'],
    ].map((value) => _text(value, '').toLowerCase()).join(' ');
    if (_isCashAdjustmentExpenseRow(row) || haystack.contains('kas keluar')) {
      return 'Kas keluar manual';
    }
    if (_isProductionPaymentExpenseRow(row)) {
      return 'Ongkos produksi terbayar';
    }
    if (haystack.contains('purchase') || haystack.contains('pembelian')) {
      return 'Pembelian disetujui';
    }
    if (haystack.contains('finance_operational_expenses') ||
        haystack.contains('operational') ||
        haystack.contains('operasional')) {
      return 'Biaya operasional disetujui';
    }
    return _sourceLabel(_text(row['source'] ?? row['category'], 'Data'));
  }

  String _skuDetailStableLineKey(Map<String, dynamic> row) {
    String cleanPart(dynamic value) {
      final text = _cleanText(value, '').trim();
      if (text == '-' || text.toLowerCase() == 'null') return '';
      return text.toLowerCase();
    }

    String firstPart(List<String> keys) {
      for (final key in keys) {
        final value = cleanPart(row[key]);
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    final orderId = firstPart(const [
      'order',
      'order_sn',
      'external_order_id',
      'remote_order_id',
      'order_id',
    ]);
    final externalLineId = firstPart(const [
      'external_order_item_id',
      'platform_order_item_id',
      'remote_order_item_id',
      'line_item_id',
      'line_id',
    ]);

    final resi = firstPart(const [
      'resi',
      'tracking_number',
      'tracking_no',
      'logistics_tracking_number',
      'awb',
      'waybill_no',
    ]);
    final settlement = firstPart(const [
      'statement_id',
      'settlement_ref',
      'settlement_id',
      'statement_ref',
    ]);
    final sku = firstPart(const [
      'local_sku',
      'sku',
      'marketplace_sku_id',
      'marketplace_sku',
      'marketplace_seller_sku',
    ]);
    final variant = firstPart(const [
      'variant_name',
      'marketplace_variation_name',
      'product_name',
      'title',
    ]);
    final qty = _num(row['qty'] ?? row['quantity']).toStringAsFixed(4);
    final gross = _num(row['gross'] ?? row['gross_amount']).toStringAsFixed(2);
    final payout =
        _num(row['payout'] ?? row['payout_amount']).toStringAsFixed(2);
    final hpp = _num(row['hpp_item'] ?? row['hpp']).toStringAsFixed(2);
    final facts = [
      'facts',
      orderId,
      resi,
      settlement,
      sku,
      variant,
      qty,
      gross,
      payout,
      hpp,
    ].join('|');
    if ('$orderId$resi$settlement$sku$variant'.isNotEmpty) return facts;
    if (orderId.isNotEmpty && externalLineId.isNotEmpty) {
      return 'line|$orderId|$externalLineId';
    }
    return 'row|${identityHashCode(row)}';
  }

  Map<String, dynamic> _preferSkuDetailRow(
    Map<String, dynamic> existing,
    Map<String, dynamic> incoming,
  ) {
    final copy = Map<String, dynamic>.from(existing);
    final existingHasPayout =
        _hasReleasedPayout(copy) || _skuDetailHasPayoutV82o(copy);
    final incomingHasPayout =
        _hasReleasedPayout(incoming) || _skuDetailHasPayoutV82o(incoming);
    if (!existingHasPayout && incomingHasPayout) {
      copy.addAll(incoming);
      return copy;
    }

    for (final entry in incoming.entries) {
      final currentText = _text(copy[entry.key], '').trim();
      final nextText = _text(entry.value, '').trim();
      if ((currentText.isEmpty || currentText == '-') &&
          nextText.isNotEmpty &&
          nextText != '-') {
        copy[entry.key] = entry.value;
      }
    }

    for (final key in const [
      'qty',
      'quantity',
      'gross',
      'gross_amount',
      'payout',
      'payout_amount',
      'hpp',
      'hpp_amount',
      'hpp_item',
      'platform_fee_item',
      'commission_fee_item',
      'affiliate_fee_item',
      'shipping_fee_item',
      'discount_amount_item',
      'refund_amount_item',
      'adjustment_amount_item',
    ]) {
      if (_num(copy[key]) == 0 && _num(incoming[key]) != 0) {
        copy[key] = incoming[key];
      }
    }
    return copy;
  }

  List<Map<String, dynamic>> _dedupeSkuDetailRows(
      List<Map<String, dynamic>> rows) {
    final out = <Map<String, dynamic>>[];
    final byKey = <String, int>{};
    for (final row in rows) {
      final key = _skuDetailStableLineKey(row);
      final index = byKey[key];
      if (index == null) {
        byKey[key] = out.length;
        out.add(Map<String, dynamic>.from(row));
      } else {
        out[index] = _preferSkuDetailRow(out[index], row);
      }
    }
    return out;
  }

  String _summaryBreakdownText(dynamic value, {int limit = 8}) {
    final map = _asMap(value);
    if (map.isEmpty) return '';
    final entries = map.entries
        .map(
            (entry) => MapEntry(_text(entry.key, '').trim(), _num(entry.value)))
        .where((entry) => entry.key.isNotEmpty && entry.value > 0)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return '';
    return entries
        .take(limit)
        .map((entry) =>
            '${entry.key}: ${entry.value.toStringAsFixed(entry.value % 1 == 0 ? 0 : 2)}')
        .join('  ·  ');
  }

  Future<void> _refreshExpenseCategories() async {
    try {
      final response =
          await _client.rpc('finance_list_operational_expense_categories');
      final options = <String>[];
      if (response is List) {
        for (final item in response) {
          if (item is Map) {
            final value = _text(item['category'], '').trim();
            if (value.isNotEmpty &&
                !options.any((e) => e.toLowerCase() == value.toLowerCase()))
              options.add(value);
          } else {
            final value = item.toString().trim();
            if (value.isNotEmpty &&
                !options.any((e) => e.toLowerCase() == value.toLowerCase()))
              options.add(value);
          }
        }
      }
      if (!mounted) return;
      setState(() => _expenseCategoryOptions =
          _mergeExpenseCategories(_expenses, extra: options));
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _expenseCategoryOptions = _mergeExpenseCategories(_expenses));
    }
  }

  List<String> _mergeExpenseCategories(List<Map<String, dynamic>> rows,
      {List<String> extra = const []}) {
    final merged = <String>[];
    void add(String value) {
      final clean = value.trim();
      if (clean.isEmpty || clean == '-') return;
      if (!merged.any((item) => item.toLowerCase() == clean.toLowerCase()))
        merged.add(clean);
    }

    for (final item in _baseExpenseCategories) add(item);
    for (final item in extra) add(item);
    for (final row in rows) add(_text(row['category'], ''));
    return merged;
  }

  List<String> _orderRefs(Map<String, dynamic> row,
      {String payoutFilter = 'all'}) {
    return _filteredSkuOrderRows(_safeOrderRefRows(row), payoutFilter)
        .map(_orderRefLine)
        .where((item) => item.trim().isNotEmpty && item.trim() != '-')
        .toList();
  }

  List<Map<String, dynamic>> _filteredSkuOrderRows(
      List<Map<String, dynamic>> rows, String payoutFilter) {
    bool isCancelRefundReturn(Map<String, dynamic> item) {
      if (item['is_returned'] == true) return true;
      final status = _text(
        item['status'] ??
            item['order_status'] ??
            item['payout_status'] ??
            item['settlement_status'] ??
            item['finance_status'] ??
            item['abnormal_status'],
        '',
      ).toUpperCase();

      return status.contains('CANCEL') ||
          status.contains('REFUND') ||
          status.contains('RETURN') ||
          status.contains('BATAL') ||
          status.contains('RETUR');
    }

    final deduped = _dedupeSkuDetailRows(rows);

    if (payoutFilter == 'paid') {
      return deduped
          .where(
              (item) => !isCancelRefundReturn(item) && _hasReleasedPayout(item))
          .toList();
    }

    if (payoutFilter == 'unpaid') {
      return deduped
          .where((item) =>
              !isCancelRefundReturn(item) && !_hasReleasedPayout(item))
          .toList();
    }

    if (payoutFilter == 'returned' || payoutFilter == 'batal' || payoutFilter == 'retur') {
      return deduped.where(isCancelRefundReturn).toList();
    }

    return deduped;
  }

  String _orderRefLine(Map<String, dynamic> item) {
    final ref = _text(item['ref'], '');
    final payout = _linePayoutAmount(item);
    final gross = _num(item['gross']);
    final parts = <String>[ref];
    if (gross > 0) parts.add('Gross ${_money(gross)}');
    if (_hasReleasedPayout(item)) {
      parts.add('Payout ${_money(payout)}');
    } else {
      parts.add('Payout belum ada');
    }
    return parts
        .where((part) => part.trim().isNotEmpty && part.trim() != '-')
        .join(' · ');
  }

  List<Map<String, dynamic>> _safeOrderRefRows(Map<String, dynamic> row) {
    final rows = _orderRefRows(row);
    return _detailRowsLookAggregated(row, rows)
        ? <Map<String, dynamic>>[]
        : rows;
  }

  bool _detailRowsLookAggregated(
      Map<String, dynamic> parent, List<Map<String, dynamic>> rows) {
    if (rows.length <= 1) return false;

    final parentPayout = _numFirstNonZero([
      parent['payout_total'],
      parent['payout_amount'],
      parent['received_amount'],
      parent['net_received'],
      parent['net_settlement'],
      parent['payout'],
    ]);
    if (parentPayout > 0) {
      var repeatedPayout = 0;
      for (final row in rows) {
        final linePayout = _numFirstNonZero([
          row['payout'],
          row['payout_amount'],
          row['payout_total'],
          row['received_amount'],
          row['net_received'],
          row['net_settlement'],
        ]);
        if ((linePayout - parentPayout).abs() < 0.01) repeatedPayout += 1;
      }
      if (repeatedPayout >= 2) return true;
    }

    final parentQty = _numFirstNonZero([
      parent['settled_qty'],
      parent['paid_qty'],
      parent['qty_settled'],
      parent['paid_qty_total'],
      parent['qty_total'],
      parent['qty'],
      parent['quantity'],
    ]);
    if (parentQty > 1) {
      var repeatedQty = 0;
      for (final row in rows) {
        final lineQty = _numFirstNonZero([
          row['qty'],
          row['quantity'],
          row['settled_qty'],
          row['paid_qty'],
          row['qty_total'],
        ]);
        if (lineQty >= parentQty) repeatedQty += 1;
      }
      if (repeatedQty >= 2) return true;
    }

    return false;
  }

  List<Map<String, dynamic>> _orderRefRows(Map<String, dynamic> row) {
    final direct = row['order_details'] ?? row['orders'] ?? row['order_refs'];
    final rows = <Map<String, dynamic>>[];
    final seen = <String>{};

    void add({
      required String order,
      required String resi,
      dynamic orderDate,
      dynamic qty,
      dynamic gross,
      dynamic payout,
      dynamic hpp,
      dynamic hppPerItem,
      dynamic grossPerItem,
      dynamic payoutPerItem,
      dynamic source,
      dynamic localSku,
      dynamic marketplaceSku,
      dynamic marketplaceSellerSku,
      dynamic statementId,
      dynamic orderStatus,
      dynamic payoutStatus,
      dynamic payoutReason,
      dynamic rawPayoutComponents,
      dynamic negativePayoutReason,
      dynamic resiReason,
      dynamic variantName,
    }) {
      var cleanOrder = order.trim();
      final rawResi = resi.trim();
      final cleanResi =
          rawResi.isEmpty || rawResi == '-' || rawResi == cleanOrder
              ? '-'
              : rawResi;
      if (cleanOrder.isEmpty || cleanOrder == '-') {
        cleanOrder =
            _text(payoutStatus, '').toLowerCase().contains('pending') ||
                    _text(source, '').toLowerCase().contains('pending')
                ? 'Belum ada order ID'
                : '-';
      }
      final ref = cleanResi == '-' ? cleanOrder : '$cleanOrder / $cleanResi';
      if (ref.trim().isEmpty || ref == '-') return;
      final key = '$ref|${_dateTime(orderDate)}|${_num(gross)}|${_num(payout)}'
          .toLowerCase();
      if (seen.contains(key)) return;
      final qtyNum = _num(qty) > 0 ? _num(qty) : 1.0;
      final grossNum = _num(gross);
      final grossPerItemNum = _num(grossPerItem) > 0
          ? _num(grossPerItem)
          : (qtyNum > 0 ? grossNum / qtyNum : grossNum);
      final hppPerItemNum = _normalizeHppPerItemValue(
        hppPerItemRaw: _num(hppPerItem),
        hppTotalRaw: _num(hpp),
        qty: qtyNum,
        grossPerItem: grossPerItemNum,
      );
      rows.add({
        'order': cleanOrder.isEmpty ? '-' : cleanOrder,
        'resi': cleanResi.isEmpty ? '-' : cleanResi,
        'order_date': orderDate,
        'qty': qtyNum,
        'gross': grossNum,
        'payout': _num(payout),
        'hpp': hppPerItemNum > 0 ? hppPerItemNum * qtyNum : _num(hpp),
        'hpp_per_item': hppPerItemNum,
        'gross_per_item': grossPerItemNum,
        'payout_per_item': _num(payoutPerItem) > 0
            ? _num(payoutPerItem)
            : (qtyNum > 0 ? _num(payout) / qtyNum : _num(payout)),
        'source': _text(source, '-'),
        'local_sku': _text(localSku, ''),
        'marketplace_sku': _text(marketplaceSku, ''),
        'marketplace_seller_sku': _text(marketplaceSellerSku, ''),
        'statement_id': _text(statementId, ''),
        'order_status': _text(orderStatus, ''),
        'payout_status': _text(payoutStatus, ''),
        'payout_reason': _text(payoutReason, ''),
        'raw_payout_components': _text(rawPayoutComponents, ''),
        'negative_payout_reason': _text(negativePayoutReason, ''),
        'resi_reason': _text(resiReason, ''),
        'variant_name': _text(variantName, ''),
        'ref': ref,
      });
      seen.add(key);
    }

    if (direct is List) {
      for (final item in direct) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final order = _text(
              map['order'] ??
                  map['order_sn'] ??
                  map['external_order_id'] ??
                  map['remote_order_id'] ??
                  map['order_id'],
              '');
          final resi = _text(
              map['tracking_number'] ??
                  map['tracking_no'] ??
                  map['logistics_tracking_number'] ??
                  map['tracking_number_from_settlement'] ??
                  map['awb_number'] ??
                  map['awb'] ??
                  map['waybill_no'] ??
                  map['resi'] ??
                  map['shipping_tracking_number'],
              '');
          final payout = _num(
            map['payout'] ??
                map['payout_amount'] ??
                map['payout_total'] ??
                map['received_amount'] ??
                map['net_received'] ??
                map['net_settlement'] ??
                map['settlement_amount'] ??
                map['paid_amount'],
          );
          add(
            order: order,
            resi: resi == order ? '-' : resi,
            orderDate: map['order_date'] ??
                map['order_created_at'] ??
                map['transaction_time'] ??
                map['created_at'],
            qty: map['qty'] ?? map['quantity'] ?? 1,
            gross: map['gross'] ??
                map['gross_amount'] ??
                map['gross_sales'] ??
                map['gross_total'] ??
                map['expected_amount'] ??
                map['item_gross_amount'],
            payout: payout,
            hpp: map['hpp_total'] ??
                map['hpp_amount'] ??
                map['total_hpp'] ??
                map['hpp'],
            hppPerItem:
                map['hpp_per_item'] ?? map['unit_hpp'] ?? map['hpp_unit'],
            grossPerItem: map['gross_per_item'] ?? map['unit_gross_amount'],
            payoutPerItem: map['payout_per_item'] ??
                map['unit_paid_amount'] ??
                map['unit_payout_amount'],
            source: map['source'] ?? map['price_source'] ?? map['bucket'],
            localSku: map['local_sku'] ?? row['local_sku'] ?? row['sku'],
            marketplaceSku: map['marketplace_sku'] ??
                map['marketplace_sku_id'] ??
                map['sku_id'] ??
                map['remote_sku_id'] ??
                row['marketplace_sku'] ??
                row['marketplace_sku_id'],
            marketplaceSellerSku: map['marketplace_seller_sku'] ??
                map['seller_sku'] ??
                row['marketplace_seller_sku'],
            statementId: map['statement_id'] ??
                map['statement'] ??
                map['finance_statement_id'] ??
                map['statement_transaction_id'] ??
                map['settlement_id'] ??
                row['statement_id'],
            orderStatus: map['order_status'] ?? map['status'],
            payoutStatus: map['payout_status'] ??
                map['settlement_status'] ??
                map['finance_status'] ??
                map['abnormal_status'],
            payoutReason: map['payout_reason'],
            rawPayoutComponents: map['raw_payout_components'] ??
                map['payout_components'] ??
                map['finance_components'] ??
                map['deduction_components'],
            negativePayoutReason: map['negative_payout_reason'] ??
                map['payout_minus_reason'] ??
                map['settlement_reason'],
            resiReason: map['resi_reason'],
            variantName: map['variant_name'] ??
                map['marketplace_variation_name'] ??
                map['marketplace_variant_name'] ??
                row['variant_name'] ??
                row['marketplace_variation_name'],
          );
        } else {
          _addOrderRefFromText(item.toString(), add);
        }
      }
    } else {
      final raw = _text(direct, '');
      for (final part in raw.split(RegExp(r'[,;|]'))) {
        _addOrderRefFromText(part, add);
      }
    }
    rows.sort((a, b) {
      final left =
          _parseDate(a['order_date']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final right =
          _parseDate(b['order_date']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return right.compareTo(left);
    });
    return rows;
  }

  void _addOrderRefFromText(
    String value,
    void Function({
      required String order,
      required String resi,
      dynamic orderDate,
      dynamic qty,
      dynamic gross,
      dynamic payout,
      dynamic hpp,
      dynamic hppPerItem,
      dynamic grossPerItem,
      dynamic payoutPerItem,
      dynamic source,
      dynamic localSku,
      dynamic marketplaceSku,
      dynamic marketplaceSellerSku,
      dynamic statementId,
      dynamic orderStatus,
      dynamic payoutStatus,
      dynamic payoutReason,
      dynamic rawPayoutComponents,
      dynamic negativePayoutReason,
      dynamic resiReason,
      dynamic variantName,
    }) add,
  ) {
    final clean = value.trim();
    if (clean.isEmpty || clean == '-') return;
    final payoutMatch = RegExp(r'(?:payout|net|diterima)\s*rp\s*([0-9.,-]+)',
            caseSensitive: false)
        .firstMatch(clean);
    final grossMatch =
        RegExp(r'(?:gross|omzet)\s*rp\s*([0-9.,-]+)', caseSensitive: false)
            .firstMatch(clean);
    final payout =
        payoutMatch == null ? 0 : _parseLooseMoney(payoutMatch.group(1) ?? '0');
    final gross =
        grossMatch == null ? 0 : _parseLooseMoney(grossMatch.group(1) ?? '0');
    var ref = clean
        .replaceAll(
            RegExp(
                r'·?\s*(?:gross|omzet|payout|net|diterima)?\s*rp\s*[0-9.,-]+',
                caseSensitive: false),
            '')
        .trim();
    ref = ref.replaceAll(RegExp(r'·\s*$'), '').trim();
    final parts = ref.split(RegExp(r'\s*/\s*'));
    add(
      order: parts.isNotEmpty ? parts.first : ref,
      resi: parts.length > 1 ? parts.sublist(1).join(' / ') : '-',
      qty: 1,
      gross: gross,
      payout: payout,
      hpp: 0,
      hppPerItem: 0,
      grossPerItem: gross,
      payoutPerItem: payout,
      source: 'legacy order_refs',
      localSku: '',
      marketplaceSku: '',
      marketplaceSellerSku: '',
      statementId: '',
      orderStatus: null,
      payoutStatus: null,
      payoutReason: null,
      rawPayoutComponents: null,
      negativePayoutReason: null,
      resiReason: null,
      variantName: null,
    );
  }

  num _parseLooseMoney(String value) {
    final normalized = value
        .trim()
        .replaceAll('.', '')
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'[^0-9.-]'), '');
    return num.tryParse(normalized) ?? 0;
  }

  String _moneyInput(num value) {
    final raw = value.abs().round().toString();
    if (raw == '0') return '';
    return _formatThousands(raw);
  }

  String _formatThousands(String digits) {
    final clean = digits.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.isEmpty) return '';
    final trimmed = clean.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final buffer = StringBuffer();
    for (var i = 0; i < trimmed.length; i++) {
      final reverse = trimmed.length - i;
      buffer.write(trimmed[i]);
      if (reverse > 1 && reverse % 3 == 1) buffer.write('.');
    }
    return buffer.toString();
  }

  String _profitLossValue(Map<String, dynamic> row) {
    final amount = _num(row['amount'] ?? row['value']);
    final label =
        _text(row['name'] ?? row['label'] ?? row['category']).toLowerCase();
    final format = _text(row['format']).toLowerCase();

    // Nilai biaya, HPP, payout, penjualan, dan laba tetap nominal Rupiah.
    // Baris margin/rasio tetap persentase walaupun labelnya mengandung kata payout.
    final mustBeMoney = label.contains('biaya') ||
        label.contains('hpp') ||
        label.contains('payout') ||
        label.contains('omzet') ||
        label.contains('gross') ||
        label.contains('penjualan') ||
        label.contains('laba') ||
        label.contains('rugi') ||
        label.contains('expense') ||
        label.contains('cost');
    final isPercent = !mustBeMoney &&
        (format.contains('percent') ||
            label.contains('margin') ||
            label.contains('rasio') ||
            label.contains('percent') ||
            label.contains('persen'));
    if (isPercent) return '${amount.toStringAsFixed(2)}%';

    return _money(amount);
  }

  String? _accountUuidParam() {
    final id = _accountFilter.trim();
    if (id == 'all' || id.isEmpty || !_isUuid(id)) return null;
    return id;
  }

  String _accountId(Map<String, dynamic> account) {
    final datas = [
      account['marketplace_account_id'],
      account['account_id'],
      account['id'],
    ];
    for (final value in datas) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && _isUuid(text)) return text;
    }
    return '';
  }

  bool _isUuid(String value) {
    final text = value.trim();
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(text);
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is List && value.isNotEmpty) return _asMap(value.first);
    if (value is String) {
      try {
        return _asMap(jsonDecode(value));
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    if (value is Map<String, dynamic>) {
      if (value.length == 1) {
        final onlyKey = value.keys.first;
        if (onlyKey == 'dashboard' ||
            onlyKey == 'report' ||
            onlyKey == 'abnormal' ||
            onlyKey == 'data' ||
            onlyKey == 'result') return _asMap(value[onlyKey]);
      }
      return value;
    }
    if (value is Map) {
      final map = Map<String, dynamic>.from(
          value.map((k, v) => MapEntry(k.toString(), v)));
      if (map.length == 1) {
        final onlyKey = map.keys.first;
        if (onlyKey == 'dashboard' ||
            onlyKey == 'report' ||
            onlyKey == 'abnormal' ||
            onlyKey == 'data' ||
            onlyKey == 'result') return _asMap(map[onlyKey]);
      }
      return map;
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asList(dynamic value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  bool _bool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1' || text == 'yes' || text == 'y';
  }

  double _num(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    final text = value.toString().trim();
    if (text.isEmpty) return 0.0;
    final direct = num.tryParse(text);
    if (direct != null) return direct.toDouble();
    return _parseLooseMoney(text).toDouble();
  }

  num _numAny(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (map.containsKey(key)) {
        final value = map[key];
        final parsed = _num(value);
        if (parsed != 0 || value == 0 || value == '0') return parsed;
      }
    }
    return 0;
  }

  bool _hasNonEmptyKey(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (!map.containsKey(key)) continue;
      final value = map[key];
      if (value == null) continue;
      if (value is String && value.trim().isEmpty) continue;
      return true;
    }
    return false;
  }

  Map<String, double> _positivePayoutRangeForSku({
    required Map<String, dynamic> row,
    required List<Map<String, dynamic>> detailRows,
    required int settledQty,
  }) {
    final values = <double>[];
    for (final detail in detailRows) {
      final qty = _num(detail['qty'] ?? detail['quantity']);
      final safeQty = qty > 0 ? qty : 1.0;
      final linePayout = _linePayoutAmount(detail, defaultQty: safeQty);
      if (linePayout <= 0) continue;
      final explicitPerItem = _numFirstNonZero([
        detail['payout_per_item'],
        detail['payout_item'],
        detail['settlement_per_item'],
      ]);
      final perItem =
          explicitPerItem > 0 ? explicitPerItem : linePayout / safeQty;
      if (perItem > 0) values.add(perItem.toDouble());
    }

    if (values.isEmpty) {
      final positiveTotal = _num(row['positive_payout_total']);
      final positiveQty = _numFirstNonZero([
        row['positive_payout_qty'],
        row['settled_qty'],
        row['paid_qty'],
        settledQty,
      ]);
      if (positiveTotal > 0 && positiveQty > 0) {
        values.add((positiveTotal / positiveQty).toDouble());
      }
    }

    if (values.isEmpty) return const {'highest': 0.0, 'lowest': 0.0};
    var highest = values.first;
    var lowest = values.first;
    for (final value in values.skip(1)) {
      if (value > highest) highest = value;
      if (value < lowest) lowest = value;
    }
    return {'highest': highest, 'lowest': lowest};
  }

  double _linePayoutAmount(Map<String, dynamic> detail,
      {double defaultQty = 1.0}) {
    const directKeys = [
      'payout',
      'payout_amount',
      'payout_total',
      'received_amount',
      'net_settlement',
      'settlement_amount',
      'paid_amount',
    ];
    for (final key in directKeys) {
      if (!_hasNonEmptyKey(detail, [key])) continue;
      return _num(detail[key]);
    }
    final qty = _num(detail['qty'] ?? detail['quantity']);
    final safeQty = qty > 0 ? qty : defaultQty;
    final perItem = _num(detail['payout_per_item'] ??
        detail['payout_item'] ??
        detail['settlement_per_item']);
    return perItem * safeQty;
  }

  bool _hasReleasedPayout(Map<String, dynamic> detail) {
    final payout = _linePayoutAmount(detail);
    if (payout != 0) {
      return true;
    }

    if (detail.containsKey('has_payout') && detail['has_payout'] != null) {
      if (detail['has_payout'] == true) return true;
    }

    final orderStatus = _text(
      detail['status'] ?? detail['order_status'],
      '',
    ).toUpperCase();

    final financeStatus = _text(
      detail['payout_status'] ??
          detail['settlement_status'] ??
          detail['finance_status'] ??
          detail['abnormal_status'],
      '',
    ).toUpperCase();

    final joinedStatus = '$orderStatus $financeStatus';

    if (joinedStatus.contains('CANCEL') ||
        joinedStatus.contains('REFUND') ||
        joinedStatus.contains('RETURN') ||
        joinedStatus.contains('BATAL')) {
      return false;
    }

    if (financeStatus.contains('SETTLED') && !financeStatus.contains('UNSETTLED')) {
      return true;
    }

    final marketplace = _text(detail['marketplace'] ?? detail['marketplace_name'], '').toLowerCase();
    if (marketplace.contains('shopee')) {
      if (financeStatus.contains('SETTLED') || financeStatus.contains('PAID') || financeStatus.contains('RELEASE')) {
        return true;
      }
      final bool isUnpaidStatus = financeStatus.contains('SHIPPED') ||
          financeStatus.contains('DIKIRIM') ||
          financeStatus.contains('RECEIVE') ||
          financeStatus.contains('BELUM') ||
          financeStatus.contains('PENDING') ||
          financeStatus.contains('UNPAID') ||
          financeStatus.contains('UNSETTLED') ||
          financeStatus.contains('PERLU') ||
          financeStatus.contains('READY') ||
          financeStatus.contains('DITERIMA') ||
          financeStatus.contains('TERIMA');
      return !isUnpaidStatus &&
          (financeStatus.contains('SELESAI') ||
              financeStatus.contains('COMPLETED') ||
              financeStatus.contains('IMPORT') ||
              financeStatus.contains('PROCESSED'));
    }

    return financeStatus.contains('SETTLED') ||
        financeStatus.contains('PAID') ||
        financeStatus.contains('RELEASE') ||
        financeStatus.contains('PAYOUT_MINUS') ||
        financeStatus.contains('NEGATIVE_PAYOUT');
  }

  String _payoutStatusText(Map<String, dynamic> detail) {
    final explicit =
        _text(detail['payout_status'] ?? detail['settlement_status'], '')
            .trim();
    final payout = _linePayoutAmount(detail);
    final explicitUpper = explicit.toUpperCase();
    if (explicitUpper.contains('PENDING') ||
        explicitUpper.contains('WAIT') ||
        explicitUpper.contains('NO_PAYOUT')) {
      return 'Menunggu settlement';
    }
    if (explicit.isNotEmpty && explicit != '-') return explicit;
    if (payout < 0) return 'payout minus/koreksi';
    if (payout > 0) return 'sudah release';
    if (_hasReleasedPayout(detail)) return 'sudah release Rp 0';
    return 'Menunggu settlement';
  }

  String _cleanText(dynamic value, String fallback) {
    final text = _text(value, '').trim();
    if (text.isEmpty || text == '-') return fallback;
    return text;
  }

  String _skuDetailPayoutItemLabel(Map<String, dynamic> detail) {
    if (!_hasReleasedPayout(detail)) return 'Payout/item';
    if (_skuDetailHasExactItemPayout(detail) ||
        _skuDetailSingleItemOrderIsExact(detail)) {
      return 'Payout exact/item';
    }
    final source = _text(detail['payout_source'] ?? detail['source'], '')
        .trim()
        .toLowerCase();
    if (source.contains('marketplace_finance_reports') ||
        source.contains('net_settlement') ||
        source.contains('settlement')) {
      return 'Estimasi payout/item';
    }
    return 'Rata-rata payout/item';
  }

  bool _skuDetailHasExactItemPayout(Map<String, dynamic> detail) {
    final exact = _numFirstNonZero([
      detail['exact_item_settlement'],
      detail['exact_item_payout'],
      detail['exact_line_settlement'],
      detail['exact_line_payout'],
    ]);
    if (exact != 0) return true;
    final source = _text(detail['payout_source'] ?? detail['source'], '')
        .trim()
        .toLowerCase();
    return source.contains('exact_item') || source.contains('exact_line');
  }

  bool _skuDetailSingleItemOrderIsExact(Map<String, dynamic> detail) {
    if (detail['single_item_order_payout_exact'] == true) return true;
    final orderPayout = _numFirstNonZero([
      detail['order_payout'],
      detail['order_payout_total'],
      detail['order_settlement_total'],
      detail['order_net_settlement'],
    ]);
    final orderGross = _numFirstNonZero([
      detail['order_line_gross'],
      detail['order_gross_total'],
      detail['order_line_gross_total'],
    ]);
    final lineGross = _numFirstNonZero([
      detail['gross'],
      detail['gross_amount'],
      detail['gross_total'],
    ]);
    return orderPayout != 0 &&
        orderGross > 0 &&
        lineGross > 0 &&
        (orderGross - lineGross).abs() <= 0.01;
  }

  String _skuDetailSourceText(Map<String, dynamic> detail) {
    return _cleanText(
      detail['payout_source'] ?? detail['source'],
      'Sumber tidak tersimpan',
    );
  }

  String _skuDetailPayoutItemText(Map<String, dynamic> detail) {
    if (!_hasReleasedPayout(detail)) return 'Belum ada payout';
    final qty = _num(detail['qty'] ?? detail['quantity']);
    final safeQty = qty > 0 ? qty : 1.0;
    final perItem = _numFirstNonZero([
      detail['payout_per_item'],
      detail['payout_item'],
      detail['settlement_per_item'],
      _linePayoutAmount(detail, defaultQty: safeQty) / safeQty,
    ]);
    return perItem > 0 ? _money(perItem) : 'Payout item belum tersimpan';
  }

  double _skuDetailOrderPayoutAmount(Map<String, dynamic> detail) {
    return _numFirstNonZero([
      detail['order_payout'],
      detail['order_payout_total'],
      detail['order_settlement_total'],
      detail['order_net_settlement'],
      detail['settlement_total'],
      detail['net_settlement'],
      detail['received_amount'],
      if (_skuDetailSingleItemOrderIsExact(detail))
        detail['payout'] ?? detail['payout_amount'],
    ]);
  }

  String _skuDetailOrderPayoutText(Map<String, dynamic> detail) {
    if (!_hasReleasedPayout(detail)) return 'Belum ada payout';
    final orderPayout = _skuDetailOrderPayoutAmount(detail);
    if (orderPayout != 0) return _money(orderPayout);
    final fallback = _linePayoutAmount(detail);
    return fallback != 0 ? _money(fallback) : 'Payout order belum tersimpan';
  }

  String _skuDetailAllocationText(Map<String, dynamic> detail) {
    if (!_hasReleasedPayout(detail)) return '';
    final source = _text(detail['payout_source'] ?? detail['source'], '')
        .trim()
        .toLowerCase();
    if (!source.contains('marketplace_finance_reports') &&
        !source.contains('settlement') &&
        !source.contains('page_first') &&
        !_skuDetailHasExactItemPayout(detail)) {
      return '';
    }

    final orderPayout = _numFirstNonZero([
      detail['order_payout'],
      detail['order_payout_total'],
      detail['order_settlement_total'],
      detail['order_net_settlement'],
    ]);
    final orderGross = _numFirstNonZero([
      detail['order_line_gross'],
      detail['order_gross_total'],
      detail['order_line_gross_total'],
    ]);
    final lineGross = _numFirstNonZero([
      detail['gross'],
      detail['gross_amount'],
      detail['gross_total'],
    ]);
    final linePayout = _numFirstNonZero([
      detail['payout'],
      detail['payout_amount'],
    ]);

    if (_skuDetailHasExactItemPayout(detail)) {
      return 'Payout exact dari settlement marketplace per item: ${_money(linePayout)}.';
    }

    if (orderGross > 0 && lineGross > 0) {
      if (_skuDetailSingleItemOrderIsExact(detail)) {
        return 'Payout exact dari settlement order single-item: ${_money(orderPayout)}.';
      } else {
        return 'Payout/item ditampilkan sebagai Rata-rata/Estimasi karena settlement exact per item belum tersedia.';
      }
    }
    return 'Payout/item ditampilkan sebagai Rata-rata/Estimasi.';
  }

  bool _skuDetailGrossMissing(Map<String, dynamic> detail) {
    final missingFlag =
        _text(detail['is_gross_missing'], '').trim().toLowerCase();
    if (missingFlag == 'true' || missingFlag == '1' || missingFlag == 'yes') {
      return true;
    }

    final validFlag =
        _text(detail['is_marketplace_gross_valid'], '').trim().toLowerCase();
    if (validFlag == 'false' || validFlag == '0' || validFlag == 'no') {
      return true;
    }

    final source = _text(detail['gross_source'], '').trim().toLowerCase();
    if (source == 'missing') return true;

    final gross = _num(detail['gross_sales'] ??
        detail['gross'] ??
        detail['gross_amount'] ??
        detail['gross_total']);
    final unit = _num(detail['gross_per_item'] ??
        detail['harga_jual_per_item'] ??
        detail['unit_price'] ??
        detail['price_per_item'] ??
        detail['unit_gross_amount']);

    return gross <= 0 && unit <= 0;
  }

  String _skuDetailGrossMissingLabel(Map<String, dynamic> detail) {
    final rawLabel = _cleanText(
      detail['gross_missing_label'] ??
          detail['gross_sales_display'] ??
          detail['harga_jual_per_item_display'],
      '',
    ).trim();

    final normalized = rawLabel.toLowerCase();
    final looksZero = RegExp(r'^(rp\s*)?0([,.]0+)?$').hasMatch(normalized);

    if (rawLabel.isNotEmpty &&
        normalized != 'null' &&
        rawLabel != '-' &&
        !looksZero) {
      return rawLabel;
    }

    return 'Harga marketplace belum tersedia';
  }

  String _skuDetailGrossPerItemText(Map<String, dynamic> detail) {
    if (_skuDetailGrossMissing(detail)) {
      return _skuDetailGrossMissingLabel(detail);
    }

    final unit = _num(detail['gross_per_item'] ??
        detail['harga_jual_per_item'] ??
        detail['unit_price'] ??
        detail['price_per_item'] ??
        detail['unit_gross_amount']);
    if (unit > 0) return _money(unit);

    final gross = _num(detail['gross_sales'] ??
        detail['gross'] ??
        detail['gross_amount'] ??
        detail['gross_total']);
    final qty = _num(detail['qty'] ?? detail['quantity']);
    if (gross > 0 && qty > 0) return _money(gross / qty);

    return _skuDetailGrossMissingLabel(detail);
  }

  String _skuDetailHppItemText(Map<String, dynamic> detail) {
    final hpp = _num(detail['hpp_per_item'] ?? detail['hpp']);
    if (hpp <= 0) return 'HPP belum mapping';
    return _money(hpp);
  }

  String _skuDetailSettlementText(Map<String, dynamic> detail) {
    if (!_hasReleasedPayout(detail)) return 'Belum ada settlement';
    final statement = _cleanText(
      detail['statement_id'] ??
          detail['settlement_id'] ??
          detail['statement_ref'] ??
          detail['settlement_ref'],
      '',
    );
    return statement.isEmpty ? 'Ref settlement belum tersimpan' : statement;
  }

  String _payoutExplainText(Map<String, dynamic> detail) {
    final payout = _linePayoutAmount(detail);
    final reason =
        _text(detail['negative_payout_reason'] ?? detail['payout_reason'], '')
            .trim();
    final components = _text(
      detail['raw_payout_components'] ??
          detail['payout_components'] ??
          detail['finance_components'] ??
          detail['deduction_components'],
      '',
    ).trim();
    if (payout < 0) {
      final parts = <String>[
        'Payout minus ${_money(payout)} dari marketplace.'
      ];
      if (reason.isNotEmpty && reason != '-') parts.add(reason);
      if (components.isNotEmpty && components != '-')
        parts.add('Rincian potongan: $components');
      if (parts.length == 1)
        parts.add(
            'Biasanya karena refund/return, voucher, biaya platform, atau koreksi marketplace.');
      return parts.join(' ');
    }
    if (reason.isNotEmpty && reason != '-') return reason;
    if (components.isNotEmpty && components != '-')
      return 'Rincian potongan: $components';
    return '';
  }

  bool _isCancelLikeStatus(dynamic value) {
    final text = _text(value, '').toUpperCase();
    return text.contains('CANCEL') ||
        text.contains('CANCELED') ||
        text.contains('CANCELLED') ||
        text.contains('BATAL') ||
        text.contains('RETURN') ||
        text.contains('REFUND') ||
        text.contains('RTS') ||
        text.contains('GAGAL') ||
        text.contains('FAILED') ||
        text.contains('CLOSED');
  }

  bool _shouldHideZeroCancelAbnormal(Map<String, dynamic> row) {
    final status = row['order_status'] ?? row['status'];
    if (!_isCancelLikeStatus(status)) return false;
    final payout =
        _num(row['payout_amount'] ?? row['payout_total'] ?? row['payout']);
    final diff = _num(row['difference_amount'] ?? row['gap_amount']);
    final reason =
        _text(row['payout_reason'] ?? row['message'] ?? row['catatan'], '')
            .toLowerCase();
    final hasPenaltyNote = reason.contains('penalty') ||
        reason.contains('denda') ||
        reason.contains('charge') ||
        reason.contains('minus') ||
        reason.contains('potong');
    // Order cancel tanpa settlement tidak perlu memenuhi daftar abnormal. Kalau ada nilai minus/charge ke seller, tetap tampil.
    return payout >= 0 && !hasPenaltyNote && diff >= 0;
  }

  String _text(dynamic value, [String fallback = '-']) {
    final raw = value?.toString().trim() ?? '';
    return raw.isEmpty ? fallback : raw;
  }

  String _moneyNullable(dynamic value) {
    if (value == null) return '-';
    final parsed = _num(value);
    if (parsed == 0 && (value is String && value.trim().isEmpty)) return '-';
    return _money(parsed);
  }

  String _money(num value) {
    return AppUi.rupiah(value);
  }

  String _date(dynamic value) {
    final date = _parseDate(value);
    if (date == null) return '-';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  String _dateTime(dynamic value) {
    return AppUi.formatWibDateTime(value);
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    final parsed =
        value is DateTime ? value : DateTime.tryParse(value.toString());
    if (parsed == null) return null;
    return parsed.toUtc().add(const Duration(hours: 7));
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  DateTime _monthStart(DateTime value) => DateTime(value.year, value.month, 1);

  String _monthLabel(DateTime value) {
    const names = [
      'Januari',
      'Februari',
      'Maret',
      'April',
      'Mei',
      'Juni',
      'Juli',
      'Agustus',
      'September',
      'Oktober',
      'November',
      'Desember',
    ];
    final monthName = names[(value.month - 1).clamp(0, 11).toInt()];
    return '$monthName ${value.year}';
  }

  Future<DateTime?> _pickMonth(DateTime initial) async {
    var year = initial.year;
    var selectedMonth = initial.month;
    return showDialog<DateTime>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          title: Text('Pilih bulan'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Tahun sebelumnya',
                      onPressed: () => setDialogState(() => year--),
                      icon: Icon(Icons.chevron_left_rounded),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          '$year',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Tahun berikutnya',
                      onPressed: () => setDialogState(() => year++),
                      icon: Icon(Icons.chevron_right_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 12,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisExtent: 42,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    final month = index + 1;
                    final selected = month == selectedMonth;
                    return OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: selected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        foregroundColor: selected
                            ? Theme.of(context).colorScheme.onPrimary
                            : null,
                      ),
                      onPressed: () =>
                          setDialogState(() => selectedMonth = month),
                      child: Text(_monthLabel(DateTime(year, month, 1))
                          .split(' ')
                          .first),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: Text('Batal')),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, DateTime(year, selectedMonth, 1)),
              child: Text('Pilih'),
            ),
          ],
        ),
      ),
    );
  }

  String _toDateParam(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  }

  String _marketplaceName(String value) {
    final clean = value.toLowerCase();
    if (clean.contains('tiktok')) return 'TikTok Shop';
    if (clean.contains('shopee')) return 'Shopee';
    if (clean == '-' || clean == 'all') return 'Marketplace';
    return value;
  }

  String _sourceLabel(String value) {
    final clean = value.toLowerCase().replaceAll('_', ' ').trim();
    if (clean.contains('arus kas bersih') ||
        clean.contains('jumlah arus kas') ||
        clean.contains('total arus kas')) return 'Jumlah Arus Kas';
    if (clean.contains('potongan marketplace')) return 'Potongan marketplace';
    if (clean.contains('marketplace')) return 'Marketplace';
    if (clean.contains('purchase') || clean.contains('pembelian'))
      return 'Pembelian disetujui';
    if (clean.contains('expense') || clean.contains('biaya'))
      return 'Biaya operasional';
    if (clean.contains('cash')) return 'Arus kas';
    if (clean.contains('hpp')) return 'HPP';
    if (clean == '-' || clean.isEmpty) return 'Data';
    return value
        .split(RegExp(r'[ _-]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
  }

  String _cleanError(Object e) {
    final raw = e.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('failed host lookup') ||
        lower.contains('socketexception') ||
        lower.contains('no address associated with hostname')) {
      return 'Koneksi belum stabil. Cek internet/DNS/VPN, lalu refresh ulang. Data tetap aman.';
    }
    if (lower.contains('sortfield is a required field')) {
      return 'Tarik finance gagal karena format request TikTok belum sesuai. Deploy ulang fungsi marketplace TikTok terbaru.';
    }
    if (lower.contains('could not find the function') ||
        lower.contains('function public.') ||
        lower.contains('does not exist')) {
      return 'Data terakhir tetap ditampilkan. Refresh server masih diproses otomatis.';
    }
    if (lower.contains('null value in column') &&
        lower.contains('description')) {
      return 'Catatan biaya kosong. Isi catatan otomatis dari kategori, lalu simpan ulang.';
    }
    return AppUi.userMessage(raw
        .replaceAll('PostgrestException(message: ', '')
        .replaceAll(', code:', '\nKode:')
        .replaceAll(', details:', '\nDetail:')
        .replaceAll(', hint:', '\nSaran:')
        .replaceAll(')', ''));
  }

  Future<void> _syncSkuHppFromMapping() async {
    if (_isSyncingHpp) return;
    setState(() => _isSyncingHpp = true);
    try {
      await _client.rpc(
        'marketplace_sync_hpp_from_sku_maps',
        params: {
          'p_tenant_id': _currentTenantId,
          'p_marketplace_account_id': _marketplaceFilter == 'all' ? null : _marketplaceFilter,
          'p_overwrite': false,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('HPP disinkronisasi.')));
        _hardReloadFinanceView();
      }
    } catch (e) {
      if (mounted) {
        final err = _cleanError(e);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal sinkron HPP: $err')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncingHpp = false);
      }
    }
  }
}

class _Metric {
  final String label;
  final String value;
  final IconData icon;

  const _Metric(this.label, this.value, this.icon);
}

class _ThousandsInputFormatter extends TextInputFormatter {
  const _ThousandsInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return const AppMoneyInputFormatter().formatEditUpdate(oldValue, newValue);
  }
}
