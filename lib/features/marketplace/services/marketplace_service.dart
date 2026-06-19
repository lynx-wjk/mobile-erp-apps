// ignore_for_file: unnecessary_type_check
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../stock/models/product.dart';
import '../models/marketplace_account_public.dart';
import '../models/marketplace_sku_map.dart';
import '../models/marketplace_sku_map_input.dart';
import '../models/marketplace_stock_sync_item.dart';
import '../models/marketplace_sync_log_item.dart';
import '../models/marketplace_stock_difference_item.dart';
import '../models/marketplace_variant_snapshot.dart';
import '../models/marketplace_order_item.dart';
import '../models/marketplace_order_summary.dart';

class MarketplaceConnectLink {
  final String marketplace;
  final String authorizationUrl;
  final String state;
  final DateTime? expiresAt;
  final String environment;
  final String? shopeeHost;
  final bool shopeeUsedFallbackCredential;
  final String? shopeeCredentialSource;
  final String? shopeePartnerIdMasked;
  final bool shopeeRedirectUriConfigured;

  const MarketplaceConnectLink({
    required this.marketplace,
    required this.authorizationUrl,
    required this.state,
    required this.expiresAt,
    required this.environment,
    required this.shopeeHost,
    required this.shopeeUsedFallbackCredential,
    required this.shopeeCredentialSource,
    required this.shopeePartnerIdMasked,
    required this.shopeeRedirectUriConfigured,
  });

  factory MarketplaceConnectLink.fromMap(Map<String, dynamic> map) {
    return MarketplaceConnectLink(
      marketplace: map['marketplace']?.toString() ?? '',
      authorizationUrl: map['authorization_url']?.toString() ?? '',
      state: map['state']?.toString() ?? '',
      expiresAt: map['expires_at'] == null
          ? null
          : DateTime.tryParse(map['expires_at'].toString()),
      environment: map['environment']?.toString() ?? 'production',
      shopeeHost: map['shopee_host']?.toString(),
      shopeeUsedFallbackCredential:
          map['shopee_used_fallback_credential'] == true,
      shopeeCredentialSource: map['shopee_credential_source']?.toString(),
      shopeePartnerIdMasked: map['shopee_partner_id_masked']?.toString(),
      shopeeRedirectUriConfigured:
          map['shopee_redirect_uri_configured'] == true,
    );
  }
}

class MarketplaceProductPullResult {
  final bool ok;
  final String marketplace;
  final int products;
  final int variants;
  final String? message;
  final bool hasMore;
  final Map<String, dynamic>? nextCursor;
  final int batchCount;

  const MarketplaceProductPullResult({
    required this.ok,
    required this.marketplace,
    required this.products,
    required this.variants,
    this.message,
    this.hasMore = false,
    this.nextCursor,
    this.batchCount = 1,
  });

  factory MarketplaceProductPullResult.fromMap(Map<String, dynamic> map) {
    final rawCursor = map['next_cursor'];
    return MarketplaceProductPullResult(
      ok: map['ok'] == true,
      marketplace: map['marketplace']?.toString() ?? '',
      products: _asInt(map['products']),
      variants: _asInt(map['variants']),
      message: map['message']?.toString(),
      hasMore: map['has_more'] == true,
      nextCursor:
          rawCursor is Map ? Map<String, dynamic>.from(rawCursor) : null,
      batchCount:
          _asInt(map['batch_count']) <= 0 ? 1 : _asInt(map['batch_count']),
    );
  }

  String get summary {
    final base = 'Produk: $products · Varian: $variants · Batch: $batchCount';
    final cleanMessage = message?.trim();
    if (cleanMessage != null && cleanMessage.isNotEmpty) {
      return '$base · $cleanMessage';
    }
    return base;
  }
}

class MarketplaceStockSyncWorkerResult {
  final bool ok;
  final bool dryRun;
  final int picked;
  final int success;
  final int dryRunSuccess;
  final int waitingMarketplaceIds;
  final int skipped;
  final int autoSyncDisabled;
  final int failed;
  final String? message;

  const MarketplaceStockSyncWorkerResult({
    required this.ok,
    required this.dryRun,
    required this.picked,
    required this.success,
    required this.dryRunSuccess,
    required this.waitingMarketplaceIds,
    required this.skipped,
    this.autoSyncDisabled = 0,
    required this.failed,
    this.message,
  });

  factory MarketplaceStockSyncWorkerResult.fromMap(Map<String, dynamic> map) {
    return MarketplaceStockSyncWorkerResult(
      ok: map['ok'] == true,
      dryRun: map['dry_run'] == true,
      picked: _asInt(map['picked']),
      success: _asInt(map['success']),
      dryRunSuccess: _asInt(map['dry_run_success']),
      waitingMarketplaceIds: _asInt(map['waiting_marketplace_ids']),
      skipped: _asInt(map['skipped']),
      autoSyncDisabled: _asInt(map['auto_sync_disabled']),
      failed: _asInt(map['failed']),
      message: map['message']?.toString(),
    );
  }

  int get processed =>
      success +
      dryRunSuccess +
      waitingMarketplaceIds +
      skipped +
      autoSyncDisabled +
      failed;

  String get summary {
    if (!ok && message != null) return message!;
    return dryRun
        ? 'Diproses: $picked · Cek OK: $dryRunSuccess · Belum Lengkap: $waitingMarketplaceIds · Dilewati: $skipped · Gagal: $failed'
        : autoSyncDisabled > 0
            ? 'Picked: $picked · Sync OK: $success · Auto OFF: $autoSyncDisabled · Waiting ID: $waitingMarketplaceIds · Failed: $failed'
            : 'Picked: $picked · Sync OK: $success · Waiting ID: $waitingMarketplaceIds · Skipped: $skipped · Failed: $failed';
  }
}

class MarketplaceAutoSyncSetting {
  final bool enabled;
  final int intervalMinutes;
  final DateTime? updatedAt;
  final DateTime? lastAutoRunAt;
  final String? lastAutoRunMessage;

  const MarketplaceAutoSyncSetting({
    required this.enabled,
    required this.intervalMinutes,
    this.updatedAt,
    this.lastAutoRunAt,
    this.lastAutoRunMessage,
  });

  factory MarketplaceAutoSyncSetting.fromMap(Map<String, dynamic> map) {
    return MarketplaceAutoSyncSetting(
      enabled: map['auto_real_sync_enabled'] == true,
      intervalMinutes: _asInt(map['interval_minutes']) == 0
          ? 10
          : _asInt(map['interval_minutes']),
      updatedAt: map['updated_at'] == null
          ? null
          : DateTime.tryParse(map['updated_at'].toString()),
      lastAutoRunAt: map['last_auto_run_at'] == null
          ? null
          : DateTime.tryParse(map['last_auto_run_at'].toString()),
      lastAutoRunMessage: map['last_auto_run_message']?.toString(),
    );
  }
}

class MarketplaceOrderPullJobDigest {
  final int running;
  final int pending;
  final int done;
  final int failed;
  final DateTime? latestUpdatedAt;
  final List<String> lines;

  const MarketplaceOrderPullJobDigest({
    required this.running,
    required this.pending,
    required this.done,
    required this.failed,
    required this.latestUpdatedAt,
    required this.lines,
  });

  bool get hasActive => running > 0 || pending > 0;

  int get total => running + pending + done + failed;
}

class MarketplaceOrderAutoPullSetting {
  final bool enabled;
  final int intervalMinutes;
  final int daysBack;
  final int previousUnpackedDays;
  final DateTime? updatedAt;
  final DateTime? lastAutoRunAt;
  final String? lastAutoRunMessage;

  const MarketplaceOrderAutoPullSetting({
    required this.enabled,
    required this.intervalMinutes,
    required this.daysBack,
    required this.previousUnpackedDays,
    this.updatedAt,
    this.lastAutoRunAt,
    this.lastAutoRunMessage,
  });

  factory MarketplaceOrderAutoPullSetting.fromMap(Map<String, dynamic> map) {
    final interval = _asInt(map['interval_minutes']);
    final days = _asInt(map['days_back']);
    final previousDays = _asInt(map['previous_unpacked_days']);
    return MarketplaceOrderAutoPullSetting(
      enabled: map['auto_order_pull_enabled'] == true,
      intervalMinutes: interval <= 0 ? 10 : interval,
      daysBack: days <= 0 ? 90 : days,
      previousUnpackedDays: previousDays <= 0 ? 90 : previousDays,
      updatedAt: map['updated_at'] == null
          ? null
          : DateTime.tryParse(map['updated_at'].toString()),
      lastAutoRunAt: map['last_auto_run_at'] == null
          ? null
          : DateTime.tryParse(map['last_auto_run_at'].toString()),
      lastAutoRunMessage: map['last_auto_run_message']?.toString(),
    );
  }
}

class MarketplaceOrderPullResult {
  final bool ok;
  final String marketplace;
  final int orders;
  final int items;
  final int mappedItems;
  final int unmappedItems;
  final int warningCount;
  final String? message;

  const MarketplaceOrderPullResult({
    required this.ok,
    required this.marketplace,
    required this.orders,
    required this.items,
    required this.mappedItems,
    required this.unmappedItems,
    required this.warningCount,
    this.message,
  });

  factory MarketplaceOrderPullResult.fromMap(Map<String, dynamic> map) {
    return MarketplaceOrderPullResult(
      ok: map['ok'] == true,
      marketplace: map['marketplace']?.toString() ?? '',
      orders: _asInt(map['orders']),
      items: _asInt(map['items']),
      mappedItems: _asInt(map['mapped_items']),
      unmappedItems: _asInt(map['unmapped_items']),
      warningCount: _asInt(map['warning_count']),
      message: map['message']?.toString(),
    );
  }

  String get summary => message?.trim().isNotEmpty == true
      ? message!
      : 'Data masuk: $orders order, $items item.';
}

class MarketplaceOrderJobProcessResult {
  final bool ok;
  final int queued;
  final int accounts;
  final int processed;
  final int failed;
  final int remaining;
  final int orders;
  final int items;
  final int mappedItems;
  final int unmappedItems;
  final int warningCount;
  final String? message;

  const MarketplaceOrderJobProcessResult({
    required this.ok,
    required this.queued,
    required this.accounts,
    required this.processed,
    required this.failed,
    required this.remaining,
    required this.orders,
    required this.items,
    required this.mappedItems,
    required this.unmappedItems,
    required this.warningCount,
    this.message,
  });

  factory MarketplaceOrderJobProcessResult.fromMap(Map<String, dynamic> map) {
    return MarketplaceOrderJobProcessResult(
      ok: map['ok'] == true,
      queued: _asInt(map['queued']),
      accounts: _asInt(map['accounts']),
      processed: _asInt(map['processed']),
      failed: _asInt(map['failed']),
      remaining: _asInt(map['remaining']),
      orders: _asInt(map['orders']),
      items: _asInt(map['items']),
      mappedItems: _asInt(map['mapped_items']),
      unmappedItems: _asInt(map['unmapped_items']),
      warningCount: _asInt(map['warning_count']),
      message: map['message']?.toString(),
    );
  }

  String get summary {
    final clean = message?.trim();
    if (clean != null && clean.isNotEmpty) return clean;
    return 'Order jobs: queued=$queued, processed=$processed, remaining=$remaining, orders=$orders, items=$items.';
  }
}

class MarketplaceOrderStockOutResult {
  final bool ok;
  final int processed;
  final int skipped;
  final int unmapped;
  final int failed;
  final int processedOrders;
  final int failedOrders;
  final String message;

  const MarketplaceOrderStockOutResult({
    required this.ok,
    required this.processed,
    required this.skipped,
    required this.unmapped,
    required this.failed,
    required this.processedOrders,
    required this.failedOrders,
    required this.message,
  });

  factory MarketplaceOrderStockOutResult.fromMap(Map<String, dynamic> map) {
    return MarketplaceOrderStockOutResult(
      ok: map['ok'] == true,
      processed: _asInt(map['processed']),
      skipped: _asInt(map['skipped']),
      unmapped: _asInt(map['unmapped']),
      failed: _asInt(map['failed']),
      processedOrders: _asInt(map['processed_orders']),
      failedOrders: _asInt(map['failed_orders']),
      message: map['message']?.toString() ?? 'Stock out order selesai.',
    );
  }
}

class MarketplaceBootstrapAccountStatus {
  final String marketplaceAccountId;
  final String marketplace;
  final String storeName;
  final String environment;
  final String accountStatus;
  final String bootstrapStatus;
  final String clientMessage;
  final String technicalStatus;
  final double progressPct;
  final int totalJobs;
  final int doneJobs;
  final int pendingJobs;
  final int runningJobs;
  final int retryJobs;
  final int failedJobs;
  final int pageLimitRiskJobs;
  final int ordersPulled;
  final int itemsPulled;
  final String? estimatedFinishWib;
  final String? estimatedRemaining;

  const MarketplaceBootstrapAccountStatus({
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.storeName,
    required this.environment,
    required this.accountStatus,
    required this.bootstrapStatus,
    required this.clientMessage,
    required this.technicalStatus,
    required this.progressPct,
    required this.totalJobs,
    required this.doneJobs,
    required this.pendingJobs,
    required this.runningJobs,
    required this.retryJobs,
    required this.failedJobs,
    required this.pageLimitRiskJobs,
    required this.ordersPulled,
    required this.itemsPulled,
    this.estimatedFinishWib,
    this.estimatedRemaining,
  });

  factory MarketplaceBootstrapAccountStatus.fromMap(Map<String, dynamic> map) {
    return MarketplaceBootstrapAccountStatus(
      marketplaceAccountId: map['marketplace_account_id']?.toString() ?? '',
      marketplace: map['marketplace']?.toString() ?? '',
      storeName: map['store_name']?.toString() ?? 'Marketplace',
      environment: map['environment']?.toString() ?? '',
      accountStatus: map['account_status']?.toString() ?? '',
      bootstrapStatus: map['bootstrap_status']?.toString() ?? '',
      clientMessage: map['client_message']?.toString() ?? '',
      technicalStatus: map['technical_status']?.toString() ?? '',
      progressPct: _asDouble(map['progress_pct']),
      totalJobs: _asInt(map['total_jobs']),
      doneJobs: _asInt(map['done_jobs']),
      pendingJobs: _asInt(map['pending_jobs']),
      runningJobs: _asInt(map['running_jobs']),
      retryJobs: _asInt(map['retry_jobs']),
      failedJobs: _asInt(map['failed_jobs']),
      pageLimitRiskJobs: _asInt(map['page_limit_risk_jobs']),
      ordersPulled: _asInt(map['orders_pulled']),
      itemsPulled: _asInt(map['items_pulled']),
      estimatedFinishWib: map['estimated_finish_wib']?.toString(),
      estimatedRemaining: map['estimated_remaining']?.toString(),
    );
  }

  bool get isActive =>
      pendingJobs > 0 ||
      runningJobs > 0 ||
      retryJobs > 0 ||
      bootstrapStatus == 'pulling' ||
      bootstrapStatus == 'syncing' ||
      bootstrapStatus == 'queued';

  bool get isCompleted => bootstrapStatus == 'completed' && !isActive;
  bool get isBlocked => bootstrapStatus == 'blocked_pagination_limit';
  bool get hasFailed => failedJobs > 0 || bootstrapStatus == 'failed';
}

class MarketplaceBootstrapUiStatus {
  final bool ok;
  final bool showBanner;
  final String severity;
  final String title;
  final String message;
  final Map<String, dynamic> summary;
  final List<MarketplaceBootstrapAccountStatus> accounts;

  const MarketplaceBootstrapUiStatus({
    required this.ok,
    required this.showBanner,
    required this.severity,
    required this.title,
    required this.message,
    required this.summary,
    required this.accounts,
  });

  factory MarketplaceBootstrapUiStatus.fromMap(Map<String, dynamic> map) {
    final rawAccounts = map['accounts'];
    final accounts = rawAccounts is List
        ? rawAccounts
            .whereType<Map>()
            .map((item) => MarketplaceBootstrapAccountStatus.fromMap(
                Map<String, dynamic>.from(item)))
            .toList(growable: false)
        : const <MarketplaceBootstrapAccountStatus>[];

    final rawSummary = map['summary'];
    return MarketplaceBootstrapUiStatus(
      ok: map['ok'] == true,
      showBanner: map['show_banner'] == true,
      severity: map['severity']?.toString() ?? 'neutral',
      title: map['title']?.toString() ?? 'Status marketplace',
      message: map['message']?.toString() ?? '',
      summary: rawSummary is Map
          ? Map<String, dynamic>.from(rawSummary)
          : const <String, dynamic>{},
      accounts: accounts,
    );
  }

  int get totalAccounts => _asInt(summary['total_accounts']);
  int get doneJobs => _asInt(summary['done_jobs']);
  int get totalJobs => _asInt(summary['total_jobs']);
  int get retryJobs => _asInt(summary['retry_jobs']);
  int get pendingJobs => _asInt(summary['pending_jobs']);
  int get runningJobs => _asInt(summary['running_jobs']);
  int get failedJobs => _asInt(summary['failed_jobs']);
  int get pageLimitRiskJobs => _asInt(summary['page_limit_risk_jobs']);
  int get ordersPulled => _asInt(summary['orders_pulled']);
  int get itemsPulled => _asInt(summary['items_pulled']);
  String get estimatedFinishWib =>
      summary['estimated_finish_wib']?.toString() ?? '';

  bool get hasActiveWork => pendingJobs > 0 || runningJobs > 0 || retryJobs > 0;
  bool get hasProblem => failedJobs > 0 || pageLimitRiskJobs > 0;
  bool get hasAccounts => accounts.isNotEmpty;
}

int _asInt(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}

double _asDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}

class MarketplaceService {
  MarketplaceService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  static const int _variantPageSize = 1000;
  static const int _variantMaxRows = 5000;

  Future<MarketplaceBootstrapUiStatus?> fetchBootstrapUiStatus() async {
    try {
      final response = await _client.rpc('marketplace_bootstrap_ui_status');
      if (response is Map) {
        return MarketplaceBootstrapUiStatus.fromMap(
          Map<String, dynamic>.from(response),
        );
      }
    } catch (_) {
      // Older deployments may not have the RPC yet. The UI must stay usable.
    }
    return null;
  }

  Future<MarketplaceOrderPullJobDigest?> getRecentOrderPullJobDigest({
    required String tenantId,
    int limit = 20,
  }) async {
    if (tenantId.trim().isEmpty) return null;
    try {
      final safeLimit = limit < 1 ? 1 : (limit > 50 ? 50 : limit);
      final data = await _client
          .from('marketplace_order_pull_jobs')
          .select(
              'status, attempts, order_count, item_count, last_message, created_at, updated_at')
          .eq('tenant_id', tenantId)
          .order('updated_at', ascending: false)
          .range(0, safeLimit - 1);

      final rows = data is List ? data.cast<dynamic>() : const <dynamic>[];
      var running = 0;
      var pending = 0;
      var done = 0;
      var failed = 0;
      DateTime? latest;
      final lines = <String>[];

      for (final raw in rows) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        final status = row['status']?.toString().toLowerCase().trim() ?? '';
        if (status == 'running') {
          running++;
        } else if (status == 'pending' || status == 'retry') {
          pending++;
        } else if (status == 'done') {
          done++;
        } else if (status == 'failed') {
          failed++;
        }

        final updated = DateTime.tryParse(
            (row['updated_at'] ?? row['created_at'] ?? '').toString());
        if (updated != null && (latest == null || updated.isAfter(latest)))
          latest = updated;

        if (lines.length < 8) {
          final msg = (row['last_message'] ?? '')
              .toString()
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          final orderCount = _asInt(row['order_count']);
          final itemCount = _asInt(row['item_count']);
          final attempts = _asInt(row['attempts']);
          final statusLabel = status.isEmpty ? 'unknown' : status.toUpperCase();
          final base =
              '$statusLabel · order $orderCount · item $itemCount · attempt $attempts';
          lines.add(msg.isEmpty ? base : '$base · $msg');
        }
      }

      return MarketplaceOrderPullJobDigest(
        running: running,
        pending: pending,
        done: done,
        failed: failed,
        latestUpdatedAt: latest,
        lines: lines,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<MarketplaceAccountPublic>> listAccounts({
    required String tenantId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    try {
      final data = await _client.rpc(
        'marketplace_list_accounts_public',
        params: {'p_tenant_id': tenantId},
      );

      return (data as List<dynamic>)
          .map((item) => MarketplaceAccountPublic.fromMap(
                Map<String, dynamic>.from(item as Map),
              ))
          .where((account) => account.status.toLowerCase() != 'deleted')
          .toList();
    } catch (_) {
      final data = await _client
          .from('marketplace_accounts_public')
          .select()
          .eq('tenant_id', tenantId)
          .order('updated_at', ascending: false)
          .range(0, 199);

      return (data as List<dynamic>)
          .map((item) => MarketplaceAccountPublic.fromMap(
                Map<String, dynamic>.from(item as Map),
              ))
          .where((account) => account.status.toLowerCase() != 'deleted')
          .toList();
    }
  }

  Future<MarketplaceConnectLink> createConnectLink({
    required String marketplace,
    required String storeAlias,
    String authAction = 'connect_new',
    String? marketplaceAccountId,
    String environment = 'production',
  }) async {
    final body = <String, dynamic>{
      'marketplace': marketplace,
      'store_alias': storeAlias.trim(),
      'auth_action':
          authAction.trim().isEmpty ? 'connect_new' : authAction.trim(),
      'environment':
          environment.trim().isEmpty ? 'production' : environment.trim(),
    };

    final accountId = marketplaceAccountId?.trim();
    if (accountId != null && accountId.isNotEmpty) {
      body['marketplace_account_id'] = accountId;
    }

    final response = await _client.functions.invoke(
      'marketplace-auth-start',
      body: body,
    );

    if (response.status < 200 || response.status >= 300) {
      throw Exception(_describeAuthStartError(response.data));
    }

    final raw = response.data;
    if (raw is! Map) {
      throw Exception('Respons hubungkan toko belum sesuai.');
    }

    final data = Map<String, dynamic>.from(raw);
    final link = MarketplaceConnectLink.fromMap(data);

    if (link.authorizationUrl.trim().isEmpty) {
      throw Exception('Link hubungkan toko belum tersedia.');
    }

    return link;
  }

  String _describeAuthStartError(dynamic data) {
    final fallback = 'Gagal membuat authorization link.';
    if (data == null) return fallback;

    final raw = data.toString();
    Map<String, dynamic>? map;
    if (data is Map) {
      map = Map<String, dynamic>.from(data);
    }

    final message = [
      map?['message'],
      map?['error'],
      raw,
    ].whereType<Object>().map((value) => value.toString()).join(' ');

    if (message.contains('SHOPEE_TEST_PARTNER_ID') ||
        message.contains('SHOPEE_TEST_PARTNER_KEY')) {
      return 'Credential Shopee Testing belum lengkap. Untuk akun Shopee yang masih developing, isi SHOPEE_TEST_PARTNER_ID dan SHOPEE_TEST_PARTNER_KEY di Supabase Secrets, lalu generate link Testing lagi.';
    }
    if (message.contains('SHOPEE_PARTNER_ID') ||
        message.contains('SHOPEE_PARTNER_KEY')) {
      return 'Credential Shopee belum lengkap. Isi SHOPEE_PARTNER_ID dan SHOPEE_PARTNER_KEY di Supabase Secrets, lalu coba generate link lagi.';
    }
    if (message.contains('SHOPEE_REDIRECT_URI')) {
      return 'Redirect URI Shopee belum diset. Isi SHOPEE_REDIRECT_URI ke callback Supabase Shopee, lalu coba lagi.';
    }

    final backendMessage = map?['message']?.toString().trim();
    final backendError = map?['error']?.toString().trim();
    if (backendMessage != null && backendMessage.isNotEmpty) {
      return backendError != null && backendError.isNotEmpty
          ? '$backendError: $backendMessage'
          : backendMessage;
    }
    if (backendError != null && backendError.isNotEmpty) return backendError;
    return raw.trim().isEmpty ? fallback : raw;
  }

  Future<void> setMarketplaceAccountStockSyncEnabled({
    required String tenantId,
    required String marketplaceAccountId,
    required bool enabled,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }
    if (marketplaceAccountId.trim().isEmpty) {
      throw Exception('Marketplace account kosong.');
    }

    await _client.rpc(
      'marketplace_set_account_stock_sync_enabled',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id': marketplaceAccountId,
        'p_enabled': enabled,
      },
    );
  }

  Future<void> deleteMarketplaceAccount({
    required String tenantId,
    required String marketplaceAccountId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }
    if (marketplaceAccountId.trim().isEmpty) {
      throw Exception('Marketplace account kosong.');
    }

    await _client.rpc(
      'marketplace_delete_account',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id': marketplaceAccountId,
      },
    );
  }

  Future<List<Product>> listLocalProducts({
    required String tenantId,
    String? search,
    int limit = 200,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    dynamic query = _client.from('products').select('''
      product_id,
      kode_sku,
      kode_barcode,
      nama_barang,
      kategori,
      satuan,
      harga_hpp_default,
      stock_awal,
      stock_saat_ini,
      low_stock_limit,
      lokasi_rak,
      status,
      created_at
    ''').eq('tenant_id', tenantId).eq('status', 'active');

    final keyword = search?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      final safeKeyword = keyword.replaceAll(',', ' ').trim();
      query = query.or(
        'kode_sku.ilike.%$safeKeyword%,kode_barcode.ilike.%$safeKeyword%,nama_barang.ilike.%$safeKeyword%',
      );
    }

    final safeLimit = limit.clamp(1, 200).toInt();
    final data = await query.order('nama_barang').range(0, safeLimit - 1);

    return (data as List<dynamic>)
        .map((item) => Product.fromMap(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<List<MarketplaceSkuMap>> listSkuMaps({
    required String tenantId,
    String? marketplaceAccountId,
    String? search,
    int limit = 200,
    int offset = 0,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    dynamic query = _client
        .from('marketplace_sku_maps_public')
        .select()
        .eq('tenant_id', tenantId);

    final accountId = marketplaceAccountId?.trim();
    if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
      query = query.eq('marketplace_account_id', accountId);
    }

    final keyword = search?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      final safeKeyword = keyword.replaceAll(',', ' ').trim();
      query = query.or(
        'local_sku.ilike.%$safeKeyword%,local_product_name.ilike.%$safeKeyword%,marketplace_seller_sku.ilike.%$safeKeyword%,marketplace_product_name.ilike.%$safeKeyword%',
      );
    }

    final safeLimit = limit.clamp(1, 200).toInt();
    final safeOffset = offset < 0 ? 0 : offset;
    final data = await query
        .order('updated_at', ascending: false)
        .range(safeOffset, safeOffset + safeLimit - 1);

    return (data as List<dynamic>)
        .map((item) =>
            MarketplaceSkuMap.fromMap(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<void> createSkuMap(MarketplaceSkuMapInput input) async {
    if (input.tenantId.trim().isEmpty) {
      throw Exception('Data akun belum lengkap.');
    }

    if (input.marketplaceAccountId.trim().isEmpty) {
      throw Exception('Pilih marketplace account dulu.');
    }

    if (input.productId.trim().isEmpty) {
      throw Exception('Pilih varian/SKU lokal dulu.');
    }

    await _client.from('marketplace_sku_maps').insert(input.toInsertMap());
  }

  Future<void> updateSkuMapSync({
    required String marketplaceSkuMapId,
    required bool syncEnabled,
  }) async {
    await _client.from('marketplace_sku_maps').update({
      'sync_enabled': syncEnabled,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('marketplace_sku_map_id', marketplaceSkuMapId);
  }

  Future<void> updateSkuMapStatus({
    required String marketplaceSkuMapId,
    required String status,
  }) async {
    await _client.from('marketplace_sku_maps').update({
      'status': status,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('marketplace_sku_map_id', marketplaceSkuMapId);
  }

  Future<void> deleteSkuMap(String marketplaceSkuMapId) async {
    await _client
        .from('marketplace_sku_maps')
        .delete()
        .eq('marketplace_sku_map_id', marketplaceSkuMapId);
  }

  Future<int> autoMatchSkuMaps({
    required String tenantId,
    String? marketplaceAccountId,
  }) async {
    final response = await _client.rpc(
      'marketplace_auto_match_sku_maps',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id':
            marketplaceAccountId == 'all' ? null : marketplaceAccountId,
      },
    );

    if (response is num) return response.toInt();
    return int.tryParse(response?.toString() ?? '0') ?? 0;
  }

  Future<List<MarketplaceStockSyncItem>> listStockSyncItems({
    required String tenantId,
    String? marketplace,
    String? marketplaceAccountId,
    String? search,
    int limit = 250,
    int offset = 0,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    dynamic query = _client
        .from('marketplace_stock_sync_overview_public')
        .select()
        .eq('tenant_id', tenantId);

    final marketplaceId = marketplace?.trim();
    if (marketplaceId != null &&
        marketplaceId.isNotEmpty &&
        marketplaceId != 'all') {
      query = query.eq('marketplace', marketplaceId);
    }

    final accountId = marketplaceAccountId?.trim();
    if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
      query = query.eq('marketplace_account_id', accountId);
    }

    final keyword = search?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      final safeKeyword = keyword.replaceAll(',', ' ').trim();
      query = query.or(
        'local_sku.ilike.%$safeKeyword%,local_product_name.ilike.%$safeKeyword%,marketplace_seller_sku.ilike.%$safeKeyword%,marketplace_product_name.ilike.%$safeKeyword%',
      );
    }

    final safeLimit = limit.clamp(1, 250).toInt();
    final safeOffset = offset < 0 ? 0 : offset;
    final data = await query
        .order('local_product_name')
        .range(safeOffset, safeOffset + safeLimit - 1);

    return (data as List<dynamic>)
        .map((item) => MarketplaceStockSyncItem.fromMap(
            Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<String> queueStockSyncForMapping({
    required String tenantId,
    required String marketplaceSkuMapId,
    String reason = 'manual',
  }) async {
    final response = await _client.rpc(
      'marketplace_queue_stock_sync_for_mapping',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_sku_map_id': marketplaceSkuMapId,
        'p_reason': reason,
      },
    );

    return response?.toString() ?? '';
  }

  Future<int> queueStockSyncForAccount({
    required String tenantId,
    String? marketplaceAccountId,
    String reason = 'manual_account_queue',
  }) async {
    final response = await _client.rpc(
      'marketplace_queue_stock_sync_for_account',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id':
            marketplaceAccountId == null || marketplaceAccountId == 'all'
                ? null
                : marketplaceAccountId,
        'p_reason': reason,
      },
    );

    if (response is num) return response.toInt();
    return int.tryParse(response?.toString() ?? '0') ?? 0;
  }

  Future<MarketplaceProductPullResult> pullMarketplaceProducts({
    required String tenantId,
    required String marketplaceAccountId,
    int limit = 30,
  }) async {
    Map<String, dynamic>? cursor;
    int totalProducts = 0;
    int totalVariants = 0;
    int batchCount = 0;
    String? lastMessage;
    const maxBatches = 40;

    while (true) {
      batchCount += 1;
      dynamic response;
      try {
        response = await _client.functions.invoke(
          'marketplace-product-pull',
          body: {
            'tenant_id': tenantId,
            'marketplace_account_id': marketplaceAccountId,
            'page_size': limit.clamp(1, 5),
            'max_pages': 1,
            'max_products_per_run': 5,
            'clear_cache': false,
            if (cursor != null) 'cursor': cursor,
          },
        );
      } catch (error) {
        final message = error.toString();
        if (message.contains('NOT_FOUND') ||
            message.contains('Requested function was not found') ||
            message.contains('status: 404')) {
          throw Exception(
            'Sinkron produk belum aktif di server. Hubungi admin untuk mengaktifkan pembaruan produk marketplace.',
          );
        }
        if (message.contains('WorkerRequestCancelled') ||
            message.contains('request has been cancelled by supervisor')) {
          return MarketplaceProductPullResult(
            ok: true,
            marketplace: '',
            products: totalProducts,
            variants: totalVariants,
            message:
                'Request produk dihentikan server, tetapi data yang sudah masuk tetap disimpan. Tekan Refresh untuk memuat varian terbaru, lalu klik Ambil Produk & Varian lagi bila perlu.',
            hasMore: true,
            nextCursor: cursor,
            batchCount: batchCount,
          );
        }
        throw Exception(message);
      }

      if (response.status < 200 || response.status >= 300) {
        final message =
            response.data?.toString() ?? 'Gagal mengambil produk marketplace.';
        if (response.status == 404 || message.contains('NOT_FOUND')) {
          throw Exception(
              'Sinkron produk belum aktif di server. Hubungi admin untuk mengaktifkan pembaruan produk marketplace.');
        }
        throw Exception(message);
      }

      final raw = response.data;
      if (raw is! Map) {
        throw Exception('Respons pembaruan produk belum sesuai.');
      }

      final result =
          MarketplaceProductPullResult.fromMap(Map<String, dynamic>.from(raw));
      if (!result.ok) {
        throw Exception(
            result.message ?? 'Gagal mengambil produk marketplace.');
      }

      totalProducts += result.products;
      totalVariants += result.variants;
      lastMessage = result.message;

      if (!result.hasMore || result.nextCursor == null) {
        return MarketplaceProductPullResult(
          ok: true,
          marketplace: result.marketplace,
          products: totalProducts,
          variants: totalVariants,
          message: lastMessage,
          batchCount: batchCount,
        );
      }

      if (batchCount >= maxBatches) {
        return MarketplaceProductPullResult(
          ok: true,
          marketplace: result.marketplace,
          products: totalProducts,
          variants: totalVariants,
          message:
              'Pull dihentikan sementara setelah $maxBatches batch. Klik Ambil Produk & Varian lagi untuk melanjutkan jika marketplace masih punya halaman produk berikutnya.',
          hasMore: true,
          nextCursor: result.nextCursor,
          batchCount: batchCount,
        );
      }

      cursor = result.nextCursor;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<List<MarketplaceVariantSnapshot>> listMarketplaceVariants({
    required String tenantId,
    String? marketplaceAccountId,
    String? search,
    bool unmappedOnly = false,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final accountId = marketplaceAccountId?.trim();
    final keyword = search?.trim();

    try {
      final data = await _fetchMarketplaceVariantPublicRows(
        tenantId: tenantId,
        marketplaceAccountId: accountId,
        search: keyword,
        unmappedOnly: unmappedOnly,
      );
      final variants = data
          .map((item) => MarketplaceVariantSnapshot.fromMap(
              Map<String, dynamic>.from(item as Map)))
          .where((item) => item.isActiveMarketplaceRecord)
          .toList();

      if (variants.isNotEmpty ||
          (keyword != null && keyword.isNotEmpty) ||
          unmappedOnly) {
        return variants;
      }
    } catch (_) {
      // Fallback di bawah dipakai untuk database yang view-nya belum ikut patch
      // atau ketika view security_invoker mulai mengikuti RLS base table.
    }

    return _listMarketplaceVariantsFromBaseTables(
      tenantId: tenantId,
      marketplaceAccountId: accountId,
      search: keyword,
      unmappedOnly: unmappedOnly,
    );
  }

  Future<List<dynamic>> _fetchMarketplaceVariantPublicRows({
    required String tenantId,
    String? marketplaceAccountId,
    String? search,
    bool unmappedOnly = false,
  }) async {
    final rows = <dynamic>[];
    final accountId = marketplaceAccountId?.trim();
    final keyword = search?.trim();

    for (var offset = 0; offset < _variantMaxRows; offset += _variantPageSize) {
      dynamic query = _client
          .from('marketplace_variant_snapshots_public')
          .select()
          .eq('tenant_id', tenantId);

      if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
        query = query.eq('marketplace_account_id', accountId);
      }

      if (unmappedOnly) {
        query = query.filter('marketplace_sku_map_id', 'is', null);
      }

      if (keyword != null && keyword.isNotEmpty) {
        final safeKeyword = keyword.replaceAll(',', ' ').trim();
        query = query.or(
          'marketplace_product_name.ilike.%$safeKeyword%,marketplace_variant_name.ilike.%$safeKeyword%,marketplace_seller_sku.ilike.%$safeKeyword%,marketplace_sku_id.ilike.%$safeKeyword%,mapped_local_sku.ilike.%$safeKeyword%,mapped_local_product_name.ilike.%$safeKeyword%',
        );
      }

      final page = await query
          .order('updated_at', ascending: false)
          .range(offset, offset + _variantPageSize - 1) as List<dynamic>;
      rows.addAll(page);
      if (page.length < _variantPageSize) break;
    }

    return rows;
  }

  Future<List<dynamic>> _fetchMarketplaceVariantBaseRows({
    required String tenantId,
    String? marketplaceAccountId,
    String? search,
  }) async {
    final rows = <dynamic>[];
    final accountId = marketplaceAccountId?.trim();
    final keyword = search?.trim();

    for (var offset = 0; offset < _variantMaxRows; offset += _variantPageSize) {
      dynamic variantQuery =
          _client.from('marketplace_variant_snapshots').select('''
        marketplace_variant_snapshot_id,
        tenant_id,
        marketplace_account_id,
        marketplace,
        marketplace_product_id,
        marketplace_sku_id,
        marketplace_sku_code,
        marketplace_seller_sku,
        marketplace_product_name,
        marketplace_variant_name,
        product_status,
        sku_status,
        price_amount,
        price_currency,
        stock_quantity,
        raw_variant,
        first_seen_at,
        last_seen_at,
        created_at,
        updated_at
      ''').eq('tenant_id', tenantId);

      if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
        variantQuery = variantQuery.eq('marketplace_account_id', accountId);
      }

      if (keyword != null && keyword.isNotEmpty) {
        final safeKeyword = keyword.replaceAll(',', ' ').trim();
        variantQuery = variantQuery.or(
          'marketplace_product_name.ilike.%$safeKeyword%,marketplace_variant_name.ilike.%$safeKeyword%,marketplace_seller_sku.ilike.%$safeKeyword%,marketplace_sku_id.ilike.%$safeKeyword%,marketplace_product_id.ilike.%$safeKeyword%',
        );
      }

      final page = await variantQuery
          .order('updated_at', ascending: false)
          .range(offset, offset + _variantPageSize - 1) as List<dynamic>;
      rows.addAll(page);
      if (page.length < _variantPageSize) break;
    }

    return rows;
  }

  Future<List<MarketplaceVariantSnapshot>>
      _listMarketplaceVariantsFromBaseTables({
    required String tenantId,
    String? marketplaceAccountId,
    String? search,
    bool unmappedOnly = false,
  }) async {
    final accountId = marketplaceAccountId?.trim();
    final keyword = search?.trim();
    final variantRows = await _fetchMarketplaceVariantBaseRows(
      tenantId: tenantId,
      marketplaceAccountId: accountId,
      search: keyword,
    );
    if (variantRows.isEmpty) return const <MarketplaceVariantSnapshot>[];

    final accountRows = await _safeRows(() async {
      dynamic query = _client.from('marketplace_accounts').select('''
        marketplace_account_id,
        tenant_id,
        marketplace,
        store_alias,
        shop_name,
        shop_region,
        status
      ''').eq('tenant_id', tenantId);
      if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
        query = query.eq('marketplace_account_id', accountId);
      }
      return query.order('updated_at', ascending: false).range(0, 199);
    });

    final mapRows = await _safeRows(() async {
      dynamic query = _client.from('marketplace_sku_maps').select('''
        marketplace_sku_map_id,
        tenant_id,
        marketplace_account_id,
        marketplace_product_id,
        marketplace_sku_id,
        marketplace_variant_snapshot_id,
        local_product_id,
        product_id,
        local_sku,
        local_product_name,
        sync_enabled,
        is_stock_sync_enabled,
        status
      ''').eq('tenant_id', tenantId);
      if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
        query = query.eq('marketplace_account_id', accountId);
      }
      return query.order('updated_at', ascending: false).range(0, 499);
    });

    final productIds = <String>{};
    for (final row in mapRows) {
      final productId =
          _readText(row, const ['local_product_id', 'product_id']);
      if (productId != null) productIds.add(productId);
    }

    final List<Map<String, dynamic>> productRows = [];
    if (productIds.isNotEmpty) {
      final idList = productIds.toList();
      final chunks = <List<String>>[];
      for (var i = 0; i < idList.length; i += 50) {
        chunks.add(
            idList.sublist(i, i + 50 > idList.length ? idList.length : i + 50));
      }
      final chunkResults = await Future.wait(chunks.map((chunk) {
        return _safeRows(() async => _client
            .from('products')
            .select('product_id, kode_sku, nama_barang, stock_saat_ini')
            .inFilter('product_id', chunk));
      }));
      for (final res in chunkResults) {
        productRows.addAll(res);
      }
    }

    final accountsById = <String, Map<String, dynamic>>{};
    for (final row in accountRows) {
      final id = row['marketplace_account_id']?.toString() ?? '';
      if (id.isNotEmpty) accountsById[id] = row;
    }

    final productsById = <String, Map<String, dynamic>>{};
    for (final row in productRows) {
      final id = row['product_id']?.toString() ?? '';
      if (id.isNotEmpty) productsById[id] = row;
    }

    final mappedBySnapshot = <String, Map<String, dynamic>>{};
    final mappedByVariant = <String, Map<String, dynamic>>{};
    for (final row in mapRows) {
      if ((row['status']?.toString().toLowerCase() ?? '') == 'deleted')
        continue;

      final snapshotId =
          row['marketplace_variant_snapshot_id']?.toString() ?? '';
      if (snapshotId.isNotEmpty) mappedBySnapshot[snapshotId] = row;

      final key = _variantMapKey(
        row['marketplace_account_id']?.toString(),
        row['marketplace_product_id']?.toString(),
        row['marketplace_sku_id']?.toString(),
      );
      if (key.isNotEmpty) mappedByVariant[key] = row;
    }

    final items = <MarketplaceVariantSnapshot>[];
    for (final raw in variantRows) {
      final row = Map<String, dynamic>.from(raw as Map);
      final snapshotId =
          row['marketplace_variant_snapshot_id']?.toString() ?? '';
      final variantKey = _variantMapKey(
        row['marketplace_account_id']?.toString(),
        row['marketplace_product_id']?.toString(),
        row['marketplace_sku_id']?.toString(),
      );
      final mapRow =
          mappedBySnapshot[snapshotId] ?? mappedByVariant[variantKey];
      if (unmappedOnly && mapRow != null) continue;

      final account =
          accountsById[row['marketplace_account_id']?.toString() ?? ''];
      final productId = mapRow == null
          ? null
          : _readText(mapRow, const ['local_product_id', 'product_id']);
      final product = productId == null ? null : productsById[productId];

      final prepared = <String, dynamic>{
        ...row,
        'marketplace': row['marketplace'] ?? account?['marketplace'],
        'account_store_alias': _readText(
                account, const ['store_alias', 'shop_name', 'marketplace']) ??
            '-',
        'account_shop_name': account?['shop_name'],
        'shop_region': account?['shop_region'],
        'marketplace_sku_map_id': mapRow?['marketplace_sku_map_id'],
        'mapped_product_id': productId,
        'mapped_local_sku':
            _readText(mapRow, const ['local_sku']) ?? product?['kode_sku'],
        'mapped_local_product_name':
            _readText(mapRow, const ['local_product_name']) ??
                product?['nama_barang'],
        'mapped_local_stock': product?['stock_saat_ini'],
        'mapped_sync_enabled': mapRow?['sync_enabled'] ??
            mapRow?['is_stock_sync_enabled'] ??
            false,
        'map_status':
            mapRow?['status'] ?? (mapRow == null ? 'unmapped' : 'active'),
      };

      final item = MarketplaceVariantSnapshot.fromMap(prepared);
      if (item.isActiveMarketplaceRecord) items.add(item);
    }

    return items;
  }

  Future<void> mapMarketplaceVariantToLocalProduct({
    required MarketplaceVariantSnapshot variant,
    required Product product,
    bool syncEnabled = true,
  }) async {
    if (variant.tenantId.trim().isEmpty)
      throw Exception('Data varian belum lengkap.');
    if (variant.marketplaceAccountId.trim().isEmpty)
      throw Exception('Marketplace account variant kosong.');
    if (variant.marketplaceProductId.trim().isEmpty)
      throw Exception('Marketplace product ID kosong.');
    if (variant.marketplaceSkuId.trim().isEmpty)
      throw Exception('Marketplace SKU ID kosong.');
    if (product.productId.trim().isEmpty)
      throw Exception('Varian/SKU lokal belum dipilih.');

    final sellerSku = variant.marketplaceSellerSku?.trim();
    final skuCode = variant.marketplaceSkuCode?.trim();
    final marketplaceSellerSku = (sellerSku != null && sellerSku.isNotEmpty)
        ? sellerSku
        : ((skuCode != null && skuCode.isNotEmpty)
            ? skuCode
            : variant.marketplaceSkuId);

    try {
      await _client.rpc(
        'marketplace_upsert_sku_map_from_variant',
        params: {
          'p_tenant_id': variant.tenantId,
          'p_marketplace_account_id': variant.marketplaceAccountId,
          'p_marketplace': variant.marketplace,
          'p_product_id': product.productId,
          'p_local_sku': product.kodeSku.trim(),
          'p_marketplace_product_id': variant.marketplaceProductId,
          'p_marketplace_sku_id': variant.marketplaceSkuId,
          'p_marketplace_sku': variant.marketplaceSkuCode,
          'p_marketplace_seller_sku': marketplaceSellerSku,
          'p_marketplace_product_name': variant.marketplaceProductName,
          'p_marketplace_variation_name': variant.displayVariant,
          'p_marketplace_variant_snapshot_id':
              variant.marketplaceVariantSnapshotId,
          'p_sync_enabled': syncEnabled,
        },
      );
      return;
    } catch (error) {
      final message = error.toString();
      if (!message.contains('marketplace_upsert_sku_map_from_variant') &&
          !message.contains('function') &&
          !message.contains('Could not find')) {
        rethrow;
      }
    }

    // Fallback untuk project yang belum menjalankan SQL patch terbaru.
    // Tetap aman karena lookup-nya pakai varian marketplace, bukan local SKU.
    final existing = await _client
        .from('marketplace_sku_maps')
        .select('marketplace_sku_map_id')
        .eq('tenant_id', variant.tenantId)
        .eq('marketplace_account_id', variant.marketplaceAccountId)
        .eq('marketplace_product_id', variant.marketplaceProductId)
        .eq('marketplace_sku_id', variant.marketplaceSkuId)
        .limit(1)
        .maybeSingle();

    final payload = {
      'tenant_id': variant.tenantId,
      'marketplace_account_id': variant.marketplaceAccountId,
      'marketplace': variant.marketplace,
      'product_id': product.productId,
      'local_sku': product.kodeSku.trim(),
      'marketplace_product_id': variant.marketplaceProductId,
      'marketplace_sku_id': variant.marketplaceSkuId,
      'marketplace_sku': variant.marketplaceSkuCode,
      'marketplace_seller_sku': marketplaceSellerSku,
      'marketplace_product_name': variant.marketplaceProductName,
      'marketplace_variation_name': variant.displayVariant,
      'marketplace_variant_snapshot_id': variant.marketplaceVariantSnapshotId,
      'mapping_source': 'marketplace_variant_pull',
      'sync_enabled': syncEnabled,
      'status': 'active',
      'last_error': null,
      'updated_at': DateTime.now().toIso8601String(),
    };

    if (existing != null &&
        existing is Map &&
        existing['marketplace_sku_map_id'] != null) {
      await _client.from('marketplace_sku_maps').update(payload).eq(
          'marketplace_sku_map_id',
          existing['marketplace_sku_map_id'].toString());
      return;
    }

    await _client.from('marketplace_sku_maps').insert({
      ...payload,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<int> clearMarketplaceProductCache({
    required String tenantId,
    required String marketplaceAccountId,
  }) async {
    final response = await _client.rpc(
      'marketplace_clear_product_cache',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id': marketplaceAccountId,
      },
    );

    if (response is num) return response.toInt();
    return int.tryParse(response?.toString() ?? '0') ?? 0;
  }

  Future<MarketplaceStockSyncWorkerResult> processStockSyncQueue({
    required String tenantId,
    String? marketplaceAccountId,
    int limit = 20,
    bool dryRun = true,
  }) async {
    dynamic response;
    try {
      response = await _client.functions.invoke(
        'marketplace-stock-sync-worker',
        body: {
          'tenant_id': tenantId,
          'marketplace_account_id':
              marketplaceAccountId == null || marketplaceAccountId == 'all'
                  ? null
                  : marketplaceAccountId,
          'limit': limit,
          'dry_run': dryRun,
        },
      );
    } catch (error) {
      final message = error.toString();
      if (message.contains('NOT_FOUND') ||
          message.contains('Requested function was not found') ||
          message.contains('status: 404')) {
        throw Exception(
          'Sinkron stok belum aktif di server. Hubungi admin untuk mengaktifkan proses stok marketplace.',
        );
      }
      throw Exception(message);
    }

    if (response.status < 200 || response.status >= 300) {
      final message = response.data?.toString() ?? 'Sinkron stok gagal.';
      if (response.status == 404 || message.contains('NOT_FOUND')) {
        throw Exception(
          'Sinkron stok belum aktif di server. Hubungi admin untuk mengaktifkan proses stok marketplace.',
        );
      }
      throw Exception(message);
    }

    final raw = response.data;
    if (raw is! Map) {
      throw Exception('Respons sinkron stok belum sesuai.');
    }

    final result = MarketplaceStockSyncWorkerResult.fromMap(
        Map<String, dynamic>.from(raw));
    if (!result.ok) {
      throw Exception(result.message ?? 'Sinkron stok gagal.');
    }

    return result;
  }

  Future<MarketplaceAutoSyncSetting> getAutoSyncSetting({
    required String tenantId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_get_stock_sync_auto_setting',
      params: {'p_tenant_id': tenantId},
    );

    Map<String, dynamic>? map;
    if (response is List && response.isNotEmpty) {
      map = Map<String, dynamic>.from(response.first as Map);
    } else if (response is Map) {
      map = Map<String, dynamic>.from(response);
    }

    if (map == null) {
      return const MarketplaceAutoSyncSetting(
        enabled: false,
        intervalMinutes: 10,
      );
    }

    return MarketplaceAutoSyncSetting.fromMap(map);
  }

  Future<MarketplaceAutoSyncSetting> setAutoSyncEnabled({
    required String tenantId,
    required bool enabled,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_set_stock_sync_auto_enabled',
      params: {
        'p_tenant_id': tenantId,
        'p_enabled': enabled,
      },
    );

    Map<String, dynamic>? map;
    if (response is List && response.isNotEmpty) {
      map = Map<String, dynamic>.from(response.first as Map);
    } else if (response is Map) {
      map = Map<String, dynamic>.from(response);
    }

    if (map == null) {
      throw Exception('Pengaturan sinkron stok belum bisa dibaca.');
    }

    return MarketplaceAutoSyncSetting.fromMap(map);
  }

  Future<List<MarketplaceSyncLogItem>> listSyncLogs({
    required String tenantId,
    String? marketplaceAccountId,
    String status = 'all',
    String? search,
    int limit = 100,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    dynamic query = _client
        .from('marketplace_stock_sync_logs_public')
        .select()
        .eq('tenant_id', tenantId);

    final accountId = marketplaceAccountId?.trim();
    if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
      query = query.eq('marketplace_account_id', accountId);
    }

    final cleanStatus = status.trim();
    if (cleanStatus.isNotEmpty && cleanStatus != 'all') {
      if (cleanStatus == 'failed_group') {
        query = query.or(
            'sync_status.eq.failed,sync_status.eq.failed_retryable,sync_status.eq.failed_final');
      } else {
        query = query.eq('sync_status', cleanStatus);
      }
    }

    final keyword = search?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      final safeKeyword = keyword.replaceAll(',', ' ').trim();
      query = query.or(
        'local_sku.ilike.%$safeKeyword%,local_product_name.ilike.%$safeKeyword%,marketplace_seller_sku.ilike.%$safeKeyword%,marketplace_product_name.ilike.%$safeKeyword%,error_message.ilike.%$safeKeyword%',
      );
    }

    final safeLimit = limit.clamp(1, 200).toInt();
    final data = await query
        .order('created_at', ascending: false)
        .range(0, safeLimit - 1);

    return (data as List<dynamic>)
        .map((item) => MarketplaceSyncLogItem.fromMap(
            Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<int> retryStockSyncLog({
    required String tenantId,
    required String marketplaceStockSyncLogId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_retry_stock_sync_log',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_stock_sync_log_id': marketplaceStockSyncLogId,
      },
    );

    if (response is num) return response.toInt();
    return int.tryParse(response?.toString() ?? '0') ?? 0;
  }

  Future<int> retryFailedStockSyncLogs({
    required String tenantId,
    String? marketplaceAccountId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_retry_failed_stock_sync_logs',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id':
            marketplaceAccountId == null || marketplaceAccountId == 'all'
                ? null
                : marketplaceAccountId,
      },
    );

    if (response is num) return response.toInt();
    return int.tryParse(response?.toString() ?? '0') ?? 0;
  }

  Future<int> deleteStockSyncLog({
    required String tenantId,
    required String marketplaceStockSyncLogId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_delete_stock_sync_log',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_stock_sync_log_id': marketplaceStockSyncLogId,
      },
    );

    if (response is num) return response.toInt();
    return int.tryParse(response?.toString() ?? '0') ?? 0;
  }

  Future<int> deleteFinishedStockSyncLogs({
    required String tenantId,
    String? marketplaceAccountId,
    String status = 'all',
    int? olderThanDays,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_delete_stock_sync_logs_by_filter',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id':
            marketplaceAccountId == null || marketplaceAccountId == 'all'
                ? null
                : marketplaceAccountId,
        'p_status': status.trim().isEmpty ? 'all' : status.trim(),
        'p_older_than_days': olderThanDays,
      },
    );

    if (response is num) return response.toInt();
    return int.tryParse(response?.toString() ?? '0') ?? 0;
  }

  Future<int> pruneOldStockSyncLogs({
    required String tenantId,
    int keepDays = 30,
    bool keepFailed = true,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_prune_stock_sync_logs',
      params: {
        'p_tenant_id': tenantId,
        'p_keep_days': keepDays,
        'p_keep_failed': keepFailed,
      },
    );

    if (response is num) return response.toInt();
    return int.tryParse(response?.toString() ?? '0') ?? 0;
  }

  Future<List<MarketplaceStockDifferenceItem>> listStockDifferences({
    required String tenantId,
    String? marketplace,
    String? marketplaceAccountId,
    String status = 'all',
    String? search,
    int limit = 200,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    dynamic query = _client
        .from('marketplace_stock_difference_public')
        .select()
        .eq('tenant_id', tenantId);

    final marketplaceId = marketplace?.trim();
    if (marketplaceId != null &&
        marketplaceId.isNotEmpty &&
        marketplaceId != 'all') {
      query = query.eq('marketplace', marketplaceId);
    }

    final accountId = marketplaceAccountId?.trim();
    if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
      query = query.eq('marketplace_account_id', accountId);
    }

    final cleanStatus = status.trim();
    if (cleanStatus.isNotEmpty && cleanStatus != 'all') {
      query = query.eq('difference_status', cleanStatus);
    }

    final keyword = search?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      final safeKeyword = keyword.replaceAll(',', ' ').trim();
      query = query.or(
        'local_sku.ilike.%$safeKeyword%,local_product_name.ilike.%$safeKeyword%,marketplace_seller_sku.ilike.%$safeKeyword%,marketplace_product_name.ilike.%$safeKeyword%',
      );
    }

    final safeLimit = limit.clamp(1, 250).toInt();
    final data = await query
        .order('updated_at', ascending: false)
        .range(0, safeLimit - 1);

    return (data as List<dynamic>)
        .map((item) => MarketplaceStockDifferenceItem.fromMap(
            Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<MarketplaceOrderAutoPullSetting> getOrderAutoPullSetting({
    required String tenantId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_get_order_pull_auto_setting',
      params: {'p_tenant_id': tenantId},
    );

    Map<String, dynamic>? map;
    if (response is List && response.isNotEmpty) {
      map = Map<String, dynamic>.from(response.first as Map);
    } else if (response is Map) {
      map = Map<String, dynamic>.from(response);
    }

    if (map == null) {
      return const MarketplaceOrderAutoPullSetting(
        enabled: false,
        intervalMinutes: 10,
        daysBack: 90,
        previousUnpackedDays: 90,
      );
    }

    return MarketplaceOrderAutoPullSetting.fromMap(map);
  }

  Future<MarketplaceOrderAutoPullSetting> setOrderAutoPullEnabled({
    required String tenantId,
    required bool enabled,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final response = await _client.rpc(
      'marketplace_set_order_pull_auto_enabled',
      params: {
        'p_tenant_id': tenantId,
        'p_enabled': enabled,
      },
    );

    Map<String, dynamic>? map;
    if (response is List && response.isNotEmpty) {
      map = Map<String, dynamic>.from(response.first as Map);
    } else if (response is Map) {
      map = Map<String, dynamic>.from(response);
    }

    if (map == null) {
      throw Exception('Pengaturan auto pull order belum bisa dibaca.');
    }

    return MarketplaceOrderAutoPullSetting.fromMap(map);
  }

  Future<String?> refreshMarketplaceReturnBatalFlags({
    required String tenantId,
    String? marketplaceAccountId,
    int daysBack = 90,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final accountId = marketplaceAccountId?.trim();
    String? warning;

    try {
      final response = await _client.functions.invoke(
        'marketplace-return-refund-pull',
        body: {
          'tenant_id': tenantId,
          'marketplace_account_id':
              accountId == null || accountId.isEmpty || accountId == 'all'
                  ? null
                  : accountId,
          'days_back': daysBack < 1 ? 90 : daysBack,
          'limit': 20,
          'max_pages': 3,
        },
      );

      if (response.status < 200 || response.status >= 300) {
        warning = response.data?.toString() ??
            'Gagal mengambil data retur/cancel marketplace.';
      } else {
        final raw = response.data;
        if (raw is Map && raw['ok'] != true) {
          warning = raw['message']?.toString() ??
              'Gagal mengambil data retur/cancel marketplace.';
        }
      }
    } catch (error) {
      warning = error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
    }

    try {
      await _client.rpc(
        'marketplace_prepare_return_item_reviews',
        params: {
          'p_tenant_id': tenantId,
          'p_marketplace_account_id':
              accountId == null || accountId.isEmpty || accountId == 'all'
                  ? null
                  : accountId,
        },
      );
    } catch (error) {
      final prepareWarning =
          error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      warning = warning == null
          ? prepareWarning
          : '$warning · Prepare review: $prepareWarning';
    }

    return warning;
  }

  Future<MarketplaceOrderJobProcessResult> processMarketplaceOrderPullJobs({
    required String tenantId,
    required String marketplaceAccountId,
    String mode = 'period',
    String? startDate,
    String? endDate,
    bool enqueue = true,
    bool process = true,
    bool forceRequeue = false,
    int maxJobs = 1,
    int windowMinutes = 60,
    int pageSize = 50,
    int maxPages = 1,
    int maxDetails = 50,
    bool includeUpdateTimeSearch = true,
    bool refreshExistingStatus = true,
    int statusRangeDays = 14,
    int maxExistingOrders = 80,
    bool skipCompletedStatusRefresh = true,
    bool skipCompletedOrderPull = true,
    bool background = false,
    bool rejectIfActive = true,
  }) async {
    dynamic response;
    try {
      response = await _client.functions.invoke(
        'marketplace-order-sync-jobs',
        body: {
          'tenant_id': tenantId,
          'marketplace_account_id': marketplaceAccountId,
          'mode': mode,
          if (startDate != null && startDate.trim().isNotEmpty)
            'start_date': startDate.trim(),
          if (endDate != null && endDate.trim().isNotEmpty)
            'end_date': endDate.trim(),
          'enqueue': enqueue,
          'process': process,
          'force_requeue': forceRequeue,
          'max_jobs': maxJobs,
          'window_minutes': windowMinutes,
          'page_size': pageSize,
          'max_pages': maxPages,
          'max_details': maxDetails,
          'include_update_time_search': includeUpdateTimeSearch,
          'refresh_existing_status': refreshExistingStatus,
          'status_range_days': statusRangeDays,
          'max_existing_orders': maxExistingOrders,
          'skip_completed_status_refresh': skipCompletedStatusRefresh,
          'skip_completed_order_pull': skipCompletedOrderPull,
          'background': background,
          'reject_if_active': rejectIfActive,
          'source': background
              ? 'flutter-marketplace-orders-background-v24_6_9'
              : 'flutter-marketplace-orders-page-v24',
        },
      );
    } catch (error) {
      final message = error.toString();
      if (message.contains('NOT_FOUND') ||
          message.contains('Requested function was not found') ||
          message.contains('status: 404')) {
        throw Exception(
            'Pembaruan order belum aktif di server. Hubungi admin untuk mengaktifkan proses order marketplace.');
      }
      throw Exception(message);
    }

    if (response.status < 200 || response.status >= 300) {
      final message = response.data?.toString() ??
          'Gagal memproses antrian order marketplace.';
      if (response.status == 404 || message.contains('NOT_FOUND')) {
        throw Exception(
            'Pembaruan order belum aktif di server. Hubungi admin untuk mengaktifkan proses order marketplace.');
      }
      throw Exception(message);
    }

    final raw = response.data;
    if (raw is! Map) throw Exception('Respons pembaruan order belum sesuai.');

    final result = MarketplaceOrderJobProcessResult.fromMap(
        Map<String, dynamic>.from(raw));
    if (!result.ok)
      throw Exception(
          result.message ?? 'Gagal memproses antrian order marketplace.');
    return result;
  }

  Future<MarketplaceOrderPullResult> pullMarketplaceOrders({
    required String tenantId,
    required String marketplaceAccountId,
    int daysBack = 90,
    int limit = 50,
    int maxPages = 20,
    bool includePreviousUnpacked = true,
    int previousUnpackedDays = 90,
    String? startDate,
    String? endDate,
    List<String>? statuses,
    bool includeStatuslessSearch = true,
    bool includeUpdateTimeSearch = true,
    bool statuslessOnly = false,
    int? maxDetails,
    int? startSeconds,
    int? endSeconds,
    String searchMode = 'normal',
    String? action,
  }) async {
    dynamic response;
    try {
      response = await _client.functions.invoke(
        'marketplace-order-pull',
        body: {
          'tenant_id': tenantId,
          'marketplace_account_id': marketplaceAccountId,
          if (action != null && action.trim().isNotEmpty)
            'action': action.trim(),
          'days_back': daysBack,
          if (startDate != null && startDate.trim().isNotEmpty)
            'start_date': startDate.trim(),
          if (endDate != null && endDate.trim().isNotEmpty)
            'end_date': endDate.trim(),
          if (startSeconds != null && startSeconds > 0)
            'start_seconds': startSeconds,
          if (endSeconds != null && endSeconds > 0) 'end_seconds': endSeconds,
          'limit': limit,
          'max_pages': maxPages,
          'include_previous_unpacked': includePreviousUnpacked,
          'previous_unpacked_days': previousUnpackedDays,
          if (statuses != null && statuses.isNotEmpty) 'statuses': statuses,
          'include_statusless_search': includeStatuslessSearch,
          'include_update_time_search': includeUpdateTimeSearch,
          'statusless_only': statuslessOnly,
          if (maxDetails != null) 'max_details': maxDetails,
          'search_mode': searchMode,
        },
      );
    } catch (error) {
      final message = error.toString();
      if (message.contains('NOT_FOUND') ||
          message.contains('Requested function was not found') ||
          message.contains('status: 404')) {
        throw Exception(
            'Pengambilan order belum aktif di server. Hubungi admin untuk mengaktifkan proses order marketplace.');
      }
      throw Exception(message);
    }

    if (response.status < 200 || response.status >= 300) {
      final message =
          response.data?.toString() ?? 'Gagal mengambil order marketplace.';
      if (response.status == 404 || message.contains('NOT_FOUND')) {
        throw Exception(
            'Pengambilan order belum aktif di server. Hubungi admin untuk mengaktifkan proses order marketplace.');
      }
      throw Exception(message);
    }

    final raw = response.data;
    if (raw is! Map) throw Exception('Respons pengambilan order belum sesuai.');

    final result =
        MarketplaceOrderPullResult.fromMap(Map<String, dynamic>.from(raw));
    if (!result.ok)
      throw Exception(result.message ?? 'Gagal mengambil order marketplace.');
    return result;
  }

  Future<List<MarketplaceOrderSummary>> listMarketplaceOrders({
    required String tenantId,
    String? marketplace,
    String? marketplaceAccountId,
    String status = 'all',
    String? search,
    String? startDate,
    String? endDate,
    int limit = 120,
    int offset = 0,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    try {
      final res = await _client.rpc(
        'marketplace_orders_fast_list',
        params: {
          'p_tenant_id': tenantId,
          'p_marketplace': marketplace,
          'p_marketplace_account_id': marketplaceAccountId == null ||
                  marketplaceAccountId.trim().isEmpty ||
                  marketplaceAccountId == 'all'
              ? null
              : marketplaceAccountId,
          'p_status': status,
          'p_search': search?.trim().isEmpty == true ? null : search?.trim(),
          'p_start': startDate,
          'p_end': endDate,
          'p_limit': limit,
          'p_offset': offset,
        },
      );
      final map = _rpcMap(res);
      final rawRows = map['rows'];
      if (map['ok'] == true && rawRows is List) {
        final rows = rawRows
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        await _attachPendingReturnReviewFlags(tenantId: tenantId, rows: rows);
        return rows.map(MarketplaceOrderSummary.fromMap).toList();
      }
    } catch (_) {
      // Fallback to legacy public view if the fast RPC is not installed yet.
    }

    dynamic query = _client
        .from('marketplace_orders_public')
        .select()
        .eq('tenant_id', tenantId);

    final marketplaceId = marketplace?.trim();
    if (marketplaceId != null &&
        marketplaceId.isNotEmpty &&
        marketplaceId != 'all') {
      query = query.eq('marketplace', marketplaceId);
    }

    final accountId = marketplaceAccountId?.trim();
    if (accountId != null && accountId.isNotEmpty && accountId != 'all') {
      query = query.eq('marketplace_account_id', accountId);
    }

    final cleanStatus = status.trim();
    if (cleanStatus.isNotEmpty && cleanStatus != 'all') {
      query = query.eq('stock_action_status', cleanStatus);
    }

    final cleanStartDate = startDate?.trim();
    if (cleanStartDate != null &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(cleanStartDate)) {
      final parts = cleanStartDate.split('-').map(int.parse).toList();
      final startUtc = DateTime.utc(parts[0], parts[1], parts[2])
          .subtract(const Duration(hours: 7));
      query = query.gte('order_created_at', startUtc.toIso8601String());
    }

    final cleanEndDate = endDate?.trim();
    if (cleanEndDate != null &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(cleanEndDate)) {
      final parts = cleanEndDate.split('-').map(int.parse).toList();
      final endUtc = DateTime.utc(parts[0], parts[1], parts[2] + 1)
          .subtract(const Duration(hours: 7));
      query = query.lt('order_created_at', endUtc.toIso8601String());
    }

    final keyword = search?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      final safeKeyword = keyword.replaceAll(',', ' ').trim();
      query = query.or(
        'external_order_id.ilike.%$safeKeyword%,order_id.ilike.%$safeKeyword%,order_sn.ilike.%$safeKeyword%,remote_order_id.ilike.%$safeKeyword%,package_id.ilike.%$safeKeyword%,tracking_number.ilike.%$safeKeyword%,buyer_username.ilike.%$safeKeyword%,recipient_name.ilike.%$safeKeyword%',
      );
    }

    final safeLimit = limit.clamp(1, 250).toInt();
    final safeOffset = offset < 0 ? 0 : offset;
    final data = await query
        .order('order_created_at', ascending: false)
        .order('pulled_at', ascending: false)
        .order('updated_at', ascending: false)
        .range(safeOffset, safeOffset + safeLimit - 1);

    final rows = (data as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    await _attachPendingReturnReviewFlags(tenantId: tenantId, rows: rows);

    return rows.map(MarketplaceOrderSummary.fromMap).toList();
  }

  Future<void> _attachPendingReturnReviewFlags({
    required String tenantId,
    required List<Map<String, dynamic>> rows,
  }) async {
    if (rows.isEmpty) return;

    final orderIds = rows
        .map((row) => row['marketplace_order_id']?.toString() ?? '')
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList();

    if (orderIds.isEmpty) return;

    try {
      final List<dynamic> reviewRows = [];
      if (orderIds.isNotEmpty) {
        final chunks = <List<String>>[];
        for (var i = 0; i < orderIds.length; i += 50) {
          chunks.add(orderIds.sublist(
              i, i + 50 > orderIds.length ? orderIds.length : i + 50));
        }
        final chunkResults = await Future.wait(chunks.map((chunk) {
          return _client
              .from('marketplace_return_item_reviews')
              .select('marketplace_order_id, review_status, review_type')
              .eq('tenant_id', tenantId)
              .inFilter('marketplace_order_id', chunk)
              .inFilter('review_status',
                  const ['pending', 'open', 'review_required']);
        }));
        for (final res in chunkResults) {
          if (res is List) {
            reviewRows.addAll(res);
          }
        }
      }

      final counts = <String, int>{};
      final types = <String, Set<String>>{};

      for (final raw in reviewRows as List<dynamic>) {
        final item = Map<String, dynamic>.from(raw as Map);
        final orderId = item['marketplace_order_id']?.toString() ?? '';
        if (orderId.isEmpty) continue;

        counts[orderId] = (counts[orderId] ?? 0) + 1;
        final reviewType = item['review_type']?.toString().trim() ?? '';
        if (reviewType.isNotEmpty) {
          (types[orderId] ??= <String>{}).add(reviewType.replaceAll('_', ' '));
        }
      }

      for (final row in rows) {
        final orderId = row['marketplace_order_id']?.toString() ?? '';
        row['pending_return_review_count'] = counts[orderId] ?? 0;
        row['pending_return_review_types'] =
            (types[orderId] ?? <String>{}).join(', ');
      }
    } catch (_) {
      // Review flag is UI helper only. Do not break order list if an older
      // database has not installed the review table/policy yet.
    }
  }

  Future<List<MarketplaceOrderItem>> listMarketplaceOrderItems({
    required String tenantId,
    required String marketplaceOrderId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final data = await _client
        .from('marketplace_order_items_public')
        .select()
        .eq('tenant_id', tenantId)
        .eq('marketplace_order_id', marketplaceOrderId)
        .order('created_at', ascending: true)
        .range(0, 199);

    return (data as List<dynamic>)
        .map((item) => MarketplaceOrderItem.fromMap(
            Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<MarketplaceOrderStockOutResult> processMarketplaceOrderStockOut({
    required String tenantId,
    required String marketplaceOrderId,
  }) async {
    final response = await _client.rpc(
      'marketplace_process_order_stock_out',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_order_id': marketplaceOrderId,
      },
    );

    final map = _rpcMap(response);
    return MarketplaceOrderStockOutResult.fromMap(map);
  }

  Future<MarketplaceOrderStockOutResult> processReadyMarketplaceOrdersStockOut({
    required String tenantId,
    String? marketplaceAccountId,
    int limit = 25,
  }) async {
    final response = await _client.rpc(
      'marketplace_process_ready_order_stock_out',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id':
            marketplaceAccountId == null || marketplaceAccountId == 'all'
                ? null
                : marketplaceAccountId,
        'p_limit': limit,
      },
    );

    final map = _rpcMap(response);
    return MarketplaceOrderStockOutResult.fromMap(map);
  }

  Future<String?> refreshMarketplaceReturnCancelFlags({
    required String tenantId,
    String? marketplaceAccountId,
    int daysBack = 90,
  }) {
    return refreshMarketplaceReturnBatalFlags(
      tenantId: tenantId,
      marketplaceAccountId: marketplaceAccountId,
      daysBack: daysBack,
    );
  }

  Future<MarketplaceOrderStockOutResult> processSiapMarketplaceOrdersStockOut({
    required String tenantId,
    String? marketplaceAccountId,
    int limit = 25,
  }) {
    return processReadyMarketplaceOrdersStockOut(
      tenantId: tenantId,
      marketplaceAccountId: marketplaceAccountId,
      limit: limit,
    );
  }

  Future<Map<String, dynamic>> resetMarketplaceOrderFinanceData({
    required String tenantId,
    String? marketplaceAccountId,
  }) async {
    if (tenantId.trim().isEmpty) {
      throw Exception(
          'Data akun belum lengkap. Login ulang atau hubungi admin.');
    }

    final accountId = marketplaceAccountId?.trim();
    final response = await _client.rpc(
      'marketplace_reset_order_finance_data',
      params: {
        'p_account_id':
            accountId == null || accountId.isEmpty || accountId == 'all'
                ? null
                : accountId,
      },
    );

    return _rpcMap(response);
  }

  Future<List<Map<String, dynamic>>> _safeRows(
      Future<dynamic> Function() loader) async {
    try {
      final data = await loader();
      if (data is List) {
        return data
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
    return const <Map<String, dynamic>>[];
  }

  String? _readText(Map<String, dynamic>? map, List<String> keys) {
    if (map == null) return null;
    for (final key in keys) {
      final value = map[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value.toLowerCase() != 'null') {
        return value;
      }
    }
    return null;
  }

  String _variantMapKey(String? accountId, String? productId, String? skuId) {
    final cleanAccount = accountId?.trim() ?? '';
    final cleanProduct = productId?.trim() ?? '';
    final cleanSku = skuId?.trim() ?? '';
    if (cleanAccount.isEmpty || cleanProduct.isEmpty || cleanSku.isEmpty)
      return '';
    return '$cleanAccount::$cleanProduct::$cleanSku';
  }

  Map<String, dynamic> _rpcMap(dynamic response) {
    if (response is Map) return Map<String, dynamic>.from(response);
    if (response is List && response.isNotEmpty && response.first is Map) {
      return Map<String, dynamic>.from(response.first as Map);
    }
    return {
      'ok': false,
      'message': response?.toString() ?? 'Respons server belum sesuai.'
    };
  }

  Future<Map<String, dynamic>> refreshFinanceAfterHppMapping({
    required String tenantId,
    String? marketplaceAccountId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    String? dateParam(DateTime? value) {
      if (value == null) return null;
      final y = value.year.toString().padLeft(4, '0');
      final m = value.month.toString().padLeft(2, '0');
      final d = value.day.toString().padLeft(2, '0');
      return '$y-$m-$d';
    }

    final response = await _client.rpc(
      'marketplace_finance_recalc_after_hpp_mapping',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id':
            marketplaceAccountId == null || marketplaceAccountId == 'all'
                ? null
                : marketplaceAccountId,
        'p_start': dateParam(startDate),
        'p_end': dateParam(endDate),
      },
    );

    return _rpcMap(response);
  }

  // ── HPP / Margin Mapping ─────────────────────────────────────────────────
  // v24.6.44: sumber HPP dari variant snapshot + order item, bukan cuma order item.

  /// List HPP+margin per marketplace variant.
  /// Returns jsonb {ok, page, page_size, total, rows[]}
  Future<Map<String, dynamic>> hppList({
    String? accountId,
    String? search,
    bool missingOnly = false,
    int page = 1,
    int pageSize = 20,
  }) async {
    final params = {
      'p_account_id': accountId?.trim().isEmpty == true ? null : accountId,
      'p_search': search?.trim().isEmpty == true ? null : search?.trim(),
      'p_missing_only': missingOnly,
      'p_page': page,
      'p_page_size': pageSize,
    };
    try {
      final res =
          await _client.rpc('marketplace_variant_hpp_list', params: params);
      return _rpcMap(res);
    } catch (_) {
      try {
        final res =
            await _client.rpc('marketplace_variant_hpp_list', params: params);
        return _rpcMap(res);
      } catch (_) {
        try {
          final res =
              await _client.rpc('marketplace_variant_hpp_list', params: params);
          return _rpcMap(res);
        } catch (_) {
          final res =
              await _client.rpc('marketplace_variant_hpp_list', params: params);
          return _rpcMap(res);
        }
      }
    }
  }

  /// Upsert HPP+margin rows in bulk.
  /// rows: List of maps with keys matching marketplace_variant_hpp_mappings columns.
  Future<Map<String, dynamic>> hppUpsertBulk(
      List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return {'ok': true, 'upserted': 0};

    String? cleanText(dynamic value) {
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    bool isUuid(String value) {
      return RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(value.trim());
    }

    final normalizedRows = rows.map((row) {
      final hpp = row['hpp'] ?? row['hpp_amount'] ?? row['hpp_per_item'] ?? 0;
      final targetMargin =
          row['target_margin_percent'] ?? row['target_margin'] ?? 0;
      final clean = <String, dynamic>{
        ...row,
        'hpp': hpp,
        'hpp_amount': hpp,
        'hpp_per_item': hpp,
        'target_margin_percent': targetMargin,
      };

      for (final key in [
        'local_variant_id',
        'local_product_id',
        'hpp_mapping_id'
      ]) {
        final value = cleanText(clean[key]);
        if (value == null || !isUuid(value)) {
          clean.remove(key);
        } else {
          clean[key] = value;
        }
      }

      clean.removeWhere((_, value) => value == null);
      return clean;
    }).toList();

    try {
      final res = await _client.rpc(
        'marketplace_variant_hpp_upsert_bulk',
        params: {'p_rows': normalizedRows},
      );
      return _rpcMap(res);
    } catch (_) {
      try {
        final res = await _client.rpc(
          'marketplace_variant_hpp_upsert_bulk',
          params: {'p_rows': normalizedRows},
        );
        return _rpcMap(res);
      } catch (_) {
        final res = await _client.rpc(
          'marketplace_variant_hpp_upsert_bulk',
          params: {'p_rows': normalizedRows},
        );
        return _rpcMap(res);
      }
    }
  }

  Future<Map<String, dynamic>> skuMappingExportSnapshot({
    required String tenantId,
    String? marketplaceAccountId,
  }) async {
    final res = await _client.rpc(
      'marketplace_sku_mapping_export_snapshot',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id': marketplaceAccountId == null ||
                marketplaceAccountId.trim().isEmpty ||
                marketplaceAccountId == 'all'
            ? null
            : marketplaceAccountId,
      },
    );
    return _rpcMap(res);
  }

  Future<Map<String, dynamic>> importSkuMappingBulk(
    List<Map<String, dynamic>> rows, {
    bool syncEnabled = true,
  }) async {
    if (rows.isEmpty) return {'ok': true, 'upserted': 0};
    final res = await _client.rpc(
      'marketplace_sku_mapping_import_bulk',
      params: {
        'p_rows': rows,
        'p_sync_enabled': syncEnabled,
      },
    );
    return _rpcMap(res);
  }

  Future<Map<String, dynamic>> syncHppFromSkuMaps({
    required String tenantId,
    String? marketplaceAccountId,
    bool overwrite = false,
  }) async {
    final res = await _client.rpc(
      'marketplace_sync_hpp_from_sku_maps',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id': marketplaceAccountId == null ||
                marketplaceAccountId.trim().isEmpty ||
                marketplaceAccountId == 'all'
            ? null
            : marketplaceAccountId,
        'p_overwrite': overwrite,
      },
    );
    return _rpcMap(res);
  }

  Future<Map<String, dynamic>> recalculateFinanceAfterHppMapping({
    required String tenantId,
    String? marketplaceAccountId,
    String? startDate,
    String? endDate,
  }) async {
    final res = await _client.rpc(
      'marketplace_finance_recalc_after_hpp_mapping',
      params: {
        'p_tenant_id': tenantId,
        'p_marketplace_account_id': marketplaceAccountId == null ||
                marketplaceAccountId.trim().isEmpty ||
                marketplaceAccountId == 'all'
            ? null
            : marketplaceAccountId,
        'p_start': startDate,
        'p_end': endDate,
      },
    );
    return _rpcMap(res);
  }
}
