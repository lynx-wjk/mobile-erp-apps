class ProductionProgress {
  final String progressId;
  final String productName;
  final String? sku;
  final double qty;
  final String status;
  final String? sourceNote;
  final DateTime? targetFinishDate;
  final String? proofUrl;
  final String? catatan;
  final String? createdByName;
  final String? createdByEmail;
  final String? createdByRole;
  final DateTime? finishedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ProductionProgress({
    required this.progressId,
    required this.productName,
    required this.sku,
    required this.qty,
    required this.status,
    required this.sourceNote,
    required this.targetFinishDate,
    required this.proofUrl,
    required this.catatan,
    required this.createdByName,
    required this.createdByEmail,
    required this.createdByRole,
    required this.finishedAt,
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

  static DateTime? _toNullableDateTime(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  factory ProductionProgress.fromMap(Map<String, dynamic> map) {
    return ProductionProgress(
      progressId: map['progress_id']?.toString() ?? '',
      productName: map['product_name']?.toString() ?? '-',
      sku: map['sku']?.toString(),
      qty: _toDouble(map['qty']),
      status: map['status']?.toString() ?? 'progress',
      sourceNote: map['source_note']?.toString(),
      targetFinishDate: _toNullableDateTime(map['target_finish_date']),
      proofUrl: map['proof_url']?.toString(),
      catatan: map['catatan']?.toString(),
      createdByName: map['created_by_name']?.toString(),
      createdByEmail: map['created_by_email']?.toString(),
      createdByRole: map['created_by_role']?.toString(),
      finishedAt: _toNullableDateTime(map['finished_at']),
      createdAt: _toDateTime(map['created_at']),
      updatedAt: _toDateTime(map['updated_at']),
    );
  }
}