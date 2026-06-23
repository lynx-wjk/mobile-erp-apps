import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';

class HrPerformancePage extends StatefulWidget {
  const HrPerformancePage({super.key});

  @override
  State<HrPerformancePage> createState() => _HrPerformancePageState();
}

class _HrPerformancePageState extends State<HrPerformancePage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  String? _errorMessage;
  List<_RolePerformance> _items = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<List<Map<String, dynamic>>> _safeSelect(
      String table, String select) async {
    try {
      final response = await _client.from(table).select(select).limit(10000);
      return (response as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final users =
          await _safeSelect('users', 'user_id, nama, email, role_id, status');
      final attendance = await _safeSelect(
          'attendance', 'user_id, status, check_in_time, check_out_time');
      final tasks =
          await _safeSelect('tasks', 'assigned_to, role_target, status');
      final stocks = await _safeSelect('stock_transactions',
          'user_id, transaction_type, jenis_transaksi, created_by');
      final purchases =
          await _safeSelect('purchases', 'created_by, requested_by, status');
      final progress = await _safeSelect(
          'production_progress', 'created_by, user_id, status');
      final finance =
          await _safeSelect('finance_verifications', 'verified_by, status');
      final live =
          await _safeSelect('live_schedules', 'user_id, host_id, status');
      final content = await _safeSelect(
          'content_tasks', 'assigned_to, creator_id, creator_user_id, status');

      final activeUsers = users
          .where((user) => AppUi.text(user['status'], 'active') == 'active')
          .toList();

      final result = activeUsers.map((user) {
        final id = user['user_id']?.toString();
        final role = AppUi.text(user['role_id']);

        int count(List<Map<String, dynamic>> rows,
            bool Function(Map<String, dynamic>) test) {
          return rows.where(test).length;
        }

        final hadir = count(
            attendance,
            (e) =>
                e['user_id']?.toString() == id &&
                AppUi.text(e['status']) == 'valid');
        final outside = count(
            attendance,
            (e) =>
                e['user_id']?.toString() == id &&
                AppUi.text(e['status']) == 'outside_area');
        final assignedTasks =
            count(tasks, (e) => e['assigned_to']?.toString() == id);
        final doneTasks = count(tasks, (e) {
          final status = AppUi.text(e['status']);
          return e['assigned_to']?.toString() == id &&
              (status == 'done' || status == 'verified');
        });

        final metrics = <_Metric>[];
        metrics.add(_Metric('Absensi valid', hadir));
        metrics.add(_Metric('Di luar radius', outside));

        switch (role) {
          case 'warehouse':
            metrics.add(_Metric(
                'Stock IN',
                count(
                    stocks,
                    (e) =>
                        e['user_id']?.toString() == id &&
                        AppUi.text(e['transaction_type']) == 'IN')));
            metrics.add(_Metric(
                'Stock OUT',
                count(
                    stocks,
                    (e) =>
                        e['user_id']?.toString() == id &&
                        AppUi.text(e['transaction_type']) == 'OUT')));
            break;
          case 'produksi':
            metrics.add(_Metric(
                'Progress produksi',
                count(
                    progress,
                    (e) =>
                        e['created_by']?.toString() == id ||
                        e['user_id']?.toString() == id)));
            metrics.add(_Metric(
                'Pembelian dibuat',
                count(
                    purchases,
                    (e) =>
                        e['created_by']?.toString() == id ||
                        e['requested_by']?.toString() == id)));
            break;
          case 'finance':
            metrics.add(_Metric('Verifikasi finance',
                count(finance, (e) => e['verified_by']?.toString() == id)));
            metrics.add(_Metric(
                'Approved',
                count(
                    finance,
                    (e) =>
                        e['verified_by']?.toString() == id &&
                        AppUi.text(e['status']) == 'approved')));
            break;
          case 'host_live':
            metrics.add(_Metric(
                'Jadwal live',
                count(
                    live,
                    (e) =>
                        e['user_id']?.toString() == id ||
                        e['host_id']?.toString() == id)));
            metrics.add(_Metric(
                'Live verified',
                count(
                    live,
                    (e) =>
                        (e['user_id']?.toString() == id ||
                            e['host_id']?.toString() == id) &&
                        AppUi.text(e['status']) == 'verified')));
            break;
          case 'content_creator':
            metrics.add(_Metric(
                'Task konten',
                count(
                    content,
                    (e) =>
                        e['assigned_to']?.toString() == id ||
                        e['creator_id']?.toString() == id ||
                        e['creator_user_id']?.toString() == id)));
            metrics.add(_Metric(
                'Konten approved',
                count(
                    content,
                    (e) =>
                        (e['assigned_to']?.toString() == id ||
                            e['creator_id']?.toString() == id ||
                            e['creator_user_id']?.toString() == id) &&
                        AppUi.text(e['status']) == 'approved')));
            break;
          case 'hr':
            metrics.add(_Metric('Task dibuat/ditangani', assignedTasks));
            metrics.add(_Metric('Live monitoring',
                count(live, (e) => AppUi.text(e['status']).isNotEmpty)));
            metrics.add(_Metric('Content monitoring',
                count(content, (e) => AppUi.text(e['status']).isNotEmpty)));
            break;
          default:
            metrics.add(_Metric(
                'Aktivitas stock',
                count(
                    stocks,
                    (e) =>
                        e['user_id']?.toString() == id ||
                        e['created_by']?.toString() == id)));
            metrics.add(_Metric('Aktivitas task', assignedTasks));
        }

        metrics.add(_Metric('Task assigned', assignedTasks));
        metrics.add(_Metric('Task done', doneTasks));

        final totalScore =
            metrics.fold<int>(0, (sum, metric) => sum + metric.value);

        return _RolePerformance(
          user: user,
          metrics: metrics,
          score: totalScore,
        );
      }).toList()
        ..sort((a, b) => b.score.compareTo(a.score));

      if (!mounted) return;
      setState(() => _items = result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();
    if (_errorMessage != null)
      return ErrorState(message: _errorMessage!, onRetry: _loadData);

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          FuturisticHeader(
            icon: Icons.insights_outlined,
            title: 'Kinerja',
            subtitle:
                'Indikator dibuat per role agar penilaian warehouse, produksi, finance, host live, dan content creator tidak disamaratakan.',
            stats: [
              StatPill(label: 'User', value: _items.length.toString()),
            ],
          ),
          const SizedBox(height: 14),
          if (_items.isEmpty)
            const EmptyState(
                title: 'Data kosong',
                subtitle: 'Belum ada aktivitas untuk direkap.')
          else
            ..._items.map((item) {
              final user = item.user;
              final role = AppUi.text(user['role_id']);
              return NiceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                            child: Text(AppUi.text(user['nama'], '-')
                                .substring(0, 1)
                                .toUpperCase())),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(AppUi.text(user['nama']),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                              Text('${AppUi.text(user['email'])} • $role'),
                            ],
                          ),
                        ),
                        Chip(label: Text('Score ${item.score}')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: item.metrics.map((metric) {
                        return Chip(
                          label: Text('${metric.label}: ${metric.value}'),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kinerja'), actions: [
        IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh))
      ]),
      body: _body(),
    );
  }
}

class _RolePerformance {
  final Map<String, dynamic> user;
  final List<_Metric> metrics;
  final int score;

  const _RolePerformance({
    required this.user,
    required this.metrics,
    required this.score,
  });
}

class _Metric {
  final String label;
  final int value;

  const _Metric(this.label, this.value);
}
