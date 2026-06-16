import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

        return Scaffold(
          appBar: AppBar(title: const Text('Akses dibatasi')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline_rounded, size: 54),
                    const SizedBox(height: 16),
                    Text(
                      '${widget.featureLabel} tidak aktif di $planName.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Hubungi owner/platform owner untuk mengubah paket atau entitlement tenant.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () {
                        final navigator = Navigator.of(context);
                        if (navigator.canPop()) navigator.pop();
                      },
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: const Text('Kembali'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
