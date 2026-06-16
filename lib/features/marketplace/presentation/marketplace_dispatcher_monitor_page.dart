import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      if (!mounted) return;

      setState(() {
        _payload = _asMap(response);
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

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    final summary = _asMap(payload?['summary']);
    final coverage = _asMap(payload?['coverage']);
    final orderStates = _asMapList(payload?['order_states']);
    final financeStates = _asMapList(payload?['finance_states']);
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
              _CronCard(jobs: cronJobs),
            ],
          ],
        ),
      ),
    );
  }
}

enum _DispatcherType { order, finance }

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
              label: 'Akun aktif',
              value: _intValue(coverage['active_accounts']).toString(),
              ok: true,
            ),
            _MetricTile(
              label: 'Missing order state',
              value:
                  _intValue(coverage['accounts_missing_order_state']).toString(),
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
    final isOk = failureCount == 0 &&
        lastError.isEmpty &&
        (lockStatus == 'free' || lockStatus == 'locked');

    final status = type == _DispatcherType.order
        ? _textValue(state['bootstrap_status'])
        : _textValue(state['finance_status']);

    final rows = type == _DispatcherType.order
        ? [
            _InfoRow('Mode', _textOrDash(state['last_mode'])),
            _InfoRow('Status', _textOrDash(status)),
            _InfoRow('Cursor', _formatDateTime(state['bootstrap_cursor_at'])),
            _InfoRow('Recent', _formatDateTime(state['recent_cursor_at'])),
            _InfoRow('Last success', _formatDateTime(state['last_success_at'])),
            _InfoRow('Orders 90d', _intValue(state['orders_90d']).toString()),
            _InfoRow('Last order',
                _formatDateTime(state['last_order_created_at'])),
            _InfoRow('Next run', _formatDateTime(state['next_run_at'])),
          ]
        : [
            _InfoRow('Mode', _textOrDash(state['last_mode'])),
            _InfoRow('Status', _textOrDash(status)),
            _InfoRow('Cursor', _textOrDash(state['bootstrap_cursor_date'])),
            _InfoRow('Recent', _textOrDash(state['recent_cursor_date'])),
            _InfoRow('Last success', _formatDateTime(state['last_success_at'])),
            _InfoRow('Checked', _intValue(state['checked_total']).toString()),
            _InfoRow('Synced', _intValue(state['synced_total']).toString()),
            _InfoRow('Reports 90d',
                _intValue(state['finance_reports_90d']).toString()),
            _InfoRow('Payout 90d', _moneyText(state['payout_sum_90d'])),
            _InfoRow('Next run', _formatDateTime(state['next_run_at'])),
          ];

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
  final text = _textValue(value);
  if (text.isEmpty || text == 'null') return '-';
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return text;
  final local = parsed.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
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
