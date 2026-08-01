import 'package:supabase_flutter/supabase_flutter.dart';

class TenantEntitlementSnapshot {
  final bool ok;
  final String reason;
  final String roleId;
  final String tenantId;
  final bool isPlatformOwner;
  final String planCode;
  final String planName;
  final String subscriptionStatus;
  final Map<String, bool> featureEnabled;
  final Map<String, int?> featureLimits;
  final Map<String, int> quotas;

  const TenantEntitlementSnapshot({
    required this.ok,
    required this.reason,
    required this.roleId,
    required this.tenantId,
    required this.isPlatformOwner,
    required this.planCode,
    required this.planName,
    required this.subscriptionStatus,
    required this.featureEnabled,
    required this.featureLimits,
    required this.quotas,
  });

  factory TenantEntitlementSnapshot.empty({String reason = 'empty'}) {
    return TenantEntitlementSnapshot(
      ok: false,
      reason: reason,
      roleId: '',
      tenantId: '',
      isPlatformOwner: false,
      planCode: 'unassigned',
      planName: 'Unassigned',
      subscriptionStatus: 'unassigned',
      featureEnabled: const <String, bool>{},
      featureLimits: const <String, int?>{},
      quotas: const <String, int>{},
    );
  }

  factory TenantEntitlementSnapshot.fromMap(Map<String, dynamic> map) {
    final subscription = map['subscription'] is Map
        ? Map<String, dynamic>.from(map['subscription'] as Map)
        : <String, dynamic>{};

    final rawFeatures = map['feature_enabled'] is Map
        ? Map<String, dynamic>.from(map['feature_enabled'] as Map)
        : <String, dynamic>{};

    final features = <String, bool>{};
    for (final entry in rawFeatures.entries) {
      features[entry.key] =
          entry.value == true || entry.value?.toString() == 'true';
    }

    final rawLimits = map['feature_limits'] is Map
        ? Map<String, dynamic>.from(map['feature_limits'] as Map)
        : <String, dynamic>{};

    final limits = <String, int?>{};
    for (final entry in rawLimits.entries) {
      limits[entry.key] = int.tryParse(entry.value?.toString() ?? '');
    }

    final rawQuotas = map['quotas'] is Map
        ? Map<String, dynamic>.from(map['quotas'] as Map)
        : <String, dynamic>{};

    final quotas = <String, int>{};
    for (final entry in rawQuotas.entries) {
      quotas[entry.key] = int.tryParse(entry.value?.toString() ?? '') ?? 0;
    }

    final role = map['role_id']?.toString().trim().toLowerCase() ?? '';

    return TenantEntitlementSnapshot(
      ok: map['ok'] == true,
      reason: map['reason']?.toString() ?? '',
      roleId: role,
      tenantId: map['tenant_id']?.toString() ?? '',
      isPlatformOwner:
          map['is_platform_owner'] == true || role == 'platform_owner',
      planCode: subscription['plan_code']?.toString() ?? 'unassigned',
      planName: subscription['plan_name']?.toString() ?? 'Unassigned',
      subscriptionStatus: subscription['status']?.toString() ?? 'unassigned',
      featureEnabled: features,
      featureLimits: limits,
      quotas: quotas,
    );
  }

  bool isFeatureEnabled(String featureKey) {
    if (isPlatformOwner) return true;
    return featureEnabled[featureKey] == true;
  }
}

class TenantEntitlementService {
  final SupabaseClient client;

  const TenantEntitlementService(this.client);

  Future<TenantEntitlementSnapshot> load() async {
    try {
      final response = await client.rpc('tenant_entitlement_snapshot_for_app');
      if (response is Map<String, dynamic>) {
        return TenantEntitlementSnapshot.fromMap(response);
      }
      if (response is Map) {
        return TenantEntitlementSnapshot.fromMap(
          Map<String, dynamic>.from(response),
        );
      }
      return TenantEntitlementSnapshot.empty(reason: 'invalid_rpc_response');
    } catch (error) {
      return TenantEntitlementSnapshot.empty(reason: error.toString());
    }
  }
}
