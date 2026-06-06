class WorkLocation {
  final String locationId;
  final String namaLokasi;
  final double latitude;
  final double longitude;
  final double radiusMeter;
  final String? alamat;
  final String? catatan;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  const WorkLocation({
    required this.locationId,
    required this.namaLokasi,
    required this.latitude,
    required this.longitude,
    required this.radiusMeter,
    required this.alamat,
    required this.catatan,
    required this.status,
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

  factory WorkLocation.fromMap(Map<String, dynamic> map) {
    return WorkLocation(
      locationId: map['location_id']?.toString() ?? '',
      namaLokasi: map['nama_lokasi']?.toString() ?? '-',
      latitude: _toDouble(map['latitude']),
      longitude: _toDouble(map['longitude']),
      radiusMeter: _toDouble(map['radius_meter']),
      alamat: map['alamat']?.toString(),
      catatan: map['catatan']?.toString(),
      status: map['status']?.toString() ?? 'inactive',
      createdAt: _toDateTime(map['created_at']),
      updatedAt: _toDateTime(map['updated_at']),
    );
  }

  bool get isActive => status == 'active';
}