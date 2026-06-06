class AbsensiLog {
  final String attendanceId;
  final String userId;
  final String? namaUser;
  final String? emailUser;
  final String? roleId;
  final String attendanceType;
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final String? catatan;
  final DateTime createdAt;

  const AbsensiLog({
    required this.attendanceId,
    required this.userId,
    required this.namaUser,
    required this.emailUser,
    required this.roleId,
    required this.attendanceType,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.catatan,
    required this.createdAt,
  });

  static double? _toNullableDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static DateTime _parseDateTime(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');

    if (parsed == null) {
      return DateTime.now();
    }

    return parsed.toLocal();
  }

  factory AbsensiLog.fromMap(Map<String, dynamic> map) {
    return AbsensiLog(
      attendanceId: map['attendance_id'] as String,
      userId: map['user_id'] as String,
      namaUser: map['nama_user'] as String?,
      emailUser: map['email_user'] as String?,
      roleId: map['role_id'] as String?,
      attendanceType: map['attendance_type'] as String? ?? '-',
      latitude: _toNullableDouble(map['latitude']),
      longitude: _toNullableDouble(map['longitude']),
      accuracy: _toNullableDouble(map['accuracy']),
      catatan: map['catatan'] as String?,
      createdAt: _parseDateTime(map['created_at']),
    );
  }

  String get typeLabel {
    switch (attendanceType) {
      case 'CHECK_IN':
        return 'Check In';
      case 'CHECK_OUT':
        return 'Check Out';
      default:
        return attendanceType;
    }
  }

  String get locationText {
    if (latitude == null || longitude == null) {
      return '-';
    }

    return '$latitude, $longitude';
  }
}