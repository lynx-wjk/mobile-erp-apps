import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/attendance_log.dart';
import '../repositories/attendance_repository.dart';

class AbsensiManagementPage extends StatefulWidget {
  const AbsensiManagementPage({super.key});

  @override
  State<AbsensiManagementPage> createState() =>
      _AbsensiManagementPageState();
}

class _AbsensiManagementPageState extends State<AbsensiManagementPage> {
  final _repository = AbsensiRepository();
  final _searchController = TextEditingController();

  bool _isLoading = true;
  String? _errorMessage;

  List<AbsensiLog> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final logs = await _repository.getAllAbsensiLogs();

      if (!mounted) return;

      setState(() {
        _logs = logs;
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;

      setState(() {
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<AbsensiLog> get _filteredLogs {
    final keyword = _searchController.text.trim().toLowerCase();

    if (keyword.isEmpty) return _logs;

    return _logs.where((log) {
      return (log.namaUser ?? '').toLowerCase().contains(keyword) ||
          (log.emailUser ?? '').toLowerCase().contains(keyword) ||
          (log.roleId ?? '').toLowerCase().contains(keyword) ||
          log.attendanceType.toLowerCase().contains(keyword);
    }).toList();
  }

  String _formatDateTime(DateTime dateTime) {
    final d = dateTime.toLocal();

    String two(int value) => value.toString().padLeft(2, '0');

    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorMessage!,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final logs = _filteredLogs;

    if (logs.isEmpty) {
      return const Center(
        child: Text('Data absensi tidak ditemukan.'),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadLogs,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final log = logs[index];

          return Card(
            child: ListTile(
              leading: CircleAvatar(
                child: Icon(
                  log.attendanceType == 'CHECK_IN'
                      ? Icons.login_outlined
                      : Icons.logout_outlined,
                ),
              ),
              title: Text('${log.namaUser ?? '-'} - ${log.typeLabel}'),
              subtitle: Text(
                'Email: ${log.emailUser ?? '-'}\n'
                    'Role: ${log.roleId ?? '-'}\n'
                    'Waktu: ${_formatDateTime(log.createdAt)}\n'
                    'Lokasi: ${log.locationText}\n'
                    'Akurasi: ${log.accuracy?.toStringAsFixed(1) ?? '-'} meter\n'
                    'Catatan: ${log.catatan ?? '-'}',
              ),
              isThreeLine: false,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Absensi Karyawan'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Cari nama / email / role / tipe absensi',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }
}