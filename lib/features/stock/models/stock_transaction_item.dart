class StockTransactionItem {
  final String stockTransactionId;
  final String transactionType;
  final double qty;
  final String? sumberTujuan;
  final String? nomorResi;
  final double stockBefore;
  final double stockAfter;
  final String? catatan;
  final DateTime createdAt;
  final String kodeSku;
  final String namaBarang;
  final String namaUser;
  final String emailUser;
  final String? username;

  const StockTransactionItem({
    required this.stockTransactionId,
    required this.transactionType,
    required this.qty,
    required this.sumberTujuan,
    required this.nomorResi,
    required this.stockBefore,
    required this.stockAfter,
    required this.catatan,
    required this.createdAt,
    required this.kodeSku,
    required this.namaBarang,
    required this.namaUser,
    required this.emailUser,
    required this.username,
  });

  String get userDisplay {
    final cleanUsername = username?.trim();
    final cleanEmail = emailUser.trim();
    final cleanNama = namaUser.trim();

    if (cleanUsername != null && cleanUsername.isNotEmpty) {
      return cleanUsername;
    }

    if (cleanEmail.isNotEmpty && cleanEmail != '-') {
      return cleanEmail;
    }

    if (cleanNama.isNotEmpty && cleanNama != '-') {
      return cleanNama;
    }

    return '-';
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static DateTime _parseDateTime(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');

    if (parsed == null) {
      return DateTime.now();
    }

    return parsed.toLocal();
  }

  factory StockTransactionItem.fromMap(Map<String, dynamic> map) {
    final product = map['product'] as Map<String, dynamic>?;
    final user = map['user'] as Map<String, dynamic>?;

    return StockTransactionItem(
      stockTransactionId: map['stock_transaction_id'] as String,
      transactionType: map['transaction_type'] as String? ?? '-',
      qty: _toDouble(map['qty']),
      sumberTujuan: map['sumber_tujuan'] as String?,
      nomorResi: map['nomor_resi'] as String?,
      stockBefore: _toDouble(map['stock_before']),
      stockAfter: _toDouble(map['stock_after']),
      catatan: map['catatan'] as String?,
      createdAt: _parseDateTime(map['created_at']),
      kodeSku: product?['kode_sku'] as String? ?? '-',
      namaBarang: product?['nama_barang'] as String? ?? '-',
      namaUser: user?['nama'] as String? ?? '-',
      emailUser: user?['email'] as String? ?? '-',
      username: user?['username'] as String?,
    );
  }
}