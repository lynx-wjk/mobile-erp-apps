class MarketplaceAccountPublic {
  final String marketplaceAccountId;
  final String tenantId;
  final String marketplace;
  final String storeAlias;
  final String shopName;
  final String shopRegion;
  final String status;
  final String environment;
  final bool stockSyncEnabled;
  final String? lastError;
  final String? shopIdMasked;
  final String? shopCipherMasked;
  final DateTime? accessTokenExpiredAt;
  final DateTime? refreshTokenExpiredAt;
  final DateTime? connectedAt;
  final DateTime? reauthorizedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const MarketplaceAccountPublic({
    required this.marketplaceAccountId,
    required this.tenantId,
    required this.marketplace,
    required this.storeAlias,
    required this.shopName,
    required this.shopRegion,
    required this.status,
    required this.environment,
    required this.stockSyncEnabled,
    required this.lastError,
    required this.shopIdMasked,
    required this.shopCipherMasked,
    required this.accessTokenExpiredAt,
    required this.refreshTokenExpiredAt,
    required this.connectedAt,
    required this.reauthorizedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MarketplaceAccountPublic.fromMap(Map<String, dynamic> map) {
    return MarketplaceAccountPublic(
      marketplaceAccountId: map['marketplace_account_id']?.toString() ?? '',
      tenantId: map['tenant_id']?.toString() ?? '',
      marketplace: map['marketplace']?.toString() ?? '-',
      storeAlias: map['store_alias']?.toString() ?? '-',
      shopName: map['shop_name']?.toString() ?? '-',
      shopRegion: map['shop_region']?.toString() ?? 'ID',
      status: map['status']?.toString() ?? 'inactive',
      environment: _environment(map['environment']),
      stockSyncEnabled: _bool(map['stock_sync_enabled']),
      lastError: _nullableText(map['last_error']),
      shopIdMasked: _nullableText(map['shop_id_masked'] ?? map['shop_id']),
      shopCipherMasked: _nullableText(map['shop_cipher_masked'] ?? map['shop_cipher']),
      accessTokenExpiredAt: _date(map['access_token_expired_at']),
      refreshTokenExpiredAt: _date(map['refresh_token_expired_at']),
      connectedAt: _date(map['connected_at']),
      reauthorizedAt: _date(map['reauthorized_at']),
      createdAt: _date(map['created_at']),
      updatedAt: _date(map['updated_at']),
    );
  }

  String get marketplaceLabel {
    switch (marketplace) {
      case 'tiktok_shop':
        return 'TikTok Shop';
      case 'shopee':
        return 'Shopee';
      default:
        return marketplace;
    }
  }

  String get safeStoreName {
    if (storeAlias.trim().isNotEmpty && storeAlias != '-') return storeAlias;
    if (shopName.trim().isNotEmpty && shopName != '-') return shopName;
    return marketplaceLabel;
  }

  bool get isTesting => environment.toLowerCase() == 'testing';

  String get environmentLabel => isTesting ? 'Testing / Dev Shop' : 'Production';

  bool get isError => status.toLowerCase() == 'error' || (lastError != null && lastError!.trim().isNotEmpty);

  bool get isExpired => status.toLowerCase() == 'expired';

  int? get daysUntilReauthRequired {
    final now = DateTime.now();
    if (marketplace.toLowerCase().contains('shopee')) {
      final baseDate = reauthorizedAt ?? connectedAt;
      if (baseDate != null) {
        final daysPassed = now.difference(baseDate).inDays;
        return 30 - daysPassed;
      }
    }
    if (refreshTokenExpiredAt != null) {
      return refreshTokenExpiredAt!.difference(now).inDays;
    }
    return null;
  }

  bool get needsReauth {
    if (status.toLowerCase() == 'inactive') return false;
    if (isError || isExpired) return true;
    final daysLeft = daysUntilReauthRequired;
    if (daysLeft != null && daysLeft <= 5) return true;
    return false;
  }

  String get reauthWarningMessage {
    if (isError) {
      return 'Koneksi toko bermasalah atau otorisasi gagal. Hubungkan ulang toko agar sinkronisasi berjalan lancar.';
    }
    if (isExpired) {
      return 'Sesi otorisasi toko telah kedaluwarsa. Hubungkan ulang diperlukan.';
    }
    final daysLeft = daysUntilReauthRequired;
    if (daysLeft != null) {
      if (daysLeft <= 0) {
        return 'Masa aktif otorisasi 30 hari Shopee telah habis. Hubungkan ulang toko agar sinkronisasi tidak terhenti.';
      }
      return 'Masa aktif otorisasi Shopee tersisa $daysLeft hari. Hubungkan ulang segera sebelum kedaluwarsa.';
    }
    return 'Toko memerlukan otorisasi ulang.';
  }

  static String _environment(dynamic value) {
    final raw = value?.toString().trim().toLowerCase() ?? '';
    if (raw == 'test' || raw == 'dev' || raw == 'development' || raw == 'sandbox') {
      return 'testing';
    }
    if (raw == 'testing') return 'testing';
    return 'production';
  }

  static String? _nullableText(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return null;
    return text;
  }

  static bool _bool(dynamic value) {
    if (value == true) return true;
    if (value is num) return value != 0;
    final text = value?.toString().toLowerCase().trim() ?? '';
    return text == 'true' || text == '1' || text == 'yes' || text == 'on';
  }

  static DateTime? _date(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }
}
