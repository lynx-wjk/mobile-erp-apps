// ignore_for_file: unused_element
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';

class StockHistoryPage extends StatefulWidget {
  const StockHistoryPage({super.key});

  @override
  State<StockHistoryPage> createState() => _StockHistoryPageState();
}

class _StockHistoryPageState extends State<StockHistoryPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  String? _errorMessage;
  String _type = 'ALL';
  DateTime? _selectedDate;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _canDelete = false;
  bool _permissionLoaded = false;

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

  Future<void> _loadData() async {
    await _ensureDeletePermission();
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      var query = _client.from('stock_transactions').select(
          'stock_transaction_id, transaction_id, product_id, kode_sku, kode_barcode, nama_barang, transaction_type, jenis_transaksi, qty, sumber_tujuan, nomor_resi, catatan, user_name, user_email, role_id, created_at');

      if (_selectedDate != null) {
        final start = DateTime(
            _selectedDate!.year, _selectedDate!.month, _selectedDate!.day);
        final end = start.add(const Duration(days: 1));
        query = query
            .gte('created_at', start.toIso8601String())
            .lt('created_at', end.toIso8601String());
      }

      final data = await query.order('created_at', ascending: false).limit(500);

      final items =
          (data as List).map((e) => Map<String, dynamic>.from(e)).toList();

      if (!mounted) return;

      setState(() {
        _items = items;
        _applyFilter(_searchController.text, notify: false);
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

  void _applyFilter(String value, {bool notify = true}) {
    final keyword = value.trim().toLowerCase();

    final result = _items.where((item) {
      final transactionType = _transactionType(item);
      final matchesType = _type == 'ALL' || transactionType == _type;
      final matchesKeyword = AppUi.text(item['nama_barang'])
              .toLowerCase()
              .contains(keyword) ||
          AppUi.text(item['kode_sku']).toLowerCase().contains(keyword) ||
          AppUi.text(item['kode_barcode']).toLowerCase().contains(keyword) ||
          _resiText(item).toLowerCase().contains(keyword) ||
          AppUi.text(item['sumber_tujuan']).toLowerCase().contains(keyword) ||
          AppUi.text(item['user_email']).toLowerCase().contains(keyword);

      return matchesType && matchesKeyword;
    }).toList();

    if (notify) {
      setState(() => _filtered = result);
    } else {
      _filtered = result;
    }
  }

  Future<void> _ensureDeletePermission() async {
    if (_permissionLoaded) return;
    try {
      final result = await _client.rpc('current_user_can_delete_stock_history');
      _canDelete = result == true || result.toString().toLowerCase() == 'true';
    } catch (_) {
      _canDelete = false;
    } finally {
      _permissionLoaded = true;
    }
  }

  String _resiText(Map<String, dynamic> item) {
    final keys = ['nomor_resi', 'tracking_number', 'resi', 'no_resi'];
    for (final key in keys) {
      final value = AppUi.text(item[key], '').trim();
      if (value.isNotEmpty && value != '-') return value;
    }
    return '-';
  }

  String _stockTransactionId(Map<String, dynamic> item) {
    final value = AppUi.text(item['stock_transaction_id'], '').trim();
    if (value.isNotEmpty) return value;
    return AppUi.text(item['transaction_id'], '').trim();
  }

  String _transactionType(Map<String, dynamic> item) {
    final values = [
      AppUi.text(item['jenis_transaksi']),
      AppUi.text(item['transaction_type']),
      AppUi.text(item['type']),
    ].map((e) => e.trim().toUpperCase()).where((e) => e.isNotEmpty).toList();

    for (final value in values) {
      if (value == 'IN' ||
          value == 'MASUK' ||
          value == 'STOCK_IN' ||
          value == 'STOK_MASUK') return 'IN';
      if (value == 'OUT' ||
          value == 'KELUAR' ||
          value == 'STOCK_OUT' ||
          value == 'STOK_KELUAR') return 'OUT';
    }

    return values.isEmpty ? '-' : values.first;
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
    final transactionId = _stockTransactionId(item);
    if (transactionId.isEmpty) {
      AppUi.showSnack(
          'ID transaksi stok tidak ditemukan. Refresh halaman lalu coba lagi.');
      return;
    }

    final productName = AppUi.text(item['nama_barang'], '-');
    final resi = _resiText(item);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus transaksi stok?'),
        content: Text(
          'Transaksi akan dihapus permanen. Untuk stock out, stok barang akan dikembalikan sesuai qty transaksi.\n\nProduk: $productName\nResi: $resi',
        ),
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
      final response = await _client.rpc(
        'delete_stock_transaction_for_app',
        params: {'p_stock_transaction_id': transactionId},
      );
      final message = response is Map
          ? AppUi.text(response['message'], 'Transaksi stok berhasil dihapus.')
          : 'Transaksi stok berhasil dihapus.';
      AppUi.showSnack(message);
      await _loadData();
    } on PostgrestException catch (error) {
      AppUi.showSnack(error.message);
    } catch (error) {
      AppUi.showSnack('Gagal menghapus transaksi stok: $error');
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus semua riwayat stok?'),
        content: const Text(
            'Gunakan hanya setelah data selesai direkap. Riwayat stok akan dihapus permanen.'),
        actions: [
          TextButton(
              onPressed: () => AppUi.safePop(context, false),
              child: const Text('Batal')),
          FilledButton(
              onPressed: () => AppUi.safePop(context, true),
              child: const Text('Hapus Semua')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _client.rpc('clear_stock_history_for_app');
      AppUi.showSnack('Riwayat stok berhasil dikosongkan.');
      await _loadData();
    } on PostgrestException catch (error) {
      AppUi.showSnack(error.message);
    } catch (error) {
      AppUi.showSnack('Gagal hapus riwayat stok: $error');
    }
  }

  void _openDetail(Map<String, dynamic> item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(18),
        child: ListView(
          shrinkWrap: true,
          children: [
            Text('Detail Riwayat Stok',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            NiceCard(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  _detailRow('Transaksi', _transactionType(item)),
                  _detailRow('Produk', AppUi.text(item['nama_barang'])),
                  _detailRow('SKU', AppUi.text(item['kode_sku'])),
                  _detailRow('Barcode', AppUi.text(item['kode_barcode'])),
                  _detailRow(
                      'Qty', AppUi.toNum(item['qty']).toStringAsFixed(0)),
                  _detailRow(
                      'Sumber/Tujuan', AppUi.text(item['sumber_tujuan'])),
                  _detailRow('Resi', _resiText(item)),
                  _detailRow('Catatan', AppUi.text(item['catatan'])),
                  _detailRow('User', AppUi.text(item['user_name'])),
                  _detailRow('Email', AppUi.text(item['user_email'])),
                  _detailRow('Role', AppUi.text(item['role_id'])),
                  _detailRow('Waktu', AppUi.dateTime(item['created_at'])),
                ])),
            if (_canDelete) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _deleteOne(item);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Hapus Transaksi Ini'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 120,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w800))),
        Expanded(child: SelectableText(value)),
      ]),
    );
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();

    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadData);
    }

    final totalIn = _items
        .where((e) => _transactionType(e) == 'IN')
        .fold<num>(0, (sum, item) => sum + AppUi.toNum(item['qty']));
    final totalOut = _items
        .where((e) => _transactionType(e) == 'OUT')
        .fold<num>(0, (sum, item) => sum + AppUi.toNum(item['qty']));

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          FuturisticHeader(
            icon: Icons.receipt_long_outlined,
            title: 'Riwayat Stok',
            subtitle:
                'Pantau stok masuk, stok keluar, resi, user, dan catatan.',
            stats: [
              StatPill(label: 'Masuk', value: totalIn.toStringAsFixed(0)),
              StatPill(label: 'Keluar', value: totalOut.toStringAsFixed(0)),
              StatPill(label: 'Data', value: _items.length.toString()),
              if (_selectedDate != null)
                StatPill(label: 'Tanggal', value: AppUi.date(_selectedDate)),
            ],
          ),
          const SizedBox(height: 14),
          SearchBox(
            controller: _searchController,
            onChanged: _applyFilter,
            hint: 'Cari SKU, barcode, produk, resi, atau user',
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 10, children: [
            OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.date_range),
                label: Text(_selectedDate == null
                    ? 'Filter Tanggal'
                    : AppUi.date(_selectedDate))),
            if (_selectedDate != null)
              OutlinedButton.icon(
                  onPressed: () {
                    setState(() => _selectedDate = null);
                    _loadData();
                  },
                  icon: const Icon(Icons.clear),
                  label: const Text('Reset')),
          ]),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ALL', label: Text('Semua')),
              ButtonSegment(value: 'IN', label: Text('Masuk')),
              ButtonSegment(value: 'OUT', label: Text('Keluar')),
            ],
            selected: {_type},
            onSelectionChanged: (value) {
              setState(() => _type = value.first);
              _applyFilter(_searchController.text);
            },
          ),
          const SizedBox(height: 14),
          if (_filtered.isEmpty)
            const EmptyState(
              title: 'Belum ada riwayat',
              subtitle: 'Transaksi stok masuk dan keluar akan tampil di sini.',
            )
          else
            ..._filtered.map((item) {
              final type = _transactionType(item);
              final color = type == 'IN' ? AppUi.green : AppUi.red;

              return NiceCard(
                padding: EdgeInsets.zero,
                onTap: () => _openDetail(item),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: CircleAvatar(
                    backgroundColor: color.withOpacity(0.13),
                    child: Icon(
                        type == 'IN' ? Icons.south_west : Icons.north_east,
                        color: color),
                  ),
                  title: Text(
                    '${type == 'IN' ? '+' : '-'}${AppUi.toNum(item['qty']).toStringAsFixed(0)} • ${AppUi.text(item['nama_barang'])}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    'SKU: ${AppUi.text(item['kode_sku'])} • Barcode: ${AppUi.text(item['kode_barcode'])}\n'
                    '${AppUi.text(item['sumber_tujuan'])} • Resi: ${_resiText(item)}\n'
                    '${AppUi.text(item['user_email'])} • ${AppUi.text(item['role_id'])}\n'
                    '${AppUi.dateTime(item['created_at'])}',
                  ),
                  isThreeLine: true,
                  trailing: _canDelete
                      ? IconButton(
                          tooltip: 'Hapus transaksi',
                          onPressed: () => _deleteOne(item),
                          icon: const Icon(Icons.delete_outline),
                        )
                      : const Icon(Icons.chevron_right),
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
        title: const Text('Riwayat Stok'),
        actions: [
          if (_canDelete)
            IconButton(
              tooltip: 'Hapus semua riwayat',
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _body(),
    );
  }
}
