import 'package:flutter/material.dart';

import '../../../models/app_user.dart';
import '../models/product.dart';
import '../models/stock_transaction_item.dart';
import '../repositories/product_repository.dart';
import '../repositories/stock_repository.dart';
import 'low_stock_page.dart';
import 'product_list_page.dart';
import 'stock_history_page.dart';
import 'stock_in_page.dart';
import 'stock_out_page.dart';
import '../../attendance/presentation/attendance_page.dart';

class WarehouseDashboardPage extends StatefulWidget {
  final AppUser currentUser;

  const WarehouseDashboardPage({
    super.key,
    required this.currentUser,
  });

  @override
  State<WarehouseDashboardPage> createState() => _WarehouseDashboardPageState();
}

class _WarehouseDashboardPageState extends State<WarehouseDashboardPage> {
  final _productRepository = ProductRepository();
  final _stockRepository = StockRepository();

  bool _isLoading = true;
  String? _errorMessage;

  List<Product> _products = [];
  List<Product> _lowStockProducts = [];

  List<StockTransactionItem> _allTransactions = [];
  List<StockTransactionItem> _recentTransactions = [];

  @override
  void initState() {
    super.initState();
    _loadDashboard();
  }

  Future<void> _loadDashboard() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final products = await _productRepository.getProducts(activeOnly: true);
      final transactions = await _stockRepository.getRecentTransactions();

      if (!mounted) return;

      setState(() {
        _products = products;
        _lowStockProducts = products.where((item) => item.isLowStock).toList();

        _allTransactions = transactions;
        _recentTransactions = transactions.take(5).toList();
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

  bool _isToday(DateTime date) {
    final localDate = date.toLocal();
    final now = DateTime.now();

    return localDate.year == now.year &&
        localDate.month == now.month &&
        localDate.day == now.day;
  }

  double get _totalStock {
    return _products.fold<double>(
      0,
          (total, product) => total + product.stockSaatIni,
    );
  }

  double get _stockInToday {
    return _allTransactions
        .where(
          (item) => item.transactionType == 'IN' && _isToday(item.createdAt),
    )
        .fold<double>(
      0,
          (total, item) => total + item.qty,
    );
  }

  double get _stockOutToday {
    return _allTransactions
        .where(
          (item) => item.transactionType == 'OUT' && _isToday(item.createdAt),
    )
        .fold<double>(
      0,
          (total, item) => total + item.qty,
    );
  }

  int get _transactionCountToday {
    return _allTransactions.where((item) => _isToday(item.createdAt)).length;
  }

  void _openPage(Widget page) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    ).then((_) => _loadDashboard());
  }

  String _formatNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }

    return value.toStringAsFixed(2);
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 25,
                child: Icon(icon),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentTransactions() {
    if (_recentTransactions.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Belum ada transaksi stock.'),
        ),
      );
    }

    return Column(
      children: _recentTransactions.map((item) {
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Text(item.transactionType),
            ),
            title: Text('${item.kodeSku} - ${item.namaBarang}'),
            subtitle: Text(
              'Qty: ${_formatNumber(item.qty)}\n'
                  'Stock: ${_formatNumber(item.stockBefore)} → ${_formatNumber(item.stockAfter)}\n'
                  'Sumber/Tujuan: ${item.sumberTujuan ?? '-'}\n'
                  'Resi: ${item.nomorResi ?? '-'}\n'
                  'User: ${item.userDisplay}',
            ),
            isThreeLine: false,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorMessage!,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDashboard,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.warehouse_outlined),
              ),
              title: const Text('Dashboard Warehouse'),
              subtitle: Text(
                '${widget.currentUser.nama}\n'
                    '${widget.currentUser.email}\n'
                    'Transaksi hari ini: $_transactionCountToday',
              ),
              isThreeLine: true,
            ),
          ),
          const SizedBox(height: 12),
          _summaryCard(
            title: 'Total SKU Aktif',
            value: _products.length.toString(),
            icon: Icons.inventory_2_outlined,
            onTap: () => _openPage(
              ProductListPage(currentUser: widget.currentUser),
            ),
          ),
          _summaryCard(
            title: 'Total Stock',
            value: _formatNumber(_totalStock),
            icon: Icons.warehouse_outlined,
            onTap: () => _openPage(
              ProductListPage(currentUser: widget.currentUser),
            ),
          ),
          _summaryCard(
            title: 'Barang Low Stock',
            value: _lowStockProducts.length.toString(),
            icon: Icons.warning_amber_outlined,
            onTap: () => _openPage(const LowStockPage()),
          ),
          _summaryCard(
            title: 'Stock Masuk Hari Ini',
            value: _formatNumber(_stockInToday),
            icon: Icons.add_box_outlined,
            onTap: () => _openPage(const StockInPage()),
          ),
          _summaryCard(
            title: 'Stock Keluar Hari Ini',
            value: _formatNumber(_stockOutToday),
            icon: Icons.indeterminate_check_box_outlined,
            onTap: () => _openPage(const StockOutPage()),
          ),
          const SizedBox(height: 16),
          Text(
            'Aksi Cepat',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _openPage(const StockInPage()),
                  icon: const Icon(Icons.add_box_outlined),
                  label: const Text('Stok Masuk'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _openPage(const StockOutPage()),
                  icon: const Icon(Icons.indeterminate_check_box_outlined),
                  label: const Text('Stok Keluar'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _openPage(
              AbsensiPage(currentUser: widget.currentUser),
            ),
            icon: const Icon(Icons.person_pin_circle_outlined),
            label: const Text('Absensi Warehouse'),
          ),
          const SizedBox(height: 16),
          Text(
            'Riwayat Terbaru',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _buildRecentTransactions(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _openPage(const StockHistoryPage()),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Lihat Semua Riwayat'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard Warehouse'),
      ),
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }
}