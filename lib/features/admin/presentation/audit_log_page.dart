import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/app_roles.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';

class AuditLogPage extends StatefulWidget {
  const AuditLogPage({super.key});

  @override
  State<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends State<AuditLogPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  bool _isDemoSuperAdmin = false;
  String _currentRoleId = '';
  bool get _canDeleteAuditLog =>
      !_isDemoSuperAdmin && AppRolePermissions.isSuperRoleId(_currentRoleId);
  String? _errorMessage;

  // Filters & Search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedModule;
  DateTime? _startDate;
  DateTime? _endDate;

  // Pagination
  int _currentPage = 1;
  static const int _pageSize = 50;
  int _totalRecords = 0;
  int get _totalPages => _totalRecords == 0 ? 1 : (_totalRecords / _pageSize).ceil();

  List<Map<String, dynamic>> _items = [];

  static const List<String> _moduleOptions = [
    'Semua',
    'Absensi',
    'Finance',
    'Stock',
    'Marketplace',
    'HR',
    'Auth',
    'Master Data',
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _dateOnly(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '--';
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
      final username =
          profile?['username']?.toString().toLowerCase().trim() ?? '';
      final email = profile?['email']?.toString().toLowerCase().trim() ?? '';

      _currentRoleId = role;
      _isDemoSuperAdmin = AppRolePermissions.isDemoSuperAdminId(role) ||
          profile?['is_demo_account'] == true ||
          username == 'demo_super_admin' ||
          email.contains('demo_super_admin');
    } catch (_) {
      // Audit log tetap bisa dibuka meski role guard gagal dibaca.
    }
  }

  Future<void> _loadData({int? page}) async {
    if (page != null) _currentPage = page;
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      await _loadCurrentRole();

      final cleanSearch = _searchQuery.trim().isEmpty ? null : _searchQuery.trim();
      final cleanModule = (_selectedModule == null || _selectedModule == 'Semua') ? null : _selectedModule;
      final startStr = _startDate != null ? _dateOnly(_startDate!) : null;
      final endStr = _endDate != null ? _dateOnly(_endDate!) : null;
      final offset = (_currentPage - 1) * _pageSize;

      // 1. Fetch total count across ALL database records for this tenant & filter
      final countRes = await _client.rpc(
        'count_audit_logs_for_app',
        params: {
          'p_search': cleanSearch,
          'p_module': cleanModule,
          'p_start_date': startStr,
          'p_end_date': endStr,
        },
      );
      _totalRecords = (countRes as num?)?.toInt() ?? 0;

      // 2. Fetch the specific page batch (50 rows)
      final data = await _client.rpc(
        'list_audit_logs_for_app',
        params: {
          'p_search': cleanSearch,
          'p_module': cleanModule,
          'p_start_date': startStr,
          'p_end_date': endStr,
          'p_limit': _pageSize,
          'p_offset': offset,
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

  String _firstText(Map<String, dynamic> item, List<String> keys,
      [String fallback = '-']) {
    for (final key in keys) {
      final value = AppUi.text(item[key], '');
      if (value.trim().isNotEmpty) return value;
    }
    return fallback;
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2023),
      lastDate: now.add(const Duration(days: 365)),
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
    );
    if (picked == null) return;
    setState(() {
      _startDate = picked.start;
      _endDate = picked.end;
      _currentPage = 1;
    });
    await _loadData();
  }

  Future<void> _jumpToPageDialog() async {
    final controller = TextEditingController(text: '');
    final targetPage = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lompat ke Halaman'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Masukkan nomor halaman (1 s/d ):'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                hintText: 'Nomor halaman',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              final page = int.tryParse(controller.text.trim());
              if (page != null && page >= 1 && page <= _totalPages) {
                Navigator.pop(ctx, page);
              } else {
                AppUi.showSnack('Nomor halaman tidak valid');
              }
            },
            child: const Text('Lompat'),
          ),
        ],
      ),
    );

    if (targetPage != null && targetPage != _currentPage) {
      _loadData(page: targetPage);
    }
  }

  Future<void> _deleteOne(Map<String, dynamic> item) async {
    if (!_canDeleteAuditLog) {
      AppUi.showSnack(
          'Mode demo hanya bisa melihat audit log. Hapus log dikunci.');
      return;
    }

    final auditLogId = AppUi.text(item['audit_log_id'], '').trim();
    if (auditLogId.isEmpty) {
      AppUi.showSnack(
          'ID audit log tidak ditemukan. Refresh halaman lalu coba lagi.');
      return;
    }

    final activity = _firstText(item, ['activity', 'aktivitas']);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus audit log?'),
        content: Text('Log ini akan dihapus permanen.\n\nAktivitas: '),
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
      AppUi.showSnack('Gagal menghapus audit log: ');
    }
  }

  Future<void> _clearAll() async {
    if (!_canDeleteAuditLog) {
      AppUi.showSnack(
          'Mode demo hanya bisa melihat audit log. Hapus log dikunci.');
      return;
    }

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
      await _loadData(page: 1);
    } on PostgrestException catch (error) {
      AppUi.showSnack(error.message);
    } catch (error) {
      AppUi.showSnack('Gagal menghapus audit log: ');
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
        initialChildSize: 0.75,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        builder: (sheetContext, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              'Detail Riwayat Aktivitas & Jejak Error',
              style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 12),
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow('Aktivitas', activity),
                  _detailRow('Modul', module),
                  _detailRow(
                      'User / Pelaku', _firstText(item, ['user_name', 'nama_user'])),
                  _detailRow('Email', _firstText(item, ['user_email'])),
                  _detailRow('Role', AppUi.text(item['role_id'])),
                  _detailRow('Waktu Eksekusi', AppUi.dateTime(item['created_at'])),
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
                    'Data Sebelum (Before)',
                    style:
                        Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                      _firstText(item, ['before_data', 'data_sebelum'])),
                ],
              ),
            ),
            const SizedBox(height: 12),
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Data Sesudah (After)',
                    style:
                        Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                      _firstText(item, ['after_data', 'data_sesudah'])),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (_canDeleteAuditLog)
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
            width: 120,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  Widget _buildPaginationBar() {
    final startIdx = _totalRecords == 0 ? 0 : (_currentPage - 1) * _pageSize + 1;
    final endIdx = ((_currentPage - 1) * _pageSize + _items.length).clamp(0, _totalRecords);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              'Menampilkan $startIdx - $endIdx dari $_totalRecords data log',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.first_page_rounded),
                tooltip: 'Halaman Pertama',
                onPressed: _currentPage > 1 ? () => _loadData(page: 1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded),
                tooltip: 'Halaman Sebelumnya',
                onPressed: _currentPage > 1 ? () => _loadData(page: _currentPage - 1) : null,
              ),
              InkWell(
                onTap: _jumpToPageDialog,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    'Hal $_currentPage / $_totalPages',
                    style: GoogleFonts.outfit(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: const Color(0xFF38BDF8),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded),
                tooltip: 'Halaman Berikutnya',
                onPressed: _currentPage < _totalPages ? () => _loadData(page: _currentPage + 1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.last_page_rounded),
                tooltip: 'Halaman Terakhir',
                onPressed: _currentPage < _totalPages ? () => _loadData(page: _totalPages) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return RefreshIndicator(
      onRefresh: () => _loadData(page: 1),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          FuturisticHeader(
            icon: Icons.history_outlined,
            title: 'Audit Log & Pelacak Error',
            subtitle:
                'Jejak aktivitas seluruh sistem tanpa batas (semua data). Telusuri siapa yang membuat perubahan atau kesalahan operasional.',
            stats: [
              StatPill(
                label: 'Total Record',
                value: _totalRecords.toString(),
                accentColor: const Color(0xFF38BDF8),
              ),
              StatPill(
                label: 'Halaman',
                value: '$_currentPage / $_totalPages',
              ),
              if (_selectedModule != null && _selectedModule != 'Semua')
                StatPill(label: 'Modul', value: _selectedModule!),
            ],
          ),
          const SizedBox(height: 14),

          // Search & Filter Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Search Field
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onSubmitted: (val) {
                          setState(() {
                            _searchQuery = val;
                            _currentPage = 1;
                          });
                          _loadData();
                        },
                        decoration: InputDecoration(
                          hintText: 'Cari user, email, aksi, atau detail error...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                      _currentPage = 1;
                                    });
                                    _loadData();
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() {
                          _searchQuery = _searchController.text;
                          _currentPage = 1;
                        });
                        _loadData();
                      },
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      ),
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('Cari'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Module Filter Chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _moduleOptions.map((mod) {
                      final isSelected = (_selectedModule == null && mod == 'Semua') ||
                          _selectedModule == mod;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(mod),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              _selectedModule = mod == 'Semua' ? null : mod;
                              _currentPage = 1;
                            });
                            _loadData();
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),

                // Date Filter & Action Buttons
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickDateRange,
                      icon: const Icon(Icons.date_range_rounded, size: 18),
                      label: Text(_startDate != null && _endDate != null
                          ? '${AppUi.date(_startDate!)} - ${AppUi.date(_endDate!)}'
                          : 'Filter Rentang Tanggal'),
                    ),
                    if (_startDate != null || _selectedModule != null || _searchQuery.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _startDate = null;
                            _endDate = null;
                            _selectedModule = null;
                            _searchQuery = '';
                            _currentPage = 1;
                          });
                          _loadData();
                        },
                        icon: const Icon(Icons.clear_all_rounded, size: 18),
                        label: const Text('Reset Semua Filter'),
                      ),
                    if (_canDeleteAuditLog)
                      FilledButton.icon(
                        onPressed: _clearAll,
                        style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('Kosongkan Audit Log'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Pagination Top Bar
          if (_totalRecords > 0) ...[
            _buildPaginationBar(),
            const SizedBox(height: 12),
          ],

          // Content List
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_errorMessage != null)
            ErrorState(message: _errorMessage!, onRetry: () => _loadData())
          else if (_items.isEmpty)
            const EmptyState(
              title: 'Tidak Ada Data Audit Log',
              subtitle:
                  'Tidak ditemukan riwayat aktivitas untuk filter pencarian atau tanggal ini.',
            )
          else ...[
            ..._items.map((item) {
              final module = _firstText(item, ['module', 'modul']);
              final activity = _firstText(item, ['activity', 'aktivitas']);
              final user = _firstText(item, ['user_name', 'nama_user']);
              final email = _firstText(item, ['user_email'], '');
              final createdAt = item['created_at'];
              final detail = _firstText(item, ['details', 'detail', 'keterangan', 'data_sesudah', 'after_data'], '');
              final initial =
                  module.isNotEmpty ? module.substring(0, 1).toUpperCase() : 'A';

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: NiceCard(
                  padding: const EdgeInsets.all(12),
                  onTap: () => _openDetail(item),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF38BDF8).withOpacity(0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            initial,
                            style: const TextStyle(
                              color: Color(0xFF0284C7),
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    activity.isNotEmpty ? activity : 'Aktivitas Sistem',
                                    style: GoogleFonts.inter(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13.5,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF38BDF8).withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    module.toUpperCase(),
                                    style: const TextStyle(
                                      color: Color(0xFF0284C7),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 9.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${createdAt != null ? AppUi.dateTime(createdAt) : '-'} • Oleh: ${user.isNotEmpty ? user : "System"} ${email.isNotEmpty ? "($email)" : ""}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppUi.mutedText(context, 0.8),
                              ),
                            ),
                            if (detail.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                detail,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppUi.mutedText(context, 0.65),
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (_canDeleteAuditLog) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Hapus log ini',
                          onPressed: () => _deleteOne(item),
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 12),
            _buildPaginationBar(),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WebResponsiveScaffold(
      title: 'Audit Log & Pelacak Error',
      activeWebTitle: 'Audit Log & Pelacak Error Sistem',
      actions: [
        IconButton(
          onPressed: () => _loadData(),
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh Data',
        ),
      ],
      body: _body(),
    );
  }
}
