import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/ui/app_ui.dart';
import '../../../models/app_user.dart';

class OvertimePage extends StatefulWidget {
  final AppUser? currentUser;

  const OvertimePage({super.key, this.currentUser});

  @override
  State<OvertimePage> createState() => _OvertimePageState();
}

class _OvertimePageState extends State<OvertimePage> with SingleTickerProviderStateMixin {
  final SupabaseClient _client = Supabase.instance.client;
  late TabController _tabController;

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isUploadingAttachment = false;
  String? _tenantId;

  List<Map<String, dynamic>> _myRequests = [];
  List<Map<String, dynamic>> _pendingRequests = [];

  final _dateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _startTimeController = TextEditingController(text: '17:00');
  final _endTimeController = TextEditingController(text: '19:00');
  final _reasonController = TextEditingController();

  List<Map<String, dynamic>> _myLeaveRequests = [];
  List<Map<String, dynamic>> _allLeaveRequests = [];

  List<Map<String, dynamic>> _myShiftChangeRequests = [];
  List<Map<String, dynamic>> _allShiftChangeRequests = [];

  String _selectedLeaveType = 'sakit';
  final _leaveStartDateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _leaveEndDateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _leaveReasonCtrl = TextEditingController();
  final _leaveAttachmentCtrl = TextEditingController();

  final _shiftDateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _shiftNewStartCtrl = TextEditingController(text: '12:00');
  final _shiftNewEndCtrl = TextEditingController(text: '20:00');
  final _shiftReasonCtrl = TextEditingController();

  String _userRoleId = '';

  bool get _isApprover {
    final role = (_userRoleId.isNotEmpty
            ? _userRoleId
            : (widget.currentUser?.role ??
                _client.auth.currentUser?.userMetadata?['role_id'] ??
                _client.auth.currentUser?.appMetadata['role_id'] ??
                ''))
        .toString()
        .toLowerCase();
    return role.contains('super_admin') ||
        role.contains('finance') ||
        role.contains('hr') ||
        role.contains('admin') ||
        role == 'super_admin' ||
        role == 'demo_super_admin';
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _dateController.dispose();
    _startTimeController.dispose();
    _endTimeController.dispose();
    _reasonController.dispose();
    _leaveStartDateCtrl.dispose();
    _leaveEndDateCtrl.dispose();
    _leaveReasonCtrl.dispose();
    _leaveAttachmentCtrl.dispose();
    _shiftDateCtrl.dispose();
    _shiftNewStartCtrl.dispose();
    _shiftNewEndCtrl.dispose();
    _shiftReasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _openAttachmentUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _pickAndUploadAttachment() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null) return;

      setState(() => _isUploadingAttachment = true);

      final ext = file.extension ?? 'jpg';
      final fileName = 'leave_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final storagePath = 'leave/$fileName';

      await _client.storage.from('leave_attachments').uploadBinary(
        storagePath,
        file.bytes!,
        fileOptions: FileOptions(contentType: ext == 'pdf' ? 'application/pdf' : 'image/$ext', upsert: true),
      );

      final publicUrl = _client.storage.from('leave_attachments').getPublicUrl(storagePath);

      setState(() {
        _leaveAttachmentCtrl.text = publicUrl;
      });

      AppUi.showSnack('Bukti surat/dokumen berhasil diupload!');
    } catch (e) {
      AppUi.showSnack('Gagal meng-upload dokumen: $e');
    } finally {
      if (mounted) setState(() => _isUploadingAttachment = false);
    }
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final user = _client.auth.currentUser;
      if (user == null) return;

      final profileRes = await _client.from('users').select('tenant_id, nama, email, role_id').eq('user_id', user.id).maybeSingle();
      _tenantId = profileRes?['tenant_id']?.toString() ?? '';
      _userRoleId = profileRes?['role_id']?.toString().toLowerCase() ?? '';

      if (_tabController.length != 3) {
        _tabController.dispose();
        _tabController = TabController(length: 3, vsync: this);
      }

      final myRes = await _client
          .from('overtime_requests')
          .select()
          .eq('user_id', user.id)
          .order('created_at', ascending: false)
          .limit(100);
      _myRequests = (myRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

      final myLeaveRes = await _client
          .from('leave_requests')
          .select()
          .eq('user_id', user.id)
          .order('created_at', ascending: false)
          .limit(100);
      _myLeaveRequests = (myLeaveRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

      final myShiftRes = await _client
          .from('shift_change_requests')
          .select()
          .eq('user_id', user.id)
          .order('created_at', ascending: false)
          .limit(100);
      _myShiftChangeRequests = (myShiftRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

      if (_isApprover) {
        final pendingRes = await _client
            .from('overtime_requests')
            .select()
            .order('created_at', ascending: false)
            .limit(100);
        _pendingRequests = (pendingRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

        final allLeaveRes = await _client
            .from('leave_requests')
            .select()
            .order('created_at', ascending: false)
            .limit(100);
        _allLeaveRequests = (allLeaveRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

        final allShiftRes = await _client
            .from('shift_change_requests')
            .select()
            .order('created_at', ascending: false)
            .limit(100);
        _allShiftChangeRequests = (allShiftRes as List).map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Load overtime error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  double _calculateDurationHours() {
    try {
      final sParts = _startTimeController.text.trim().split(':');
      final eParts = _endTimeController.text.trim().split(':');
      if (sParts.length != 2 || eParts.length != 2) return 0;
      final startMin = int.parse(sParts[0]) * 60 + int.parse(sParts[1]);
      final endMin = int.parse(eParts[0]) * 60 + int.parse(eParts[1]);
      if (endMin <= startMin) return 0;
      return (endMin - startMin) / 60.0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _submitOvertime() async {
    final dateStr = _dateController.text.trim();
    final startTime = _startTimeController.text.trim();
    final endTime = _endTimeController.text.trim();
    final reason = _reasonController.text.trim();
    final duration = _calculateDurationHours();

    if (duration <= 0) {
      AppUi.showSnack('Jam selesai harus lebih dari jam mulai');
      return;
    }
    if (reason.isEmpty) {
      AppUi.showSnack('Alasan lembur wajib diisi');
      return;
    }

    setState(() => _isSaving = true);
    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama, email, role_id, tenant_id').eq('user_id', user!.id).single();

      final tenantId = userProfile['tenant_id'] ?? _tenantId;
      double hourlyRate = 25000.0;
      try {
        final prof = await _client
            .from('user_payroll_profiles')
            .select('hourly_rate')
            .eq('user_id', user.id)
            .maybeSingle();
        if (prof != null && AppUi.toNum(prof['hourly_rate']) > 0) {
          hourlyRate = AppUi.toNum(prof['hourly_rate']).toDouble();
        }
      } catch (_) {}

      final totalAmount = duration * hourlyRate;

      await _client.from('overtime_requests').insert({
        'tenant_id': tenantId,
        'user_id': user.id,
        'user_name': userProfile['nama'] ?? 'Karyawan',
        'user_email': userProfile['email'] ?? '',
        'role_id': userProfile['role_id'] ?? 'staff',
        'overtime_date': dateStr,
        'start_time': startTime,
        'end_time': endTime,
        'duration_hours': duration,
        'reason': reason,
        'status': 'pending',
        'hourly_rate': hourlyRate,
        'total_amount': totalAmount,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      _reasonController.clear();
      AppUi.showSnack('Pengajuan lembur berhasil dikirim!');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal mengirim lembur: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _approveOvertime(Map<String, dynamic> request) async {
    final double duration = AppUi.toNum(request['duration_hours']).toDouble();
    double hourlyRate = AppUi.toNum(request['hourly_rate']).toDouble() > 0
        ? AppUi.toNum(request['hourly_rate']).toDouble()
        : 25000.0;

    try {
      final prof = await _client
          .from('user_payroll_profiles')
          .select('hourly_rate')
          .eq('user_id', request['user_id'])
          .maybeSingle();
      if (prof != null && AppUi.toNum(prof['hourly_rate']) > 0) {
        hourlyRate = AppUi.toNum(prof['hourly_rate']).toDouble();
      }
    } catch (_) {}

    final double totalAmount = duration * hourlyRate;
    final currencyFmt = NumberFormat.currency(locale: 'id', symbol: 'Rp ', decimalDigits: 0);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Setujui Pengajuan Lembur'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Karyawan: ${AppUi.text(request['user_name'])} (${AppUi.text(request['role_id'])})'),
            const SizedBox(height: 4),
            Text('Tanggal: ${request['overtime_date']} (${request['start_time']} - ${request['end_time']})'),
            const SizedBox(height: 4),
            Text('Durasi: ${duration.toStringAsFixed(1)} Jam'),
            const SizedBox(height: 4),
            Text('Alasan: ${AppUi.text(request['reason'])}'),
            const Divider(height: 20),
            Text('Tarif Lembur (Payroll): ${currencyFmt.format(hourlyRate)} / Jam', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Total Uang Lembur: ${currencyFmt.format(totalAmount)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Setujui')),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama').eq('user_id', user!.id).maybeSingle();
      final approvedByName = userProfile?['nama'] ?? 'Approver';

      await _client.from('overtime_requests').update({
        'status': 'approved',
        'hourly_rate': hourlyRate,
        'total_amount': totalAmount,
        'approved_by': user.id,
        'approved_by_name': approvedByName,
        'approved_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('overtime_id', request['overtime_id']);

      AppUi.showSnack('Pengajuan lembur disetujui!');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menyetujui lembur: $e');
    }
  }

  Future<void> _rejectOvertime(Map<String, dynamic> request) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tolak Pengajuan Lembur'),
        content: TextField(
          controller: reasonController,
          decoration: const InputDecoration(
            labelText: 'Alasan Penolakan',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tolak'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama').eq('user_id', user!.id).maybeSingle();

      await _client.from('overtime_requests').update({
        'status': 'rejected',
        'rejection_reason': reasonController.text.trim(),
        'approved_by': user.id,
        'approved_by_name': userProfile?['nama'] ?? 'Approver',
        'approved_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('overtime_id', request['overtime_id']);

      AppUi.showSnack('Pengajuan lembur ditolak.');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menolak lembur: $e');
    }
  }

  Future<void> _editOvertime(Map<String, dynamic> req) async {
    final dateCtrl = TextEditingController(text: req['overtime_date']);
    final startCtrl = TextEditingController(text: req['start_time']);
    final endCtrl = TextEditingController(text: req['end_time']);
    final reasonCtrl = TextEditingController(text: req['reason']);
    final rateCtrl = TextEditingController(text: AppUi.toNum(req['hourly_rate']).toStringAsFixed(0));
    String status = req['status'] ?? 'pending';

    final updated = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          title: Text('Edit Pengajuan Lembur (${AppUi.text(req['user_name'])})'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: dateCtrl, decoration: const InputDecoration(labelText: 'Tanggal (yyyy-MM-dd)', border: OutlineInputBorder())),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: TextField(controller: startCtrl, decoration: const InputDecoration(labelText: 'Jam Mulai (HH:mm)', border: OutlineInputBorder()))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: endCtrl, decoration: const InputDecoration(labelText: 'Jam Selesai (HH:mm)', border: OutlineInputBorder()))),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(controller: rateCtrl, decoration: const InputDecoration(labelText: 'Tarif Lembur Per Jam (Rp)', border: OutlineInputBorder())),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: status,
                  decoration: const InputDecoration(labelText: 'Status Approval', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'pending', child: Text('PENDING')),
                    DropdownMenuItem(value: 'approved', child: Text('APPROVED')),
                    DropdownMenuItem(value: 'rejected', child: Text('REJECTED')),
                  ],
                  onChanged: (v) => setModalState(() => status = v ?? status),
                ),
                const SizedBox(height: 10),
                TextField(controller: reasonCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Alasan', border: OutlineInputBorder())),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan Perubahan')),
          ],
        ),
      ),
    );

    if (updated != true) return;

    try {
      final sTime = startCtrl.text.trim();
      final eTime = endCtrl.text.trim();
      double duration = 0;
      try {
        final sParts = sTime.split(':');
        final eParts = eTime.split(':');
        final sMin = int.parse(sParts[0]) * 60 + int.parse(sParts[1]);
        final eMin = int.parse(eParts[0]) * 60 + int.parse(eParts[1]);
        duration = (eMin - sMin) / 60.0;
      } catch (_) {}
      if (duration < 0) duration = 0;

      final hourlyRate = double.tryParse(rateCtrl.text.trim()) ?? 25000;
      final totalAmount = duration * hourlyRate;

      await _client.from('overtime_requests').update({
        'overtime_date': dateCtrl.text.trim(),
        'start_time': sTime,
        'end_time': eTime,
        'duration_hours': duration,
        'hourly_rate': hourlyRate,
        'total_amount': totalAmount,
        'status': status,
        'reason': reasonCtrl.text.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('overtime_id', req['overtime_id']);

      AppUi.showSnack('Data lembur berhasil diperbarui!');
      _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal mengedit data lembur: $e');
    }
  }

  Future<void> _deleteOvertime(Map<String, dynamic> req) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Pengajuan Lembur'),
        content: Text('Apakah Anda yakin ingin menghapus data lembur tanggal ${req['overtime_date']} untuk ${AppUi.text(req['user_name'])}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.from('overtime_requests').delete().eq('overtime_id', req['overtime_id']);
      AppUi.showSnack('Data lembur berhasil dihapus!');
      _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menghapus data lembur: $e');
    }
  }

  Future<void> _submitLeaveRequest() async {
    final startDateStr = _leaveStartDateCtrl.text.trim();
    final endDateStr = _leaveEndDateCtrl.text.trim();
    final reason = _leaveReasonCtrl.text.trim();

    if (reason.isEmpty) {
      AppUi.showSnack('Alasan izin / sakit wajib diisi');
      return;
    }

    DateTime sDate = DateTime.tryParse(startDateStr) ?? DateTime.now();
    DateTime eDate = DateTime.tryParse(endDateStr) ?? DateTime.now();
    if (eDate.isBefore(sDate)) {
      AppUi.showSnack('Tanggal selesai tidak boleh sebelum tanggal mulai');
      return;
    }

    final totalDays = eDate.difference(sDate).inDays + 1;

    setState(() => _isSaving = true);
    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama, email, role_id, tenant_id').eq('user_id', user!.id).maybeSingle();

      final tenantId = userProfile?['tenant_id'] ?? _tenantId;

      await _client.from('leave_requests').insert({
        'tenant_id': tenantId,
        'user_id': user.id,
        'user_name': userProfile?['nama'] ?? 'Karyawan',
        'user_email': userProfile?['email'] ?? '',
        'role_id': userProfile?['role_id'] ?? 'staff',
        'leave_type': _selectedLeaveType,
        'start_date': startDateStr,
        'end_date': endDateStr,
        'total_days': totalDays,
        'reason': reason,
        'attachment_url': _leaveAttachmentCtrl.text.trim().isNotEmpty ? _leaveAttachmentCtrl.text.trim() : null,
        'status': 'pending',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      _leaveReasonCtrl.clear();
      _leaveAttachmentCtrl.clear();
      AppUi.showSnack('Pengajuan izin / sakit berhasil dikirim!');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal mengirim pengajuan izin: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _approveLeaveRequest(Map<String, dynamic> request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Setujui Pengajuan Izin / Sakit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Karyawan: ${AppUi.text(request['user_name'])} (${AppUi.text(request['role_id'])})'),
            const SizedBox(height: 4),
            Text('Tipe Izin: ${request['leave_type']?.toString().toUpperCase()}'),
            const SizedBox(height: 4),
            Text('Periode: ${request['start_date']} s/d ${request['end_date']} (${request['total_days']} Hari)'),
            const SizedBox(height: 4),
            Text('Alasan: ${AppUi.text(request['reason'])}'),
            const SizedBox(height: 12),
            const Text('Hari izin yang disetujui akan otomatis dicatat ke Absensi sehingga gaji karyawan tidak dipotong saat payroll.', style: TextStyle(fontSize: 12, color: Colors.blue)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Setujui Izin')),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama').eq('user_id', user!.id).maybeSingle();

      await _client.from('leave_requests').update({
        'status': 'approved',
        'approved_by': user.id,
        'approved_by_name': userProfile?['nama'] ?? 'Approver',
        'approved_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('request_id', request['request_id']);

      DateTime sDate = DateTime.tryParse(request['start_date']) ?? DateTime.now();
      DateTime eDate = DateTime.tryParse(request['end_date']) ?? DateTime.now();

      for (DateTime d = sDate; !d.isAfter(eDate); d = d.add(const Duration(days: 1))) {
        final dateStr = DateFormat('yyyy-MM-dd').format(d);
        await _client.from('attendance').upsert({
          'tenant_id': request['tenant_id'],
          'user_id': request['user_id'],
          'user_name': request['user_name'],
          'user_email': request['user_email'],
          'role_id': request['role_id'],
          'date': dateStr,
          'status': request['leave_type'],
          'notes': 'Izin disetujui: ${request['reason']}',
        }, onConflict: 'tenant_id, user_id, date');
      }

      AppUi.showSnack('Pengajuan izin disetujui & otomatis dicatat di Absensi!');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menyetujui izin: $e');
    }
  }

  Future<void> _rejectLeaveRequest(Map<String, dynamic> request) async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tolak Pengajuan Izin'),
        content: TextField(
          controller: reasonCtrl,
          decoration: const InputDecoration(labelText: 'Alasan Penolakan', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tolak'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama').eq('user_id', user!.id).maybeSingle();

      await _client.from('leave_requests').update({
        'status': 'rejected',
        'rejection_reason': reasonCtrl.text.trim(),
        'approved_by': user.id,
        'approved_by_name': userProfile?['nama'] ?? 'Approver',
        'approved_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('request_id', request['request_id']);

      AppUi.showSnack('Pengajuan izin ditolak.');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menolak izin: $e');
    }
  }

  Future<void> _deleteLeaveRequest(Map<String, dynamic> request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Pengajuan Izin'),
        content: Text('Hapus pengajuan izin ${request['start_date']} s/d ${request['end_date']} untuk ${AppUi.text(request['user_name'])}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.from('leave_requests').delete().eq('request_id', request['request_id']);
      AppUi.showSnack('Pengajuan izin berhasil dihapus!');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menghapus izin: $e');
    }
  }

  Future<void> _submitShiftChangeRequest() async {
    final dateStr = _shiftDateCtrl.text.trim();
    final newStart = _shiftNewStartCtrl.text.trim();
    final newEnd = _shiftNewEndCtrl.text.trim();
    final reason = _shiftReasonCtrl.text.trim();

    if (reason.isEmpty) {
      AppUi.showSnack('Alasan perubahan/tukar shift wajib diisi');
      return;
    }

    setState(() => _isSaving = true);
    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama, email, role_id, tenant_id').eq('user_id', user!.id).maybeSingle();

      final Map<String, dynamic> insertPayload = {
        'user_id': user.id,
        'user_name': userProfile?['nama'] ?? 'Karyawan',
        'user_email': userProfile?['email'] ?? '',
        'role_id': userProfile?['role_id'] ?? 'staff',
        'shift_date': dateStr,
        'new_start_time': newStart,
        'new_end_time': newEnd,
        'reason': reason,
        'status': 'pending',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      final rawTenant = userProfile?['tenant_id'] ?? _tenantId;
      if (rawTenant != null && rawTenant.toString().isNotEmpty) {
        insertPayload['tenant_id'] = rawTenant;
      }

      await _client.from('shift_change_requests').insert(insertPayload);

      _shiftReasonCtrl.clear();
      AppUi.showSnack('Pengajuan tukar shift berhasil dikirim! Menunggu persetujuan Super Admin / HR / Finance.');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal mengirim pengajuan tukar shift: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _approveShiftChangeRequest(Map<String, dynamic> req) async {
    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama').eq('user_id', user!.id).maybeSingle();

      await _client.from('shift_change_requests').update({
        'status': 'approved',
        'approved_by': user.id,
        'approved_by_name': userProfile?['nama'] ?? 'Approver',
        'approved_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('request_id', req['request_id']);

      AppUi.showSnack('Pengajuan tukar shift disetujui! Jam kerja hari tersebut otomatis diperbarui.');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menyetujui tukar shift: $e');
    }
  }

  Future<void> _rejectShiftChangeRequest(Map<String, dynamic> req) async {
    try {
      final user = _client.auth.currentUser;
      final userProfile = await _client.from('users').select('nama').eq('user_id', user!.id).maybeSingle();

      await _client.from('shift_change_requests').update({
        'status': 'rejected',
        'approved_by': user.id,
        'approved_by_name': userProfile?['nama'] ?? 'Approver',
        'approved_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('request_id', req['request_id']);

      AppUi.showSnack('Pengajuan tukar shift ditolak.');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menolak tukar shift: $e');
    }
  }

  Future<void> _deleteShiftChangeRequest(Map<String, dynamic> req) async {
    try {
      await _client.from('shift_change_requests').delete().eq('request_id', req['request_id']);
      AppUi.showSnack('Data tukar shift berhasil dihapus!');
      await _loadData();
    } catch (e) {
      AppUi.showSnack('Gagal menghapus data tukar shift: $e');
    }
  }

  Future<void> _pickDate() async {
    DateTime initialDate = DateTime.tryParse(_dateController.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now().add(const Duration(days: 180)),
    );
    if (picked != null) {
      setState(() {
        _dateController.text = DateFormat('yyyy-MM-dd').format(picked);
      });
    }
  }

  Future<void> _pickStartTime() async {
    final parts = _startTimeController.text.split(':');
    final initialTime = parts.length == 2
        ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 17, minute: int.tryParse(parts[1]) ?? 0)
        : const TimeOfDay(hour: 17, minute: 0);
    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );
    if (picked != null) {
      setState(() {
        _startTimeController.text =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  Future<void> _pickEndTime() async {
    final parts = _endTimeController.text.split(':');
    final initialTime = parts.length == 2
        ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 20, minute: int.tryParse(parts[1]) ?? 0)
        : const TimeOfDay(hour: 20, minute: 0);
    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );
    if (picked != null) {
      setState(() {
        _endTimeController.text =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  Future<void> _pickShiftStartTime() async {
    final parts = _shiftNewStartCtrl.text.split(':');
    final initialTime = parts.length == 2
        ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 12, minute: int.tryParse(parts[1]) ?? 0)
        : const TimeOfDay(hour: 12, minute: 0);
    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );
    if (picked != null) {
      setState(() {
        _shiftNewStartCtrl.text =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  Future<void> _pickShiftEndTime() async {
    final parts = _shiftNewEndCtrl.text.split(':');
    final initialTime = parts.length == 2
        ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 20, minute: int.tryParse(parts[1]) ?? 0)
        : const TimeOfDay(hour: 20, minute: 0);
    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );
    if (picked != null) {
      setState(() {
        _shiftNewEndCtrl.text =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return Colors.green;
      case 'rejected':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  List<Widget> _buildMyTabChildren() {
    return [
      NiceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Form Pengajuan Lembur', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _dateController,
                    readOnly: true,
                    onTap: _pickDate,
                    decoration: const InputDecoration(
                      labelText: 'Tanggal',
                      suffixIcon: Icon(Icons.calendar_today_rounded, size: 20),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _startTimeController,
                    readOnly: true,
                    onTap: _pickStartTime,
                    decoration: const InputDecoration(
                      labelText: 'Jam Mulai',
                      suffixIcon: Icon(Icons.access_time_rounded, size: 20),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _endTimeController,
                    readOnly: true,
                    onTap: _pickEndTime,
                    decoration: const InputDecoration(
                      labelText: 'Jam Selesai',
                      suffixIcon: Icon(Icons.access_time_rounded, size: 20),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Estimasi Durasi: ${_calculateDurationHours().toStringAsFixed(1)} Jam', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            TextField(
              controller: _reasonController,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Alasan / Deskripsi Pekerjaan Lembur', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _submitOvertime,
                icon: const Icon(Icons.send_rounded),
                label: Text(_isSaving ? 'Mengirim...' : 'Kirim Pengajuan Lembur'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Text('Riwayat Pengajuan Lembur Saya (${_myRequests.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      const SizedBox(height: 8),
      if (_myRequests.isEmpty)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Belum ada riwayat pengajuan lembur.')))
      else
        ..._myRequests.map((req) {
          final status = req['status']?.toString() ?? 'pending';
          final color = _getStatusColor(status);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: NiceCard(
              child: ListTile(
                title: Text('Tanggal: ${req['overtime_date']} (${req['start_time']} - ${req['end_time']})'),
                subtitle: Text('Durasi: ${AppUi.toNum(req['duration_hours']).toStringAsFixed(1)} Jam | Total: Rp ${AppUi.toNum(req['total_amount']).toStringAsFixed(0)}\nAlasan: ${AppUi.text(req['reason'])}'),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                  child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ),
            ),
          );
        }),
    ];
  }

  List<Widget> _buildApproverTabChildren() {
    return [
      Text('Daftar Persetujuan Lembur Karyawan (${_pendingRequests.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      const SizedBox(height: 10),
      if (_pendingRequests.isEmpty)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Tidak ada pengajuan lembur.')))
      else
        ..._pendingRequests.map((req) {
          final status = req['status']?.toString() ?? 'pending';
          final color = _getStatusColor(status);
          final isPending = status == 'pending';

          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${AppUi.text(req['user_name'])} • ${AppUi.text(req['role_id'])}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                        child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Tanggal: ${req['overtime_date']} (${req['start_time']} - ${req['end_time']}) | Durasi: ${AppUi.toNum(req['duration_hours']).toStringAsFixed(1)} Jam'),
                  Text('Tarif: Rp ${AppUi.toNum(req['hourly_rate']).toStringAsFixed(0)}/jam | Total: Rp ${AppUi.toNum(req['total_amount']).toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                  Text('Alasan: ${AppUi.text(req['reason'])}'),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_isApprover) ...[
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, color: Colors.blue, size: 20),
                          onPressed: () => _editOvertime(req),
                          tooltip: 'Edit Data Lembur',
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
                          onPressed: () => _deleteOvertime(req),
                          tooltip: 'Hapus Data Lembur',
                        ),
                      ],
                    ],
                  ),
                  if (isPending) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _rejectOvertime(req),
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            label: const Text('Tolak'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _approveOvertime(req),
                            icon: const Icon(Icons.check_rounded, size: 18),
                            label: const Text('Setujui'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
    ];
  }

  List<Widget> _buildLeaveTabChildren() {
    return [
      NiceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Form Pengajuan Izin / Sakit / Cuti', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedLeaveType,
              decoration: const InputDecoration(labelText: 'Tipe Izin', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'sakit', child: Text('Sakit (Dengan Surat Dokter)')),
                DropdownMenuItem(value: 'izin', child: Text('Izin / Permisi')),
                DropdownMenuItem(value: 'cuti', child: Text('Cuti Tahunan')),
                DropdownMenuItem(value: 'cuti_melahirkan', child: Text('Cuti Melahirkan / Duka')),
                DropdownMenuItem(value: 'lainnya', child: Text('Lainnya')),
              ],
              onChanged: (v) => setState(() => _selectedLeaveType = v ?? 'sakit'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _leaveStartDateCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Tanggal Mulai',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today_rounded),
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: DateTime.tryParse(_leaveStartDateCtrl.text) ?? DateTime.now(),
                        firstDate: DateTime.now().subtract(const Duration(days: 90)),
                        lastDate: DateTime.now().add(const Duration(days: 180)),
                      );
                      if (picked != null) {
                        setState(() => _leaveStartDateCtrl.text = DateFormat('yyyy-MM-dd').format(picked));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _leaveEndDateCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Tanggal Selesai',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today_rounded),
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: DateTime.tryParse(_leaveEndDateCtrl.text) ?? DateTime.now(),
                        firstDate: DateTime.now().subtract(const Duration(days: 90)),
                        lastDate: DateTime.now().add(const Duration(days: 180)),
                      );
                      if (picked != null) {
                        setState(() => _leaveEndDateCtrl.text = DateFormat('yyyy-MM-dd').format(picked));
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _leaveReasonCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Alasan Izin / Sakit',
                hintText: 'Contoh: Sakit demam tinggi / Keperluan mendesak...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _leaveAttachmentCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Lampiran / Bukti Surat Dokter (PDF / Foto)',
                      hintText: 'Upload file atau isi link dokumen...',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.attach_file_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _isUploadingAttachment ? null : _pickAndUploadAttachment,
                  icon: _isUploadingAttachment
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.upload_file_rounded),
                  label: Text(_isUploadingAttachment ? 'Uploading...' : 'Upload File'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _submitLeaveRequest,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                icon: _isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded),
                label: Text(_isSaving ? 'Mengirim...' : 'Kirim Pengajuan Izin'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),

      if (_isApprover) ...[
        Text('Daftar Persetujuan Izin Karyawan (${_allLeaveRequests.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        if (_allLeaveRequests.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('Belum ada pengajuan izin karyawan.')))
        else
          ..._allLeaveRequests.map((req) {
            final status = req['status']?.toString() ?? 'pending';
            final color = _getStatusColor(status);
            final isPending = status == 'pending';
            final attachUrl = req['attachment_url']?.toString();

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: NiceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${AppUi.text(req['user_name'])} • ${AppUi.text(req['role_id'])}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                          child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Tipe: ${req['leave_type']?.toString().toUpperCase()} | Periode: ${req['start_date']} s/d ${req['end_date']} (${req['total_days']} Hari)', style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('Alasan: ${AppUi.text(req['reason'])}'),
                    if (attachUrl != null && attachUrl.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () => _openAttachmentUrl(attachUrl),
                        child: Row(
                          children: const [
                            Icon(Icons.attachment_rounded, size: 16, color: Colors.blue),
                            SizedBox(width: 4),
                            Text('Lihat Bukti Surat Dokter / Dokumen', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 13, decoration: TextDecoration.underline)),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
                          onPressed: () => _deleteLeaveRequest(req),
                          tooltip: 'Hapus Pengajuan Izin',
                        ),
                      ],
                    ),
                    if (isPending) ...[
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _rejectLeaveRequest(req),
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text('Tolak'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _approveLeaveRequest(req),
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('Setujui Izin'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 20),
      ],

      Text('Riwayat Pengajuan Izin Saya (${_myLeaveRequests.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      const SizedBox(height: 8),
      if (_myLeaveRequests.isEmpty)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Belum ada riwayat pengajuan izin.')))
      else
        ..._myLeaveRequests.map((req) {
          final status = req['status']?.toString() ?? 'pending';
          final color = _getStatusColor(status);
          final attachUrl = req['attachment_url']?.toString();
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: NiceCard(
              child: ListTile(
                title: Text('${req['leave_type']?.toString().toUpperCase()}: ${req['start_date']} s/d ${req['end_date']} (${req['total_days']} Hari)'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Alasan: ${AppUi.text(req['reason'])}'),
                    if (attachUrl != null && attachUrl.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      InkWell(
                        onTap: () => _openAttachmentUrl(attachUrl),
                        child: Row(
                          children: const [
                            Icon(Icons.attachment_rounded, size: 14, color: Colors.blue),
                            SizedBox(width: 4),
                            Text('Lihat Dokumen', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 12, decoration: TextDecoration.underline)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                  child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ),
            ),
          );
        }),
    ];
  }

  List<Widget> _buildShiftChangeTabChildren() {
    return [
      NiceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Form Pengajuan Tukar Shift / Ubah Jam Kerja', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _shiftDateCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Tanggal Shift',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today_rounded),
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: DateTime.tryParse(_shiftDateCtrl.text) ?? DateTime.now(),
                        firstDate: DateTime.now().subtract(const Duration(days: 30)),
                        lastDate: DateTime.now().add(const Duration(days: 90)),
                      );
                      if (picked != null) {
                        setState(() => _shiftDateCtrl.text = DateFormat('yyyy-MM-dd').format(picked));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _shiftNewStartCtrl,
                    readOnly: true,
                    onTap: _pickShiftStartTime,
                    decoration: const InputDecoration(
                      labelText: 'Jam Mulai Baru',
                      hintText: '12:00',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.access_time_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _shiftNewEndCtrl,
                    readOnly: true,
                    onTap: _pickShiftEndTime,
                    decoration: const InputDecoration(
                      labelText: 'Jam Selesai Baru',
                      hintText: '20:00',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.access_time_rounded),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _shiftReasonCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Alasan Tukar Shift / Ubah Jam Kerja',
                hintText: 'Contoh: Ada keperluan mendesak pagi hari, kerja dialihkan ke jam 12:00 - 20:00...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _submitShiftChangeRequest,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
                icon: _isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded),
                label: Text(_isSaving ? 'Mengirim...' : 'Kirim Pengajuan Tukar Shift'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),

      if (_isApprover) ...[
        Text('Daftar Persetujuan Tukar Shift Karyawan (${_allShiftChangeRequests.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        if (_allShiftChangeRequests.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('Belum ada pengajuan tukar shift.')))
        else
          ..._allShiftChangeRequests.map((req) {
            final status = req['status']?.toString() ?? 'pending';
            final color = _getStatusColor(status);
            final isPending = status == 'pending';

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: NiceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${AppUi.text(req['user_name'])} • ${AppUi.text(req['role_id'])}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                          child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Tanggal Shift: ${req['shift_date']} | Jam Baru: ${req['new_start_time']} s/d ${req['new_end_time']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('Alasan: ${AppUi.text(req['reason'])}'),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
                          onPressed: () => _deleteShiftChangeRequest(req),
                          tooltip: 'Hapus Pengajuan',
                        ),
                      ],
                    ),
                    if (isPending) ...[
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _rejectShiftChangeRequest(req),
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text('Tolak'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _approveShiftChangeRequest(req),
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('Setujui Tukar Shift'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 20),
      ],

      Text('Riwayat Pengajuan Tukar Shift Saya (${_myShiftChangeRequests.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      const SizedBox(height: 8),
      if (_myShiftChangeRequests.isEmpty)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Belum ada riwayat pengajuan tukar shift.')))
      else
        ..._myShiftChangeRequests.map((req) {
          final status = req['status']?.toString() ?? 'pending';
          final color = _getStatusColor(status);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: NiceCard(
              child: ListTile(
                title: Text('Shift ${req['shift_date']}: ${req['new_start_time']} - ${req['new_end_time']}'),
                subtitle: Text('Alasan: ${AppUi.text(req['reason'])}'),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                  child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ),
            ),
          );
        }),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pengajuan Lembur, Izin & Tukar Shift'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.more_time_rounded), text: 'Lembur'),
            Tab(icon: Icon(Icons.event_note_rounded), text: 'Izin & Sakit'),
            Tab(icon: Icon(Icons.published_with_changes_rounded), text: 'Tukar Shift'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    ..._buildMyTabChildren(),
                    if (_isApprover) ...[
                      const SizedBox(height: 24),
                      const Divider(height: 32, thickness: 2),
                      ..._buildApproverTabChildren(),
                    ],
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: _buildLeaveTabChildren(),
                ),
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: _buildShiftChangeTabChildren(),
                ),
              ],
            ),
    );
  }
}
