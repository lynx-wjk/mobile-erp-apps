import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/ui/app_ui.dart';
import '../../../models/app_user.dart';
import '../models/marketplace_account_public.dart';
import '../services/marketplace_historical_import_service.dart';

class MarketplaceHistoricalImportPage extends StatefulWidget {
  final AppUser currentUser;
  final List<MarketplaceAccountPublic> accounts;

  const MarketplaceHistoricalImportPage({
    super.key,
    required this.currentUser,
    required this.accounts,
  });

  @override
  State<MarketplaceHistoricalImportPage> createState() =>
      _MarketplaceHistoricalImportPageState();
}

class _MarketplaceHistoricalImportPageState
    extends State<MarketplaceHistoricalImportPage> {
  final MarketplaceHistoricalImportService _service =
      MarketplaceHistoricalImportService();

  String? _selectedAccountId;
  HistoricalImportParseResult? _orderParsed;
  HistoricalImportParseResult? _incomeParsed;
  String? _orderBatchId;
  String? _incomeBatchId;
  Map<String, dynamic>? _validation;
  Map<String, dynamic>? _payoutReadiness;
  bool _busy = false;
  String? _message;
  String? _error;

  List<MarketplaceAccountPublic> get _activeAccounts => widget.accounts
      .where((account) => account.status.toLowerCase() == 'active')
      .toList(growable: false);

  MarketplaceAccountPublic? get _selectedAccount {
    final id = _selectedAccountId;
    if (id == null) return _activeAccounts.isEmpty ? null : _activeAccounts.first;
    for (final account in _activeAccounts) {
      if (account.marketplaceAccountId == id) return account;
    }
    return _activeAccounts.isEmpty ? null : _activeAccounts.first;
  }

  @override
  void initState() {
    super.initState();
    if (_activeAccounts.isNotEmpty) {
      _selectedAccountId = _activeAccounts.first.marketplaceAccountId;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickOrder() async {
    final account = _selectedAccount;
    if (account == null) return;
    await _run(() async {
      final parsed = await _service.pickAndParseOrderExport(
        marketplace: account.marketplace,
      );
      if (parsed == null) return;
      setState(() {
        _orderParsed = parsed;
        _orderBatchId = null;
        _validation = null;
        _message =
            'Order export siap: ${parsed.totalRows} row, valid ${parsed.validRows}.';
      });
    });
  }

  Future<void> _pickIncome() async {
    final account = _selectedAccount;
    if (account == null) return;
    await _run(() async {
      final parsed = await _service.pickAndParseIncomeExport(
        marketplace: account.marketplace,
      );
      if (parsed == null) return;
      setState(() {
        _incomeParsed = parsed;
        _incomeBatchId = null;
        _payoutReadiness = null;
        _message =
            'Income export siap: ${parsed.totalRows} row, estimasi payout ${_money(parsed.validGrossTotal)}.';
      });
    });
  }

  Future<void> _uploadOrder() async {
    final account = _selectedAccount;
    final parsed = _orderParsed;
    if (account == null || parsed == null) return;

    await _run(() async {
      final result = await _service.uploadOrderExport(
        marketplaceAccountId: account.marketplaceAccountId,
        marketplace: account.marketplace,
        parsed: parsed,
      );
      setState(() {
        _orderBatchId = result.batchId;
        _message =
            'Order export masuk staging: ${result.uploadedRows}/${result.totalRows} row.';
      });
    });
  }

  Future<void> _uploadIncome() async {
    final account = _selectedAccount;
    final parsed = _incomeParsed;
    if (account == null || parsed == null) return;

    await _run(() async {
      final result = await _service.uploadIncomeExport(
        marketplaceAccountId: account.marketplaceAccountId,
        marketplace: account.marketplace,
        parsed: parsed,
      );
      setState(() {
        _incomeBatchId = result.batchId;
        _message =
            'Income/payout export masuk staging: ${result.uploadedRows}/${result.totalRows} row.';
      });
    });
  }

  Future<void> _validate() async {
    final account = _selectedAccount;
    if (account == null) return;

    await _run(() async {
      final validation = await _service.fetchValidationSnapshot(
        marketplaceAccountId: account.marketplaceAccountId,
      );
      final payout = await _service.fetchPayoutReadiness(
        marketplaceAccountId: account.marketplaceAccountId,
      );
      setState(() {
        _validation = validation;
        _payoutReadiness = payout;
        _message = 'Validasi import diperbarui.';
      });
    });
  }

  Future<void> _finalize() async {
    final account = _selectedAccount;
    if (account == null) return;

    final validation = _validation;
    final summary = validation?['summary'];
    final validOrders = _asInt(
      summary is Map ? summary['valid_orders'] : null,
    );

    if (validOrders <= 0) {
      setState(() => _error =
          'Belum ada valid order di validasi. Jangan finalize, nanti data bolong. Luar biasa konsepnya.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finalize bootstrap marketplace?'),
        content: Text(
          'Akun ${account.safeStoreName} akan dianggap selesai bootstrap. '
          'Cursor sync dipindah ke sekarang. Pastikan order export dan income export sudah masuk staging dan angka validasi cocok.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Finalize'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await _run(() async {
      final result = await _service.finalizeBootstrap(
        marketplaceAccountId: account.marketplaceAccountId,
        minValidOrders: validOrders,
      );
      setState(() {
        _message = 'Finalize result: ${jsonEncode(result)}';
      });
    });
  }

  String _money(num value) {
    final text = value.round().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final pos = text.length - i;
      buffer.write(text[i]);
      if (pos > 1 && pos % 3 == 1) buffer.write('.');
    }
    return 'Rp ${buffer.toString()}';
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Widget _fileCard({
    required String title,
    required String subtitle,
    required HistoricalImportParseResult? parsed,
    required VoidCallback onPick,
    required VoidCallback? onUpload,
    required String? batchId,
    required IconData icon,
  }) {
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(title: title),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (parsed == null)
            const Text('Belum ada file dipilih.')
          else ...[
            _MetricLine(label: 'File', value: parsed.fileName),
            _MetricLine(label: 'Rows', value: parsed.totalRows.toString()),
            _MetricLine(label: 'Valid-ish', value: parsed.validRows.toString()),
            _MetricLine(label: 'Cancelled', value: parsed.cancelledRows.toString()),
            _MetricLine(label: 'Gross', value: _money(parsed.grossTotal)),
            _MetricLine(label: 'Valid Gross', value: _money(parsed.validGrossTotal)),
            if (batchId != null) _MetricLine(label: 'Batch ID', value: batchId),
            const SizedBox(height: 10),
            Text(
              'Header terdeteksi: ${parsed.headers.take(12).join(', ')}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : onPick,
                icon: Icon(icon),
                label: const Text('Pilih File'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : onUpload,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Upload ke Staging'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _jsonBox(String title, Map<String, dynamic>? value) {
    if (value == null) return const SizedBox.shrink();
    const encoder = JsonEncoder.withIndent('  ');
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(title: title),
          const SizedBox(height: 8),
          SelectableText(
            encoder.convert(value),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = _selectedAccount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Historical Marketplace'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _validate,
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: 'Validasi',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          FuturisticHeader(
            icon: Icons.upload_file_outlined,
            title: 'Import Historical Data',
            subtitle:
                'Upload export order dan income ke staging dulu. Finalize dinonaktifkan sampai mapper final ke tabel order/finance live beres.',
            stats: [
              StatPill(label: 'Account', value: _activeAccounts.length.toString()),
              StatPill(label: 'Order', value: _orderParsed?.totalRows.toString() ?? '-'),
              StatPill(label: 'Income', value: _incomeParsed?.totalRows.toString() ?? '-'),
            ],
          ),
          const SizedBox(height: 14),
          if (_error != null) ...[
            ErrorState(message: _error!, onRetry: () => setState(() => _error = null)),
            const SizedBox(height: 14),
          ],
          if (_message != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppUi.green.withOpacity(.12),
                border: Border.all(color: AppUi.green.withOpacity(.4)),
              ),
              child: Text(_message!, style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 14),
          ],
          NiceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle(title: 'Target Akun Marketplace'),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: account?.marketplaceAccountId,
                  decoration: const InputDecoration(
                    labelText: 'Akun',
                    border: OutlineInputBorder(),
                  ),
                  items: _activeAccounts
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.marketplaceAccountId,
                          child: Text('${item.marketplaceLabel} · ${item.safeStoreName}'),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() {
                            _selectedAccountId = value;
                            _orderParsed = null;
                            _incomeParsed = null;
                            _orderBatchId = null;
                            _incomeBatchId = null;
                            _validation = null;
                            _payoutReadiness = null;
                          });
                        },
                ),
                if (_activeAccounts.isEmpty) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Belum ada akun active. Auth marketplace dulu, baru import export.',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          _fileCard(
            title: '1. Order Export 90 Hari',
            subtitle:
                'Pakai file order dari TikTok/Shopee. Bisa pilih lebih dari 1 file sekaligus, termasuk Shopee export yang terpisah.',
            parsed: _orderParsed,
            onPick: _pickOrder,
            onUpload: _orderParsed == null ? null : _uploadOrder,
            batchId: _orderBatchId,
            icon: Icons.receipt_long_outlined,
          ),
          const SizedBox(height: 14),
          _fileCard(
            title: '2. Income / Payout Export 90 Hari',
            subtitle:
                'Pakai file income/settlement/payout. Bisa pilih lebih dari 1 file sekaligus jika marketplace memecah export.',
            parsed: _incomeParsed,
            onPick: _pickIncome,
            onUpload: _incomeParsed == null ? null : _uploadIncome,
            batchId: _incomeBatchId,
            icon: Icons.payments_outlined,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy || account == null ? null : _validate,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.fact_check_outlined),
                label: Text(_busy ? 'Memproses...' : 'Validasi Import'),
              ),
              OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Finalize belum aktif'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _jsonBox('Order Validation Snapshot', _validation),
          const SizedBox(height: 14),
          _jsonBox('Payout Readiness', _payoutReadiness),
        ],
      ),
    );
  }
}

class _MetricLine extends StatelessWidget {
  final String label;
  final String value;

  const _MetricLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 98,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
