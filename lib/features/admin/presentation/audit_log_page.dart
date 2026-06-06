import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';

class AuditLogPage extends StatefulWidget {
  const AuditLogPage({super.key});

  @override
  State<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends State<AuditLogPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  bool _isDemoSuperAdmin = false;
  bool get _canDeleteAuditLog => !_isDemoSuperAdmin;
  String? _errorMessage;
  DateTime? _selectedDate;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  String _dateOnly(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)}';
  }

  Future<void> _loadCurrentRole() async {
    final currentUserId = _client.auth.currentUser?.id;
    if (currentUserId == null) return;

    try {
      final profile = await _client
          .from('users')
          .select('role_id, is_demo_account, username, email')
          .eq('user_id', currentUserId)
          .maybeSingle();

      final role = profile?['role_id']?.toString().toLowerCase().trim() ?? '';
      final username = profile?['username']?.toString().toLowerCase().trim() ?? '';
      final email = profile?['email']?.toString().toLowerCase().trim() ?? '';

      _isDemoSuperAdmin = role == 'demo_super_admin' ||
          profile?['is_demo_account'] == true ||
          username == 'demo_super_admin' ||
          email.contains('demo_super_admin');
    } catch (_) {
      // Audit log tetap bisa dibuka meski role guard gagal dibaca.
    }
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      await _loadCurrentRole();
      final data = await _client.rpc(
        'list_audit_logs_for_app',
        params: {
          'p_date': _selectedDate == null ? null : _dateOnly(_selectedDate!),
          'p_limit': 500,
        },
      );

      final list = (data as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (!mounted) return;
      setState(() => _items = list);
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

  String _firstText(Map<String, dynamic> item, List<String> keys, [String fallback = '-']) {
    for (final key in keys) {
      final value = AppUi.text(item[key], '');
      if (value.trim().isNotEmpty) return value;
    }
    return fallback;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2023),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() => _selectedDate = picked);
    await _loadData();
  }

  Future<void> _deleteOne(Map<String, dynamic> item) async {
    if (!_canDeleteAuditLog) {
      AppUi.showSnack('Mode demo hanya bisa melihat audit log. Hapus log dikunci.');
      return;
    }

    final auditLogId = AppUi.text(item['audit_log_id'], '').trim();
    if (auditLogId.isEmpty) {
      AppUi.showSnack('ID audit log tidak ditemukan. Refresh halaman lalu coba lagi.');
      return;
    }

    final activity = _firstText(item, ['activity', 'aktivitas']);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus audit log?'),
        content: Text('Log ini akan dihapus permanen.\n\nAktivitas: $activity'),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext, false),
            child: const Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => AppUi.safePop(dialogContext, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _client.rpc(
        'delete_audit_log_for_app',
        params: {'p_audit_log_id': auditLogId},
      );
      AppUi.showSnack('Audit log berhasil dihapus.');
      await _loadData();
    } on PostgrestException catch (error) {
      AppUi.showSnack(error.message);
    } catch (error) {
      AppUi.showSnack('Gagal menghapus audit log: $error');
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus semua audit log?'),
        content: const Text(
          'Gunakan hanya setelah pembukuan kantor sudah direkap. Data audit log akan dihapus permanen.',
        ),
        actions: [
          TextButton(
            onPressed: () => AppUi.safePop(dialogContext, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => AppUi.safePop(dialogContext, true),
            child: const Text('Hapus Semua'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _client.rpc('delete_all_audit_logs_for_app');
      AppUi.showSnack('Audit log berhasil dikosongkan.');
      await _loadData();
    } on PostgrestException catch (error) {
      AppUi.showSnack(error.message);
    } catch (error) {
      AppUi.showSnack('Gagal menghapus audit log: $error');
    }
  }

  void _openDetail(Map<String, dynamic> item) {
    final module = _firstText(item, ['module', 'modul']);
    final activity = _firstText(item, ['activity', 'aktivitas']);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (sheetContext, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              'Detail Riwayat Aktivitas',
              style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 12),
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow('Aktivitas', activity),
                  _detailRow('Modul', module),
                  _detailRow('User', _firstText(item, ['user_name', 'nama_user'])),
                  _detailRow('Email', _firstText(item, ['user_email'])),
                  _detailRow('Role', AppUi.text(item['role_id'])),
                  _detailRow('Waktu', AppUi.dateTime(item['created_at'])),
                  _detailRow('Latitude', AppUi.text(item['latitude'])),
                  _detailRow('Longitude', AppUi.text(item['longitude'])),
                ],
              ),
            ),
            const SizedBox(height: 12),
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Data Sebelum',
                    style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(_firstText(item, ['before_data', 'data_sebelum'])),
                ],
              ),
            ),
            const SizedBox(height: 12),
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Data Sesudah',
                    style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(_firstText(item, ['after_data', 'data_sesudah'])),
                ],
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _deleteOne(item);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Hapus Log Ini'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();
    if (_errorMessage != null) return ErrorState(message: _errorMessage!, onRetry: _loadData);

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          FuturisticHeader(
            icon: Icons.history_outlined,
            title: 'Riwayat Aktivitas',
            subtitle: 'Jejak aktivitas sistem untuk kontrol internal dan pemeriksaan operasional.',
            stats: [
              StatPill(label: 'Log tampil', value: _items.length.toString()),
              if (_selectedDate != null) StatPill(label: 'Tanggal', value: AppUi.date(_selectedDate)),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.date_range),
                label: Text(_selectedDate == null ? 'Filter Hari' : AppUi.date(_selectedDate)),
              ),
              if (_selectedDate != null)
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() => _selectedDate = null);
                    _loadData();
                  },
                  icon: const Icon(Icons.clear),
                  label: const Text('Reset Filter'),
                ),
              if (_canDeleteAuditLog)
                FilledButton.icon(
                  onPressed: _clearAll,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Hapus Semua'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_items.isEmpty)
            const EmptyState(
              title: 'Audit log kosong',
              subtitle: 'Aktivitas modul akan otomatis tampil setelah user menambah, mengubah, atau menghapus data.',
            )
          else
            ..._items.map((item) {
              final module = _firstText(item, ['module', 'modul']);
              final activity = _firstText(item, ['activity', 'aktivitas']);
              final user = _firstText(item, ['user_name', 'nama_user']);
              final email = _firstText(item, ['user_email'], '');
              final initial = module.isEmpty ? '?' : module.substring(0, 1).toUpperCase();
              return NiceCard(
                padding: EdgeInsets.zero,
                onTap: () => _openDetail(item),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: CircleAvatar(child: Text(initial)),
                  title: Text(activity, style: const TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text(
                    '$module • $user\n${email.isEmpty ? AppUi.text(item['role_id']) : email}\n${AppUi.dateTime(item['created_at'])}',
                  ),
                  isThreeLine: true,
                  trailing: _canDeleteAuditLog
                      ? IconButton(
                          tooltip: 'Hapus log',
                          onPressed: () => _deleteOne(item),
                          icon: const Icon(Icons.delete_outline),
                        )
                      : null,
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
        title: const Text('Riwayat Aktivitas'),
        actions: [IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh))],
      ),
      body: _body(),
    );
  }
}
