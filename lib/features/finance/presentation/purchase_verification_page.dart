import 'package:flutter/material.dart';
import '../../../core/ui/app_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PurchaseVerificationPage extends StatefulWidget {
  const PurchaseVerificationPage({super.key});

  @override
  State<PurchaseVerificationPage> createState() =>
      _PurchaseVerificationPageState();
}

class _PurchaseVerificationPageState extends State<PurchaseVerificationPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  String? _errorMessage;
  List<_PurchaseHeader> _items = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await _client.rpc('list_purchases_for_app');

      if (!mounted) return;

      final items = (data as List)
          .map(
            (item) => _PurchaseHeader.fromMap(
              Map<String, dynamic>.from(item),
            ),
          )
          .toList();

      setState(() {
        _items = items;
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openDetail(_PurchaseHeader item) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _PurchaseVerificationDetailPage(
          purchase: item,
        ),
      ),
    );

    if (result == true) {
      _loadData();
    }
  }

  String _money(num value) {
    return AppUi.money(value);
  }

  String _date(DateTime? value) {
    if (value == null) return '-';

    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.day)}/${two(value.month)}/${value.year}';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'verified_finance':
      case 'approved':
        return Colors.green;
      case 'rejected':
      case 'cancelled':
        return Colors.red;
      case 'revision':
        return Colors.orange;
      case 'submitted':
        return Colors.blue;
      case 'draft':
        return Colors.grey;
      default:
        return Colors.blueGrey;
    }
  }

  Widget _summaryCard() {
    final submitted = _items.where((item) => item.status == 'submitted').length;

    final approved = _items.where((item) {
      return item.status == 'verified_finance' || item.status == 'approved';
    }).length;

    final rejected = _items.where((item) => item.status == 'rejected').length;

    final revision = _items.where((item) => item.status == 'revision').length;

    final total = _items
        .where((item) => item.status != 'rejected' && item.status != 'cancelled')
        .fold<num>(
          0,
          (sum, item) => sum + item.totalPembelian,
        );

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            blurRadius: 0,
            offset: Offset(6, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.verified_outlined,
            color: Theme.of(context).colorScheme.onSurface,
            size: 34,
          ),
          SizedBox(height: 12),
          Text(
            'Verifikasi Pembelian',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Cek nota, item, total, foto bukti, lalu approve, revisi, atau reject.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.76),
              height: 1.35,
            ),
          ),
          SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _miniStat('Submitted', submitted.toString()),
              _miniStat('Approved', approved.toString()),
              _miniStat('Revision', revision.toString()),
              _miniStat('Rejected', rejected.toString()),
              _miniStat('Total', 'Rp ${_money(total)}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Container(
      width: 132,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.11),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.72),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _purchaseCard(_PurchaseHeader item, int index) {
    final color = _statusColor(item.status);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(
        milliseconds: 220 + (index * 30).clamp(0, 260),
      ),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 16 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.all(14),
          leading: CircleAvatar(
            backgroundColor: color.withOpacity(0.14),
            child: Icon(
              Icons.receipt_long_outlined,
              color: color,
            ),
          ),
          title: Text(
            item.nomorPembelian,
            style: TextStyle(
              fontWeight: FontWeight.w900,
            ),
          ),
          subtitle: Text(
            '${item.supplierName} • ${_date(item.tanggal)}\n'
            '${item.status} • Rp ${_money(item.totalPembelian)}',
          ),
          isThreeLine: true,
          trailing: Icon(Icons.chevron_right),
          onTap: () => _openDetail(item),
        ),
      ),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(),
      );
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

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          _summaryCard(),
          SizedBox(height: 18),
          Text(
            'Data Pembelian',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
          ),
          SizedBox(height: 10),
          if (_items.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Text('Belum ada data pembelian.'),
              ),
            )
          else
            ..._items.asMap().entries.map(
                  (entry) => _purchaseCard(
                    entry.value,
                    entry.key,
                  ),
                ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Verifikasi Pembelian'),
        actions: [
          IconButton(
            onPressed: _loadData,
            icon: Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(),
    );
  }
}

class _PurchaseVerificationDetailPage extends StatefulWidget {
  final _PurchaseHeader purchase;

  const _PurchaseVerificationDetailPage({
    required this.purchase,
  });

  @override
  State<_PurchaseVerificationDetailPage> createState() =>
      _PurchaseVerificationDetailPageState();
}

class _PurchaseVerificationDetailPageState
    extends State<_PurchaseVerificationDetailPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _noteController = TextEditingController();

  bool _isLoading = true;
  bool _isUpdating = false;
  String? _errorMessage;
  List<_PurchaseItem> _items = [];

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadItems() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await _client.rpc(
        'list_purchase_items_for_app',
        params: {
          'p_purchase_id': widget.purchase.purchaseId,
        },
      );

      if (!mounted) return;

      final items = (data as List)
          .map(
            (item) => _PurchaseItem.fromMap(
              Map<String, dynamic>.from(item),
            ),
          )
          .toList();

      setState(() {
        _items = items;
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _updateStatus(String status) async {
    setState(() => _isUpdating = true);
    var success = false;

    try {
      await _client.rpc(
        'set_purchase_status_for_app',
        params: {
          'p_purchase_id': widget.purchase.purchaseId,
          'p_status': status,
          'p_note': _noteController.text.trim().isEmpty
              ? null
              : _noteController.text.trim(),
        },
      );

      success = true;
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PostgrestException catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(error.message),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Gagal update status: $error'),
        ),
      );
    } finally {
      if (!success && mounted) {
        setState(() => _isUpdating = false);
      }
    }
  }

  Future<void> _deletePurchase() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Hapus Pembelian?'),
          content: Text(
            'Data pembelian dan semua itemnya akan dihapus. Aksi ini hanya bisa dilakukan oleh Super Admin.',
          ),
          actions: [
            TextButton(
              onPressed: () => AppUi.safePop(context, false),
              child: Text('Batal'),
            ),
            FilledButton.icon(
              onPressed: () => AppUi.safePop(context, true),
              icon: Icon(Icons.delete_outline),
              label: Text('Hapus'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() => _isUpdating = true);
    var success = false;

    try {
      await _client.rpc(
        'delete_purchase_by_admin',
        params: {
          'p_purchase_id': widget.purchase.purchaseId,
        },
      );

      success = true;
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PostgrestException catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(error.message),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Gagal hapus pembelian: $error'),
        ),
      );
    } finally {
      if (!success && mounted) {
        setState(() => _isUpdating = false);
      }
    }
  }

  String _money(num value) {
    return AppUi.money(value);
  }

  String _dateTime(DateTime? value) {
    if (value == null) return '-';

    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.day)}/${two(value.month)}/${value.year} ${two(value.hour)}:${two(value.minute)}';
  }

  String? _driveThumbnailUrl(String? rawUrl) {
    final url = rawUrl?.trim() ?? '';

    if (url.isEmpty) return null;

    final uri = Uri.tryParse(url);
    final queryId = uri?.queryParameters['id'];

    if (queryId != null && queryId.isNotEmpty) {
      return 'https://drive.google.com/thumbnail?id=$queryId&sz=w1200';
    }

    final match = RegExp(r'/d/([^/]+)').firstMatch(url);
    final pathId = match?.group(1);

    if (pathId != null && pathId.isNotEmpty) {
      return 'https://drive.google.com/thumbnail?id=$pathId&sz=w1200';
    }

    return url;
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }

  Widget _headerCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            blurRadius: 0,
            offset: Offset(6, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            color: Theme.of(context).colorScheme.onSurface,
            size: 34,
          ),
          SizedBox(height: 12),
          Text(
            widget.purchase.nomorPembelian,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 8),
          Text(
            widget.purchase.supplierName,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.76),
            ),
          ),
          SizedBox(height: 14),
          Text(
            'Rp ${_money(widget.purchase.totalPembelian)}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 26,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard() {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _infoRow('Status', widget.purchase.status),
            _infoRow('Dibuat Oleh', widget.purchase.createdByName),
            _infoRow('Email', widget.purchase.createdByEmail),
            _infoRow('Role', widget.purchase.createdByRole),
            _infoRow('Tanggal', _dateTime(widget.purchase.createdAt)),
            _infoRow(
              'Lokasi',
              widget.purchase.latitude == null ||
                      widget.purchase.longitude == null
                  ? '-'
                  : '${widget.purchase.latitude}, ${widget.purchase.longitude}',
            ),
            _infoRow('Catatan', widget.purchase.catatan ?? '-'),
          ],
        ),
      ),
    );
  }

  Widget _photoCard() {
    final url = _driveThumbnailUrl(widget.purchase.photoUrl);

    if (url == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Foto nota tidak ada.'),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              'Foto Nota',
              style: TextStyle(
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          AspectRatio(
            aspectRatio: 3 / 4,
            child: Image.network(
              url,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;

                return Center(
                  child: CircularProgressIndicator(),
                );
              },
              errorBuilder: (context, error, stackTrace) {
                return Padding(
                  padding: const EdgeInsets.all(18),
                  child: Center(
                    child: Text(
                      'Foto gagal dimuat.\n${widget.purchase.photoUrl}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Item Pembelian',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
        ),
        SizedBox(height: 8),
        if (_items.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Belum ada item.'),
            ),
          )
        else
          ..._items.map((item) {
            return Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: ListTile(
                title: Text(
                  item.namaBarang,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: Text(
                  'SKU: ${item.kodeSku ?? '-'}\n'
                  '${item.qty.toStringAsFixed(0)} ${item.satuan} x Rp ${_money(item.hargaItem)}',
                ),
                isThreeLine: true,
                trailing: Text(
                  'Rp ${_money(item.subtotal)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _actionButtons() {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Update Status Pembelian',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Catatan Finance / Super Admin',
                hintText: 'Isi catatan approve, reject, atau revisi',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _isUpdating ? null : () => _updateStatus('rejected'),
                    icon: Icon(Icons.close),
                    label: Text('Reject'),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _isUpdating ? null : () => _updateStatus('revision'),
                    icon: Icon(Icons.edit_note_outlined),
                    label: Text('Revision'),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isUpdating
                    ? null
                    : () => _updateStatus('verified_finance'),
                icon: _isUpdating
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(Icons.check_circle_outline),
                label: Text(
                  _isUpdating ? 'Updating...' : 'Approve Finance',
                ),
              ),
            ),
            SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isUpdating ? null : _deletePurchase,
                icon: Icon(Icons.delete_outline),
                label: Text('Hapus Pembelian'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(),
      );
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

    return RefreshIndicator(
      onRefresh: _loadItems,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          _headerCard(),
          SizedBox(height: 12),
          _infoCard(),
          SizedBox(height: 12),
          _photoCard(),
          SizedBox(height: 12),
          _itemsSection(),
          SizedBox(height: 12),
          _actionButtons(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Detail Verifikasi'),
        actions: [
          IconButton(
            onPressed: _loadItems,
            icon: Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(),
    );
  }
}

class _PurchaseHeader {
  final String purchaseId;
  final String nomorPembelian;
  final DateTime? tanggal;
  final String supplierName;
  final num totalPembelian;
  final String status;
  final String? catatan;
  final String? photoUrl;
  final num? latitude;
  final num? longitude;
  final String createdByName;
  final String createdByEmail;
  final String createdByRole;
  final DateTime? createdAt;

  const _PurchaseHeader({
    required this.purchaseId,
    required this.nomorPembelian,
    required this.tanggal,
    required this.supplierName,
    required this.totalPembelian,
    required this.status,
    required this.catatan,
    required this.photoUrl,
    required this.latitude,
    required this.longitude,
    required this.createdByName,
    required this.createdByEmail,
    required this.createdByRole,
    required this.createdAt,
  });

  factory _PurchaseHeader.fromMap(Map<String, dynamic> map) {
    return _PurchaseHeader(
      purchaseId: map['purchase_id']?.toString() ?? '',
      nomorPembelian: map['nomor_pembelian']?.toString() ?? '-',
      tanggal: _toDate(map['tanggal']),
      supplierName: map['supplier_name']?.toString() ?? '-',
      totalPembelian: _toNum(map['total_pembelian']),
      status: map['status']?.toString() ?? 'draft',
      catatan: map['catatan']?.toString(),
      photoUrl: map['photo_url']?.toString(),
      latitude: _toNullableNum(map['latitude']),
      longitude: _toNullableNum(map['longitude']),
      createdByName: map['created_by_name']?.toString() ?? '-',
      createdByEmail: map['created_by_email']?.toString() ?? '-',
      createdByRole: map['created_by_role']?.toString() ?? '-',
      createdAt: _toDate(map['created_at']),
    );
  }
}

class _PurchaseItem {
  final String itemId;
  final String? kodeSku;
  final String? kodeBarcode;
  final String namaBarang;
  final num qty;
  final String satuan;
  final num hargaItem;
  final num subtotal;

  const _PurchaseItem({
    required this.itemId,
    required this.kodeSku,
    required this.kodeBarcode,
    required this.namaBarang,
    required this.qty,
    required this.satuan,
    required this.hargaItem,
    required this.subtotal,
  });

  factory _PurchaseItem.fromMap(Map<String, dynamic> map) {
    return _PurchaseItem(
      itemId: map['item_id']?.toString() ?? '',
      kodeSku: map['kode_sku']?.toString(),
      kodeBarcode: map['kode_barcode']?.toString(),
      namaBarang: map['nama_barang']?.toString() ?? '-',
      qty: _toNum(map['qty']),
      satuan: map['satuan']?.toString() ?? 'pcs',
      hargaItem: _toNum(map['harga_item']),
      subtotal: _toNum(map['subtotal']),
    );
  }
}

DateTime? _toDate(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString())?.toLocal();
}

num _toNum(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  return num.tryParse(value.toString()) ?? 0;
}

num? _toNullableNum(dynamic value) {
  if (value == null) return null;
  if (value is num) return value;
  return num.tryParse(value.toString());
}
