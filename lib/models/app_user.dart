import '../core/constants/app_roles.dart';

class AppUser {
  final String userId;
  final String nama;
  final String email;
  final AppRole role;
  final String status;
  final String tenantId;
  final String? nomorHp;

  const AppUser({
    required this.userId,
    required this.nama,
    required this.email,
    required this.role,
    required this.status,
    required this.tenantId,
    this.nomorHp,
  });

  factory AppUser.fromMap(Map<String, dynamic> map) {
    final role = appRoleFromRoleId(map['role_id'] as String?);

    return AppUser(
      userId: map['user_id'] as String? ?? '',
      nama: map['nama'] as String? ?? '-',
      email: map['email'] as String? ?? '-',
      role: role,
      status: map['status'] as String? ?? 'inactive',
      tenantId: map['tenant_id']?.toString() ?? '',
      nomorHp: map['nomor_hp'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'user_id': userId,
      'nama': nama,
      'email': email,
      'role_id': role.roleId,
      'status': status,
      'tenant_id': tenantId,
      'nomor_hp': nomorHp,
    };
  }

  bool get isActive => status == 'active';

  bool get hasTenant => tenantId.trim().isNotEmpty;
}
