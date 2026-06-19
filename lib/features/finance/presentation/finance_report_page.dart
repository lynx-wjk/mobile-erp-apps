import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/app_roles.dart';
import '../../../core/ui/app_ui.dart';
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
  Map<String, dynamic> _marketplaceBootstrapUiStatus =
      const <String, dynamic>{};
  int _financeLoadSerial = 0;
  static const String _financeCacheVersion =
      'finance_live_20260619_recover_existing_rpc_v25';
  static const List<String> _financeCacheVersionFallbacks = <String>[
    _financeCacheVersion,
    'finance_live_20260619_recover_existing_rpc_v23',
    'finance_live_20260606_local_cache_fast_v20',
    'finance_live_20260606_local_cache_fast_v19',
    'finance_live_20260606_local_cache_fast_v18',
    'finance_live_20260606_local_cache_fast_v17',
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
  static const int _skuPageSize = 50;
  List<Map<String, dynamic>> _cashFlow = [];
  List<Map<String, dynamic>> _cashOpeningBalances = [];
  List<Map<String, dynamic>> _cashAdjustments = [];
  List<Map<String, dynamic>> _marketplaceWithdrawals = [];
  List<Map<String, dynamic>> _withdrawalAllocations = [];
  List<Map<String, dynamic>> _expenses = [];
  List<Map<String, dynamic>> _profitLoss = [];
  List<Map<String, dynamic>> _profitLossByMarketplace = [];
  List<Map<String, dynamic>> _abnormals = [];

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

  @override
  void initState() {
    super.initState();
    _marketplaceFilter =
        _normalizeMarketplaceFilter(_marketplaceFilter) ?? 'all';
    _accountFilter = _accountFilter == 'all' || _isUuid(_accountFilter)
        ? _accountFilter
        : 'all';
    _rememberFilters();
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
      'finance_customer_dashboard_snapshot',
      'finance_customer_dashboard_snapshot',
    ];

    Object? lastError;
    dynamic firstEmptyResponse;

    for (final rpcName in candidates) {
      final safeRpcName = rpcName.trim();
      if (safeRpcName.isEmpty) continue;

      try {
        final response = await _client.rpc(safeRpcName, params: params);
        final enrichedResponse =
            await _withMarketplaceReconciliation(response, params);
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

    if (lastError != null) {
      throw lastError;
    }

    throw Exception('Belum ada data pada filter ini.');
  }

  Future<dynamic> _withMarketplaceReconciliation(
    dynamic response,
    Map<String, dynamic> params,
  ) async {
    if (response is! Map) return response;
    try {
      final reconciliation = await _client.rpc(
        'finance_marketplace_reconciliation_breakdown',
        params: {
          'p_start': params['p_start'],
          'p_end': params['p_end'],
          'p_marketplace': params['p_marketplace'],
          'p_account_id': params['p_account_id'],
        },
      );
      if (reconciliation is! Map) return response;

      final out = Map<String, dynamic>.from(response);
      final summary = Map<String, dynamic>.from(_asMap(out['summary']));
      final reconciliationSummary =
          Map<String, dynamic>.from(_asMap(reconciliation['summary']));

      for (final entry in reconciliationSummary.entries) {
        summary[entry.key] = entry.value;
      }
      out['summary'] = summary;

      // Jangan overwrite by_marketplace dari canonical snapshot.
      // Snapshot sudah membawa HPP split per marketplace; reconciliation raw tidak selalu punya HPP.
      final existingMarketplaceRows =
          _asList(out['by_marketplace'] ?? out['marketplaces']);
      final byMarketplace = _asList(reconciliation['by_marketplace']);
      if (existingMarketplaceRows.isEmpty && byMarketplace.isNotEmpty) {
        out['by_marketplace'] = byMarketplace;
        out['marketplaces'] = byMarketplace;
      }

      // Jangan append breakdown dari reconciliation ke snapshot karena bisa double
      // setelah refresh. Pakai breakdown snapshot jika ada; fallback ke reconciliation.
      final existingBreakdown = _asList(out['profit_loss_breakdown']);
      final reconciliationBreakdown =
          _asList(reconciliation['profit_loss_breakdown']);
      if (existingBreakdown.isEmpty && reconciliationBreakdown.isNotEmpty) {
        out['profit_loss_breakdown'] = reconciliationBreakdown;
      }
      return out;
    } catch (error) {
      debugPrint('FINANCE_RECONCILIATION_RPC_FAILED: $error');
      return response;
    }
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
    final base = FinanceLocalCache.snapshotKey(
      start: _start,
      end: _end,
      marketplace: _marketplaceFilter,
      accountId: _accountFilter,
    );
    return _financeCacheVersionFallbacks
        .map((version) => '$base::$version')
        .toList(growable: false);
  }

  Future<Map<String, dynamic>?> _readFinanceSnapshotLocalAny() async {
    for (final key in _financeSnapshotLocalKeys()) {
      final cached = await FinanceLocalCache.readJson(key, ttlDays: 90);
      if (cached != null && !_isFinanceSnapshotEmpty(cached)) return cached;
    }
    return null;
  }

  Future<void> _refreshFinanceCacheForSelectedPeriod() async {
    // Jangan hapus semua local cache. Kalau server timeout, cache lama tetap
    // dipakai sebagai tampilan cepat.
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
    final manual = _sumAmountRows(manualExpenses);
    final purchases = _sumAmountRows(approvedPurchases);
    final expenseTotal = manual + purchases;
    final grossProfit = payout - hpp;
    final profit = grossProfit - expenseTotal;
    final margin = payout > 0
        ? (profit / payout) * 100
        : _numFirstNonZero([out['net_margin_percent'], out['margin_percent']]);
    out['manual_expense_total'] = manual;
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
    final params = <String, dynamic>{
      'p_start': _toDateParam(_start),
      'p_end': _toDateParam(_end),
      'p_marketplace': _marketplaceRpcParam(),
      'p_account_id': _accountUuidParam(),
    };

    List<Map<String, dynamic>> results = [];
    try {
      final candidates = <String>[
        'finance_list_manual_operational_expenses',
        'finance_list_manual_operational_expenses',
      ];
      final res = await _rpcWithFallback(candidates, params);
      final rows = _asList(_asMap(res)['rows'] ?? res);
      if (rows.isNotEmpty) {
        results = rows
            .map((e) => _normalizeProductionExpenseRow(
                Map<String, dynamic>.from(e as Map)))
            .toList();
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
            .range(0, 499);
        results = _asList(res)
            .map((e) => _normalizeProductionExpenseRow(
                Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {}
    }

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
        return _productionPaymentExpenseFromRow(map);
      }).where((row) {
        final aliases = _productionExpenseAliases(row);
        return aliases.every((alias) => !mirroredProductionIds.contains(alias));
      }).toList();

      results.addAll(tailorPayments);
      results.sort((a, b) {
        final dateA = a['expense_date']?.toString() ?? '';
        final dateB = b['expense_date']?.toString() ?? '';
        return dateB.compareTo(dateA);
      });
    } catch (_) {}

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

  Future<List<Map<String, dynamic>>> _fetchSkuRowsByPayoutFilterAll(
      String payoutFilter) async {
    final allRows = <Map<String, dynamic>>[];
    const pageSize = 500;

    for (var page = 1; page <= 20; page++) {
      final params = {
        'p_start': _toDateParam(_start),
        'p_end': _toDateParam(_end),
        'p_marketplace': _marketplaceRpcParam(),
        'p_account_id': _accountUuidParam(),
        'p_search': null,
        'p_payout_filter': payoutFilter,
        'p_page': page,
        'p_page_size': pageSize,
      };

      try {
        final response = await _client.rpc(
          'finance_sku_order_details',
          params: params,
        );
        final map = _asMap(response);
        final rows = _asList(map['rows'] ?? map['by_sku'] ?? map['sku'])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();

        if (rows.isEmpty) break;
        allRows.addAll(rows);
        if (rows.length < pageSize) break;
      } catch (error) {
        debugPrint('FINANCE_SKU_${payoutFilter}_PAGE_$page failed: $error');
        break;
      }
    }

    return allRows;
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
        'finance_sku_order_details',
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

  String _snapshotStats(dynamic response) {
    final data = _asMap(response);
    final summary = _asMap(data['summary']);
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
    final data = _asMap(response);
    final summary = _asMap(data['summary']);
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
    final summary = _asMap(data['summary']);
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
      final updatedLine = updatedAt == null
          ? null
          : 'Update terakhir: ${_dateTime(updatedAt)} WIB';
      setState(() {
        _progressTitle = title;
        _progressLines
          ..clear()
          ..addAll([
            if (updatedLine != null) updatedLine,
            ...lines.take(10),
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
      out['account_name'] = _text(
        out['account_name'] ?? out['shop_name'] ?? out['store_alias'],
        '-',
      );
      out['shop_name'] = _text(out['shop_name'] ?? out['account_name'], '-');
      return out;
    }).toList(growable: false);
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
    final normalizedSummary = _normalizeFinanceSummary(_asMap(data['summary']));
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
    ]);
    final approvedPurchases = _dedupeByStableKey(<Map<String, dynamic>>[
      ...backendPurchases,
      ...backendExpenses.where(_isPurchaseExpenseRow),
      ...livePurchases,
    ]);

    final snapshotSkuRows = _skuRowsFromSnapshot(data);
    final liveSettledSkuRows = includeSupplementalSku
        ? _filterSkuRowsBySelectedScope(
            await _fetchSkuRowsByPayoutFilterAll('settled'),
          )
        : <Map<String, dynamic>>[];
    final liveUnpaidSkuRows = includeSupplementalSku
        ? _filterSkuRowsBySelectedScope(
            await _fetchSkuRowsByPayoutFilterAll('unpaid'),
          )
        : <Map<String, dynamic>>[];

    var rawSkuRows = _filterSkuRowsBySelectedScope(<Map<String, dynamic>>[
      ...snapshotSkuRows,
      ...liveSettledSkuRows,
      ...liveUnpaidSkuRows,
    ]);

    // Backend snapshot/RPC sudah menerima p_marketplace dan p_account_id.
    // Beberapa summary SKU lama tidak membawa field marketplace/account di tiap row.
    // Kalau filter scope lokal mengosongkan semua row padahal snapshot punya data,
    // pakai data snapshot scoped dari server agar range lama seperti 1-31 Mei tetap tampil.
    if (rawSkuRows.isEmpty && snapshotSkuRows.isNotEmpty) {
      rawSkuRows = snapshotSkuRows;
    }

    final normalizedSku = _mergeSkuRows(
      _normalizeSkuRows(rawSkuRows),
      const <Map<String, dynamic>>[],
    );

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
    final normalizedProfitLoss = _profitLossRowsFromSummary(displaySummary);
    final normalizedMarketplaceForDisplay =
        _marketplaceRowsWithFinanceAliases(normalizedMarketplace);
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
      _cashFlow = normalizedCashFlow;
      _cashOpeningBalances = useBackendCashFlow
          ? <Map<String, dynamic>>[]
          : cashWalletData['opening'] ?? <Map<String, dynamic>>[];
      _cashAdjustments = useBackendCashFlow
          ? <Map<String, dynamic>>[]
          : cashWalletData['adjustments'] ?? <Map<String, dynamic>>[];
      _marketplaceWithdrawals = useBackendCashFlow
          ? <Map<String, dynamic>>[]
          : cashWalletData['withdrawals'] ?? <Map<String, dynamic>>[];
      _withdrawalAllocations = useBackendCashFlow
          ? <Map<String, dynamic>>[]
          : cashWalletData['allocations'] ?? <Map<String, dynamic>>[];
      _expenses = normalizedExpenses;
      _profitLoss = normalizedProfitLoss;
      final rawProfitLossMarketplace = _asList(
        data['profit_loss_by_marketplace'] ??
            data['by_marketplace'] ??
            data['marketplaces'],
      );
      _profitLossByMarketplace = _marketplaceRowsWithFinanceAliases(
        rawProfitLossMarketplace
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(),
      );
      _abnormals = _normalizeAbnormalRows(_asList(data['abnormals']));
      if (_progressTitle.trim().isEmpty && _progressLines.isEmpty) {
        final lastMessage = _text(
            _summary['last_manual_finance_sync_message'] ??
                _summary['last_finance_sync_message']);
        if (lastMessage.trim().isNotEmpty) {
          _progressTitle = 'Status auto finance';
          _progressLines.add(AppUi.userMessage(lastMessage));
          _cacheFinanceProgress();
        }
      }
      _expenseCategoryOptions = _mergeExpenseCategories(normalizedExpenses);
    });
  }

  Future<void> _load({bool ignoreLocalCache = false}) async {
    if (!mounted) return;

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

      // Jangan tampilkan angka periode lama ketika user ganti filter.
      // Lebih baik kosong saat loading daripada laporan keuangan cosplay jadi ramalan.
      _summary = <String, dynamic>{};
      _sources = [];
      _approvedPurchases = [];
      _byMarketplace = [];
      _bySku = [];
      _cashFlow = [];
      _cashOpeningBalances = [];
      _cashAdjustments = [];
      _marketplaceWithdrawals = [];
      _withdrawalAllocations = [];
      _expenses = [];
      _profitLoss = [];
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
        // Cache lokal harus langsung usable, tapi tab Abnormal tetap butuh page
        // kecil dari server/raw agar tidak kosong saat summary bilang ada payout minus.
        await _loadAbnormalesPage(silent: true, resetPage: true);
      }

      final snapshotParams = {
        'p_start': _toDateParam(_start),
        'p_end': _toDateParam(_end),
        'p_marketplace': _marketplaceRpcParam(),
        'p_account_id': _accountUuidParam(),
      };

      var response = await _loadFinanceSnapshot(snapshotParams);
      var data = _asMap(response);
      if (_isFinanceSnapshotEmpty(data)) {
        await _refreshFinanceCacheForSelectedPeriod();
        response = await _loadFinanceSnapshot(snapshotParams);
        data = _asMap(response);
      }
      if (_isFinanceSnapshotEmpty(data)) {
        if (hasLocalSnapshot) {
          await _loadPersistedFinanceProgressFromDb();
          await _loadAbnormalesPage(silent: true, resetPage: true);
          return;
        }
        if (mounted) {
          _setMessage(
              'Data laporan periode ini belum siap. Auto finance sedang mengejar data periode ini di background.');
        }
        await _loadPersistedFinanceProgressFromDb();
        await _loadAbnormalesPage(silent: true, resetPage: true);
        return;
      }
      await FinanceLocalCache.writeJson(localKey, data);
      if (!isCurrentFinanceLoad()) return;
      await _applyFinanceSnapshotData(
        data,
        fallbackAccounts,
        includeOperationalExpenses: true,
        includeSupplementalSku: true,
      );

      if (!isCurrentFinanceLoad() || !mounted) return;
      await _overlaySkuPayoutCountSummaryFromServer();
      if (!isCurrentFinanceLoad() || !mounted) return;
      await _loadPersistedFinanceProgressFromDb();
      await _loadAbnormalesPage(silent: true, resetPage: true);
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

      for (final item in rawRows) {
        if (item is! Map) continue;
        final row = Map<String, dynamic>.from(item);

        final marketplaceSku = _firstSkuPayoutCountValue(row, const [
          'marketplace_sku',
          'marketplace_sku_id',
          'sku_marketplace',
        ]);

        final localSku = _firstSkuPayoutCountValue(row, const [
          'local_sku',
          'sku_local',
        ]);

        final skuKey = _skuPayoutCountCleanKey(marketplaceSku);
        if (skuKey.isEmpty) continue;

        final compositeKey =
            _skuPayoutCountCompositeKey(marketplaceSku, localSku);

        if (compositeKey.trim() != '|') {
          out[compositeKey] = row;
        }

        // Fallback utama. Marketplace SKU harus unik untuk variant marketplace.
        out['$skuKey|'] = row;
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
      'marketplace_sku',
      'marketplace_sku_id',
      'sku_marketplace',
    ]);

    final localSku = _firstSkuPayoutCountValue(row, const [
      'local_sku',
      'sku_local',
    ]);

    final compositeKey = _skuPayoutCountCompositeKey(marketplaceSku, localSku);
    final skuOnlyKey = '${_skuPayoutCountCleanKey(marketplaceSku)}|';

    final summary = summaryMap[compositeKey] ?? summaryMap[skuOnlyKey];
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

    final visibleQty = paidQty + unpaidQty;
    final merged = Map<String, dynamic>.from(row);

    merged['paid_qty'] = paidQty;
    merged['settled_qty'] = paidQty;
    merged['qty_paid'] = paidQty;
    merged['positive_payout_qty'] = paidQty;

    merged['unpaid_qty'] = unpaidQty;
    merged['qty_unpaid'] = unpaidQty;
    merged['pending_payout_qty'] = unpaidQty;
    merged['pending_payout_qty_total'] = unpaidQty;

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
      });
    } catch (e) {
      // Overlay hitungan settled/belum payout hanya data peng.
      // Jangan pernah bikin laporan utama gagal dimuat gara-gara RPC overlay
      // belum ada, beda signature, timeout, atau schema cache Supabase sedang malas hidup.
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

    for (final source in rows) {
      if (_isPurchaseExpenseRow(source) || _isSyntheticExpenseRow(source)) {
        continue;
      }

      final row = Map<String, dynamic>.from(source);
      final amount = _numFirstNonZero(
          [row['amount'], row['total_amount'], row['expense_total']]);
      if (amount.abs() <= 0.49) continue;

      final expenseId = _expenseId(row);
      final stableDate = _date(row['expense_date'] ??
          row['paid_at'] ??
          row['date'] ??
          row['created_at']);
      final category = _text(row['category'], '').trim().toLowerCase();
      final note = _text(row['note'] ?? row['description'], '')
          .trim()
          .toLowerCase();
      final key = _isUuid(expenseId)
          ? 'id:$expenseId'
          : 'manual:$stableDate|$category|${amount.toStringAsFixed(0)}|$note';

      final existing = deduped[key];
      if (existing == null || (!_isUuid(_expenseId(existing)) && _isUuid(expenseId))) {
        deduped[key] = row;
      }
    }

    final out = deduped.values.toList();
    out.sort((a, b) {
      final ad = _parseDate(a['expense_date'] ?? a['paid_at'] ?? a['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bd = _parseDate(b['expense_date'] ?? b['paid_at'] ?? b['created_at']) ??
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
    return rows.where(_rowMatchesSelectedScope).toList();
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
          .toLowerCase();
      return status.contains('approved') ||
          status.contains('verified') ||
          status.contains('accepted') ||
          status.contains('approve') ||
          status == 'done' ||
          status == 'paid';
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
        final rows = await _client.from(table).select('*').range(0, 499);
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
    final purchases = _numFirstNonZero([
      summary['approved_purchase_total'],
      summary['purchase_cashout'],
      summary['approved_purchase_cashout']
    ]);
    final netCash = payout - manual - purchases;
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
    if (payout > 0 || manual > 0 || purchases > 0)
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
    final purchases = _numFirstNonZero([
      summary['approved_purchase_total'],
      summary['purchase_cashout'],
      summary['approved_purchase_cashout']
    ]);
    final ops = manual + purchases;
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
      if (amount <= 0) continue;
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
        'amount': -amount.abs(),
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
      {
        'name': 'Laba bersih',
        'description': 'Payout - HPP - biaya operasional - pembelian disetujui',
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
        if (paidQty <= 0 && paidPayout != 0) paidQty = totalQty;
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
      final local =
          _text(row['local_sku'] ?? row['sku'], '').trim().toLowerCase();
      return local.isEmpty || local == '-'
          ? ['${prefix}row_${row.hashCode}']
          : ['$prefix$local'];
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

      final detailOnly = _text(row['detail_source'], '').contains('detail') ||
          _text(row['source'], '').contains('detail');
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
      'NEGATIVE_PAYOUT',
      'MISSING_PAYOUT_FINAL',
      'PENDING_PAYOUT',
      'SAFE_CANCEL_UNPAID',
    ];
  }

  String _abnormalFilterLabel(String value) {
    switch (value.toUpperCase()) {
      case 'ALL':
        return 'Semua abnormal';
      case 'NEGATIVE_PAYOUT':
        return 'Payout minus / rugi';
      case 'MISSING_PAYOUT_FINAL':
        return 'Final tanpa payout';
      case 'PENDING_PAYOUT':
        return 'Belum payout';
      case 'SAFE_CANCEL_UNPAID':
        return 'Batal/unpaid aman';
      default:
        return value;
    }
  }

  List<Map<String, dynamic>> _filteredAbnormales() {
    final source = _abnormalServerLoaded ? _serverAbnormales : _abnormals;
    final filter = _abnormalStatusFilter.trim().toUpperCase();
    return source
        .where((row) {
          if (!_abnormalServerLoaded && _shouldHideZeroCancelAbnormal(row))
            return false;
          if (filter.isEmpty || filter == 'ALL') return true;
          final status = _text(row['abnormal_status'] ??
                  row['payout_status'] ??
                  row['order_status'] ??
                  row['status'])
              .trim()
              .toUpperCase();
          if (filter == 'NEGATIVE_PAYOUT')
            return _num(row['payout_amount'] ??
                        row['payout_total'] ??
                        row['payout']) <
                    0 ||
                status == 'NEGATIVE_PAYOUT';
          return status == filter ||
              _text(row['order_status'] ?? row['status'])
                      .trim()
                      .toUpperCase() ==
                  filter;
        })
        .take(_abnormalPageSize)
        .toList();
  }

  //  Abnormal reader
  // True duplicate check: marketplace_account_id + external_order_id + external_order_item_id.
  // Status mapping:
  //   PENDING_PAYOUT        â„¢ waiting, not error, not refresh-payout data.
  //   MISSING_PAYOUT_FINAL  â„¢ real abnormal, COMPLETED order without payout.
  //   NO_PAYOUT_EXPECTED    â„¢ excluded from payout refresh, show as greyed-out.
  //   CANCEL_OR_RETURN_DONE â„¢ finished without stock-in (cancelled before packing).
  //   DELIVERED w/o payout  â„¢ not a final abnormal unless status COMPLETED.

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
      'p_status': _abnormalStatusFilter == 'all' ? null : _abnormalStatusFilter,
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
        _abnormalTotal = _selectedScopeIsSpecific()
            ? rawRows.length
            : _num(map['total']).toInt();
        _abnormalPage = _num(map['page']).toInt().clamp(1, 999999).toInt();

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
    } catch (_) {
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
        });
      } else if (!silent) {
        setState(() {
          _serverAbnormales = [];
          _abnormalTotal = 0;
          _abnormalServerLoaded = false;
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
      color: Theme.of(context).colorScheme.outline,
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
      final dir = await getApplicationDocumentsDirectory();
      final file =
          File('${dir.path}/laporan_keuangan_semua_marketplace_$stamp.xlsx');
      await file.writeAsBytes(bytes, flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
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
            title: const Text('Pilih periode'),
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
          title: const Text('Edit saldo awal bulan'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Bulan'),
                  subtitle: Text(_monthLabel(period)),
                  trailing: const Icon(Icons.calendar_month_rounded),
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
                child: const Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Simpan')),
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
        title: const Text('Reset saldo awal?'),
        content: Text(
            'Saldo awal ${_monthLabel(_parseDate(row['period_month']) ?? _start)} akan diatur menjadi Rp0.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reset')),
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
        title: const Text('Hapus saldo awal?'),
        content: Text(
            'Saldo awal ${_monthLabel(_parseDate(row['period_month']) ?? _start)} akan dihapus dari Arus Kas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
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
                  title: const Text('Tanggal transaksi'),
                  subtitle: Text(_date(adjustmentDate)),
                  trailing: const Icon(Icons.calendar_month_rounded),
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
                child: const Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Simpan')),
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
        'tenant_id': _currentTenantId,
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
        title: const Text('Hapus kas manual?'),
        content: Text(
            '${_text(row['category'], 'Kas manual')} akan dihapus dari Arus Kas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
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
                  title: const Text('Tanggal penarikan'),
                  subtitle: Text(_date(withdrawalDate)),
                  trailing: const Icon(Icons.calendar_month_rounded),
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
                child: const Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Simpan')),
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
        title: const Text('Hapus penarikan marketplace?'),
        content: const Text(
            'Penarikan dan alokasi terkait akan dihapus dari Arus Kas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
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
                  title: const Text('Bulan sumber'),
                  subtitle: Text(_monthLabel(sourceMonth)),
                  trailing: const Icon(Icons.calendar_month_rounded),
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
                child: const Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Simpan')),
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
        title: const Text('Hapus alokasi penarikan?'),
        content: Text(
            'Alokasi bulan ${_monthLabel(_parseDate(row['source_period_month']) ?? _start)} akan dihapus.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
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
          accent.withOpacity(.12),
          Theme.of(context).cardColor,
        ),
        border: Border.all(color: accent.withOpacity(.55), width: 1.4),
        borderRadius: BorderRadius.zero,
        boxShadow: const [
          BoxShadow(color: Colors.black, blurRadius: 0, offset: Offset(3, 3)),
        ],
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
                        fontWeight: FontWeight.w900,
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
        color: Theme.of(context).scaffoldBackgroundColor.withOpacity(.62),
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(.22),
        ),
        borderRadius: BorderRadius.zero,
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: Theme.of(context).textTheme.bodyLarge?.color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Color _bootstrapFinanceSeverityColor(String severity) {
    switch (severity) {
      case 'error':
        return Colors.redAccent;
      case 'warning':
        return AppUi.orange;
      case 'success':
        return Colors.greenAccent;
      case 'info':
        return Colors.cyan;
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
      child: AppGlobalBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_rounded, size: 20),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: Text(
              'Laporan Keuangan'.toUpperCase(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white
                    : Colors.black,
              ),
            ),
            actions: [
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.cyan),
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
              preferredSize: const Size.fromHeight(48),
              child: Container(
                decoration: const BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: Colors.black, width: 3)),
                ),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: const UnderlineTabIndicator(
                    borderSide: BorderSide(color: Colors.cyan, width: 6),
                    insets: EdgeInsets.symmetric(horizontal: 16),
                  ),
                  labelColor: Theme.of(context).brightness == Brightness.dark
                      ? Colors.cyan
                      : Colors.black,
                  unselectedLabelColor:
                      Theme.of(context).brightness == Brightness.dark
                          ? Colors.white54
                          : Colors.black54,
                  labelStyle: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1),
                  unselectedLabelStyle: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700),
                  tabs: tabs,
                ),
              ),
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
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.cyan),
                      ),
                    );
                  }

                  return FloatingActionButton.extended(
                    onPressed: _addManualExpense,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.black,
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('BIAYA',
                        style: TextStyle(fontWeight: FontWeight.w900)),
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
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border(
          bottom:
              BorderSide(color: isDark ? Colors.white : Colors.black, width: 2),
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
                    shape:
                        RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                  ),
                  onPressed: () =>
                      setState(() => _filterExpanded = !_filterExpanded),
                  icon: Icon(
                      _filterExpanded ? Icons.expand_less : Icons.tune_rounded,
                      size: 18),
                  label: const Text('Filter',
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
    final manual = _summary['last_manual_finance_sync_at'];
    final auto = _financeAutoSyncLastRunAt ??
        _parseDate(_summary['last_auto_finance_sync_at']);
    final finance = _summary['last_finance_updated_at'];
    final order = _summary['last_order_pulled_at'];
    final period = '${_date(_start)} s/d ${_date(_end)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withOpacity(0.72),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Periode: $period',
            style: TextStyle(
                color: Theme.of(context).textTheme.bodyLarge?.color,
                fontSize: 11,
                fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 4),
          Text(
            ' ${_dateTime(manual)}',
            style: TextStyle(
                color: Theme.of(context).textTheme.bodyMedium?.color,
                fontSize: 11),
          ),
          Text(
            ' ${_dateTime(auto)}${_financeAutoSyncMessage.isNotEmpty ? ' · $_financeAutoSyncMessage' : ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Theme.of(context).textTheme.bodyMedium?.color,
                fontSize: 11),
          ),
          Text(
            'Order: ${_dateTime(order)} · Finance: ${_dateTime(finance)}',
            style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 10.5),
          ),
          if (_lastSnapshotStats.trim().isNotEmpty) ...[
            SizedBox(height: 3),
            Text(
              _lastSnapshotStats,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withOpacity(0.62),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: Theme.of(context).dividerColor),
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
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Theme.of(context).dividerColor)),
                SizedBox(height: 2),
                Text(
                    'Payout, missing payout, dan status order lama diproses otomatis di background.',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: Theme.of(context).colorScheme.outline)),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withOpacity(0.82),
          borderRadius: BorderRadius.zero,
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Text(
          label,
          style: TextStyle(
              color: Theme.of(context).dividerColor,
              fontSize: 11,
              fontWeight: FontWeight.w800),
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
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      borderRadius: BorderRadius.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.zero,
            border: Border.all(color: isDark ? Colors.white30 : Colors.black),
          ),
          child: Row(
            children: [
              Icon(icon, size: 14, color: Colors.cyan),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 86, maxWidth: 220),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.white70 : Colors.black54,
                            fontWeight: FontWeight.w600)),
                    Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            color: isDark ? Colors.white : Colors.black)),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: (Theme.of(context).cardColor),
        borderRadius: BorderRadius.zero,
        border:
            Border.all(color: Theme.of(context).dividerColor.withOpacity(0.35)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).textTheme.bodyLarge?.color),
          dropdownColor: (Theme.of(context).cardColor),
          items: items,
          onChanged: onChanged,
          hint: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
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
    final sampleOrderCount = _num(_summary['sample_order_count']);
    final sampleHppTotal = _num(_summary['sample_hpp_total']);
    final sampleNegativePayout = _num(_summary['sample_negative_payout_total']);
    final sampleLossEstimate = _numFirstNonZero([
      _summary['sample_loss_estimate'],
      sampleHppTotal + sampleNegativePayout,
    ]);

    if (_loading) {
      return const Center(child: FuturisticLoader(message: 'MEMUAT DATA...'));
    }

    final isEmpty = gross == 0 && payout == 0 && profit == 0 && orderCount == 0;

    return RefreshIndicator(
      color: Colors.cyan,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 130),
        children: [
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
                  backgroundColor: Colors.cyan,
                  foregroundColor: Colors.black,
                  side: const BorderSide(color: Colors.black, width: 3),
                ),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('TARIK ULANG DATA'),
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
            if (sampleOrderCount > 0 ||
                sampleHppTotal > 0 ||
                sampleNegativePayout > 0) ...[
              _detailCard(
                title: 'Sample / Gratis',
                subtitle:
                    '${sampleOrderCount.toStringAsFixed(0)} order · HPP ${_money(sampleHppTotal)} · Payout minus ${_money(sampleNegativePayout)}',
                children: [
                  _miniMetric(
                      'Order sample', sampleOrderCount.toStringAsFixed(0)),
                  _miniMetric('HPP sample', _money(sampleHppTotal)),
                  _miniMetric(
                      'Payout minus sample', _money(sampleNegativePayout)),
                  _miniMetric('Estimasi dampak', _money(sampleLossEstimate)),
                ],
              ),
              const SizedBox(height: 12),
            ],
            _metricGrid([
              _Metric('Omzet', _money(gross), Icons.sell_rounded),
              _Metric('Payout', _money(payout), Icons.payments_rounded),
              _Metric('HPP', _money(hpp), Icons.inventory_2_rounded),
              _Metric(
                  'Biaya Ops', _money(operational), Icons.receipt_long_rounded),
              _Metric('Payout Minus', _money(negativePayout),
                  Icons.remove_circle_outline),
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
            ..._byMarketplace.map((row) {
              final marketplace = _marketplaceName(_text(row['marketplace']));
              final shop = _text(
                  row['shop_name'] ?? row['seller_name'] ?? row['account_name'],
                  _accountNameById(_text(row['marketplace_account_id'])));
              final profit = _num(row['net_profit'] ?? row['profit']);
              final margin =
                  _num(row['net_margin_percent'] ?? row['margin_percent']);
              return _detailCard(
                title: '$marketplace · $shop',
                subtitle:
                    '${_num(row['order_count']).toStringAsFixed(0)} pesanan  ·  ${_dateTime(row['last_updated_at'] ?? row['updated_at'])}',
                children: [
                  _miniMetric('Omzet',
                      _money(_num(row['gross_sales'] ?? row['gross']))),
                  _miniMetric('Payout',
                      _money(_num(row['payout_total'] ?? row['net_received']))),
                  _miniMetric(
                      'HPP', _money(_num(row['hpp_total'] ?? row['hpp']))),
                  _miniMetric('Laba', _money(profit)),
                  _miniMetric('Margin', '${margin.toStringAsFixed(2)}%'),
                ],
              );
            }),
        ],
      ),
    );
  }

  int get _skuTotalPages {
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
    final start = ((page - 1) * _skuPageSize) + 1;
    final end = (page * _skuPageSize) > _bySku.length
        ? _bySku.length
        : page * _skuPageSize;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border.all(color: theme.dividerColor, width: 1.4),
        borderRadius: BorderRadius.zero,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'SKU $start–$end dari ${_bySku.length} · Page $page/$totalPages',
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Page sebelumnya',
            onPressed:
                page > 1 ? () => setState(() => _skuPage = page - 1) : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          IconButton(
            tooltip: 'Page berikutnya',
            onPressed: page < totalPages
                ? () => setState(() => _skuPage = page + 1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }

  Widget _skuTab() {
    if (_loading)
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _sectionHeader('Kinerja SKU'),
          SizedBox(height: 8),
          if (_bySku.isNotEmpty) ...[
            _skuPaginationControls(),
            const SizedBox(height: 10),
          ],
          if (_bySku.isEmpty)
            _emptyCard(
                'Belum ada data SKU finance.\nAuto finance sedang mengejar data periode ini di background. Pastikan mapping SKU lokal sudah benar agar HPP ikut terbaca.')
          else
            ..._skuVisibleRows.map((row) {
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
              final paidQtyDisplay = _qtyFromOrderRows(paidDetailRows) > 0
                  ? _qtyFromOrderRows(paidDetailRows)
                  : _numFirstNonZero([
                      row['paid_qty'],
                      row['settled_qty'],
                      row['qty_paid']
                    ]).round();
              final unpaidQtyDisplay = _qtyFromOrderRows(unpaidDetailRows) > 0
                  ? _qtyFromOrderRows(unpaidDetailRows)
                  : _numFirstNonZero([
                      row['unpaid_qty'],
                      row['pending_payout_qty'],
                      row['qty_unpaid']
                    ]).round();
              final qtyTotalDisplay = _numFirstNonZero([
                row['qty'],
                row['qty_total'],
                row['total_qty'],
                paidQtyDisplay + unpaidQtyDisplay,
              ]).round();
              final displayPayoutPerItem = _numFirstNonZero([
                row['positive_payout_per_item'],
                row['payout_per_item_paid'],
                row['payout_per_item'],
                paidQtyDisplay > 0
                    ? (_num(row['payout_total'] ??
                            row['payout_amount'] ??
                            row['received_amount']) /
                        paidQtyDisplay)
                    : 0,
              ]);
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
                paidQtyDisplay > 0 ? paidHppTotalForDisplay / paidQtyDisplay : 0,
              ]);
              if (displayPayoutPerItem > 0 && displayHppPerItem > 0) {
                actualMargin =
                    ((displayPayoutPerItem - displayHppPerItem) /
                            displayPayoutPerItem) *
                        100;
              }
              final belowTarget =
                  targetMargin > 0 && actualMargin < targetMargin;
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
                    TextButton.icon(
                      onPressed: () =>
                          _showSkuOrderRefsV82o(row, payoutFilter: 'paid'),
                      icon: Icon(Icons.receipt_long_rounded, size: 16),
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
                      onPressed: () =>
                          _showSkuOrderRefsV82o(row, payoutFilter: 'unpaid'),
                      icon: Icon(Icons.pending_actions_rounded, size: 16),
                      label: Text('Belum payout $unpaidQtyDisplay',
                          style: TextStyle(fontSize: 12)),
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
                  if (_num(row['positive_payout_qty']) > 0)
                    _miniMetric('Qty payout +',
                        _num(row['positive_payout_qty']).toStringAsFixed(0)),
                  if (_num(row['negative_payout_qty']) > 0)
                    _miniMetric('Qty koreksi -',
                        _num(row['negative_payout_qty']).toStringAsFixed(0),
                        warning: true),
                  _miniMetric(
                      'Gross/item', _money(_num(row['gross_per_item']))),
                  _miniMetric('Payout +/item', _money(displayPayoutPerItem)),
                  _miniMetric(
                      'Total payout',
                      _money(_num(row['payout_total'] ??
                          row['payout_amount'] ??
                          row['received_amount']))),
                  if (_num(row['negative_payout_total']) < 0)
                    _miniMetric('Koreksi minus',
                        _money(_num(row['negative_payout_total'])),
                        warning: true),
                  if (_num(row['net_payout_per_item_paid']) != 0 &&
                      (_num(row['net_payout_per_item_paid']) -
                                  _num(row['positive_payout_per_item'] ??
                                      row['payout_per_item_paid'] ??
                                      row['payout_per_item']))
                              .abs() >
                          0.49)
                    _miniMetric('Net payout/item',
                        _money(_num(row['net_payout_per_item_paid'])),
                        warning: _num(row['net_payout_per_item_paid']) < 0),
                  _miniMetric('HPP/item', _money(displayHppPerItem)),
                  _miniMetric(
                      'Margin net', '${actualMargin.toStringAsFixed(2)}%',
                      warning: belowTarget),
                  _miniMetric(
                      'Target',
                      targetMargin <= 0
                          ? '-'
                          : '${targetMargin.toStringAsFixed(2)}%'),
                ],
              );
            }),
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
    final purchases = _numFirstNonZero([
      _summary['approved_purchase_total'],
      _summary['purchase_cashout'],
      _summary['approved_purchase_cashout']
    ]);
    final netCash = summaryPayout - manual - purchases;
    if (summaryPayout == 0 && manual == 0 && purchases == 0 && netCash == 0)
      return <Map<String, dynamic>>[];
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
      {
        'category': 'Jumlah Arus Kas',
        'type': netCash >= 0 ? 'in' : 'out',
        'amount': netCash,
        'description': 'Payout - biaya manual - pembelian disetujui'
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
    final purchases = _numFirstNonZero([
      _summary['approved_purchase_total'],
      _summary['purchase_cashout'],
      _summary['approved_purchase_cashout']
    ]);
    final profit = payout - hpp - manual - purchases;
    if (gross == 0 &&
        payout == 0 &&
        hpp == 0 &&
        manual == 0 &&
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
      {
        'label': 'Laba Bersih',
        'amount': profit,
        'description': 'Payout - HPP - biaya manual - pembelian disetujui'
      },
    ];
  }

  Widget _cashFlowTab() {
    if (_loading) {
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
    }
    final cashRows = _cashFlow.isNotEmpty ? _cashFlow : _fallbackCashFlowRows();
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
      final amount = _num(row['amount']);
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
                  icon: const Icon(Icons.account_balance_wallet_rounded,
                      size: 18),
                  label: const Text('Saldo awal'),
                ),
                OutlinedButton.icon(
                  onPressed: _processing
                      ? null
                      : () => _editCashAdjustment(direction: 'in'),
                  icon: const Icon(Icons.south_west_rounded, size: 18),
                  label: const Text('Kas masuk'),
                ),
                OutlinedButton.icon(
                  onPressed: _processing
                      ? null
                      : () => _editCashAdjustment(direction: 'out'),
                  icon: const Icon(Icons.north_east_rounded, size: 18),
                  label: const Text('Kas keluar'),
                ),
                OutlinedButton.icon(
                  onPressed: _processing ? null : _editMarketplaceWithdrawal,
                  icon: const Icon(Icons.account_balance_rounded, size: 18),
                  label: const Text('Penarikan'),
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
              final amount = _num(row['amount']);
              return _simpleRowCard(
                title: _sourceLabel(
                    _text(row['source'] ?? row['category'] ?? type)),
                subtitle:
                    '${_date(row['date'] ?? row['created_at'])} - ${type.toUpperCase()}',
                trailing: (amount >= 0 ? '+ ' : '- ') + _money(amount.abs()),
                positive: amount >= 0,
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

  Widget _expensesTab() {
    if (_loading)
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
    return RefreshIndicator(
      color: Theme.of(context).colorScheme.primary,
      onRefresh: _safeRefreshFinanceView,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 130),
        children: [
          _sectionHeader('Biaya Operasional'),
          SizedBox(height: 8),
          if (_expenses.isEmpty && _approvedPurchases.isEmpty)
            _emptyCard(
                'Belum ada biaya operasional atau pembelian yang sudah disetujui.')
          else ...[
            ..._expenses.map(_expenseRowCard),
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
      ),
    );
  }

  bool _isGenericSettlementProfitLossRow(Map<String, dynamic> row) {
    final raw = _text(row['category'] ?? row['name'] ?? row['label']);
    final key = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

    return key == 'omzet' ||
        key == 'gross_sales' ||
        key.contains('payout_diterima') ||
        key.contains('payout_received') ||
        key.contains('voucher') ||
        key.contains('discount') ||
        key.contains('diskon') ||
        key.contains('marketplace') ||
        key.contains('platform_fee') ||
        key.contains('commission') ||
        key.contains('komisi') ||
        key.contains('affiliate') ||
        key.contains('shipping') ||
        key.contains('transaction_fee') ||
        key.contains('payment_fee') ||
        key.contains('refund') ||
        key.contains('retur') ||
        key.contains('return') ||
        key.contains('cancel') ||
        key.contains('tax') ||
        key.contains('pajak') ||
        key.contains('adjustment') ||
        key.contains('sample_zero_payment') ||
        key.contains('sample') ||
        key.contains('unclassified') ||
        key.contains('belum_terklasifikasi') ||
        key.contains('settlement_belum_final') ||
        key.contains('potongan_marketplace') ||
        raw.trim().toLowerCase() == 'marketplace';
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
        color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
        borderRadius: BorderRadius.zero,
        border: Border.all(
          color: warning
              ? Theme.of(context).colorScheme.error.withOpacity(0.32)
              : Theme.of(context).colorScheme.primary.withOpacity(0.20),
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
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
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
      final gross =
          _num(row['gross_sales'] ?? row['omzet_total'] ?? row['gross_total']);
      final payout = _num(row['payout_total'] ??
          row['received_amount'] ??
          row['net_settlement']);
      final hpp = _num(row['hpp_total'] ?? row['total_hpp']);
      final profit = _num(row['net_profit'] ?? row['profit'] ?? (payout - hpp));
      final margin = payout > 0
          ? _num(row['margin_percent'] ??
              row['net_margin_percent'] ??
              (profit / payout * 100))
          : 0;
      final discount = _num(row['discount_amount'] ?? row['voucher_amount']);
      final refund = _num(row['refund_amount'] ?? row['return_refund_amount']);
      final adjustment = _num(row['adjustment_amount']);
      final payoutMinus = _num(row['sample_negative_payout_total'] ??
          row['negative_payout_total'] ??
          row['minus_payout_total']);

      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withOpacity(0.76),
          borderRadius: BorderRadius.zero,
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$marketplace · $shop',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: Theme.of(context).textTheme.bodyLarge?.color,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '$orderCount pesanan · periode ${_date(_start)} - ${_date(_end)}',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _profitLossMiniMetric('Omzet', _money(gross), positive: true),
                _profitLossMiniMetric('Payout', _money(payout), positive: true),
                _profitLossMiniMetric('HPP', _money(hpp), warning: hpp > 0),
                _profitLossMiniMetric('Laba', _money(profit),
                    positive: profit >= 0, warning: profit < 0),
                _profitLossMiniMetric(
                    'Margin', '${margin.toStringAsFixed(2)}%'),
                if (discount.abs() > 0.49)
                  _profitLossMiniMetric(
                      'Voucher / diskon', _money(discount.abs()),
                      warning: true),
                if (refund.abs() > 0.49)
                  _profitLossMiniMetric('Refund / retur', _money(refund.abs()),
                      warning: true),
                if (adjustment.abs() > 0.49)
                  _profitLossMiniMetric('Adjustment', _money(adjustment),
                      warning: adjustment < 0),
                if (payoutMinus.abs() > 0.49)
                  _profitLossMiniMetric(
                      'Payout minus', _money(payoutMinus.abs()),
                      warning: true),
              ],
            ),
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
        0, (sum, row) => sum + _num(row['hpp_total'] ?? row['total_hpp']));
    final totalProfit = _profitLossByMarketplace.fold<num>(
        0, (sum, row) => sum + _num(row['net_profit'] ?? row['profit']));
    final totalMargin = totalPayout > 0 ? (totalProfit / totalPayout) * 100 : 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withOpacity(0.74),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Breakdown Laba Rugi per Marketplace',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: Theme.of(context).textTheme.bodyLarge?.color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tampilan kartu. Bukan tabel rekonsiliasi panjang.',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.outline,
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
    if (_loading)
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
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
          SizedBox(height: 8),
          if (_profitLossByMarketplace.isNotEmpty) ...[
            _profitLossByMarketplaceCard(),
            const SizedBox(height: 8),
          ],
          if (profitRows.isEmpty)
            _emptyCard('Belum ada data laba rugi pada periode ini.')
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
      ),
    );
  }

  Widget _abnormalTab() {
    if (_loading)
      return Center(child: FuturisticLoader(message: 'Memuat data...'));
    final visibleAbnormales = _filteredAbnormales();
    final pageMax = (_abnormalTotal <= 0)
        ? 1
        : ((_abnormalTotal + _abnormalPageSize - 1) ~/ _abnormalPageSize);
    final startRow =
        _abnormalTotal <= 0 ? 0 : ((_abnormalPage - 1) * _abnormalPageSize) + 1;
    final endRow =
        (_abnormalPage * _abnormalPageSize).clamp(0, _abnormalTotal).toInt();

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
            style:
                TextStyle(color: Theme.of(context).dividerColor, fontSize: 13),
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

          if (_abnormalSearchBusy)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                  child: FuturisticLoader(message: 'Mencari abnormal...')),
            )
          else ...[
            // Info bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor.withOpacity(0.72),
                borderRadius: BorderRadius.zero,
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Text(
                _abnormalServerLoaded
                    ? 'Hal $_abnormalPage/$pageMax · $startRow-$endRow dari $_abnormalTotal · $dataCount perlu cek payout'
                    : 'Belum ada hasil pencarian.',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
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
                      child: _abnormalStatusBadge(
                          statusInfo.label, statusInfo.color),
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

            if (_abnormalServerLoaded &&
                _abnormalTotal > _abnormalPageSize) ...[
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
                          color: Theme.of(context).colorScheme.outline,
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
        borderRadius: BorderRadius.zero,
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.3)),
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
          height: 14,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.zero,
          ),
        ),
        SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.outline,
            letterSpacing: 0.3,
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
    final borderColor = isDark ? Colors.white : Colors.black;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border.all(color: borderColor, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: borderColor.withOpacity(0.8),
            blurRadius: 0,
            offset: const Offset(5, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withOpacity(0.16),
              borderRadius: BorderRadius.zero,
              border: Border.all(color: color.withOpacity(0.32)),
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
                      color: color.withOpacity(0.8),
                      fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w900, color: color),
                ),
                SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).textTheme.bodyMedium?.color,
                    fontWeight: FontWeight.w700,
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
            final borderColor = isDark ? Colors.white70 : Colors.black;

            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.zero,
                color: isDark ? const Color(0xFF0F172A) : Colors.white,
                border: Border.all(color: borderColor, width: 2),
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
                          .withOpacity(0.12),
                      borderRadius: BorderRadius.zero,
                      border: Border.all(color: borderColor, width: 1.5),
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
                              fontSize: 10.5,
                              color:
                                  Theme.of(context).textTheme.bodyMedium?.color,
                              fontWeight: FontWeight.w800),
                        ),
                        SizedBox(height: 3),
                        Text(
                          metric.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            color: Theme.of(context).textTheme.bodyLarge?.color,
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
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 2.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            offset: Offset(4, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 18, color: Theme.of(context).colorScheme.outline),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.outline,
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
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
        border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
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
  }) {
    final color = positive
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: (Theme.of(context).cardColor),
        border: Border.all(color: Theme.of(context).dividerColor),
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
                      color: Theme.of(context).dividerColor),
                ),
                SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.outline),
                ),
              ],
            ),
          ),
          SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              trailing,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 13, color: color),
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
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Theme.of(context).dividerColor),
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
                      color: Theme.of(context).dividerColor),
                ),
                SizedBox(height: 3),
                Text(
                  subtitleParts.join(' - '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.outline),
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
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Theme.of(context).dividerColor),
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
                      color: Theme.of(context).dividerColor),
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
                      color: Theme.of(context).colorScheme.outline),
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
    final expenseId = _expenseId(row);
    final canEditExpense = _isUuid(expenseId) && !_isSyntheticExpenseRow(row);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: (Theme.of(context).cardColor),
        border: Border.all(color: Theme.of(context).dividerColor),
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
                      color: Theme.of(context).dividerColor),
                ),
                SizedBox(height: 3),
                Text(
                  '${_date(row['paid_at'] ?? row['expense_date'] ?? row['created_at'])}  ·  ${_text(row['note'], 'Tanpa catatan')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.outline),
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
                          () => _editManualExpense(row)),
                      _tinyActionButton(Icons.delete_outline_rounded, 'Hapus',
                          () => _deleteManualExpense(row),
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
      borderRadius: BorderRadius.zero,
      child: InkWell(
        onTap: _processing ? null : onTap,
        borderRadius: BorderRadius.zero,
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
        borderRadius: BorderRadius.zero,
        color: (Theme.of(context).cardColor),
        border: Border.all(color: Theme.of(context).dividerColor),
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
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).dividerColor),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11.5, color: Theme.of(context).colorScheme.outline),
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
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
                          fontWeight: FontWeight.w900,
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
    return _text(
      row['order_status'] ??
          row['status_order'] ??
          row['live_order_status'] ??
          row['raw_order_status'] ??
          row['status'],
      '-',
    ).trim();
  }

  bool _skuDetailNeedsMarketplaceRefreshV82o(Map<String, dynamic> row) {
    if (_skuOrderDetailPayoutValueV82o(row) <= 0) return false;
    final status = _skuDetailOrderStatusV82o(row).toUpperCase();
    if (status.isEmpty || status == '-') return false;
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.10),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: Colors.orange.withOpacity(0.35)),
      ),
      child: Text(
        'Payout sudah masuk, tetapi status order masih $status. Perlu refresh marketplace.',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
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

    final payout = _skuOrderDetailPayoutValueV82o(copy);
    copy['payout'] = payout;
    copy['payout_amount'] = payout;

    final payoutPerItem = _skuOrderDetailPayoutPerItemValueV82o(copy);
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

    if (joinedStatus.contains('CANCEL') ||
        joinedStatus.contains('REFUND') ||
        joinedStatus.contains('RETURN')) {
      return false;
    }

    if (payout != 0) return true;

    return financeStatus.contains('SETTLED') ||
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

    if (joinedStatus.contains('CANCEL') ||
        joinedStatus.contains('REFUND') ||
        joinedStatus.contains('RETURN')) {
      return false;
    }

    if (payout != 0) return false;

    return financeStatus.contains('BELUM') ||
        financeStatus.contains('PENDING') ||
        financeStatus.contains('UNPAID') ||
        financeStatus.contains('MISSING') ||
        financeStatus.trim().isEmpty;
  }

  List<Map<String, dynamic>> _filteredSkuOrderRowsV82o(
      List<Map<String, dynamic>> rows, String payoutFilter) {
    final normalized = rows
        .map(_normalizeSkuOrderDetailDisplayRowV82o)
        .toList(growable: false);

    if (payoutFilter == 'paid') {
      return normalized.where(_skuDetailHasPayoutV82o).toList();
    }

    if (payoutFilter == 'unpaid') {
      return normalized.where(_skuDetailIsPendingPayoutV82o).toList();
    }

    return normalized;
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

  String? _marketplaceRpcParam() {
    final value = _text(_marketplaceParam(), '').trim();
    if (value.isEmpty || value.toLowerCase() == 'all') return null;
    return value;
  }

  Map<String, String> _skuOrderLookupParamsV82o(Map<String, dynamic> row) {
    final productSearch = _text(
      row['product_name'] ??
          row['nama_barang'] ??
          row['title'] ??
          row['marketplace_product_name'] ??
          row['product_title'],
      '',
    ).trim();

    final variantSearch = _text(
      row['variant_name'] ??
          row['marketplace_variation_name'] ??
          row['variation_name'],
      '',
    ).trim();

    final marketplaceSku = _text(
      row['marketplace_sku_id'] ??
          row['marketplace_sku'] ??
          row['marketplace_seller_sku'] ??
          row['seller_sku'] ??
          row['sku_marketplace'] ??
          row['external_sku_id'] ??
          row['sku_id'],
      '',
    ).trim();

    final explicitLocalSku = _text(
      row['local_sku'] ??
          row['product_sku'] ??
          row['local_product_sku'] ??
          row['mapped_local_sku'],
      '',
    ).trim();

    final rowSku = _text(row['sku'], '').trim();
    final localSku = explicitLocalSku.isNotEmpty
        ? explicitLocalSku
        : (rowSku.isNotEmpty &&
                rowSku != '-' &&
                rowSku.toLowerCase() != productSearch.toLowerCase()
            ? rowSku
            : '');

    final fallbackSearch = productSearch.isNotEmpty
        ? productSearch
        : (variantSearch.isNotEmpty ? variantSearch : '');

    return {
      'marketplace_sku': marketplaceSku,
      'local_sku': localSku,
      'fallback_search': fallbackSearch,
    };
  }

  String _canonicalSkuPayoutFilterV82o(String value) {
    final clean = value.trim().toLowerCase().replaceAll('_', ' ');
    if (clean == 'settled' ||
        clean == 'released' ||
        clean == 'release' ||
        clean == 'payout' ||
        clean == 'paid payout' ||
        clean == 'sudah payout') {
      return 'paid';
    }
    if (clean == 'pending' ||
        clean == 'belum payout' ||
        clean == 'no payout' ||
        clean == 'missing payout') {
      return 'unpaid';
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
    int pageSize = 100,
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

    final response = await _client.rpc(
      'finance_sku_order_details',
      params: {
        'p_start': _toDateParam(_start),
        'p_end': _toDateParam(_end),
        'p_marketplace': _marketplaceRpcParam(),
        'p_account_id': _accountUuidParam(),
        'p_marketplace_sku': marketplaceSku.isEmpty ? null : marketplaceSku,
        'p_local_sku': localSku.isEmpty || localSku == '-' ? null : localSku,
        'p_search': searchText.isEmpty ? null : searchText,
        'p_payout_filter': rpcPayoutFilter,
        'p_page': page,
        'p_page_size': pageSize,
      },
    );

    final rawRows = _extractSkuOrderDetailRowsV82o(response);
    final rows = _filteredSkuOrderRowsV82o(
      rawRows
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(),
      payoutFilter,
    );
    final total = _skuDetailTotalV82o(response, rows.length);
    final resolvedPage = _skuDetailPageV82o(response, page);
    final resolvedPageSize = _skuDetailPageSizeV82o(response, pageSize);
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

  Future<List<Map<String, dynamic>>> _fetchSkuOrderDetailsV82oForRow(
      Map<String, dynamic> row, String payoutFilter) async {
    try {
      final result = await _fetchSkuOrderDetailsV82oPageForRow(
        row,
        payoutFilter,
        page: 1,
        pageSize: 100,
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

  Future<void> _showSkuOrderRefsV82o(Map<String, dynamic> row,
      {String payoutFilter = 'all'}) async {
    final payoutLabel = payoutFilter == 'paid'
        ? 'sudah ada payout'
        : payoutFilter == 'unpaid'
            ? 'belum ada payout'
            : 'semua status payout';

    Map<String, dynamic> pageResult;
    try {
      pageResult = await _fetchSkuOrderDetailsV82oPageForRow(
        row,
        payoutFilter,
        page: 1,
        pageSize: 100,
      );
    } catch (error) {
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
    var pageSize = _positiveIntV82o(pageResult['page_size'], 100);
    var total = _intFromV82o(pageResult['total'], rows.length);
    var totalPages = _positiveIntV82o(pageResult['total_pages'], 1);

    if (rows.isEmpty && total <= 0) {
      _setMessage(
          'Detail order SKU ($payoutLabel) belum ditemukan dari server.');
      return;
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
          pageSize: 100,
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
          pageSize = _positiveIntV82o(result['page_size'], 100);
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
        backgroundColor: (Theme.of(context).cardColor),
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
                                      fontWeight: FontWeight.w900,
                                      color: Theme.of(context).dividerColor),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  '${_text(detailRow['product_name'] ?? detailRow['nama_barang'], 'Produk')} · $pageSummary · $payoutLabel',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: Icon(Icons.close_rounded,
                                color: Theme.of(context).dividerColor),
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
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: IconButton(
                            tooltip: 'Cari',
                            onPressed: loadingPage
                                ? null
                                : () => loadPage(
                                      1,
                                      searchController.text,
                                      setSheetState,
                                    ),
                            icon: const Icon(Icons.search),
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
                                  color: Theme.of(context).colorScheme.outline),
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
                            icon: const Icon(Icons.chevron_left_rounded),
                            label: const Text('Sebelumnya'),
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
                            icon: const Icon(Icons.chevron_right_rounded),
                            label: const Text('Berikutnya'),
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
                                              borderRadius: BorderRadius.zero,
                                              border: Border.all(
                                                  color: Theme.of(context)
                                                      .dividerColor
                                                      .withOpacity(0.75)),
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
                                                        .withOpacity(0.10),
                                                    borderRadius:
                                                        BorderRadius.zero,
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
                                                        'Order: ${_text(item['order'], '-')}',
                                                        style: TextStyle(
                                                            fontSize: 13.5,
                                                            fontWeight:
                                                                FontWeight.w900,
                                                            color: Theme.of(
                                                                    context)
                                                                .dividerColor),
                                                      ),
                                                      SizedBox(height: 4),
                                                      SelectableText(
                                                        'Resi: ${_text(item['resi'], '-')}',
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .outline,
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
                                                                .outline,
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
                                                                .outline,
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
                                                        'SKU lokal: ${_text(item['local_sku'], _text(detailRow['local_sku'] ?? detailRow['sku'], '-'))}  ·  SKU marketplace: ${_text(item['marketplace_sku'] ?? item['marketplace_seller_sku'], '-')}  ·  Varian: ${_text(item['variant_name'] ?? item['marketplace_variation_name'], '-')}',
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .outline,
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
                                                              _money(_num(item[
                                                                  'gross_per_item']))),
                                                          _miniMetric(
                                                              'Payout/item',
                                                              _moneyNullable(item[
                                                                  'payout_per_item'])),
                                                          _miniMetric(
                                                              'HPP/item',
                                                              _money(_num(item[
                                                                      'hpp_per_item'] ??
                                                                  item[
                                                                      'hpp']))),
                                                        ],
                                                      ),
                                                      SizedBox(height: 6),
                                                      Text(
                                                        'Statement: ${_text(item['statement_id'], '-')}  ·   ${_text(item['source'], '-')}',
                                                        style: TextStyle(
                                                            fontSize: 10.5,
                                                            color: Theme.of(
                                                                    context)
                                                                .colorScheme
                                                                .outline,
                                                            height: 1.3),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip: 'Salin',
                                                  onPressed: () {
                                                    final text = [
                                                      'Order: ${_text(item['order'], '-')}',
                                                      'Resi: ${_text(item['resi'], '-')}',
                                                      'Tanggal pesanan: ${_dateTime(item['order_date'])}',
                                                      'Status: ${_skuDetailOrderStatusV82o(item)}',
                                                      'Payout status: ${_payoutStatusText(item)}',
                                                      'Catatan payout: ${_payoutExplainText(item).trim().isEmpty ? '-' : _payoutExplainText(item)}',
                                                      'Catatan resi: ${_text(item['resi_reason'], '-')}',
                                                      'SKU lokal: ${_text(item['local_sku'], _text(detailRow['local_sku'] ?? detailRow['sku'], '-'))}',
                                                      'SKU marketplace: ${_text(item['marketplace_sku'] ?? item['marketplace_seller_sku'], '-')}',
                                                      'Varian: ${_text(item['variant_name'] ?? item['marketplace_variation_name'], '-')}',
                                                      'Qty: ${_num(item['qty']).toStringAsFixed(0)}',
                                                      'Harga jual/item: ${_money(_num(item['gross_per_item']))}',
                                                      'Payout/item: ${_moneyNullable(item['payout_per_item'])}',
                                                      'HPP/item: ${_money(_num(item['hpp_per_item'] ?? item['hpp']))}',
                                                      'Statement: ${_text(item['statement_id'], '-')}',
                                                      ' ${_text(item['source'], '-')}',
                                                      if (_skuDetailNeedsMarketplaceRefreshV82o(
                                                          item))
                                                        'Warning: Payout sudah masuk, tetapi status order masih ${_skuDetailOrderStatusV82o(item)}. Perlu refresh marketplace.',
                                                    ].join('\n');
                                                    Clipboard.setData(
                                                        ClipboardData(
                                                            text: text));
                                                    ScaffoldMessenger.of(
                                                            sheetContext)
                                                        .showSnackBar(
                                                            const SnackBar(
                                                                content: Text(
                                                                    'Detail order disalin.')));
                                                  },
                                                  icon: Icon(Icons.copy_rounded,
                                                      size: 18,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .outline),
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
                                                .withOpacity(0.55),
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
                                    fontWeight: FontWeight.w900,
                                    color: Theme.of(context).dividerColor),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '${_text(detailRow['product_name'] ?? detailRow['nama_barang'], 'Produk')} · ${allRows.length} detail order SKU · $payoutLabel',
                                style: TextStyle(
                                    fontSize: 12,
                                    color:
                                        Theme.of(context).colorScheme.outline),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: Icon(Icons.close_rounded,
                              color: Theme.of(context).dividerColor),
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
                                    color: (Theme.of(context).cardColor),
                                    borderRadius: BorderRadius.zero,
                                    border: Border.all(
                                        color: Theme.of(context)
                                            .dividerColor
                                            .withOpacity(0.75)),
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
                                              .withOpacity(0.10),
                                          borderRadius: BorderRadius.zero,
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
                                              'Order: ${_text(item['order'], '-')}',
                                              style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w900,
                                                  color: Theme.of(context)
                                                      .dividerColor),
                                            ),
                                            SizedBox(height: 4),
                                            SelectableText(
                                              'Resi: ${_text(item['resi'], '-')}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .outline,
                                                  height: 1.35),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Tanggal pesanan: ${_dateTime(item['order_date'])}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .outline,
                                                  height: 1.35),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Status: ${_text(item['order_status'], '-')}  ·  Payout: ${_payoutStatusText(item)}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .outline,
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
                                              'SKU lokal: ${_text(item['local_sku'], _text(detailRow['local_sku'] ?? detailRow['sku'], '-'))}  ·  SKU marketplace: ${_text(item['marketplace_sku'] ?? item['marketplace_seller_sku'], '-')}  ·  Varian: ${_text(item['variant_name'] ?? item['marketplace_variation_name'], '-')}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .outline,
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
                                                    _money(_num(item[
                                                        'gross_per_item']))),
                                                _miniMetric(
                                                    'Payout/item',
                                                    _moneyNullable(item[
                                                        'payout_per_item'])),
                                                _miniMetric(
                                                    'HPP/item',
                                                    _money(_num(
                                                        item['hpp_per_item'] ??
                                                            item['hpp']))),
                                              ],
                                            ),
                                            SizedBox(height: 6),
                                            Text(
                                              'Statement: ${_text(item['statement_id'], '-')}  ·   ${_text(item['source'], '-')}',
                                              style: TextStyle(
                                                  fontSize: 10.5,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .outline,
                                                  height: 1.3),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Salin',
                                        onPressed: () {
                                          final text = [
                                            'Order: ${_text(item['order'], '-')}',
                                            'Resi: ${_text(item['resi'], '-')}',
                                            'Tanggal pesanan: ${_dateTime(item['order_date'])}',
                                            'Status: ${_text(item['order_status'], '-')}',
                                            'Payout status: ${_payoutStatusText(item)}',
                                            'Catatan payout: ${_payoutExplainText(item).trim().isEmpty ? '-' : _payoutExplainText(item)}',
                                            'Catatan resi: ${_text(item['resi_reason'], '-')}',
                                            'SKU lokal: ${_text(item['local_sku'], _text(detailRow['local_sku'] ?? detailRow['sku'], '-'))}',
                                            'SKU marketplace: ${_text(item['marketplace_sku'] ?? item['marketplace_seller_sku'], '-')}',
                                            'Varian: ${_text(item['variant_name'] ?? item['marketplace_variation_name'], '-')}',
                                            'Qty: ${_num(item['qty']).toStringAsFixed(0)}',
                                            'Harga jual/item: ${_money(_num(item['gross_per_item']))}',
                                            'Payout/item: ${_moneyNullable(item['payout_per_item'])}',
                                            'HPP/item: ${_money(_num(item['hpp_per_item'] ?? item['hpp']))}',
                                            'Statement: ${_text(item['statement_id'], '-')}',
                                            ' ${_text(item['source'], '-')}',
                                          ].join('\n');
                                          Clipboard.setData(
                                              ClipboardData(text: text));
                                          ScaffoldMessenger.of(sheetContext)
                                              .showSnackBar(const SnackBar(
                                                  content: Text(
                                                      'Detail order disalin.')));
                                        },
                                        icon: Icon(Icons.copy_rounded,
                                            size: 18,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .outline),
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
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: warning ? color : Theme.of(context).dividerColor,
            ),
          ),
        ],
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
            borderRadius: BorderRadius.zero,
            color: (Theme.of(context).cardColor),
            border: Border.all(
                color: Theme.of(context).colorScheme.error.withOpacity(0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error.withOpacity(0.10),
                  borderRadius: BorderRadius.zero,
                  border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .error
                          .withOpacity(0.25)),
                ),
                child: Icon(Icons.error_outline_rounded,
                    size: 28, color: Theme.of(context).colorScheme.error),
              ),
              SizedBox(height: 16),
              Text(
                'Laporan gagal dimuat',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: Theme.of(context).dividerColor),
              ),
              SizedBox(height: 8),
              Text(
                _error ?? '-',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.outline,
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
      row['id'],
      row['finance_expense_id'],
      row['operational_expense_id'],
    ];
    for (final value in datas) {
      final text = value?.toString().trim() ?? '';
      if (_isUuid(text)) return text;
    }
    return '';
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
          status.contains('RETURN');
    }

    if (payoutFilter == 'paid') {
      return rows
          .where(
              (item) => !isCancelRefundReturn(item) && _hasReleasedPayout(item))
          .toList();
    }

    if (payoutFilter == 'unpaid') {
      return rows
          .where((item) =>
              !isCancelRefundReturn(item) && !_hasReleasedPayout(item))
          .toList();
    }

    return rows;
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
        joinedStatus.contains('RETURN')) {
      return false;
    }

    final payout = _linePayoutAmount(detail);
    if (payout != 0) return true;

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
    if (explicit.isNotEmpty && explicit != '-') return explicit;
    if (payout < 0) return 'payout minus/koreksi';
    if (payout > 0) return 'sudah release';
    if (_hasReleasedPayout(detail)) return 'sudah release Rp 0';
    return 'belum ada payout';
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
        text.contains('CANCELLED');
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
    final date = _parseDate(value);
    if (date == null) return '-';
    return '${_date(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value.toLocal();
    return DateTime.tryParse(value.toString())?.toLocal();
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
          title: const Text('Pilih bulan'),
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
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          '$year',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Tahun berikutnya',
                      onPressed: () => setDialogState(() => year++),
                      icon: const Icon(Icons.chevron_right_rounded),
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
                        foregroundColor: selected ? Colors.black : null,
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
                onPressed: () => Navigator.pop(context),
                child: const Text('Batal')),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, DateTime(year, selectedMonth, 1)),
              child: const Text('Pilih'),
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
