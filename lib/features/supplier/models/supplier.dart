class Supplier {
  final String supplierId;
  final String namaSupplier;
  final String kontak;
  final String alamat;
  final String catatan;
  final String status;

  const Supplier({
    required this.supplierId,
    required this.namaSupplier,
    required this.kontak,
    required this.alamat,
    required this.catatan,
    required this.status,
  });

  factory Supplier.fromMap(Map<String, dynamic> map) {
    return Supplier(
      supplierId: map['supplier_id']?.toString() ?? '',
      namaSupplier:
          (map['nama_supplier'] ?? map['nama'] ?? '-').toString(),
      kontak:
          (map['kontak'] ?? map['phone'] ?? '').toString(),
      alamat: map['alamat']?.toString() ?? '',
      catatan: map['catatan']?.toString() ?? '',
      status: map['status']?.toString() ?? 'active',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (supplierId.isNotEmpty) 'supplier_id': supplierId,
      'nama_supplier': namaSupplier,
      'kontak': kontak,
      'phone': kontak,
      'alamat': alamat,
      'catatan': catatan,
      'status': status,
      'updated_at': DateTime.now().toIso8601String(),
    };
  }
}
