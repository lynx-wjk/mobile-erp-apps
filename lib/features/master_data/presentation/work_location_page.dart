import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/web_responsive_layout.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/ui/app_ui.dart';
import '../models/work_location.dart';
import '../repositories/master_data_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// WorkLocationPage — Tab: Lokasi Kerja | Jam Kerja per User
// ─────────────────────────────────────────────────────────────────────────────
class WorkLocationPage extends StatefulWidget {
  const WorkLocationPage({super.key});

  @override
  State<WorkLocationPage> createState() => _WorkLocationPageState();
}

class _WorkLocationPageState extends State<WorkLocationPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lokasi & Jam Kerja'),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: 'Lokasi Kerja'),
            Tab(text: 'Jam Kerja per User'),
          ],
        ),
      ),
      body: WebResponsiveWrapper(
        activeTitle: 'Lokasi & Jam Kerja',
        child: TabBarView(
          controller: _tabCtrl,
          children: const [
            _LocationTab(),
            _WorkScheduleTab(),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1 — Lokasi Kerja
// ─────────────────────────────────────────────────────────────────────────────
class _LocationTab extends StatefulWidget {
  const _LocationTab();

  @override
  State<_LocationTab> createState() => _LocationTabState();
}

class _LocationTabState extends State<_LocationTab> {
  final _repository = MasterDataRepository();
  final _searchCtrl = TextEditingController();

  bool _isLoading = true;
  bool _isSuperAdmin = false;
  bool _isDemoSuperAdmin = false;
  bool get _canManage => _isSuperAdmin && !_isDemoSuperAdmin;
  String? _error;
  List<WorkLocation> _locations = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) {
        final profile = await Supabase.instance.client
            .from('users')
            .select('role_id, is_demo_account, username, email')
            .eq('user_id', uid)
            .maybeSingle();
        final role = profile?['role_id']?.toString().toLowerCase().trim() ?? '';
        final username =
            profile?['username']?.toString().toLowerCase().trim() ?? '';
        final email = profile?['email']?.toString().toLowerCase().trim() ?? '';
        _isDemoSuperAdmin = role == 'demo_super_admin' ||
            profile?['is_demo_account'] == true ||
            username == 'demo_super_admin' ||
            email.contains('demo_super_admin');
        _isSuperAdmin = role == 'super_admin' && !_isDemoSuperAdmin;
      }
      final locations = await _repository.getWorkLocations();
      if (!mounted) return;
      setState(() => _locations = locations);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memuat lokasi. Coba refresh.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<WorkLocation> get _filtered {
    final kw = _searchCtrl.text.trim().toLowerCase();
    if (kw.isEmpty) return _locations;
    return _locations
        .where(
          (loc) =>
              loc.namaLokasi.toLowerCase().contains(kw) ||
              (loc.alamat ?? '').toLowerCase().contains(kw),
        )
        .toList();
  }

  Future<void> _delete(WorkLocation loc) async {
    if (!_isSuperAdmin) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: const Text('Hapus lokasi kerja?'),
        content: Text('Lokasi "${loc.namaLokasi}" akan dihapus permanen.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Hapus'),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Colors.white),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client
          .rpc('delete_record_for_super_admin', params: {
        'p_table_name': 'work_locations',
        'p_record_id': loc.locationId,
      });
      AppUi.showSnack('Lokasi berhasil dihapus.');
      await _load();
    } catch (_) {
      AppUi.showSnack('Gagal hapus lokasi. Coba lagi.');
    }
  }

  Future<void> _openForm({WorkLocation? location}) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => WorkLocationFormPage(location: location)),
    );
    if (result == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Cari nama lokasi / alamat…',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_isLoading) {
      return const Center(child: FuturisticLoader(message: 'Memuat lokasi…'));
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }
    final locs = _filtered;
    if (locs.isEmpty) {
      return const EmptyState(
        icon: Icons.location_off_outlined,
        title: 'Belum ada lokasi',
        subtitle: 'Tambah titik lokasi kerja untuk validasi absensi GPS.',
      );
    }
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            itemCount: locs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final loc = locs[i];
              return NiceCard(
                onTap: () => _openForm(location: loc),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: (loc.isActive
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error)
                            .withOpacity(0.12),
                      ),
                      child: Icon(
                        loc.isActive
                            ? Icons.location_on_rounded
                            : Icons.location_off_rounded,
                        color: loc.isActive
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(loc.namaLokasi,
                              style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color:
                                      Theme.of(context).colorScheme.onSurface)),
                          const SizedBox(height: 2),
                          Text(
                            'Radius ${loc.radiusMeter.toStringAsFixed(0)} m  ·  ${loc.status}',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppUi.mutedText(context, 0.90)),
                          ),
                          if ((loc.alamat ?? '').isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              loc.alamat!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withOpacity(0.4)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_canManage)
                      IconButton(
                        onPressed: () => _delete(loc),
                        icon: const Icon(Icons.delete_outline_rounded, size: 20),
                        color: Theme.of(context)
                            .colorScheme
                            .error
                            .withOpacity(0.7),
                        tooltip: 'Hapus lokasi',
                      ),
                    Icon(Icons.chevron_right_rounded,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 18),
                  ],
                ),
              );
            },
          ),
        ),
        if (_canManage)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add_location_alt_rounded),
              label: const Text('Tambah Lokasi'),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 2 — Jam Kerja per User
// ─────────────────────────────────────────────────────────────────────────────
class _WorkScheduleTab extends StatefulWidget {
  const _WorkScheduleTab();

  @override
  State<_WorkScheduleTab> createState() => _WorkScheduleTabState();
}

class _WorkScheduleTabState extends State<_WorkScheduleTab> {
  final _client = Supabase.instance.client;

  bool _isLoading = true;
  String? _error;

  List<Map<String, dynamic>> _users = [];
  Map<String, List<Map<String, dynamic>>> _userSchedulesMap = {};

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

  static const _dayShortNames = ['Ming', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab'];

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final userData = await _client
          .from('users')
          .select('user_id, nama, role_id, status, email')
          .neq('status', 'deleted')
          .neq('role_id', 'platform_owner')
          .order('nama');

      final users = (userData as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      final schedData = await _client
          .from('user_work_schedules')
          .select('user_id, day_of_week, start_time, end_time, late_tolerance_minutes, is_active');

      final schedules = (schedData as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      final Map<String, List<Map<String, dynamic>>> schedMap = {};
      for (final s in schedules) {
        final uid = s['user_id']?.toString();
        if (uid != null) {
          schedMap.putIfAbsent(uid, () => []).add(s);
        }
      }

      if (!mounted) return;
      setState(() {
        _users = users;
        _userSchedulesMap = schedMap;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memuat daftar user. Coba refresh.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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

  List<Map<String, dynamic>> get _filteredUsers {
    return _users.where((user) {
      final name = AppUi.text(user['nama']).toLowerCase();
      final email = AppUi.text(user['email']).toLowerCase();
      final role = AppUi.text(user['role_id']).toLowerCase();

      final matchesQuery = _searchQuery.isEmpty ||
          name.contains(_searchQuery.toLowerCase()) ||
          email.contains(_searchQuery.toLowerCase());

      final matchesRole = _selectedRoleFilter == 'all' ||
          role == _selectedRoleFilter.toLowerCase();

      return matchesQuery && matchesRole;
    }).toList();
  }

  void _showUserScheduleModal(Map<String, dynamic> user) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _UserScheduleBottomSheet(
        user: user,
        allUsers: _users,
        existingRows: _userSchedulesMap[user['user_id']?.toString()] ?? [],
        onSaved: _loadAllData,
      ),
    );
  }

  String _buildScheduleSummary(List<Map<String, dynamic>> rows) {
    final activeRows = rows.where((r) => r['is_active'] == true).toList()
      ..sort((a, b) => (a['day_of_week'] as int).compareTo(b['day_of_week'] as int));

    if (activeRows.isEmpty) return 'Nonaktif seluruh hari';

    final daysStr = activeRows.map((r) {
      final day = r['day_of_week'] as int? ?? 0;
      return day >= 0 && day <= 6 ? _dayShortNames[day] : '';
    }).where((s) => s.isNotEmpty).join(', ');

    final firstStart = activeRows.first['start_time']?.toString() ?? '08:00';
    final firstEnd = activeRows.first['end_time']?.toString() ?? '17:00';

    return '$daysStr ($firstStart - $firstEnd)';
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
              color: isSelected ? roleColor : roleColor.withOpacity(0.25),
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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: FuturisticLoader(message: 'Memuat data user…'));
    }
    if (_error != null && _users.isEmpty) {
      return ErrorState(message: _error!, onRetry: _loadAllData);
    }

    final filtered = _filteredUsers;

    return RefreshIndicator(
      onRefresh: _loadAllData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
        children: [
          // Info banner header
          FuturisticHeader(
            icon: Icons.access_time_filled_rounded,
            title: 'Pengaturan Jam Kerja User',
            subtitle:
                'Klik kartu user mana saja untuk mengatur jam kerja 7 hari & toleransi keterlambatan. User dengan jadwal khusus ditandai badge glowing.',
            stats: [
              StatPill(label: 'Total User', value: _users.length.toString()),
              StatPill(
                label: 'Jadwal Khusus',
                value: _userSchedulesMap.keys.length.toString(),
                accentColor: const Color(0xFF10B981),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Search & Role Filter Bar
          Container(
            padding: const EdgeInsets.all(12),
            decoration: AppUi.glassDecoration(context, radius: 16),
            child: Column(
              children: [
                TextField(
                  onChanged: (val) => setState(() => _searchQuery = val),
                  decoration: InputDecoration(
                    hintText: 'Cari nama atau email user…',
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
              title: 'User tidak ditemukan',
              subtitle: 'Tidak ada user aktif sesuai kriteria pencarian.',
              icon: Icons.search_off_outlined,
            )
          else
            ...filtered.map((user) {
              final uid = user['user_id']?.toString() ?? '';
              final name = AppUi.text(user['nama']);
              final email = AppUi.text(user['email']);
              final role = AppUi.text(user['role_id']);
              final roleColor = _getRoleColor(role);

              final userSchedules = _userSchedulesMap[uid];
              final bool hasCustomSchedule =
                  userSchedules != null && userSchedules.isNotEmpty;

              final initial = name.substring(0, 1).toUpperCase();

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: NiceCard(
                  onTap: () => _showUserScheduleModal(user),
                  borderColor: hasCustomSchedule
                      ? const Color(0xFF10B981)
                      : roleColor.withOpacity(0.3),
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
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: roleColor.withOpacity(0.25),
                                  blurRadius: 6,
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
                                  name,
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
                                        email,
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

                          // Status Badge: Custom vs Default
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: hasCustomSchedule
                                  ? const Color(0xFF10B981).withOpacity(0.15)
                                  : Theme.of(context)
                                      .colorScheme
                                      .secondary
                                      .withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: hasCustomSchedule
                                    ? const Color(0xFF10B981).withOpacity(0.4)
                                    : Theme.of(context)
                                        .colorScheme
                                        .secondary
                                        .withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  hasCustomSchedule
                                      ? Icons.check_circle_rounded
                                      : Icons.schedule_rounded,
                                  size: 13,
                                  color: hasCustomSchedule
                                      ? const Color(0xFF10B981)
                                      : Theme.of(context).colorScheme.secondary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  hasCustomSchedule
                                      ? 'JADWAL KHUSUS'
                                      : 'JADWAL DEFAULT',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: hasCustomSchedule
                                        ? const Color(0xFF10B981)
                                        : Theme.of(context)
                                            .colorScheme
                                            .secondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceVariant
                              .withOpacity(0.35),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.alarm_on_outlined,
                              size: 15,
                              color: hasCustomSchedule
                                  ? const Color(0xFF10B981)
                                  : Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                hasCustomSchedule
                                    ? _buildScheduleSummary(userSchedules)
                                    : 'Default Sistem: Sen–Jum (08:00 - 17:00, Tol: 15m)',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.tune_rounded,
                              size: 14,
                              color: roleColor,
                            ),
                          ],
                        ),
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
}

// ─────────────────────────────────────────────────────────────────────────────
// User Schedule Draggable Bottom Sheet & Editor
// ─────────────────────────────────────────────────────────────────────────────
class _UserScheduleBottomSheet extends StatefulWidget {
  final Map<String, dynamic> user;
  final List<Map<String, dynamic>> allUsers;
  final List<Map<String, dynamic>> existingRows;
  final VoidCallback onSaved;

  const _UserScheduleBottomSheet({
    required this.user,
    required this.allUsers,
    required this.existingRows,
    required this.onSaved,
  });

  @override
  State<_UserScheduleBottomSheet> createState() =>
      _UserScheduleBottomSheetState();
}

class _UserScheduleBottomSheetState extends State<_UserScheduleBottomSheet> {
  final _client = Supabase.instance.client;

  final Map<int, _DaySchedule> _schedule = {};
  bool _saving = false;

  static const _dayNames = [
    'Minggu',
    'Senin',
    'Selasa',
    'Rabu',
    'Kamis',
    'Jumat',
    'Sabtu'
  ];

  @override
  void initState() {
    super.initState();
    _initSchedule();
  }

  static bool _parseBool(dynamic val) {
    if (val == null) return false;
    if (val is bool) return val;
    final str = val.toString().toLowerCase().trim();
    return str == 'true' || str == '1' || str == 't' || str == 'yes' || str == 'on';
  }

  void _initSchedule() {
    for (int d = 0; d < 7; d++) {
      _schedule[d] = _DaySchedule(
        dayOfWeek: d,
        isActive: d >= 1 && d <= 5,
        startTime: const TimeOfDay(hour: 8, minute: 0),
        endTime: const TimeOfDay(hour: 17, minute: 0),
        lateTolerance: 15,
      );
    }

    for (final row in widget.existingRows) {
      final rawDay = row['day_of_week'];
      int day = rawDay is int ? rawDay : int.tryParse(rawDay?.toString() ?? '') ?? -1;
      if (day == 7) day = 0;
      if (day < 0 || day > 6) continue;
      _schedule[day] = _DaySchedule(
        dayOfWeek: day,
        isActive: _parseBool(row['is_active']),
        startTime: _parseTime(row['start_time']?.toString() ?? '08:00'),
        endTime: _parseTime(row['end_time']?.toString() ?? '17:00'),
        lateTolerance: row['late_tolerance_minutes'] is int
            ? (row['late_tolerance_minutes'] as int)
            : int.tryParse(row['late_tolerance_minutes']?.toString() ?? '15') ?? 15,
      );
    }
  }

  static TimeOfDay _parseTime(String raw) {
    final parts = raw.split(':');
    if (parts.length < 2) return const TimeOfDay(hour: 8, minute: 0);
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 8,
      minute: int.tryParse(parts[1]) ?? 0,
    );
  }

  static String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _bulkApplyDays(List<int> days) {
    final monSched = _schedule[1]!;
    for (final d in days) {
      _schedule[d] = _schedule[d]!.copyWith(
        startTime: monSched.startTime,
        endTime: monSched.endTime,
        lateTolerance: monSched.lateTolerance,
        isActive: true,
      );
    }
    for (int d = 0; d <= 6; d++) {
      if (!days.contains(d)) {
        _schedule[d] = _schedule[d]!.copyWith(isActive: false);
      }
    }
    setState(() {});
    AppUi.showSnack('Jadwal diaplikasikan ke ${days.map((d) => _dayNames[d]).join(", ")}.');
  }

  Future<void> _pickTime(int day, bool isStart) async {
    final current =
        isStart ? _schedule[day]!.startTime : _schedule[day]!.endTime;
    final picked =
        await showTimePicker(context: context, initialTime: current);
    if (!mounted || picked == null) return;
    setState(() {
      if (isStart) {
        _schedule[day] = _schedule[day]!.copyWith(startTime: picked);
      } else {
        _schedule[day] = _schedule[day]!.copyWith(endTime: picked);
      }
    });
  }

  Future<void> _save({List<String>? targetUserIds}) async {
    final targetIds = targetUserIds ?? [widget.user['user_id']?.toString() ?? ''];
    if (targetIds.isEmpty || targetIds.first.isEmpty) return;

    setState(() => _saving = true);
    try {
      final List<Map<String, dynamic>> allRows = [];

      for (final uid in targetIds) {
        for (final s in _schedule.values) {
          allRows.add({
            'user_id': uid,
            'day_of_week': s.dayOfWeek,
            'start_time': _formatTime(s.startTime),
            'end_time': _formatTime(s.endTime),
            'late_tolerance_minutes': s.lateTolerance,
            'timezone': 'Asia/Jakarta',
            'is_active': s.isActive,
          });
        }
      }

      await _client.rpc(
        'user_work_schedule_upsert_bulk',
        params: {'p_rows': allRows},
      );

      if (!mounted) return;
      AppUi.showSnack(targetIds.length > 1
          ? 'Jadwal berhasil disalin ke ${targetIds.length} user!'
          : 'Jadwal kerja ${AppUi.text(widget.user['nama'])} berhasil disimpan.');

      widget.onSaved();
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      AppUi.showSnack('Gagal menyimpan jadwal. Coba lagi.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyToRoleUsers() async {
    final role = AppUi.text(widget.user['role_id']);
    final roleUsers = widget.allUsers
        .where((u) => AppUi.text(u['role_id']) == role)
        .map((u) => u['user_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    if (roleUsers.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Salin Jadwal ke Role $role?'),
        content: Text(
            'Jadwal ini akan disalin ke ${roleUsers.length} user yang memiliki role "$role".'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ya, Salin')),
        ],
      ),
    );

    if (confirm == true) {
      await _save(targetUserIds: roleUsers);
    }
  }

  Future<void> _copyToAllUsers() async {
    final allIds = widget.allUsers
        .map((u) => u['user_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    if (allIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Terapkan ke Semuanya (Batch All)?'),
        content: Text(
            'Jadwal ini akan diterapkan ke SELURUH (${allIds.length}) karyawan/user aktif di sistem.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ya, Terapkan Semua')),
        ],
      ),
    );

    if (confirm == true) {
      await _save(targetUserIds: allIds);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userName = AppUi.text(widget.user['nama']);
    final role = AppUi.text(widget.user['role_id']);

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.5,
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

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Edit Jadwal: $userName',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            'Role: ${role.toUpperCase()}',
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
              const SizedBox(height: 8),
              const Divider(height: 1),

              // Form body
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20),
                  children: [
                    // Presets
                    NiceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Terapkan Preset Cepat',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () =>
                                    _bulkApplyDays([1, 2, 3, 4, 5]),
                                child: const Text('Senin–Jumat'),
                              ),
                              OutlinedButton(
                                onPressed: () =>
                                    _bulkApplyDays([1, 2, 3, 4, 5, 6]),
                                child: const Text('Senin–Sabtu'),
                              ),
                              OutlinedButton(
                                onPressed: () =>
                                    _bulkApplyDays([0, 1, 2, 3, 4, 5, 6]),
                                child: const Text('Senin–Minggu'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    const SectionTitle(title: 'Jadwal 7 Hari Kerja'),
                    const SizedBox(height: 10),

                    ...List.generate(7, (day) {
                      final sched = _schedule[day]!;
                      final active = sched.isActive;
                      final color = active
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: NiceCard(
                          borderColor: active
                              ? Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.3)
                              : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _dayNames[day],
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: active
                                            ? Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                            : AppUi.mutedText(context, 0.92),
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  Switch(
                                    value: active,
                                    activeColor:
                                        Theme.of(context).colorScheme.primary,
                                    onChanged: (v) => setState(() =>
                                        _schedule[day] =
                                            sched.copyWith(isActive: v)),
                                  ),
                                ],
                              ),
                              if (active) ...[
                                const Divider(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _timeBtn('JAM MULAI', sched.startTime,
                                          color, () => _pickTime(day, true)),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _timeBtn(
                                          'JAM SELESAI',
                                          sched.endTime,
                                          color,
                                          () => _pickTime(day, false)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    const Text(
                                      'Toleransi telat:',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      onPressed: sched.lateTolerance <= 0
                                          ? null
                                          : () => setState(() => _schedule[day] =
                                              sched.copyWith(
                                                  lateTolerance:
                                                      sched.lateTolerance - 5)),
                                      icon: const Icon(
                                          Icons.remove_circle_outline,
                                          size: 20),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8),
                                      child: Text(
                                        '${sched.lateTolerance} menit',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () => setState(() =>
                                          _schedule[day] = sched.copyWith(
                                              lateTolerance:
                                                  sched.lateTolerance + 5)),
                                      icon: const Icon(
                                          Icons.add_circle_outline,
                                          size: 20),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 16),

                    // Actions Row
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _saving ? null : _copyToRoleUsers,
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: Text('Role $role'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: _saving ? null : _copyToAllUsers,
                            icon: const Icon(Icons.groups_outlined, size: 18),
                            label: const Text('Semua User'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    FilledButton.icon(
                      onPressed: _saving ? null : () => _save(),
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.save_rounded),
                      label: Text(
                        _saving ? 'Menyimpan…' : 'Simpan Jadwal $userName',
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
  }

  Widget _timeBtn(
      String label, TimeOfDay time, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: color.withOpacity(0.08),
          border: Border.all(color: color.withOpacity(0.20), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 9.5,
                color: color.withOpacity(0.8),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _formatTime(time),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DaySchedule {
  final int dayOfWeek;
  final bool isActive;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final int lateTolerance;

  const _DaySchedule({
    required this.dayOfWeek,
    required this.isActive,
    required this.startTime,
    required this.endTime,
    required this.lateTolerance,
  });

  _DaySchedule copyWith(
      {bool? isActive,
      TimeOfDay? startTime,
      TimeOfDay? endTime,
      int? lateTolerance}) {
    return _DaySchedule(
      dayOfWeek: dayOfWeek,
      isActive: isActive ?? this.isActive,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      lateTolerance: lateTolerance ?? this.lateTolerance,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WorkLocationFormPage (Location Form with GPS & Maps launcher)
// ─────────────────────────────────────────────────────────────────────────────
class WorkLocationFormPage extends StatefulWidget {
  final WorkLocation? location;

  const WorkLocationFormPage({super.key, this.location});

  @override
  State<WorkLocationFormPage> createState() => _WorkLocationFormPageState();
}

class _WorkLocationFormPageState extends State<WorkLocationFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _repository = MasterDataRepository();

  final _namaCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  final _radiusCtrl = TextEditingController(text: '100');
  final _alamatCtrl = TextEditingController();
  final _catatanCtrl = TextEditingController();

  bool _isSaving = false;
  bool _isGettingGps = false;
  bool _isDemoSuperAdmin = false;
  String _status = 'active';

  bool get _isEdit => widget.location != null;

  @override
  void initState() {
    super.initState();
    _loadDemoRole();
    final loc = widget.location;
    if (loc != null) {
      _namaCtrl.text = loc.namaLokasi;
      _latCtrl.text = loc.latitude.toString();
      _lngCtrl.text = loc.longitude.toString();
      _radiusCtrl.text = loc.radiusMeter.toString();
      _alamatCtrl.text = loc.alamat ?? '';
      _catatanCtrl.text = loc.catatan ?? '';
      _status = loc.status == 'inactive' ? 'inactive' : 'active';
    }
  }

  Future<void> _loadDemoRole() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final profile = await Supabase.instance.client
          .from('users')
          .select('role_id, is_demo_account, username, email')
          .eq('user_id', uid)
          .maybeSingle();
      final role = profile?['role_id']?.toString().toLowerCase().trim() ?? '';
      final username =
          profile?['username']?.toString().toLowerCase().trim() ?? '';
      final email = profile?['email']?.toString().toLowerCase().trim() ?? '';
      if (!mounted) return;
      setState(() {
        _isDemoSuperAdmin = role == 'demo_super_admin' ||
            profile?['is_demo_account'] == true ||
            username == 'demo_super_admin' ||
            email.contains('demo_super_admin');
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _namaCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _radiusCtrl.dispose();
    _alamatCtrl.dispose();
    _catatanCtrl.dispose();
    super.dispose();
  }

  Future<void> _getCurrentGpsLocation() async {
    setState(() => _isGettingGps = true);
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        AppUi.showSnack('Layanan GPS perangkat belum aktif.');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          AppUi.showSnack('Izin lokasi ditolak.');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        AppUi.showSnack('Izin lokasi ditolak secara permanen di pengaturan.');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      _latCtrl.text = position.latitude.toStringAsFixed(6);
      _lngCtrl.text = position.longitude.toStringAsFixed(6);

      AppUi.showSnack(
          'Lokasi GPS berhasil diambil: ${_latCtrl.text}, ${_lngCtrl.text}');
    } catch (e) {
      AppUi.showSnack('Gagal mengambil lokasi GPS: $e');
    } finally {
      if (mounted) setState(() => _isGettingGps = false);
    }
  }

  Future<void> _openGoogleMaps() async {
    final lat = _latCtrl.text.trim();
    final lng = _lngCtrl.text.trim();

    if (lat.isEmpty || lng.isEmpty) {
      AppUi.showSnack('Isi latitude dan longitude terlebih dahulu.');
      return;
    }

    final urlString = 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';
    final uri = Uri.parse(urlString);

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        AppUi.showSnack('Tidak dapat membuka Google Maps.');
      }
    } catch (e) {
      AppUi.showSnack('Gagal membuka peta: $e');
    }
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Wajib diisi' : null;

  double? _parseDouble(String v) =>
      double.tryParse(v.trim().replaceAll(',', '.'));

  String? _nullable(TextEditingController ctrl) {
    final v = ctrl.text.trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    final lat = _parseDouble(_latCtrl.text);
    final lng = _parseDouble(_lngCtrl.text);
    final radius = _parseDouble(_radiusCtrl.text);
    if (lat == null || lng == null || radius == null) {
      AppUi.showSnack('Latitude, longitude, dan radius harus angka.');
      return;
    }
    if (radius <= 0) {
      AppUi.showSnack('Radius harus lebih dari 0 meter.');
      return;
    }
    setState(() => _isSaving = true);
    var success = false;
    try {
      await _repository.upsertWorkLocation(
        locationId: widget.location?.locationId,
        namaLokasi: _namaCtrl.text.trim(),
        latitude: lat,
        longitude: lng,
        radiusMeter: radius,
        alamat: _nullable(_alamatCtrl),
        catatan: _nullable(_catatanCtrl),
        status: _status,
      );
      if (!mounted) return;
      success = true;
      Navigator.of(context).pop(true);
    } on PostgrestException catch (e) {
      AppUi.showSnack('Gagal simpan: ${e.message}');
    } catch (_) {
      AppUi.showSnack('Gagal simpan lokasi. Coba lagi.');
    } finally {
      if (!success && mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebResponsiveScaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Lokasi Kerja' : 'Tambah Lokasi Kerja'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            NiceCard(
              borderColor:
                  Theme.of(context).colorScheme.primary.withOpacity(0.2),
              child: Text(
                'Isi titik lokasi kerja untuk validasi absensi. Anda bisa menekan tombol GPS untuk mengisi koordinat secara otomatis atau membukanya di peta.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppUi.mutedText(context, 0.92),
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 12),
            NiceCard(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _namaCtrl,
                      validator: _required,
                      decoration: const InputDecoration(
                        labelText: 'Nama Lokasi',
                        hintText: 'Contoh: Gudang Utama',
                      ),
                    ),
                    const SizedBox(height: 12),

                    // GPS Capture & Maps Buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed:
                                _isGettingGps ? null : _getCurrentGpsLocation,
                            icon: _isGettingGps
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.my_location_rounded, size: 18),
                            label: Text(
                                _isGettingGps ? 'Mengambil…' : 'Ambil GPS'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: _openGoogleMaps,
                          icon: const Icon(Icons.map_outlined, size: 18),
                          label: const Text('Lihat Map'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _latCtrl,
                            validator: _required,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Latitude',
                              hintText: '-6.200000',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(
                            controller: _lngCtrl,
                            validator: _required,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Longitude',
                              hintText: '106.816666',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: _radiusCtrl,
                      validator: _required,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Radius Validasi (Meter)',
                        hintText: 'Contoh: 100',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _alamatCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Alamat'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _catatanCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Catatan'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _status,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: const [
                        DropdownMenuItem(value: 'active', child: Text('Aktif')),
                        DropdownMenuItem(
                            value: 'inactive', child: Text('Nonaktif')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _status = v);
                      },
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed:
                          (_isSaving || _isDemoSuperAdmin) ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save_rounded),
                      label: Text(_isSaving ? 'Menyimpan…' : 'Simpan Lokasi'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
