import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../../core/theme/app_theme_mode.dart';
import '../../../core/constants/app_roles.dart';
import '../../subscription/services/tenant_entitlement_service.dart';
import '../../subscription/presentation/feature_gate_page.dart';
import '../../../models/app_user.dart';

import '../../attendance/presentation/attendance_page.dart';
import '../../auth/presentation/login_page.dart';
import '../../admin/presentation/user_management_page.dart';
import '../../admin/presentation/data_export_import_page.dart';
import '../../admin/presentation/audit_log_page.dart';
import '../../content/presentation/content_monitoring_page.dart';
import '../../finance/presentation/finance_report_page.dart';
import '../../finance/services/finance_local_cache.dart';
import '../../finance/presentation/purchase_verification_page.dart';
import '../../host_live/presentation/host_live_page.dart';
import '../../hr/presentation/hr_performance_page.dart';
import '../../marketplace/presentation/marketplace_accounts_page.dart';
import '../../marketplace/presentation/marketplace_orders_page.dart';
import '../../marketplace/presentation/marketplace_job_monitor_page.dart';
import '../../marketplace/presentation/marketplace_refund_monitor_page.dart';
import '../../marketplace/presentation/marketplace_sku_mapping_page.dart';
import '../../marketplace/presentation/marketplace_stock_difference_page.dart';
import '../../marketplace/presentation/marketplace_stock_sync_page.dart';
import '../../marketplace/presentation/marketplace_stock_out_review_page.dart';
import '../../master_data/presentation/work_location_page.dart';
import '../../production/presentation/purchase_request_page.dart';
import '../../production/presentation/stock_progress_page.dart';
import '../../stock/presentation/product_list_page.dart';
import '../../stock/presentation/stock_history_page.dart';
import '../../stock/presentation/stock_in_page.dart';
import '../../stock/presentation/stock_out_page.dart';
import '../../stock/presentation/low_stock_page.dart';
import '../../supplier/presentation/supplier_page.dart';
import '../../tasks/presentation/task_page.dart';

class DashboardPage extends StatefulWidget {
  final AppUser? currentUser;

  const DashboardPage({
    super.key,
    this.currentUser,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _client = Supabase.instance.client;
  bool _loading = true;
  AppUser? _appUser;
  _CurrentUser? _user;
  int _todayStockOut = 0;
  int _todayStockIn = 0;
  int _activeProducts = 0;
  int _lowStock = 0;
  int _pendingPurchase = 0;
  int _runningProduction = 0;
  int _todayAttendance = 0;
  int _myOpenTasks = 0;
  int _allOpenTasks = 0;
  int _myTodayLive = 0;
  int _pendingLiveReview = 0;
  int _financeAbnormalCount = 0;
  num _financeNetProfit = 0;
  num _financeOmzet = 0;
  int _financeOrderCount = 0;
  List<_TrendPoint> _financeTrend = const <_TrendPoint>[];
  int? _selectedTrendIndex;
  String _dashboardFinanceMarketplaceFilter = 'all';
  List<_AppNotification> _notifications = const <_AppNotification>[];
  int _contentTotal = 0;
  int _contentDueSoon = 0;
  int _lateAttendance = 0;
  int _absentAttendance = 0;
  String _myAttendanceLabel = 'Belum';
  _TenantSubscriptionInfo? _tenantSubscriptionInfo;
  TenantEntitlementSnapshot? _entitlement;

  String get _role =>
      (_appUser?.role.roleId ?? _user?.role ?? '').trim().toLowerCase();
  bool get _isAdmin =>
      AppRolePermissions.isSuperRoleId(_role) || _isDemoSuperAdmin;
  bool get _isOperationalAdmin => AppRolePermissions.isAdminRoleId(_role);
  bool get _isManagementRole =>
      _isAdmin || _isOperationalAdmin || _role == 'hr';
  bool get _canOpenSuperSettings =>
      AppRolePermissions.canOpenSuperSettings(_role);
  bool get _isPlatformOwner =>
      AppRolePermissions.isPlatformOwnerId(_role) ||
      (_entitlement?.isPlatformOwner ?? false);
  bool _planHasFeature(String featureKey) {
    if (_isPlatformOwner) return true;
    return _entitlement?.isFeatureEnabled(featureKey) == true;
  }

  bool get _canAccessFinance =>
      AppRolePermissions.canAccessFinance(_role) &&
      _planHasFeature('finance_basic');
  bool get _isDemoSuperAdmin => AppRolePermissions.isDemoSuperAdminId(_role);
  bool get _isFinance => _role == 'finance';
  bool get _isWarehouse => _role == 'warehouse';
  int get _activeNotificationCount => _notifications
      .where((item) => item.status.toLowerCase() == 'active')
      .length;

  AppUser get _requiredAppUser {
    final existing = _appUser;
    if (existing != null) return existing;

    final authUser = _client.auth.currentUser;
    final role = _role.isEmpty ? 'unassigned' : _role;
    return AppUser.fromMap({
      'user_id': authUser?.id ?? '',
      'nama': _user?.name ?? authUser?.email ?? '-',
      'email': _user?.email ?? authUser?.email ?? '-',
      'role_id': role,
      'status': _user?.active == false ? 'inactive' : 'active',
      'tenant_id': '',
    });
  }

  @override
  void initState() {
    super.initState();
    _loadDashboard();
  }

  Future<void> _loadDashboard() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final authUser = _client.auth.currentUser;
      if (authUser == null) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (_) => false,
        );
        return;
      }

      AppUser? appUser = widget.currentUser;
      Map<String, dynamic>? profile;
      if (appUser == null) {
        final rawProfile = await _client
            .from('users')
            .select(
                'user_id, email, nama, role_id, status, nomor_hp, tenant_id')
            .eq('user_id', authUser.id)
            .maybeSingle();
        if (rawProfile != null) {
          profile = Map<String, dynamic>.from(rawProfile as Map);
          appUser = AppUser.fromMap(profile);
        }
      }

      final entitlement = await TenantEntitlementService(_client).load();

      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day).toIso8601String();
      final end = DateTime(now.year, now.month, now.day + 1).toIso8601String();
      final todayDate =
          "${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

      final results = await Future.wait<List<dynamic>>([
        _safeList(() => _client
            .from('stock_transactions')
            .select('stock_transaction_id')
            .eq('transaction_type', 'OUT')
            .gte('created_at', start)
            .lt('created_at', end)),
        _safeList(() => _client
            .from('stock_transactions')
            .select('stock_transaction_id')
            .eq('transaction_type', 'IN')
            .gte('created_at', start)
            .lt('created_at', end)),
        _safeList(() => _client
            .from('products')
            .select('product_id, stock_saat_ini, low_stock_limit, status')
            .eq('status', 'active')),
        _safeList(() => _client
                .from('purchases')
                .select('purchase_id')
                .inFilter('status', [
              'draft',
              'submitted',
              'pending',
              'revision',
              'revision_requested'
            ])),
        _safeList(() => _client
            .from('production_progress')
            .select('progress_id')
            .inFilter('status', ['progress', 'in_progress', 'pending'])),
        _safeList(() => _client
            .from('attendance')
            .select(
                'attendance_id, user_id, date, status, check_in_time, check_out_time')
            .eq('date', todayDate)),
        _safeList(() => _client
            .from('tasks')
            .select('task_id, assigned_to, status')
            .inFilter(
                'status', ['assigned', 'on_progress', 'done', 'rejected'])),
        _safeList(() => _client
            .from('live_schedules')
            .select('live_schedule_id, user_id, status, tanggal')
            .eq('tanggal', todayDate)),
        _safeList(() => _client
            .from('content_tasks')
            .select(
                'content_task_id, assigned_to, status, deadline, deadline_date, due_date')
            .inFilter(
                'status', ['planned', 'in_progress', 'uploaded', 'revision'])),
      ]);

      final products = results[2]
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final lowStock = products.where((product) {
        final stock = AppUi.toNum(product['stock_saat_ini']);
        final min = AppUi.toNum(product['low_stock_limit']);
        return min > 0 && stock <= min;
      }).length;

      final authUserId = authUser.id;
      final attendanceRows = results[5]
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final tasks = results[6]
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final liveSchedules = results[7]
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final contentRows = results.length > 8
          ? results[8]
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
          : <Map<String, dynamic>>[];
      final roleId = (appUser?.role.roleId ?? AppUi.text(profile?['role_id']))
          .trim()
          .toLowerCase();
      final isManagementRole =
          AppRolePermissions.canManageOperationalWork(roleId) ||
              roleId == 'finance';
      final tenantSubscriptionInfo = await _safeTenantSubscriptionInfo(
          appUser?.tenantId ?? profile?['tenant_id']);
      final canLoadFinanceSummary =
          AppRolePermissions.isPlatformOwnerId(roleId) ||
              (AppRolePermissions.canAccessFinance(roleId) &&
                  entitlement.isFeatureEnabled('finance_basic'));
      final financeSummary = canLoadFinanceSummary
          ? await _safeFinanceSummary(now)
          : <String, dynamic>{};
      final notifications = _withLowStockNotificationFallback(
        await _safeNotifications(),
        roleId: roleId,
        lowStockCount: lowStock,
      );
      final taskOpenStatuses = {'assigned', 'on_progress', 'rejected'};
      final taskReviewStatuses = {
        'assigned',
        'on_progress',
        'done',
        'rejected'
      };
      final myAttendanceRows = attendanceRows
          .where((item) => item['user_id']?.toString() == authUserId)
          .toList();
      final myAttendanceLabel =
          myAttendanceRows.any((item) => item['check_out_time'] != null)
              ? 'Pulang'
              : myAttendanceRows.any((item) => item['check_in_time'] != null)
                  ? 'Masuk'
                  : 'Belum';
      final lateAttendance = attendanceRows
          .where((item) => AppUi.text(item['status']).toLowerCase() == 'late')
          .length;
      final absentAttendance = attendanceRows
          .where((item) => AppUi.text(item['status']).toLowerCase() == 'absent')
          .length;
      final myContentRows = contentRows.where((item) {
        if (isManagementRole) return true;
        return item['assigned_to']?.toString() == authUserId;
      }).toList();
      final todayOnly = DateTime(now.year, now.month, now.day);
      final soonLimit = todayOnly.add(const Duration(days: 3));
      final contentDueSoon = myContentRows.where((item) {
        final raw = AppUi.text(
            item['deadline_date'] ?? item['deadline'] ?? item['due_date']);
        if (raw.trim().isEmpty) return false;
        final due =
            DateTime.tryParse(raw.length >= 10 ? raw.substring(0, 10) : raw);
        if (due == null) return false;
        return !due.isBefore(todayOnly) && !due.isAfter(soonLimit);
      }).length;
      final myOpenTasks = tasks.where((task) {
        final status = (task['status'] ?? '').toString().toLowerCase();
        return task['assigned_to']?.toString() == authUserId &&
            taskOpenStatuses.contains(status);
      }).length;
      final allOpenTasks = tasks.where((task) {
        final status = (task['status'] ?? '').toString().toLowerCase();
        return taskReviewStatuses.contains(status);
      }).length;
      final myTodayLive = liveSchedules
          .where((item) => item['user_id']?.toString() == authUserId)
          .length;
      final pendingLiveReview = liveSchedules.where((item) {
        final status = (item['status'] ?? '').toString().toLowerCase();
        return status == 'finished' ||
            status == 'live_started' ||
            status == 'scheduled';
      }).length;

      if (!mounted) return;
      setState(() {
        _appUser = appUser;
        _user = appUser != null
            ? _CurrentUser.fromAppUser(appUser)
            : _CurrentUser.fromMap(
                profile ?? <String, dynamic>{}, authUser.email ?? '-');
        _todayStockOut = results[0].length;
        _todayStockIn = results[1].length;
        _activeProducts = products.length;
        _lowStock = lowStock;
        _pendingPurchase = results[3].length;
        _runningProduction = results[4].length;
        _todayAttendance = attendanceRows.length;
        _myOpenTasks = myOpenTasks;
        _allOpenTasks = allOpenTasks;
        _myTodayLive = myTodayLive;
        _pendingLiveReview = pendingLiveReview;
        _financeAbnormalCount = AppUi.toNum(financeSummary['abnormal_count'] ??
                financeSummary['anomaly_count'])
            .toInt();
        _financeNetProfit = AppUi.toNum(financeSummary['net_profit']);
        _financeOmzet = AppUi.toNum(financeSummary['omzet_total']);
        _financeOrderCount =
            AppUi.toNum(financeSummary['orders_count']).toInt();
        _financeTrend = (financeSummary['trend'] as List<_TrendPoint>?) ??
            const <_TrendPoint>[];
        _notifications = notifications;
        _contentTotal = myContentRows.length;
        _contentDueSoon = contentDueSoon;
        _lateAttendance = lateAttendance;
        _absentAttendance = absentAttendance;
        _myAttendanceLabel = myAttendanceLabel;
        _tenantSubscriptionInfo = tenantSubscriptionInfo;
        _entitlement = entitlement;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppUi.safeSnack(context, 'Dashboard gagal dimuat: $e');
    }
  }

  String _ymd(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _safeRawFinanceSummary(DateTime now,
      {String? marketplaceFilter}) async {
    final startDate = _ymd(DateTime(now.year, now.month, 1));
    final endDate = _ymd(now);
    final marketplaceFilter = _dashboardFinanceMarketplaceParam();
    try {
      dynamic query = _client
          .from('marketplace_finance_reports')
          .select(
              'finance_report_id, order_id, marketplace_order_id, marketplace, period_start, gross_amount, gross_sales, payout_amount, received_amount, net_settlement, total_hpp')
          .gte('period_start', startDate)
          .lte('period_start', endDate);

      final cleanMarketplace = marketplaceFilter?.trim().toLowerCase();
      if (cleanMarketplace == 'shopee') {
        query = query.eq('marketplace', 'shopee');
      } else if (cleanMarketplace == 'tiktok') {
        query = query.inFilter('marketplace', ['tiktok', 'tiktok_shop']);
      }

      final response = await query.limit(10000);
      final rows = response is List
          ? response
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      if (rows.isEmpty) return <String, dynamic>{};

      final orderKeys = <String>{};
      final daily = <String, Map<String, dynamic>>{};
      var gross = 0.0;
      var payout = 0.0;
      var hpp = 0.0;
      var negativeCount = 0;
      var negativeAbs = 0.0;

      for (final row in rows) {
        final orderKey =
            AppUi.text(row['order_id'] ?? row['marketplace_order_id']);
        if (orderKey.trim().isNotEmpty) orderKeys.add(orderKey);
        final rowGross = AppUi.toNum(row['gross_amount'] ?? row['gross_sales']);
        final rowPayout = AppUi.toNum(row['payout_amount'] ??
            row['received_amount'] ??
            row['net_settlement']);
        final rowHpp = AppUi.toNum(row['total_hpp']);
        gross += rowGross;
        payout += rowPayout;
        hpp += rowHpp;
        if (rowPayout < 0) {
          negativeCount += 1;
          negativeAbs += rowPayout.abs();
        }

        final rawDate = AppUi.text(row['period_start']);
        if (rawDate.trim().isEmpty) continue;
        final dateKey =
            rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
        final bucket = daily.putIfAbsent(
            dateKey,
            () => <String, dynamic>{
                  'date': dateKey,
                  'gross': 0.0,
                  'orders': <String>{},
                });
        bucket['gross'] = AppUi.toNum(bucket['gross']) + rowGross;
        if (orderKey.trim().isNotEmpty) {
          (bucket['orders'] as Set<String>).add(orderKey);
        }
      }

      final trend = daily.entries.map((entry) {
        final date = DateTime.tryParse(entry.key) ??
            DateTime(now.year, now.month, now.day);
        final orders = entry.value['orders'] is Set<String>
            ? (entry.value['orders'] as Set<String>).length
            : 0;
        return _TrendPoint(
          date: date,
          omzet: AppUi.toNum(entry.value['gross']),
          orders: orders,
        );
      }).toList()
        ..sort((a, b) => a.date.compareTo(b.date));

      final orders = orderKeys.length;
      return <String, dynamic>{
        'abnormal_count': negativeCount,
        'anomaly_count': negativeCount,
        'negative_payout_total_abs': negativeAbs,
        'payout_minus_total_abs': negativeAbs,
        'minus_payout_total_abs': negativeAbs,
        'net_profit': payout - hpp,
        'omzet_total': gross,
        'orders_count': orders,
        'trend': _monthToDateTrend(now, trend),
      };
    } catch (e) {
      debugPrint('Dashboard raw finance summary failed: $e');
      return <String, dynamic>{};
    }
  }

  static const int _dashboardOrderAnalyticsDays = 90;

  Map<String, dynamic> _dashboardOrderAnalyticsFromRpc(
    DateTime now,
    Map<String, dynamic> data,
  ) {
    if (data.isEmpty || data['ok'] == false) return <String, dynamic>{};

    final summary = _asMap(data['summary']);
    final rawDaily = data['daily'] is List ? data['daily'] as List : const [];
    final points = <_TrendPoint>[];

    for (final item in rawDaily) {
      final row = _asMap(item);
      final dateText = AppUi.text(
        row['date'] ?? row['report_date'] ?? row['order_date'],
        '',
      );
      if (dateText.isEmpty) continue;

      final date = DateTime.tryParse(
        dateText.length >= 10 ? dateText.substring(0, 10) : dateText,
      );
      if (date == null) continue;

      points.add(
        _TrendPoint(
          date: date,
          omzet: AppUi.toNum(
            row['omzet_total'] ??
                row['gross_sales'] ??
                row['gross_total'] ??
                row['amount'],
          ),
          orders: AppUi.toNum(
            row['orders_count'] ?? row['order_count'] ?? row['orders'],
          ).toInt(),
        ),
      );
    }

    points.sort((a, b) => a.date.compareTo(b.date));

    final omzet = AppUi.toNum(
      summary['omzet_total'] ??
          summary['gross_sales'] ??
          summary['gross_total'] ??
          data['omzet_total'],
    );
    final orders = AppUi.toNum(
      summary['orders_count'] ?? summary['order_count'] ?? data['orders_count'],
    ).toInt();

    if (omzet <= 0 && orders <= 0 && points.every((p) => p.orders <= 0)) {
      return <String, dynamic>{};
    }

    return <String, dynamic>{
      'abnormal_count': 0,
      'anomaly_count': 0,
      'net_profit': 0,
      'omzet_total': omzet,
      'orders_count': orders,
      'trend': points,
      'source_rpc': 'dashboard_marketplace_order_analytics_90d',
    };
  }

  Future<Map<String, dynamic>> _safeDashboardOrderAnalytics90d(
    DateTime now, {
    String? marketplaceFilter,
  }) async {
    try {
      final response = await _client.rpc(
        'dashboard_marketplace_order_analytics_90d',
        params: {
          'p_marketplace': marketplaceFilter,
          'p_days': _dashboardOrderAnalyticsDays,
        },
      );
      final parsed = _dashboardOrderAnalyticsFromRpc(now, _asMap(response));
      if (_dashboardFinanceSummaryUsable(parsed)) return parsed;
    } catch (error) {
      debugPrint('Dashboard marketplace order analytics RPC failed: $error');
    }

    return <String, dynamic>{};
  }

  Map<String, dynamic> _mergeDashboardOrderAnalytics(
    Map<String, dynamic> base,
    Map<String, dynamic> orderAnalytics,
  ) {
    if (!_dashboardFinanceSummaryUsable(orderAnalytics)) {
      return base;
    }

    final out = Map<String, dynamic>.from(base);
    out['abnormal_count'] = out['abnormal_count'] ?? 0;
    out['anomaly_count'] = out['anomaly_count'] ?? out['abnormal_count'] ?? 0;
    out['net_profit'] = out['net_profit'] ?? 0;
    out['omzet_total'] = orderAnalytics['omzet_total'];
    out['orders_count'] = orderAnalytics['orders_count'];
    out['trend'] = orderAnalytics['trend'];
    out['source_rpc'] =
        '${AppUi.text(out['source_rpc'], 'finance_snapshot')}+marketplace_orders_90d';
    return out;
  }

  Future<Map<String, dynamic>> _safeFinanceSummary(DateTime now) async {
    final startDate = _ymd(DateTime(now.year, now.month, 1));
    final endDate = _ymd(now);
    final marketplaceFilter = _dashboardFinanceMarketplaceParam();

    final orderAnalytics = await _safeDashboardOrderAnalytics90d(
      now,
      marketplaceFilter: marketplaceFilter,
    );

    final live = await _safeFinanceSummaryFromSnapshot(
      now,
      startDate,
      endDate,
      marketplaceFilter,
    );
    if (live['_tenant_empty_finance'] == true) {
      return _mergeDashboardOrderAnalytics(live, orderAnalytics);
    }
    if (_dashboardFinanceSummaryUsable(live)) {
      return _mergeDashboardOrderAnalytics(live, orderAnalytics);
    }

    final cached = await _safeFinanceSummaryFromLocalCache(
      now,
      startDate,
      endDate,
      marketplaceFilter,
    );
    if (_dashboardFinanceSummaryUsable(cached)) {
      return _mergeDashboardOrderAnalytics(cached, orderAnalytics);
    }

    final rawSummary =
        await _safeRawFinanceSummary(now, marketplaceFilter: marketplaceFilter);
    if (_dashboardFinanceSummaryUsable(rawSummary)) {
      return _mergeDashboardOrderAnalytics(rawSummary, orderAnalytics);
    }

    if (_dashboardFinanceSummaryUsable(orderAnalytics)) {
      return orderAnalytics;
    }

    return <String, dynamic>{
      'abnormal_count': 0,
      'anomaly_count': 0,
      'net_profit': 0,
      'omzet_total': 0,
      'orders_count': 0,
      'trend': _monthToDateTrend(now, const <_TrendPoint>[]),
    };
  }

  bool _dashboardFinanceSummaryUsable(Map<String, dynamic> data) {
    return AppUi.toNum(data['omzet_total']).abs() > 0 ||
        AppUi.toNum(data['orders_count']).abs() > 0 ||
        AppUi.toNum(data['net_profit']).abs() > 0 ||
        AppUi.toNum(data['abnormal_count'] ?? data['anomaly_count']).abs() > 0;
  }

  Future<Map<String, dynamic>> _safeFinanceSummaryFromSnapshot(
    DateTime now,
    String startDate,
    String endDate,
    String? marketplaceFilter,
  ) async {
    final rpcCandidates = <String>[
      'finance_customer_dashboard_snapshot',
      'finance_customer_dashboard_snapshot',
    ];

    Object? lastError;
    for (final rpcName in rpcCandidates) {
      for (final rpcParams in _dashboardFinanceSnapshotParamVariants(
          rpcName, startDate, endDate, marketplaceFilter)) {
        try {
          final response = await _client.rpc(rpcName, params: rpcParams);
          final parsed =
              _financeSummaryFromSnapshot(now, _asMap(response), rpcName);
          if (_dashboardFinanceSummaryUsable(parsed)) {
            try {
              final keyBase = FinanceLocalCache.snapshotKey(
                start: DateTime(now.year, now.month, 1),
                end: DateTime(now.year, now.month, now.day),
                marketplace: marketplaceFilter ?? 'all',
                accountId: 'all',
              );
              final cacheKey =
                  '$keyBase::finance_live_20260606_local_cache_fast_v20';
              await FinanceLocalCache.writeJson(cacheKey, _asMap(response));
            } catch (_) {}
            return parsed;
          }
          break;
        } catch (error) {
          lastError = error;
          if (!_isDashboardRpcParamMismatch(error)) break;
        }
      }
    }

    if (lastError != null) {
      debugPrint('Dashboard finance snapshot failed: $lastError');
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _dashboardFinanceSnapshotParamVariants(
    String rpcName,
    String startDate,
    String endDate,
    String? marketplaceFilter,
  ) {
    if (rpcName.endsWith('82o')) {
      return [
        {
          'p_start': startDate,
          'p_end': endDate,
          'p_marketplace': marketplaceFilter,
          'p_account_id': null,
        },
        {
          'p_start_date': startDate,
          'p_end_date': endDate,
          'p_marketplace_filter': marketplaceFilter,
          'p_account_id_filter': null,
        },
      ];
    }
    return [
      {
        'p_start': startDate,
        'p_end': endDate,
        'p_marketplace': marketplaceFilter,
        'p_account_id': null,
      }
    ];
  }

  bool _isDashboardRpcParamMismatch(Object error) {
    final lower = error.toString().toLowerCase();
    return lower.contains('could not find the function') ||
        lower.contains('function public.') ||
        lower.contains('does not exist') ||
        lower.contains('pgrst202') ||
        lower.contains('pgrst204') ||
        lower.contains('pgrst301');
  }

  Future<Map<String, dynamic>> _safeFinanceSummaryFromLocalCache(
    DateTime now,
    String startDate,
    String endDate,
    String? marketplaceFilter,
  ) async {
    final versions = <String>[
      'finance_live_20260606_local_cache_fast_v20',
      'finance_live_20260606_local_cache_fast_v19',
      'finance_live_20260606_local_cache_fast_v18',
      'finance_live_20260606_local_cache_fast_v17',
      'finance_live_20260606_truth_abnormal_raw_v15',
      'finance_live_20260606_no_local_cache_server_rpc_v16',
    ];
    final keyBase = FinanceLocalCache.snapshotKey(
      start: DateTime(now.year, now.month, 1),
      end: DateTime(now.year, now.month, now.day),
      marketplace: marketplaceFilter ?? 'all',
      accountId: 'all',
    );

    for (final version in versions) {
      try {
        final cached =
            await FinanceLocalCache.readJson('$keyBase::$version', ttlDays: 90);
        if (cached == null || cached.isEmpty) continue;
        final parsed = _financeSummaryFromSnapshot(now, cached, 'local_cache');
        if (_dashboardFinanceSummaryUsable(parsed)) return parsed;
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> _financeSummaryFromSnapshot(
    DateTime now,
    Map<String, dynamic> data,
    String source,
  ) {
    if (data.isEmpty) return <String, dynamic>{};

    final summary = _asMap(data['summary']);
    if (summary.isEmpty) return <String, dynamic>{};

    final snapshotSource = AppUi.text(data['source'], '').toLowerCase();
    final snapshotReason = AppUi.text(data['reason'], '').toLowerCase();
    final snapshotVersion = AppUi.text(data['version'], '').toLowerCase();
    if (snapshotSource == 'tenant_runtime_guard' ||
        snapshotReason == 'tenant_has_no_finance_data' ||
        snapshotVersion.contains('tenant_empty_finance_snapshot')) {
      return <String, dynamic>{
        '_tenant_empty_finance': true,
        'abnormal_count': 0,
        'anomaly_count': 0,
        'net_profit': 0,
        'omzet_total': 0,
        'orders_count': 0,
        'trend': _monthToDateTrend(now, const <_TrendPoint>[]),
        'source_rpc': source,
      };
    }
    final abnormals = data['abnormals'] ?? data['anomalies'];
    final rawTrend = _trendFromFinanceSnapshot(data);
    final abnormalCount = summary['abnormal_count'] ??
        summary['anomaly_count'] ??
        data['abnormal_count'] ??
        data['anomaly_count'] ??
        (abnormals is List ? abnormals.length : 0);
    final payout = AppUi.toNum(summary['payout_total'] ??
        summary['payout_amount'] ??
        summary['received_amount'] ??
        summary['net_settlement']);
    final hpp = AppUi.toNum(summary['hpp_total'] ?? summary['total_hpp']);
    final expense = AppUi.toNum(summary['expense_total'] ??
        summary['operational_expense_total'] ??
        summary['operational_expense'] ??
        summary['operational_cost_total']);
    final gross = AppUi.toNum(summary['omzet_total'] ??
        summary['gross_total'] ??
        summary['gross_sales'] ??
        summary['gross_amount']);
    final orders = AppUi.toNum(summary['orders_count'] ??
            summary['order_count'] ??
            summary['finance_order_count'] ??
            summary['finance_orders_count'] ??
            data['orders_count'])
        .toInt();
    if (gross <= 0 && orders <= 0 && AppUi.toNum(abnormalCount) <= 0) {
      return <String, dynamic>{};
    }
    final netProfit = summary['net_profit'] ??
        summary['profit'] ??
        (payout > 0 ? payout - hpp - expense : 0);
    final trend = rawTrend.isNotEmpty
        ? _monthToDateTrend(now, rawTrend)
        : _monthToDateTrend(now, <_TrendPoint>[
            _TrendPoint(date: now, omzet: gross, orders: orders),
          ]);
    return <String, dynamic>{
      'abnormal_count': abnormalCount,
      'anomaly_count': abnormalCount,
      'net_profit': netProfit,
      'omzet_total': gross,
      'orders_count': orders,
      'trend': trend,
      'source_rpc': source,
    };
  }

  Future<List<_AppNotification>> _safeNotifications() async {
    try {
      final response = await _client.rpc(
        'list_app_notifications_for_app',
        params: {'p_include_resolved': false},
      );
      final rows = response is List
          ? response
          : response is Map && response['rows'] is List
              ? response['rows'] as List
              : const <dynamic>[];
      return rows
          .whereType<Map>()
          .map((item) =>
              _AppNotification.fromMap(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    } catch (_) {
      return const <_AppNotification>[];
    }
  }

  List<_AppNotification> _withLowStockNotificationFallback(
    List<_AppNotification> notifications, {
    required String roleId,
    required int lowStockCount,
  }) {
    if (notifications.isNotEmpty || lowStockCount <= 0) return notifications;
    final role = AppRolePermissions.normalizeRoleId(roleId);
    if (role != 'super_admin' &&
        role != 'warehouse' &&
        role != 'production' &&
        role != 'produksi') {
      return notifications;
    }
    return <_AppNotification>[_AppNotification.localLowStock(lowStockCount)];
  }

  Future<void> _refreshNotifications() async {
    final notifications = _withLowStockNotificationFallback(
      await _safeNotifications(),
      roleId: _role,
      lowStockCount: _lowStock,
    );
    if (!mounted) return;
    setState(() => _notifications = notifications);
  }

  Future<void> _markNotificationRead(_AppNotification notification) async {
    if (notification.notificationId.trim().isEmpty) return;
    try {
      await _client.rpc(
        'mark_app_notification_read',
        params: {'p_notification_id': notification.notificationId},
      );
      await _refreshNotifications();
    } catch (e) {
      if (!mounted) return;
      AppUi.safeSnack(context, AppUi.userMessage(e.toString()));
    }
  }

  List<_TrendPoint> _trendFromFinanceSnapshot(Map<String, dynamic> data) {
    final rows =
        (data['daily'] is List ? data['daily'] : data['by_date']) as dynamic;
    if (rows is! List) return const <_TrendPoint>[];
    final points = <_TrendPoint>[];
    for (final item in rows) {
      final row = _asMap(item);
      final rawDate = AppUi.text(
          row['date'] ?? row['report_date'] ?? row['order_date'], '');
      if (rawDate.isEmpty) continue;
      final date = DateTime.tryParse(
          rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate);
      if (date == null) continue;
      points.add(_TrendPoint(
        date: date,
        omzet: AppUi.toNum(
            row['omzet_total'] ?? row['gross_sales'] ?? row['gross_total']),
        orders: AppUi.toNum(row['order_count'] ?? row['orders_count']).toInt(),
      ));
    }
    points.sort((a, b) => a.date.compareTo(b.date));
    return points;
  }

  List<_TrendPoint> _monthToDateTrend(DateTime now, List<_TrendPoint> source) {
    final monthStart = DateTime(now.year, now.month, 1);
    final today = DateTime(now.year, now.month, now.day);
    final grouped = <String, _TrendPoint>{};

    for (final point in source) {
      final date = DateTime(point.date.year, point.date.month, point.date.day);
      if (date.isBefore(monthStart) || date.isAfter(today)) continue;
      final key = _ymd(date);
      final existing = grouped[key];
      grouped[key] = _TrendPoint(
        date: date,
        omzet: (existing?.omzet ?? 0) + point.omzet,
        orders: (existing?.orders ?? 0) + point.orders,
      );
    }

    final result = <_TrendPoint>[];
    for (var date = monthStart;
        !date.isAfter(today);
        date = date.add(const Duration(days: 1))) {
      result.add(
          grouped[_ymd(date)] ?? _TrendPoint(date: date, omzet: 0, orders: 0));
    }
    return result;
  }

  String _shortRupiah(num value) {
    final abs = value.abs();
    final sign = value < 0 ? '-' : '';
    if (abs >= 1000000000)
      return '${sign}Rp ${(abs / 1000000000).toStringAsFixed(1)}M';
    if (abs >= 1000000)
      return '${sign}Rp ${(abs / 1000000).toStringAsFixed(1)}Jt';
    if (abs >= 1000) return '${sign}Rp ${(abs / 1000).toStringAsFixed(0)}Rb';
    return AppUi.rupiah(value);
  }

  Future<List<dynamic>> _safeList(Future<dynamic> Function() loader) async {
    try {
      final data = await loader();
      if (data is List<dynamic>) return data;
      if (data is List) return data.cast<dynamic>();
    } catch (_) {
      return const <dynamic>[];
    }
    return const <dynamic>[];
  }

  Future<_TenantSubscriptionInfo?> _safeTenantSubscriptionInfo(
      dynamic tenantIdValue) async {
    final tenantId = tenantIdValue?.toString().trim() ?? '';
    if (tenantId.isEmpty) return null;

    try {
      final response = await _client
          .from('tenant_subscriptions')
          .select(
            'status, trial_ends_at, current_period_end, created_at, '
            'subscription_plans(plan_name, plan_code, billing_period, price_amount, currency)',
          )
          .eq('tenant_id', tenantId)
          .order('created_at', ascending: false)
          .limit(1);

      final rows = response is List ? response : const <dynamic>[];
      if (rows.isEmpty || rows.first is! Map) return null;

      return _TenantSubscriptionInfo.fromMap(
        Map<String, dynamic>.from(rows.first as Map),
      );
    } catch (e) {
      debugPrint('Dashboard tenant subscription lookup failed: $e');
      return null;
    }
  }

  Future<void> _logout() async {
    await _client.auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  String? _featureForPage(Widget page) {
    final type = page.runtimeType.toString();

    if (type.contains('FinanceReportPage') ||
        type.contains('PurchaseVerificationPage') ||
        type.contains('DataExportImportPage')) {
      return 'finance_basic';
    }

    if (type.contains('StockProgressPage')) return 'production_basic';
    if (type.contains('PurchaseRequestPage')) return 'purchase_requests';
    if (type.contains('SupplierPage')) return 'production_basic';

    if (type.contains('MarketplaceAccountsPage')) return 'marketplace_accounts';
    if (type.contains('MarketplaceOrdersPage')) return 'marketplace_order_sync';
    if (type.contains('MarketplaceSkuMappingPage')) {
      return 'marketplace_product_sync';
    }
    if (type.contains('MarketplaceStockSyncPage') ||
        type.contains('MarketplaceSyncMonitorPage') ||
        type.contains('MarketplaceStockDifferencePage')) {
      return 'marketplace_stock_sync';
    }
    if (type.contains('MarketplaceRefundMonitorPage') ||
        type.contains('MarketplaceStockOutReviewPage')) {
      return 'marketplace_return_refund';
    }
    if (type.contains('MarketplaceJobMonitorPage')) {
      return 'marketplace_job_monitor';
    }

    if (type.contains('ProductListPage') ||
        type.contains('StockOutPage') ||
        type.contains('StockInPage') ||
        type.contains('StockHistoryPage') ||
        type.contains('LowStockPage')) {
      return 'stock_basic';
    }

    if (type.contains('AttendancePage') ||
        type.contains('AbsensiPage') ||
        type.contains('HrPerformancePage') ||
        type.contains('WorkLocationPage')) {
      return 'attendance_basic';
    }

    if (type.contains('HostLivePage')) return 'live_schedule_basic';
    if (type.contains('ContentMonitoringPage')) return 'content_task_basic';
    if (type.contains('TaskPage')) return 'task_basic';

    if (type.contains('UserManagementPage')) return 'invite_management';
    if (type.contains('AuditLogPage')) return 'tenant_management';

    return null;
  }

  String? _featureForMenu(_DashboardMenu menu) {
    final title = menu.title.toLowerCase();

    if (title.contains('keuangan') ||
        title.contains('laporan') ||
        title.contains('verifikasi pembelian') ||
        title.contains('abnormal') ||
        title.contains('arus kas') ||
        title.contains('export')) {
      return 'finance_basic';
    }

    if (title.contains('produksi berjalan') || title == 'produksi') {
      return 'production_basic';
    }
    if (title.contains('pembelian barang') || title == 'pembelian') {
      return 'purchase_requests';
    }
    if (title.contains('supplier')) return 'production_basic';

    if (title.contains('akun marketplace')) return 'marketplace_accounts';
    if (title.contains('order marketplace')) return 'marketplace_order_sync';
    if (title.contains('mapping sku')) return 'marketplace_product_sync';
    if (title.contains('sync stock') || title.contains('selisih')) {
      return 'marketplace_stock_sync';
    }
    if (title.contains('refund') ||
        title.contains('retur') ||
        title.contains('review stock out')) {
      return 'marketplace_return_refund';
    }
    if (title.contains('monitor job')) return 'marketplace_job_monitor';

    if (title.contains('stok') ||
        title.contains('stock') ||
        title.contains('master sku') ||
        title.contains('riwayat')) {
      return 'stock_basic';
    }

    if (title.contains('absensi') ||
        title.contains('performance') ||
        title.contains('people')) {
      return 'attendance_basic';
    }

    if (title.contains('live')) return 'live_schedule_basic';
    if (title.contains('konten')) return 'content_task_basic';
    if (title.contains('tugas')) return 'task_basic';
    if (title.contains('user')) return 'invite_management';

    return null;
  }

  List<_DashboardMenu> _filterMenusByPlan(List<_DashboardMenu> menus) {
    if (_isPlatformOwner) return menus;

    return menus.where((menu) {
      final feature = _featureForMenu(menu);
      if (feature == null) return true;
      return _planHasFeature(feature);
    }).toList(growable: false);
  }

  void _open(Widget page) {
    final feature = _featureForPage(page);
    if (feature != null && !_planHasFeature(feature)) {
      final planName = _entitlement?.planName ?? 'paket aktif';
      AppUi.safeSnack(
        context,
        'Fitur ini tidak aktif di $planName.',
      );
      return;
    }

    final guardedPage = feature == null
        ? page
        : FeatureGatePage(
            featureKey: feature,
            featureLabel: feature.replaceAll('_', ' '),
            child: page,
          );

    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => guardedPage))
        .then((_) {
      if (!mounted) return;
      _loadDashboard();
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 840;

    return Scaffold(
      extendBody: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          if (wide)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _sidebarNavigation(),
            ),
          Positioned(
            left: wide ? 316 : 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: SafeArea(
              bottom: false,
              child: _loading
                  ? const FuturisticLoader(message: 'Memuat dashboard…')
                  : RefreshIndicator(
                      color: Theme.of(context).colorScheme.primary,
                      backgroundColor: Theme.of(context).cardColor,
                      onRefresh: _loadDashboard,
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          16,
                          16,
                          wide ? 32 : 132,
                        ),
                        children: [
                          _topBar(),
                          const SizedBox(height: 16),
                          _profileCard(_user),
                          if (_isAdmin || _isOperationalAdmin) ...[
                            const SizedBox(height: 12),
                            _subscriptionOverviewCard(),
                          ],
                          if (_isDemoSuperAdmin) ...[
                            const SizedBox(height: 12),
                            _demoReadOnlyBanner(),
                          ],
                          const SizedBox(height: 14),
                          _summaryGrid(),
                          const SizedBox(height: 20),
                          if (_isAdmin &&
                              _canAccessFinance &&
                              _financeTrend.isNotEmpty) ...[
                            _adminAnalyticsCard(),
                            const SizedBox(height: 20),
                          ],
                          ..._roleAnalyticsContent(),
                        ],
                      ),
                    ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: _loading,
              child: wide ? const SizedBox.shrink() : _bottomQuickBar(),
            ),
          ),
        ],
      ),
    );
  }

  // ── Top bar ─────────────────────────────────────────────────────────────────
  Widget _sidebarNavigation() {
    final menus = _filterMenusByPlan(_roleMenus());
    return SafeArea(
      right: false,
      child: Container(
        width: 286,
        margin: const EdgeInsets.fromLTRB(14, 14, 0, 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.zero,
          color: Theme.of(context).cardColor,
          border: Border.all(color: Colors.black, width: 3),
          boxShadow: const [
            BoxShadow(
              color: Colors.black,
              blurRadius: 0,
              offset: Offset(6, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.zero,
                    color: Theme.of(context).colorScheme.primary,
                    border: Border.all(
                        color: (Theme.of(context).dividerColor), width: 1.4),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).colorScheme.tertiary,
                        blurRadius: 0,
                        offset: const Offset(3, 3),
                      ),
                    ],
                  ),
                  child: Icon(Icons.grid_view_rounded,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Analytics',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _sidebarTile(
              icon: Icons.analytics_rounded,
              title: 'Dashboard Analytics',
              subtitle: _roleLabel(_role),
              selected: true,
              onTap: () {},
            ),
            const SizedBox(height: 10),
            Text(
              'MENU',
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.9,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: menus
                    .map((menu) => _sidebarTile(
                          icon: menu.icon,
                          title: menu.title,
                          subtitle: menu.subtitle,
                          selected: false,
                          onTap: menu.onTap,
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebarTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final accent = AppUi
        .playfulPalette[(title.hashCode.abs()) % AppUi.playfulPalette.length];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.zero,
              color: selected ? accent : Theme.of(context).cardColor,
              border: Border.all(
                color: Colors.black,
                width: 2,
              ),
              boxShadow: selected
                  ? [
                      const BoxShadow(
                        color: Colors.black,
                        offset: Offset(3, 3),
                      )
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Icon(icon, color: selected ? Colors.black : accent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? Colors.black
                              : Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                          letterSpacing: 0.5,
                        ),
                      ),
                      if (subtitle.trim().isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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

  String _dashboardTitle() {
    final name = (_appUser?.nama ?? _user?.name ?? '').trim();
    if (name.isEmpty || name == '-') return 'OperasionalApp';
    return name;
  }

  Widget _topBar() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _greeting(),
                style: TextStyle(
                  fontSize: 12,
                  color:
                      Theme.of(context).colorScheme.primary.withOpacity(0.85),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _dashboardTitle(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
        if (_canOpenSuperSettings) ...[
          _iconBtn(Icons.settings_rounded, _openAdminSettingsSheet),
          const SizedBox(width: 8),
        ],
        _notificationButton(),
        const SizedBox(width: 8),
        ValueListenableBuilder<AppVisualMode>(
          valueListenable: AppThemeModeController.mode,
          builder: (context, visualMode, _) {
            return Tooltip(
              message: visualMode == AppVisualMode.girl
                  ? 'Switch to Man Dark'
                  : 'Switch to Girl Light',
              child: _iconBtn(
                visualMode == AppVisualMode.girl
                    ? Icons.dark_mode_rounded
                    : Icons.light_mode_rounded,
                AppThemeModeController.toggle,
              ),
            );
          },
        ),
        const SizedBox(width: 8),
        _iconBtn(Icons.refresh_rounded, _loadDashboard),
        const SizedBox(width: 8),
        _iconBtn(Icons.logout_rounded, _logout),
      ],
    );
  }

  Widget _notificationButton() {
    final count = _activeNotificationCount;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _iconBtn(
          count > 0
              ? Icons.notifications_active_rounded
              : Icons.notifications_none_rounded,
          _openNotificationsSheet,
        ),
        if (count > 0)
          Positioned(
            right: -4,
            top: -4,
            child: Container(
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.zero,
                border: Border.all(
                    color: (Theme.of(context).dividerColor), width: 1),
              ),
              child: Text(
                count > 99 ? '99+' : count.toString(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _openNotificationsSheet() async {
    await _refreshNotifications();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: (Theme.of(context).cardColor),
      builder: (context) {
        final notifications = _notifications;
        return Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
          decoration: BoxDecoration(
            color: (Theme.of(context).cardColor),
            borderRadius: BorderRadius.zero,
            border:
                Border.all(color: (Theme.of(context).dividerColor), width: 1.4),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).dividerColor.withOpacity(0.16),
                blurRadius: 0,
                offset: const Offset(4, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondary,
                      borderRadius: BorderRadius.zero,
                      border: Border.all(
                          color: (Theme.of(context).dividerColor), width: 1),
                    ),
                    child: Icon(Icons.notifications_active_rounded,
                        color: Theme.of(context).colorScheme.onSurface),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Notifikasi Aktif',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _open(const LowStockPage());
                    },
                    icon: Icon(Icons.warning_amber_rounded, size: 18),
                    label: Text('Stock Low'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.66,
                ),
                child: notifications.isEmpty
                    ? const EmptyState(
                        icon: Icons.verified_rounded,
                        title: 'Belum ada notifikasi aktif',
                        subtitle:
                            'Kalau stok sudah di bawah limit, super admin, produksi, dan warehouse akan melihat alert di sini.',
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: notifications.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = notifications[index];
                          final isRead = item.readAt != null;
                          return Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.zero,
                            child: InkWell(
                              borderRadius: BorderRadius.zero,
                              onTap: () async {
                                Navigator.pop(context);
                                await _markNotificationRead(item);
                                if (!mounted) return;
                                if (item.notificationType == 'low_stock') {
                                  _open(const LowStockPage());
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Color.alphaBlend(
                                    (isRead
                                            ? Theme.of(context)
                                                .colorScheme
                                                .surfaceVariant
                                            : Theme.of(context)
                                                .colorScheme
                                                .secondary)
                                        .withOpacity(isRead ? 0.20 : 0.12),
                                    (Theme.of(context).cardColor),
                                  ),
                                  borderRadius: BorderRadius.zero,
                                  border: Border.all(
                                      color: (Theme.of(context).dividerColor)
                                          .withOpacity(isRead ? 0.18 : 0.42)),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      item.notificationType == 'low_stock'
                                          ? Icons.warning_amber_rounded
                                          : Icons.notifications_rounded,
                                      color: item.severityColor(context),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.title,
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            item.body,
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .outline,
                                              fontWeight: FontWeight.w600,
                                              height: 1.32,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            'Update ${AppUi.dateTime(item.lastTriggeredAt)}',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .outline
                                                  ?.withOpacity(0.78),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 11) return 'SELAMAT PAGI';
    if (hour < 15) return 'SELAMAT SIANG';
    if (hour < 18) return 'SELAMAT SORE';
    return 'SELAMAT MALAM';
  }

  Color _menuAccent(_DashboardMenu item) {
    final colors = AppUi.playfulPalette;
    final seed = (item.title.hashCode ^ item.icon.codePoint).abs();
    return colors[seed % colors.length];
  }

  BoxDecoration _pixelDecoration(Color accent) {
    return BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.zero,
      border: Border.all(color: Colors.black, width: 2.5),
      boxShadow: const [
        BoxShadow(
          color: Colors.black,
          offset: Offset(4, 4),
        ),
      ],
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.zero,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.zero,
            color: Theme.of(context).cardColor,
            border: Border.all(color: Colors.black, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black,
                offset: Offset(3, 3),
              ),
            ],
          ),
          child: Icon(icon,
              size: 20, color: Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
  }

  Widget _demoReadOnlyBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).colorScheme.secondary.withOpacity(0.10),
        border: Border.all(
            color: Theme.of(context).colorScheme.secondary.withOpacity(0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded,
              color: Theme.of(context).colorScheme.secondary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Mode demo aktif. Semua aksi tambah, simpan, edit, hapus, import, sinkron, dan perubahan data dikunci. Akun ini hanya untuk melihat alur aplikasi.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openAdminSettingsSheet() {
    if (!_canOpenSuperSettings) {
      AppUi.safeSnack(context, 'Pengaturan sistem hanya untuk Super Admin.');
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: (Theme.of(context).cardColor),
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
            decoration: BoxDecoration(
              color: (Theme.of(context).cardColor),
              borderRadius: BorderRadius.zero,
              border: Border.all(color: (Theme.of(context).dividerColor)),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).dividerColor.withOpacity(0.16),
                  blurRadius: 0,
                  offset: const Offset(4, -4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.zero,
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(0.12),
                        border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(0.24)),
                      ),
                      child: Icon(Icons.settings_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pengaturan Admin',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Kelola akses, lokasi kerja, dan backup data.',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _settingsTile(
                  icon: Icons.manage_accounts_rounded,
                  title: 'User Management',
                  subtitle: 'Kelola akun, role, dan status user.',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _open(const UserManagementPage());
                  },
                ),
                const SizedBox(height: 10),
                _settingsTile(
                  icon: Icons.location_on_rounded,
                  title: 'Set Lokasi',
                  subtitle: 'Atur titik lokasi kerja untuk absensi.',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _open(const WorkLocationPage());
                  },
                ),
                const SizedBox(height: 10),
                _settingsTile(
                  icon: Icons.table_view_rounded,
                  title: 'Export / Import Data',
                  subtitle:
                      'Backup semua data, download finance, dan import update SKU/stock.',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _open(const DataExportImportPage());
                  },
                ),
                const SizedBox(height: 10),
                _settingsTile(
                  icon: Icons.manage_search_rounded,
                  title: 'Audit Log',
                  subtitle: 'Lihat dan hapus riwayat aktivitas sistem.',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _open(const AuditLogPage());
                  },
                ),
                const SizedBox(height: 10),
                _settingsTile(
                  icon: Icons.sync_problem_rounded,
                  title: 'Monitor Job Marketplace',
                  subtitle:
                      'Status order pull, finance payout, retry, dan reset job macet.',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _open(const MarketplaceJobMonitorPage());
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _settingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final color = AppUi
        .playfulPalette[(title.hashCode.abs()) % AppUi.playfulPalette.length];
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: _pixelDecoration(color),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.zero,
                  color: color.withOpacity(0.14),
                  border: Border.all(color: color.withOpacity(0.28)),
                ),
                child: Icon(icon, color: color, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 11.5,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: Theme.of(context).colorScheme.outline, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ── Profile card ────────────────────────────────────────────────────────────
  Widget _profileCard(_CurrentUser? user) {
    final roleLabel = _roleLabel(user?.role ?? '-');
    final isActive = user?.active ?? true;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            blurRadius: 0,
            offset: Offset(6, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.zero,
              color: Theme.of(context).colorScheme.primary,
              border: Border.all(color: Colors.black, width: 2.5),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black,
                  offset: Offset(4, 4),
                ),
              ],
            ),
            child: Icon(Icons.person_rounded, color: Colors.black, size: 30),
          ),
          const SizedBox(width: 14),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user?.name ?? 'User',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  user?.email ?? '-',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.50),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _roleBadge(roleLabel),
                    const SizedBox(width: 8),
                    _statusDot(isActive),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _subscriptionOverviewCard() {
    final info = _tenantSubscriptionInfo;
    final status = info?.status ?? 'unassigned';
    final planName = info?.planName ?? 'Belum ada paket';
    final billing = info?.billingPeriod ?? '-';
    final price = info == null ? '-' : info.priceLabel;
    final periodLabel = info?.periodLabel ?? 'Belum diset';
    final statusColor = _subscriptionStatusColor(status);

    return NiceCard(
      borderColor: statusColor,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.18),
              border: Border.all(color: statusColor, width: 2),
              borderRadius: BorderRadius.zero,
            ),
            child: Icon(Icons.workspace_premium_rounded,
                color: statusColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PAKET SUBSCRIPTION',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  planName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _subscriptionPill('BILLING $billing', statusColor),
                    _subscriptionPill(price, statusColor),
                    _subscriptionPill(periodLabel, statusColor),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _subscriptionPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.55), width: 1.4),
        borderRadius: BorderRadius.zero,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Color _subscriptionStatusColor(String status) {
    final clean = status.toLowerCase();
    if (clean == 'active' || clean == 'trialing') {
      return Theme.of(context).colorScheme.primary;
    }
    if (clean == 'unassigned') {
      return Theme.of(context).colorScheme.secondary;
    }
    if (clean == 'expired' ||
        clean == 'suspended' ||
        clean == 'canceled' ||
        clean == 'past_due') {
      return Theme.of(context).colorScheme.error;
    }
    return Theme.of(context).colorScheme.outline;
  }

  Widget _roleBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
        borderRadius: BorderRadius.zero,
        border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.28)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _statusDot(bool active) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(
          active ? 'Aktif' : 'Nonaktif',
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  List<_TrendPoint> _financeTrendForChart() {
    if (_financeTrend.length >= 2) return _financeTrend;
    final now = DateTime.now();
    return <_TrendPoint>[
      _TrendPoint(date: DateTime(now.year, now.month, 1), omzet: 0, orders: 0),
      _TrendPoint(date: now, omzet: _financeOmzet, orders: _financeOrderCount),
    ];
  }

  String? _dashboardFinanceMarketplaceParam() {
    final clean = _dashboardFinanceMarketplaceFilter.trim().toLowerCase();
    if (clean == 'shopee') return 'shopee';
    if (clean == 'tiktok') return 'tiktok';
    return null;
  }

  String _dashboardFinanceMarketplaceLabel() {
    switch (_dashboardFinanceMarketplaceFilter.trim().toLowerCase()) {
      case 'shopee':
        return 'Shopee';
      case 'tiktok':
        return 'TikTok';
      default:
        return 'Semua';
    }
  }

  void _setDashboardFinanceMarketplaceFilter(String value) {
    final clean = value.trim().toLowerCase();
    final next = clean == 'shopee' || clean == 'tiktok' ? clean : 'all';
    if (_dashboardFinanceMarketplaceFilter == next) return;

    setState(() {
      _dashboardFinanceMarketplaceFilter = next;
      _selectedTrendIndex = null;
    });

    unawaited(_loadDashboard());
  }

  Widget _dashboardFinanceMarketplaceFilterCards() {
    final items = <({String value, String label})>[
      (value: 'all', label: 'Semua'),
      (value: 'shopee', label: 'Shopee'),
      (value: 'tiktok', label: 'TikTok'),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items.map((item) {
        final selected = _dashboardFinanceMarketplaceFilter == item.value ||
            (item.value == 'all' &&
                _dashboardFinanceMarketplaceFilter.trim().isEmpty);
        final accent = selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline.withOpacity(0.55);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _setDashboardFinanceMarketplaceFilter(item.value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primary.withOpacity(0.18)
                    : Colors.white.withOpacity(0.045),
                borderRadius: BorderRadius.zero,
                border: Border.all(
                  color: accent,
                  width: selected ? 2 : 1.2,
                ),
                boxShadow: selected
                    ? const [
                        BoxShadow(
                          color: Colors.black,
                          offset: Offset(2, 2),
                        )
                      ]
                    : null,
              ),
              child: Text(
                item.label,
                style: TextStyle(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurface,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        );
      }).toList(growable: false),
    );
  }

  int _defaultFinanceTrendIndex(List<_TrendPoint> points) {
    if (points.isEmpty) return 0;
    for (var i = points.length - 1; i >= 0; i--) {
      final point = points[i];
      if (point.orders > 0 || point.omzet.abs() > 0) return i;
    }
    return points.length - 1;
  }

  // ── Summary 2×2 grid ────────────────────────────────────────────────────────
  Widget _adminAnalyticsCard() {
    final points = _financeTrendForChart();
    final defaultSelectedIndex = _defaultFinanceTrendIndex(points);
    final selected = points.isEmpty
        ? null
        : points[(_selectedTrendIndex ?? defaultSelectedIndex)
            .clamp(0, points.length - 1)
            .toInt()];
    final totalOrders = points.fold<int>(0, (sum, point) => sum + point.orders);
    final totalOmzet = points.fold<num>(0, (sum, point) => sum + point.omzet);

    void selectFromPosition(Offset local, double width) {
      if (points.isEmpty || width <= 0) return;
      final idx = ((local.dx / width) * (points.length - 1))
          .round()
          .clamp(0, points.length - 1)
          .toInt();
      setState(() => _selectedTrendIndex = idx);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 2.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            blurRadius: 0,
            offset: Offset(5, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Analytics Finance',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w900),
                ),
              ),
              _miniBadge('Omzet ${_shortRupiah(totalOmzet)}'),
              const SizedBox(width: 8),
              _miniBadge('$totalOrders order'),
            ],
          ),
          const SizedBox(height: 10),
          _dashboardFinanceMarketplaceFilterCards(),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: _miniBadge('Filter ${_dashboardFinanceMarketplaceLabel()}'),
          ),
          const SizedBox(height: 10),
          if (selected != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.zero,
                color: Colors.white.withOpacity(0.055),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _shortRupiah(selected.omzet),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
                  ),
                  Text(
                    '${selected.orders} pesanan',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                onTapDown: (details) => selectFromPosition(
                    details.localPosition, constraints.maxWidth),
                onPanUpdate: (details) => selectFromPosition(
                    details.localPosition, constraints.maxWidth),
                child: SizedBox(
                  height: 156,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _FinanceTrendPainter(
                      points: points,
                      selectedIndex:
                          selected == null ? null : points.indexOf(selected),
                      omzetColor: Theme.of(context).colorScheme.primary,
                      orderColor: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _legendDot(
                  Theme.of(context).colorScheme.primary, 'Omzet per hari'),
              const SizedBox(width: 14),
              _legendDot(
                  Theme.of(context).colorScheme.tertiary, 'Pesanan per hari'),
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: 10),
            Text(
              '${AppUi.date(selected.date)} · omzet ${_shortRupiah(selected.omzet)} · ${selected.orders} pesanan',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w800),
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Text(text,
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 11,
              fontWeight: FontWeight.w800)),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 11,
                fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _summaryGrid() {
    final items = _summaryItemsForRole();

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        mainAxisExtent: 88,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: item.onTap,
            borderRadius: BorderRadius.zero,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: _pixelDecoration(item.color),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.zero,
                      color: item.color.withOpacity(0.12),
                    ),
                    child: Icon(item.icon, color: item.color, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item.value,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            color: item.color,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.2,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.6),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: item.color.withOpacity(0.65),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  _SummaryItem _summaryItem(
    IconData icon,
    String label,
    String value,
    Color color,
    VoidCallback onTap,
  ) {
    return _SummaryItem(icon, label, value, color, onTap: onTap);
  }

  VoidCallback _summaryTap(String target) {
    final normalized = target.toLowerCase();
    if (normalized.contains('stock out')) {
      return () => _open(const StockOutPage());
    }
    if (normalized.contains('stock in')) {
      return () => _open(const StockInPage());
    }
    if (normalized.contains('stok rendah')) {
      return () => _open(const LowStockPage());
    }
    if (normalized.contains('sku aktif')) {
      return () => _open(ProductListPage(currentUser: _requiredAppUser));
    }
    if (normalized.contains('pembelian')) {
      if (_canAccessFinance || _isAdmin || _isOperationalAdmin) {
        return () => _open(const PurchaseVerificationPage());
      }
      return () => _open(const PurchaseRequestPage());
    }
    if (normalized.contains('produksi')) {
      return () => _open(const StockProgressPage());
    }
    if (normalized.contains('task')) {
      return () => _open(const TaskPage());
    }
    if (normalized.contains('absensi') || normalized.contains('telat')) {
      return _isManagementRole
          ? () => _open(const HrPerformancePage())
          : () => _open(AbsensiPage(currentUser: _requiredAppUser));
    }
    if (normalized.contains('live')) {
      return () => _open(const HostLivePage());
    }
    if (normalized.contains('konten') || normalized.contains('deadline')) {
      return () => _open(const ContentMonitoringPage());
    }
    if (normalized.contains('abnormal') ||
        normalized.contains('anomali') ||
        normalized.contains('anomaly') ||
        normalized.contains('laba')) {
      return () => _open(const FinanceReportPage());
    }
    return () => _open(const TaskPage());
  }

  List<_SummaryItem> _summaryItemsForRole() {
    final role = _role;
    final managedTasks = _isManagementRole ? _allOpenTasks : _myOpenTasks;

    if (role == 'warehouse') {
      return [
        _summaryItem(
            Icons.local_shipping_rounded,
            'Stock Out Hari Ini',
            _todayStockOut.toString(),
            Theme.of(context).colorScheme.primary,
            _summaryTap('stock out')),
        _summaryItem(
            Icons.qr_code_scanner_rounded,
            'Stock In Hari Ini',
            _todayStockIn.toString(),
            Theme.of(context).colorScheme.primary,
            _summaryTap('stock in')),
        _summaryItem(
            Icons.warning_amber_rounded,
            'Stok Rendah',
            _lowStock.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('stok rendah')),
        _summaryItem(
            Icons.inventory_2_rounded,
            'SKU Aktif',
            _activeProducts.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('sku aktif')),
      ];
    }
    if (role == 'finance') {
      return [
        _summaryItem(
            Icons.verified_rounded,
            'Pembelian Pending',
            _pendingPurchase.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('pembelian')),
        _summaryItem(
            Icons.task_alt_rounded,
            'Task Saya',
            _myOpenTasks.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('task')),
        _summaryItem(
            Icons.warning_amber_rounded,
            'Abnormal Finance',
            _financeAbnormalCount.toString(),
            Theme.of(context).colorScheme.error,
            _summaryTap('abnormal')),
        _summaryItem(
            Icons.receipt_long_rounded,
            'Laba Bersih',
            _shortRupiah(_financeNetProfit),
            Theme.of(context).colorScheme.primary,
            _summaryTap('laba')),
      ];
    }
    if (role == 'production' || role == 'produksi') {
      return [
        _summaryItem(
            Icons.shopping_cart_checkout_rounded,
            'Pembelian Pending',
            _pendingPurchase.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('pembelian')),
        _summaryItem(
            Icons.precision_manufacturing_rounded,
            'Produksi Aktif',
            _runningProduction.toString(),
            Theme.of(context).colorScheme.primary,
            _summaryTap('produksi')),
        _summaryItem(
            Icons.task_alt_rounded,
            'Task Saya',
            _myOpenTasks.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('task')),
        _summaryItem(
            Icons.how_to_reg_rounded,
            'Absensi Saya',
            _myAttendanceLabel,
            Theme.of(context).colorScheme.primary,
            _summaryTap('absensi')),
      ];
    }
    if (role == 'host_live') {
      return [
        _summaryItem(
            Icons.live_tv_rounded,
            'Live Hari Ini',
            _myTodayLive.toString(),
            Theme.of(context).colorScheme.primary,
            _summaryTap('live')),
        _summaryItem(
            Icons.task_alt_rounded,
            'Task Saya',
            _myOpenTasks.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('task')),
        _summaryItem(
            Icons.how_to_reg_rounded,
            'Absensi Saya',
            _myAttendanceLabel,
            Theme.of(context).colorScheme.primary,
            _summaryTap('absensi')),
        _summaryItem(
            Icons.fact_check_rounded,
            'Bukti Perlu Cek',
            _pendingLiveReview.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('live')),
      ];
    }
    if (role == 'hr') {
      return [
        _summaryItem(
            Icons.how_to_reg_rounded,
            'Absensi Hari Ini',
            _todayAttendance.toString(),
            Theme.of(context).colorScheme.primary,
            _summaryTap('absensi')),
        _summaryItem(
            Icons.task_alt_rounded,
            'Task Review',
            managedTasks.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('task')),
        _summaryItem(
            Icons.live_tv_rounded,
            'Live Review',
            _pendingLiveReview.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('live')),
        _summaryItem(
            Icons.analytics_rounded,
            'Telat / Absen',
            '$_lateAttendance / $_absentAttendance',
            Theme.of(context).colorScheme.primary,
            _summaryTap('telat')),
      ];
    }
    if (role == 'content_creator') {
      return [
        _summaryItem(
            Icons.task_alt_rounded,
            'Task Saya',
            _myOpenTasks.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('task')),
        _summaryItem(
            Icons.video_collection_rounded,
            'Konten',
            _contentTotal.toString(),
            Theme.of(context).colorScheme.primary,
            _summaryTap('konten')),
        _summaryItem(
            Icons.how_to_reg_rounded,
            'Absensi Saya',
            _myAttendanceLabel,
            Theme.of(context).colorScheme.primary,
            _summaryTap('absensi')),
        _summaryItem(
            Icons.schedule_rounded,
            'Deadline',
            _contentDueSoon.toString(),
            Theme.of(context).colorScheme.secondary,
            _summaryTap('deadline')),
      ];
    }
    return [
      _summaryItem(
          Icons.local_shipping_rounded,
          'Stock Out Hari Ini',
          _todayStockOut.toString(),
          Theme.of(context).colorScheme.primary,
          _summaryTap('stock out')),
      _summaryItem(
          Icons.warning_amber_rounded,
          'Stok Rendah',
          _lowStock.toString(),
          Theme.of(context).colorScheme.secondary,
          _summaryTap('stok rendah')),
      _summaryItem(
          Icons.task_alt_rounded,
          'Task Review',
          managedTasks.toString(),
          Theme.of(context).colorScheme.secondary,
          _summaryTap('task')),
      _summaryItem(
          Icons.verified_rounded,
          'Pembelian Pending',
          _pendingPurchase.toString(),
          Theme.of(context).colorScheme.primary,
          _summaryTap('pembelian')),
    ];
  }

  // ── Menu content ─────────────────────────────────────────────────────────────
  List<Widget> _menuContent() {
    final menus = _filterMenusByPlan(_roleMenus());
    if (menus.isEmpty) return [];
    return [
      _sectionHeader('Menu Utama'),
      const SizedBox(height: 10),
      for (final item in menus) ...[
        _menuCard(item),
        const SizedBox(height: 10),
      ],
      if (_canOpenSuperSettings) ...[
        const SizedBox(height: 6),
        _superAdminRecommendationCard(),
      ],
    ];
  }

  Widget _metricsAnalyticsChartCard(
    String title,
    List<_OpsMetric> metrics, {
    String badge = 'Realtime',
  }) {
    final maxValue =
        metrics.fold<int>(1, (max, item) => math.max(max, item.value));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 2.5),
        boxShadow: const [
          BoxShadow(color: Colors.black, blurRadius: 0, offset: Offset(5, 5)),
        ],
      ),
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
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _miniBadge(badge),
            ],
          ),
          const SizedBox(height: 12),
          ...metrics.map((item) => _opsBar(item, maxValue)),
        ],
      ),
    );
  }

  Widget _adminOperationsChartCard() {
    return _metricsAnalyticsChartCard(
      'Analytics Operasional',
      <_OpsMetric>[
        _OpsMetric(
          label: 'Stock Out',
          value: _todayStockOut,
          icon: Icons.local_shipping_rounded,
          color: Theme.of(context).colorScheme.primary,
          onTap: () => _open(const StockOutPage()),
        ),
        _OpsMetric(
          label: 'Stok Rendah',
          value: _lowStock,
          icon: Icons.warning_amber_rounded,
          color: Theme.of(context).colorScheme.secondary,
          onTap: () => _open(const LowStockPage()),
        ),
        _OpsMetric(
          label: 'Task Review',
          value: _allOpenTasks,
          icon: Icons.task_alt_rounded,
          color: Theme.of(context).colorScheme.tertiary,
          onTap: () => _open(const TaskPage()),
        ),
        _OpsMetric(
          label: 'Pembelian',
          value: _pendingPurchase,
          icon: Icons.verified_rounded,
          color: Theme.of(context).colorScheme.primary,
          onTap: () => _open(const PurchaseVerificationPage()),
        ),
        _OpsMetric(
          label: 'Produksi',
          value: _runningProduction,
          icon: Icons.precision_manufacturing_rounded,
          color: Theme.of(context).colorScheme.secondary,
          onTap: () => _open(const StockProgressPage()),
        ),
        _OpsMetric(
          label: 'People Ops',
          value: _todayAttendance,
          icon: Icons.groups_rounded,
          color: Theme.of(context).colorScheme.tertiary,
          onTap: () => _open(const HrPerformancePage()),
        ),
      ],
    );
  }

  Widget _opsBar(_OpsMetric item, int maxValue) {
    final fraction = maxValue <= 0
        ? 0.0
        : (item.value / maxValue).clamp(0.06, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.zero,
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.zero,
                color: item.color.withOpacity(0.12),
                border: Border.all(color: item.color.withOpacity(0.30)),
              ),
              child: Icon(item.icon, color: item.color, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      Text(
                        item.value.toString(),
                        style: TextStyle(
                          color: item.color,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Stack(
                    children: [
                      Container(
                        height: 9,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.zero,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.08),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: fraction,
                        child: Container(
                          height: 9,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.zero,
                            color: item.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: item.color, size: 18),
          ],
        ),
      ),
    );
  }

  List<Widget> _roleAnalyticsContent() {
    final role = _role;
    final title = 'Analytics ${_roleLabel(role)}';
    final managedTasks = _isManagementRole ? _allOpenTasks : _myOpenTasks;
    final cards = <Widget>[
      _sectionHeader(title),
      const SizedBox(height: 10),
    ];

    List<_OpsMetric> metricsForRole() {
      if (_isFinance) {
        return <_OpsMetric>[
          _OpsMetric(
            label: 'Laba Bersih',
            value: _financeNetProfit.abs().round(),
            icon: Icons.account_balance_wallet_rounded,
            color: Theme.of(context).colorScheme.primary,
            onTap: () => _open(const FinanceReportPage()),
          ),
          _OpsMetric(
            label: 'Omzet',
            value: _financeOmzet.abs().round(),
            icon: Icons.sell_rounded,
            color: Theme.of(context).colorScheme.primary,
            onTap: () => _open(const FinanceReportPage()),
          ),
          _OpsMetric(
            label: 'Order Finance',
            value: _financeOrderCount,
            icon: Icons.receipt_long_rounded,
            color: Theme.of(context).colorScheme.secondary,
            onTap: () => _open(const FinanceReportPage()),
          ),
          _OpsMetric(
            label: 'Abnormal',
            value: _financeAbnormalCount,
            icon: Icons.warning_amber_rounded,
            color: Theme.of(context).colorScheme.error,
            onTap: () => _open(const FinanceReportPage(initialTabIndex: 6)),
          ),
          _OpsMetric(
            label: 'Pembelian',
            value: _pendingPurchase,
            icon: Icons.verified_rounded,
            color: Theme.of(context).colorScheme.secondary,
            onTap: () => _open(const PurchaseVerificationPage()),
          ),
        ];
      }
      if (_isAdmin || _isOperationalAdmin) {
        return <_OpsMetric>[
          _OpsMetric(
              label: 'Stock Out',
              value: _todayStockOut,
              icon: Icons.local_shipping_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(const StockOutPage())),
          _OpsMetric(
              label: 'Stok Rendah',
              value: _lowStock,
              icon: Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const LowStockPage())),
          _OpsMetric(
              label: 'Task Review',
              value: _allOpenTasks,
              icon: Icons.task_alt_rounded,
              color: Theme.of(context).colorScheme.tertiary,
              onTap: () => _open(const TaskPage())),
          _OpsMetric(
              label: 'Pembelian',
              value: _pendingPurchase,
              icon: Icons.verified_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(const PurchaseVerificationPage())),
          _OpsMetric(
              label: 'Produksi',
              value: _runningProduction,
              icon: Icons.precision_manufacturing_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const StockProgressPage())),
          _OpsMetric(
              label: 'People Ops',
              value: _todayAttendance,
              icon: Icons.groups_rounded,
              color: Theme.of(context).colorScheme.tertiary,
              onTap: () => _open(const HrPerformancePage())),
        ];
      }
      if (role == 'warehouse') {
        return <_OpsMetric>[
          _OpsMetric(
              label: 'Stock Out Hari Ini',
              value: _todayStockOut,
              icon: Icons.qr_code_scanner_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(const StockOutPage())),
          _OpsMetric(
              label: 'Stock In Hari Ini',
              value: _todayStockIn,
              icon: Icons.qr_code_scanner_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(const StockInPage())),
          _OpsMetric(
              label: 'Stok Rendah',
              value: _lowStock,
              icon: Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const LowStockPage())),
          _OpsMetric(
              label: 'SKU Aktif',
              value: _activeProducts,
              icon: Icons.inventory_2_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const ProductListPage())),
        ];
      }
      if (role == 'production' || role == 'produksi') {
        return <_OpsMetric>[
          _OpsMetric(
              label: 'Produksi Aktif',
              value: _runningProduction,
              icon: Icons.precision_manufacturing_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(const StockProgressPage())),
          _OpsMetric(
              label: 'Pembelian Pending',
              value: _pendingPurchase,
              icon: Icons.shopping_cart_checkout_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const PurchaseVerificationPage())),
          _OpsMetric(
              label: 'Task Saya',
              value: _myOpenTasks,
              icon: Icons.task_alt_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const TaskPage())),
          _OpsMetric(
              label: 'Supplier',
              value: _pendingPurchase,
              icon: Icons.storefront_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(const SupplierPage())),
        ];
      }
      if (role == 'hr') {
        return <_OpsMetric>[
          _OpsMetric(
              label: 'Absensi Hari Ini',
              value: _todayAttendance,
              icon: Icons.how_to_reg_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(AbsensiPage(currentUser: _requiredAppUser))),
          _OpsMetric(
              label: 'Telat',
              value: _lateAttendance,
              icon: Icons.schedule_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const HrPerformancePage())),
          _OpsMetric(
              label: 'Absen',
              value: _absentAttendance,
              icon: Icons.person_off_rounded,
              color: Theme.of(context).colorScheme.error,
              onTap: () => _open(const HrPerformancePage())),
          _OpsMetric(
              label: 'Task Review',
              value: _allOpenTasks,
              icon: Icons.task_alt_rounded,
              color: Theme.of(context).colorScheme.tertiary,
              onTap: () => _open(const TaskPage())),
        ];
      }
      if (role == 'host_live') {
        return <_OpsMetric>[
          _OpsMetric(
              label: 'Live Hari Ini',
              value: _myTodayLive,
              icon: Icons.live_tv_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(const HostLivePage())),
          _OpsMetric(
              label: 'Live Review',
              value: _pendingLiveReview,
              icon: Icons.fact_check_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const HostLivePage())),
          _OpsMetric(
              label: 'Task Saya',
              value: _myOpenTasks,
              icon: Icons.task_alt_rounded,
              color: Theme.of(context).colorScheme.tertiary,
              onTap: () => _open(const TaskPage())),
        ];
      }
      if (role == 'content_creator') {
        return <_OpsMetric>[
          _OpsMetric(
              label: 'Konten Aktif',
              value: _contentTotal,
              icon: Icons.video_collection_rounded,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => _open(const ContentMonitoringPage())),
          _OpsMetric(
              label: 'Deadline Dekat',
              value: _contentDueSoon,
              icon: Icons.schedule_rounded,
              color: Theme.of(context).colorScheme.secondary,
              onTap: () => _open(const ContentMonitoringPage())),
          _OpsMetric(
              label: 'Task Saya',
              value: _myOpenTasks,
              icon: Icons.task_alt_rounded,
              color: Theme.of(context).colorScheme.tertiary,
              onTap: () => _open(const TaskPage())),
        ];
      }
      return <_OpsMetric>[
        _OpsMetric(
            label: 'Task Saya',
            value: _myOpenTasks,
            icon: Icons.task_alt_rounded,
            color: Theme.of(context).colorScheme.secondary,
            onTap: () => _open(const TaskPage())),
        _OpsMetric(
            label: 'Absensi Saya',
            value: _myAttendanceLabel == 'Belum' ? 0 : 1,
            icon: Icons.how_to_reg_rounded,
            color: Theme.of(context).colorScheme.primary,
            onTap: () => _open(AbsensiPage(currentUser: _requiredAppUser))),
      ];
    }

    cards.add(_metricsAnalyticsChartCard(
      title,
      metricsForRole(),
      badge: _isAdmin || _isOperationalAdmin ? 'Realtime' : _roleLabel(role),
    ));

    if (_isAdmin || _isOperationalAdmin) {
      cards
        ..add(const SizedBox(height: 12))
        ..add(_roleScopeInfoCard());
    }

    return cards;
  }

  Widget _roleScopeInfoCard() {
    final role = _role;
    final isSuper = AppRolePermissions.isSuperRoleId(role) || _isDemoSuperAdmin;
    final title =
        isSuper ? 'Analytics Super Admin' : 'Analytics ${_roleLabel(role)}';
    final subtitle = isSuper
        ? 'Ringkasan lintas finance, stock, marketplace, produksi, dan people ops.'
        : 'Ringkasan data disesuaikan dengan role aktif.';
    final items = <String>[
      'Finance ${_shortRupiah(_financeNetProfit)}',
      'Order $_financeOrderCount',
      'Stock risk $_lowStock',
      'Task ${_isManagementRole ? _allOpenTasks : _myOpenTasks}',
    ];
    return NiceCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics_rounded,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: items.map((item) => _miniBadge(item)).toList(),
          ),
        ],
      ),
    );
  }

  Widget _superAdminRecommendationCard() {
    const items = [
      'Permission matrix per role',
      'System health dan status job',
      'Safe maintenance cache/antrean',
      'Backup center dan audit activity',
    ];

    return NiceCard(
      borderColor: Theme.of(context).colorScheme.tertiary,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  border: Border.all(color: Colors.black, width: 2),
                  borderRadius: BorderRadius.zero,
                ),
                child: Icon(Icons.auto_awesome_rounded,
                    color: Theme.of(context).colorScheme.onPrimary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Rekomendasi Super Admin',
                      style:
                          TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Ide fitur berikutnya untuk kontrol sistem.',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: items
                .map(
                  (item) => Chip(
                    avatar: Icon(Icons.check_circle_rounded, size: 16),
                    label: Text(item),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

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
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.outline,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  // ── Finance content ──────────────────────────────────────────────────────────
  List<Widget> _financeContent() {
    return [
      _sectionHeader('Analytics Finance'),
      const SizedBox(height: 10),
      _financeCard(
        'Laporan Keuangan',
        'Pantau omzet, HPP, biaya, dan laba rugi.',
        Icons.account_balance_wallet_rounded,
        Theme.of(context).colorScheme.primary,
        () => _open(const FinanceReportPage()),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Absensi',
        'Check-in dan check-out karyawan dengan validasi lokasi.',
        Icons.how_to_reg_rounded,
        Theme.of(context).colorScheme.secondary,
        () => _open(AbsensiPage(currentUser: _requiredAppUser)),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Tugas',
        'Lihat task yang ditugaskan ke akun finance.',
        Icons.task_alt_rounded,
        Theme.of(context).colorScheme.primary,
        () => _open(const TaskPage()),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Verifikasi Pembelian',
        'Cek nota dan status pembelian pending.',
        Icons.verified_rounded,
        Theme.of(context).colorScheme.primary,
        () => _open(const PurchaseVerificationPage()),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Export Data Finance',
        'Download finance + seluruh marketplace di laporan keuangan ke XLSX.',
        Icons.file_download_rounded,
        Theme.of(context).colorScheme.secondary,
        () => _open(const DataExportImportPage()),
      ),
      const SizedBox(height: 10),
      _financeCard(
        'Abnormal Marketplace',
        'Temukan pesanan dengan payout atau margin di luar batas.',
        Icons.warning_amber_rounded,
        Theme.of(context).colorScheme.secondary,
        () => _open(const FinanceReportPage(initialTabIndex: 6)),
      ),
    ];
  }

  Widget _financeCard(String title, String subtitle, IconData icon, Color color,
      VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.zero,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: _pixelDecoration(color),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.zero,
                  color: color.withOpacity(0.12),
                  border: Border.all(color: color.withOpacity(0.25)),
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(0.60),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: color.withOpacity(0.6), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuCard(_DashboardMenu item) {
    final color = _menuAccent(item);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: _pixelDecoration(color),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.zero,
                  color: color.withOpacity(0.14),
                  border: Border.all(color: Colors.black, width: 2),
                ),
                child: Icon(item.icon, color: color, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title.toUpperCase(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(0.60),
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.zero,
                  color: color.withOpacity(0.10),
                  border: Border.all(color: Colors.black, width: 1.5),
                ),
                child:
                    Icon(Icons.chevron_right_rounded, color: color, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Bottom nav ───────────────────────────────────────────────────────────────
  Widget _bottomQuickBar() {
    final canStockOut = _canStockOut();
    final baseMenus = _bottomMenus();
    final roleMenus = _roleMenus();
    final maxVisible = canStockOut ? 3 : 4;
    final menus = baseMenus.take(maxVisible).toList();
    if (roleMenus.length > menus.length) {
      menus.add(_DashboardMenu(
        Icons.apps_rounded,
        'More',
        'Buka semua menu',
        _showMoreMenu,
        shortTitle: 'More',
      ));
    }
    final leftItems = canStockOut ? menus.take(2).toList() : menus;
    final rightItems =
        canStockOut ? menus.skip(2).toList() : const <_DashboardMenu>[];
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            14, 0, 14, math.max(10, bottomInset > 0 ? bottomInset : 10)),
        child: SizedBox(
          height: canStockOut ? 100 : 74,
          child: Stack(
            alignment: Alignment.bottomCenter,
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.zero,
                  child: Container(
                    height: 70,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.zero,
                      border: Border.all(color: Colors.black, width: 2.5),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black,
                          blurRadius: 0,
                          offset: Offset(4, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        for (final item in leftItems)
                          Expanded(child: _bottomBarItem(item)),
                        if (canStockOut) const SizedBox(width: 82),
                        for (final item in rightItems)
                          Expanded(child: _bottomBarItem(item)),
                      ],
                    ),
                  ),
                ),
              ),
              if (canStockOut)
                Positioned(
                  bottom: 13,
                  child: _stockOutBottomButton(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stockOutBottomButton() {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.zero,
      elevation: 14,
      shadowColor: Theme.of(context).colorScheme.primary.withOpacity(0.30),
      child: InkWell(
        borderRadius: BorderRadius.zero,
        onTap: () => _open(const StockOutPage()),
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.primary,
            border: Border.all(color: Colors.black, width: 3),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.28),
                blurRadius: 0,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(Icons.qr_code_scanner_rounded,
              size: 31, color: Theme.of(context).colorScheme.onPrimary),
        ),
      ),
    );
  }

  Widget _bottomBarItem(_DashboardMenu item) {
    final color = _menuAccent(item);
    final label = item.shortTitle ?? item.title;
    return Tooltip(
      message: item.title,
      child: Semantics(
        label: item.title,
        button: true,
        child: InkResponse(
          radius: 24,
          onTap: item.onTap,
          child: Center(
            child: SizedBox(
              height: 52,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 34,
                    height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.zero,
                      color: color.withOpacity(0.14),
                      border: Border.all(color: color.withOpacity(0.20)),
                    ),
                    child: Icon(item.icon, size: 19, color: color),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMoreMenu() {
    final menus = _filterMenusByPlan(_roleMenus());
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: (Theme.of(context).cardColor),
      builder: (context) {
        return Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
          decoration: BoxDecoration(
            color: (Theme.of(context).cardColor),
            borderRadius: BorderRadius.zero,
            border:
                Border.all(color: (Theme.of(context).dividerColor), width: 1.4),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).dividerColor.withOpacity(0.16),
                blurRadius: 0,
                offset: const Offset(4, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondary,
                      borderRadius: BorderRadius.zero,
                    ),
                    child: Icon(Icons.apps_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Semua Menu',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.66,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: menus
                      .map(
                        (menu) => ListTile(
                          leading: Icon(menu.icon, color: _menuAccent(menu)),
                          title: Text(
                            menu.title,
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                          subtitle: menu.subtitle.isEmpty
                              ? null
                              : Text(
                                  menu.subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: Icon(Icons.chevron_right_rounded),
                          onTap: () {
                            Navigator.pop(context);
                            menu.onTap();
                          },
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _canStockOut() =>
      !_isDemoSuperAdmin && (_isAdmin || _isOperationalAdmin || _isWarehouse);

  _DashboardMenu _attendanceMenu() {
    return _DashboardMenu(
      Icons.how_to_reg_rounded,
      'Absensi',
      'Check-in dan check-out karyawan dengan validasi lokasi.',
      () => _open(AbsensiPage(currentUser: _requiredAppUser)),
    );
  }

  List<_DashboardMenu> _superAdminAllRoleMenus() {
    return [
      _DashboardMenu(
          Icons.account_balance_wallet_rounded,
          'Keuangan',
          'Pantau omzet, HPP, biaya, margin, dan laba rugi.',
          () => _open(const FinanceReportPage())),
      _DashboardMenu(
          Icons.verified_rounded,
          'Verifikasi Pembelian',
          'Review nota pembelian yang masuk.',
          () => _open(const PurchaseVerificationPage())),
      _DashboardMenu(
          Icons.warning_amber_rounded,
          'Abnormal Marketplace',
          'Temukan pesanan dengan payout atau margin di luar batas.',
          () => _open(const FinanceReportPage(initialTabIndex: 6))),
      _DashboardMenu(
          Icons.receipt_long_rounded,
          'Arus Kas',
          'Pantau mutasi dana masuk dan keluar.',
          () => _open(const FinanceReportPage(initialTabIndex: 3))),
      _DashboardMenu(
          Icons.file_download_rounded,
          'Export / Import Data',
          'Backup data tenant, export finance, dan import data operasional.',
          () => _open(const DataExportImportPage())),
      _DashboardMenu(
          Icons.inventory_2_rounded,
          'Master SKU',
          'Kelola barang, barcode, stok minimum, dan HPP.',
          () => _open(ProductListPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.qr_code_scanner_rounded,
          'Stok Keluar',
          'Scan barcode pesanan untuk update stok keluar.',
          () => _open(const StockOutPage())),
      _DashboardMenu(
          Icons.add_box_rounded,
          'Stock In',
          'Tambah stok masuk dari produksi, retur, atau adjustment.',
          () => _open(const StockInPage())),
      _DashboardMenu(
          Icons.history_rounded,
          'Riwayat Stock Out',
          'Cek pengeluaran barang dan validasi resi.',
          () => _open(const StockHistoryPage())),
      _DashboardMenu(
          Icons.warning_amber_rounded,
          'Stok Rendah',
          'Pantau produk yang sudah di bawah batas minimum.',
          () => _open(const LowStockPage())),
      _DashboardMenu(
          Icons.storefront_rounded,
          'Akun Marketplace',
          'Kelola akun Shopee/TikTok dan sinkronisasi.',
          () => _open(MarketplaceAccountsPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.receipt_long_rounded,
          'Order Marketplace',
          'Tarik dan cek order aktif untuk packing.',
          () => _open(MarketplaceOrdersPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.link_rounded,
          'Mapping SKU',
          'Cocokkan SKU lokal dengan varian marketplace.',
          () =>
              _open(MarketplaceSkuMappingPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.sync_rounded,
          'Sync Stock',
          'Simulasi dan kirim stok real ke marketplace.',
          () => _open(MarketplaceStockSyncPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.compare_arrows_rounded,
          'Selisih Stock',
          'Bandingkan stok lokal dengan stok marketplace.',
          () => _open(
              MarketplaceStockDifferencePage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.rule_rounded,
          'Review Stock Out',
          'Review stock out tanpa mode match marketplace.',
          () => _open(
              MarketplaceStockOutReviewPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.assignment_return_rounded,
          'Refund & Retur',
          'Pantau retur/cancel dan keputusan stok masuk.',
          () => _open(MarketplaceRefundMonitorPage(
              currentUser: _requiredAppUser, accounts: const []))),
      _DashboardMenu(
          Icons.sync_problem_rounded,
          'Monitor Job',
          'Pantau update order, payout, dan antrean.',
          () => _open(const MarketplaceJobMonitorPage())),
      _DashboardMenu(
          Icons.shopping_cart_checkout_rounded,
          'Pembelian Barang / Bahan',
          'Buat dan pantau pembelian barang atau bahan.',
          () => _open(const PurchaseRequestPage())),
      _DashboardMenu(
          Icons.precision_manufacturing_rounded,
          'Produksi Berjalan',
          'Pantau stok dalam proses produksi.',
          () => _open(const StockProgressPage())),
      _DashboardMenu(Icons.store_rounded, 'Supplier',
          'Kelola data supplier pembelian.', () => _open(const SupplierPage())),
      _attendanceMenu(),
      _DashboardMenu(
          Icons.analytics_rounded,
          'Performance Monitor',
          'Pantau telat, absen, dan aktivitas karyawan.',
          () => _open(const HrPerformancePage())),
      _DashboardMenu(
          Icons.location_on_rounded,
          'Set Lokasi',
          'Atur titik lokasi kerja untuk absensi.',
          () => _open(const WorkLocationPage())),
      _DashboardMenu(
          Icons.manage_accounts_rounded,
          'User Management',
          'Kelola akun, role, dan status user.',
          () => _open(const UserManagementPage())),
      _DashboardMenu(
          Icons.manage_search_rounded,
          'Audit Log',
          'Lihat dan hapus riwayat aktivitas sistem.',
          () => _open(const AuditLogPage())),
      _DashboardMenu(
          Icons.task_alt_rounded,
          'Monitoring Tugas',
          'Buat, cek, dan verifikasi task seluruh role.',
          () => _open(const TaskPage())),
      _DashboardMenu(
          Icons.video_collection_rounded,
          'Verifikasi Konten',
          'Review konten creator: approve, revisi, atau reject.',
          () => _open(const ContentMonitoringPage())),
      _DashboardMenu(Icons.live_tv_rounded, 'Verifikasi Live',
          'Review bukti kerja host live.', () => _open(const HostLivePage())),
      _DashboardMenu(
          Icons.live_tv_rounded,
          'Host Live',
          'Upload bukti sesi live sesuai jadwal.',
          () => _open(const HostLivePage())),
    ];
  }

  // ── Role menus ───────────────────────────────────────────────────────────────
  List<_DashboardMenu> _roleMenus() {
    final role = _role;

    if (_isAdmin || _isPlatformOwner) {
      return _superAdminAllRoleMenus();
    }

    if (role == 'warehouse') {
      return [
        _DashboardMenu(
            Icons.qr_code_scanner_rounded,
            'Stok Keluar',
            'Scan barcode pesanan untuk update stok keluar.',
            () => _open(const StockOutPage())),
        _DashboardMenu(
            Icons.inventory_2_rounded,
            'Master SKU',
            'Kelola barang, barcode, stok minimum, dan HPP.',
            () => _open(const ProductListPage())),
        _DashboardMenu(
            Icons.add_box_rounded,
            'Stok Masuk',
            'Tambah stok masuk dari produksi atau retur.',
            () => _open(const StockInPage())),
        _attendanceMenu(),
        _DashboardMenu(
            Icons.history_rounded,
            'Riwayat',
            'Cek pengeluaran barang dan validasi resi.',
            () => _open(const StockHistoryPage())),
        _DashboardMenu(
            Icons.compare_arrows_rounded,
            'Selisih Stok',
            'Bandingkan stok lokal dengan marketplace.',
            () => _open(
                MarketplaceStockDifferencePage(currentUser: _requiredAppUser))),
        _DashboardMenu(
            Icons.assignment_return_rounded,
            'Refund & Retur',
            'Pantau pesanan retur atau cancel.',
            () => _open(MarketplaceRefundMonitorPage(
                currentUser: _requiredAppUser, accounts: const []))),
      ];
    }
    if (_isOperationalAdmin) {
      return [
        _DashboardMenu(
            Icons.inventory_2_rounded,
            'Master SKU',
            'Kelola barang, barcode, stok minimum, dan data operasional SKU.',
            () => _open(ProductListPage(currentUser: _requiredAppUser))),
        _DashboardMenu(
            Icons.storefront_rounded,
            'Akun Marketplace',
            'Hubungkan ulang toko dan atur sinkronisasi marketplace.',
            () =>
                _open(MarketplaceAccountsPage(currentUser: _requiredAppUser))),
        _DashboardMenu(
            Icons.receipt_long_rounded,
            'Order Marketplace',
            'Tarik dan cek order aktif untuk proses packing.',
            () => _open(MarketplaceOrdersPage(currentUser: _requiredAppUser))),
        _DashboardMenu(
            Icons.link_rounded,
            'Mapping SKU',
            'Cocokkan SKU lokal dengan produk dan varian marketplace.',
            () => _open(
                MarketplaceSkuMappingPage(currentUser: _requiredAppUser))),
        _DashboardMenu(
            Icons.sync_rounded,
            'Sync Stock',
            'Cek simulasi, kirim stok real, dan pantau pembaruan.',
            () =>
                _open(MarketplaceStockSyncPage(currentUser: _requiredAppUser))),
        _DashboardMenu(
            Icons.compare_arrows_rounded,
            'Selisih Stock',
            'Bandingkan stok lokal dengan stok marketplace.',
            () => _open(
                MarketplaceStockDifferencePage(currentUser: _requiredAppUser))),
        _DashboardMenu(
            Icons.rule_rounded,
            'Review Stock Out',
            'Review stock out tanpa mode match marketplace.',
            () => _open(
                MarketplaceStockOutReviewPage(currentUser: _requiredAppUser))),
        _DashboardMenu(
            Icons.assignment_return_rounded,
            'Refund & Retur',
            'Pantau retur/cancel dan keputusan stok masuk.',
            () => _open(MarketplaceRefundMonitorPage(
                currentUser: _requiredAppUser, accounts: const []))),
        _DashboardMenu(
            Icons.sync_problem_rounded,
            'Monitor Job',
            'Pantau pembaruan order, payout, dan status antrean.',
            () => _open(const MarketplaceJobMonitorPage())),
        _DashboardMenu(
            Icons.manage_accounts_rounded,
            'User Operasional',
            'Kelola role operasional non-sensitif.',
            () => _open(const UserManagementPage())),
        _DashboardMenu(
            Icons.qr_code_scanner_rounded,
            'Stock In',
            'Tambah stok masuk dari produksi, retur, atau adjustment.',
            () => _open(const StockInPage())),
        _DashboardMenu(
            Icons.history_rounded,
            'Riwayat Stock Out',
            'Cek pengeluaran barang dan validasi resi.',
            () => _open(const StockHistoryPage())),
        _attendanceMenu(),
        _DashboardMenu(Icons.task_alt_rounded, 'Monitoring Tugas',
            'Cek progres tugas karyawan.', () => _open(const TaskPage())),
        _DashboardMenu(
            Icons.video_collection_rounded,
            'Verifikasi Konten',
            'Review konten creator.',
            () => _open(const ContentMonitoringPage())),
        _DashboardMenu(Icons.live_tv_rounded, 'Verifikasi Live',
            'Review bukti kerja host live.', () => _open(const HostLivePage())),
        _DashboardMenu(
            Icons.shopping_cart_checkout_rounded,
            'Pembelian Barang / Bahan',
            'Buat dan pantau pembelian barang atau bahan.',
            () => _open(const PurchaseRequestPage())),
        _DashboardMenu(
            Icons.precision_manufacturing_rounded,
            'Produksi Berjalan',
            'Pantau stok dalam proses produksi.',
            () => _open(const StockProgressPage())),
        _DashboardMenu(
            Icons.store_rounded,
            'Supplier',
            'Kelola data supplier pembelian.',
            () => _open(const SupplierPage())),
      ];
    }
    if (role == 'finance') {
      return [
        _DashboardMenu(
            Icons.account_balance_wallet_rounded,
            'Laporan Keuangan',
            'Pantau omzet, HPP, biaya, margin, dan laba rugi.',
            () => _open(const FinanceReportPage())),
        _DashboardMenu(
            Icons.verified_rounded,
            'Verifikasi Pembelian',
            'Review nota pembelian yang masuk.',
            () => _open(const PurchaseVerificationPage())),
        _DashboardMenu(
            Icons.warning_amber_rounded,
            'Abnormal Marketplace',
            'Temukan pesanan dengan payout atau margin di luar batas.',
            () => _open(const FinanceReportPage(initialTabIndex: 6))),
        _DashboardMenu(
            Icons.receipt_long_rounded,
            'Arus Kas',
            'Pantau mutasi dana masuk dan keluar.',
            () => _open(const FinanceReportPage(initialTabIndex: 3))),
        _attendanceMenu(),
        _DashboardMenu(
            Icons.task_alt_rounded,
            'Tugas Finance',
            'Lihat task yang ditugaskan ke akun finance.',
            () => _open(const TaskPage())),
        _DashboardMenu(
            Icons.file_download_rounded,
            'Export Data',
            'Download data finance ke Excel.',
            () => _open(const DataExportImportPage())),
      ];
    }
    if (role == 'production' || role == 'produksi') {
      return [
        _DashboardMenu(
            Icons.shopping_cart_checkout_rounded,
            'Pembelian',
            'Input kebutuhan barang dan lampirkan nota.',
            () => _open(const PurchaseRequestPage())),
        _attendanceMenu(),
        _DashboardMenu(
            Icons.task_alt_rounded,
            'Tugas',
            'Lihat task yang ditugaskan ke akun produksi.',
            () => _open(const TaskPage())),
        _DashboardMenu(
            Icons.precision_manufacturing_rounded,
            'Produksi Berjalan',
            'Pantau stok dalam proses produksi.',
            () => _open(const StockProgressPage())),
        _DashboardMenu(
            Icons.storefront_rounded,
            'Supplier',
            'Kelola data supplier pembelian.',
            () => _open(const SupplierPage())),
      ];
    }
    if (role == 'host_live') {
      return [
        _DashboardMenu(
            Icons.live_tv_rounded,
            'Host Live',
            'Upload bukti sesi live sesuai jadwal.',
            () => _open(const HostLivePage())),
        _attendanceMenu(),
        _DashboardMenu(
            Icons.task_alt_rounded,
            'Tugas',
            'Lihat tugas dan update progres pekerjaan.',
            () => _open(const TaskPage())),
      ];
    }
    if (role == 'hr') {
      return [
        _DashboardMenu(
            Icons.analytics_rounded,
            'Performance Review',
            'Pantau telat, absen, dan aktivitas karyawan.',
            () => _open(const HrPerformancePage())),
        _DashboardMenu(
            Icons.video_collection_rounded,
            'Verifikasi Konten',
            'Review konten creator: approve, revisi, atau reject.',
            () => _open(const ContentMonitoringPage())),
        _attendanceMenu(),
        _DashboardMenu(Icons.live_tv_rounded, 'Verifikasi Live',
            'Review bukti kerja host live.', () => _open(const HostLivePage())),
        _DashboardMenu(Icons.task_alt_rounded, 'Monitoring Tugas',
            'Cek progres tugas karyawan.', () => _open(const TaskPage())),
      ];
    }
    if (role == 'content_creator') {
      return [
        _DashboardMenu(
            Icons.task_alt_rounded,
            'Tugas Konten',
            'Lihat brief dan upload bukti konten.',
            () => _open(const TaskPage())),
        _attendanceMenu(),
        _DashboardMenu(
            Icons.video_collection_rounded,
            'Konten',
            'Tambah konten, update progress, dan upload bukti.',
            () => _open(const ContentMonitoringPage())),
      ];
    }
    // Super admin / demo_super_admin
    return [
      _DashboardMenu(
          Icons.qr_code_scanner_rounded,
          'Stok Keluar',
          'Scan barcode pesanan untuk update stok keluar.',
          () => _open(const StockOutPage())),
      _DashboardMenu(
          Icons.inventory_2_rounded,
          'Master SKU',
          'Kelola barang, barcode, stok minimum, dan HPP.',
          () => _open(ProductListPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.account_balance_wallet_rounded,
          'Keuangan',
          'Pantau omzet, HPP, biaya, dan laba rugi.',
          () => _open(const FinanceReportPage())),
      _DashboardMenu(
          Icons.precision_manufacturing_rounded,
          'Produksi',
          'Pantau stok dalam proses produksi.',
          () => _open(const StockProgressPage())),
      _DashboardMenu(
          Icons.storefront_rounded,
          'Akun Marketplace',
          'Kelola akun Shopee/TikTok dan sinkronisasi.',
          () => _open(MarketplaceAccountsPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.receipt_long_rounded,
          'Order Marketplace',
          'Tarik dan cek order aktif untuk packing.',
          () => _open(MarketplaceOrdersPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.link_rounded,
          'Mapping SKU',
          'Cocokkan SKU lokal dengan varian marketplace.',
          () =>
              _open(MarketplaceSkuMappingPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.sync_rounded,
          'Sync Stock',
          'Simulasi dan kirim stok real ke marketplace.',
          () => _open(MarketplaceStockSyncPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.compare_arrows_rounded,
          'Selisih Stock',
          'Bandingkan stok lokal dengan stok marketplace.',
          () => _open(
              MarketplaceStockDifferencePage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.rule_rounded,
          'Review Stock Out',
          'Review stock out tanpa mode match marketplace.',
          () => _open(
              MarketplaceStockOutReviewPage(currentUser: _requiredAppUser))),
      _DashboardMenu(
          Icons.assignment_return_rounded,
          'Refund & Retur',
          'Pantau retur/cancel dan keputusan stok masuk.',
          () => _open(MarketplaceRefundMonitorPage(
              currentUser: _requiredAppUser, accounts: const []))),
      _DashboardMenu(
          Icons.sync_problem_rounded,
          'Monitor Job',
          'Pantau update order, payout, dan antrean.',
          () => _open(const MarketplaceJobMonitorPage())),
      _attendanceMenu(),
      _DashboardMenu(
          Icons.task_alt_rounded,
          'Monitoring Tugas',
          'Buat, cek, dan verifikasi task seluruh role.',
          () => _open(const TaskPage())),
      _DashboardMenu(
          Icons.qr_code_scanner_rounded,
          'Stock In',
          'Tambah stok masuk dari produksi atau retur.',
          () => _open(const StockInPage())),
      _DashboardMenu(
          Icons.history_rounded,
          'Riwayat Out',
          'Cek pengeluaran barang dan validasi resi.',
          () => _open(const StockHistoryPage())),
    ];
  }

  List<_DashboardMenu> _bottomMenus() {
    final role = _role;
    if (_isAdmin || _isPlatformOwner) {
      return [
        _DashboardMenu(Icons.account_balance_wallet_rounded, 'Keuangan', '',
            () => _open(const FinanceReportPage()),
            shortTitle: 'Finance'),
        _DashboardMenu(Icons.receipt_long_rounded, 'Order', '',
            () => _open(MarketplaceOrdersPage(currentUser: _requiredAppUser)),
            shortTitle: 'Order'),
        _DashboardMenu(Icons.inventory_2_rounded, 'Master SKU', '',
            () => _open(ProductListPage(currentUser: _requiredAppUser)),
            shortTitle: 'SKU'),
        _DashboardMenu(Icons.analytics_rounded, 'Performance', '',
            () => _open(const HrPerformancePage()),
            shortTitle: 'People'),
      ];
    }
    if (role == 'finance') {
      return [
        _DashboardMenu(Icons.account_balance_wallet_rounded, 'Laporan', '',
            () => _open(const FinanceReportPage()),
            shortTitle: 'Laporan'),
        _DashboardMenu(Icons.verified_rounded, 'Verifikasi', '',
            () => _open(const PurchaseVerificationPage()),
            shortTitle: 'Verifikasi'),
        _DashboardMenu(Icons.warning_amber_rounded, 'Abnormal', '',
            () => _open(const FinanceReportPage(initialTabIndex: 6)),
            shortTitle: 'Abnormal'),
        _DashboardMenu(Icons.receipt_long_rounded, 'Arus Kas', '',
            () => _open(const FinanceReportPage(initialTabIndex: 3)),
            shortTitle: 'Arus Kas'),
        _DashboardMenu(
            Icons.task_alt_rounded, 'Tugas', '', () => _open(const TaskPage()),
            shortTitle: 'Tugas'),
      ];
    }
    if (role == 'warehouse') {
      return [
        _DashboardMenu(Icons.inventory_2_rounded, 'Master SKU', '',
            () => _open(const ProductListPage()),
            shortTitle: 'SKU'),
        _DashboardMenu(Icons.qr_code_scanner_rounded, 'Stock In', '',
            () => _open(const StockInPage()),
            shortTitle: 'Stock In'),
        _DashboardMenu(Icons.history_rounded, 'Riwayat', '',
            () => _open(const StockHistoryPage()),
            shortTitle: 'Riwayat'),
        _DashboardMenu(
            Icons.assignment_return_rounded,
            'Retur',
            '',
            () => _open(MarketplaceRefundMonitorPage(
                currentUser: _requiredAppUser, accounts: const [])),
            shortTitle: 'Retur'),
      ];
    }
    if (role == 'production' || role == 'produksi') {
      return [
        _DashboardMenu(Icons.shopping_cart_checkout_rounded, 'Pembelian', '',
            () => _open(const PurchaseRequestPage()),
            shortTitle: 'Beli'),
        _DashboardMenu(Icons.storefront_rounded, 'Supplier', '',
            () => _open(const SupplierPage()),
            shortTitle: 'Supplier'),
        _DashboardMenu(
            Icons.task_alt_rounded, 'Tugas', '', () => _open(const TaskPage()),
            shortTitle: 'Tugas'),
      ];
    }
    if (role == 'host_live') {
      return [
        _DashboardMenu(Icons.live_tv_rounded, 'Live', '',
            () => _open(const HostLivePage()),
            shortTitle: 'Live'),
        _DashboardMenu(
            Icons.task_alt_rounded, 'Tugas', '', () => _open(const TaskPage()),
            shortTitle: 'Tugas'),
      ];
    }
    if (role == 'hr') {
      return [
        _DashboardMenu(Icons.analytics_rounded, 'Performance', '',
            () => _open(const HrPerformancePage()),
            shortTitle: 'Review'),
        _DashboardMenu(Icons.video_collection_rounded, 'Konten', '',
            () => _open(const ContentMonitoringPage()),
            shortTitle: 'Konten'),
        _DashboardMenu(Icons.live_tv_rounded, 'Live', '',
            () => _open(const HostLivePage()),
            shortTitle: 'Live'),
        _DashboardMenu(
            Icons.task_alt_rounded, 'Tugas', '', () => _open(const TaskPage()),
            shortTitle: 'Tugas'),
      ];
    }
    if (role == 'content_creator') {
      return [
        _DashboardMenu(
            Icons.task_alt_rounded, 'Tugas', '', () => _open(const TaskPage()),
            shortTitle: 'Tugas'),
        _DashboardMenu(Icons.video_collection_rounded, 'Konten', '',
            () => _open(const ContentMonitoringPage()),
            shortTitle: 'Konten'),
      ];
    }
    if (_isOperationalAdmin) {
      return [
        _DashboardMenu(Icons.receipt_long_rounded, 'Order', '',
            () => _open(MarketplaceOrdersPage(currentUser: _requiredAppUser)),
            shortTitle: 'Order'),
        _DashboardMenu(Icons.storefront_rounded, 'Akun', '',
            () => _open(MarketplaceAccountsPage(currentUser: _requiredAppUser)),
            shortTitle: 'Akun'),
        _DashboardMenu(
            Icons.link_rounded,
            'Mapping',
            '',
            () =>
                _open(MarketplaceSkuMappingPage(currentUser: _requiredAppUser)),
            shortTitle: 'Mapping'),
        _DashboardMenu(
            Icons.sync_rounded,
            'Sync',
            '',
            () =>
                _open(MarketplaceStockSyncPage(currentUser: _requiredAppUser)),
            shortTitle: 'Sync'),
      ];
    }
    return [
      _DashboardMenu(Icons.account_balance_wallet_rounded, 'Laporan', '',
          () => _open(const FinanceReportPage()),
          shortTitle: 'Laporan'),
      _DashboardMenu(Icons.shopping_cart_checkout_rounded, 'Pembelian', '',
          () => _open(const PurchaseRequestPage()),
          shortTitle: 'Beli'),
      _DashboardMenu(Icons.verified_rounded, 'Verifikasi', '',
          () => _open(const PurchaseVerificationPage()),
          shortTitle: 'Verif'),
    ];
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'super_admin':
        return 'Super Admin';
      case 'demo_super_admin':
        return 'Demo Admin';
      case 'admin':
        return 'Admin';
      case 'warehouse':
        return 'Warehouse';
      case 'production':
      case 'produksi':
        return 'Produksi';
      case 'finance':
        return 'Finance';
      case 'host_live':
        return 'Host Live';
      case 'hr':
        return 'HR';
      case 'content_creator':
        return 'Content Creator';
      default:
        return role.isEmpty ? '-' : role;
    }
  }
}

// ── Data classes ─────────────────────────────────────────────────────────────

class _TenantSubscriptionInfo {
  final String status;
  final String planName;
  final String planCode;
  final String billingPeriod;
  final num priceAmount;
  final String currency;
  final DateTime? trialEndsAt;
  final DateTime? currentPeriodEnd;
  final DateTime? createdAt;

  const _TenantSubscriptionInfo({
    required this.status,
    required this.planName,
    required this.planCode,
    required this.billingPeriod,
    required this.priceAmount,
    required this.currency,
    this.trialEndsAt,
    this.currentPeriodEnd,
    this.createdAt,
  });

  factory _TenantSubscriptionInfo.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic value) {
      final raw = value?.toString().trim() ?? '';
      if (raw.isEmpty) return null;
      return DateTime.tryParse(raw)?.toLocal();
    }

    final plan = map['subscription_plans'] is Map
        ? Map<String, dynamic>.from(map['subscription_plans'] as Map)
        : <String, dynamic>{};

    return _TenantSubscriptionInfo(
      status: AppUi.text(map['status'], 'unassigned'),
      planName: AppUi.text(plan['plan_name'], 'Belum ada paket'),
      planCode: AppUi.text(plan['plan_code'], '-'),
      billingPeriod: AppUi.text(plan['billing_period'], '-'),
      priceAmount: AppUi.toNum(plan['price_amount']),
      currency: AppUi.text(plan['currency'], 'IDR'),
      trialEndsAt: parseDate(map['trial_ends_at']),
      currentPeriodEnd: parseDate(map['current_period_end']),
      createdAt: parseDate(map['created_at']),
    );
  }

  String get priceLabel {
    if (priceAmount <= 0)
      return currency.toUpperCase() == 'IDR'
          ? 'Rp 0'
          : '0 ${currency.toUpperCase()}';
    if (currency.toUpperCase() == 'IDR') return AppUi.rupiah(priceAmount);
    return '${AppUi.money(priceAmount)} ${currency.toUpperCase()}';
  }

  String get periodLabel {
    final cleanStatus = status.toLowerCase();
    final target = cleanStatus == 'trialing' ? trialEndsAt : currentPeriodEnd;
    if (target == null) return 'PERIODE -';
    if (cleanStatus == 'trialing') return 'TRIAL S/D ${AppUi.date(target)}';
    return 'AKTIF S/D ${AppUi.date(target)}';
  }
}

class _OpsMetric {
  final String label;
  final int value;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _OpsMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

class _SummaryItem {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onTap;

  const _SummaryItem(this.icon, this.label, this.value, this.color,
      {this.onTap});
}

class _TrendPoint {
  final DateTime date;
  final num omzet;
  final int orders;

  const _TrendPoint({
    required this.date,
    required this.omzet,
    required this.orders,
  });
}

class _AppNotification {
  final String notificationId;
  final String notificationType;
  final String severity;
  final String title;
  final String body;
  final String status;
  final DateTime? readAt;
  final DateTime? lastTriggeredAt;

  const _AppNotification({
    required this.notificationId,
    required this.notificationType,
    required this.severity,
    required this.title,
    required this.body,
    required this.status,
    this.readAt,
    this.lastTriggeredAt,
  });

  factory _AppNotification.localLowStock(int count) {
    return _AppNotification(
      notificationId: '',
      notificationType: 'low_stock',
      severity: 'warning',
      title: 'Stok rendah aktif',
      body:
          '$count SKU lokal sedang berada di bawah atau tepat pada limit minimum.',
      status: 'active',
      lastTriggeredAt: DateTime.now(),
    );
  }

  factory _AppNotification.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic value) {
      final text = value?.toString();
      if (text == null || text.trim().isEmpty) return null;
      return DateTime.tryParse(text);
    }

    return _AppNotification(
      notificationId: AppUi.text(map['notification_id']),
      notificationType: AppUi.text(map['notification_type'], 'info'),
      severity: AppUi.text(map['severity'], 'info'),
      title: AppUi.text(map['title'], 'Notifikasi'),
      body: AppUi.text(map['body'], '-'),
      status: AppUi.text(map['status'], 'active'),
      readAt: parseDate(map['read_at']),
      lastTriggeredAt: parseDate(map['last_triggered_at']),
    );
  }

  Color severityColor(BuildContext context) {
    switch (severity.toLowerCase()) {
      case 'danger':
      case 'error':
        return Theme.of(context).colorScheme.error;
      case 'warning':
        return Theme.of(context).colorScheme.secondary;
      case 'success':
        return Theme.of(context).colorScheme.primary;
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }
}

class _FinanceTrendPainter extends CustomPainter {
  final List<_TrendPoint> points;
  final int? selectedIndex;
  final Color omzetColor;
  final Color orderColor;

  const _FinanceTrendPainter({
    required this.points,
    required this.selectedIndex,
    required this.omzetColor,
    required this.orderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.07)
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    if (points.length < 2) return;

    final maxOmzet =
        points.fold<num>(0, (max, point) => math.max(max, point.omzet.abs()));
    final maxOrders =
        points.fold<int>(0, (max, point) => math.max(max, point.orders));
    final pad = 12.0;
    final chartW = math.max(1.0, size.width - pad * 2);
    final chartH = math.max(1.0, size.height - pad * 2);

    Offset pos(int i, num value, num maxValue) {
      final x = pad + chartW * i / (points.length - 1);
      final normalized =
          maxValue <= 0 ? 0.0 : (value / maxValue).clamp(0, 1).toDouble();
      final y = pad + chartH * (1 - normalized);
      return Offset(x, y);
    }

    Path pathFor(num Function(_TrendPoint point) valueOf, num maxValue) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final p = pos(i, valueOf(points[i]), maxValue);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path;
    }

    void drawSeries(Color color, Path path) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, paint);
    }

    drawSeries(omzetColor, pathFor((p) => p.omzet, maxOmzet));
    drawSeries(
        orderColor, pathFor((p) => p.orders, maxOrders <= 0 ? 1 : maxOrders));

    final selected = selectedIndex;
    if (selected != null && selected >= 0 && selected < points.length) {
      final x = pad + chartW * selected / (points.length - 1);
      final markerPaint = Paint()
        ..color = Colors.white.withOpacity(0.28)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), markerPaint);
      canvas.drawCircle(pos(selected, points[selected].omzet, maxOmzet), 4.5,
          Paint()..color = omzetColor);
      canvas.drawCircle(
          pos(selected, points[selected].orders,
              maxOrders <= 0 ? 1 : maxOrders),
          4.5,
          Paint()..color = orderColor);
    }
  }

  @override
  bool shouldRepaint(covariant _FinanceTrendPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.selectedIndex != selectedIndex ||
        oldDelegate.omzetColor != omzetColor ||
        oldDelegate.orderColor != orderColor;
  }
}

class _DashboardBackdropPainter extends CustomPainter {
  final Color gridColor;
  final Color primaryColor;
  final Color accentColor;

  _DashboardBackdropPainter({
    required this.gridColor,
    required this.primaryColor,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    const gap = 42.0;
    for (double x = -size.height * 0.16; x < size.width; x += gap) {
      canvas.drawLine(
          Offset(x, 0), Offset(x + size.height * 0.16, size.height), grid);
    }

    final pulse = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.square
      ..color = primaryColor.withOpacity(0.4);

    final path = Path();
    final y0 = size.height * 0.105;
    path.moveTo(size.width * 0.03, y0);
    for (double x = size.width * 0.03; x <= size.width * 0.98; x += 12) {
      final y = y0 + math.sin(x / 24) * 8 + math.sin(x / 67) * 5;
      path.lineTo(x, y);
    }
    canvas.drawPath(path, pulse);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..color = primaryColor.withOpacity(0.045);
    canvas.drawArc(
      Rect.fromCircle(
          center: Offset(size.width * 0.88, size.height * 0.20), radius: 74),
      -1.4,
      4.2,
      false,
      ringPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _DashboardBackdropPainter oldDelegate) {
    return oldDelegate.gridColor != gridColor ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.accentColor != accentColor;
  }
}

class _DashboardMenu {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? shortTitle;

  const _DashboardMenu(this.icon, this.title, this.subtitle, this.onTap,
      {this.shortTitle});
}

class _CurrentUser {
  final String id;
  final String email;
  final String name;
  final String role;
  final bool active;

  const _CurrentUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    required this.active,
  });

  factory _CurrentUser.fromAppUser(AppUser user) {
    return _CurrentUser(
      id: user.userId,
      email: user.email,
      name: user.nama,
      role: user.role.roleId,
      active: user.status == 'active',
    );
  }

  factory _CurrentUser.fromMap(Map<String, dynamic> map, String fallbackEmail) {
    final status = (map['status'] ?? '').toString().toLowerCase().trim();
    return _CurrentUser(
      id: (map['user_id'] ?? map['id'] ?? '').toString(),
      email: (map['email'] ?? fallbackEmail).toString(),
      name: (map['nama'] ?? map['name'] ?? map['email'] ?? fallbackEmail)
          .toString(),
      role: (map['role_id'] ?? map['role'] ?? '').toString(),
      active: status.isEmpty ? map['is_active'] != false : status == 'active',
    );
  }
}
