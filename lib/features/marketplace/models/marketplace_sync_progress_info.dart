class MarketplaceAccountSyncProgress {
  final String syncStateId;
  final String marketplace;
  final String marketplaceAccountId;
  final String bootstrapStatus;
  final double progressPercent; // 0.0 to 100.0
  final bool isActive;
  final String? lastError;
  final DateTime? lastSuccessAt;

  const MarketplaceAccountSyncProgress({
    required this.syncStateId,
    required this.marketplace,
    required this.marketplaceAccountId,
    required this.bootstrapStatus,
    required this.progressPercent,
    required this.isActive,
    this.lastError,
    this.lastSuccessAt,
  });

  String get displayName {
    if (marketplace == 'shopee') return 'Shopee';
    if (marketplace == 'tiktok_shop') return 'TikTok Shop';
    return marketplace.toUpperCase();
  }
}

class MarketplaceSyncProgressSummary {
  final List<MarketplaceAccountSyncProgress> accounts;
  final double overallProgressPercent; // 0.0 to 100.0
  final bool hasActiveSync;

  const MarketplaceSyncProgressSummary({
    required this.accounts,
    required this.overallProgressPercent,
    required this.hasActiveSync,
  });

  static MarketplaceSyncProgressSummary fromRawStates(
    List<Map<String, dynamic>> rows, {
    String? filterMarketplace,
    String? filterAccountId,
  }) {
    if (rows.isEmpty) {
      return const MarketplaceSyncProgressSummary(
        accounts: [],
        overallProgressPercent: 0,
        hasActiveSync: false,
      );
    }

    final now = DateTime.now();
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    final list = <MarketplaceAccountSyncProgress>[];
    double totalProgressSum = 0;
    int activeCount = 0;

    for (final raw in rows) {
      final s = Map<String, dynamic>.from(raw);
      final marketplace = (s['marketplace'] ?? '').toString().toLowerCase().trim();
      final accountId = (s['marketplace_account_id'] ?? '').toString().trim();

      if (filterMarketplace != null &&
          filterMarketplace != 'all' &&
          marketplace != filterMarketplace.toLowerCase().trim()) {
        continue;
      }
      if (filterAccountId != null &&
          filterAccountId != 'all' &&
          accountId != filterAccountId.trim()) {
        continue;
      }

      final status = (s['bootstrap_status'] ?? '').toString().toLowerCase().trim();
      final lockedUntilStr = s['locked_until']?.toString();
      final lockedUntil = lockedUntilStr != null ? DateTime.tryParse(lockedUntilStr) : null;
      final isLocked = lockedUntil != null && lockedUntil.isAfter(now);

      final isDone = status == 'done' ||
          status == 'complete' ||
          status == 'completed' ||
          status == 'idle' ||
          status == 'ready';

      final isRunning = status == 'running' ||
          status == 'in_progress' ||
          status == 'syncing' ||
          status == 'bootstrap';

      final isActive = !isDone && (isRunning || (status.isNotEmpty && isLocked));

      final from = (s['bootstrap_from_seconds'] as num?)?.toDouble() ?? 0;
      final to = (s['bootstrap_to_seconds'] as num?)?.toDouble() ?? nowSec.toDouble();
      final cursor = (s['bootstrap_cursor_seconds'] as num?)?.toDouble() ?? from;

      double pct = 0;
      if (isDone) {
        pct = 100.0;
      } else if (to > from && cursor >= from) {
        pct = (((cursor - from) / (to - from)) * 100.0).clamp(0.0, 100.0);
      }

      if (isActive) {
        totalProgressSum += pct;
        activeCount++;
      }

      final lastSuccessStr = s['last_success_at']?.toString();
      final lastSuccess = lastSuccessStr != null ? DateTime.tryParse(lastSuccessStr) : null;

      list.add(MarketplaceAccountSyncProgress(
        syncStateId: (s['sync_state_id'] ?? '').toString(),
        marketplace: marketplace,
        marketplaceAccountId: accountId,
        bootstrapStatus: status,
        progressPercent: pct,
        isActive: isActive,
        lastError: s['last_error']?.toString(),
        lastSuccessAt: lastSuccess,
      ));
    }

    final double overall = activeCount > 0 ? (totalProgressSum / activeCount).clamp(0.0, 100.0) : 0;
    final bool hasActive = list.any((a) => a.isActive);

    return MarketplaceSyncProgressSummary(
      accounts: list,
      overallProgressPercent: overall,
      hasActiveSync: hasActive,
    );
  }
}
