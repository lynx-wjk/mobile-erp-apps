import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';

import '../../../core/ui/web_responsive_layout.dart';

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
  List<Map<String, dynamic>> _rawAttendance = [];
  
  String _searchQuery = '';
  String _selectedRoleFilter = 'all';

  static const List<Map<String, String>> _roleFilters = [
    {'id': 'all', 'label': 'Semua Role'},
    {'id': 'warehouse', 'label': 'Warehouse'},
    {'id': 'produksi', 'label': 'Produksi'},
    {'id': 'finance', 'label': 'Finance'},
    {'id': 'host_live', 'label': 'Host Live'},
    {'id': 'content_creator', 'label': 'Content Creator'},
    {'id': 'hr', 'label': 'HR'},
  ];

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
        'attendance',
        'attendance_id, user_id, user_name, user_email, role_id, date, check_in_time, check_in_lat, check_in_lng, check_in_distance_meter, check_out_time, check_out_lat, check_out_lng, check_out_distance_meter, status, note, created_at',
      );
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

      _rawAttendance = attendance;

      final activeUsers = users.where((user) {
        final status = AppUi.text(user['status'], 'active').toLowerCase();
        final role = AppUi.text(user['role_id']).toLowerCase();
        return status == 'active' &&
            role != 'platform_owner' &&
            role != 'demo_super_admin';
      }).toList();

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
        metrics.add(_Metric('Absensi valid', hadir, icon: Icons.check_circle_outline));
        metrics.add(_Metric('Di luar radius', outside, icon: Icons.wrong_location_outlined));

        switch (role) {
          case 'warehouse':
            metrics.add(_Metric(
                'Stock IN',
                count(
                    stocks,
                    (e) =>
                        e['user_id']?.toString() == id &&
                        AppUi.text(e['transaction_type']) == 'IN'),
                icon: Icons.move_to_inbox_outlined));
            metrics.add(_Metric(
                'Stock OUT',
                count(
                    stocks,
                    (e) =>
                        e['user_id']?.toString() == id &&
                        AppUi.text(e['transaction_type']) == 'OUT'),
                icon: Icons.outbox_outlined));
            break;
          case 'produksi':
            metrics.add(_Metric(
                'Progress produksi',
                count(
                    progress,
                    (e) =>
                        e['created_by']?.toString() == id ||
                        e['user_id']?.toString() == id),
                icon: Icons.precision_manufacturing_outlined));
            metrics.add(_Metric(
                'Pembelian dibuat',
                count(
                    purchases,
                    (e) =>
                        e['created_by']?.toString() == id ||
                        e['requested_by']?.toString() == id),
                icon: Icons.shopping_bag_outlined));
            break;
          case 'finance':
            metrics.add(_Metric('Verifikasi finance',
                count(finance, (e) => e['verified_by']?.toString() == id),
                icon: Icons.verified_user_outlined));
            metrics.add(_Metric(
                'Approved',
                count(
                    finance,
                    (e) =>
                        e['verified_by']?.toString() == id &&
                        AppUi.text(e['status']) == 'approved'),
                icon: Icons.task_alt));
            break;
          case 'host_live':
            metrics.add(_Metric(
                'Jadwal live',
                count(
                    live,
                    (e) =>
                        e['user_id']?.toString() == id ||
                        e['host_id']?.toString() == id),
                icon: Icons.live_tv_outlined));
            metrics.add(_Metric(
                'Live verified',
                count(
                    live,
                    (e) =>
                        (e['user_id']?.toString() == id ||
                            e['host_id']?.toString() == id) &&
                        AppUi.text(e['status']) == 'verified'),
                icon: Icons.verified_outlined));
            break;
          case 'content_creator':
            metrics.add(_Metric(
                'Task konten',
                count(
                    content,
                    (e) =>
                        e['assigned_to']?.toString() == id ||
                        e['creator_id']?.toString() == id ||
                        e['creator_user_id']?.toString() == id),
                icon: Icons.video_library_outlined));
            metrics.add(_Metric(
                'Konten approved',
                count(
                    content,
                    (e) =>
                        (e['assigned_to']?.toString() == id ||
                            e['creator_id']?.toString() == id ||
                            e['creator_user_id']?.toString() == id) &&
                        AppUi.text(e['status']) == 'approved'),
                icon: Icons.thumb_up_outlined));
            break;
          case 'hr':
            metrics.add(_Metric('Task dibuat/ditangani', assignedTasks, icon: Icons.assignment_outlined));
            metrics.add(_Metric('Live monitoring',
                count(live, (e) => AppUi.text(e['status']).isNotEmpty), icon: Icons.monitor_outlined));
            metrics.add(_Metric('Content monitoring',
                count(content, (e) => AppUi.text(e['status']).isNotEmpty), icon: Icons.ondemand_video_outlined));
            break;
          default:
            metrics.add(_Metric(
                'Aktivitas stock',
                count(
                    stocks,
                    (e) =>
                        e['user_id']?.toString() == id ||
                        e['created_by']?.toString() == id),
                icon: Icons.inventory_2_outlined));
            metrics.add(_Metric('Aktivitas task', assignedTasks, icon: Icons.task_outlined));
        }

        metrics.add(_Metric('Task assigned', assignedTasks, icon: Icons.assignment_turned_in_outlined));
        metrics.add(_Metric('Task done', doneTasks, icon: Icons.task_alt_outlined));

        final totalScore =
            metrics.fold<int>(0, (sum, metric) => sum + metric.value);

        return _RolePerformance(
          user: user,
          metrics: metrics,
          score: totalScore,
          hadirCount: hadir,
          outsideCount: outside,
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

  void _showAttendanceDetail(BuildContext context, _RolePerformance item) {
    final userId = item.user['user_id']?.toString() ?? '';
    final userAttendance = _rawAttendance
        .where((e) => e['user_id']?.toString() == userId)
        .toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _UserAttendanceSheet(
        item: item,
        attendanceLogs: userAttendance,
      ),
    );
  }

  List<_RolePerformance> get _filteredItems {
    return _items.where((item) {
      final name = AppUi.text(item.user['nama']).toLowerCase();
      final email = AppUi.text(item.user['email']).toLowerCase();
      final role = AppUi.text(item.user['role_id']).toLowerCase();

      final matchesQuery = _searchQuery.isEmpty ||
          name.contains(_searchQuery.toLowerCase()) ||
          email.contains(_searchQuery.toLowerCase());

      final matchesRole = _selectedRoleFilter == 'all' ||
          role == _selectedRoleFilter.toLowerCase();

      return matchesQuery && matchesRole;
    }).toList();
  }

  Color _getRoleColor(String role) {
    switch (role.toLowerCase()) {
      case 'warehouse':
        return const Color(0xFFF59E0B);
      case 'produksi':
        return const Color(0xFF10B981);
      case 'finance':
        return const Color(0xFF8B5CF6);
      case 'host_live':
        return const Color(0xFF06B6D4);
      case 'content_creator':
        return const Color(0xFFEC4899);
      case 'hr':
        return const Color(0xFF6366F1);
      default:
        return const Color(0xFF3B82F6);
    }
  }

  Widget _buildRoleFilterBar() {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _roleFilters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = _roleFilters[index];
          final isSelected = _selectedRoleFilter == filter['id'];
          final roleColor = filter['id'] == 'all'
              ? Theme.of(context).colorScheme.primary
              : _getRoleColor(filter['id']!);

          return ChoiceChip(
            selected: isSelected,
            label: Text(filter['label']!),
            labelStyle: TextStyle(
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 12.5,
              color: isSelected
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
            ),
            selectedColor: roleColor,
            backgroundColor: roleColor.withOpacity(0.08),
            side: BorderSide(
              color: isSelected
                  ? roleColor
                  : roleColor.withOpacity(0.25),
              width: 1,
            ),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            onSelected: (selected) {
              if (selected) {
                setState(() => _selectedRoleFilter = filter['id']!);
              }
            },
          );
        },
      ),
    );
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();
    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadData);
    }

    final filtered = _filteredItems;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          FuturisticHeader(
            icon: Icons.insights_outlined,
            title: 'Kinerja Team',
            subtitle:
                'Klik pada kartu user untuk melihat detail rincian absensi harian, waktu check-in, dan log lokasi.',
            stats: [
              StatPill(label: 'Aktif User', value: _items.length.toString()),
              StatPill(
                label: 'Filtered',
                value: filtered.length.toString(),
                accentColor: const Color(0xFF10B981),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Search & Filter controls
          Container(
            padding: const EdgeInsets.all(12),
            decoration: AppUi.glassDecoration(context, radius: 16),
            child: Column(
              children: [
                TextField(
                  onChanged: (val) => setState(() => _searchQuery = val),
                  decoration: InputDecoration(
                    hintText: 'Cari nama atau email...',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.5),
                    ),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() => _searchQuery = ''),
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Theme.of(context)
                        .colorScheme
                        .surfaceVariant
                        .withOpacity(0.3),
                  ),
                ),
                const SizedBox(height: 10),
                _buildRoleFilterBar(),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (filtered.isEmpty)
            const EmptyState(
              title: 'Tidak ada data',
              subtitle: 'User tidak ditemukan sesuai filter yang dipilih.',
              icon: Icons.search_off_outlined,
            )
          else
            ...filtered.map((item) {
              final user = item.user;
              final role = AppUi.text(user['role_id']);
              final roleColor = _getRoleColor(role);
              final initial = AppUi.text(user['nama'], '-')
                  .substring(0, 1)
                  .toUpperCase();

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: NiceCard(
                  onTap: () => _showAttendanceDetail(context, item),
                  borderColor: roleColor,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [
                                  roleColor,
                                  roleColor.withOpacity(0.7),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: roleColor.withOpacity(0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                initial,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppUi.text(user['nama']),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: roleColor.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        role.toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: roleColor,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        AppUi.text(user['email']),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.6),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  roleColor.withOpacity(0.15),
                                  roleColor.withOpacity(0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: roleColor.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  '${item.score}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                    color: roleColor,
                                  ),
                                ),
                                const Text(
                                  'SCORE',
                                  style: TextStyle(
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: item.metrics.map((metric) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceVariant
                                  .withOpacity(0.4),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withOpacity(0.3),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  metric.icon,
                                  size: 13,
                                  color: roleColor,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${metric.label}: ',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withOpacity(0.7),
                                  ),
                                ),
                                Text(
                                  '${metric.value}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            'Lihat absensi harian',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: roleColor,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.arrow_forward_ios_rounded,
                            size: 11,
                            color: roleColor,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WebResponsiveScaffold(
      title: 'Kinerja Staff & Absensi',
      actions: [
        IconButton(
          onPressed: _loadData,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh data',
        ),
      ],
      body: _body(),
    );
  }
}

class _RolePerformance {
  final Map<String, dynamic> user;
  final List<_Metric> metrics;
  final int score;
  final int hadirCount;
  final int outsideCount;

  const _RolePerformance({
    required this.user,
    required this.metrics,
    required this.score,
    required this.hadirCount,
    required this.outsideCount,
  });
}

class _Metric {
  final String label;
  final int value;
  final IconData icon;

  const _Metric(this.label, this.value, {this.icon = Icons.analytics_outlined});
}

// ─────────────────────────────────────────────────────────────────────────────
// User Attendance Detail Draggable Scrollable Sheet
// ─────────────────────────────────────────────────────────────────────────────
class _UserAttendanceSheet extends StatefulWidget {
  final _RolePerformance item;
  final List<Map<String, dynamic>> attendanceLogs;

  const _UserAttendanceSheet({
    required this.item,
    required this.attendanceLogs,
  });

  @override
  State<_UserAttendanceSheet> createState() => _UserAttendanceSheetState();
}

class _UserAttendanceSheetState extends State<_UserAttendanceSheet> {
  late DateTime _selectedMonth;

  static const List<String> _monthNames = [
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
    'Desember'
  ];

  @override
  void initState() {
    super.initState();
    _selectedMonth = DateTime.now();
  }

  void _previousMonth() {
    setState(() {
      _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1);
    });
  }

  List<Map<String, dynamic>> get _filteredLogs {
    return widget.attendanceLogs.where((log) {
      final dateStr = log['date']?.toString() ?? log['created_at']?.toString();
      if (dateStr == null) return false;
      final parsed = DateTime.tryParse(dateStr);
      if (parsed == null) return false;
      return parsed.year == _selectedMonth.year &&
          parsed.month == _selectedMonth.month;
    }).toList()
      ..sort((a, b) {
        final dA = DateTime.tryParse(a['date']?.toString() ?? '') ??
            DateTime(1970);
        final dB = DateTime.tryParse(b['date']?.toString() ?? '') ??
            DateTime(1970);
        return dB.compareTo(dA);
      });
  }

  Color _getRoleColor(String role) {
    switch (role.toLowerCase()) {
      case 'warehouse':
        return const Color(0xFFF59E0B);
      case 'produksi':
        return const Color(0xFF10B981);
      case 'finance':
        return const Color(0xFF8B5CF6);
      case 'host_live':
        return const Color(0xFF06B6D4);
      case 'content_creator':
        return const Color(0xFFEC4899);
      case 'hr':
        return const Color(0xFF6366F1);
      default:
        return const Color(0xFF3B82F6);
    }
  }

  String _formatTime(dynamic val) {
    if (val == null) return '-';
    final str = val.toString().trim();
    if (str.isEmpty) return '-';

    if (str.contains('T')) {
      final dt = DateTime.tryParse(str);
      if (dt != null) {
        final wib = dt.toUtc().add(const Duration(hours: 7));
        String two(int n) => n.toString().padLeft(2, '0');
        return '${two(wib.hour)}:${two(wib.minute)} WIB';
      }
    }
    if (str.contains(':')) {
      final parts = str.split(':');
      if (parts.length >= 2) {
        return '${parts[0].padLeft(2, '0')}:${parts[1].padLeft(2, '0')} WIB';
      }
    }
    return str;
  }

  String _formatDayDate(dynamic val) {
    if (val == null) return '-';
    final dt = DateTime.tryParse(val.toString());
    if (dt == null) return val.toString();

    const days = [
      'Minggu',
      'Senin',
      'Selasa',
      'Rabu',
      'Kamis',
      'Jumat',
      'Sabtu'
    ];
    final dayName = days[dt.weekday % 7];
    String two(int n) => n.toString().padLeft(2, '0');
    return '$dayName, ${two(dt.day)} ${_monthNames[dt.month - 1]} ${dt.year}';
  }

  Widget _buildStatusBadge(String status) {
    final clean = status.toLowerCase();
    Color bg;
    Color fg;
    String label;
    IconData icon;

    if (clean == 'valid') {
      bg = const Color(0xFF10B981).withOpacity(0.15);
      fg = const Color(0xFF10B981);
      label = 'VALID';
      icon = Icons.check_circle_rounded;
    } else if (clean == 'outside_area') {
      bg = const Color(0xFFF59E0B).withOpacity(0.15);
      fg = const Color(0xFFF59E0B);
      label = 'DI LUAR RADIUS';
      icon = Icons.warning_amber_rounded;
    } else {
      bg = const Color(0xFFEF4444).withOpacity(0.15);
      fg = const Color(0xFFEF4444);
      label = status.toUpperCase();
      icon = Icons.info_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: fg.withOpacity(0.3), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.item.user;
    final role = AppUi.text(user['role_id']);
    final roleColor = _getRoleColor(role);
    final filteredLogs = _filteredLogs;

    final validCount = filteredLogs
        .where((e) => AppUi.text(e['status']) == 'valid')
        .length;
    final outsideCount = filteredLogs
        .where((e) => AppUi.text(e['status']) == 'outside_area')
        .length;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            children: [
              // Drag Indicator
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),

              // Header User Profile Info
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [roleColor, roleColor.withOpacity(0.7)],
                        ),
                      ),
                      child: Center(
                        child: Text(
                          AppUi.text(user['nama'], '-')
                              .substring(0, 1)
                              .toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppUi.text(user['nama']),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            '${AppUi.text(user['email'])} • ${role.toUpperCase()}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),

              // Content Area
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20),
                  children: [
                    // Month Picker Header
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: AppUi.glassDecoration(context, radius: 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            onPressed: _previousMonth,
                          ),
                          Row(
                            children: [
                              const Icon(Icons.calendar_month_outlined,
                                  size: 18),
                              const SizedBox(width: 8),
                              Text(
                                '${_monthNames[_selectedMonth.month - 1]} ${_selectedMonth.year}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _nextMonth,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Month Summary Stats
                    Row(
                      children: [
                        Expanded(
                          child: StatPill(
                            label: 'Total Hadir Valid',
                            value: '$validCount Hari',
                            accentColor: const Color(0xFF10B981),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: StatPill(
                            label: 'Di Luar Radius',
                            value: '$outsideCount Hari',
                            accentColor: const Color(0xFFF59E0B),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: StatPill(
                            label: 'Total Entry',
                            value: '${filteredLogs.length} Log',
                            accentColor: roleColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Daily Timeline List Header
                    Row(
                      children: [
                        const Icon(Icons.history_outlined, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          'Riwayat Absensi Harian (${filteredLogs.length})',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    if (filteredLogs.isEmpty)
                      const EmptyState(
                        title: 'Tidak ada absensi',
                        subtitle:
                            'Belum ada rekaman absensi untuk bulan ini.',
                        icon: Icons.event_busy_outlined,
                      )
                    else
                      ...filteredLogs.map((log) {
                        final checkInTime = _formatTime(log['check_in_time']);
                        final checkOutTime = _formatTime(log['check_out_time']);
                        final status = AppUi.text(log['status'], 'valid');
                        final dateFormatted = _formatDayDate(log['date'] ?? log['created_at']);
                        final note = AppUi.text(log['note'], '');

                        final inMeter = AppUi.toNum(log['check_in_distance_meter']);
                        final outMeter = AppUi.toNum(log['check_out_distance_meter']);

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: AppUi.modernCardDecoration(context,
                                radius: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Date & Status Row
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        dateFormatted,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                    ),
                                    _buildStatusBadge(status),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                const Divider(height: 1),
                                const SizedBox(height: 10),

                                // Check-in and Check-out Times
                                Row(
                                  children: [
                                    Expanded(
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF10B981)
                                              .withOpacity(0.08),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Row(
                                              children: [
                                                Icon(Icons.login_rounded,
                                                    size: 14,
                                                    color: Color(0xFF10B981)),
                                                SizedBox(width: 4),
                                                Text(
                                                  'CHECK-IN',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w700,
                                                    color: Color(0xFF10B981),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              checkInTime,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 13,
                                              ),
                                            ),
                                            if (inMeter > 0) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                '📍 ${inMeter.round()}m dari lokasi',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withOpacity(0.6),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF59E0B)
                                              .withOpacity(0.08),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Row(
                                              children: [
                                                Icon(Icons.logout_rounded,
                                                    size: 14,
                                                    color: Color(0xFFF59E0B)),
                                                SizedBox(width: 4),
                                                Text(
                                                  'CHECK-OUT',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w700,
                                                    color: Color(0xFFF59E0B),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              checkOutTime,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 13,
                                              ),
                                            ),
                                            if (outMeter > 0) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                '📍 ${outMeter.round()}m dari lokasi',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withOpacity(0.6),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),

                                if (note.isNotEmpty && note != '-') ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surfaceVariant
                                          .withOpacity(0.3),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Icon(Icons.sticky_note_2_outlined,
                                            size: 13),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            'Catatan: $note',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
