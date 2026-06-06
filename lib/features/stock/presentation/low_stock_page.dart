import 'package:flutter/material.dart';

import '../../../core/ui/app_ui.dart';
import '../models/product.dart';
import '../repositories/product_repository.dart';

class LowStockPage extends StatefulWidget {
  const LowStockPage({super.key});

  @override
  State<LowStockPage> createState() => _LowStockPageState();
}

class _LowStockPageState extends State<LowStockPage> {
  final _repository = ProductRepository();

  bool _isLoading = true;
  String? _errorMessage;
  List<Product> _products = [];

  @override
  void initState() {
    super.initState();
    _loadLowStock();
  }

  Future<void> _loadLowStock() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final products = await _repository.getLowStockProducts();

      if (!mounted) return;

      setState(() {
        _products = products;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const FuturisticLoader(message: 'Mengecek stok rendah...');
    }

    if (_errorMessage != null) {
      return ErrorState(
        message: AppUi.userMessage(_errorMessage!),
        onRetry: _loadLowStock,
      );
    }

    if (_products.isEmpty) {
      return const EmptyState(
        icon: Icons.verified_rounded,
        title: 'Stok Aman',
        subtitle:
            'Belum ada SKU lokal yang menyentuh limit minimum untuk saat ini.',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadLowStock,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          FuturisticHeader(
            icon: Icons.warning_amber_rounded,
            title: 'Stock Low',
            subtitle:
                'Prioritas restock SKU lokal sebelum marketplace oversell.',
            stats: [
              StatPill(label: 'SKU', value: _products.length.toString()),
              StatPill(label: 'Core', value: 'Lokal'),
            ],
          ),
          const SizedBox(height: 14),
          ..._products.map(_productCard),
        ],
      ),
    );
  }

  Widget _productCard(Product product) {
    final stockText = _qty(product.stockSaatIni);
    final limitText = _qty(product.lowStockLimit);
    final location = product.lokasiRak?.trim();
    final theme = Theme.of(context);
    final accent = product.stockSaatIni <= 0
        ? theme.colorScheme.error
        : theme.colorScheme.secondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NiceCard(
        borderColor: accent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: accent.withOpacity(0.45)),
              ),
              child: Icon(Icons.inventory_2_rounded, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.namaBarang,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'SKU ${product.kodeSku} · ${product.satuan}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _miniStat('Stok', stockText, accent),
                      _miniStat('Limit', limitText, Theme.of(context).colorScheme.primary),
                      if (location != null && location.isNotEmpty)
                        _miniStat('Rak', location, Theme.of(context).colorScheme.secondary),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  String _qty(num value) {
    if (value % 1 == 0) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Stock Low'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : _loadLowStock,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}
