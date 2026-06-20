import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/ui/app_ui.dart';

class MarketplaceDispatcherMonitorPage extends StatefulWidget {
  const MarketplaceDispatcherMonitorPage({super.key});

  @override
  State<MarketplaceDispatcherMonitorPage> createState() =>
      _MarketplaceDispatcherMonitorPageState();
}

class _MarketplaceDispatcherMonitorPageState
    extends State<MarketplaceDispatcherMonitorPage> {
  final SupabaseClient _client = Supabase.instance.client;
  Map<String, dynamic>? _payload;
  List<Map<String, dynamic>> _accountAuthRows = const <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final response =
          await _client.rpc('marketplace_dispatcher_monitor_snapshot');
      final accountAuthRows = await _loadAccountAuthRows();
      if (!mounted) return;

      setState(() {
        _payload = _asMap(response);
        _accountAuthRows = accountAuthRows;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<String?> _currentTenantId() async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;
    final profile = await _client
        .from('users')
        .select('tenant_id')
        .eq('user_id', authUser.id)
        .maybeSingle();
    final tenantId = profile?['tenant_id']?.toString().trim();
    return tenantId == null || tenantId.isEmpty ? null : tenantId;
  }

  Future<List<Map<String, dynamic>>> _loadAccountAuthRows() async {
    try {
      final tenantId = await _currentTenantId();
      if (tenantId == null) return const <Map<String, dynamic>>[];

      final response = await _client
          .from('marketplace_accounts_public')
          .select()
          .eq('tenant_id', tenantId)
          .order('updated_at', ascending: false)
          .range(0, 49)
          .timeout(const Duration(seconds: 4));
      if (response is! List) return const <Map<String, dynamic>>[];
      return response
          .whereType<Map>()
          .map((row) => _asMap(row))
          .where((row) => _textValue(row['status']).toLowerCase() != 'deleted')
          .toList(growable: false);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    final summary = _asMap(payload?['summary']);
    final coverage = _asMap(payload?['coverage']);
    final orderStates = _asMapList(payload?['order_states']);
    final financeStates = _asMapList(payload?['finance_states']);
    final productStates = _asMapList(payload?['product_states']);
    final retentionStates = _asMapList(payload?['retention_states']);
    final bootstrapStates = _asMapList(payload?['bootstrap_states']);
    final cronJobs = _asMapList(payload?['cron_jobs']);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispatcher Monitor'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading && payload == null)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _HeaderCard(
                generatedAt: _formatDateTime(payload?['generated_at']),
                error: _error,
              ),
              const SizedBox(height: 12),
              _SummaryCard(summary: summary, coverage: coverage),
              const SizedBox(height: 12),
              _AccountAuthSection(rows: _accountAuthRows),
              const SizedBox(height: 12),
              _StateSection(
                title: 'Order Dispatcher',
                subtitle: 'Bootstrap, recent cursor, lock, dan order 90 hari.',
                states: orderStates,
                type: _DispatcherType.order,
              ),
              const SizedBox(height: 12),
              _StateSection(
                title: 'Finance Dispatcher',
                subtitle: 'Backfill/catchup finance per akun marketplace.',
                states: financeStates,
                type: _DispatcherType.finance,
              ),
              const SizedBox(height: 12),
              _StateSection(
                title: 'Product Snapshot',
                subtitle: 'Status pull katalog manual/onboarding per akun.',
                states: productStates,
                type: _DispatcherType.product,
              ),
              const SizedBox(height: 12),
              _StateSection(
                title: 'Retention 90 Hari',
                subtitle: 'Audit data marketplace di luar window retensi.',
                states: retentionStates,
                type: _DispatcherType.retention,
              ),
              const SizedBox(height: 12),
              _StateSection(
                title: 'Bootstrap',
                subtitle: 'Progress bootstrap order dan finance per akun.',
                states: bootstrapStates,
                type: _DispatcherType.bootstrap,
              ),
              const SizedBox(height: 12),
              _CronCard(jobs: cronJobs),
            ],
          ],
        ),
      ),
    );
  }
}

enum _DispatcherType { order, finance, product, retention, bootstrap }

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.generatedAt, required this.error});

  final String generatedAt;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.monitor_heart_outlined,
                color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Marketplace Dispatcher',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('Update terakhir: $generatedAt'),
                  if (error != null && error!.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.coverage});

  final Map<String, dynamic> summary;
  final Map<String, dynamic> coverage;

  @override
  Widget build(BuildContext context) {
    final orderBad = _intValue(summary['order_bad_count']);
    final financeBad = _intValue(summary['finance_bad_count']);
    final orderActive = _boolValue(summary['order_dispatcher_active']);
    final financeActive = _boolValue(summary['finance_dispatcher_active']);
    final oldFinanceActive = _boolValue(summary['old_finance_pull_active']);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _MetricTile(
              label: 'Order bad',
              value: orderBad.toString(),
              ok: orderBad == 0,
            ),
            _MetricTile(
              label: 'Finance bad',
              value: financeBad.toString(),
              ok: financeBad == 0,
            ),
            _MetricTile(
              label: 'Order cron',
              value: orderActive ? 'Aktif' : 'Mati',
              ok: orderActive,
            ),
            _MetricTile(
              label: 'Finance cron',
              value: financeActive ? 'Aktif' : 'Mati',
              ok: financeActive,
            ),
            _MetricTile(
              label: 'Finance lama',
              value: oldFinanceActive ? 'Aktif' : 'Mati',
              ok: !oldFinanceActive,
            ),
            _MetricTile(
              label: 'Product empty',
              value: _intValue(summary['product_bad_count']).toString(),
              ok: _intValue(summary['product_bad_count']) == 0,
            ),
            _MetricTile(
              label: 'Retention rows',
              value: _intValue(summary['retention_old_rows']).toString(),
              ok: _intValue(summary['retention_old_rows']) == 0,
            ),
            _MetricTile(
              label: 'Bootstrap run',
              value: _intValue(summary['bootstrap_running_count']).toString(),
              ok: true,
            ),
            _MetricTile(
              label: 'Retention cron',
              value: _boolValue(summary['retention_cron_active'])
                  ? 'Aktif'
                  : 'Mati',
              ok: _boolValue(summary['retention_cron_active']),
            ),
            _MetricTile(
              label: 'Akun aktif',
              value: _intValue(coverage['active_accounts']).toString(),
              ok: true,
            ),
            _MetricTile(
              label: 'Missing order state',
              value: _intValue(coverage['accounts_missing_order_state'])
                  .toString(),
              ok: _intValue(coverage['accounts_missing_order_state']) == 0,
            ),
            _MetricTile(
              label: 'Missing finance state',
              value: _intValue(coverage['accounts_missing_finance_state'])
                  .toString(),
              ok: _intValue(coverage['accounts_missing_finance_state']) == 0,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.ok,
  });

  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = ok ? Colors.green : theme.colorScheme.error;

    return Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(
            value,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800, color: color),
          ),
        ],
      ),
    );
  }
}

class _AccountAuthSection extends StatelessWidget {
  const _AccountAuthSection({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Akun & Token Marketplace',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Status akun, akses token, refresh token, dan update terakhir per tenant.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Belum ada akun marketplace aktif.'),
              )
            else
              ...rows.map((row) {
                final tokenStatus = _accountTokenStatus(row);
                final ok = tokenStatus == 'token_present' ||
                    tokenStatus == 'access_expiring_soon' ||
                    tokenStatus == 'access_expired_needs_refresh';
                final lastError = _textValue(row['last_error']);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color:
                            ok ? theme.dividerColor : theme.colorScheme.error),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            ok
                                ? Icons.verified_user_outlined
                                : Icons.warning_amber_outlined,
                            color: ok ? Colors.green : theme.colorScheme.error,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${_marketplaceLabel(row['marketplace'])} · ${_storeName(row)}',
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          _InfoRow('Account', _textOrDash(row['status'])),
                          _InfoRow('Token', _tokenLabel(tokenStatus)),
                          _InfoRow('Access exp',
                              _formatDateTime(row['access_token_expired_at'])),
                          _InfoRow('Refresh exp',
                              _formatDateTime(row['refresh_token_expired_at'])),
                          _InfoRow(
                              'Updated', _formatDateTime(row['updated_at'])),
                          _InfoRow('Account ID',
                              _shortId(row['marketplace_account_id'])),
                        ],
                      ),
                      if (lastError.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(lastError,
                            style: TextStyle(color: theme.colorScheme.error)),
                      ],
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _StateSection extends StatelessWidget {
  const _StateSection({
    required this.title,
    required this.subtitle,
    required this.states,
    required this.type,
  });

  final String title;
  final String subtitle;
  final List<Map<String, dynamic>> states;
  final _DispatcherType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(subtitle, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (states.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Belum ada state.'),
              )
            else
              ...states.map((state) => _StateTile(state: state, type: type)),
          ],
        ),
      ),
    );
  }
}

class _StateTile extends StatelessWidget {
  const _StateTile({required this.state, required this.type});

  final Map<String, dynamic> state;
  final _DispatcherType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final marketplace = _marketplaceLabel(state['marketplace']);
    final accountId = _shortId(state['marketplace_account_id']);
    final lockStatus = _textValue(state['lock_status']);
    final failureCount = _intValue(state['failure_count']);
    final lastError = _textValue(state['last_error']);
    final status = _stateStatus(type, state);
    final isOk = _stateOk(type, state, failureCount, lastError, lockStatus);
    final rows = _stateRows(type, state);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(
          color: isOk ? theme.dividerColor : theme.colorScheme.error,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        leading: Icon(
          isOk ? Icons.check_circle_outline : Icons.error_outline,
          color: isOk ? Colors.green : theme.colorScheme.error,
        ),
        title: Text('$marketplace · $accountId'),
        subtitle: Text(
          'Status $status · Failure $failureCount · Lock $lockStatus',
        ),
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: rows,
          ),
          if (lastError.isNotEmpty) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                lastError,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

bool _stateOk(
  _DispatcherType type,
  Map<String, dynamic> state,
  int failureCount,
  String lastError,
  String lockStatus,
) {
  switch (type) {
    case _DispatcherType.order:
    case _DispatcherType.finance:
      return failureCount == 0 &&
          lastError.isEmpty &&
          (lockStatus == 'free' || lockStatus == 'locked');
    case _DispatcherType.product:
      return _intValue(state['product_rows']) > 0;
    case _DispatcherType.retention:
      return _textValue(state['status']) == 'ok';
    case _DispatcherType.bootstrap:
      return !_stateStatus(type, state).toLowerCase().contains('missing');
  }
}

String _stateStatus(_DispatcherType type, Map<String, dynamic> state) {
  switch (type) {
    case _DispatcherType.order:
      return _textValue(state['bootstrap_status']);
    case _DispatcherType.finance:
      return _textValue(state['finance_status']);
    case _DispatcherType.product:
      return _textValue(state['status']);
    case _DispatcherType.retention:
      return _textValue(state['status']);
    case _DispatcherType.bootstrap:
      final order = _textOrDash(state['order_bootstrap_status']);
      final finance = _textOrDash(state['finance_bootstrap_status']);
      return 'Order $order / Finance $finance';
  }
}

List<_InfoRow> _stateRows(_DispatcherType type, Map<String, dynamic> state) {
  switch (type) {
    case _DispatcherType.order:
      return [
        _InfoRow('Mode', _textOrDash(state['last_mode'])),
        _InfoRow('Status', _textOrDash(state['bootstrap_status'])),
        _InfoRow('Cursor', _formatDateTime(state['bootstrap_cursor_at'])),
        _InfoRow('Recent', _formatDateTime(state['recent_cursor_at'])),
        _InfoRow('Last success', _formatDateTime(state['last_success_at'])),
        _InfoRow('Orders 90d', _intValue(state['orders_90d']).toString()),
        _InfoRow('Last order', _formatDateTime(state['last_order_created_at'])),
        _InfoRow('Next run', _formatDateTime(state['next_run_at'])),
      ];
    case _DispatcherType.finance:
      return [
        _InfoRow('Mode', _textOrDash(state['last_mode'])),
        _InfoRow('Status', _textOrDash(state['finance_status'])),
        _InfoRow('Cursor', _textOrDash(state['bootstrap_cursor_date'])),
        _InfoRow('Recent', _textOrDash(state['recent_cursor_date'])),
        _InfoRow('Last success', _formatDateTime(state['last_success_at'])),
        _InfoRow('Checked', _intValue(state['checked_total']).toString()),
        _InfoRow('Synced', _intValue(state['synced_total']).toString()),
        _InfoRow(
            'Reports 90d', _intValue(state['finance_reports_90d']).toString()),
        _InfoRow('Payout 90d', _moneyText(state['payout_sum_90d'])),
        _InfoRow('Next run', _formatDateTime(state['next_run_at'])),
      ];
    case _DispatcherType.product:
      return [
        _InfoRow('Status', _textOrDash(state['status'])),
        _InfoRow('Products', _intValue(state['product_rows']).toString()),
        _InfoRow(
            'Product statuses', _productStatusText(state['product_statuses'])),
        _InfoRow(
            'Last updated', _formatDateTime(state['last_product_updated_at'])),
        _InfoRow('Last seen', _formatDateTime(state['last_product_seen_at'])),
      ];
    case _DispatcherType.retention:
      return [
        _InfoRow('Status', _textOrDash(state['status'])),
        _InfoRow('Cutoff', _textOrDash(state['cutoff_date_wib'])),
        _InfoRow('Old rows', _intValue(state['total_old_rows']).toString()),
        _InfoRow('Old orders', _intValue(state['old_order_rows']).toString()),
        _InfoRow('Old finance',
            _intValue(state['old_finance_report_rows']).toString()),
        _InfoRow(
            'Order jobs', _intValue(state['old_order_job_rows']).toString()),
        _InfoRow('Finance jobs',
            _intValue(state['old_finance_job_rows']).toString()),
        _InfoRow('Refreshed', _formatDateTime(state['refreshed_at'])),
      ];
    case _DispatcherType.bootstrap:
      return [
        _InfoRow('Order status', _textOrDash(state['order_bootstrap_status'])),
        _InfoRow('Order cursor',
            _formatDateTime(state['order_bootstrap_cursor_at'])),
        _InfoRow('Order done',
            _formatDateTime(state['order_bootstrap_completed_at'])),
        _InfoRow(
            'Finance status', _textOrDash(state['finance_bootstrap_status'])),
        _InfoRow('Finance cursor',
            _textOrDash(state['finance_bootstrap_cursor_date'])),
        _InfoRow('Finance done',
            _formatDateTime(state['finance_bootstrap_completed_at'])),
      ];
  }
}

String _productStatusText(Object? value) {
  final rows = _asMapList(value);
  if (rows.isEmpty) return '-';
  return rows
      .map((row) => '${_textOrDash(row['status'])}: ${_intValue(row['rows'])}')
      .join(', ');
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _CronCard extends StatelessWidget {
  const _CronCard({required this.jobs});

  final List<Map<String, dynamic>> jobs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cron Marketplace',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            if (jobs.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Belum ada cron marketplace.'),
              )
            else
              ...jobs.map((job) {
                final active = _boolValue(job['active']);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    active ? Icons.play_circle_outline : Icons.pause_circle,
                    color: active ? Colors.green : Colors.orange,
                  ),
                  title: Text(_textOrDash(job['jobname'])),
                  subtitle: Text('Schedule ${_textOrDash(job['schedule'])}'),
                  trailing: Text(active ? 'Aktif' : 'Mati'),
                );
              }),
          ],
        ),
      ),
    );
  }
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _asMapList(Object? value) {
  if (value is Iterable) {
    return value.map(_asMap).where((item) => item.isNotEmpty).toList();
  }
  return <Map<String, dynamic>>[];
}

String _textValue(Object? value) => value?.toString().trim() ?? '';

String _textOrDash(Object? value) {
  final text = _textValue(value);
  return text.isEmpty ? '-' : text;
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(_textValue(value)) ?? 0;
}

bool _boolValue(Object? value) {
  if (value is bool) return value;
  final text = _textValue(value).toLowerCase();
  return text == 'true' || text == 't' || text == '1';
}

String _formatDateTime(Object? value) {
  return AppUi.formatWibDateTime(value);
}

DateTime? _parseDate(Object? value) {
  final text = _textValue(value);
  if (text.isEmpty || text == 'null') return null;
  return DateTime.tryParse(text);
}

String _storeName(Map<String, dynamic> row) {
  for (final key in const ['store_name', 'store_alias', 'shop_name']) {
    final text = _textValue(row[key]);
    if (text.isNotEmpty) return text;
  }
  return _shortId(row['marketplace_account_id']);
}

String _accountTokenStatus(Map<String, dynamic> row) {
  final status = _textValue(row['status']).toLowerCase();
  if (status.isNotEmpty && status != 'active') return 'inactive';

  final now = DateTime.now().toUtc();
  final refreshExpiry = _parseDate(row['refresh_token_expired_at'])?.toUtc();
  if (refreshExpiry != null && !refreshExpiry.isAfter(now)) {
    return 'refresh_expired_reconnect';
  }

  final accessExpiry = _parseDate(row['access_token_expired_at'])?.toUtc();
  if (accessExpiry == null) return 'token_present';
  if (!accessExpiry.isAfter(now)) return 'access_expired_needs_refresh';
  if (!accessExpiry.isAfter(now.add(const Duration(days: 3)))) {
    return 'access_expiring_soon';
  }
  return 'token_present';
}

String _tokenLabel(String status) {
  switch (status) {
    case 'inactive':
      return 'Akun nonaktif';
    case 'refresh_expired_reconnect':
      return 'Reconnect';
    case 'access_expired_needs_refresh':
      return 'Perlu refresh';
    case 'access_expiring_soon':
      return 'Segera expired';
    case 'token_present':
      return 'OK';
  }
  return status;
}

String _marketplaceLabel(Object? value) {
  final text = _textValue(value);
  if (text == 'tiktok_shop') return 'TikTok';
  if (text == 'shopee') return 'Shopee';
  return text.isEmpty ? 'Marketplace' : text;
}

String _shortId(Object? value) {
  final text = _textValue(value);
  if (text.length <= 8) return _textOrDash(value);
  return '${text.substring(0, 8)}…';
}

String _moneyText(Object? value) {
  final n = num.tryParse(_textValue(value)) ?? 0;
  return 'Rp ${n.round()}';
}
