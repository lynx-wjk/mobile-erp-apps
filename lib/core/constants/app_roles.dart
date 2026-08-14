enum AppRole {
  unassigned,
  platformOwner,
  superAdmin,
  demoSuperAdmin,
  admin,
  warehouse,
  produksi,
  finance,
  hostLive,
  hr,
  contentCreator,
}

extension AppRoleExtension on AppRole {
  String get label {
    switch (this) {
      case AppRole.unassigned:
        return 'Belum aktif';
      case AppRole.platformOwner:
        return 'Platform Owner';
      case AppRole.superAdmin:
        return 'Super Admin';
      case AppRole.demoSuperAdmin:
        return 'Demo';
      case AppRole.admin:
        return 'Admin';
      case AppRole.warehouse:
        return 'Warehouse';
      case AppRole.produksi:
        return 'Produksi';
      case AppRole.finance:
        return 'Finance';
      case AppRole.hostLive:
        return 'Host Live';
      case AppRole.hr:
        return 'HR';
      case AppRole.contentCreator:
        return 'Content Creator';
    }
  }

  String get roleId {
    switch (this) {
      case AppRole.unassigned:
        return 'unassigned';
      case AppRole.platformOwner:
        return 'platform_owner';
      case AppRole.superAdmin:
        return 'super_admin';
      case AppRole.demoSuperAdmin:
        return 'demo_super_admin';
      case AppRole.admin:
        return 'admin';
      case AppRole.warehouse:
        return 'warehouse';
      case AppRole.produksi:
        return 'produksi';
      case AppRole.finance:
        return 'finance';
      case AppRole.hostLive:
        return 'host_live';
      case AppRole.hr:
        return 'hr';
      case AppRole.contentCreator:
        return 'content_creator';
    }
  }

  bool get isSuperRole {
    return this == AppRole.superAdmin || this == AppRole.demoSuperAdmin || this == AppRole.platformOwner;
  }

  bool get isDemoSuperAdmin => this == AppRole.demoSuperAdmin;

  bool get isAdmin => this == AppRole.admin;
}

AppRole appRoleFromRoleId(String? roleId) {
  final value = roleId?.trim().toLowerCase();

  switch (value) {
    case 'unassigned':
    case 'belum di-assign':
    case 'belum_di_assign':
    case 'pending':
    case null:
    case '':
      return AppRole.unassigned;
    case 'platform_owner':
    case 'platformowner':
      return AppRole.platformOwner;
    case 'super_admin':
    case 'superadmin':
    case 'owner':
    case 'platform_super_admin':
      return AppRole.superAdmin;
    case 'admin':
      return AppRole.admin;
    case 'demo_super_admin':
    case 'demo':
    case 'demo-super-admin':
    case 'demo super admin':
      return AppRole.demoSuperAdmin;
    case 'warehouse':
      return AppRole.warehouse;
    case 'produksi':
    case 'production':
      return AppRole.produksi;
    case 'finance':
    case 'finanace':
      return AppRole.finance;
    case 'host_live':
      return AppRole.hostLive;
    case 'hr':
      return AppRole.hr;
    case 'content_creator':
      return AppRole.contentCreator;
    default:
      throw Exception('Role tidak dikenal: $roleId');
  }
}

class AppRolePermissions {
  static String normalizeRoleId(String? roleId) {
    return roleId?.trim().toLowerCase().replaceAll(' ', '_') ?? '';
  }

  static bool isPlatformOwnerId(String? roleId) {
    return normalizeRoleId(roleId) == 'platform_owner';
  }

  static bool isSuperRoleId(String? roleId) {
    final role = normalizeRoleId(roleId);
    return role == 'super_admin' ||
        role == 'superadmin' ||
        role == 'owner' ||
        role == 'platform_owner' ||
        role == 'platform_super_admin';
  }

  static bool isDemoSuperAdminId(String? roleId) {
    final role = normalizeRoleId(roleId);
    return role == 'demo_super_admin' ||
        role == 'demo-super-admin' ||
        role == 'demo';
  }

  static bool isAdminRoleId(String? roleId) {
    return normalizeRoleId(roleId) == 'admin';
  }

  static bool canAccessFinance(String? roleId) {
    final role = normalizeRoleId(roleId);
    return isSuperRoleId(role) || isDemoSuperAdminId(role) || role == 'finance';
  }

  static bool canAccessPayroll(String? roleId) {
    final role = normalizeRoleId(roleId);
    return isSuperRoleId(role) ||
        isDemoSuperAdminId(role) ||
        role == 'finance' ||
        role == 'hr';
  }

  static bool canManageMarketplaceAuth(String? roleId) {
    return isSuperRoleId(roleId) || isAdminRoleId(roleId);
  }

  static bool canConnectNewMarketplace(String? roleId) {
    return isSuperRoleId(roleId);
  }

  static bool canDeleteBusinessData(String? roleId) {
    return isSuperRoleId(roleId);
  }

  static bool canExportImport(String? roleId) {
    return isSuperRoleId(roleId);
  }

  static bool canOpenSuperSettings(String? roleId) {
    return isSuperRoleId(roleId);
  }

  static bool canManageOperationalUsers(String? roleId) {
    return isSuperRoleId(roleId) || isAdminRoleId(roleId);
  }

  static bool canManageOperationalWork(String? roleId) {
    final role = normalizeRoleId(roleId);
    return isSuperRoleId(role) || isAdminRoleId(role) || role == 'hr';
  }

  static bool isSensitiveUserRole(String? roleId) {
    final role = normalizeRoleId(roleId);
    return isSuperRoleId(role) ||
        isDemoSuperAdminId(role) ||
        isAdminRoleId(role) ||
        role == 'finance';
  }

  static const Set<String> operationalAssignableRoles = {
    'unassigned',
    'warehouse',
    'produksi',
    'production',
    'hr',
    'host_live',
    'content_creator',
  };
}
