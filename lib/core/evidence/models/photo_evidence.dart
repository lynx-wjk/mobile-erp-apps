class PhotoEvidence {
  final String evidenceId;
  final String moduleName;
  final String purpose;
  final String? referenceId;

  final String publicUrl;
  final String storagePath;
  final String? localPath;

  final double latitude;
  final double longitude;
  final double? accuracyMeter;

  final DateTime capturedAt;
  final String? createdBy;
  final DateTime createdAt;

  const PhotoEvidence({
    required this.evidenceId,
    required this.moduleName,
    required this.purpose,
    required this.referenceId,
    required this.publicUrl,
    required this.storagePath,
    this.localPath,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeter,
    required this.capturedAt,
    required this.createdBy,
    required this.createdAt,
  });

  factory PhotoEvidence.fromMap(Map<String, dynamic> map) {
    final filePath = map['file_path']?.toString();
    final storagePath = map['storage_path']?.toString();

    return PhotoEvidence(
      evidenceId: map['evidence_id']?.toString() ?? '',
      moduleName: map['module_name']?.toString() ?? '',
      purpose: map['purpose']?.toString() ?? '',
      referenceId: map['reference_id']?.toString(),
      publicUrl: map['public_url']?.toString() ?? '',
      storagePath: storagePath ?? filePath ?? '',
      localPath: null,
      latitude: _toDouble(map['latitude']),
      longitude: _toDouble(map['longitude']),
      accuracyMeter: _toNullableDouble(map['accuracy_meter']),
      capturedAt: _toDateTime(map['captured_at']),
      createdBy: map['created_by']?.toString(),
      createdAt: _toDateTime(map['created_at']),
    );
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static double? _toNullableDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static DateTime _toDateTime(dynamic value) {
    return DateTime.tryParse(value?.toString() ?? '')?.toLocal() ??
        DateTime.now();
  }

  // Alias biar kode lama yang masih manggil bucketId / filePath tidak langsung hancur.
  String get bucketId {
    if (storagePath.startsWith('google_drive:')) {
      return 'google_drive';
    }

    return 'evidence-photos';
  }

  String get filePath => storagePath;
}