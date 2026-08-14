// ignore_for_file: unused_element
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';

enum StockChartPeriod { today, last7Days, last30Days, pastMonth, custom }

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

  // Chart & Advanced Filtering States
  StockChartPeriod _chartPeriod = StockChartPeriod.last7Days;
  DateTimeRange? _customDateRange;
  String _selectedSku = 'ALL'; // 'ALL' or specific kode_sku
  String? _selectedSkuName;
  DateTime? _tappedChartDate;
  int? _selectedPointIndex;

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

  (DateTime start, DateTime end) _getPeriodDateRange() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);

    if (_selectedDate != null) {
      final s = DateTime(_selectedDate!.year, _selectedDate!.month, _selectedDate!.day);
      return (s, s.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1)));
    }

    switch (_chartPeriod) {
      case StockChartPeriod.today:
        return (todayStart, todayEnd);
      case StockChartPeriod.last7Days:
        return (todayStart.subtract(const Duration(days: 6)), todayEnd);
      case StockChartPeriod.last30Days:
        return (todayStart.subtract(const Duration(days: 29)), todayEnd);
      case StockChartPeriod.pastMonth:
        final firstDayThisMonth = DateTime(now.year, now.month, 1);
        final lastMonthEnd = firstDayThisMonth.subtract(const Duration(seconds: 1));
        final lastMonthStart = DateTime(lastMonthEnd.year, lastMonthEnd.month, 1);
        return (lastMonthStart, lastMonthEnd);
      case StockChartPeriod.custom:
        if (_customDateRange != null) {
          final s = DateTime(_customDateRange!.start.year, _customDateRange!.start.month, _customDateRange!.start.day);
          final e = DateTime(_customDateRange!.end.year, _customDateRange!.end.month, _customDateRange!.end.day, 23, 59, 59);
          return (s, e);
        }
        return (todayStart.subtract(const Duration(days: 6)), todayEnd);
    }
  }

  Future<void> _loadData() async {
    await _ensureDeletePermission();
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _selectedPointIndex = null;
      _tappedChartDate = null;
    });

    try {
      var query = _client.from('stock_transactions').select(
          'stock_transaction_id, transaction_id, product_id, kode_sku, kode_barcode, nama_barang, transaction_type, jenis_transaksi, qty, sumber_tujuan, nomor_resi, catatan, user_name, user_email, role_id, created_at');

      final range = _getPeriodDateRange();
      query = query
          .gte('created_at', range.$1.toIso8601String())
          .lte('created_at', range.$2.toIso8601String());

      if (_selectedSku != 'ALL') {
        query = query.eq('kode_sku', _selectedSku);
      }

      final data = await query.order('created_at', ascending: false).limit(1000);

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

      final sku = AppUi.text(item['kode_sku']);
      final matchesSku = _selectedSku == 'ALL' || sku.toLowerCase() == _selectedSku.toLowerCase();

      final itemDate = DateTime.tryParse(AppUi.text(item['created_at']))?.toLocal();
      bool matchesTappedDate = true;
      if (_tappedChartDate != null && itemDate != null) {
        if (_chartPeriod == StockChartPeriod.today && _selectedDate == null) {
          matchesTappedDate = itemDate.year == _tappedChartDate!.year &&
              itemDate.month == _tappedChartDate!.month &&
              itemDate.day == _tappedChartDate!.day &&
              itemDate.hour == _tappedChartDate!.hour;
        } else {
          matchesTappedDate = itemDate.year == _tappedChartDate!.year &&
              itemDate.month == _tappedChartDate!.month &&
              itemDate.day == _tappedChartDate!.day;
        }
      }

      final matchesKeyword = AppUi.text(item['nama_barang'])
              .toLowerCase()
              .contains(keyword) ||
          AppUi.text(item['kode_sku']).toLowerCase().contains(keyword) ||
          AppUi.text(item['kode_barcode']).toLowerCase().contains(keyword) ||
          _resiText(item).toLowerCase().contains(keyword) ||
          AppUi.text(item['sumber_tujuan']).toLowerCase().contains(keyword) ||
          AppUi.text(item['user_email']).toLowerCase().contains(keyword);

      return matchesType && matchesSku && matchesTappedDate && matchesKeyword;
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
          value == 'STOK_MASUK') {
        return 'IN';
      }
      if (value == 'OUT' ||
          value == 'KELUAR' ||
          value == 'STOCK_OUT' ||
          value == 'STOK_KELUAR') {
        return 'OUT';
      }
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
    setState(() {
      _selectedDate = picked;
      _chartPeriod = StockChartPeriod.custom;
    });
    await _loadData();
  }

  Future<void> _pickCustomRange() async {
    DateTime start = _customDateRange?.start ?? DateTime.now().subtract(const Duration(days: 7));
    DateTime end = _customDateRange?.end ?? DateTime.now();

    final picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (ctx) {
        DateTime tempStart = start;
        DateTime tempEnd = end;

        return StatefulBuilder(
          builder: (context, setDlgState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;

            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              backgroundColor: cardBg,
              elevation: 12,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.date_range_rounded, color: Color(0xFF38BDF8), size: 22),
                          const SizedBox(width: 10),
                          const Text(
                            'Pilih Rentang Tanggal',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final d = await showDatePicker(
                                  context: context,
                                  initialDate: tempStart,
                                  firstDate: DateTime(2023),
                                  lastDate: DateTime.now().add(const Duration(days: 365)),
                                );
                                if (d != null) {
                                  setDlgState(() {
                                    tempStart = d;
                                    if (tempEnd.isBefore(tempStart)) tempEnd = tempStart;
                                  });
                                }
                              },
                              child: Text(
                                '${tempStart.day}/${tempStart.month}/${tempStart.year}',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('s/d', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          ),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final d = await showDatePicker(
                                  context: context,
                                  initialDate: tempEnd,
                                  firstDate: tempStart,
                                  lastDate: DateTime.now().add(const Duration(days: 365)),
                                );
                                if (d != null) {
                                  setDlgState(() => tempEnd = d);
                                }
                              },
                              child: Text(
                                '${tempEnd.day}/${tempEnd.month}/${tempEnd.year}',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ActionChip(
                            label: const Text('7 Hari'),
                            onPressed: () {
                              setDlgState(() {
                                tempEnd = DateTime.now();
                                tempStart = tempEnd.subtract(const Duration(days: 7));
                              });
                            },
                          ),
                          ActionChip(
                            label: const Text('30 Hari'),
                            onPressed: () {
                              setDlgState(() {
                                tempEnd = DateTime.now();
                                tempStart = tempEnd.subtract(const Duration(days: 30));
                              });
                            },
                          ),
                          ActionChip(
                            label: const Text('Bulan Ini'),
                            onPressed: () {
                              final now = DateTime.now();
                              setDlgState(() {
                                tempStart = DateTime(now.year, now.month, 1);
                                tempEnd = now;
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(context, DateTimeRange(start: tempStart, end: tempEnd));
                        },
                        icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                        label: const Text('Terapkan Filter'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (picked == null) return;
    setState(() {
      _customDateRange = picked;
      _chartPeriod = StockChartPeriod.custom;
      _selectedDate = null;
    });
    await _loadData();
  }

  void _openSkuSelector() {
    // Unique list of SKUs from current workspace / fetched items
    final skuMap = <String, Map<String, dynamic>>{};
    for (final item in _items) {
      final sku = AppUi.text(item['kode_sku']).trim();
      if (sku.isNotEmpty && !skuMap.containsKey(sku)) {
        skuMap[sku] = {
          'kode_sku': sku,
          'nama_barang': AppUi.text(item['nama_barang']),
          'kode_barcode': AppUi.text(item['kode_barcode']),
        };
      }
    }
    final skuList = skuMap.values.toList();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        String modalSearch = '';
        return StatefulBuilder(
          builder: (context, setModalState) {
            final filteredSkuList = skuList.where((e) {
              final kw = modalSearch.toLowerCase();
              return e['kode_sku'].toString().toLowerCase().contains(kw) ||
                  e['nama_barang'].toString().toLowerCase().contains(kw) ||
                  e['kode_barcode'].toString().toLowerCase().contains(kw);
            }).toList();

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.75,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              builder: (context, scrollController) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Pilih SKU Barang',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      onChanged: (val) => setModalState(() => modalSearch = val),
                      decoration: InputDecoration(
                        hintText: 'Cari SKU, Barcode, atau Nama Barang...',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14)),
                        filled: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        children: [
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor: _selectedSku == 'ALL'
                                  ? AppUi.green.withValues(alpha: 0.2)
                                  : Colors.grey.withValues(alpha: 0.15),
                              child: Icon(Icons.apps,
                                  color: _selectedSku == 'ALL'
                                      ? AppUi.green
                                      : Colors.grey),
                            ),
                            title: const Text('Semua SKU (Gabungan)',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: const Text('Tampilkan grafik total semua produk'),
                            trailing: _selectedSku == 'ALL'
                                ? const Icon(Icons.check_circle, color: AppUi.green)
                                : null,
                            onTap: () {
                              Navigator.pop(context);
                              setState(() {
                                _selectedSku = 'ALL';
                                _selectedSkuName = null;
                              });
                              _loadData();
                            },
                          ),
                          const Divider(),
                          ...filteredSkuList.map((item) {
                            final sku = item['kode_sku'].toString();
                            final isSelected = _selectedSku == sku;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isSelected
                                    ? AppUi.green.withValues(alpha: 0.2)
                                    : Colors.blue.withValues(alpha: 0.1),
                                child: Icon(Icons.inventory_2_outlined,
                                    color: isSelected ? AppUi.green : Colors.blue),
                              ),
                              title: Text(sku,
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('${item['nama_barang']}\nBarcode: ${item['kode_barcode']}'),
                              isThreeLine: true,
                              trailing: isSelected
                                  ? const Icon(Icons.check_circle, color: AppUi.green)
                                  : null,
                              onTap: () {
                                Navigator.pop(context);
                                setState(() {
                                  _selectedSku = sku;
                                  _selectedSkuName = item['nama_barang'].toString();
                                });
                                _loadData();
                              },
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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

  List<_StockTrendPoint> _buildChartPoints() {
    final range = _getPeriodDateRange();
    final points = <_StockTrendPoint>[];

    if (_chartPeriod == StockChartPeriod.today && _selectedDate == null) {
      // Group by hour 0..23
      final hourMapIn = <int, num>{};
      final hourMapOut = <int, num>{};
      for (final item in _items) {
        final dt = DateTime.tryParse(AppUi.text(item['created_at']))?.toLocal();
        if (dt != null) {
          final type = _transactionType(item);
          final qty = AppUi.toNum(item['qty']);
          if (type == 'IN') {
            hourMapIn[dt.hour] = (hourMapIn[dt.hour] ?? 0) + qty;
          } else if (type == 'OUT') {
            hourMapOut[dt.hour] = (hourMapOut[dt.hour] ?? 0) + qty;
          }
        }
      }

      // Show interval of 3 hours or every hour
      for (var h = 0; h <= 23; h += 2) {
        final dt = DateTime(range.$1.year, range.$1.month, range.$1.day, h);
        final label = '${h.toString().padLeft(2, '0')}:00';
        final qtyIn = (hourMapIn[h] ?? 0) + (hourMapIn[h + 1] ?? 0);
        final qtyOut = (hourMapOut[h] ?? 0) + (hourMapOut[h + 1] ?? 0);
        points.add(_StockTrendPoint(
          label: label,
          date: dt,
          qtyIn: qtyIn,
          qtyOut: qtyOut,
        ));
      }
    } else {
      // Group by day
      final dayMapIn = <String, num>{};
      final dayMapOut = <String, num>{};

      for (final item in _items) {
        final dt = DateTime.tryParse(AppUi.text(item['created_at']))?.toLocal();
        if (dt != null) {
          final key = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
          final type = _transactionType(item);
          final qty = AppUi.toNum(item['qty']);
          if (type == 'IN') {
            dayMapIn[key] = (dayMapIn[key] ?? 0) + qty;
          } else if (type == 'OUT') {
            dayMapOut[key] = (dayMapOut[key] ?? 0) + qty;
          }
        }
      }

      var curr = DateTime(range.$1.year, range.$1.month, range.$1.day);
      final endDate = DateTime(range.$2.year, range.$2.month, range.$2.day);

      while (!curr.isAfter(endDate)) {
        final key = '${curr.year}-${curr.month.toString().padLeft(2, '0')}-${curr.day.toString().padLeft(2, '0')}';
        final label = '${curr.day}/${curr.month}';
        final qtyIn = dayMapIn[key] ?? 0;
        final qtyOut = dayMapOut[key] ?? 0;

        points.add(_StockTrendPoint(
          label: label,
          date: curr,
          qtyIn: qtyIn,
          qtyOut: qtyOut,
        ));

        curr = curr.add(const Duration(days: 1));
      }
    }

    return points;
  }

  Widget _chartSection(List<_StockTrendPoint> points) {
    final totalIn = _items
        .where((e) => _transactionType(e) == 'IN')
        .fold<num>(0, (sum, item) => sum + AppUi.toNum(item['qty']));
    final totalOut = _items
        .where((e) => _transactionType(e) == 'OUT')
        .fold<num>(0, (sum, item) => sum + AppUi.toNum(item['qty']));
    final netChange = totalIn - totalOut;

    return NiceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Grafik Pergerakan Stok',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _selectedSku == 'ALL'
                          ? 'Mencakup Gabungan Semua SKU'
                          : 'SKU: $_selectedSku ${_selectedSkuName != null ? "• $_selectedSkuName" : ""}',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                          fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _openSkuSelector,
                icon: const Icon(Icons.filter_list, size: 18),
                label: Text(
                  _selectedSku == 'ALL' ? 'Filter SKU' : _selectedSku,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Period Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _periodChip('Hari Ini', StockChartPeriod.today),
                const SizedBox(width: 6),
                _periodChip('7 Hari', StockChartPeriod.last7Days),
                const SizedBox(width: 6),
                _periodChip('30 Hari', StockChartPeriod.last30Days),
                const SizedBox(width: 6),
                _periodChip('Bulan Lalu', StockChartPeriod.pastMonth),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.date_range, size: 16),
                  label: Text(_chartPeriod == StockChartPeriod.custom && _customDateRange != null
                      ? '${AppUi.date(_customDateRange!.start)} - ${AppUi.date(_customDateRange!.end)}'
                      : 'Kustom'),
                  backgroundColor: _chartPeriod == StockChartPeriod.custom
                      ? AppUi.green.withValues(alpha: 0.2)
                      : null,
                  onPressed: _pickCustomRange,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Stat Summary Cards Row
          Row(
            children: [
              Expanded(
                child: _statBox(
                  'Stock In (+)',
                  totalIn.toStringAsFixed(0),
                  AppUi.green,
                  Icons.arrow_downward,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statBox(
                  'Stock Out (-)',
                  totalOut.toStringAsFixed(0),
                  AppUi.red,
                  Icons.arrow_upward,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statBox(
                  'Net Change',
                  '${netChange >= 0 ? "+" : ""}${netChange.toStringAsFixed(0)}',
                  netChange >= 0 ? Colors.teal : Colors.orange,
                  Icons.show_chart,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Legend
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legendDot('Stock In (Masuk)', AppUi.green),
              const SizedBox(width: 20),
              _legendDot('Stock Out (Keluar)', AppUi.red),
            ],
          ),
          const SizedBox(height: 10),

          // Line Chart Canvas Container
          SizedBox(
            height: 180,
            child: points.isEmpty
                ? const Center(child: Text('Tidak ada data grafik di periode ini'))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        onTapDown: (details) {
                          final pointW = constraints.maxWidth / math.max(1, points.length - 1);
                          final dx = details.localPosition.dx;
                          final idx = (dx / pointW).round().clamp(0, points.length - 1);
                          setState(() {
                            _selectedPointIndex = idx;
                            _tappedChartDate = points[idx].date;
                            _applyFilter(_searchController.text);
                          });
                        },
                        child: CustomPaint(
                          size: Size(constraints.maxWidth, 180),
                          painter: _StockLineChartPainter(
                            points: points,
                            selectedIndex: _selectedPointIndex,
                            inColor: AppUi.green,
                            outColor: AppUi.red,
                          ),
                        ),
                      );
                    },
                  ),
          ),

          if (_tappedChartDate != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Menampilkan transaksi untuk tanggal: ${AppUi.date(_tappedChartDate)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _tappedChartDate = null;
                        _selectedPointIndex = null;
                        _applyFilter(_searchController.text);
                      });
                    },
                    child: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _periodChip(String label, StockChartPeriod period) {
    final isSelected = _chartPeriod == period && _selectedDate == null;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      selected: isSelected,
      selectedColor: AppUi.green.withValues(alpha: 0.2),
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _chartPeriod = period;
            _selectedDate = null;
          });
          _loadData();
        }
      },
    );
  }

  Widget _statBox(String title, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold, color: color),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w900, color: color),
          ),
        ],
      ),
    );
  }

  Widget _legendDot(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();

    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadData);
    }

    final chartPoints = _buildChartPoints();

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          FuturisticHeader(
            icon: Icons.receipt_long_outlined,
            title: 'Riwayat Stok & Analitik',
            subtitle:
                'Pantau tren stock in/out harian per SKU, resi, user, dan catatan.',
            stats: [
              StatPill(label: 'Total SKU', value: _selectedSku == 'ALL' ? 'Semua' : _selectedSku),
              StatPill(label: 'Data', value: _items.length.toString()),
              if (_selectedDate != null)
                StatPill(label: 'Tanggal', value: AppUi.date(_selectedDate)),
            ],
          ),
          const SizedBox(height: 14),

          // Dual Line Chart Widget
          _chartSection(chartPoints),
          const SizedBox(height: 16),

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
            if (_selectedDate != null || _tappedChartDate != null || _selectedSku != 'ALL')
              OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _selectedDate = null;
                      _tappedChartDate = null;
                      _selectedPointIndex = null;
                      _selectedSku = 'ALL';
                      _selectedSkuName = null;
                      _chartPeriod = StockChartPeriod.last7Days;
                    });
                    _loadData();
                  },
                  icon: const Icon(Icons.clear),
                  label: const Text('Reset Filter')),
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
                    backgroundColor: color.withValues(alpha: 0.13),
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
    return WebResponsiveScaffold(
      title: 'Riwayat & Analitik Stok',
      actions: [
        if (_canDelete)
          IconButton(
            tooltip: 'Hapus semua riwayat',
            onPressed: _clearAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh)),
      ],
      body: _body(),
    );
  }
}

class _StockTrendPoint {
  final String label;
  final DateTime date;
  final num qtyIn;
  final num qtyOut;

  _StockTrendPoint({
    required this.label,
    required this.date,
    required this.qtyIn,
    required this.qtyOut,
  });
}

class _StockLineChartPainter extends CustomPainter {
  final List<_StockTrendPoint> points;
  final int? selectedIndex;
  final Color inColor;
  final Color outColor;

  _StockLineChartPainter({
    required this.points,
    required this.selectedIndex,
    required this.inColor,
    required this.outColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final gridPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.12)
      ..strokeWidth = 1;

    // Draw horizontal grid lines (4 rows)
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    num maxVal = 1;
    for (final p in points) {
      maxVal = math.max(maxVal, math.max(p.qtyIn, p.qtyOut));
    }

    final padX = 20.0;
    final padY = 25.0;
    final chartW = math.max(1.0, size.width - padX * 2);
    final chartH = math.max(1.0, size.height - padY * 2);

    Offset pos(int i, num val) {
      final x = points.length == 1
          ? size.width / 2
          : padX + chartW * i / (points.length - 1);
      final norm = (val / maxVal).clamp(0.0, 1.0);
      final y = padY + chartH * (1 - norm);
      return Offset(x, y);
    }

    // Path building for Stock In & Stock Out with smooth cubic curves
    final pathIn = Path();
    final pathOut = Path();

    for (var i = 0; i < points.length; i++) {
      final pIn = pos(i, points[i].qtyIn);
      final pOut = pos(i, points[i].qtyOut);

      if (i == 0) {
        pathIn.moveTo(pIn.dx, pIn.dy);
        pathOut.moveTo(pOut.dx, pOut.dy);
      } else {
        final prevIn = pos(i - 1, points[i - 1].qtyIn);
        final prevOut = pos(i - 1, points[i - 1].qtyOut);

        final ctrlX1 = prevIn.dx + (pIn.dx - prevIn.dx) / 2;
        pathIn.cubicTo(ctrlX1, prevIn.dy, ctrlX1, pIn.dy, pIn.dx, pIn.dy);

        final ctrlX2 = prevOut.dx + (pOut.dx - prevOut.dx) / 2;
        pathOut.cubicTo(ctrlX2, prevOut.dy, ctrlX2, pOut.dy, pOut.dx, pOut.dy);
      }
    }

    // Draw soft background gradient fills beneath line curves
    if (points.length > 1) {
      final fillIn = Path.from(pathIn)
        ..lineTo(pos(points.length - 1, points.last.qtyIn).dx, size.height - padY)
        ..lineTo(pos(0, points.first.qtyIn).dx, size.height - padY)
        ..close();

      final gradientIn = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [inColor.withValues(alpha: 0.18), inColor.withValues(alpha: 0.0)],
      );
      final fillPaintIn = Paint()
        ..shader = gradientIn.createShader(Rect.fromLTWH(0, padY, size.width, chartH))
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillIn, fillPaintIn);
    }

    // Draw stroke lines
    final linePaintIn = Paint()
      ..color = inColor
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final linePaintOut = Paint()
      ..color = outColor
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(pathIn, linePaintIn);
    canvas.drawPath(pathOut, linePaintOut);

    // Draw dots and X-axis labels
    final dotPaintIn = Paint()..color = inColor;
    final dotPaintOut = Paint()..color = outColor;
    final dotBorderPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final textStyle = TextStyle(
      color: Colors.grey.shade600,
      fontSize: 10,
      fontWeight: FontWeight.w600,
    );

    // Decide label frequency
    final step = points.length > 12 ? (points.length / 6).ceil() : 1;

    for (var i = 0; i < points.length; i++) {
      final pIn = pos(i, points[i].qtyIn);
      final pOut = pos(i, points[i].qtyOut);

      final isSelected = selectedIndex == i;
      final radius = isSelected ? 5.5 : 3.5;

      // Draw Stock In Dot
      canvas.drawCircle(pIn, radius, dotPaintIn);
      canvas.drawCircle(pIn, radius, dotBorderPaint);

      // Draw Stock Out Dot
      canvas.drawCircle(pOut, radius, dotPaintOut);
      canvas.drawCircle(pOut, radius, dotBorderPaint);

      // X-axis date labels
      if (i % step == 0 || i == points.length - 1) {
        final tp = TextPainter(
          text: TextSpan(text: points[i].label, style: textStyle),
          textDirection: TextDirection.ltr,
        );
        tp.layout();
        tp.paint(canvas, Offset(pIn.dx - tp.width / 2, size.height - 14));
      }
    }

    // Draw selected tooltip
    if (selectedIndex != null && selectedIndex! < points.length) {
      final idx = selectedIndex!;
      final pIn = pos(idx, points[idx].qtyIn);
      final pt = points[idx];

      final selectionPaint = Paint()
        ..color = Colors.blue.withValues(alpha: 0.3)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.drawLine(
        Offset(pIn.dx, padY),
        Offset(pIn.dx, size.height - 18),
        selectionPaint,
      );

      final tooltipText = 'In: ${pt.qtyIn.toStringAsFixed(0)} | Out: ${pt.qtyOut.toStringAsFixed(0)}';
      final tooltipPainter = TextPainter(
        text: TextSpan(
          text: tooltipText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tooltipPainter.layout();

      final boxWidth = tooltipPainter.width + 16;
      final boxHeight = tooltipPainter.height + 8;
      var boxX = pIn.dx - boxWidth / 2;
      boxX = boxX.clamp(4.0, size.width - boxWidth - 4.0);
      final boxY = 2.0;

      final bgPaint = Paint()
        ..color = Colors.black87
        ..style = PaintingStyle.fill;
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(boxX, boxY, boxWidth, boxHeight),
        const Radius.circular(6),
      );
      canvas.drawRRect(rrect, bgPaint);

      tooltipPainter.paint(
        canvas,
        Offset(boxX + 8, boxY + 4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StockLineChartPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.selectedIndex != selectedIndex;
  }
}

