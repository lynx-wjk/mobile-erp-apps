import 'package:flutter/material.dart';
import '../../../core/ui/app_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
        title: Text('Lokasi & Jam Kerja'),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: 'Lokasi Kerja'),
            Tab(text: 'Jam Kerja per User'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [
          _LocationTab(),
          _WorkScheduleTab(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1 — Lokasi Kerja (existing logic, unchanged)
// ─────────────────────────────────────────────────────────────────────────────
class _LocationTab extends StatefulWidget {
  const _LocationTab();

  @override
  State<_LocationTab> createState() => _LocationTabState();
}

class _LocationTabState extends State<_LocationTab> {
  final _repository   = MasterDataRepository();
  final _searchCtrl   = TextEditingController();

  bool _isLoading       = true;
  bool _isSuperAdmin    = false;
  bool _isDemoSuperAdmin = false;
  bool get _canManage   => _isSuperAdmin && !_isDemoSuperAdmin;
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
    setState(() { _isLoading = true; _error = null; });
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) {
        final profile = await Supabase.instance.client
            .from('users')
            .select('role_id, is_demo_account, username, email')
            .eq('user_id', uid)
            .maybeSingle();
        final role     = profile?['role_id']?.toString().toLowerCase().trim() ?? '';
        final username = profile?['username']?.toString().toLowerCase().trim() ?? '';
        final email    = profile?['email']?.toString().toLowerCase().trim() ?? '';
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
    return _locations.where((loc) =>
      loc.namaLokasi.toLowerCase().contains(kw) ||
      (loc.alamat ?? '').toLowerCase().contains(kw),
    ).toList();
  }

  Future<void> _delete(WorkLocation loc) async {
    if (!_isSuperAdmin) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: Text('Hapus lokasi kerja?'),
        content: Text('Lokasi "${loc.namaLokasi}" akan dihapus permanen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Batal')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: Icon(Icons.delete_outline),
            label: Text('Hapus'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client.rpc('delete_record_for_super_admin', params: {
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
      MaterialPageRoute(builder: (_) => WorkLocationFormPage(location: location)),
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
    if (_isLoading) return const Center(child: FuturisticLoader(message: 'Memuat lokasi…'));
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }
    final locs = _filtered;
    if (locs.isEmpty) {
      return EmptyState(
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
                        color: (loc.isActive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error).withOpacity(0.12),
                      ),
                      child: Icon(
                        loc.isActive ? Icons.location_on_rounded : Icons.location_off_rounded,
                        color: loc.isActive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(loc.namaLokasi, style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface)),
                          const SizedBox(height: 2),
                          Text(
                            'Radius ${loc.radiusMeter.toStringAsFixed(0)} m  ·  ${loc.status}',
                            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
                          ),
                          if ((loc.alamat ?? '').isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              loc.alamat!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_canManage)
                      IconButton(
                        onPressed: () => _delete(loc),
                        icon: Icon(Icons.delete_outline_rounded, size: 20),
                        color: Theme.of(context).colorScheme.error.withOpacity(0.7),
                        tooltip: 'Hapus lokasi',
                      ),
                    Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 18),
                  ],
                ),
              );
            },
          ),
        ),
        if (_canManage)
          Positioned(
            right: 16, bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: Icon(Icons.add_location_alt_rounded),
              label: Text('Tambah Lokasi'),
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

  bool _loadingUsers   = true;
  bool _loadingSched   = false;
  bool _saving         = false;
  String? _error;

  List<Map<String, dynamic>> _users   = [];
  String? _selectedUserId;
  String  _selectedUserName = '';

  // day_of_week: 0=Minggu, 1=Senin, ..., 6=Sabtu
  final Map<int, _DaySchedule> _schedule = {};

  static const _dayNames = ['Minggu', 'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu'];

  @override
  void initState() {
    super.initState();
    _initScheduleDefaults();
    _loadUsers();
  }

  void _initScheduleDefaults() {
    for (int d = 0; d < 7; d++) {
      _schedule[d] = _DaySchedule(
        dayOfWeek: d,
        isActive: d >= 1 && d <= 5, // Mon–Fri default active
        startTime: const TimeOfDay(hour: 8, minute: 0),
        endTime:   const TimeOfDay(hour: 17, minute: 0),
        lateTolerance: 15,
      );
    }
  }

  Future<void> _loadUsers() async {
    if (!mounted) return;
    setState(() { _loadingUsers = true; _error = null; });
    try {
      final data = await _client
          .from('users')
          .select('user_id, nama, role_id, status, email')
          .neq('status', 'deleted')
          .order('nama');
      if (!mounted) return;
      final users = (data as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      setState(() => _users = users);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memuat daftar user. Coba refresh.');
    } finally {
      if (mounted) setState(() => _loadingUsers = false);
    }
  }

  Future<void> _loadSchedule(String userId) async {
    if (!mounted) return;
    setState(() { _loadingSched = true; _error = null; });
    try {
      final res = await _client.rpc(
        'user_work_schedule_list_v24_6_28',
        params: {'p_user_id': userId},
      );
      if (!mounted) return;
      final map  = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final rows = (map['rows'] as List? ?? [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();

      // Reset defaults first
      _initScheduleDefaults();

      // Apply loaded rows
      for (final row in rows) {
        final day = _asInt(row['day_of_week']);
        if (day < 0 || day > 6) continue;
        _schedule[day] = _DaySchedule(
          dayOfWeek: day,
          isActive:  row['is_active'] == true,
          startTime: _parseTime(row['start_time']?.toString() ?? '08:00'),
          endTime:   _parseTime(row['end_time']?.toString() ?? '17:00'),
          lateTolerance: _asInt(row['late_tolerance_minutes'], defaultVal: 15),
        );
      }
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memuat jadwal. Coba refresh.');
    } finally {
      if (mounted) setState(() => _loadingSched = false);
    }
  }

  Future<void> _save() async {
    if (_selectedUserId == null) {
      AppUi.showSnack('Pilih user terlebih dahulu.');
      return;
    }
    setState(() => _saving = true);
    try {
      final rows = _schedule.values.map((s) => {
        'user_id':               _selectedUserId,
        'day_of_week':           s.dayOfWeek,
        'start_time':            _formatTime(s.startTime),
        'end_time':              _formatTime(s.endTime),
        'late_tolerance_minutes': s.lateTolerance,
        'timezone':              'Asia/Jakarta',
        'is_active':             s.isActive,
      }).toList();

      await _client.rpc(
        'user_work_schedule_upsert_bulk_v24_6_28',
        params: {'p_rows': rows},
      );

      if (!mounted) return;
      AppUi.showSnack('Jadwal kerja $_selectedUserName berhasil disimpan.');
    } catch (_) {
      if (!mounted) return;
      AppUi.showSnack('Gagal menyimpan jadwal. Coba lagi.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _bulkApply(List<int> days) {
    // Apply Mon schedule to selected days
    final monSched = _schedule[1]!;
    for (final d in days) {
      _schedule[d] = _schedule[d]!.copyWith(
        startTime: monSched.startTime,
        endTime: monSched.endTime,
        lateTolerance: monSched.lateTolerance,
        isActive: true,
      );
    }
    // Deactivate days not in the list (except Mon which is always in list)
    for (int d = 0; d <= 6; d++) {
      if (!days.contains(d)) {
        _schedule[d] = _schedule[d]!.copyWith(isActive: false);
      }
    }
    setState(() {});
    AppUi.showSnack('Jadwal diaplikasikan ke ${days.map((d) => _dayNames[d]).join(", ")}.');
  }

  Future<void> _pickTime(int day, bool isStart) async {
    final current = isStart ? _schedule[day]!.startTime : _schedule[day]!.endTime;
    final picked  = await showTimePicker(context: context, initialTime: current);
    if (!mounted || picked == null) return;
    setState(() {
      if (isStart) {
        _schedule[day] = _schedule[day]!.copyWith(startTime: picked);
      } else {
        _schedule[day] = _schedule[day]!.copyWith(endTime: picked);
      }
    });
  }

  static TimeOfDay _parseTime(String raw) {
    final parts = raw.split(':');
    if (parts.length < 2) return const TimeOfDay(hour: 8, minute: 0);
    return TimeOfDay(
      hour:   int.tryParse(parts[0]) ?? 8,
      minute: int.tryParse(parts[1]) ?? 0,
    );
  }

  static String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}';

  static int _asInt(dynamic v, {int defaultVal = 0}) =>
      int.tryParse(v?.toString() ?? '') ?? defaultVal;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _loadUsers,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
        children: [
          // Info banner
          NiceCard(
            borderColor: Theme.of(context).colorScheme.primary.withOpacity(0.25),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
                  ),
                  child: Icon(Icons.info_outline_rounded, color: Theme.of(context).colorScheme.primary, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Pengaturan ini menentukan jam kerja per user yang dipakai sistem absensi ke depan. Timezone default Asia/Jakarta (WIB).',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // User picker
          if (_loadingUsers)
            const Center(child: FuturisticLoader(message: 'Memuat user…'))
          else if (_error != null && _users.isEmpty)
            ErrorState(message: _error!, onRetry: _loadUsers)
          else ...[
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pilih User',
                    style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.outline, fontSize: 12, letterSpacing: 0.4),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedUserId,
                      isExpanded: true,
                      hint: Text('Pilih user untuk edit jadwal…', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
                      dropdownColor: Theme.of(context).cardColor,
                      iconEnabledColor: Theme.of(context).colorScheme.outline,
                      items: _users.map((user) {
                        final uid   = user['user_id']?.toString() ?? '';
                        final nama  = user['nama']?.toString() ?? user['email']?.toString() ?? uid;
                        final role  = user['role_id']?.toString() ?? '-';
                        return DropdownMenuItem<String>(
                          value: uid,
                          child: Text('$nama  ($role)', overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
                        );
                      }).toList(),
                      onChanged: (uid) {
                        if (uid == null) return;
                        final user = _users.firstWhere((u) => u['user_id']?.toString() == uid, orElse: () => {});
                        setState(() {
                          _selectedUserId   = uid;
                          _selectedUserName = user['nama']?.toString() ?? uid;
                        });
                        _loadSchedule(uid);
                      },
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            if (_selectedUserId != null) ...[
              // Bulk apply buttons
              NiceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Terapkan cepat', style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.outline, fontSize: 12)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8, runSpacing: 8,
                      children: [
                        _bulkBtn('Senin–Jumat', () => _bulkApply([1, 2, 3, 4, 5])),
                        _bulkBtn('Senin–Sabtu',  () => _bulkApply([1, 2, 3, 4, 5, 6])),
                        _bulkBtn('Senin–Minggu', () => _bulkApply([0, 1, 2, 3, 4, 5, 6])),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Schedule per day
              if (_loadingSched)
                const Center(child: FuturisticLoader(message: 'Memuat jadwal…'))
              else ...[
                const SectionTitle(title: 'Jadwal per Hari'),
                const SizedBox(height: 8),
                ...List.generate(7, (day) => _dayCard(day)),
                const SizedBox(height: 16),

                // Save button
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : Icon(Icons.save_rounded),
                  label: Text(_saving ? 'Menyimpan…' : 'Simpan Jadwal $_selectedUserName'),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Widget _bulkBtn(String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: TextStyle(fontSize: 12)),
    );
  }

  Widget _dayCard(int day) {
    final sched  = _schedule[day]!;
    final active = sched.isActive;
    final color  = active ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: NiceCard(
        borderColor: active ? Theme.of(context).colorScheme.primary.withOpacity(0.25) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Expanded(
                  child: Text(
                    _dayNames[day],
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: active ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.outline,
                      fontSize: 14,
                    ),
                  ),
                ),
                Switch(
                  value: active,
                  activeColor: Theme.of(context).colorScheme.primary,
                  onChanged: (v) => setState(() => _schedule[day] = sched.copyWith(isActive: v)),
                ),
              ],
            ),
            if (active) ...[
              const Divider(height: 12),
              Row(
                children: [
                  Expanded(child: _timeButton('Mulai', sched.startTime, color, () => _pickTime(day, true))),
                  const SizedBox(width: 8),
                  Expanded(child: _timeButton('Selesai', sched.endTime, color, () => _pickTime(day, false))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Toleransi telat:', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
                  const Spacer(),
                  IconButton(
                    onPressed: sched.lateTolerance <= 0 ? null : () => setState(() => _schedule[day] = sched.copyWith(lateTolerance: sched.lateTolerance - 5)),
                    icon: Icon(Icons.remove_circle_outline, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('${sched.lateTolerance} menit', style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface, fontSize: 13)),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _schedule[day] = sched.copyWith(lateTolerance: sched.lateTolerance + 5)),
                    icon: Icon(Icons.add_circle_outline, size: 20),
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
  }

  Widget _timeButton(String label, TimeOfDay time, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: color.withOpacity(0.08),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 10, color: color.withOpacity(0.8), fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              _formatTime(time),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Day schedule model
// ─────────────────────────────────────────────────────────────────────────────
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

  _DaySchedule copyWith({bool? isActive, TimeOfDay? startTime, TimeOfDay? endTime, int? lateTolerance}) {
    return _DaySchedule(
      dayOfWeek: dayOfWeek,
      isActive:  isActive  ?? this.isActive,
      startTime: startTime ?? this.startTime,
      endTime:   endTime   ?? this.endTime,
      lateTolerance: lateTolerance ?? this.lateTolerance,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WorkLocationFormPage (existing, unchanged)
// ─────────────────────────────────────────────────────────────────────────────
class WorkLocationFormPage extends StatefulWidget {
  final WorkLocation? location;

  const WorkLocationFormPage({super.key, this.location});

  @override
  State<WorkLocationFormPage> createState() => _WorkLocationFormPageState();
}

class _WorkLocationFormPageState extends State<WorkLocationFormPage> {
  final _formKey    = GlobalKey<FormState>();
  final _repository = MasterDataRepository();

  final _namaCtrl      = TextEditingController();
  final _latCtrl       = TextEditingController();
  final _lngCtrl       = TextEditingController();
  final _radiusCtrl    = TextEditingController(text: '100');
  final _alamatCtrl    = TextEditingController();
  final _catatanCtrl   = TextEditingController();

  bool _isSaving         = false;
  bool _isDemoSuperAdmin = false;
  String _status         = 'active';

  bool get _isEdit => widget.location != null;

  @override
  void initState() {
    super.initState();
    _loadDemoRole();
    final loc = widget.location;
    if (loc != null) {
      _namaCtrl.text    = loc.namaLokasi;
      _latCtrl.text     = loc.latitude.toString();
      _lngCtrl.text     = loc.longitude.toString();
      _radiusCtrl.text  = loc.radiusMeter.toString();
      _alamatCtrl.text  = loc.alamat ?? '';
      _catatanCtrl.text = loc.catatan ?? '';
      _status           = loc.status == 'inactive' ? 'inactive' : 'active';
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
      final role     = profile?['role_id']?.toString().toLowerCase().trim() ?? '';
      final username = profile?['username']?.toString().toLowerCase().trim() ?? '';
      final email    = profile?['email']?.toString().toLowerCase().trim() ?? '';
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
    _namaCtrl.dispose(); _latCtrl.dispose(); _lngCtrl.dispose();
    _radiusCtrl.dispose(); _alamatCtrl.dispose(); _catatanCtrl.dispose();
    super.dispose();
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Wajib diisi' : null;

  double? _parseDouble(String v) => double.tryParse(v.trim().replaceAll(',', '.'));

  String? _nullable(TextEditingController ctrl) {
    final v = ctrl.text.trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    final lat    = _parseDouble(_latCtrl.text);
    final lng    = _parseDouble(_lngCtrl.text);
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
        locationId:   widget.location?.locationId,
        namaLokasi:   _namaCtrl.text.trim(),
        latitude:     lat,
        longitude:    lng,
        radiusMeter:  radius,
        alamat:       _nullable(_alamatCtrl),
        catatan:      _nullable(_catatanCtrl),
        status:       _status,
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
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Lokasi Kerja' : 'Tambah Lokasi Kerja')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            NiceCard(
              borderColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
              child: Text(
                'Isi latitude, longitude, dan radius untuk validasi absensi GPS. Koordinat bisa diambil dari Google Maps.',
                style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.outline, height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            NiceCard(
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(controller: _namaCtrl, validator: _required,
                      decoration: const InputDecoration(labelText: 'Nama Lokasi', hintText: 'Contoh: Gudang Utama')),
                    const SizedBox(height: 12),
                    TextFormField(controller: _latCtrl, validator: _required,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(labelText: 'Latitude', hintText: 'Contoh: -6.200000')),
                    const SizedBox(height: 12),
                    TextFormField(controller: _lngCtrl, validator: _required,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(labelText: 'Longitude', hintText: 'Contoh: 106.816666')),
                    const SizedBox(height: 12),
                    TextFormField(controller: _radiusCtrl, validator: _required,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Radius Meter', hintText: 'Contoh: 100')),
                    const SizedBox(height: 12),
                    TextFormField(controller: _alamatCtrl, maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Alamat')),
                    const SizedBox(height: 12),
                    TextFormField(controller: _catatanCtrl, maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Catatan')),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _status,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: const [
                        DropdownMenuItem(value: 'active',   child: Text('Aktif')),
                        DropdownMenuItem(value: 'inactive', child: Text('Nonaktif')),
                      ],
                      onChanged: (v) { if (v != null) setState(() => _status = v); },
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: (_isSaving || _isDemoSuperAdmin) ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.save_rounded),
                      label: Text(_isSaving ? 'Menyimpan…' : 'Simpan'),
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
