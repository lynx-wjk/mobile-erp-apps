import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseRealtimeService {
  static final SupabaseRealtimeService _instance = SupabaseRealtimeService._internal();
  factory SupabaseRealtimeService() => _instance;
  SupabaseRealtimeService._internal();

  final SupabaseClient _supabase = Supabase.instance.client;

  RealtimeChannel? _ordersChannel;
  RealtimeChannel? _alertsChannel;

  /// Subscribe to live order & payout change notifications via Supabase WebSockets
  void subscribeToRealtimeUpdates({
    required String tenantId,
    required Function(Map<String, dynamic> payload) onOrderChanged,
    required Function(String title, String message, String alertType) onAlertBroadcast,
  }) {
    // Unsubscribe existing channels if active
    unsubscribeAll();

    debugPrint('⚡ [Realtime WebSocket] Subscribing to tenant channels: $tenantId');

    // 1. Subscribe to Postgres Change Data Capture (CDC) for marketplace_orders
    _ordersChannel = _supabase.channel('public:marketplace_orders:tenant=$tenantId');
    _ordersChannel!
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'marketplace_orders',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'tenant_id',
          value: tenantId,
        ),
        callback: (payload) {
          debugPrint('⚡ [Realtime WebSocket] Order Change Received: ${payload.eventType}');
          if (payload.newRecord.isNotEmpty) {
            onOrderChanged(payload.newRecord);
          }
        },
      )
      .subscribe();

    // 2. Subscribe to Realtime Alert Broadcasts (Low Stock & Escrow Payouts)
    _alertsChannel = _supabase.channel('public:alerts:tenant=$tenantId');
    _alertsChannel!
      .onBroadcast(
        event: 'alert_notification',
        callback: (payload) {
          final title = payload['title']?.toString() ?? 'Alert Sistem';
          final body = payload['body']?.toString() ?? payload['message']?.toString() ?? '';
          final alertType = payload['alert_type']?.toString() ?? 'general';

          debugPrint('🔔 [Realtime Broadcast Alert] $title: $body');
          onAlertBroadcast(title, body, alertType);
        },
      )
      .subscribe();
  }

  void unsubscribeAll() {
    if (_ordersChannel != null) {
      _supabase.removeChannel(_ordersChannel!);
      _ordersChannel = null;
    }
    if (_alertsChannel != null) {
      _supabase.removeChannel(_alertsChannel!);
      _alertsChannel = null;
    }
  }
}
