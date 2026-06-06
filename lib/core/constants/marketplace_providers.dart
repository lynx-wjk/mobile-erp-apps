class MarketplaceProvider {
  final String id;
  final String label;
  final String shortLabel;
  final bool supportsAuthReconnect;
  final bool supportsProductPull;
  final bool supportsOrderPull;
  final bool supportsStockSync;
  final bool supportsFinancePull;
  final bool supportsRefundCancelMonitor;

  const MarketplaceProvider({
    required this.id,
    required this.label,
    required this.shortLabel,
    required this.supportsAuthReconnect,
    required this.supportsProductPull,
    required this.supportsOrderPull,
    required this.supportsStockSync,
    required this.supportsFinancePull,
    required this.supportsRefundCancelMonitor,
  });
}

class MarketplaceProviders {
  static const tiktokShop = MarketplaceProvider(
    id: 'tiktok_shop',
    label: 'TikTok Shop',
    shortLabel: 'TikTok',
    supportsAuthReconnect: true,
    supportsProductPull: true,
    supportsOrderPull: true,
    supportsStockSync: true,
    supportsFinancePull: true,
    supportsRefundCancelMonitor: true,
  );

  static const shopee = MarketplaceProvider(
    id: 'shopee',
    label: 'Shopee',
    shortLabel: 'Shopee',
    supportsAuthReconnect: true,
    supportsProductPull: true,
    supportsOrderPull: true,
    supportsStockSync: true,
    supportsFinancePull: false,
    supportsRefundCancelMonitor: true,
  );

  static const List<MarketplaceProvider> active = [
    tiktokShop,
    shopee,
  ];

  static MarketplaceProvider byId(String? marketplace) {
    final id = normalize(marketplace);
    return active.firstWhere(
      (provider) => provider.id == id,
      orElse: () => tiktokShop,
    );
  }

  static String normalize(String? marketplace) {
    final raw = marketplace?.trim().toLowerCase().replaceAll('-', '_') ?? '';
    if (raw == 'tiktok' || raw == 'tiktokshop' || raw == 'tiktok_shop') {
      return tiktokShop.id;
    }
    if (raw == 'shopee' || raw == 'shopee_shop') {
      return shopee.id;
    }
    return raw.isEmpty ? tiktokShop.id : raw;
  }

  static bool isSupported(String? marketplace) {
    final id = normalize(marketplace);
    return active.any((provider) => provider.id == id);
  }

  static String labelFor(String? marketplace) => byId(marketplace).label;
}
