class Product {
  final String productId;
  final String kodeSku;
  final String? kodeBarcode;
  final String namaBarang;
  final String? kategori;
  final String satuan;
  final double stockAwal;
  final double stockSaatIni;
  final double lowStockLimit;
  final String? lokasiRak;
  final String status;

  const Product({
    required this.productId,
    required this.kodeSku,
    required this.kodeBarcode,
    required this.namaBarang,
    required this.kategori,
    required this.satuan,
    required this.stockAwal,
    required this.stockSaatIni,
    required this.lowStockLimit,
    required this.lokasiRak,
    required this.status,
  });

  bool get isLowStock => stockSaatIni <= lowStockLimit;

  String get barcodeValue {
    final barcode = kodeBarcode?.trim();

    if (barcode != null && barcode.isNotEmpty) {
      return barcode;
    }

    return kodeSku;
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      productId: map['product_id'] as String,
      kodeSku: map['kode_sku'] as String? ?? '',
      kodeBarcode: map['kode_barcode'] as String?,
      namaBarang: map['nama_barang'] as String? ?? '',
      kategori: map['kategori'] as String?,
      satuan: map['satuan'] as String? ?? 'pcs',
      stockAwal: _toDouble(map['stock_awal']),
      stockSaatIni: _toDouble(map['stock_saat_ini']),
      lowStockLimit: _toDouble(map['low_stock_limit']),
      lokasiRak: map['lokasi_rak'] as String?,
      status: map['status'] as String? ?? 'active',
    );
  }
}
