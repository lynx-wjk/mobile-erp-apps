class MarketplaceSkuMapInput {
  final String tenantId;
  final String marketplaceAccountId;
  final String marketplace;
  final String productId;
  final String localSku;
  final String marketplaceProductId;
  final String marketplaceSkuId;
  final String marketplaceSku;
  final String marketplaceSellerSku;
  final String marketplaceProductName;
  final String marketplaceVariationName;
  final bool syncEnabled;

  const MarketplaceSkuMapInput({
    required this.tenantId,
    required this.marketplaceAccountId,
    required this.marketplace,
    required this.productId,
    required this.localSku,
    required this.marketplaceProductId,
    required this.marketplaceSkuId,
    required this.marketplaceSku,
    required this.marketplaceSellerSku,
    required this.marketplaceProductName,
    required this.marketplaceVariationName,
    required this.syncEnabled,
  });

  Map<String, dynamic> toInsertMap() {
    String? nullIfEmpty(String value) {
      final clean = value.trim();
      return clean.isEmpty ? null : clean;
    }

    return {
      'tenant_id': tenantId,
      'marketplace_account_id': marketplaceAccountId,
      'marketplace': marketplace,
      'product_id': productId,
      'local_sku': localSku.trim(),
      'marketplace_product_id': nullIfEmpty(marketplaceProductId),
      'marketplace_sku_id': nullIfEmpty(marketplaceSkuId),
      'marketplace_sku': nullIfEmpty(marketplaceSku),
      'marketplace_seller_sku': marketplaceSellerSku.trim().isNotEmpty
          ? marketplaceSellerSku.trim()
          : (marketplaceSkuId.trim().isNotEmpty
              ? marketplaceSkuId.trim()
              : localSku.trim()),
      'marketplace_product_name': nullIfEmpty(marketplaceProductName),
      'marketplace_variation_name': nullIfEmpty(marketplaceVariationName),
      'sync_enabled': syncEnabled,
      'status': 'active',
    };
  }
}
