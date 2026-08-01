// ignore_for_file: unused_element, unnecessary_non_null_assertion, unused_local_variable
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
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
    return role == 'super_admin' ||
        role == 'superadmin' ||
        role == 'owner' ||
        role == 'admin' ||
        role == 'hr';
  }

  bool get _isAuthorizedOverrideRole {
    final role = AppUi.text(_profile?['role_id']).toLowerCase();
    return role.contains('super_admin') ||
        role.contains('finance') ||
        role.contains('hr') ||
        role.contains('admin');
  }

  bool get _isSuperAdmin =>
      AppUi.text(_profile?['role_id']).toLowerCase() == 'super_admin';

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
          .select(
              'location_id, nama_lokasi, latitude, longitude, radius_meter, status')
          .eq('status', 'active')
          .order('created_at', ascending: false);

      dynamic attendanceResponse;
      final select =
          'attendance_id, user_id, user_name, user_email, role_id, date, check_in_time, check_in_lat, check_in_lng, check_in_distance_meter, check_out_time, check_out_lat, check_out_lng, check_out_distance_meter, status, note, created_at';
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
        final isStillOpen =
            item['check_in_time'] != null && item['check_out_time'] == null;
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
      Map<String, dynamic>? data = response == null || response is! Map
          ? null
          : Map<String, dynamic>.from(response);

      final nowWib = DateTime.now().toUtc().add(const Duration(hours: 7));
      final dateStr = DateFormat('yyyy-MM-dd').format(nowWib);
      final shiftChange = await _client
          .from('shift_change_requests')
          .select('new_start_time, new_end_time')
          .eq('user_id', userId)
          .eq('shift_date', dateStr)
          .eq('status', 'approved')
          .maybeSingle();

      if (shiftChange != null) {
        data ??= {'is_workday': true};
        data['original_start_time'] = data['start_time'];
        data['original_end_time'] = data['end_time'];
        data['start_time'] = shiftChange['new_start_time'];
        data['end_time'] = shiftChange['new_end_time'];
        data['has_shift_override'] = true;
      }

      if (data == null) return null;
      return _TodayWorkSchedule.fromMap(data);
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

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('Izin lokasi ditolak');
    }

    final pos = await Geolocator.getCurrentPosition();
    final isMocked = pos.isMocked || pos.accuracy <= 0.05 || pos.accuracy == 0.0;
    if (isMocked) {
      final profile = await _currentProfile();
      try {
        await _client.from('audit_logs').insert({
          'user_id': profile?['user_id'],
          'nama_user': profile?['nama'],
          'role_id': profile?['role_id'],
          'aktivitas': 'FAKE_LOCATION_DETECTED',
          'modul': 'attendance',
          'data_sesudah': {
            'latitude': pos.latitude,
            'longitude': pos.longitude,
            'accuracy': pos.accuracy,
            'is_mocked': pos.isMocked,
          },
        });
      } catch (_) {}
      throw Exception('Aplikasi Fake Location / Mock GPS terdeteksi (Akurasi ${pos.accuracy}m)! Absensi ditolak demi keamanan.');
    }
    return pos;
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
      final distance = Geolocator.distanceBetween(
          position.latitude, position.longitude, lat, lng);

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
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // Log tambahan tidak boleh menggagalkan absensi utama.
    }
  }

  Future<void> _checkIn() async {
    setState(() => _isSaving = true);

    try {
      final profile = await _currentProfile();
      final userId = profile?['user_id']?.toString();
      final nowUtc = DateTime.now().toUtc();
      final now = nowUtc.toIso8601String();
      final wibDateStr = DateFormat('yyyy-MM-dd').format(nowUtc.add(const Duration(hours: 7)));

      // 1. Check approved leave conflict
      if (userId != null && userId.isNotEmpty) {
        final leaveCheck = await _client
            .from('leave_requests')
            .select('leave_type, reason')
            .eq('user_id', userId)
            .eq('status', 'approved')
            .lte('start_date', wibDateStr)
            .gte('end_date', wibDateStr)
            .maybeSingle();

        if (leaveCheck != null) {
          final lType = (leaveCheck['leave_type'] ?? 'Izin / Sakit').toString().toUpperCase();
          final lReason = leaveCheck['reason'] ?? '-';
          throw Exception('Tidak dapat Check-In dikarenakan Anda memiliki pengajuan $lType yang telah disetujui untuk hari ini ($wibDateStr).\nAlasan: $lReason');
        }

        // 2. Check existing attendance record for today
        final existingAtt = await _client
            .from('attendance')
            .select('attendance_id, status, check_in_time')
            .eq('user_id', userId)
            .eq('date', wibDateStr)
            .maybeSingle();

        if (existingAtt != null) {
          final attStatus = (existingAtt['status'] ?? '').toString().toUpperCase();
          throw Exception('Tidak dapat Check-In dikarenakan data absensi Anda sudah tersedia untuk tanggal ini ($wibDateStr).\nStatus: $attStatus');
        }
      }

      final position = await _position();
      final location = _checkLocation(position);
      final note = _noteController.text.trim();
      final schedule = userId == null
          ? null
          : await _loadTodaySchedule(userId);

      if (location.status != 'valid') {
        final distance = location.distanceMeter == null
            ? '-'
            : location.distanceMeter!.toStringAsFixed(0);
        throw Exception(
            'Di luar area ${location.locationName} ($distance meter). Check in ditolak.');
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
        'date': wibDateStr,
        'check_in_time': now,
        'check_in_lat': position.latitude,
        'check_in_lng': position.longitude,
        'check_in_distance_meter': location.distanceMeter,
        'status': status,
        'note': finalNote,
        'created_at': now,
        'updated_at': now,
      });

      await _insertLog(
          profile: profile,
          type: 'CHECK_IN',
          position: position,
          note: finalNote);

      if (!mounted) return;
      _noteController.clear();
      AppUi.showSnack('Check-in berhasil (${location.status})');
      _loadData();
    } catch (error) {
      if (!mounted) return;
      String userMsg = error.toString().replaceAll('Exception: ', '');
      if (userMsg.contains('23505') || userMsg.contains('uq_attendance_tenant_user_date') || userMsg.contains('duplicate key')) {
        userMsg = 'Tidak dapat Check-In dikarenakan data absensi/izin Anda sudah tersedia untuk tanggal hari ini.';
      }
      AppUi.showSnack(userMsg, isError: true);
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
        title: const Text('Hapus data absensi?'),
        content: Text(
            'Data absensi ${attendance['user_name']} (${attendance['date']}) akan dihapus permanen.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppUi.red),
            child: const Text('Hapus Permanen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.rpc('delete_record_for_super_admin', params: {
        'p_table_name': 'attendance',
        'p_record_id': id,
      });

      AppUi.showSnack('Data absensi berhasil dihapus!');
      _loadData();
    } catch (error) {
      AppUi.showSnack('Gagal hapus attendance: $error', isError: true);
    }
  }

  Future<void> _approveEarlyLeave(Map<String, dynamic> item) async {
    try {
      await _client.from('attendance').update({
        'status': 'valid',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('attendance_id', item['attendance_id']);

      AppUi.showSnack('Status Pulang Awal berhasil disetujui!');
      _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menyetujui pulang awal: $e', isError: true);
    }
  }

  Future<void> _checkOut() async {
    setState(() => _isSaving = true);

    try {
      final profile = await _currentProfile();
      final today = _todayAbsensi;

      if (today == null) {
        throw Exception('Anda belum melakukan check-in hari ini.');
      }

      final position = await _position();
      final location = _checkLocation(position);
      final note = _noteController.text.trim();

      if (location.status != 'valid') {
        final distance = location.distanceMeter == null
            ? '-'
            : location.distanceMeter!.toStringAsFixed(0);
        throw Exception(
            'Di luar area ${location.locationName} ($distance meter). Check out ditolak.');
      }

      // Check Early Check-out Guard against today's work schedule end_time
      final userId = profile?['user_id']?.toString();
      final schedule = userId == null ? null : await _loadTodaySchedule(userId);
      final isAuthorized = _isAuthorizedOverrideRole;

      bool isEarly = false;
      String earlyReason = '';

      final endLabel = (schedule != null && schedule.endLabel != '-') ? schedule.endLabel : '17:00';
      final isWorkday = (schedule != null) ? schedule.isWorkday : true;

      if (isWorkday && endLabel != '-') {
        try {
          final nowWib = DateTime.now().toUtc().add(const Duration(hours: 7));
          final currentMin = nowWib.hour * 60 + nowWib.minute;
          final endParts = endLabel.split(':');
          if (endParts.length == 2) {
            final endMin = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);

            if (currentMin < endMin) {
              isEarly = true;
              final remainingMin = endMin - currentMin;

              final earlyReasonCtrl = TextEditingController();
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Row(
                    children: const [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange),
                      SizedBox(width: 8),
                      Text('Check-out Sebelum Jam Pulang'),
                    ],
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Jadwal kerja selesai pukul $endLabel (tersisa $remainingMin menit).'),
                      const SizedBox(height: 10),
                      const Text('Anda melakukan Check-out lebih awal. Wajib isi Alasan Pulang Awal untuk persetujuan HR / Admin:'),
                      const SizedBox(height: 10),
                      TextField(
                        controller: earlyReasonCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Alasan Pulang Awal',
                          hintText: 'Contoh: Sakit mendadak / Izin urusan keluarga...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kirim & Check-out')),
                  ],
                ),
              );

              if (confirmed != true) {
                setState(() => _isSaving = false);
                return;
              }

              earlyReason = earlyReasonCtrl.text.trim();
              if (earlyReason.isEmpty) {
                throw Exception('Alasan Pulang Awal wajib diisi.');
              }
            }
          }
        } catch (e) {
          if (e is Exception) rethrow;
        }
      }

      final nowUtc = DateTime.now().toUtc().toIso8601String();

      final statusStr = isEarly
          ? (isAuthorized ? 'valid' : 'early_leave_pending')
          : (location.status == 'valid'
              ? (AppUi.text(today['status']) == 'late' ? 'late' : 'valid')
              : 'outside_area');

      final finalNote = [
        if (note.isNotEmpty) note,
        if (isEarly && earlyReason.isNotEmpty) 'PULANG AWAL: $earlyReason',
        'Lokasi checkout: ${location.locationName}',
      ].join(' | ');

      await _client.from('attendance').update({
        'check_out_time': nowUtc,
        'check_out_lat': position.latitude,
        'check_out_lng': position.longitude,
        'check_out_distance_meter': location.distanceMeter,
        'status': statusStr,
        'note': finalNote,
        'updated_at': nowUtc,
      }).eq('attendance_id', today['attendance_id']);

      await _insertLog(
          profile: profile, type: 'CHECK_OUT', position: position, note: finalNote);

      if (!mounted) return;
      _noteController.clear();
      final msg = isEarly
          ? (isAuthorized
              ? 'Check-out berhasil (Disetujui otomatis sebagai Atasan)'
              : 'Check-out berhasil (Menunggu persetujuan Pulang Awal oleh HR/Admin)')
          : 'Check-out berhasil (${location.status})';
      AppUi.showSnack(msg);
      _loadData();
    } catch (error) {
      if (!mounted) return;
      String errStr = error.toString().replaceAll('Exception: ', '');
      AppUi.showSnack('Check out gagal: $errStr', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildScheduleCard() {
    final schedule = _todaySchedule;
    final title = schedule == null
        ? 'Jadwal kerja belum diset'
        : schedule.isWorkday
            ? (schedule.hasShiftOverride
                ? 'Jadwal Hari Ini: ${schedule.startLabel} - ${schedule.endLabel} (Tukar Shift)'
                : 'Jadwal Hari Ini: ${schedule.startLabel} - ${schedule.endLabel}')
            : 'Tidak ada jadwal aktif hari ini';
    final subtitle = schedule == null
        ? 'Isi jam kerja di Set Lokasi agar check-in bisa otomatis menandai tepat waktu atau telat.'
        : schedule.isWorkday
            ? (schedule.hasShiftOverride
                ? 'Jadwal Asli: ${schedule.originalStartLabel} - ${schedule.originalEndLabel} (Ditukar ke ${schedule.startLabel} - ${schedule.endLabel}) • ${schedule.isLate ? 'Indikasi: telat ${schedule.lateMinutes} m' : 'Indikasi: Tepat Waktu'}'
                : '${schedule.isLate ? 'Indikasi sekarang: telat ${schedule.lateMinutes} menit' : 'Indikasi sekarang: tepat waktu'} • toleransi ${schedule.toleranceMinutes} menit')
            : 'Check-in tetap boleh dilakukan, tetapi tidak ditandai telat.';
    final color =
        schedule != null && schedule.isLate ? AppUi.orange : AppUi.teal;

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
                Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Theme.of(context).colorScheme.onSurface)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withOpacity(0.85))),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _showShiftChangeModal,
                  icon: const Icon(Icons.published_with_changes_rounded, size: 16),
                  label: const Text('Ajukan Tukar Shift / Ubah Jam Kerja', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showShiftChangeModal() async {
    final dateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
    final startCtrl = TextEditingController(text: '12:00');
    final endCtrl = TextEditingController(text: '20:00');
    final reasonCtrl = TextEditingController();
    bool isSubmitting = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        String? modalError;
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: EdgeInsets.only(
                left: 20, right: 20, top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40, height: 4,
                        decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Pengajuan Tukar Shift / Ubah Jam Kerja', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text('Pengajuan ini akan dikirim ke Super Admin / HR / Finance. Setelah disetujui, jam kerja hari tersebut otomatis diperbarui.', style: TextStyle(fontSize: 12.5, color: Colors.grey)),
                    const SizedBox(height: 16),
                    if (modalError != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          border: Border.all(color: const Color(0xFFFCA5A5)),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                modalError!,
                                style: const TextStyle(color: Color(0xFF991B1B), fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: dateCtrl,
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: 'Tanggal Shift',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.calendar_today_rounded),
                      ),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: DateTime.tryParse(dateCtrl.text) ?? DateTime.now(),
                          firstDate: DateTime.now().subtract(const Duration(days: 30)),
                          lastDate: DateTime.now().add(const Duration(days: 90)),
                        );
                        if (picked != null) {
                          setModalState(() => dateCtrl.text = DateFormat('yyyy-MM-dd').format(picked));
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startCtrl,
                            readOnly: true,
                            decoration: const InputDecoration(
                              labelText: 'Jam Mulai Baru',
                              hintText: '12:00',
                              border: OutlineInputBorder(),
                              suffixIcon: Icon(Icons.access_time_rounded),
                            ),
                            onTap: () async {
                              final parts = startCtrl.text.split(':');
                              final initTime = parts.length == 2
                                  ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 12, minute: int.tryParse(parts[1]) ?? 0)
                                  : const TimeOfDay(hour: 12, minute: 0);
                              final picked = await showTimePicker(context: context, initialTime: initTime);
                              if (picked != null) {
                                setModalState(() {
                                  startCtrl.text = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: endCtrl,
                            readOnly: true,
                            decoration: const InputDecoration(
                              labelText: 'Jam Selesai Baru',
                              hintText: '20:00',
                              border: OutlineInputBorder(),
                              suffixIcon: Icon(Icons.access_time_rounded),
                            ),
                            onTap: () async {
                              final parts = endCtrl.text.split(':');
                              final initTime = parts.length == 2
                                  ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 20, minute: int.tryParse(parts[1]) ?? 0)
                                  : const TimeOfDay(hour: 20, minute: 0);
                              final picked = await showTimePicker(context: context, initialTime: initTime);
                              if (picked != null) {
                                setModalState(() {
                                  endCtrl.text = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                                });
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: reasonCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Alasan Tukar Shift',
                        hintText: 'Contoh: Keperluan mendesak pagi hari...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: isSubmitting ? null : () async {
                          final reason = reasonCtrl.text.trim();
                          if (reason.isEmpty) {
                            setModalState(() => modalError = 'Alasan tukar shift wajib diisi');
                            AppUi.showSnack('Alasan tukar shift wajib diisi', isError: true);
                            return;
                          }
                          setModalState(() {
                            modalError = null;
                            isSubmitting = true;
                          });
                          try {
                            final user = _client.auth.currentUser;
                            final profile = await _currentProfile();
                            final Map<String, dynamic> payload = {
                              'user_id': user!.id,
                              'user_name': profile?['nama'] ?? 'Karyawan',
                              'user_email': profile?['email'] ?? '',
                              'role_id': profile?['role_id'] ?? 'staff',
                              'shift_date': dateCtrl.text.trim(),
                              'new_start_time': startCtrl.text.trim(),
                              'new_end_time': endCtrl.text.trim(),
                              'reason': reason,
                              'status': 'pending',
                              'created_at': DateTime.now().toUtc().toIso8601String(),
                              'updated_at': DateTime.now().toUtc().toIso8601String(),
                            };
                            final rawTenant = profile?['tenant_id'] ?? _profile?['tenant_id'];
                            if (rawTenant != null && rawTenant.toString().isNotEmpty) {
                              payload['tenant_id'] = rawTenant;
                            }
                            await _client.from('shift_change_requests').insert(payload);
                            if (ctx.mounted) Navigator.pop(ctx);
                            AppUi.showSnack('Pengajuan Tukar Shift dikirim! Menunggu persetujuan HR/Admin.');
                            _loadData();
                          } catch (e) {
                            AppUi.showSnack('Gagal mengirim pengajuan tukar shift: $e', isError: true);
                          } finally {
                            setModalState(() => isSubmitting = false);
                          }
                        },
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
                        icon: isSubmitting
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.send_rounded),
                        label: Text(isSubmitting ? 'Mengirim...' : 'Kirim Pengajuan Tukar Shift'),
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

  Future<void> _showReportBugModal() async {
    final dateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
    final descController = TextEditingController();
    String issueType = 'Aplikasi Error / Crash';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Container(
            padding: EdgeInsets.only(
              left: 20, right: 20, top: 20,
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.grey.withOpacity(0.4), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Laporkan Kendala Absensi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                const Text('Kirim laporan jika HP / GPS / Aplikasi mengalami kendala absensi.', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 16),
                TextField(
                  controller: dateController,
                  decoration: const InputDecoration(labelText: 'Tanggal Kendala (yyyy-MM-dd)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: issueType,
                  decoration: const InputDecoration(labelText: 'Tipe Kendala', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'Aplikasi Error / Crash', child: Text('Aplikasi Error / Crash')),
                    DropdownMenuItem(value: 'GPS / Lokasi Bermasalah', child: Text('GPS / Lokasi Bermasalah')),
                    DropdownMenuItem(value: 'HP / Perangkat Bermasalah', child: Text('HP / Perangkat Bermasalah')),
                    DropdownMenuItem(value: 'Lainnya', child: Text('Lainnya')),
                  ],
                  onChanged: (v) => setModalState(() => issueType = v ?? issueType),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descController,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Deskripsi Detail Kendala', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      if (descController.text.trim().isEmpty) {
                        AppUi.showSnack('Deskripsi kendala wajib diisi');
                        return;
                      }
                      try {
                        final user = _client.auth.currentUser;
                        final userProfile = await _currentProfile();
                        final Map<String, dynamic> insertPayload = {
                          'user_id': user!.id,
                          'user_name': userProfile?['nama'] ?? 'Karyawan',
                          'user_email': userProfile?['email'] ?? '',
                          'role_id': userProfile?['role_id'] ?? 'staff',
                          'report_date': dateController.text.trim(),
                          'issue_type': issueType,
                          'description': descController.text.trim(),
                          'status': 'pending',
                          'created_at': DateTime.now().toUtc().toIso8601String(),
                        };
                        final rawTenant = userProfile?['tenant_id'] ?? _profile?['tenant_id'];
                        if (rawTenant != null && rawTenant.toString().isNotEmpty) {
                          insertPayload['tenant_id'] = rawTenant;
                        }

                        await _client.from('attendance_bug_reports').insert(insertPayload);
                        Navigator.pop(ctx);
                        AppUi.showSnack('Laporan kendala berhasil dikirim ke Super Admin / HR / Finance.');
                      } catch (e) {
                        AppUi.showSnack('Gagal mengirim laporan: $e');
                      }
                    },
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('Kirim Laporan Kendala'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showBugReportsAndOverrideModal() async {
    List<Map<String, dynamic>> bugReports = [];
    List<Map<String, dynamic>> allUsers = [];
    bool isLoadingModal = true;

    try {
      final repRes = await _client.from('attendance_bug_reports').select().order('created_at', ascending: false).limit(50);
      bugReports = (repRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

      final usrRes = await _client.from('users').select('user_id, nama, email, role_id').eq('status', 'active');
      allUsers = (usrRes as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e) {
      debugPrint('Error loading bug reports: $e');
    }
    isLoadingModal = false;

    final user = _client.auth.currentUser;
    final profile = await _currentProfile();

    Map<String, dynamic>? selectedUserForOverride = allUsers.isNotEmpty ? allUsers.first : null;
    final overrideDateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
    final overrideInTimeCtrl = TextEditingController(text: '08:00');
    final overrideOutTimeCtrl = TextEditingController(text: '17:00');
    final overrideNoteCtrl = TextEditingController(text: 'Manual Override oleh HR / Finance / Super Admin');

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return DefaultTabController(
            length: 2,
            child: Container(
              height: MediaQuery.of(context).size.height * 0.85,
              padding: EdgeInsets.only(
                left: 16, right: 16, top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A) : Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.grey.withOpacity(0.4), borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(height: 12),
                  const Text('Laporan Kendala & Manual Override Absensi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  const TabBar(
                    tabs: [
                      Tab(text: 'Laporan Kendala'),
                      Tab(text: 'Manual Override Absensi'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: TabBarView(
                      children: [
                        isLoadingModal
                            ? const Center(child: CircularProgressIndicator())
                            : bugReports.isEmpty
                                ? const Center(child: Text('Belum ada laporan kendala.'))
                                : ListView.builder(
                                    itemCount: bugReports.length,
                                    itemBuilder: (context, i) {
                                      final r = bugReports[i];
                                      final isResolved = r['status'] == 'resolved';
                                      return Card(
                                        margin: const EdgeInsets.only(bottom: 10),
                                        child: ListTile(
                                          title: Text('${AppUi.text(r['user_name'])} • ${r['report_date']}'),
                                          subtitle: Text('Tipe: ${r['issue_type']}\nKet: ${r['description']}\nStatus: ${r['status']}'),
                                          trailing: isResolved
                                              ? const Chip(label: Text('RESOLVED'), backgroundColor: Colors.greenAccent)
                                              : ElevatedButton(
                                                  onPressed: () async {
                                                    await _client.from('attendance_bug_reports').update({
                                                      'status': 'resolved',
                                                      'resolved_by': user!.id,
                                                      'resolved_by_name': profile?['nama'] ?? 'Approver',
                                                      'resolved_at': DateTime.now().toUtc().toIso8601String(),
                                                    }).eq('report_id', r['report_id']);
                                                    setModalState(() {
                                                      r['status'] = 'resolved';
                                                    });
                                                    AppUi.showSnack('Laporan ditandai selesai!');
                                                  },
                                                  child: const Text('Resolve'),
                                                ),
                                        ),
                                      );
                                    },
                                  ),
                        SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DropdownButtonFormField<Map<String, dynamic>>(
                                value: selectedUserForOverride,
                                decoration: const InputDecoration(labelText: 'Pilih Karyawan', border: OutlineInputBorder()),
                                items: allUsers.map((u) {
                                  return DropdownMenuItem(
                                    value: u,
                                    child: Text('${u['nama']} (${AppUi.text(u['role_id'])})'),
                                  );
                                }).toList(),
                                onChanged: (val) => setModalState(() => selectedUserForOverride = val),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: overrideDateCtrl,
                                decoration: const InputDecoration(labelText: 'Tanggal (yyyy-MM-dd)', border: OutlineInputBorder()),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: overrideInTimeCtrl,
                                      decoration: const InputDecoration(labelText: 'Jam Check-In (HH:mm)', border: OutlineInputBorder()),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: overrideOutTimeCtrl,
                                      decoration: const InputDecoration(labelText: 'Jam Check-Out (HH:mm)', border: OutlineInputBorder()),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: overrideNoteCtrl,
                                decoration: const InputDecoration(labelText: 'Catatan Manual Override', border: OutlineInputBorder()),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: () async {
                                    if (selectedUserForOverride == null) return;
                                    try {
                                      final targetUserId = selectedUserForOverride!['user_id'];
                                      final dateStr = overrideDateCtrl.text.trim();
                                      final checkInStr = '${dateStr}T${overrideInTimeCtrl.text.trim()}:00.000Z';
                                      final checkOutStr = '${dateStr}T${overrideOutTimeCtrl.text.trim()}:00.000Z';

                                      final profileTarget = await _client.from('users').select('tenant_id, nama, email, role_id').eq('user_id', targetUserId).single();

                                      await _client.from('attendance').upsert({
                                        'tenant_id': profileTarget['tenant_id'],
                                        'user_id': targetUserId,
                                        'user_name': profileTarget['nama'],
                                        'user_email': profileTarget['email'],
                                        'role_id': profileTarget['role_id'],
                                        'date': dateStr,
                                        'status': 'manual_override',
                                        'check_in_time': checkInStr,
                                        'check_out_time': checkOutStr,
                                        'note': overrideNoteCtrl.text.trim(),
                                      }, onConflict: 'tenant_id, user_id, date');

                                      await _client.from('audit_logs').insert({
                                        'user_id': user!.id,
                                        'nama_user': profile?['nama'],
                                        'role_id': profile?['role_id'],
                                        'aktivitas': 'MANUAL_ATTENDANCE_OVERRIDE',
                                        'modul': 'attendance',
                                        'data_sesudah': {
                                          'target_user_id': targetUserId,
                                          'date': dateStr,
                                          'check_in': checkInStr,
                                          'check_out': checkOutStr,
                                        },
                                      });

                                      Navigator.pop(ctx);
                                      _loadData();
                                      AppUi.showSnack('Manual override absensi berhasil disimpan!');
                                    } catch (e) {
                                      AppUi.showSnack('Gagal melakukan manual override: $e');
                                    }
                                  },
                                  icon: const Icon(Icons.save_rounded),
                                  label: const Text('Simpan Manual Override'),
                                ),
                              ),
                            ],
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
      ),
    );
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();
    if (_errorMessage != null)
      return ErrorState(message: _errorMessage!, onRetry: _loadData);

    final hasOpenSession = _todayAbsensi?['check_in_time'] != null &&
        _todayAbsensi?['check_out_time'] == null;
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
            subtitle:
                'Check-in dan check-out memakai GPS dengan validasi radius lokasi kerja.',
            stats: [
              StatPill(
                  label: 'Sesi Aktif',
                  value: hasOpenSession ? 'Masuk' : 'Tidak Ada'),
              StatPill(label: 'Check Out', value: checkedOut ? 'Done' : '-'),
              StatPill(
                  label: 'Lokasi Aktif', value: _locations.length.toString()),
              StatPill(
                  label: 'Jadwal',
                  value: _todaySchedule == null
                      ? '-'
                      : (_todaySchedule!.isWorkday
                          ? _todaySchedule!.startLabel
                          : 'Libur')),
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
                        onPressed:
                            _isSaving || hasOpenSession ? null : _checkIn,
                        icon: Icon(Icons.login),
                        label: Text('Check In'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _isSaving || !hasOpenSession ? null : _checkOut,
                        icon: Icon(Icons.logout),
                        label: Text('Check Out'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _showReportBugModal,
                    icon: const Icon(Icons.bug_report_outlined, color: Colors.orange),
                    label: const Text('Laporkan Kendala Absensi'),
                  ),
                ),
                if (_isAuthorizedOverrideRole) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _showBugReportsAndOverrideModal,
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
                      icon: const Icon(Icons.verified_user_rounded),
                      label: const Text('Laporan Kendala & Manual Override Absensi'),
                    ),
                  ),
                ],
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
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${AppUi.text(item['user_email'])} • ${AppUi.text(item['role_id'])}\n'
                    'Tanggal: ${AppUi.date(item['date'])} • Status: $status\n'
                    'IN: ${AppUi.dateTime(item['check_in_time'])} (${AppUi.toNum(item['check_in_distance_meter']).toStringAsFixed(0)}m)\n'
                    'OUT: ${AppUi.dateTime(item['check_out_time'])} (${AppUi.toNum(item['check_out_distance_meter']).toStringAsFixed(0)}m)',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isAuthorizedOverrideRole && status == 'early_leave_pending') ...[
                        FilledButton.icon(
                          onPressed: () => _approveEarlyLeave(item),
                          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981), padding: const EdgeInsets.symmetric(horizontal: 8)),
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Setujui Pulang Awal', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                      if (_isSuperAdmin) ...[
                        IconButton(
                          tooltip: 'Hapus attendance',
                          onPressed: () => _deleteAbsensi(item),
                          icon: Icon(Icons.delete_outline, color: AppUi.red),
                        ),
                      ],
                    ],
                  ),
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
  final String originalStartLabel;
  final String originalEndLabel;
  final bool hasShiftOverride;

  const _TodayWorkSchedule({
    required this.isWorkday,
    required this.isLate,
    required this.lateMinutes,
    required this.toleranceMinutes,
    required this.startLabel,
    required this.endLabel,
    required this.originalStartLabel,
    required this.originalEndLabel,
    required this.hasShiftOverride,
  });

  factory _TodayWorkSchedule.fromMap(Map<String, dynamic> map) {
    return _TodayWorkSchedule(
      isWorkday: map['is_workday'] == true,
      isLate: map['is_late'] == true,
      lateMinutes: _toInt(map['late_minutes']),
      toleranceMinutes: _toInt(map['tolerance_minutes']),
      startLabel: _formatTime(map['start_time']),
      endLabel: _formatTime(map['end_time']),
      originalStartLabel: _formatTime(map['original_start_time']),
      originalEndLabel: _formatTime(map['original_end_time']),
      hasShiftOverride: map['has_shift_override'] == true,
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
