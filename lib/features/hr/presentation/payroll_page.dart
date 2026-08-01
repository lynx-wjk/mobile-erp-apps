import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_roles.dart';
import '../../../core/ui/app_ui.dart';

class PayrollPage extends StatefulWidget {
  const PayrollPage({super.key});

  @override
  State<PayrollPage> createState() => _PayrollPageState();
}

class _PayrollPageState extends State<PayrollPage> with SingleTickerProviderStateMixin {
  final _supabase = Supabase.instance.client;
  late TabController _tabController;
  bool _isLoading = true;
  String _userRole = '';
  String _tenantId = '';
  List<Map<String, dynamic>> _activeUsers = [];
  List<Map<String, dynamic>> _payrollHistory = [];

  // Company Settings
  Map<String, dynamic> _companySettings = {
    'company_name': 'HAI INVENTORY & APPAREL',
    'company_address': 'Jl. Raya Industri Kebon Jeruk No. 88, Jakarta Barat',
    'company_phone': '+62 812-9988-7766',
    'company_email': 'finance@mdhproduction.com',
    'logo_url': '',
    'signatory_name': 'Finance Manager',
    'signatory_title': 'Manager Keuangan & HR',
  };

  // Form Fields
  Map<String, dynamic>? _selectedUser;
  final _nikController = TextEditingController();
  final _bankNameController = TextEditingController(text: 'BCA');
  final _bankNumberController = TextEditingController();
  final _bankHolderController = TextEditingController();
  final _invoiceNumberController = TextEditingController();

  DateTime _selectedPeriod = DateTime.now();
  bool _autoSaveProfile = true;

  // Earnings
  final _baseSalaryController = TextEditingController(text: '0');
  final _allowancePosController = TextEditingController(text: '0');
  final _allowanceMealTransController = TextEditingController(text: '0');
  final _bonusController = TextEditingController(text: '0');
  final _annualBonusController = TextEditingController(text: '0');
  final _overtimeController = TextEditingController(text: '0');

  // Deductions
  final _bpjsController = TextEditingController(text: '0');
  final _latePenaltyController = TextEditingController(text: '0');
  final _absentDeductionController = TextEditingController(text: '0');
  final _loanController = TextEditingController(text: '0');
  final _taxController = TextEditingController(text: '0');

  final _notesController = TextEditingController();

  String _selectedSalaryType = 'monthly';
  final _dailyRateController = TextEditingController(text: '0');
  final _hourlyRateController = TextEditingController(text: '0');
  final _latePenaltyRateController = TextEditingController(text: '0');
  final _absentPenaltyRateController = TextEditingController(text: '0');

  final _currencyFormat = NumberFormat.currency(locale: 'id', symbol: 'Rp ', decimalDigits: 0);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadInitialData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nikController.dispose();
    _bankNameController.dispose();
    _bankNumberController.dispose();
    _bankHolderController.dispose();
    _invoiceNumberController.dispose();
    _baseSalaryController.dispose();
    _allowancePosController.dispose();
    _allowanceMealTransController.dispose();
    _bonusController.dispose();
    _annualBonusController.dispose();
    _overtimeController.dispose();
    _bpjsController.dispose();
    _latePenaltyController.dispose();
    _absentDeductionController.dispose();
    _loanController.dispose();
    _taxController.dispose();
    _dailyRateController.dispose();
    _hourlyRateController.dispose();
    _latePenaltyRateController.dispose();
    _absentPenaltyRateController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      final user = _supabase.auth.currentUser;
      if (user != null) {
        final profile = await _supabase.from('users').select('role_id, tenant_id').eq('user_id', user.id).maybeSingle();
        if (profile != null) {
          _userRole = AppUi.text(profile['role_id']).toLowerCase();
          _tenantId = AppUi.text(profile['tenant_id']);
        }
      }

      // 1. Fetch Company Settings
      if (_tenantId.isNotEmpty) {
        final settingsRes = await _supabase.from('payroll_company_settings').select().eq('tenant_id', _tenantId).maybeSingle();
        if (settingsRes != null) {
          _companySettings = Map<String, dynamic>.from(settingsRes);
        }

        // 2. Fetch Active Users
        final usersRes = await _supabase.from('users').select('user_id, nama, email, role_id, nomor_hp, status').eq('tenant_id', _tenantId);
        _activeUsers = List<Map<String, dynamic>>.from(usersRes.where((u) {
          final role = AppUi.text(u['role_id']).toLowerCase();
          final status = AppUi.text(u['status']).toLowerCase();
          return status == 'active' && role != 'platform_owner';
        }));

        // 3. Fetch Payroll History
        await _fetchPayrollHistory();
      }

      _generateNewInvoiceNumber();
    } catch (e) {
      debugPrint('Error loading payroll data: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchPayrollHistory() async {
    if (_tenantId.isEmpty) return;
    final res = await _supabase.from('payroll_invoices').select().eq('tenant_id', _tenantId).order('created_at', ascending: false).limit(50);
    _payrollHistory = List<Map<String, dynamic>>.from(res);
  }

  void _generateNewInvoiceNumber() {
    final periodStr = DateFormat('yyyyMM').format(_selectedPeriod);
    final count = _payrollHistory.length + 1;
    final seq = count.toString().padLeft(4, '0');
    _invoiceNumberController.text = 'SLP-$periodStr-$seq';
  }

  Future<void> _onSelectUser(Map<String, dynamic>? user) async {
    setState(() => _selectedUser = user);
    if (user == null || _tenantId.isEmpty) return;

    _bankHolderController.text = user['nama'] ?? '';

    // Check saved employee payroll profile
    try {
      final profileRes = await _supabase
          .from('user_payroll_profiles')
          .select()
          .eq('tenant_id', _tenantId)
          .eq('user_id', user['user_id'])
          .maybeSingle();

      if (profileRes != null) {
        setState(() {
          _nikController.text = profileRes['nik'] ?? '';
          _bankNameController.text = AppUi.text(profileRes['bank_name'], 'BCA');
          _bankNumberController.text = profileRes['bank_account_number'] ?? '';
          _bankHolderController.text = AppUi.text(profileRes['bank_account_holder'], user['nama']);
          _baseSalaryController.text = _formatNumber(profileRes['base_salary']);
          _allowancePosController.text = _formatNumber(profileRes['allowance_position']);
          _allowanceMealTransController.text = _formatNumber(profileRes['allowance_meal_transport']);
          _selectedSalaryType = profileRes['salary_type']?.toString() ?? 'monthly';
          _dailyRateController.text = _formatNumber(profileRes['daily_rate']);
          _hourlyRateController.text = _formatNumber(profileRes['hourly_rate']);
          _latePenaltyRateController.text = _formatNumber(profileRes['late_penalty_per_minute']);
          _absentPenaltyRateController.text = _formatNumber(profileRes['absent_penalty_per_day']);
          _notesController.text = profileRes['notes'] ?? '';
        });

        await _autoCalculatePayrollForPeriod();
      }
    } catch (e) {
      debugPrint('Error loading user profile: $e');
    }
  }

  Future<void> _autoCalculatePayrollForPeriod() async {
    if (_selectedUser == null || _tenantId.isEmpty) return;
    final userId = _selectedUser!['user_id'];
    final year = _selectedPeriod.year;
    final month = _selectedPeriod.month;
    final firstDayStr = '$year-${month.toString().padLeft(2, '0')}-01';
    final lastDay = DateTime(year, month + 1, 0).day;
    final lastDayStr = '$year-${month.toString().padLeft(2, '0')}-${lastDay.toString().padLeft(2, '0')}';

    try {
      final profileRes = await _supabase
          .from('user_payroll_profiles')
          .select()
          .eq('tenant_id', _tenantId)
          .eq('user_id', userId)
          .maybeSingle();

      final salaryType = profileRes?['salary_type']?.toString() ?? _selectedSalaryType;
      final baseSal = AppUi.toNum(profileRes?['base_salary']).toDouble();
      final dailyRate = AppUi.toNum(profileRes?['daily_rate']).toDouble();
      final hourlyRate = AppUi.toNum(profileRes?['hourly_rate']).toDouble();
      final lateRate = AppUi.toNum(profileRes?['late_penalty_per_minute']).toDouble();
      final absentRate = AppUi.toNum(profileRes?['absent_penalty_per_day']).toDouble();

      // 1. Overtime calculation
      final overtimeRes = await _supabase
          .from('overtime_requests')
          .select('total_amount')
          .eq('user_id', userId)
          .eq('status', 'approved')
          .gte('overtime_date', firstDayStr)
          .lte('overtime_date', lastDayStr);
      double totalOvertime = 0;
      for (final r in (overtimeRes as List)) {
        totalOvertime += AppUi.toNum(r['total_amount']).toDouble();
      }

      // 2. Attendance & Excused/Permit Days Calculation
      final attRes = await _supabase
          .from('attendance')
          .select('date, check_in_time, status, notes')
          .eq('user_id', userId)
          .gte('date', firstDayStr)
          .lte('date', lastDayStr);
      final attList = (attRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

      // 2b. Approved Leave/Sick Requests Calculation
      final leaveRes = await _supabase
          .from('leave_requests')
          .select('start_date, end_date, total_days, leave_type')
          .eq('user_id', userId)
          .eq('status', 'approved')
          .gte('start_date', firstDayStr)
          .lte('start_date', lastDayStr);
      final leaveList = (leaveRes as List).map((e) => Map<String, dynamic>.from(e)).toList();

      int approvedLeaveDays = 0;
      for (final l in leaveList) {
        approvedLeaveDays += AppUi.toNum(l['total_days']).toInt();
      }

      int presentDays = 0;
      int excusedDays = 0;
      for (final a in attList) {
        final statusStr = (a['status'] ?? '').toString().toLowerCase();
        final notesStr = (a['notes'] ?? '').toString().toLowerCase();

        final isExcused = statusStr.contains('sakit') ||
            statusStr.contains('izin') ||
            statusStr.contains('cuti') ||
            statusStr.contains('paid_leave') ||
            notesStr.contains('sakit') ||
            notesStr.contains('izin') ||
            notesStr.contains('cuti');

        if (isExcused) {
          excusedDays++;
        } else if (a['check_in_time'] != null) {
          presentDays++;
        }
      }

      final effectiveExcusedDays = excusedDays > approvedLeaveDays ? excusedDays : approvedLeaveDays;
      final totalPayableDays = presentDays + effectiveExcusedDays;

      // 3. Approved Shift Change Requests for the month
      final shiftChangeRes = await _supabase
          .from('shift_change_requests')
          .select('shift_date, new_start_time, new_end_time')
          .eq('user_id', userId)
          .eq('status', 'approved')
          .gte('shift_date', firstDayStr)
          .lte('shift_date', lastDayStr);
      final shiftChangeMap = <String, String>{};
      for (final sc in (shiftChangeRes as List)) {
        if (sc['shift_date'] != null && sc['new_start_time'] != null) {
          shiftChangeMap[sc['shift_date'].toString()] = sc['new_start_time'].toString();
        }
      }

      // 4. Work Schedule & Late Minutes Calculation
      final schedRes = await _supabase
          .from('user_work_schedules')
          .select('day_of_week, start_time, late_tolerance_minutes, is_active')
          .eq('user_id', userId);
      final schedList = (schedRes as List).map((e) => Map<String, dynamic>.from(e)).toList();
      final activeDays = schedList.where((s) => s['is_active'] == true).map((s) => s['day_of_week']).toSet();

      int lateMinutesTotal = 0;
      for (final a in attList) {
        if (a['check_in_time'] != null && a['date'] != null) {
          try {
            final dt = DateTime.parse(a['check_in_time']).toUtc().add(const Duration(hours: 7));
            final dateStr = a['date']?.toString() ?? DateFormat('yyyy-MM-dd').format(dt);
            final dayOfWeek = dt.weekday == 7 ? 0 : dt.weekday;
            final matchSched = schedList.firstWhere((s) => s['day_of_week'] == dayOfWeek, orElse: () => {});

            String startTimeStr = '';
            if (shiftChangeMap.containsKey(dateStr)) {
              startTimeStr = shiftChangeMap[dateStr]!;
            } else if (matchSched.isNotEmpty && matchSched['start_time'] != null) {
              startTimeStr = matchSched['start_time'].toString();
            }

            if (startTimeStr.isNotEmpty) {
              final parts = startTimeStr.split(':');
              final schedStartMin = int.parse(parts[0]) * 60 + int.parse(parts[1]);
              final checkInMin = dt.hour * 60 + dt.minute;
              final tolerance = (matchSched['late_tolerance_minutes'] ?? 15) as int;
              if (checkInMin > (schedStartMin + tolerance)) {
                lateMinutesTotal += (checkInMin - (schedStartMin + tolerance));
              }
            }
          } catch (_) {}
        }
      }

      int totalScheduledWorkdays = 0;
      for (int d = 1; d <= lastDay; d++) {
        final date = DateTime(year, month, d);
        final dow = date.weekday == 7 ? 0 : date.weekday;
        if (activeDays.isNotEmpty) {
          if (activeDays.contains(dow)) totalScheduledWorkdays++;
        } else {
          if (dow >= 1 && dow <= 6) totalScheduledWorkdays++;
        }
      }

      int absentDays = 0;
      double finalBaseSalary = baseSal;
      double totalAbsentDeduction = 0;

      if (salaryType == 'daily') {
        finalBaseSalary = totalPayableDays * dailyRate;
        totalAbsentDeduction = 0;
      } else if (salaryType == 'hourly') {
        finalBaseSalary = (totalPayableDays * 8) * hourlyRate;
        totalAbsentDeduction = 0;
      } else {
        absentDays = (totalScheduledWorkdays - totalPayableDays) > 0 ? (totalScheduledWorkdays - totalPayableDays) : 0;
        totalAbsentDeduction = absentDays * absentRate;
      }

      final totalLatePenalty = lateMinutesTotal * lateRate;

      setState(() {
        _baseSalaryController.text = _formatNumber(finalBaseSalary);
        _overtimeController.text = _formatNumber(totalOvertime);
        _latePenaltyController.text = _formatNumber(totalLatePenalty);
        _absentDeductionController.text = _formatNumber(totalAbsentDeduction);
      });

      AppUi.showSnack('Kalkulasi otomatis selesai: $presentDays masukan, $excusedDays izin/sakit, $absentDays absen, $lateMinutesTotal mnt telat, lembur Rp ${_formatNumber(totalOvertime)}');
    } catch (e) {
      debugPrint('Error auto-calculating payroll: $e');
    }
  }

  void _showPayrollConfigModal(Map<String, dynamic> user) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Container(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Konfigurasi Tarif & Tipe Gaji',
                    style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Karyawan: ${user['nama']} (${AppUi.text(user['role_id'])})',
                    style: GoogleFonts.inter(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: _selectedSalaryType,
                    decoration: const InputDecoration(
                      labelText: 'Tipe Gaji Utama',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'monthly', child: Text('Bulanan (Gaji Pokok Bulanan)')),
                      DropdownMenuItem(value: 'daily', child: Text('Harian (Per Hari Masuk)')),
                      DropdownMenuItem(value: 'hourly', child: Text('Per Jam (Per Jam Kerja)')),
                    ],
                    onChanged: (val) {
                      setModalState(() => _selectedSalaryType = val ?? 'monthly');
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_selectedSalaryType == 'daily') ...[
                    _buildTextField(context, 'Tarif Gaji Per Hari (Rp/Hari)', _dailyRateController, isCurrency: true),
                    const SizedBox(height: 12),
                  ] else if (_selectedSalaryType == 'hourly') ...[
                    _buildTextField(context, 'Tarif Gaji Per Jam (Rp/Jam)', _hourlyRateController, isCurrency: true),
                    const SizedBox(height: 12),
                  ],
                  _buildTextField(context, 'Denda Keterlambatan Per Menit (Rp/Menit)', _latePenaltyRateController, isCurrency: true),
                  const SizedBox(height: 12),
                  _buildTextField(context, 'Potongan Tidak Hadir Per Hari (Rp/Hari)', _absentPenaltyRateController, isCurrency: true),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        try {
                          await _supabase.from('user_payroll_profiles').upsert({
                            'tenant_id': _tenantId,
                            'user_id': user['user_id'],
                            'salary_type': _selectedSalaryType,
                            'daily_rate': _parseVal(_dailyRateController),
                            'hourly_rate': _parseVal(_hourlyRateController),
                            'late_penalty_per_minute': _parseVal(_latePenaltyRateController),
                            'absent_penalty_per_day': _parseVal(_absentPenaltyRateController),
                            'updated_at': DateTime.now().toIso8601String(),
                          }, onConflict: 'tenant_id, user_id');
                          Navigator.pop(ctx);
                          AppUi.showSnack('Tarif & Tipe Gaji ${user['nama']} berhasil disimpan!');
                        } catch (e) {
                          AppUi.showSnack('Gagal menyimpan profil tarif: $e');
                        }
                      },
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('Simpan Pengaturan Tarif'),
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

  String _formatNumber(dynamic val) {
    if (val == null) return '0';
    final clean = val.toString().replaceAll(RegExp(r'[^\d]'), '');
    if (clean.isEmpty) return '0';
    final numVal = int.tryParse(clean) ?? 0;
    return NumberFormat('#,##0', 'id_ID').format(numVal);
  }

  void _formatCurrencyController(TextEditingController controller, String value) {
    final clean = value.replaceAll(RegExp(r'[^\d]'), '');
    if (clean.isEmpty) {
      controller.value = const TextEditingValue(
        text: '0',
        selection: TextSelection.collapsed(offset: 1),
      );
      return;
    }
    final numVal = int.tryParse(clean) ?? 0;
    final formatted = NumberFormat('#,##0', 'id_ID').format(numVal);

    if (controller.text != formatted) {
      controller.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    }
  }

  double _parseVal(TextEditingController ctrl) {
    final clean = ctrl.text.replaceAll(RegExp(r'[^\d]'), '');
    return double.tryParse(clean) ?? 0.0;
  }

  double get _totalEarnings {
    return _parseVal(_baseSalaryController) +
        _parseVal(_allowancePosController) +
        _parseVal(_allowanceMealTransController) +
        _parseVal(_bonusController) +
        _parseVal(_annualBonusController) +
        _parseVal(_overtimeController);
  }

  double get _totalDeductions {
    return _parseVal(_bpjsController) +
        _parseVal(_latePenaltyController) +
        _parseVal(_absentDeductionController) +
        _parseVal(_loanController) +
        _parseVal(_taxController);
  }

  double get _netSalary => _totalEarnings - _totalDeductions;

  String get _pdfFileName {
    final cleanName = AppUi.text(_selectedUser?['nama'], 'Karyawan').replaceAll(RegExp(r'\s+'), '');
    final cleanRole = AppUi.text(_selectedUser?['role_id'], 'Staff').replaceAll(RegExp(r'\s+'), '');
    final period = DateFormat('MMMM_yyyy').format(_selectedPeriod);
    return '${cleanName}_${cleanRole}_${period}Slip.pdf';
  }

  Future<void> _saveAndGeneratePdf() async {

    if (_selectedUser == null) {
      AppUi.showSnack('Pilih karyawan terlebih dahulu');
      return;
    }

    try {
      setState(() => _isLoading = true);

      final userId = _selectedUser!['user_id'];
      final employeeName = AppUi.text(_selectedUser!['nama']);
      final employeeRole = AppUi.text(_selectedUser!['role_id']);
      final periodLabel = DateFormat('MMMM yyyy').format(_selectedPeriod);

      // 1. Auto-save employee profile if enabled
      if (_autoSaveProfile && _tenantId.isNotEmpty) {
        await _supabase.from('user_payroll_profiles').upsert({
          'tenant_id': _tenantId,
          'user_id': userId,
          'nik': _nikController.text.trim(),
          'bank_name': _bankNameController.text.trim(),
          'bank_account_number': _bankNumberController.text.trim(),
          'bank_account_holder': _bankHolderController.text.trim(),
          'base_salary': _parseVal(_baseSalaryController),
          'allowance_position': _parseVal(_allowancePosController),
          'allowance_meal_transport': _parseVal(_allowanceMealTransController),
          'notes': _notesController.text.trim(),
          'updated_at': DateTime.now().toIso8601String(),
        }, onConflict: 'tenant_id, user_id');
      }

      // 2. Build Earnings & Deductions JSON
      final earningsList = [
        if (_parseVal(_baseSalaryController) > 0) {'title': 'Gaji Pokok', 'amount': _parseVal(_baseSalaryController)},
        if (_parseVal(_allowancePosController) > 0) {'title': 'Tunjangan Jabatan', 'amount': _parseVal(_allowancePosController)},
        if (_parseVal(_allowanceMealTransController) > 0) {'title': 'Tunjangan Makan & Transport', 'amount': _parseVal(_allowanceMealTransController)},
        if (_parseVal(_bonusController) > 0) {'title': 'Bonus Kinerja', 'amount': _parseVal(_bonusController)},
        if (_parseVal(_annualBonusController) > 0) {'title': 'Bonus Tahunan', 'amount': _parseVal(_annualBonusController)},
        if (_parseVal(_overtimeController) > 0) {'title': 'Uang Lembur', 'amount': _parseVal(_overtimeController)},
      ];

      final deductionsList = [
        if (_parseVal(_bpjsController) > 0) {'title': 'Potongan BPJS', 'amount': _parseVal(_bpjsController)},
        if (_parseVal(_latePenaltyController) > 0) {'title': 'Denda Keterlambatan', 'amount': _parseVal(_latePenaltyController)},
        if (_parseVal(_absentDeductionController) > 0) {'title': 'Tidak Hadir', 'amount': _parseVal(_absentDeductionController)},
        if (_parseVal(_loanController) > 0) {'title': 'Potongan Kasbon', 'amount': _parseVal(_loanController)},
        if (_parseVal(_taxController) > 0) {'title': 'PPh 21', 'amount': _parseVal(_taxController)},
      ];

      // 3. Generate PDF Bytes
      final pdfBytes = await _buildPdfDocument();

      // 4. Upload to Supabase Storage
      final fileName = _pdfFileName;
      final storagePath = '$_tenantId/$fileName';


      await _supabase.storage.from('payroll_invoices').uploadBinary(
        storagePath,
        pdfBytes,
        fileOptions: const FileOptions(upsert: true, contentType: 'application/pdf'),
      );

      final pdfUrl = _supabase.storage.from('payroll_invoices').getPublicUrl(storagePath);

      // 5. Insert Record to Database
      await _supabase.from('payroll_invoices').insert({
        'tenant_id': _tenantId,
        'invoice_number': _invoiceNumberController.text.trim(),
        'user_id': userId,
        'employee_name': employeeName,
        'employee_role': employeeRole,
        'employee_nik': _nikController.text.trim(),
        'period_month': _selectedPeriod.month,
        'period_year': _selectedPeriod.year,
        'period_label': periodLabel,
        'bank_name': _bankNameController.text.trim(),
        'bank_account_number': _bankNumberController.text.trim(),
        'bank_account_holder': _bankHolderController.text.trim(),
        'earnings_json': earningsList,
        'deductions_json': deductionsList,
        'total_earnings': _totalEarnings,
        'total_deductions': _totalDeductions,
        'net_salary': _netSalary,
        'pdf_storage_path': storagePath,
        'pdf_url': pdfUrl,
        'status': 'generated',
      });

      await _fetchPayrollHistory();
      _generateNewInvoiceNumber();

      AppUi.showSnack('Slip gaji $employeeName berhasil disimpan & PDF dibuat!');
    } catch (e) {
      AppUi.showSnack('Gagal membuat slip gaji: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<Uint8List> _buildPdfDocument() async {
    final pdf = pw.Document();
    final periodLabel = DateFormat('MMMM yyyy').format(_selectedPeriod);

    final earnings = [
      if (_parseVal(_baseSalaryController) > 0) ['Gaji Pokok', _currencyFormat.format(_parseVal(_baseSalaryController))],
      if (_parseVal(_allowancePosController) > 0) ['Tunjangan Jabatan', _currencyFormat.format(_parseVal(_allowancePosController))],
      if (_parseVal(_allowanceMealTransController) > 0) ['Tunjangan Makan & Transport', _currencyFormat.format(_parseVal(_allowanceMealTransController))],
      if (_parseVal(_bonusController) > 0) ['Bonus Kinerja', _currencyFormat.format(_parseVal(_bonusController))],
      if (_parseVal(_annualBonusController) > 0) ['Bonus Tahunan', _currencyFormat.format(_parseVal(_annualBonusController))],
      if (_parseVal(_overtimeController) > 0) ['Uang Lembur', _currencyFormat.format(_parseVal(_overtimeController))],
    ];

    final deductions = [
      if (_parseVal(_bpjsController) > 0) ['Potongan BPJS', _currencyFormat.format(_parseVal(_bpjsController))],
      if (_parseVal(_latePenaltyController) > 0) ['Denda Keterlambatan', _currencyFormat.format(_parseVal(_latePenaltyController))],
      if (_parseVal(_absentDeductionController) > 0) ['Tidak Hadir', _currencyFormat.format(_parseVal(_absentDeductionController))],
      if (_parseVal(_loanController) > 0) ['Potongan Kasbon', _currencyFormat.format(_parseVal(_loanController))],
      if (_parseVal(_taxController) > 0) ['PPh 21', _currencyFormat.format(_parseVal(_taxController))],
    ];

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 36),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Company Header
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(_companySettings['company_name'] ?? 'HAI INVENTORY', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 4),
                      pw.Text(_companySettings['company_address'] ?? '', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                      pw.Text('${_companySettings['company_phone'] ?? ''}   |   ${_companySettings['company_email'] ?? ''}', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Container(
                        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: pw.BoxDecoration(color: PdfColors.blue900, borderRadius: pw.BorderRadius.circular(4)),
                        child: pw.Text('SLIP GAJI', style: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 12)),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text('No: ${_invoiceNumberController.text}', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey800)),
                      pw.Text('Periode: $periodLabel', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 14),
              pw.Divider(thickness: 1, color: PdfColors.grey400),
              pw.SizedBox(height: 12),

              // Employee Metadata Grid
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(color: PdfColors.grey100, borderRadius: pw.BorderRadius.circular(6)),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Nama Karyawan: ${_selectedUser?['nama'] ?? '-'}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
                        pw.SizedBox(height: 2),
                        pw.Text('Role / Jabatan: ${AppUi.text(_selectedUser?['role_id'])}', style: const pw.TextStyle(fontSize: 10)),
                        pw.Text('NIK / NIP: ${_nikController.text.isEmpty ? '-' : _nikController.text}', style: const pw.TextStyle(fontSize: 10)),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('Bank: ${_bankNameController.text}', style: const pw.TextStyle(fontSize: 10)),
                        pw.Text('No. Rekening: ${_bankNumberController.text}', style: const pw.TextStyle(fontSize: 10)),
                        pw.Text('Atas Nama: ${_bankHolderController.text}', style: const pw.TextStyle(fontSize: 10)),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 14),

              // Earnings & Deductions Tables
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  // Pendapatan
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Container(
                          width: double.infinity,
                          padding: const pw.EdgeInsets.all(6),
                          color: PdfColors.green100,
                          child: pw.Text('PENDAPATAN', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11, color: PdfColors.green900)),
                        ),
                        pw.SizedBox(height: 6),
                        ...earnings.map((e) => pw.Padding(
                              padding: const pw.EdgeInsets.symmetric(vertical: 3),
                              child: pw.Row(
                                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                children: [
                                  pw.Text(e[0], style: const pw.TextStyle(fontSize: 10)),
                                  pw.Text(e[1], style: const pw.TextStyle(fontSize: 10)),
                                ],
                              ),
                            )),
                        pw.Divider(color: PdfColors.grey300),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('Total Pendapatan', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                            pw.Text(_currencyFormat.format(_totalEarnings), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColors.green900)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 16),

                  // Potongan
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Container(
                          width: double.infinity,
                          padding: const pw.EdgeInsets.all(6),
                          color: PdfColors.red100,
                          child: pw.Text('POTONGAN', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11, color: PdfColors.red900)),
                        ),
                        pw.SizedBox(height: 6),
                        ...deductions.map((e) => pw.Padding(
                              padding: const pw.EdgeInsets.symmetric(vertical: 3),
                              child: pw.Row(
                                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                children: [
                                  pw.Text(e[0], style: const pw.TextStyle(fontSize: 10)),
                                  pw.Text(e[1], style: const pw.TextStyle(fontSize: 10)),
                                ],
                              ),
                            )),
                        pw.Divider(color: PdfColors.grey300),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('Total Potongan', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                            pw.Text(_currencyFormat.format(_totalDeductions), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColors.red900)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              pw.SizedBox(height: 16),

              // Net Take Home Pay Banner
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: PdfColors.blue50,
                  border: pw.Border.all(color: PdfColors.blue800, width: 1.5),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('PENERIMAAN BERSIH (TAKE HOME PAY)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11, color: PdfColors.blue900)),
                    pw.Text(_currencyFormat.format(_netSalary), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13, color: PdfColors.blue900)),
                  ],
                ),
              ),

              pw.SizedBox(height: 36),

              // Signatures
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.Text('Penerima,', style: const pw.TextStyle(fontSize: 10)),
                      pw.SizedBox(height: 45),
                      pw.Text(_selectedUser?['nama'] ?? '-', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.Text('${_companySettings['signatory_title'] ?? 'Finance Manager'},', style: const pw.TextStyle(fontSize: 10)),
                      pw.SizedBox(height: 45),
                      pw.Text(_companySettings['signatory_name'] ?? 'Manager', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 20),
              pw.Center(
                child: pw.Text('Dokumen ini dibuat otomatis oleh Sistem ERP & bersifat rahasia.', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
              ),
            ],
          );
        },

      ),
    );

    return pdf.save();
  }

  void _shareViaWhatsApp(Map<String, dynamic> inv) async {
    final phone = inv['employee_phone'] ?? _selectedUser?['nomor_hp'] ?? '';
    final name = inv['employee_name'] ?? _selectedUser?['nama'] ?? 'Karyawan';
    final period = inv['period_label'] ?? DateFormat('MMMM yyyy').format(_selectedPeriod);
    final net = _currencyFormat.format(inv['net_salary'] ?? _netSalary);
    final invNum = inv['invoice_number'] ?? _invoiceNumberController.text;
    final pdfUrl = inv['pdf_url'] ?? '';

    final message = '''
Halo *$name*,

Berikut kami sampaikan rincian *Slip Gaji Periode $period*:

📄 No. Slip: *$invNum*
💰 Penerimaan Bersih: *$net*
📌 Link Download PDF: $pdfUrl

Terima kasih atas kerja keras dan kontribusinya!
Salam,
*${_companySettings['company_name']}*
''';

    final cleanPhone = phone.replaceAll(RegExp(r'[^\d]'), '');
    final waUrl = Uri.parse('https://wa.me/$cleanPhone?text=${Uri.encodeComponent(message)}');

    if (await canLaunchUrl(waUrl)) {
      await launchUrl(waUrl, mode: LaunchMode.externalApplication);
      await _updateInvoiceStatus(invNum, 'sent_wa');
    } else {
      AppUi.showSnack('Tidak dapat membuka WhatsApp');
    }
  }

  void _shareViaEmail(Map<String, dynamic> inv) async {
    final email = inv['employee_email'] ?? _selectedUser?['email'] ?? '';
    final name = inv['employee_name'] ?? _selectedUser?['nama'] ?? 'Karyawan';
    final period = inv['period_label'] ?? DateFormat('MMMM yyyy').format(_selectedPeriod);
    final net = _currencyFormat.format(inv['net_salary'] ?? _netSalary);
    final invNum = inv['invoice_number'] ?? _invoiceNumberController.text;
    final pdfUrl = inv['pdf_url'] ?? '';

    final subject = 'Slip Gaji Periode $period - $name ($invNum)';
    final body = '''
Yth. $name,

Berikut rincian Slip Gaji Anda untuk periode $period:

No. Slip: $invNum
Penerimaan Bersih (Take Home Pay): $net
Download PDF: $pdfUrl

Salam hangat,
Team Finance & HR ${_companySettings['company_name']}
''';

    final mailUrl = Uri.parse('mailto:$email?subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}');

    if (await canLaunchUrl(mailUrl)) {
      await launchUrl(mailUrl);
      await _updateInvoiceStatus(invNum, 'sent_email');
    } else {
      AppUi.showSnack('Tidak dapat membuka aplikasi email');
    }
  }

  Future<void> _updateInvoiceStatus(String invoiceNumber, String status) async {
    if (_tenantId.isEmpty) return;
    await _supabase.from('payroll_invoices').update({'status': status}).eq('tenant_id', _tenantId).eq('invoice_number', invoiceNumber);
    await _fetchPayrollHistory();
  }

  void _openCompanySettingsModal() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final nameCtrl = TextEditingController(text: _companySettings['company_name']);
    final addrCtrl = TextEditingController(text: _companySettings['company_address']);
    final phoneCtrl = TextEditingController(text: _companySettings['company_phone']);
    final emailCtrl = TextEditingController(text: _companySettings['company_email']);
    final logoCtrl = TextEditingController(text: _companySettings['logo_url']);
    final signNameCtrl = TextEditingController(text: _companySettings['signatory_name']);
    final signTitleCtrl = TextEditingController(text: _companySettings['signatory_title']);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 20, spreadRadius: 5),
            ],
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            top: 20,
            left: 20,
            right: 20,
          ),
          child: StatefulBuilder(
            builder: (modalCtx, setModalState) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Pengaturan Branding & Perusahaan',
                            style: GoogleFonts.outfit(color: isDark ? Colors.white : const Color(0xFF0F172A), fontSize: 18, fontWeight: FontWeight.bold)),
                        IconButton(onPressed: () => Navigator.pop(ctx), icon: Icon(Icons.close_rounded, color: isDark ? Colors.white70 : Colors.black54)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildTextField(ctx, 'Nama Perusahaan', nameCtrl),
                    _buildTextField(ctx, 'Alamat Perusahaan', addrCtrl, maxLines: 2),
                    _buildTextField(ctx, 'Telepon Perusahaan', phoneCtrl),
                    _buildTextField(ctx, 'Email Perusahaan', emailCtrl),
                    _buildTextField(ctx, 'URL Logo (Opsional)', logoCtrl),
                    _buildTextField(ctx, 'Nama Penandatangan (Finance/HR)', signNameCtrl),
                    _buildTextField(ctx, 'Jabatan Penandatangan', signTitleCtrl),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38BDF8), foregroundColor: Colors.black),
                        onPressed: () async {
                          final updated = {
                            'tenant_id': _tenantId,
                            'company_name': nameCtrl.text.trim(),
                            'company_address': addrCtrl.text.trim(),
                            'company_phone': phoneCtrl.text.trim(),
                            'company_email': emailCtrl.text.trim(),
                            'logo_url': logoCtrl.text.trim(),
                            'signatory_name': signNameCtrl.text.trim(),
                            'signatory_title': signTitleCtrl.text.trim(),
                            'updated_at': DateTime.now().toIso8601String(),
                          };

                          if (_tenantId.isNotEmpty) {
                            await _supabase.from('payroll_company_settings').upsert(updated, onConflict: 'tenant_id');
                          }

                          setState(() => _companySettings = updated);
                          if (mounted) Navigator.pop(ctx);
                        },
                        child: Text('Simpan Pengaturan Live', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTextField(
    BuildContext context,
    String label,
    TextEditingController ctrl, {
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    bool isCurrency = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctrl,
        maxLines: maxLines,
        keyboardType: isCurrency ? TextInputType.number : keyboardType,
        onChanged: (val) {
          if (isCurrency) {
            _formatCurrencyController(ctrl, val);
          }
          setState(() {}); // Re-trigger live PDF preview & real-time total recalculation
        },
        style: GoogleFonts.inter(color: isDark ? Colors.white : const Color(0xFF0F172A), fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: GoogleFonts.inter(color: isDark ? Colors.white60 : Colors.black54, fontSize: 13),
          filled: true,
          fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF38BDF8)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;


    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
        elevation: 0.5,
        iconTheme: IconThemeData(color: isDark ? Colors.white : const Color(0xFF0F172A)),
        title: Text('Payroll & Slip Gaji',
            style: GoogleFonts.outfit(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_rounded, color: isDark ? Colors.white70 : Colors.black87),
            onPressed: _openCompanySettingsModal,
            tooltip: 'Pengaturan Branding Perusahaan',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF38BDF8),
          labelColor: const Color(0xFF38BDF8),
          unselectedLabelColor: isDark ? Colors.white60 : Colors.black54,
          labelStyle: GoogleFonts.outfit(fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: 'Buat Slip Gaji'),
            Tab(text: 'Tarif & Tipe Gaji'),
            Tab(text: 'Riwayat Slip Gaji'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF38BDF8)))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildCreateSlipTab(),
                _buildConfigTab(),
                _buildHistoryTab(),
              ],
            ),
    );
  }

  Widget _buildCreateSlipTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E293B).withValues(alpha: 0.7) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor = isDark ? Colors.white60 : Colors.black54;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stat Overview Cards
          Row(
            children: [
              Expanded(
                child: _buildStatCard('Gaji Bersih', _currencyFormat.format(_netSalary), Icons.account_balance_wallet_rounded, const Color(0xFF10B981)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard('Total Pendapatan', _currencyFormat.format(_totalEarnings), Icons.trending_up_rounded, const Color(0xFF38BDF8)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard('Total Potongan', _currencyFormat.format(_totalDeductions), Icons.trending_down_rounded, const Color(0xFFEF4444)),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Main Form Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey.shade200),
              boxShadow: isDark
                  ? []
                  : [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, spreadRadius: 2),
                    ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Data Karyawan & Periode', style: GoogleFonts.outfit(color: textColor, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),

                // Employee Dropdown
                DropdownButtonFormField<Map<String, dynamic>>(
                  value: _selectedUser,
                  dropdownColor: isDark ? const Color(0xFF0F172A) : Colors.white,
                  style: GoogleFonts.inter(color: textColor),
                  decoration: InputDecoration(
                    labelText: 'Pilih Karyawan',
                    labelStyle: GoogleFonts.inter(color: subTextColor),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  items: _activeUsers.map((u) {
                    return DropdownMenuItem<Map<String, dynamic>>(
                      value: u,
                      child: Text('${u['nama']} (${AppUi.text(u['role_id'])})'),
                    );
                  }).toList(),
                  onChanged: (val) {
                    _onSelectUser(val);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(child: _buildTextField(context, 'No. Slip / Invoice ID', _invoiceNumberController)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(context, 'NIK / NIP Karyawan', _nikController)),
                  ],
                ),

                Row(
                  children: [
                    Expanded(child: _buildTextField(context, 'Nama Bank', _bankNameController)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(context, 'No. Rekening', _bankNumberController)),
                  ],
                ),

                _buildTextField(context, 'Nama Pemilik Rekening', _bankHolderController),

                Row(
                  children: [
                    Checkbox(
                      value: _autoSaveProfile,
                      activeColor: const Color(0xFF38BDF8),
                      onChanged: (val) => setState(() => _autoSaveProfile = val ?? true),
                    ),
                    Expanded(
                      child: Text('Simpan otomatis profil & rekening karyawan untuk pengajuan berikutnya',
                          style: GoogleFonts.inter(color: subTextColor, fontSize: 12)),
                    ),
                  ],
                ),

                Divider(color: isDark ? Colors.white12 : Colors.black12, height: 32),

                if (_selectedUser != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _autoCalculatePayrollForPeriod,
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0EA5E9)),
                      icon: const Icon(Icons.calculate_rounded),
                      label: Text('Hitung Otomatis Dari Absensi & Lembur (${_selectedUser!['nama']})'),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Earnings Section
                Text('PENDAPATAN (EARNINGS)', style: GoogleFonts.outfit(color: const Color(0xFF34D399), fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _buildTextField(context, 'Gaji Pokok (Rp)', _baseSalaryController, isCurrency: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(context, 'Tunjangan Jabatan (Rp)', _allowancePosController, isCurrency: true)),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _buildTextField(context, 'Tunjangan Makan & Transport (Rp)', _allowanceMealTransController, isCurrency: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(context, 'Bonus Kinerja (Rp)', _bonusController, isCurrency: true)),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _buildTextField(context, 'Bonus Tahunan (Rp)', _annualBonusController, isCurrency: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(context, 'Uang Lembur (Rp)', _overtimeController, isCurrency: true)),
                  ],
                ),

                Divider(color: isDark ? Colors.white12 : Colors.black12, height: 32),

                // Deductions Section
                Text('POTONGAN (DEDUCTIONS)', style: GoogleFonts.outfit(color: const Color(0xFFF87171), fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _buildTextField(context, 'Potongan BPJS (Rp)', _bpjsController, isCurrency: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(context, 'Denda Keterlambatan (Rp)', _latePenaltyController, isCurrency: true)),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _buildTextField(context, 'Tidak Hadir (Rp)', _absentDeductionController, isCurrency: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(context, 'Potongan Kasbon (Rp)', _loanController, isCurrency: true)),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _buildTextField(context, 'PPh 21 (Rp)', _taxController, isCurrency: true)),
                    const SizedBox(width: 12),
                    const Expanded(child: SizedBox()),
                  ],
                ),

                const SizedBox(height: 20),

                // Live PDF Preview Container
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Pratinjau PDF Live', style: GoogleFonts.outfit(color: textColor, fontSize: 16, fontWeight: FontWeight.bold)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('● Updates Real-time', style: GoogleFonts.inter(color: const Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  height: 440,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: PdfPreview(
                    key: ValueKey(
                      'pdf_${_selectedUser?['user_id']}_${_invoiceNumberController.text}_${_companySettings['company_name']}_${_companySettings['company_address']}_${_companySettings['company_phone']}_${_companySettings['company_email']}_${_companySettings['signatory_name']}_${_companySettings['signatory_title']}_${_baseSalaryController.text}_${_allowancePosController.text}_${_allowanceMealTransController.text}_${_bonusController.text}_${_annualBonusController.text}_${_overtimeController.text}_${_bpjsController.text}_${_latePenaltyController.text}_${_absentDeductionController.text}_${_loanController.text}_${_taxController.text}_${_nikController.text}_${_bankNameController.text}_${_bankNumberController.text}_${_bankHolderController.text}_${_selectedPeriod.millisecondsSinceEpoch}',
                    ),
                    build: (format) => _buildPdfDocument(),
                    pdfFileName: _pdfFileName,
                    initialPageFormat: PdfPageFormat.a4,
                    pageFormats: const {'A4': PdfPageFormat.a4},

                    allowPrinting: true,
                    allowSharing: true,
                    canChangeOrientation: false,
                    canChangePageFormat: false,
                    maxPageWidth: 700,
                  ),

                ),

                const SizedBox(height: 24),

                // Save Button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.picture_as_pdf_rounded),
                    label: Text('Simpan Slip & Rekam Database', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16)),
                    onPressed: _saveAndGeneratePdf,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor = isDark ? Colors.white60 : Colors.black54;

    return _payrollHistory.isEmpty
        ? Center(
            child: Text('Belum ada riwayat slip gaji', style: GoogleFonts.inter(color: subTextColor)),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _payrollHistory.length,
            itemBuilder: (ctx, idx) {
              final inv = _payrollHistory[idx];
              final net = (inv['net_salary'] as num?)?.toDouble() ?? 0.0;
              final invNum = inv['invoice_number'] ?? '-';
              final empName = inv['employee_name'] ?? 'Karyawan';
              final period = inv['period_label'] ?? '-';
              final status = inv['status'] ?? 'generated';

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E293B) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200),
                  boxShadow: isDark ? [] : [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8)],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFF38BDF8).withValues(alpha: 0.1), shape: BoxShape.circle),
                      child: const Icon(Icons.receipt_long_rounded, color: Color(0xFF38BDF8)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(empName, style: GoogleFonts.outfit(color: textColor, fontWeight: FontWeight.bold, fontSize: 15)),
                              Text(_currencyFormat.format(net), style: GoogleFonts.outfit(color: const Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 15)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text('$invNum • $period', style: GoogleFonts.inter(color: subTextColor, fontSize: 12)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: status == 'sent_wa'
                                      ? Colors.green.withValues(alpha: 0.2)
                                      : (status == 'sent_email' ? Colors.blue.withValues(alpha: 0.2) : (isDark ? Colors.white10 : Colors.grey.shade200)),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  status == 'sent_wa' ? 'Terkirim WA' : (status == 'sent_email' ? 'Terkirim Email' : 'Tersimpan (90 Hari)'),
                                  style: GoogleFonts.inter(
                                    color: status == 'sent_wa' ? Colors.greenAccent : (status == 'sent_email' ? Colors.lightBlueAccent : subTextColor),
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.chat_rounded, color: Colors.greenAccent),
                      onPressed: () => _shareViaWhatsApp(inv),
                      tooltip: 'Kirim WhatsApp',
                    ),
                    IconButton(
                      icon: const Icon(Icons.email_rounded, color: Colors.lightBlueAccent),
                      onPressed: () => _shareViaEmail(inv),
                      tooltip: 'Kirim Email',
                    ),
                  ],
                ),
              );
            },
          );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E293B).withValues(alpha: 0.8) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor = isDark ? Colors.white60 : Colors.black54;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        boxShadow: isDark ? [] : [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color, size: 20),
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            ],
          ),
          const SizedBox(height: 10),
          Text(label, style: GoogleFonts.inter(color: subTextColor, fontSize: 11)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: GoogleFonts.outfit(color: textColor, fontWeight: FontWeight.bold, fontSize: 15)),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Pengaturan Tarif & Tipe Gaji Karyawan (${_activeUsers.length})',
          style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Atur tipe gaji (Bulanan, Harian, Per Jam), tarif dasar, denda Keterlambatan (Rp/Menit), dan potongan Tidak Hadir (Rp/Hari) per karyawan.',
          style: GoogleFonts.inter(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        if (_activeUsers.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Tidak ada karyawan aktif.')))
        else
          ..._activeUsers.map((u) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _UserPayrollConfigCard(
                user: u,
                tenantId: _tenantId,
                supabase: _supabase,
                onSaved: () => setState(() {}),
              ),
            );
          }),
      ],
    );
  }
}

class _UserPayrollConfigCard extends StatefulWidget {
  final Map<String, dynamic> user;
  final String tenantId;
  final SupabaseClient supabase;
  final VoidCallback onSaved;

  const _UserPayrollConfigCard({
    required this.user,
    required this.tenantId,
    required this.supabase,
    required this.onSaved,
  });

  @override
  State<_UserPayrollConfigCard> createState() => _UserPayrollConfigCardState();
}

class _UserPayrollConfigCardState extends State<_UserPayrollConfigCard> {
  bool _isLoading = true;
  bool _isSaving = false;

  String _salaryType = 'monthly';
  final _baseSalaryCtrl = TextEditingController(text: '0');
  final _dailyRateCtrl = TextEditingController(text: '0');
  final _hourlyRateCtrl = TextEditingController(text: '0');
  final _overtimeRateCtrl = TextEditingController(text: '25.000');
  final _latePenaltyCtrl = TextEditingController(text: '0');
  final _absentPenaltyCtrl = TextEditingController(text: '0');

  @override
  void initState() {
    super.initState();
    _loadUserConfig();
  }

  @override
  void dispose() {
    _baseSalaryCtrl.dispose();
    _dailyRateCtrl.dispose();
    _hourlyRateCtrl.dispose();
    _overtimeRateCtrl.dispose();
    _latePenaltyCtrl.dispose();
    _absentPenaltyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUserConfig() async {
    setState(() => _isLoading = true);
    try {
      final userId = widget.user['user_id'];
      final tenantId = widget.tenantId;

      final prof = await widget.supabase
          .from('user_payroll_profiles')
          .select()
          .eq('tenant_id', tenantId)
          .eq('user_id', userId)
          .maybeSingle();

      if (prof != null) {
        _salaryType = prof['salary_type']?.toString() ?? 'monthly';
        _baseSalaryCtrl.text = _fmtNum(prof['base_salary']);
        _dailyRateCtrl.text = _fmtNum(prof['daily_rate']);
        _hourlyRateCtrl.text = _fmtNum(prof['hourly_rate']);
        _overtimeRateCtrl.text = AppUi.toNum(prof['hourly_rate']).toDouble() > 0 ? _fmtNum(prof['hourly_rate']) : '25.000';
        _latePenaltyCtrl.text = _fmtNum(prof['late_penalty_per_minute']);
        _absentPenaltyCtrl.text = _fmtNum(prof['absent_penalty_per_day']);
      }
    } catch (e) {
      debugPrint('Error loading user config: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _fmtNum(dynamic val) {
    if (val == null) return '0';
    final numVal = double.tryParse(val.toString()) ?? 0;
    return NumberFormat('#,##0', 'id_ID').format(numVal.toInt());
  }

  double _parseVal(TextEditingController ctrl) {
    final clean = ctrl.text.replaceAll(RegExp(r'[^\d]'), '');
    return double.tryParse(clean) ?? 0;
  }

  Future<void> _saveUserConfig() async {
    setState(() => _isSaving = true);
    try {
      final userId = widget.user['user_id'];
      final tenantId = widget.tenantId;

      await widget.supabase.from('user_payroll_profiles').upsert({
        'tenant_id': tenantId,
        'user_id': userId,
        'salary_type': _salaryType,
        'base_salary': _parseVal(_baseSalaryCtrl),
        'daily_rate': _parseVal(_dailyRateCtrl),
        'hourly_rate': _parseVal(_overtimeRateCtrl),
        'late_penalty_per_minute': _parseVal(_latePenaltyCtrl),
        'absent_penalty_per_day': _parseVal(_absentPenaltyCtrl),
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'tenant_id, user_id');

      AppUi.showSnack('Tarif & Tipe Gaji ${widget.user['nama']} berhasil disimpan!');
      widget.onSaved();
    } catch (e) {
      AppUi.showSnack('Gagal menyimpan: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppUi.text(widget.user['nama']),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  Text(
                    '${AppUi.text(widget.user['email'])} • ${AppUi.text(widget.user['role_id'])}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              Chip(
                label: Text(_salaryType.toUpperCase()),
                backgroundColor: Colors.lightBlue.withOpacity(0.15),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _salaryType,
            decoration: const InputDecoration(labelText: 'Tipe Gaji Utama', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'monthly', child: Text('Bulanan (Gaji Pokok Bulanan)')),
              DropdownMenuItem(value: 'daily', child: Text('Harian (Per Hari Masuk)')),
              DropdownMenuItem(value: 'hourly', child: Text('Per Jam (Per Jam Kerja)')),
            ],
            onChanged: (val) => setState(() => _salaryType = val ?? 'monthly'),
          ),
          const SizedBox(height: 12),
          if (_salaryType == 'monthly')
            _buildField('Gaji Pokok Bulanan (Rp)', _baseSalaryCtrl)
          else if (_salaryType == 'daily')
            _buildField('Tarif Gaji Per Hari (Rp/Hari)', _dailyRateCtrl)
          else if (_salaryType == 'hourly')
            _buildField('Tarif Gaji Per Jam (Rp/Jam)', _hourlyRateCtrl),
          const SizedBox(height: 12),
          Text('Tarif Lembur Per Jam', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
          const SizedBox(height: 8),
          _buildField('Tarif Lembur Per Jam (Rp/Jam)', _overtimeRateCtrl),
          const SizedBox(height: 12),
          Text('Tarif Denda & Potongan Absensi', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _buildField('Denda Telat (Rp/Menit)', _latePenaltyCtrl)),
              const SizedBox(width: 8),
              Expanded(child: _buildField('Potongan Absen (Rp/Hari)', _absentPenaltyCtrl)),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _saveUserConfig,
              icon: const Icon(Icons.save_rounded),
              label: Text(_isSaving ? 'Menyimpan...' : 'Simpan Tarif & Tipe Gaji'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(String label, TextEditingController ctrl) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }
}
