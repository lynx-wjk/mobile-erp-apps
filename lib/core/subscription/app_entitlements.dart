enum SubscriptionPlanTier {
  basic,
  pro,
  business,
  enterprise,
}

enum AppFeatureEntitlement {
  coreStock,
  marketplaceAccounts,
  marketplaceOrderPull,
  marketplaceStockSync,
  marketplaceRefundCancel,
  skuMapping,
  financeReport,
  autoFinance,
  autoOrderPull,
  jobMonitor,
  analytics,
  exportImport,
  auditCenter,
  superSettings,
  manualOperationalExpense,
  purchaseVerification,
  aiChatAssistant,
  automatedPayoutSync,
  tenantIsolation,
  sampleFreeAudit,
}

class SubscriptionPlanDefinition {
  final SubscriptionPlanTier tier;
  final String id;
  final String label;
  final int maxUsers;
  final int maxMarketplaceAccounts;
  final int maxSkus;
  final int monthlyOrderSyncLimit;
  final Set<AppFeatureEntitlement> features;

  const SubscriptionPlanDefinition({
    required this.tier,
    required this.id,
    required this.label,
    required this.maxUsers,
    required this.maxMarketplaceAccounts,
    required this.maxSkus,
    required this.monthlyOrderSyncLimit,
    required this.features,
  });

  bool allows(AppFeatureEntitlement feature) => features.contains(feature);
}

class AppSubscriptionPlans {
  static const basic = SubscriptionPlanDefinition(
    tier: SubscriptionPlanTier.basic,
    id: 'basic',
    label: 'Basic',
    maxUsers: 5,
    maxMarketplaceAccounts: 0,
    maxSkus: 500,
    monthlyOrderSyncLimit: 0,
    features: {
      AppFeatureEntitlement.coreStock,
    },
  );

  static const pro = SubscriptionPlanDefinition(
    tier: SubscriptionPlanTier.pro,
    id: 'pro',
    label: 'Pro',
    maxUsers: 15,
    maxMarketplaceAccounts: 2,
    maxSkus: 3000,
    monthlyOrderSyncLimit: 5000,
    features: {
      AppFeatureEntitlement.coreStock,
      AppFeatureEntitlement.marketplaceAccounts,
      AppFeatureEntitlement.marketplaceOrderPull,
      AppFeatureEntitlement.marketplaceStockSync,
      AppFeatureEntitlement.marketplaceRefundCancel,
      AppFeatureEntitlement.skuMapping,
      AppFeatureEntitlement.analytics,
    },
  );

  static const business = SubscriptionPlanDefinition(
    tier: SubscriptionPlanTier.business,
    id: 'business',
    label: 'Business',
    maxUsers: 50,
    maxMarketplaceAccounts: 8,
    maxSkus: 15000,
    monthlyOrderSyncLimit: 50000,
    features: {
      AppFeatureEntitlement.coreStock,
      AppFeatureEntitlement.marketplaceAccounts,
      AppFeatureEntitlement.marketplaceOrderPull,
      AppFeatureEntitlement.marketplaceStockSync,
      AppFeatureEntitlement.marketplaceRefundCancel,
      AppFeatureEntitlement.skuMapping,
      AppFeatureEntitlement.financeReport,
      AppFeatureEntitlement.autoFinance,
      AppFeatureEntitlement.autoOrderPull,
      AppFeatureEntitlement.jobMonitor,
      AppFeatureEntitlement.analytics,
    },
  );

  static const enterprise = SubscriptionPlanDefinition(
    tier: SubscriptionPlanTier.enterprise,
    id: 'enterprise',
    label: 'Enterprise',
    maxUsers: 250,
    maxMarketplaceAccounts: 50,
    maxSkus: 100000,
    monthlyOrderSyncLimit: 500000,
    features: {
      AppFeatureEntitlement.coreStock,
      AppFeatureEntitlement.marketplaceAccounts,
      AppFeatureEntitlement.marketplaceOrderPull,
      AppFeatureEntitlement.marketplaceStockSync,
      AppFeatureEntitlement.marketplaceRefundCancel,
      AppFeatureEntitlement.skuMapping,
      AppFeatureEntitlement.financeReport,
      AppFeatureEntitlement.autoFinance,
      AppFeatureEntitlement.autoOrderPull,
      AppFeatureEntitlement.jobMonitor,
      AppFeatureEntitlement.analytics,
      AppFeatureEntitlement.exportImport,
      AppFeatureEntitlement.auditCenter,
      AppFeatureEntitlement.superSettings,
    },
  );

  static const all = [
    basic,
    pro,
    business,
    enterprise,
  ];

  static SubscriptionPlanDefinition byId(String? planId) {
    final id = planId?.trim().toLowerCase() ?? '';
    return all.firstWhere(
      (plan) => plan.id == id,
      orElse: () => business,
    );
  }
}
