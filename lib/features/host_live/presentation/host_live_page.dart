import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/evidence/models/photo_evidence.dart';
import '../../../core/evidence/widgets/evidence_camera_field.dart';
import '../../../core/ui/app_ui.dart';

class HostLivePage extends StatefulWidget {
  const HostLivePage({super.key});

  @override
  State<HostLivePage> createState() => _HostLivePageState();
}

class _HostLivePageState extends State<HostLivePage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  String? _errorMessage;
  Map<String, dynamic>? _currentUser;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _users = [];

  String get _role => _currentUser?['role_id']?.toString().toLowerCase() ?? '';
  String get _tenantId => _currentUser?['tenant_id']?.toString() ?? '';
  bool get _canManage => _isHrOrSuper(_role);
  bool get _isSuperAdmin => _role == 'super_admin';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  bool _isHrOrSuper(String role) {
    return role == 'hr' ||
        role == 'super_admin' ||
        role == 'superadmin' ||
        role == 'admin' ||
        role == 'owner';
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
          .select('user_id, nama, email, role_id, status, tenant_id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      if (profile == null) throw Exception('Profile user belum ada.');
      _currentUser = Map<String, dynamic>.from(profile);

      var query = _client.from('live_schedules').select('''
        live_schedule_id,
        user_id,
        host_id,
        host_name,
        title,
        tanggal,
        shift,
        sesi,
        jam_mulai,
        jam_selesai,
        platform,
        status,
        catatan,
        proof_photo_url,
        proof_lat,
        proof_lng,
        proof_timestamp,
        verified_by,
        verified_by_name,
        verified_at,
        created_at,
        updated_at,
        tenant_id
      ''');
      if (_tenantId.isNotEmpty) {
        query = query.eq('tenant_id', _tenantId);
      }

      final dynamic rawData = _canManage
          ? await query
              .order('tanggal', ascending: false)
              .order('created_at', ascending: false)
              .limit(250)
          : await query
              .eq('user_id', authUser.id)
              .order('tanggal', ascending: false)
              .order('created_at', ascending: false)
              .limit(250);

      dynamic usersQuery = _client
          .from('users')
          .select('user_id, nama, email, role_id, status, tenant_id')
          .eq('status', 'active')
          .neq('role_id', 'platform_owner');
      if (_tenantId.isNotEmpty) {
        usersQuery = usersQuery.eq('tenant_id', _tenantId);
      }
      final usersData = await usersQuery.order('nama', ascending: true);

      if (!mounted) return;
      setState(() {
        _items = (rawData as List)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        _users = (usersData as List)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
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
    if (_canManage)
      return const [
        'scheduled',
        'live_started',
        'finished',
        'verified',
        'rejected'
      ];
    return const ['live_started', 'finished'];
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'scheduled':
        return 'Scheduled';
      case 'live_started':
        return 'Live Started';
      case 'finished':
        return 'Finished';
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
      dynamic query = _client.from('live_schedules').update({
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
        if (_canManage && (status == 'verified' || status == 'rejected')) ...{
          'verified_by': _currentUser?['user_id'],
          'verified_by_name': _currentUser?['nama'],
          'verified_at': DateTime.now().toIso8601String(),
        },
      }).eq('live_schedule_id', item['live_schedule_id']);
      if (_tenantId.isNotEmpty) query = query.eq('tenant_id', _tenantId);
      await query;
      AppUi.showSnack('Status host live berhasil diperbarui.');
      await _loadData();
    } catch (error) {
      AppUi.showSnack('Gagal update status host live: $error');
    }
  }

  Future<void> _deleteSchedule(Map<String, dynamic> schedule) async {
    if (!_isSuperAdmin) return;

    final id = schedule['live_schedule_id']?.toString();
    if (id == null || id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus jadwal live?'),
        content: Text(
            "Jadwal live ${AppUi.text(schedule['host_name'] ?? schedule['users']?['nama'])} akan dihapus."),
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
      dynamic query =
          _client.from('live_schedules').delete().eq('live_schedule_id', id);
      if (_tenantId.isNotEmpty) query = query.eq('tenant_id', _tenantId);
      await query;
      AppUi.showSnack('Jadwal live berhasil dihapus.');
      await _loadData();
    } catch (error) {
      AppUi.showSnack('Gagal hapus jadwal live: $error');
    }
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => HostLiveDetailPage(
          item: item,
          currentUser: _currentUser ?? const {},
          canManage: _canManage,
        ),
      ),
    );

    if (changed == true) await _loadData();
  }

  Future<void> _showAddForm() async {
    if (!_canManage) {
      AppUi.showSnack(
          'Hanya HR dan Super Admin yang bisa membuat jadwal live.');
      return;
    }

    String? hostId =
        _users.isEmpty ? null : _users.first['user_id']?.toString();
    final titleController = TextEditingController(text: 'Live Session');
    final platformController = TextEditingController(text: 'TikTok');
    final shiftController = TextEditingController(text: 'Shift 1');
    final sesiController = TextEditingController(text: 'Sesi 1');
    final startController = TextEditingController(text: '08:00');
    final endController = TextEditingController(text: '12:00');
    final noteController = TextEditingController();
    DateTime tanggal = DateTime.now();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> save() async {
              if (hostId == null) {
                AppUi.showSnack('Host wajib dipilih.');
                return;
              }

              final host = _users.firstWhere(
                  (user) => user['user_id']?.toString() == hostId,
                  orElse: () => const {});
              final hostName =
                  host['nama']?.toString() ?? host['email']?.toString() ?? '-';

              try {
                await _client.from('live_schedules').insert({
                  'user_id': hostId,
                  'host_id': hostId,
                  'host_name': hostName,
                  'title': titleController.text.trim().isEmpty
                      ? 'Live Session'
                      : titleController.text.trim(),
                  'tanggal': tanggal.toIso8601String().split('T').first,
                  'shift': shiftController.text.trim(),
                  'sesi': sesiController.text.trim(),
                  'jam_mulai': startController.text.trim(),
                  'jam_selesai': endController.text.trim(),
                  'platform': platformController.text.trim().isEmpty
                      ? 'TikTok'
                      : platformController.text.trim(),
                  'status': 'scheduled',
                  'catatan': noteController.text.trim(),
                  if (_tenantId.isNotEmpty) 'tenant_id': _tenantId,
                });

                AppUi.showSnack('Jadwal host live berhasil dibuat.');
                if (sheetContext.mounted) AppUi.safePop(sheetContext);
                await _loadData();
              } catch (error) {
                AppUi.showSnack('Gagal simpan jadwal live: $error');
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
                    Text('Tambah Jadwal Host Live',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      value: hostId,
                      decoration: const InputDecoration(
                          labelText: 'Host', border: OutlineInputBorder()),
                      items: _users
                          .map((user) => DropdownMenuItem<String>(
                              value: user['user_id']?.toString(),
                              child: Text(
                                  '${user['nama'] ?? '-'} • ${user['role_id'] ?? '-'}')))
                          .toList(),
                      onChanged: (value) => setSheetState(() => hostId = value),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                        controller: titleController,
                        decoration: const InputDecoration(
                            labelText: 'Judul live',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(
                        controller: platformController,
                        decoration: const InputDecoration(
                            labelText: 'Platform',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                            child: TextField(
                                controller: shiftController,
                                decoration: const InputDecoration(
                                    labelText: 'Shift',
                                    border: OutlineInputBorder()))),
                        const SizedBox(width: 10),
                        Expanded(
                            child: TextField(
                                controller: sesiController,
                                decoration: const InputDecoration(
                                    labelText: 'Sesi',
                                    border: OutlineInputBorder()))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                            child: TextField(
                                controller: startController,
                                decoration: const InputDecoration(
                                    labelText: 'Jam mulai',
                                    border: OutlineInputBorder()))),
                        const SizedBox(width: 10),
                        Expanded(
                            child: TextField(
                                controller: endController,
                                decoration: const InputDecoration(
                                    labelText: 'Jam selesai',
                                    border: OutlineInputBorder()))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: tanggal,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null)
                          setSheetState(() => tanggal = picked);
                      },
                      icon: const Icon(Icons.event_outlined),
                      label: Text('Tanggal: ${AppUi.date(tanggal)}'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                        controller: noteController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                            labelText: 'Catatan',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: save,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Simpan Jadwal')),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    titleController.dispose();
    platformController.dispose();
    shiftController.dispose();
    sesiController.dispose();
    startController.dispose();
    endController.dispose();
    noteController.dispose();
  }

  Widget _liveCard(Map<String, dynamic> item) {
    final status = item['status']?.toString() ?? 'scheduled';
    final proofUrl = (item['proof_photo_url'] ?? '').toString();

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
                    Text(item['title']?.toString() ?? 'Live Session',
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('Host: ${item['host_name'] ?? '-'}'),
                    Text(
                        '${AppUi.date(item['tanggal'])} • ${item['shift'] ?? '-'} • ${item['sesi'] ?? '-'}'),
                    Text(
                        '${item['jam_mulai'] ?? '-'} - ${item['jam_selesai'] ?? '-'}'),
                  ],
                ),
              ),
              Chip(
                  label: Text(_statusLabel(status)),
                  backgroundColor: AppUi.statusColor(status).withOpacity(0.13)),
              if (_isSuperAdmin)
                IconButton(
                  tooltip: 'Hapus jadwal live',
                  onPressed: () => _deleteSchedule(item),
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
                      ? 'Bukti stream off belum diupload'
                      : 'Bukti stream off tersedia')),
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
        title: const Text('Live Host'),
        actions: [
          IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh))
        ],
      ),
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              onPressed: _showAddForm,
              icon: const Icon(Icons.add),
              label: const Text('Jadwal'))
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
                        icon: Icons.live_tv_outlined,
                        title: 'Live Host',
                        subtitle: _canManage
                            ? 'Pantau jadwal, status live, bukti stream off, dan approval.'
                            : 'Update status live dan upload bukti stream off dari detail jadwal.',
                        stats: [
                          StatPill(
                              label: 'Total', value: _items.length.toString()),
                          StatPill(
                              label: 'Finished',
                              value: _items
                                  .where((item) =>
                                      item['status'] == 'finished' ||
                                      item['status'] == 'verified')
                                  .length
                                  .toString()),
                          StatPill(
                              label: 'Proof',
                              value: _items
                                  .where((item) =>
                                      ((item['proof_photo_url'] ?? '')
                                              .toString())
                                          .isNotEmpty)
                                  .length
                                  .toString()),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_items.isEmpty)
                        const EmptyState(
                            title: 'Belum ada jadwal live',
                            subtitle: 'Jadwal host live akan tampil di sini.')
                      else
                        ..._items.map(_liveCard),
                    ],
                  ),
                ),
    );
  }
}

class HostLiveDetailPage extends StatefulWidget {
  final Map<String, dynamic> item;
  final Map<String, dynamic> currentUser;
  final bool canManage;

  const HostLiveDetailPage({
    super.key,
    required this.item,
    required this.currentUser,
    required this.canManage,
  });

  @override
  State<HostLiveDetailPage> createState() => _HostLiveDetailPageState();
}

class _HostLiveDetailPageState extends State<HostLiveDetailPage> {
  final SupabaseClient _client = Supabase.instance.client;
  late Map<String, dynamic> _item;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _item = Map<String, dynamic>.from(widget.item);
  }

  List<String> _statusOptions() {
    if (widget.canManage)
      return const [
        'scheduled',
        'live_started',
        'finished',
        'verified',
        'rejected'
      ];
    return const ['live_started', 'finished'];
  }

  String _label(String status) {
    switch (status) {
      case 'scheduled':
        return 'Scheduled';
      case 'live_started':
        return 'Live Started';
      case 'finished':
        return 'Finished';
      case 'verified':
        return 'Verified';
      case 'rejected':
        return 'Rejected';
      default:
        return status;
    }
  }

  Future<void> _updateStatus(String status) async {
    try {
      final tenantId = _item['tenant_id']?.toString() ?? '';
      dynamic query = _client.from('live_schedules').update({
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
        if (widget.canManage &&
            (status == 'verified' || status == 'rejected')) ...{
          'verified_by': widget.currentUser['user_id'],
          'verified_by_name': widget.currentUser['nama'],
          'verified_at': DateTime.now().toIso8601String(),
        },
      }).eq('live_schedule_id', _item['live_schedule_id']);
      if (tenantId.isNotEmpty) query = query.eq('tenant_id', tenantId);
      await query;

      if (!mounted) return;
      setState(() {
        _changed = true;
        _item['status'] = status;
      });
      AppUi.showSnack('Status live diperbarui.');
    } catch (error) {
      AppUi.showSnack('Gagal update status live: $error');
    }
  }

  Future<void> _saveProof(PhotoEvidence evidence) async {
    try {
      final tenantId = _item['tenant_id']?.toString() ??
          widget.currentUser['tenant_id']?.toString() ??
          '';
      dynamic query = _client.from('live_schedules').update({
        'proof_photo_url': evidence.publicUrl,
        'proof_lat': evidence.latitude,
        'proof_lng': evidence.longitude,
        'proof_timestamp': evidence.capturedAt.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('live_schedule_id', _item['live_schedule_id']);
      if (tenantId.isNotEmpty) query = query.eq('tenant_id', tenantId);
      await query;

      try {
        await _client.from('live_proofs').insert({
          'live_schedule_id': _item['live_schedule_id'],
          'user_id': widget.currentUser['user_id'] ?? _item['user_id'],
          'photo_url': evidence.publicUrl,
          'latitude': evidence.latitude,
          'longitude': evidence.longitude,
          'lat': evidence.latitude,
          'lng': evidence.longitude,
          'accuracy_meter': evidence.accuracyMeter,
          'created_at': DateTime.now().toIso8601String(),
          if (tenantId.isNotEmpty) 'tenant_id': tenantId,
        });
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _changed = true;
        _item['proof_photo_url'] = evidence.publicUrl;
        _item['proof_lat'] = evidence.latitude;
        _item['proof_lng'] = evidence.longitude;
        _item['proof_timestamp'] = evidence.capturedAt.toIso8601String();
      });
      AppUi.showSnack('Bukti stream off berhasil disimpan.');
    } catch (error) {
      AppUi.showSnack('Gagal simpan bukti stream off: $error');
    }
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 116,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: Text(value.isEmpty ? '-' : value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _item['status']?.toString() ?? 'scheduled';
    final proofUrl = (_item['proof_photo_url'] ?? '').toString();

    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _changed);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Detail Host Live'),
          leading: IconButton(
              onPressed: () => Navigator.pop(context, _changed),
              icon: const Icon(Icons.arrow_back)),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            FuturisticHeader(
              icon: Icons.live_tv_outlined,
              title: _item['title']?.toString() ?? 'Live Session',
              subtitle:
                  'Detail live, status, dan bukti stream off berbasis lokasi.',
              stats: [
                StatPill(label: 'Status', value: _label(status)),
                StatPill(label: 'Tanggal', value: AppUi.date(_item['tanggal'])),
              ],
            ),
            const SizedBox(height: 14),
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('Host', _item['host_name']?.toString() ?? '-'),
                  _row('Platform', _item['platform']?.toString() ?? '-'),
                  _row('Shift', _item['shift']?.toString() ?? '-'),
                  _row('Sesi', _item['sesi']?.toString() ?? '-'),
                  _row('Jam',
                      '${_item['jam_mulai'] ?? '-'} - ${_item['jam_selesai'] ?? '-'}'),
                  _row('Catatan', _item['catatan']?.toString() ?? '-'),
                  _row('Proof time', AppUi.dateTime(_item['proof_timestamp'])),
                  _row('Latitude', _item['proof_lat']?.toString() ?? '-'),
                  _row('Longitude', _item['proof_lng']?.toString() ?? '-'),
                  const SizedBox(height: 12),
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
              label: 'Bukti Foto Stream Off',
              helperText:
                  'Wajib berada dalam radius lokasi kerja aktif. GPS, tanggal, dan jam tersimpan otomatis.',
              moduleName: 'host_live',
              purpose: 'stream_off_proof',
              referenceId: _item['live_schedule_id']?.toString(),
              initialPhotoUrl: proofUrl,
              requireInsideWorkLocation: true,
              onUploaded: _saveProof,
            ),
          ],
        ),
      ),
    );
  }
}
