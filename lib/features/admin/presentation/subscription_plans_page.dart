import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/ui/app_ui.dart';

class SubscriptionPlansPage extends StatefulWidget {
  const SubscriptionPlansPage({super.key});

  @override
  State<SubscriptionPlansPage> createState() => _SubscriptionPlansPageState();
}

class _SubscriptionPlansPageState extends State<SubscriptionPlansPage> {
  final SupabaseClient _client = Supabase.instance.client;
  bool _isLoading = true;
  List<Map<String, dynamic>> _plansList = [];

  @override
  void initState() {
    super.initState();
    _loadPlans();
  }

  Future<void> _loadPlans() async {
    setState(() => _isLoading = true);
    try {
      final response = await _client.rpc('list_subscription_plans_for_app');
      final ok = response != null && response is Map && (response['ok'] as bool? ?? false);
      if (ok && response['plans'] is List) {
        setState(() {
          _plansList = (response['plans'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        });
      } else {
        throw Exception(response?['error'] ?? 'Gagal memuat paket subscription.');
      }
    } catch (e) {
      debugPrint('[LOAD_PLANS_ERROR] $e');
      AppUi.showSnack('GAGAL MEMUAT PAKET: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.secondary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('DAFTAR PAKET SUBSCRIPTION', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
        actions: [
          IconButton(
            tooltip: 'Reload data',
            icon: const Icon(Icons.refresh),
            onPressed: _loadPlans,
          ),
        ],
      ),
      body: AppGlobalBackdrop(
        child: _isLoading
            ? const Center(child: FuturisticLoader(message: 'MEMUAT DAFTAR PAKET...'))
            : _plansList.isEmpty
                ? const EmptyState(
                    title: 'BELUM ADA PAKET',
                    subtitle: 'Tidak ada paket subscription aktif yang ditemukan.',
                    icon: Icons.card_membership_rounded,
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FuturisticHeader(
                          icon: Icons.card_membership_rounded,
                          title: 'PAKET SUBSCRIPTION',
                          subtitle: 'Daftar paket harga, fitur, dan batasan kuota untuk client multi-tenant.',
                          stats: [
                            StatPill(label: 'Total Paket', value: _plansList.length.toString(), accentColor: AppUi.purple),
                          ],
                        ),
                        const SizedBox(height: 24),
                        ..._plansList.map((plan) {
                          final planName = plan['plan_name']?.toString() ?? 'Unnamed Plan';
                          final planCode = plan['plan_code']?.toString() ?? '-';
                          final description = plan['description']?.toString() ?? '';
                          final price = AppUi.toNum(plan['price_amount']);
                          final currency = plan['currency']?.toString() ?? 'IDR';
                          final billingPeriod = plan['billing_period']?.toString() ?? 'monthly';
                          
                          final maxUsers = plan['max_users'];
                          final maxMarketplace = plan['max_marketplace_accounts'];
                          final maxShopee = plan['max_shopee_accounts'];
                          final maxTiktok = plan['max_tiktok_accounts'];
                          final maxStorage = plan['max_storage_mb'];
                          final retentionDays = plan['max_order_retention_days'] ?? 90;
                          final isTrial = plan['is_trial'] as bool? ?? false;
                          final features = plan['features'] is List ? List<String>.from(plan['features']) : <String>[];

                          final displayPrice = price == 0
                              ? 'GRATIS'
                              : '$currency ${AppUi.money(price)} / $billingPeriod';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 24),
                            child: NiceCard(
                              borderColor: isTrial ? AppUi.teal : Colors.black,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              planName.toUpperCase(),
                                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'KODE PAKET: $planCode'.toUpperCase(),
                                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 10, color: Colors.grey[600]),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isTrial)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: AppUi.teal.withOpacity(0.15),
                                            border: Border.all(color: AppUi.teal, width: 1.5),
                                          ),
                                          child: const Text(
                                            'TRIAL',
                                            style: TextStyle(color: AppUi.teal, fontWeight: FontWeight.w900, fontSize: 9),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    displayPrice,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 18,
                                      color: price == 0 ? AppUi.green : theme.colorScheme.primary,
                                    ),
                                  ),
                                  if (description.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      description,
                                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                                    ),
                                  ],
                                  const SizedBox(height: 16),
                                  Divider(height: 1, thickness: 2, color: accent),
                                  const SizedBox(height: 16),
                                  
                                  const Text('BATASAN KUOTA', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _quotaStat('Max Users', maxUsers != null ? maxUsers.toString() : 'Unlimited'),
                                      _quotaStat('Marketplace', maxMarketplace != null ? maxMarketplace.toString() : 'Unlimited'),
                                      _quotaStat('Shopee Toko', maxShopee != null ? maxShopee.toString() : 'Unlimited'),
                                      _quotaStat('TikTok Toko', maxTiktok != null ? maxTiktok.toString() : 'Unlimited'),
                                      _quotaStat('Storage MB', maxStorage != null ? '${maxStorage} MB' : 'Unlimited'),
                                      _quotaStat('Retensi Order', '$retentionDays Hari'),
                                    ],
                                  ),
                                  const SizedBox(height: 20),
                                  
                                  const Text('FITUR TERMASUK', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                                  const SizedBox(height: 8),
                                  if (features.isEmpty)
                                    Text('Tidak ada fitur khusus.'.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.grey[600]))
                                  else
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: features.map((feature) {
                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: AppUi.green.withOpacity(0.08),
                                            border: Border.all(color: AppUi.green, width: 1.5),
                                          ),
                                          child: Text(
                                            feature.replaceAll('_', ' ').toUpperCase(),
                                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 8.5, color: AppUi.green),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _quotaStat(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        border: Border.all(color: Colors.grey[400]!, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: '.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 8.5, color: Colors.grey[700]),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 9.5),
          ),
        ],
      ),
    );
  }
}
