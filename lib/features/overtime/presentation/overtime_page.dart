import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/ui/app_segmented_tab_bar.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
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
        var pQuery = _client.from('overtime_requests').select();
        if (_tenantId != null && _tenantId!.isNotEmpty) pQuery = pQuery.eq('tenant_id', _tenantId!);
        final pendingRes = await pQuery.order('created_at', ascending: false).limit(100);
        _pendingRequests = (pendingRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

        var lQuery = _client.from('leave_requests').select();
        if (_tenantId != null && _tenantId!.isNotEmpty) lQuery = lQuery.eq('tenant_id', _tenantId!);
        final allLeaveRes = await lQuery.order('created_at', ascending: false).limit(100);
        _allLeaveRequests = (allLeaveRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

        var sQuery = _client.from('shift_change_requests').select();
        if (_tenantId != null && _tenantId!.isNotEmpty) sQuery = sQuery.eq('tenant_id', _tenantId!);
        final allShiftRes = await sQuery.order('created_at', ascending: false).limit(100);
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
    final currencyFmt = NumberFormat('#,###', 'id_ID');
    final rawRate = AppUi.toNum(req['hourly_rate']);
    
    DateTime selectedDate = DateTime.tryParse(req['overtime_date']?.toString() ?? '') ?? DateTime.now();
    final dateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd').format(selectedDate));
    
    final startCtrl = TextEditingController(text: req['start_time']?.toString() ?? '17:00');
    final endCtrl = TextEditingController(text: req['end_time']?.toString() ?? '19:00');
    final rateCtrl = TextEditingController(text: currencyFmt.format(rawRate > 0 ? rawRate : 25000));
    final reasonCtrl = TextEditingController(text: req['reason']?.toString() ?? '');
    String status = req['status']?.toString().toLowerCase() ?? 'pending';

    double calculateDuration(String sTime, String eTime) {
      try {
        final sParts = sTime.split(':');
        final eParts = eTime.split(':');
        final sMin = int.parse(sParts[0]) * 60 + int.parse(sParts[1]);
        final eMin = int.parse(eParts[0]) * 60 + int.parse(eParts[1]);
        final diff = (eMin - sMin) / 60.0;
        return diff > 0 ? diff : 0;
      } catch (_) {
        return 0;
      }
    }

    double parseRate(String text) {
      final clean = text.replaceAll(RegExp(r'[^0-9]'), '');
      return double.tryParse(clean) ?? 0;
    }

    final updated = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final duration = calculateDuration(startCtrl.text, endCtrl.text);
          final rate = parseRate(rateCtrl.text);
          final totalAmount = duration * rate;

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.edit_calendar_rounded, color: Color(0xFF0284C7), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Edit Pengajuan Lembur',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      Text(
                        AppUi.text(req['user_name']),
                        style: GoogleFonts.inter(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tanggal Picker
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime(2023),
                          lastDate: DateTime.now().add(const Duration(days: 365)),
                        );
                        if (picked != null) {
                          setModalState(() {
                            selectedDate = picked;
                            dateCtrl.text = DateFormat('yyyy-MM-dd').format(picked);
                          });
                        }
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: IgnorePointer(
                        child: TextField(
                          controller: dateCtrl,
                          decoration: InputDecoration(
                            labelText: 'Tanggal Lembur',
                            prefixIcon: const Icon(Icons.calendar_today_rounded, size: 20),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Jam Mulai & Jam Selesai Time Pickers
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final parts = startCtrl.text.split(':');
                              final initial = TimeOfDay(
                                hour: int.tryParse(parts[0]) ?? 17,
                                minute: int.tryParse(parts[1]) ?? 0,
                              );
                              final picked = await showTimePicker(context: context, initialTime: initial);
                              if (picked != null) {
                                setModalState(() {
                                  startCtrl.text =
                                      '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                                });
                              }
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: IgnorePointer(
                              child: TextField(
                                controller: startCtrl,
                                decoration: InputDecoration(
                                  labelText: 'Jam Mulai',
                                  prefixIcon: const Icon(Icons.access_time_rounded, size: 20),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final parts = endCtrl.text.split(':');
                              final initial = TimeOfDay(
                                hour: int.tryParse(parts[0]) ?? 19,
                                minute: int.tryParse(parts[1]) ?? 0,
                              );
                              final picked = await showTimePicker(context: context, initialTime: initial);
                              if (picked != null) {
                                setModalState(() {
                                  endCtrl.text =
                                      '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                                });
                              }
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: IgnorePointer(
                              child: TextField(
                                controller: endCtrl,
                                decoration: InputDecoration(
                                  labelText: 'Jam Selesai',
                                  prefixIcon: const Icon(Icons.access_time_filled_rounded, size: 20),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Tarif Lembur Per Jam (Rp) with Live Currency Formatting
                    TextField(
                      controller: rateCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Tarif Lembur Per Jam',
                        prefixText: 'Rp ',
                        prefixIcon: const Icon(Icons.payments_outlined, size: 20),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      ),
                      onChanged: (val) {
                        final parsed = parseRate(val);
                        final formatted = currencyFmt.format(parsed);
                        if (rateCtrl.text != formatted) {
                          rateCtrl.value = TextEditingValue(
                            text: formatted,
                            selection: TextSelection.collapsed(offset: formatted.length),
                          );
                        }
                        setModalState(() {});
                      },
                    ),
                    const SizedBox(height: 12),

                    // Live Calculation Banner
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.timer_outlined, size: 18, color: Color(0xFF2563EB)),
                              const SizedBox(width: 6),
                              Text(
                                'Durasi: ${duration.toStringAsFixed(1)} Jam',
                                style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          Text(
                            'Rp ${currencyFmt.format(totalAmount)}',
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: const Color(0xFF2563EB),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Status Approval Dropdown
                    DropdownButtonFormField<String>(
                      value: status,
                      decoration: InputDecoration(
                        labelText: 'Status Approval',
                        prefixIcon: const Icon(Icons.verified_outlined, size: 20),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'pending', child: Text('PENDING (Menunggu)')),
                        DropdownMenuItem(value: 'approved', child: Text('APPROVED (Disetujui)')),
                        DropdownMenuItem(value: 'rejected', child: Text('REJECTED (Ditolak)')),
                      ],
                      onChanged: (v) => setModalState(() => status = v ?? status),
                    ),
                    const SizedBox(height: 12),

                    // Alasan
                    TextField(
                      controller: reasonCtrl,
                      minLines: 2,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: 'Alasan Lembur',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Batal'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Simpan Perubahan'),
              ),
            ],
          );
        },
      ),
    );

    if (updated != true) return;

    try {
      final sTime = startCtrl.text.trim();
      final eTime = endCtrl.text.trim();
      final duration = calculateDuration(sTime, eTime);
      final hourlyRate = parseRate(rateCtrl.text.trim());
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
        final Map<String, dynamic> attPayload = {
          'user_id': request['user_id'],
          'user_name': request['user_name'],
          'user_email': request['user_email'],
          'role_id': request['role_id'],
          'date': dateStr,
          'status': request['leave_type'] ?? 'izin',
          'note': 'Izin disetujui: ${request['reason']}',
        };
        final rawTenant = request['tenant_id'] ?? _tenantId;
        if (rawTenant != null && rawTenant.toString().isNotEmpty) {
          attPayload['tenant_id'] = rawTenant;
        }
        await _client.from('attendance').upsert(attPayload, onConflict: 'tenant_id, user_id, date');
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

  Widget _buildEmptyState(String title, String subtitle, IconData icon) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B).withValues(alpha: 0.5) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
          const SizedBox(height: 10),
          Text(
            title,
            style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF334155)),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 12, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }

  Widget _buildCardContainer({required Widget child, EdgeInsetsGeometry? padding}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: padding ?? const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: child,
    );
  }

  // --- LEMBUR TAB ---
  Widget _buildOvertimeFormCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final duration = _calculateDurationHours();
    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.more_time_rounded, color: Color(0xFF3B82F6), size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Form Pengajuan Lembur', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('Ajukan waktu lembur untuk disetujui atasan', style: GoogleFonts.inter(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Date Field (Full width for mobile clarity)
          TextField(
            controller: _dateController,
            readOnly: true,
            onTap: _pickDate,
            decoration: InputDecoration(
              labelText: 'Tanggal Lembur',
              prefixIcon: const Icon(Icons.calendar_today_rounded, size: 20),
              filled: true,
              fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),

          // Start Time & End Time in 2 columns
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startTimeController,
                  readOnly: true,
                  onTap: _pickStartTime,
                  decoration: InputDecoration(
                    labelText: 'Jam Mulai',
                    prefixIcon: const Icon(Icons.access_time_rounded, size: 20),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _endTimeController,
                  readOnly: true,
                  onTap: _pickEndTime,
                  decoration: InputDecoration(
                    labelText: 'Jam Selesai',
                    prefixIcon: const Icon(Icons.access_time_rounded, size: 20),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Duration pill banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.timer_outlined, size: 18, color: Color(0xFF3B82F6)),
                    const SizedBox(width: 6),
                    Text(
                      'Estimasi Durasi: ${duration.toStringAsFixed(1)} Jam',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: isDark ? Colors.white : const Color(0xFF1E3A8A),
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: duration > 0 ? const Color(0xFF10B981).withValues(alpha: 0.2) : Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    duration > 0 ? 'Valid' : 'Pilih Jam',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: duration > 0 ? const Color(0xFF10B981) : Colors.grey,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Reason Field
          TextField(
            controller: _reasonController,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'Alasan / Deskripsi Pekerjaan Lembur',
              hintText: 'Contoh: Packing order event marketplace, stock opname...',
              filled: true,
              fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 16),

          // Submit Button
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _submitOvertime,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: _isSaving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, size: 18),
              label: Text(
                _isSaving ? 'Mengirim...' : 'Kirim Pengajuan Lembur',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyOvertimeList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Riwayat Pengajuan Saya', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF3B82F6).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Text('${_myRequests.length}', style: const TextStyle(color: Color(0xFF3B82F6), fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_myRequests.isEmpty)
          _buildEmptyState('Belum Ada Riwayat Lembur', 'Pengajuan lembur Anda akan muncul di sini setelah dikirim.', Icons.more_time_rounded)
        else
          ..._myRequests.map((req) {
            final status = req['status']?.toString() ?? 'pending';
            final color = _getStatusColor(status);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildCardContainer(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.calendar_today_rounded, size: 15, color: Color(0xFF3B82F6)),
                            const SizedBox(width: 6),
                            Text(
                              '${req['overtime_date']} (${req['start_time']} - ${req['end_time']})',
                              style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                          child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Durasi: ${AppUi.toNum(req['duration_hours']).toStringAsFixed(1)} Jam | Estimasi: Rp ${AppUi.toNum(req['total_amount']).toStringAsFixed(0)}',
                      style: GoogleFonts.inter(fontSize: 13, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 4),
                    Text('Alasan: ${AppUi.text(req['reason'])}', style: GoogleFonts.inter(fontSize: 13)),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildApproverOvertimeList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Daftar Persetujuan Lembur Karyawan', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFF59E0B).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Text('${_pendingRequests.length}', style: const TextStyle(color: Color(0xFFF59E0B), fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_pendingRequests.isEmpty)
          _buildEmptyState('Tidak Ada Pengajuan Lembur', 'Semua pengajuan lembur karyawan sudah diproses.', Icons.task_alt_rounded)
        else
          ..._pendingRequests.map((req) {
            final status = req['status']?.toString() ?? 'pending';
            final color = _getStatusColor(status);
            final isPending = status == 'pending';

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildCardContainer(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${AppUi.text(req['user_name'])} • ${AppUi.text(req['role_id'])}', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 15)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                          child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Tanggal: ${req['overtime_date']} (${req['start_time']} - ${req['end_time']}) | Durasi: ${AppUi.toNum(req['duration_hours']).toStringAsFixed(1)} Jam', style: GoogleFonts.inter(fontSize: 13)),
                    Text('Tarif: Rp ${AppUi.toNum(req['hourly_rate']).toStringAsFixed(0)}/jam | Total: Rp ${AppUi.toNum(req['total_amount']).toStringAsFixed(0)}', style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 13)),
                    Text('Alasan: ${AppUi.text(req['reason'])}', style: GoogleFonts.inter(fontSize: 13)),
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
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.red, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text('Tolak'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _approveOvertime(req),
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
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
      ],
    );
  }

  // --- LEAVE TAB ---
  Widget _buildLeaveFormCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.event_note_rounded, color: Color(0xFF10B981), size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Form Pengajuan Izin / Cuti', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('Ajukan izin sakit, cuti tahunan, atau duka', style: GoogleFonts.inter(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Tipe Izin
          DropdownButtonFormField<String>(
            value: _selectedLeaveType,
            decoration: InputDecoration(
              labelText: 'Tipe Izin',
              filled: true,
              fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
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

          // Tanggal Mulai & Tanggal Selesai
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _leaveStartDateCtrl,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: 'Tanggal Mulai',
                    prefixIcon: const Icon(Icons.calendar_today_rounded, size: 20),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _leaveEndDateCtrl,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: 'Tanggal Selesai',
                    prefixIcon: const Icon(Icons.calendar_today_rounded, size: 20),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'Alasan Izin / Sakit',
              hintText: 'Contoh: Sakit demam tinggi / Keperluan keluarga mendesak...',
              filled: true,
              fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _leaveAttachmentCtrl,
                  decoration: InputDecoration(
                    labelText: 'Lampiran / Surat Dokter',
                    hintText: 'Upload file atau isi link...',
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.attach_file_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _isUploadingAttachment ? null : _pickAndUploadAttachment,
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                ),
                icon: _isUploadingAttachment
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_file_rounded),
                label: Text(_isUploadingAttachment ? 'Upload...' : 'Upload'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _submitLeaveRequest,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: _isSaving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, size: 18),
              label: Text(
                _isSaving ? 'Mengirim...' : 'Kirim Pengajuan Izin',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApproverLeaveList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Daftar Persetujuan Izin Karyawan', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF10B981).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Text('${_allLeaveRequests.length}', style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_allLeaveRequests.isEmpty)
          _buildEmptyState('Belum Ada Pengajuan Izin', 'Semua pengajuan izin karyawan sudah diproses.', Icons.event_available_rounded)
        else
          ..._allLeaveRequests.map((req) {
            final status = req['status']?.toString() ?? 'pending';
            final color = _getStatusColor(status);
            final isPending = status == 'pending';
            final attachUrl = req['attachment_url']?.toString();

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildCardContainer(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${AppUi.text(req['user_name'])} • ${AppUi.text(req['role_id'])}', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 15)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                          child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Tipe: ${req['leave_type']?.toString().toUpperCase()} | Periode: ${req['start_date']} s/d ${req['end_date']} (${req['total_days']} Hari)', style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13)),
                    Text('Alasan: ${AppUi.text(req['reason'])}', style: GoogleFonts.inter(fontSize: 13)),
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
                          tooltip: 'Hapus Pengajuan',
                        ),
                      ],
                    ),
                    if (isPending) ...[
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _rejectLeaveRequest(req),
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.red, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text('Tolak'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _approveLeaveRequest(req),
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
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
      ],
    );
  }

  Widget _buildMyLeaveList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Riwayat Izin Saya', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF10B981).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Text('${_myLeaveRequests.length}', style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_myLeaveRequests.isEmpty)
          _buildEmptyState('Belum Ada Riwayat Izin', 'Pengajuan izin atau cuti Anda akan muncul di sini.', Icons.event_note_rounded)
        else
          ..._myLeaveRequests.map((req) {
            final status = req['status']?.toString() ?? 'pending';
            final color = _getStatusColor(status);
            final attachUrl = req['attachment_url']?.toString();
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildCardContainer(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${req['leave_type']?.toString().toUpperCase()}: ${req['start_date']} s/d ${req['end_date']} (${req['total_days']} Hari)',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                          child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Alasan: ${AppUi.text(req['reason'])}', style: GoogleFonts.inter(fontSize: 13)),
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
              ),
            );
          }),
      ],
    );
  }

  // --- SHIFT CHANGE TAB ---
  Widget _buildShiftChangeFormCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.published_with_changes_rounded, color: Color(0xFF6366F1), size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Form Tukar Shift / Ubah Jam', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('Ajukan pergantian jam kerja pada hari tertentu', style: GoogleFonts.inter(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          TextField(
            controller: _shiftDateCtrl,
            readOnly: true,
            decoration: InputDecoration(
              labelText: 'Tanggal Shift',
              prefixIcon: const Icon(Icons.calendar_today_rounded, size: 20),
              filled: true,
              fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _shiftNewStartCtrl,
                  readOnly: true,
                  onTap: _pickShiftStartTime,
                  decoration: InputDecoration(
                    labelText: 'Jam Mulai Baru',
                    prefixIcon: const Icon(Icons.access_time_rounded, size: 20),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _shiftNewEndCtrl,
                  readOnly: true,
                  onTap: _pickShiftEndTime,
                  decoration: InputDecoration(
                    labelText: 'Jam Selesai Baru',
                    prefixIcon: const Icon(Icons.access_time_rounded, size: 20),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _shiftReasonCtrl,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'Alasan Tukar Shift',
              hintText: 'Contoh: Ada keperluan mendesak pagi hari, jam kerja dialihkan...',
              filled: true,
              fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _submitShiftChangeRequest,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: _isSaving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, size: 18),
              label: Text(
                _isSaving ? 'Mengirim...' : 'Kirim Pengajuan Tukar Shift',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApproverShiftList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Daftar Persetujuan Tukar Shift', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF6366F1).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Text('${_allShiftChangeRequests.length}', style: const TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_allShiftChangeRequests.isEmpty)
          _buildEmptyState('Belum Ada Pengajuan Tukar Shift', 'Semua pengajuan tukar shift sudah diproses.', Icons.published_with_changes_rounded)
        else
          ..._allShiftChangeRequests.map((req) {
            final status = req['status']?.toString() ?? 'pending';
            final color = _getStatusColor(status);
            final isPending = status == 'pending';

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildCardContainer(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${AppUi.text(req['user_name'])} • ${AppUi.text(req['role_id'])}', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 15)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                          child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Tanggal Shift: ${req['shift_date']} | Jam Baru: ${req['new_start_time']} s/d ${req['new_end_time']}', style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13)),
                    Text('Alasan: ${AppUi.text(req['reason'])}', style: GoogleFonts.inter(fontSize: 13)),
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
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.red, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: const Text('Tolak'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _approveShiftChangeRequest(req),
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
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
      ],
    );
  }

  Widget _buildMyShiftList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Riwayat Tukar Shift Saya', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF6366F1).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Text('${_myShiftChangeRequests.length}', style: const TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_myShiftChangeRequests.isEmpty)
          _buildEmptyState('Belum Ada Riwayat Tukar Shift', 'Pengajuan tukar shift Anda akan muncul di sini.', Icons.published_with_changes_rounded)
        else
          ..._myShiftChangeRequests.map((req) {
            final status = req['status']?.toString() ?? 'pending';
            final color = _getStatusColor(status);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildCardContainer(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Shift ${req['shift_date']}: ${req['new_start_time']} - ${req['new_end_time']}', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                          child: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Alasan: ${AppUi.text(req['reason'])}', style: GoogleFonts.inter(fontSize: 13)),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return WebResponsiveScaffold(
      title: 'Lembur & Izin',
      activeWebTitle: 'Pengajuan Lembur, Izin & Tukar Shift',
      body: WebResponsiveWrapper(
        activeTitle: 'Pengajuan Lembur & Izin',
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  const SizedBox(height: 8),
                  AppSegmentedTabBar(
                    controller: _tabController,
                    maxWidth: 560,
                    tabs: const [
                      AppTabItem(label: 'Lembur', icon: Icons.more_time_rounded),
                      AppTabItem(label: 'Izin & Sakit', icon: Icons.event_note_rounded),
                      AppTabItem(label: 'Tukar Shift', icon: Icons.published_with_changes_rounded),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // Tab Views
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final isWide = constraints.maxWidth >= 900;
                        return TabBarView(
                          controller: _tabController,
                          children: [
                            // Tab 1: Lembur
                            SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 1200),
                                  child: isWide
                                      ? Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            SizedBox(width: 440, child: _buildOvertimeFormCard()),
                                            const SizedBox(width: 20),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  if (_isApprover) ...[
                                                    _buildApproverOvertimeList(),
                                                    const SizedBox(height: 24),
                                                  ],
                                                  _buildMyOvertimeList(),
                                                ],
                                              ),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            _buildOvertimeFormCard(),
                                            const SizedBox(height: 20),
                                            _buildMyOvertimeList(),
                                            if (_isApprover) ...[
                                              const SizedBox(height: 20),
                                              _buildApproverOvertimeList(),
                                            ],
                                          ],
                                        ),
                                ),
                              ),
                            ),

                            // Tab 2: Izin & Sakit
                            SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 1200),
                                  child: isWide
                                      ? Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            SizedBox(width: 440, child: _buildLeaveFormCard()),
                                            const SizedBox(width: 20),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  if (_isApprover) ...[
                                                    _buildApproverLeaveList(),
                                                    const SizedBox(height: 24),
                                                  ],
                                                  _buildMyLeaveList(),
                                                ],
                                              ),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            _buildLeaveFormCard(),
                                            const SizedBox(height: 20),
                                            _buildMyLeaveList(),
                                            if (_isApprover) ...[
                                              const SizedBox(height: 20),
                                              _buildApproverLeaveList(),
                                            ],
                                          ],
                                        ),
                                ),
                              ),
                            ),

                            // Tab 3: Tukar Shift
                            SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 1200),
                                  child: isWide
                                      ? Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            SizedBox(width: 440, child: _buildShiftChangeFormCard()),
                                            const SizedBox(width: 20),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  if (_isApprover) ...[
                                                    _buildApproverShiftList(),
                                                    const SizedBox(height: 24),
                                                  ],
                                                  _buildMyShiftList(),
                                                ],
                                              ),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            _buildShiftChangeFormCard(),
                                            const SizedBox(height: 20),
                                            _buildMyShiftList(),
                                            if (_isApprover) ...[
                                              const SizedBox(height: 20),
                                              _buildApproverShiftList(),
                                            ],
                                          ],
                                        ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
