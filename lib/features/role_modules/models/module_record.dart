class ModuleRecord {
  final String recordId;
  final String moduleKey;
  final String title;
  final String? description;
  final double amount;
  final String? assignedRole;
  final String status;
  final String? proofUrl;
  final String? createdBy;
  final String? createdByName;
  final String? createdByEmail;
  final String? createdByRole;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ModuleRecord({
    required this.recordId,
    required this.moduleKey,
    required this.title,
    required this.description,
    required this.amount,
    required this.assignedRole,
    required this.status,
    required this.proofUrl,
    required this.createdBy,
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

  factory ModuleRecord.fromMap(Map<String, dynamic> map) {
    return ModuleRecord(
      recordId: map['record_id']?.toString() ?? '',
      moduleKey: map['module_key']?.toString() ?? '',
      title: map['title']?.toString() ?? '-',
      description: map['description']?.toString(),
      amount: _toDouble(map['amount']),
      assignedRole: map['assigned_role']?.toString(),
      status: map['status']?.toString() ?? 'open',
      proofUrl: map['proof_url']?.toString(),
      createdBy: map['created_by']?.toString(),
      createdByName: map['created_by_name']?.toString(),
      createdByEmail: map['created_by_email']?.toString(),
      createdByRole: map['created_by_role']?.toString(),
      createdAt: _toDateTime(map['created_at']),
      updatedAt: _toDateTime(map['updated_at']),
    );
  }
}