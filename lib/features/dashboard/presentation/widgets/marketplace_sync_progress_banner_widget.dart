import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/constants/app_roles.dart';
import '../../../../core/ui/app_ui.dart';
import '../../../../models/app_user.dart';
import '../../../marketplace/models/marketplace_sync_progress_info.dart';

class MarketplaceSyncProgressBannerWidget extends StatefulWidget {
  final AppUser? currentUser;
  final VoidCallback? onSyncComplete;

  const MarketplaceSyncProgressBannerWidget({
    super.key,
    this.currentUser,
    this.onSyncComplete,
  });

  @override
  State<MarketplaceSyncProgressBannerWidget> createState() =>
      _MarketplaceSyncProgressBannerWidgetState();
}

class _MarketplaceSyncProgressBannerWidgetState
    extends State<MarketplaceSyncProgressBannerWidget> {
  final SupabaseClient _client = Supabase.instance.client;
  Timer? _pollTimer;
  bool _isLoading = true;
  List<Map<String, dynamic>> _syncStates = [];
  bool _wasActive = false;
  bool _dismissed = false;

  bool _isFetching = false;

  @override
  void initState() {
    super.initState();
    _loadSyncStates();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        _loadSyncStates(silent: true);
      }
    });
  }

  String get _tenantId {
    final tId = widget.currentUser?.tenantId.trim() ?? '';
    if (tId.isNotEmpty) return tId;
    return _client.auth.currentUser?.userMetadata?['tenant_id']?.toString() ??
        '';
  }

  Future<void> _loadSyncStates({bool silent = false}) async {
    if (_isFetching) return;
    final tenantId = _tenantId;
    if (tenantId.isEmpty) {
      if (!silent && mounted) setState(() => _isLoading = false);
      return;
    }

    _isFetching = true;
    try {
      List<Map<String, dynamic>> rows = [];
      try {
        final rpcRes = await _client.rpc(
          'get_marketplace_sync_states_for_app',
          params: tenantId.isNotEmpty ? {'p_tenant_id': tenantId} : {},
        );
        if (rpcRes is List) {
          rows = rpcRes.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {}

      if (rows.isEmpty) {
        final res = await _client
            .from('marketplace_order_sync_state')
            .select(
                'sync_state_id, marketplace, marketplace_account_id, bootstrap_status, bootstrap_from_seconds, bootstrap_to_seconds, bootstrap_cursor_seconds, recent_cursor_seconds, next_run_at, locked_until, failure_count, last_error, last_success_at, updated_at')
            .eq('tenant_id', tenantId);
        if (res is List) {
          rows = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      }

      if (!mounted) return;

      final isActiveNow = _hasActiveSync(rows);

      if (_wasActive && !isActiveNow) {
        widget.onSyncComplete?.call();
      }
      _wasActive = isActiveNow;

      setState(() {
        _syncStates = rows;
        _isLoading = false;
      });
    } catch (e) {
      if (!silent && mounted) setState(() => _isLoading = false);
    } finally {
      _isFetching = false;
    }
  }

  bool _hasActiveSync(List<Map<String, dynamic>> states) {
    if (states.isEmpty) return false;
    final now = DateTime.now();
    return states.any((s) {
      final status =
          (s['bootstrap_status'] ?? '').toString().toLowerCase().trim();
      final isDone = status == 'done' ||
          status == 'complete' ||
          status == 'completed' ||
          status == 'idle' ||
          status == 'ready';
      if (isDone) return false;

      final lockedUntilStr = s['locked_until']?.toString();
      final lockedUntil =
          lockedUntilStr != null ? DateTime.tryParse(lockedUntilStr) : null;
      final isLocked = lockedUntil != null && lockedUntil.isAfter(now);

      final isRunning = status == 'running' ||
          status == 'in_progress' ||
          status == 'syncing' ||
          status == 'bootstrap';

      return isRunning || (status.isNotEmpty && isLocked);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _dismissed) return const SizedBox.shrink();
    
    final summary = MarketplaceSyncProgressSummary.fromRawStates(_syncStates);
    if (!summary.hasActiveSync || summary.overallProgressPercent >= 100.0) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final overallPct = summary.overallProgressPercent;
    final progressValue = (overallPct / 100.0).clamp(0.02, 1.0);
    final pctText = '${overallPct.toInt()}%';

    final channelBadges = summary.accounts.map((a) {
      final statusLabel = a.isActive ? '${a.progressPercent.toInt()}%' : 'Selesai';
      return '${a.displayName}: $statusLabel';
    }).join(' · ');

    final activeMarketplaces = summary.accounts
        .where((a) => a.isActive)
        .map((a) => a.displayName)
        .toSet()
        .join(' & ');

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
            theme.colorScheme.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'SINKRONISASI RIWAYAT PESANAN ($activeMarketplaces)',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: theme.colorScheme.primary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              pctText,
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () => setState(() => _dismissed = true),
                            borderRadius: BorderRadius.circular(999),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        channelBadges.isNotEmpty
                            ? 'Progress per kanal: $channelBadges'
                            : 'Menarik data riwayat pesanan 90 hari ke belakang di background.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progressValue,
                minHeight: 8,
                backgroundColor:
                    theme.colorScheme.primary.withValues(alpha: 0.12),
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Data riwayat otomatis bertambah di database...',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                Text(
                  'Auto Disappear saat 100%',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
