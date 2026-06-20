// ignore_for_file: unused_element
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/evidence/models/photo_evidence.dart';
import '../../../core/evidence/widgets/evidence_camera_field.dart';
import '../../../core/ui/app_ui.dart';

class ContentMonitoringPage extends StatefulWidget {
  const ContentMonitoringPage({super.key});

  @override
  State<ContentMonitoringPage> createState() => _ContentMonitoringPageState();
}

class _ContentMonitoringPageState extends State<ContentMonitoringPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  String? _errorMessage;
  Map<String, dynamic>? _currentUser;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _users = [];

  String get _role => _currentUser?['role_id']?.toString().toLowerCase() ?? '';
  bool get _canManage => _isHrOrSuper(_role);
  bool get _canCreate => _canManage || _role == 'content_creator';
  bool get _isContentCreator => _role == 'content_creator';
  bool get _isSuperAdmin => _role == 'super_admin';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  bool _isHrOrSuper(String role) {
    return role == 'hr' || role == 'super_admin' || role == 'superadmin' || role == 'admin' || role == 'owner';
  }

  String? _textOrNull(dynamic value) {
    final text = value == null ? '' : value.toString().trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authUser = _client.auth.currentUser;
      if (authUser == null) throw Exception('Sesi login tidak ditemukan. Silakan login kembali.');

      final profile = await _client
          .from('users')
          .select('user_id, nama, email, role_id, status')
          .eq('user_id', authUser.id)
          .maybeSingle();

      if (profile == null) throw Exception('Profile user belum ada.');
      _currentUser = Map<String, dynamic>.from(profile);

      var query = _client.from('content_tasks').select('''
        content_task_id,
        assigned_to,
        assigned_by,
        judul_konten,
        platform,
        deadline,
        status,
        link_konten,
        bukti_upload_foto,
        catatan,
        created_at,
        updated_at,
        creator_user_id,
        creator_name,
        creator_email,
        title,
        description,
        content_type,
        due_date,
        post_url,
        proof_url,
        note,
        review_note,
        created_by,
        created_by_name,
        created_by_email,
        created_by_role,
        uploaded_at,
        reviewed_at,
        assigned_to_name,
        assigned_to_email,
        assigned_to_role,
        deadline_date,
        verified_by,
        verified_by_name,
        verified_at
      ''');

      final dynamic rawData = _canManage
          ? await query.order('created_at', ascending: false).limit(250)
          : await query.eq('assigned_to', authUser.id).order('created_at', ascending: false).limit(250);

      final usersData = await _client
          .from('users')
          .select('user_id, nama, email, role_id, status')
          .eq('status', 'active')
          .neq('role_id', 'platform_owner')
          .order('nama', ascending: true);

      if (!mounted) return;
      setState(() {
        _items = (rawData as List).map((item) => Map<String, dynamic>.from(item as Map)).toList();
        _users = (usersData as List).map((item) => Map<String, dynamic>.from(item as Map)).toList();
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
    if (_canManage) return const ['planned', 'in_progress', 'uploaded', 'approved', 'revision', 'rejected', 'cancelled'];
    return const ['planned', 'in_progress', 'uploaded'];
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'planned':
        return 'Planned';
      case 'in_progress':
        return 'In Progress';
      case 'uploaded':
        return 'Uploaded';
      case 'approved':
        return 'Approved';
      case 'revision':
        return 'Revision';
      case 'rejected':
        return 'Rejected';
      case 'cancelled':
        return 'Dibatalkan';
      default:
        return status;
    }
  }

  Future<void> _updateStatus(Map<String, dynamic> item, String status) async {
    try {
      await _client.from('content_tasks').update({
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
        if (status == 'uploaded') 'uploaded_at': DateTime.now().toIso8601String(),
        if (_canManage && (status == 'approved' || status == 'revision' || status == 'rejected' || status == 'cancelled')) ...{
          'verified_by': _currentUser?['user_id'],
          'verified_by_name': _currentUser?['nama'],
          'verified_at': DateTime.now().toIso8601String(),
          'reviewed_at': DateTime.now().toIso8601String(),
        },
      }).eq('content_task_id', item['content_task_id']);
      AppUi.showSnack('Status konten berhasil diperbarui.');
      await _loadData();
    } catch (error) {
      AppUi.showSnack('Gagal update status konten: $error');
    }
  }

  Future<void> _deleteContentTask(Map<String, dynamic> contentTask) async {
    if (!_isSuperAdmin) return;

    final id = contentTask['content_task_id']?.toString();
    if (id == null || id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus task konten?'),
        content: Text("Task konten ${AppUi.text(contentTask['title'] ?? contentTask['judul_konten'])} akan dihapus."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Batal')),
          FilledButton.icon(onPressed: () => Navigator.pop(dialogContext, true), icon: const Icon(Icons.delete_outline), label: const Text('Hapus')),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.rpc('delete_record_for_super_admin', params: {
        'p_table_name': 'content_tasks',
        'p_record_id': id,
      });
      AppUi.showSnack('Tugas konten berhasil dihapus.');
      await _loadData();
    } catch (error) {
      AppUi.showSnack('Gagal hapus task konten: $error');
    }
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ContentDetailPage(
          item: item,
          currentUser: _currentUser ?? const {},
          canManage: _canManage,
        ),
      ),
    );

    if (changed == true) await _loadData();
  }

  Future<void> _showAddForm() async {
    if (!_canCreate) {
      AppUi.showSnack('Akun ini belum punya akses membuat konten.');
      return;
    }

    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    final platformController = TextEditingController(text: 'TikTok');
    final noteController = TextEditingController();
    DateTime? deadline;
    String contentType = 'video';
    final activeUser = _currentUser;
    String? assignedTo = _isContentCreator
        ? _textOrNull(activeUser == null ? null : activeUser['user_id'])
        : (_users.isEmpty ? null : _textOrNull(_users.first['user_id']));

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> save() async {
              final title = titleController.text.trim();
              final platform = platformController.text.trim();

              if (title.isEmpty || platform.isEmpty || assignedTo == null) {
                AppUi.showSnack(_isContentCreator ? 'Judul dan platform wajib diisi.' : 'Judul, platform, dan PIC wajib diisi.');
                return;
              }

              final selectedUser = _isContentCreator
                  ? (_currentUser ?? const <String, dynamic>{})
                  : _users.firstWhere(
                      (user) => _textOrNull(user['user_id']) == assignedTo,
                      orElse: () => const {},
                    );

              try {
                await _client.from('content_tasks').insert({
                  'judul_konten': title,
                  'title': title,
                  'description': descriptionController.text.trim(),
                  'platform': platform,
                  'content_type': contentType,
                  'deadline': deadline?.toIso8601String(),
                  'deadline_date': deadline?.toIso8601String().split('T').first,
                  'due_date': deadline?.toIso8601String().split('T').first,
                  'assigned_to': assignedTo,
                  'assigned_by': _currentUser?['user_id'],
                  'assigned_to_name': selectedUser['nama']?.toString(),
                  'assigned_to_email': selectedUser['email']?.toString(),
                  'assigned_to_role': selectedUser['role_id']?.toString(),
                  'creator_user_id': _currentUser?['user_id'],
                  'created_by': _currentUser?['user_id'],
                  'creator_name': _currentUser?['nama']?.toString(),
                  'creator_email': _currentUser?['email']?.toString(),
                  'created_by_name': _currentUser?['nama']?.toString(),
                  'created_by_email': _currentUser?['email']?.toString(),
                  'created_by_role': _currentUser?['role_id']?.toString(),
                  'status': _isContentCreator ? 'in_progress' : 'planned',
                  'note': noteController.text.trim(),
                  'catatan': noteController.text.trim(),
                });

                AppUi.showSnack('Tugas konten berhasil dibuat.');
                if (sheetContext.mounted) AppUi.safePop(sheetContext);
                await _loadData();
              } catch (error) {
                AppUi.showSnack('Gagal simpan konten: $error');
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
                    Text('Tambah Task Konten', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 14),
                    TextField(controller: titleController, decoration: const InputDecoration(labelText: 'Judul konten', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(controller: platformController, decoration: const InputDecoration(labelText: 'Platform', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(controller: descriptionController, maxLines: 3, decoration: const InputDecoration(labelText: 'Brief / deskripsi', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    if (_canManage) ...[
                      DropdownButtonFormField<String>(
                        value: assignedTo,
                        decoration: const InputDecoration(labelText: 'PIC content creator', border: OutlineInputBorder()),
                        items: _users.map((user) => DropdownMenuItem<String>(value: _textOrNull(user['user_id']), child: Text('${user['nama'] ?? '-'} • ${user['role_id'] ?? '-'}'))).toList(),
                        onChanged: (value) => setSheetState(() => assignedTo = value),
                      ),
                      const SizedBox(height: 12),
                    ],
                    DropdownButtonFormField<String>(
                      value: contentType,
                      decoration: const InputDecoration(labelText: 'Tipe konten', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'video', child: Text('Video')),
                        DropdownMenuItem(value: 'photo', child: Text('Photo')),
                        DropdownMenuItem(value: 'carousel', child: Text('Carousel')),
                        DropdownMenuItem(value: 'story', child: Text('Story')),
                        DropdownMenuItem(value: 'other', child: Text('Other')),
                      ],
                      onChanged: (value) => setSheetState(() => contentType = value ?? 'video'),
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
                        if (picked != null) setSheetState(() => deadline = picked);
                      },
                      icon: const Icon(Icons.event_outlined),
                      label: Text(deadline == null ? 'Pilih deadline' : 'Deadline: ${AppUi.date(deadline)}'),
                    ),
                    const SizedBox(height: 12),
                    TextField(controller: noteController, maxLines: 2, decoration: const InputDecoration(labelText: 'Catatan', border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    FilledButton.icon(onPressed: save, icon: const Icon(Icons.save_outlined), label: const Text('Simpan')),
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
    platformController.dispose();
    noteController.dispose();
  }

  Widget _contentCard(Map<String, dynamic> item) {
    final status = item['status']?.toString() ?? 'planned';
    final rawTitle = (item['judul_konten'] ?? item['title'] ?? '-').toString();
    final title = rawTitle.trim().isEmpty ? '-' : rawTitle;
    final proofUrl = (item['bukti_upload_foto'] ?? item['proof_url'] ?? '').toString();
    final link = (item['link_konten'] ?? item['post_url'] ?? '').toString();

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
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('${item['platform'] ?? '-'} • ${item['content_type'] ?? 'video'}'),
                    Text('PIC: ${item['assigned_to_name'] ?? '-'}'),
                    Text('Deadline: ${AppUi.date(item['deadline_date'] ?? item['deadline'] ?? item['due_date'])}'),
                  ],
                ),
              ),
              Chip(label: Text(_statusLabel(status)), backgroundColor: AppUi.statusColor(status).withOpacity(0.13)),
              if (_isSuperAdmin)
                IconButton(
                  tooltip: 'Hapus task konten',
                  onPressed: () => _deleteContentTask(item),
                  icon: const Icon(Icons.delete_outline, color: AppUi.red),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(link.trim().isEmpty ? Icons.link_off_outlined : Icons.link_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text(link.trim().isEmpty ? 'Link konten belum diisi' : 'Link konten tersedia')),
              Icon(proofUrl.trim().isEmpty ? Icons.image_not_supported_outlined : Icons.image_outlined, size: 18),
              const SizedBox(width: 6),
              Text(proofUrl.trim().isEmpty ? 'No proof' : 'Proof'),
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
        title: const Text('Konten'),
        actions: [IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh))],
      ),
      floatingActionButton: _canCreate
          ? FloatingActionButton.extended(onPressed: _showAddForm, icon: const Icon(Icons.add), label: const Text('Konten'))
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
                        icon: Icons.video_library_outlined,
                        title: 'Konten',
                        subtitle: _canManage
                            ? 'Pantau brief, link konten, proof foto, dan approval.'
                            : 'Update progress konten, isi link konten, dan upload bukti kerja.',
                        stats: [
                          StatPill(label: 'Total', value: _items.length.toString()),
                          StatPill(label: 'Uploaded', value: _items.where((item) => item['status'] == 'uploaded' || item['status'] == 'approved').length.toString()),
                          StatPill(label: 'Proof', value: _items.where((item) => ((item['bukti_upload_foto'] ?? item['proof_url'] ?? '').toString()).isNotEmpty).length.toString()),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_items.isEmpty)
                        const EmptyState(title: 'Belum ada konten', subtitle: 'Data monitoring konten akan tampil di sini.')
                      else
                        ..._items.map(_contentCard),
                    ],
                  ),
                ),
    );
  }
}

class ContentDetailPage extends StatefulWidget {
  final Map<String, dynamic> item;
  final Map<String, dynamic> currentUser;
  final bool canManage;

  const ContentDetailPage({
    super.key,
    required this.item,
    required this.currentUser,
    required this.canManage,
  });

  @override
  State<ContentDetailPage> createState() => _ContentDetailPageState();
}

class _ContentDetailPageState extends State<ContentDetailPage> {
  final SupabaseClient _client = Supabase.instance.client;
  late Map<String, dynamic> _item;
  late TextEditingController _linkController;
  late TextEditingController _noteController;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _item = Map<String, dynamic>.from(widget.item);
    _linkController = TextEditingController(text: (_item['link_konten'] ?? _item['post_url'] ?? '').toString());
    _noteController = TextEditingController(text: (_item['catatan'] ?? _item['note'] ?? '').toString());
  }

  @override
  void dispose() {
    _linkController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  List<String> _statusOptions() {
    if (widget.canManage) return const ['planned', 'in_progress', 'uploaded', 'approved', 'revision', 'rejected', 'cancelled'];
    return const ['planned', 'in_progress', 'uploaded'];
  }

  String _label(String status) {
    switch (status) {
      case 'planned':
        return 'Planned';
      case 'in_progress':
        return 'In Progress';
      case 'uploaded':
        return 'Uploaded';
      case 'approved':
        return 'Approved';
      case 'revision':
        return 'Revision';
      case 'rejected':
        return 'Rejected';
      case 'cancelled':
        return 'Dibatalkan';
      default:
        return status;
    }
  }

  Future<void> _saveLinkAndNote() async {
    final link = _linkController.text.trim();
    final note = _noteController.text.trim();

    try {
      await _client.from('content_tasks').update({
        'link_konten': link,
        'post_url': link,
        'catatan': note,
        'note': note,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('content_task_id', _item['content_task_id']);

      if (!mounted) return;
      setState(() {
        _changed = true;
        _item['link_konten'] = link;
        _item['post_url'] = link;
        _item['catatan'] = note;
        _item['note'] = note;
      });
      AppUi.showSnack('Link/catatan konten berhasil disimpan.');
    } catch (error) {
      AppUi.showSnack('Gagal simpan link konten: $error');
    }
  }

  Future<void> _updateStatus(String status) async {
    try {
      await _client.from('content_tasks').update({
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
        if (status == 'uploaded') 'uploaded_at': DateTime.now().toIso8601String(),
        if (widget.canManage && (status == 'approved' || status == 'revision' || status == 'rejected' || status == 'cancelled')) ...{
          'verified_by': widget.currentUser['user_id'],
          'verified_by_name': widget.currentUser['nama'],
          'verified_at': DateTime.now().toIso8601String(),
          'reviewed_at': DateTime.now().toIso8601String(),
        },
      }).eq('content_task_id', _item['content_task_id']);

      if (!mounted) return;
      setState(() {
        _changed = true;
        _item['status'] = status;
      });
      AppUi.showSnack('Status konten diperbarui.');
    } catch (error) {
      AppUi.showSnack('Gagal update status konten: $error');
    }
  }

  Future<void> _saveProof(PhotoEvidence evidence) async {
    try {
      await _client.from('content_tasks').update({
        'bukti_upload_foto': evidence.publicUrl,
        'proof_url': evidence.publicUrl,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('content_task_id', _item['content_task_id']);

      try {
        await _client.from('content_proofs').insert({
          'content_task_id': _item['content_task_id'],
          'user_id': widget.currentUser['user_id'],
          'link_konten': _linkController.text.trim(),
          'photo_url': evidence.publicUrl,
          'catatan': _noteController.text.trim(),
          'uploaded_at': DateTime.now().toIso8601String(),
        });
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _changed = true;
        _item['bukti_upload_foto'] = evidence.publicUrl;
        _item['proof_url'] = evidence.publicUrl;
      });
      AppUi.showSnack('Bukti konten berhasil disimpan.');
    } catch (error) {
      AppUi.showSnack('Gagal simpan bukti konten: $error');
    }
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 116, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: Text(value.isEmpty ? '-' : value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _item['status']?.toString() ?? 'planned';
    final rawTitle = (_item['judul_konten'] ?? _item['title'] ?? 'Detail Konten').toString();
    final title = rawTitle.trim().isEmpty ? 'Detail Konten' : rawTitle;
    final proofUrl = (_item['bukti_upload_foto'] ?? _item['proof_url'] ?? '').toString();

    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _changed);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Detail Konten'),
          leading: IconButton(onPressed: () => Navigator.pop(context, _changed), icon: const Icon(Icons.arrow_back)),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            FuturisticHeader(
              icon: Icons.video_library_outlined,
              title: title,
              subtitle: 'Link konten, bukti foto, catatan, dan approval.',
              stats: [
                StatPill(label: 'Status', value: _label(status)),
                StatPill(label: 'Platform', value: _item['platform']?.toString() ?? '-'),
              ],
            ),
            const SizedBox(height: 14),
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('PIC', _item['assigned_to_name']?.toString() ?? '-'),
                  _row('Creator', _item['creator_name']?.toString() ?? _item['created_by_name']?.toString() ?? '-'),
                  _row('Tipe', _item['content_type']?.toString() ?? '-'),
                  _row('Deadline', AppUi.date(_item['deadline_date'] ?? _item['deadline'] ?? _item['due_date'])),
                  _row('Brief', _item['description']?.toString() ?? '-'),
                  _row('Proof', proofUrl.trim().isEmpty ? 'Belum ada foto bukti' : 'Foto bukti tersedia'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _linkController,
                    decoration: const InputDecoration(labelText: 'Link konten', border: OutlineInputBorder(), prefixIcon: Icon(Icons.link_outlined)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _noteController,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Catatan', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _statusOptions().contains(status) ? status : null,
                    decoration: const InputDecoration(labelText: 'Update status', border: OutlineInputBorder()),
                    items: _statusOptions().map((item) => DropdownMenuItem(value: item, child: Text(_label(item)))).toList(),
                    onChanged: (value) {
                      if (value != null) _updateStatus(value);
                    },
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(onPressed: _saveLinkAndNote, icon: const Icon(Icons.save_outlined), label: const Text('Simpan Link dan Catatan')),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            EvidenceCameraField(
              label: 'Bukti Foto Pekerjaan Konten',
              helperText: 'Foto bebas lokasi. GPS, tanggal, dan jam tetap tercatat otomatis.',
              moduleName: 'content_tasks',
              purpose: 'content_proof',
              referenceId: _item['content_task_id']?.toString(),
              initialPhotoUrl: proofUrl,
              onUploaded: _saveProof,
            ),
          ],
        ),
      ),
    );
  }
}
