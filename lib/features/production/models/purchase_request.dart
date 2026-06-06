class PurchaseRequest {
  final String requestId;
  final String? supplierId;
  final String supplierName;
  final String? nomorNota;
  final DateTime tanggalBeli;
  final String? notaUrl;
  final double totalAmount;
  final String status;
  final String? catatan;
  final String? financeNote;
  final String? createdByName;
  final String? createdByEmail;
  final String? createdByRole;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PurchaseRequest({
    required this.requestId,
    required this.supplierId,
    required this.supplierName,
    required this.nomorNota,
    required this.tanggalBeli,
    required this.notaUrl,
    required this.totalAmount,
    required this.status,
    required this.catatan,
    required this.financeNote,
    required this.createdByName,
    required this.createdByEmail,
    required this.createdByRole,
    required this.createdAt,
    required this.updatedAt,
  });

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static DateTime _toDateTime(dynamic value) {
    return DateTime.tryParse(value?.toString() ?? '')?.toLocal() ??
        DateTime.now();
  }

  factory PurchaseRequest.fromMap(Map<String, dynamic> map) {
    return PurchaseRequest(
      requestId: map['request_id']?.toString() ?? '',
      supplierId: map['supplier_id']?.toString(),
      supplierName: map['supplier_name']?.toString() ?? '-',
      nomorNota: map['nomor_nota']?.toString(),
      tanggalBeli: _toDateTime(map['tanggal_beli']),
      notaUrl: map['nota_url']?.toString(),
      totalAmount: _toDouble(map['total_amount']),
      status: map['status']?.toString() ?? 'waiting_finance',
      catatan: map['catatan']?.toString(),
      financeNote: map['finance_note']?.toString(),
      createdByName: map['created_by_name']?.toString(),
      createdByEmail: map['created_by_email']?.toString(),
      createdByRole: map['created_by_role']?.toString(),
      createdAt: _toDateTime(map['created_at']),
      updatedAt: _toDateTime(map['updated_at']),
    );
  }
}

class PurchaseRequestItem {
  final String itemId;
  final String requestId;
  final String namaBarang;
  final double qty;
  final double hargaSatuan;
  final double subtotal;
  final String? catatan;

  const PurchaseRequestItem({
    required this.itemId,
    required this.requestId,
    required this.namaBarang,
    required this.qty,
    required this.hargaSatuan,
    required this.subtotal,
    required this.catatan,
  });

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  factory PurchaseRequestItem.fromMap(Map<String, dynamic> map) {
    return PurchaseRequestItem(
      itemId: map['item_id']?.toString() ?? '',
      requestId: map['request_id']?.toString() ?? '',
      namaBarang: map['nama_barang']?.toString() ?? '-',
      qty: _toDouble(map['qty']),
      hargaSatuan: _toDouble(map['harga_satuan']),
      subtotal: _toDouble(map['subtotal']),
      catatan: map['catatan']?.toString(),
    );
  }
}

class PurchaseItemInput {
  final String namaBarang;
  final double qty;
  final double hargaSatuan;
  final String? catatan;

  const PurchaseItemInput({
    required this.namaBarang,
    required this.qty,
    required this.hargaSatuan,
    required this.catatan,
  });

  Map<String, dynamic> toJson() {
    return {
      'nama_barang': namaBarang,
      'qty': qty,
      'harga_satuan': hargaSatuan,
      'catatan': catatan,
    };
  }
}