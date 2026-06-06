// ignore_for_file: unused_element, unnecessary_non_null_assertion, unused_local_variable
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../../models/app_user.dart';

class AbsensiPage extends StatefulWidget {
  final AppUser? currentUser;

  const AbsensiPage({
    super.key,
    this.currentUser,
  });

  @override
  State<AbsensiPage> createState() => _AbsensiPageState();
}

class _AbsensiPageState extends State<AbsensiPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _noteController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;
  Map<String, dynamic>? _todayAbsensi;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _locations = [];
  Map<String, dynamic>? _profile;
  _TodayWorkSchedule? _todaySchedule;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  bool get _canSeeAll {
    final role = AppUi.text(_profile?['role_id']).toLowerCase();
    return role == 'super_admin' || role == 'superadmin' || role == 'owner' || role == 'admin' || role == 'hr';
  }

  bool get _isSuperAdmin => AppUi.text(_profile?['role_id']).toLowerCase() == 'super_admin';

  Future<Map<String, dynamic>?> _currentProfile() async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) return null;

    final user = await _client
        .from('users')
        .select('user_id, nama, email, role_id')
        .eq('user_id', authUser.id)
        .maybeSingle();

    return user == null ? null : Map<String, dynamic>.from(user);
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final profile = await _currentProfile();
      final userId = profile?['user_id']?.toString();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final canSeeAll = ['super_admin', 'superadmin', 'owner', 'admin', 'hr']
          .contains(AppUi.text(profile?['role_id']).toLowerCase());
      final schedule = userId == null || userId.isEmpty
          ? null
          : await _loadTodaySchedule(userId);

      final locationsResponse = await _client
          .from('work_locations')
          .select('location_id, nama_lokasi, latitude, longitude, radius_meter, status')
          .eq('status', 'active')
          .order('created_at', ascending: false);

      dynamic attendanceResponse;
      final select = 'attendance_id, user_id, user_name, user_email, role_id, date, check_in_time, check_in_lat, check_in_lng, check_in_distance_meter, check_out_time, check_out_lat, check_out_lng, check_out_distance_meter, status, note, created_at';
      if (canSeeAll) {
        attendanceResponse = await _client
            .from('attendance')
            .select(select)
            .order('date', ascending: false)
            .order('created_at', ascending: false)
            .limit(160);
      } else {
        attendanceResponse = await _client
            .from('attendance')
            .select(select)
            .eq('user_id', userId ?? '')
            .order('date', ascending: false)
            .order('created_at', ascending: false)
            .limit(90);
      }

      final items = (attendanceResponse as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final locations = (locationsResponse as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      Map<String, dynamic>? todayItem;
      for (final item in items) {
        final sameUser = item['user_id']?.toString() == userId;
        final sameDate = item['date']?.toString() == today;
        final isStillOpen = item['check_in_time'] != null && item['check_out_time'] == null;
        if (sameUser && sameDate && isStillOpen) {
          todayItem = item;
          break;
        }
      }

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _items = items;
        _locations = locations;
        _todayAbsensi = todayItem;
        _todaySchedule = schedule;
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<_TodayWorkSchedule?> _loadTodaySchedule(String userId) async {
    try {
      final response = await _client.rpc(
        'attendance_today_schedule',
        params: {'p_user_id': userId},
      );
      if (response == null || response is! Map) return null;
      return _TodayWorkSchedule.fromMap(Map<String, dynamic>.from(response));
    } catch (_) {
      return null;
    }
  }

  Future<Position> _position() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) throw Exception('GPS belum aktif');

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw Exception('Izin lokasi ditolak');
    }

    return Geolocator.getCurrentPosition();
  }

  _LocationCheck _checkLocation(Position position) {
    if (_locations.isEmpty) {
      return const _LocationCheck(
        status: 'outside_area',
        distanceMeter: null,
        locationName: 'Belum ada work location aktif',
      );
    }

    Map<String, dynamic>? nearest;
    double? nearestDistance;

    for (final loc in _locations) {
      final lat = AppUi.toNum(loc['latitude']).toDouble();
      final lng = AppUi.toNum(loc['longitude']).toDouble();
      final distance = Geolocator.distanceBetween(position.latitude, position.longitude, lat, lng);

      if (nearestDistance == null || distance < nearestDistance) {
        nearest = loc;
        nearestDistance = distance;
      }
    }

    final radius = AppUi.toNum(nearest?['radius_meter']).toDouble();
    final valid = nearestDistance != null && nearestDistance! <= radius;

    return _LocationCheck(
      status: valid ? 'valid' : 'outside_area',
      distanceMeter: nearestDistance,
      locationName: AppUi.text(nearest?['nama_lokasi'], '-'),
    );
  }

  Future<void> _insertLog({
    required Map<String, dynamic>? profile,
    required String type,
    required Position position,
    required String note,
  }) async {
    try {
      await _client.from('attendance_logs').insert({
        'user_id': profile?['user_id'],
        'nama_user': profile?['nama'],
        'email_user': profile?['email'],
        'role_id': profile?['role_id'],
        'attendance_type': type,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'catatan': note,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // Log tambahan tidak boleh menggagalkan absensi utama.
    }
  }

  Future<void> _checkIn() async {
    setState(() => _isSaving = true);

    try {
      final profile = await _currentProfile();
      final position = await _position();
      final location = _checkLocation(position);
      final now = DateTime.now().toIso8601String();
      final note = _noteController.text.trim();
      final schedule = profile?['user_id'] == null
          ? null
          : await _loadTodaySchedule(profile!['user_id'].toString());

      if (location.status != 'valid') {
        final distance = location.distanceMeter == null
            ? '-'
            : location.distanceMeter!.toStringAsFixed(0);
        throw Exception('Di luar area ${location.locationName} ($distance meter). Check in ditolak.');
      }

      final status = schedule != null && schedule.isWorkday && schedule.isLate
          ? 'late'
          : 'valid';
      final scheduleNote = schedule == null
          ? 'Jadwal kerja belum diset'
          : schedule.isWorkday
              ? (schedule.isLate
                  ? 'Telat ${schedule.lateMinutes} menit dari jadwal ${schedule.startLabel}'
                  : 'Tepat waktu, jadwal ${schedule.startLabel}')
              : 'Tidak ada jadwal aktif hari ini';
      final finalNote = [
        if (note.isNotEmpty) note,
        'Lokasi: ${location.locationName}',
        scheduleNote,
      ].join(' | ');

      await _client.from('attendance').insert({
        'user_id': profile?['user_id'],
        'user_name': profile?['nama'],
        'user_email': profile?['email'],
        'role_id': profile?['role_id'],
        'date': now.substring(0, 10),
        'check_in_time': now,
        'check_in_lat': position.latitude,
        'check_in_lng': position.longitude,
        'check_in_distance_meter': location.distanceMeter,
        'status': status,
        'note': finalNote,
        'created_at': now,
        'updated_at': now,
      });

      await _insertLog(profile: profile, type: 'CHECK_IN', position: position, note: finalNote);

      if (!mounted) return;
      _noteController.clear();
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Check-in berhasil (${location.status})')),
      );
      _loadData();
    } catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text('Check in gagal: $error')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }


  Future<void> _deleteAbsensi(Map<String, dynamic> attendance) async {
    if (!_isSuperAdmin) return;

    final id = attendance['attendance_id']?.toString();
    if (id == null || id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Hapus data attendance?'),
        content: Text("Data attendance ${AppUi.text(attendance['user_name'] ?? attendance['nama_user'])} tanggal ${AppUi.date(attendance['date'])} akan dihapus."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text('Batal')),
          FilledButton.icon(onPressed: () => Navigator.pop(dialogContext, true), icon: Icon(Icons.delete_outline), label: Text('Hapus')),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.rpc('delete_record_for_super_admin', params: {
        'p_table_name': 'attendance',
        'p_record_id': id,
      });
      AppUi.showSnack('Data absensi berhasil dihapus.');
      await _loadData();
    } catch (error) {
      AppUi.showSnack('Gagal hapus attendance: $error');
    }
  }

  Future<void> _checkOut() async {
    final today = _todayAbsensi;
    if (today == null) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Check in dulu sebelum check out')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final profile = await _currentProfile();
      final position = await _position();
      final location = _checkLocation(position);
      final note = _noteController.text.trim();

      if (location.status != 'valid') {
        final distance = location.distanceMeter == null
            ? '-'
            : location.distanceMeter!.toStringAsFixed(0);
        throw Exception('Di luar area ${location.locationName} ($distance meter). Check out ditolak.');
      }

      await _client
          .from('attendance')
          .update({
            'check_out_time': DateTime.now().toIso8601String(),
            'check_out_lat': position.latitude,
            'check_out_lng': position.longitude,
            'check_out_distance_meter': location.distanceMeter,
            'status': location.status == 'valid'
                ? (AppUi.text(today['status']) == 'late' ? 'late' : 'valid')
                : 'outside_area',
            'note': note.isEmpty
                ? today['note']
                : '$note | Lokasi checkout: ${location.locationName}',
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('attendance_id', today['attendance_id']);

      await _insertLog(profile: profile, type: 'CHECK_OUT', position: position, note: note);

      if (!mounted) return;
      _noteController.clear();
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Check-out berhasil (${location.status})')),
      );
      _loadData();
    } catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text('Check out gagal: $error')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildScheduleCard() {
    final schedule = _todaySchedule;
    final title = schedule == null
        ? 'Jadwal kerja belum diset'
        : schedule.isWorkday
            ? 'Jadwal hari ini ${schedule.startLabel} - ${schedule.endLabel}'
            : 'Tidak ada jadwal aktif hari ini';
    final subtitle = schedule == null
        ? 'Isi jam kerja di Set Lokasi agar check-in bisa otomatis menandai tepat waktu atau telat.'
        : schedule.isWorkday
            ? '${schedule.isLate ? 'Indikasi sekarang: telat ${schedule.lateMinutes} menit' : 'Indikasi sekarang: tepat waktu'} • toleransi ${schedule.toleranceMinutes} menit'
            : 'Check-in tetap boleh dilakukan, tetapi tidak ditandai telat.';
    final color = schedule != null && schedule.isLate ? AppUi.orange : AppUi.teal;

    return NiceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withOpacity(0.14),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              schedule != null && schedule.isLate
                  ? Icons.access_time_filled
                  : Icons.schedule_outlined,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurface)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 12.5, height: 1.35, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.85))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();
    if (_errorMessage != null) return ErrorState(message: _errorMessage!, onRetry: _loadData);

    final hasOpenSession = _todayAbsensi?['check_in_time'] != null && _todayAbsensi?['check_out_time'] == null;
    final checkedIn = hasOpenSession;
    final checkedOut = _todayAbsensi?['check_out_time'] != null;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          FuturisticHeader(
            icon: Icons.location_on_outlined,
            title: 'Absensi',
            subtitle: 'Check-in dan check-out memakai GPS dengan validasi radius lokasi kerja.',
            stats: [
              StatPill(label: 'Sesi Aktif', value: hasOpenSession ? 'Masuk' : 'Tidak Ada'),
              StatPill(label: 'Check Out', value: checkedOut ? 'Done' : '-'),
              StatPill(label: 'Lokasi Aktif', value: _locations.length.toString()),
              StatPill(label: 'Jadwal', value: _todaySchedule == null ? '-' : (_todaySchedule!.isWorkday ? _todaySchedule!.startLabel : 'Libur')),
            ],
          ),
          const SizedBox(height: 16),
          _buildScheduleCard(),
          const SizedBox(height: 14),
          NiceCard(
            child: Column(
              children: [
                TextField(
                  controller: _noteController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Catatan',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isSaving || hasOpenSession ? null : _checkIn,
                        icon: Icon(Icons.login),
                        label: Text('Check In'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSaving || !hasOpenSession ? null : _checkOut,
                        icon: Icon(Icons.logout),
                        label: Text('Check Out'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_items.isEmpty)
            const EmptyState(
              title: 'Riwayat absensi kosong',
              subtitle: 'Data check in/out akan tampil di sini.',
            )
          else
            ..._items.map((item) {
              final status = AppUi.text(item['status'], '-');
              final color = AppUi.statusColor(status);

              return NiceCard(
                padding: EdgeInsets.zero,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: CircleAvatar(
                    backgroundColor: color.withOpacity(0.14),
                    child: Icon(Icons.location_on_outlined, color: color),
                  ),
                  title: Text(
                    AppUi.text(item['user_name']),
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${AppUi.text(item['user_email'])} • ${AppUi.text(item['role_id'])}\n'
                    'Tanggal: ${AppUi.date(item['date'])} • Status: $status\n'
                    'IN: ${AppUi.dateTime(item['check_in_time'])} (${AppUi.toNum(item['check_in_distance_meter']).toStringAsFixed(0)}m)\n'
                    'OUT: ${AppUi.dateTime(item['check_out_time'])} (${AppUi.toNum(item['check_out_distance_meter']).toStringAsFixed(0)}m)',
                  ),
                  trailing: _isSuperAdmin
                      ? IconButton(
                          tooltip: 'Hapus attendance',
                          onPressed: () => _deleteAbsensi(item),
                          icon: Icon(Icons.delete_outline, color: AppUi.red),
                        )
                      : null,
                  isThreeLine: true,
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
      appBar: AppBar(
        title: Text('Absensi'),
        actions: [IconButton(onPressed: _loadData, icon: Icon(Icons.refresh))],
      ),
      body: _body(),
    );
  }
}

class _LocationCheck {
  final String status;
  final double? distanceMeter;
  final String locationName;

  const _LocationCheck({
    required this.status,
    required this.distanceMeter,
    required this.locationName,
  });
}

class _TodayWorkSchedule {
  final bool isWorkday;
  final bool isLate;
  final int lateMinutes;
  final int toleranceMinutes;
  final String startLabel;
  final String endLabel;

  const _TodayWorkSchedule({
    required this.isWorkday,
    required this.isLate,
    required this.lateMinutes,
    required this.toleranceMinutes,
    required this.startLabel,
    required this.endLabel,
  });

  factory _TodayWorkSchedule.fromMap(Map<String, dynamic> map) {
    return _TodayWorkSchedule(
      isWorkday: map['is_workday'] == true,
      isLate: map['is_late'] == true,
      lateMinutes: _toInt(map['late_minutes']),
      toleranceMinutes: _toInt(map['tolerance_minutes']),
      startLabel: _formatTime(map['start_time']),
      endLabel: _formatTime(map['end_time']),
    );
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse('$value') ?? 0;
  }

  static String _formatTime(dynamic value) {
    final text = AppUi.text(value);
    if (text.length >= 5) return text.substring(0, 5);
    return text.isEmpty ? '-' : text;
  }
}
