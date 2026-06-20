// ignore_for_file: unused_local_variable
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/evidence/models/photo_evidence.dart';
import '../../../core/evidence/widgets/evidence_camera_field.dart';
import '../../../core/constants/app_roles.dart';
import '../../../core/ui/app_ui.dart';

class TaskPage extends StatefulWidget {
  const TaskPage({super.key});

  @override
  State<TaskPage> createState() => _TaskPageState();
}

class _TaskPageState extends State<TaskPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  String? _errorMessage;
  Map<String, dynamic>? _currentUser;
  List<Map<String, dynamic>> _tasks = [];
  List<Map<String, dynamic>> _users = [];

  bool get _canManage => _isHrOrSuper(_currentRole);
  bool get _isSuperAdmin => _currentRole == 'super_admin';
  String get _currentRole =>
      _currentUser?['role_id']?.toString().toLowerCase() ?? '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  bool _isHrOrSuper(String role) {
    return AppRolePermissions.canManageOperationalWork(role);
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authUser = _client.auth.currentUser;
      if (authUser == null)
        throw Exception('Sesi login tidak ditemukan. Silakan login kembali.');

      final profile = await _client
          .from('users')
          .select('user_id, nama, email, role_id, status')
          .eq('user_id', authUser.id)
          .maybeSingle();

      if (profile == null)
        throw Exception('Profile user belum ada di tabel users.');
      _currentUser = Map<String, dynamic>.from(profile);

      var query = _client.from('tasks').select('''
        task_id,
        title,
        description,
        assigned_to,
        assigned_by,
        role_target,
        priority,
        deadline_date,
        deadline_time,
        status,
        proof_photo_url,
        proof_location_lat,
        proof_location_lng,
        proof_timestamp,
        verifier_id,
        verifier_note,
        assigned_to_name,
        assigned_by_name,
        note,
        created_at,
        updated_at
      ''');

      final dynamic rawData = _canManage
          ? await query.order('created_at', ascending: false).limit(250)
          : await query
              .eq('assigned_to', authUser.id)
              .order('created_at', ascending: false)
              .limit(250);

      final userData = await _client
          .from('users')
          .select('user_id, nama, email, role_id, status')
          .eq('status', 'active')
          .neq('role_id', 'platform_owner')
          .order('nama', ascending: true);

      final allUsers = (userData as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      if (!mounted) return;
      setState(() {
        _tasks = (rawData as List)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        _users = allUsers;
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

  List<String> _statusOptions() {
    if (_canManage) {
      return const ['assigned', 'on_progress', 'done', 'verified', 'rejected'];
    }
    return const ['on_progress', 'done'];
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'assigned':
        return 'Assigned';
      case 'on_progress':
        return 'On Progress';
      case 'done':
        return 'Done';
      case 'verified':
        return 'Verified';
      case 'rejected':
        return 'Rejected';
      default:
        return status;
    }
  }

  Future<void> _updateStatus(Map<String, dynamic> item, String status) async {
    try {
      await _client.from('tasks').update({
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
        if (_canManage && (status == 'verified' || status == 'rejected'))
          'verifier_id': _currentUser?['user_id'],
      }).eq('task_id', item['task_id']);
      AppUi.showSnack('Status tugas berhasil diperbarui.');
      await _loadData();
    } catch (error) {
      AppUi.showSnack('Gagal update status: $error');
    }
  }

  Future<void> _deleteTask(Map<String, dynamic> task) async {
    if (!_isSuperAdmin) return;

    final id = task['task_id']?.toString();
    if (id == null || id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus task?'),
        content: Text("Task ${AppUi.text(task['title'])} akan dihapus."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Batal')),
          FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Hapus')),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.rpc('delete_record_for_super_admin', params: {
        'p_table_name': 'tasks',
        'p_record_id': id,
      });
      AppUi.showSnack('Tugas berhasil dihapus.');
      await _loadData();
    } catch (error) {
      AppUi.showSnack('Gagal hapus task: $error');
    }
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TaskDetailPage(
          item: item,
          currentUser: _currentUser ?? const {},
          canManage: _canManage,
        ),
      ),
    );

    if (changed == true) {
      await _loadData();
    }
  }

  Future<void> _showAddForm() async {
    if (!_canManage) {
      AppUi.showSnack('Hanya HR dan Super Admin yang bisa membuat task.');
      return;
    }

    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    final noteController = TextEditingController();
    DateTime? deadline;
    String priority = 'medium';
    String? assignedTo =
        _users.isEmpty ? null : _users.first['user_id']?.toString();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> save() async {
              final title = titleController.text.trim();
              if (title.isEmpty || assignedTo == null) {
                AppUi.showSnack('Judul dan assigned user wajib diisi.');
                return;
              }

              final selectedUser = _users.firstWhere(
                (user) => user['user_id']?.toString() == assignedTo,
                orElse: () => const {},
              );

              try {
                await _client.from('tasks').insert({
                  'title': title,
                  'description': descriptionController.text.trim(),
                  'assigned_to': assignedTo,
                  'assigned_by': _currentUser?['user_id'],
                  'assigned_to_name': selectedUser['nama']?.toString(),
                  'assigned_by_name': _currentUser?['nama']?.toString(),
                  'role_target':
                      selectedUser['role_id']?.toString() ?? 'warehouse',
                  'priority': priority,
                  'deadline_date': deadline?.toIso8601String().split('T').first,
                  'status': 'assigned',
                  'note': noteController.text.trim(),
                });

                AppUi.showSnack('Tugas berhasil dibuat.');
                if (sheetContext.mounted) AppUi.safePop(sheetContext);
                await _loadData();
              } catch (error) {
                AppUi.showSnack('Gagal simpan task: $error');
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 18,
                right: 18,
                top: 18,
                bottom: MediaQuery.of(context).viewInsets.bottom + 18,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Tambah Tugas',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 14),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                          labelText: 'Judul task',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descriptionController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                          labelText: 'Deskripsi', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: assignedTo,
                      decoration: const InputDecoration(
                          labelText: 'Assigned ke',
                          border: OutlineInputBorder()),
                      items: _users
                          .map(
                            (user) => DropdownMenuItem<String>(
                              value: user['user_id']?.toString(),
                              child: Text(
                                  '${user['nama'] ?? '-'} • ${user['role_id'] ?? '-'}'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setSheetState(() => assignedTo = value),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: priority,
                      decoration: const InputDecoration(
                          labelText: 'Priority', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'low', child: Text('Low')),
                        DropdownMenuItem(
                            value: 'medium', child: Text('Medium')),
                        DropdownMenuItem(value: 'high', child: Text('High')),
                      ],
                      onChanged: (value) =>
                          setSheetState(() => priority = value ?? 'medium'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: deadline ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null)
                          setSheetState(() => deadline = picked);
                      },
                      icon: const Icon(Icons.event_outlined),
                      label: Text(deadline == null
                          ? 'Pilih deadline'
                          : 'Deadline: ${AppUi.date(deadline)}'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: noteController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                          labelText: 'Catatan', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: save,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Simpan Task'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    titleController.dispose();
    descriptionController.dispose();
    noteController.dispose();
  }

  Widget _taskCard(Map<String, dynamic> item) {
    final status = item['status']?.toString() ?? 'assigned';
    final proofUrl = item['proof_photo_url']?.toString() ?? '';

    return NiceCard(
      onTap: () => _openDetail(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item['title']?.toString() ?? '-',
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('PIC: ${item['assigned_to_name'] ?? '-'}'),
                    Text('Deadline: ${AppUi.date(item['deadline_date'])}'),
                  ],
                ),
              ),
              Chip(
                label: Text(_statusLabel(status)),
                backgroundColor: AppUi.statusColor(status).withOpacity(0.13),
              ),
              if (_isSuperAdmin)
                IconButton(
                  tooltip: 'Hapus task',
                  onPressed: () => _deleteTask(item),
                  icon: const Icon(Icons.delete_outline, color: AppUi.red),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                  proofUrl.trim().isEmpty
                      ? Icons.image_not_supported_outlined
                      : Icons.image_outlined,
                  size: 18),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(proofUrl.trim().isEmpty
                      ? 'Bukti foto belum diupload'
                      : 'Bukti foto tersedia')),
              DropdownButton<String>(
                value: _statusOptions().contains(status) ? status : null,
                hint: const Text('Status'),
                underline: const SizedBox.shrink(),
                items: _statusOptions()
                    .map((status) => DropdownMenuItem(
                        value: status, child: Text(_statusLabel(status))))
                    .toList(),
                onChanged: (value) {
                  if (value != null) _updateStatus(item, value);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tugas'),
        actions: [
          IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              onPressed: _showAddForm,
              icon: const Icon(Icons.add),
              label: const Text('Task'),
            )
          : null,
      body: _isLoading
          ? const LoadingState()
          : _errorMessage != null
              ? ErrorState(message: _errorMessage!, onRetry: _loadData)
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                    children: [
                      FuturisticHeader(
                        icon: Icons.task_alt_outlined,
                        title: 'Tugas',
                        subtitle: _canManage
                            ? 'HR dan Super Admin bisa membuat, memantau, dan approval task.'
                            : 'Task yang ditugaskan ke akun login. Upload bukti kerja dari detail task.',
                        stats: [
                          StatPill(
                              label: 'Total', value: _tasks.length.toString()),
                          StatPill(
                              label: 'Selesai',
                              value: _tasks
                                  .where((item) =>
                                      item['status'] == 'done' ||
                                      item['status'] == 'verified')
                                  .length
                                  .toString()),
                          StatPill(
                              label: 'Bukti',
                              value: _tasks
                                  .where((item) =>
                                      (item['proof_photo_url']?.toString() ??
                                              '')
                                          .isNotEmpty)
                                  .length
                                  .toString()),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_tasks.isEmpty)
                        const EmptyState(
                            title: 'Belum ada task',
                            subtitle: 'Data task akan tampil di sini.')
                      else
                        ..._tasks.map(_taskCard),
                    ],
                  ),
                ),
    );
  }
}

class TaskDetailPage extends StatefulWidget {
  final Map<String, dynamic> item;
  final Map<String, dynamic> currentUser;
  final bool canManage;

  const TaskDetailPage({
    super.key,
    required this.item,
    required this.currentUser,
    required this.canManage,
  });

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  final SupabaseClient _client = Supabase.instance.client;
  late Map<String, dynamic> _item;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _item = Map<String, dynamic>.from(widget.item);
  }

  Future<void> _saveProof(PhotoEvidence evidence) async {
    try {
      await _client.from('tasks').update({
        'proof_photo_url': evidence.publicUrl,
        'proof_location_lat': evidence.latitude,
        'proof_location_lng': evidence.longitude,
        'proof_timestamp': evidence.capturedAt.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('task_id', _item['task_id']);

      if (!mounted) return;
      setState(() {
        _changed = true;
        _item['proof_photo_url'] = evidence.publicUrl;
        _item['proof_location_lat'] = evidence.latitude;
        _item['proof_location_lng'] = evidence.longitude;
        _item['proof_timestamp'] = evidence.capturedAt.toIso8601String();
      });
      AppUi.showSnack('Bukti tugas berhasil disimpan.');
    } catch (error) {
      AppUi.showSnack('Gagal simpan bukti task: $error');
    }
  }

  Future<void> _updateStatus(String status) async {
    try {
      await _client.from('tasks').update({
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
        if (widget.canManage && (status == 'verified' || status == 'rejected'))
          'verifier_id': widget.currentUser['user_id'],
      }).eq('task_id', _item['task_id']);

      if (!mounted) return;
      setState(() {
        _changed = true;
        _item['status'] = status;
      });
      AppUi.showSnack('Status task diperbarui.');
    } catch (error) {
      AppUi.showSnack('Gagal update status: $error');
    }
  }

  List<String> _statusOptions() {
    if (widget.canManage)
      return const ['assigned', 'on_progress', 'done', 'verified', 'rejected'];
    return const ['on_progress', 'done'];
  }

  String _label(String status) {
    switch (status) {
      case 'assigned':
        return 'Assigned';
      case 'on_progress':
        return 'On Progress';
      case 'done':
        return 'Done';
      case 'verified':
        return 'Verified';
      case 'rejected':
        return 'Rejected';
      default:
        return status;
    }
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 112,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: Text(value.isEmpty ? '-' : value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _item['status']?.toString() ?? 'assigned';

    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _changed);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Detail Task'),
          leading: IconButton(
            onPressed: () => Navigator.pop(context, _changed),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            FuturisticHeader(
              icon: Icons.task_alt_outlined,
              title: _item['title']?.toString() ?? 'Detail Task',
              subtitle: 'Detail pekerjaan, status, dan bukti foto kerja.',
              stats: [
                StatPill(label: 'Status', value: _label(status)),
                StatPill(
                    label: 'Priority',
                    value: _item['priority']?.toString() ?? '-'),
              ],
            ),
            const SizedBox(height: 16),
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('PIC', _item['assigned_to_name']?.toString() ?? '-'),
                  _row('Dibuat oleh',
                      _item['assigned_by_name']?.toString() ?? '-'),
                  _row('Role target', _item['role_target']?.toString() ?? '-'),
                  _row('Deadline', AppUi.date(_item['deadline_date'])),
                  _row('Deskripsi', _item['description']?.toString() ?? '-'),
                  _row('Catatan', _item['note']?.toString() ?? '-'),
                  _row('Proof time', AppUi.dateTime(_item['proof_timestamp'])),
                  _row('Latitude',
                      _item['proof_location_lat']?.toString() ?? '-'),
                  _row('Longitude',
                      _item['proof_location_lng']?.toString() ?? '-'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _statusOptions().contains(status) ? status : null,
                    decoration: const InputDecoration(
                        labelText: 'Update status',
                        border: OutlineInputBorder()),
                    items: _statusOptions()
                        .map((item) => DropdownMenuItem(
                            value: item, child: Text(_label(item))))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) _updateStatus(value);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            EvidenceCameraField(
              label: 'Bukti Foto Task',
              helperText:
                  'Foto bebas lokasi. GPS, tanggal, dan jam tetap disimpan otomatis.',
              moduleName: 'tasks',
              purpose: 'task_proof',
              referenceId: _item['task_id']?.toString(),
              initialPhotoUrl: _item['proof_photo_url']?.toString(),
              onUploaded: _saveProof,
            ),
          ],
        ),
      ),
    );
  }
}
