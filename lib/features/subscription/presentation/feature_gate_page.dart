import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../services/tenant_entitlement_service.dart';

class FeatureGatePage extends StatefulWidget {
  final String featureKey;
  final String featureLabel;
  final Widget child;

  const FeatureGatePage({
    super.key,
    required this.featureKey,
    required this.child,
    this.featureLabel = 'Fitur ini',
  });

  @override
  State<FeatureGatePage> createState() => _FeatureGatePageState();
}

class _FeatureGatePageState extends State<FeatureGatePage> {
  late final Future<TenantEntitlementSnapshot> _future;

  @override
  void initState() {
    super.initState();
    _future = TenantEntitlementService(Supabase.instance.client).load();
  }

  bool _allowed(TenantEntitlementSnapshot snapshot) {
    if (snapshot.isPlatformOwner) return true;
    return snapshot.isFeatureEnabled(widget.featureKey);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TenantEntitlementSnapshot>(
      future: _future,
      builder: (context, state) {
        final snapshot = state.data;

        if (state.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot != null && _allowed(snapshot)) {
          return widget.child;
        }

        final planName = snapshot?.planName.trim().isNotEmpty == true
            ? snapshot!.planName
            : 'paket aktif';

        return WebResponsiveScaffold(
          appBar: AppBar(title: const Text('Akses dibatasi')),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: NiceCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        decoration: AppUi.tintedDecoration(
                          context,
                          color: Theme.of(context).colorScheme.primary,
                          radius: 18,
                        ),
                        child: Icon(
                          Icons.lock_outline_rounded,
                          size: 30,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '${widget.featureLabel} tidak aktif di $planName.',
                        textAlign: TextAlign.center,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Hubungi owner/platform owner untuk mengubah paket atau entitlement tenant.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.68),
                              height: 1.4,
                            ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              final navigator = Navigator.of(context);
                              if (navigator.canPop()) navigator.pop();
                            },
                            icon: const Icon(Icons.arrow_back_rounded),
                            label: const Text('Kembali'),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: () => _showUpgradeRequestDialog(context),
                            icon: const Icon(Icons.upgrade_rounded),
                            label: const Text('Ajukan Upgrade'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showUpgradeRequestDialog(BuildContext context) {
    String selectedPlan = 'starter';
    int selectedMonths = 1;
    final notesController = TextEditingController();
    bool isSending = false;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('AJUKAN UPGRADE / PERPANJANGAN',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Pilih paket yang Anda butuhkan:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: selectedPlan,
                      items: const [
                        DropdownMenuItem(
                            value: 'starter', child: Text('Starter (Rp 300.000/bln)')),
                        DropdownMenuItem(
                            value: 'growth', child: Text('Growth (Rp 500.000/bln)')),
                        DropdownMenuItem(
                            value: 'pro', child: Text('Pro (Rp 800.000/bln)')),
                        DropdownMenuItem(
                            value: 'enterprise',
                            child: Text('Enterprise (Rp 1.300.000/bln)')),
                      ],
                      onChanged: (v) {
                        if (v != null) setDialogState(() => selectedPlan = v);
                      },
                    ),
                    const SizedBox(height: 14),
                    const Text('Durasi:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 1, label: Text('1 Bln')),
                        ButtonSegment(value: 3, label: Text('3 Bln')),
                        ButtonSegment(value: 6, label: Text('6 Bln')),
                        ButtonSegment(value: 12, label: Text('1 Thn')),
                      ],
                      selected: {selectedMonths},
                      onSelectionChanged: (set) =>
                          setDialogState(() => selectedMonths = set.first),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: notesController,
                      decoration: const InputDecoration(
                        labelText: 'Catatan / Kontak Konfirmasi',
                        hintText: 'Misal: Butuh aktivasi fitur finance, WA: 08123xxx',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSending ? null : () => Navigator.pop(ctx),
                  child: const Text('BATAL'),
                ),
                FilledButton(
                  onPressed: isSending
                      ? null
                      : () async {
                          setDialogState(() => isSending = true);
                          try {
                            final res = await Supabase.instance.client.rpc(
                              'tenant_submit_renewal_request',
                              params: {
                                'p_plan_code': selectedPlan,
                                'p_duration_months': selectedMonths,
                                'p_proof_url': null,
                                'p_notes': notesController.text.trim(),
                              },
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                            AppUi.showSnack(res['message']?.toString() ??
                                'Pengajuan berhasil dikirim!');
                          } catch (e) {
                            AppUi.showSnack('Gagal mengirim: $e');
                          } finally {
                            if (ctx.mounted) {
                              setDialogState(() => isSending = false);
                            }
                          }
                        },
                  child: isSending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('KIRIM PENGAJUAN'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
