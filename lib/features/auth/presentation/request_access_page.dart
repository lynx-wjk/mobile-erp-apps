import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/ui/app_ui.dart';
import 'auth_gate.dart';

class RequestAccessPage extends StatefulWidget {
  const RequestAccessPage({super.key});

  @override
  State<RequestAccessPage> createState() => _RequestAccessPageState();
}

class _RequestAccessPageState extends State<RequestAccessPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoadingPlans = true;
  List<Map<String, dynamic>> _plans = [];

  @override
  void initState() {
    super.initState();
    _loadPublicPlans();
  }

  Future<void> _loadPublicPlans() async {
    setState(() => _isLoadingPlans = true);
    try {
      final response = await _client.rpc('list_public_subscription_plans');
      final ok = response != null &&
          response is Map &&
          (response['ok'] as bool? ?? false);

      if (!ok) {
        throw Exception(
          response is Map
              ? (response['message'] ?? response['error'] ?? response)
              : 'Gagal memuat paket subscription.',
        );
      }

      if (!mounted) return;
      setState(() {
        _plans = (response['plans'] as List? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      });
    } catch (e, st) {
      debugPrint('[LOAD_PUBLIC_PLANS_ERROR] $e\n$st');
      AppUi.showSnack('GAGAL MEMUAT PAKET PUBLIK: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoadingPlans = false);
    }
  }

  Future<void> _launchOrCopy(String urlString, String copyFallbackMsg) async {
    final uri = Uri.parse(urlString);
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        Clipboard.setData(ClipboardData(text: urlString));
        AppUi.showSnack(copyFallbackMsg);
      }
    } catch (_) {
      Clipboard.setData(ClipboardData(text: urlString));
      AppUi.showSnack(copyFallbackMsg);
    }
  }

  String _planPrice(Map<String, dynamic> plan) {
    final price = AppUi.toNum(plan['price_amount']);
    final currency = plan['currency']?.toString() ?? 'IDR';
    final period = plan['billing_period']?.toString() ?? 'monthly';

    if (price <= 0) return 'GRATIS / TRIAL';

    final periodLabel = switch (period) {
      'yearly' => 'tahun',
      'quarterly' => '3 bulan',
      _ => 'bulan',
    };

    return '$currency ${AppUi.money(price)} / $periodLabel';
  }

  String _limitText(dynamic value) {
    if (value == null) return 'Unlimited';
    final text = value.toString();
    if (text.trim().isEmpty) return 'Unlimited';
    return text;
  }

  List<Map<String, dynamic>> _planFeatures(Map<String, dynamic> plan) {
    final raw = plan['features'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  String _featureLabel(Map<String, dynamic> feature) {
    final label = feature['label']?.toString();
    if (label != null && label.trim().isNotEmpty) return label;
    return feature['feature_key']?.toString().replaceAll('_', ' ') ?? '-';
  }

  String _requestText({String? planName, String? planCode}) {
    final planPart = planName == null || planName.trim().isEmpty
        ? ''
        : ' Saya tertarik dengan paket $planName ($planCode).';
    return Uri.encodeComponent(
      'Halo Platform Owner, saya ingin request access Mobile ERP.$planPart Mohon info proses aktivasi dan demo.',
    );
  }

  void _requestViaWhatsApp({String? planName, String? planCode}) {
    final text = _requestText(planName: planName, planCode: planCode);
    _launchOrCopy(
      'https://wa.me/6285155338246?text=$text',
      'Link WhatsApp disalin ke clipboard.',
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(
              theme.brightness == Brightness.dark ? 0.18 : 0.10,
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.24),
            ),
            boxShadow: AppTheme.softShadow(theme.brightness),
          ),
          child: Icon(
            Icons.lock_person_outlined,
            color: theme.colorScheme.primary,
            size: 38,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Paket & Request Access',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Pilih paket, lalu hubungi Platform Owner',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: theme.colorScheme.primary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _infoCard(BuildContext context) {
    final theme = Theme.of(context);
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline,
                  color: theme.colorScheme.primary, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Informasi penting',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Akses Mobile ERP dibuat melalui undangan Platform Owner. Pilih paket yang sesuai, lalu kirim request agar tenant dan akun owner bisa disiapkan.',
            style: TextStyle(
                fontWeight: FontWeight.w500, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _plansSection(BuildContext context) {
    if (_isLoadingPlans) {
      return const NiceCard(
        child: Center(
          child: FuturisticLoader(message: 'Memuat paket publik...'),
        ),
      );
    }

    if (_plans.isEmpty) {
      return const EmptyState(
        title: 'Paket belum tersedia',
        subtitle: 'Daftar paket publik belum aktif.',
        icon: Icons.card_membership_rounded,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Paket tersedia',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
        const SizedBox(height: 10),
        ..._plans.map(_planCard),
      ],
    );
  }

  Widget _planCard(Map<String, dynamic> plan) {
    final planName = plan['plan_name']?.toString() ?? '-';
    final planCode = plan['plan_code']?.toString() ?? '-';
    final description = plan['description']?.toString() ?? '';
    final isTrial = plan['is_trial'] as bool? ?? false;
    final features = _planFeatures(plan);
    final visibleFeatures = features.take(8).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: NiceCard(
        borderColor: isTrial ? AppUi.teal : null,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    planName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
                if (isTrial) _badge('TRIAL', AppUi.teal),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Kode: $planCode',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _planPrice(plan),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: AppUi.green,
              ),
            ),
            if (description.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                description,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 12,
                  color: Colors.grey[700],
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _quotaBadge('USER', _limitText(plan['max_users'])),
                _quotaBadge('MARKETPLACE',
                    _limitText(plan['max_marketplace_accounts'])),
                _quotaBadge('SHOPEE', _limitText(plan['max_shopee_accounts'])),
                _quotaBadge('TIKTOK', _limitText(plan['max_tiktok_accounts'])),
                _quotaBadge('RETENSI',
                    '${plan['max_order_retention_days'] ?? 90} HARI'),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Fitur utama',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (visibleFeatures.isEmpty)
              Text(
                'Fitur belum ditampilkan.',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w600,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: visibleFeatures.map((feature) {
                  return _featureChip(_featureLabel(feature));
                }).toList(),
              ),
            if (features.length > visibleFeatures.length) ...[
              const SizedBox(height: 8),
              Text(
                '+${features.length - visibleFeatures.length} fitur lainnya',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => _requestViaWhatsApp(
                planName: planName,
                planCode: planCode,
              ),
              icon: const Icon(Icons.chat_rounded, size: 16),
              label: const Text(
                'Request paket ini',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _featureChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppUi.green.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppUi.green.withOpacity(0.28)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 11,
          color: AppUi.green,
        ),
      ),
    );
  }

  Widget _quotaBadge(String label, String value) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(
          theme.brightness == Brightness.dark ? 0.30 : 0.70,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.28)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _contactRow({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required String btnLabel,
    required Color color,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return NiceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withOpacity(
                    theme.brightness == Brightness.dark ? 0.18 : 0.10,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withOpacity(0.28)),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withOpacity(0.62),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text(
              btnLabel,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _contactsSection(BuildContext context) {
    return Column(
      children: [
        _contactRow(
          context: context,
          icon: Icons.phone_android_rounded,
          title: 'WhatsApp',
          subtitle: 'wa.me/6285155338246',
          btnLabel: 'Hubungi via WhatsApp',
          color: AppUi.green,
          onTap: () => _requestViaWhatsApp(),
        ),
        const SizedBox(height: 12),
        _contactRow(
          context: context,
          icon: Icons.email_rounded,
          title: 'Email',
          subtitle: 'bdchydi@sre.co.id',
          btnLabel: 'Kirim Email',
          color: AppUi.blue,
          onTap: () => _launchOrCopy(
            'mailto:bdchydi@sre.co.id?subject=Request%20Access%20Mobile%20ERP&body=Halo%20Platform%20Owner%2C%20saya%20ingin%20request%20access%20Mobile%20ERP.',
            'Link Email disalin ke clipboard.',
          ),
        ),
        const SizedBox(height: 12),
        _contactRow(
          context: context,
          icon: Icons.camera_alt_rounded,
          title: 'Instagram',
          subtitle: '@bdchydi',
          btnLabel: 'Buka Instagram',
          color: AppUi.pink,
          onTap: () => _launchOrCopy(
            'https://instagram.com/bdchydi',
            'Link Instagram disalin ke clipboard.',
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppGlobalBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  children: [
                    _header(context),
                    const SizedBox(height: 24),
                    _infoCard(context),
                    const SizedBox(height: 18),
                    _plansSection(context),
                    const SizedBox(height: 18),
                    _contactsSection(context),
                    const SizedBox(height: 24),
                    TextButton.icon(
                      onPressed: () {
                        if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        } else {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (_) => const AuthGate()),
                          );
                        }
                      },
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Kembali ke Login'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
