import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  List<Map<String, dynamic>> _finalizeStatus = const [];

  bool _busy = false;
  String? _message;
  String? _error;

  String? _uploadPhase;
  int _uploadDoneRows = 0;
  int _uploadTotalRows = 0;

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && kIsWeb) {
        _refreshFinalizeStatusSilently();
      }
    });
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

  void _setUploadProgress(String phase, int done, int total) {
    if (!mounted) return;
    setState(() {
      _uploadPhase = phase;
      _uploadDoneRows = done;
      _uploadTotalRows = total;
    });
  }

  void _clearUploadProgress() {
    if (!mounted) return;
    setState(() {
      _uploadPhase = null;
      _uploadDoneRows = 0;
      _uploadTotalRows = 0;
    });
  }

  Future<void> _refreshFinalizeStatusSilently() async {
    try {
      final status = await _service.fetchFinalizeStatus();
      if (!mounted) return;
      setState(() => _finalizeStatus = status);
    } catch (_) {
      // Status finalisasi hanya informasi peng. Error tidak perlu memblokir halaman import.
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
        onProgress: (done, total) =>
            _setUploadProgress('Upload order export', done, total),
      );

      setState(() {
        _orderBatchId = result.batchId;
        _message =
            'Order export masuk staging: ${result.uploadedRows}/${result.totalRows} row.';
      });

      _clearUploadProgress();
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
        onProgress: (done, total) =>
            _setUploadProgress('Upload income/payout export', done, total),
      );

      setState(() {
        _incomeBatchId = result.batchId;
        _message =
            'Income/payout export masuk staging: ${result.uploadedRows}/${result.totalRows} row.';
      });

      _clearUploadProgress();
    });
  }

  Future<void> _uploadAll() async {
    final account = _selectedAccount;
    if (account == null) return;

    final hasOrderToUpload = _orderParsed != null && _orderBatchId == null;
    final hasIncomeToUpload = _incomeParsed != null && _incomeBatchId == null;

    if (!hasOrderToUpload && !hasIncomeToUpload) {
      setState(() {
        _error =
            'Belum ada file baru untuk diupload. Pilih Order dan/atau Income dulu.';
      });
      return;
    }

    await _run(() async {
      final uploadedParts = <String>[];

      if (hasOrderToUpload) {
        final parsed = _orderParsed!;
        final result = await _service.uploadOrderExport(
          marketplaceAccountId: account.marketplaceAccountId,
          marketplace: account.marketplace,
          parsed: parsed,
          onProgress: (done, total) =>
              _setUploadProgress('Upload order export', done, total),
        );

        setState(() => _orderBatchId = result.batchId);
        uploadedParts.add('order ${result.uploadedRows}/${result.totalRows}');
      }

      if (hasIncomeToUpload) {
        final parsed = _incomeParsed!;
        final result = await _service.uploadIncomeExport(
          marketplaceAccountId: account.marketplaceAccountId,
          marketplace: account.marketplace,
          parsed: parsed,
          onProgress: (done, total) =>
              _setUploadProgress('Upload income/payout export', done, total),
        );

        setState(() => _incomeBatchId = result.batchId);
        uploadedParts.add('income ${result.uploadedRows}/${result.totalRows}');
      }

      setState(() {
        _message = 'Upload staging selesai: ${uploadedParts.join(' + ')} row.';
      });

      _clearUploadProgress();
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
      final status = await _service.fetchFinalizeStatus();

      if (!mounted) return;
      setState(() {
        _validation = validation;
        _payoutReadiness = payout;
        _finalizeStatus = status;
        _message = _buildFinalizeStatusSummary(status);
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


  Future<void> _finalizeBootstrap() async {
    final account = _selectedAccount;
    if (account == null) return;

    await _run(() async {
      final result = await _service.finalizeBootstrap(
        marketplaceAccountId: account.marketplaceAccountId,
        minValidOrders: 1,
      );

      final validation = await _service.fetchValidationSnapshot(
        marketplaceAccountId: account.marketplaceAccountId,
      );
      final payout = await _service.fetchPayoutReadiness(
        marketplaceAccountId: account.marketplaceAccountId,
      );
      final status = await _service.fetchFinalizeStatus();

      if (!mounted) return;
      setState(() {
        _validation = validation;
        _payoutReadiness = payout;
        _finalizeStatus = status;
        _message = _buildFinalizeMessage(result, account);
      });
    });
  }

  int _intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'finalized':
        return 'Sudah finalisasi live';
      case 'ready_to_finalize':
        return 'Siap finalize';
      case 'waiting_order_and_income':
        return 'Menunggu order dan income';
      case 'waiting_order':
        return 'Menunggu order';
      case 'waiting_income':
        return 'Menunggu income/payout';
      case 'needs_repair':
        return 'Perlu perbaikan data';
      default:
        return 'Status belum diketahui';
    }
  }

  String _accountTitle(Map<String, dynamic> row) {
    final marketplace = (row['marketplace'] ?? '-').toString();
    final shopName = (row['shop_name'] ?? '-').toString();
    final label = marketplace == 'tiktok_shop'
        ? 'TikTok Shop'
        : marketplace == 'shopee'
            ? 'Shopee'
            : marketplace;
    return '$label · $shopName';
  }

  String _buildFinalizeStatusSummary(List<Map<String, dynamic>> status) {
    if (status.isEmpty) {
      return 'Status finalisasi belum tersedia. Klik Validasi Import untuk memperbarui.';
    }

    final pending = status
        .where((row) => row['finalize_status'] != 'finalized')
        .map(_accountTitle)
        .toList(growable: false);

    if (pending.isEmpty) {
      return 'Semua akun marketplace sudah selesai finalisasi live.';
    }

    return 'Belum finalisasi live: ${pending.join(', ')}.';
  }

  String _buildFinalizeMessage(
    Map<String, dynamic> result,
    MarketplaceAccountPublic account,
  ) {
    final ok = result['ok'] == true;
    final message = (result['message'] ?? '').toString();

    if (!ok) {
      return 'Finalisasi ${account.marketplaceLabel} · ${account.safeStoreName} belum berhasil. $message';
    }

    final orders = _intValue(result['orders_upserted']);
    final items = _intValue(result['items_upserted']);
    final finance = _intValue(result['finance_reports_upserted']);

    if (orders > 0 || items > 0 || finance > 0) {
      return 'Finalisasi ${account.marketplaceLabel} · ${account.safeStoreName} selesai. Order live: $orders, item: $items, laporan payout: $finance.';
    }

    return 'Finalisasi ${account.marketplaceLabel} · ${account.safeStoreName} berhasil divalidasi. Data staging siap diproses ke live.';
  }

  Widget _finalizeStatusCard() {
    if (_finalizeStatus.isEmpty) return const SizedBox.shrink();

    final pending = _finalizeStatus
        .where((row) => row['finalize_status'] != 'finalized')
        .map(_accountTitle)
        .toList(growable: false);

    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: 'Status Finalisasi Akun'),
          const SizedBox(height: 8),
          Text(
            pending.isEmpty
                ? 'Semua akun marketplace sudah selesai finalisasi live.'
                : 'Belum finalisasi live: ${pending.join(', ')}.',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          ..._finalizeStatus.map((row) {
            final status = (row['finalize_status'] ?? '').toString();
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _accountTitle(row),
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 6),
                      _MetricLine(label: 'Status', value: _statusLabel(status)),
                      _MetricLine(
                        label: 'Order staging',
                        value:
                            '${_intValue(row['order_rows'])} row / ${_intValue(row['valid_orders'])} order valid',
                      ),
                      _MetricLine(
                        label: 'Income staging',
                        value: '${_intValue(row['finance_rows'])} row',
                      ),
                      _MetricLine(
                        label: 'Live',
                        value:
                            '${_intValue(row['live_orders'])} order / ${_intValue(row['live_finance_reports'])} payout report',
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
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
            _MetricLine(
              label: 'Cancelled',
              value: parsed.cancelledRows.toString(),
            ),
            _MetricLine(label: 'Gross', value: _money(parsed.grossTotal)),
            _MetricLine(
              label: 'Valid Gross',
              value: _money(parsed.validGrossTotal),
            ),
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
                label: const Text('Upload File Ini'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _uploadProgressCard() {
    final phase = _uploadPhase;
    if (phase == null) return const SizedBox.shrink();

    final total = _uploadTotalRows <= 0 ? 1 : _uploadTotalRows;
    final value = (_uploadDoneRows / total).clamp(0.0, 1.0).toDouble();
    final percent = (value * 100).toStringAsFixed(1);

    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: 'Progress Upload'),
          const SizedBox(height: 8),
          Text(
            phase,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: value, minHeight: 10),
          const SizedBox(height: 10),
          _MetricLine(
            label: 'Progress',
            value: '$_uploadDoneRows / $_uploadTotalRows row ($percent%)',
          ),
          const SizedBox(height: 6),
          const Text(
            'Jangan tutup tab browser sampai selesai. Menu ini web-only karena Android bisa memutus koneksi saat aplikasi diminimize.',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
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

    if (!kIsWeb) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Import Historical Marketplace'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          children: [
            NiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SectionTitle(title: 'Import Historical Data hanya di Web'),
                  SizedBox(height: 8),
                  Text(
                    'Upload file export besar tidak tersedia di Android app. Gunakan Flutter Web dari browser desktop agar koneksi upload tidak diputus saat aplikasi diminimize.',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

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
                'Upload export order dan income ke staging, lalu validasi dan finalize per akun marketplace.',
            stats: [
              StatPill(
                label: 'Account',
                value: _activeAccounts.length.toString(),
              ),
              StatPill(
                label: 'Order',
                value: _orderParsed?.totalRows.toString() ?? '-',
              ),
              StatPill(
                label: 'Income',
                value: _incomeParsed?.totalRows.toString() ?? '-',
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_error != null) ...[
            ErrorState(
              message: _error!,
              onRetry: () => setState(() => _error = null),
            ),
            const SizedBox(height: 14),
          ],
          if (_message != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppUi.green.withOpacity(.12),
                border: Border.all(color: AppUi.green.withOpacity(.4)),
              ),
              child: Text(
                _message!,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (_uploadPhase != null) ...[
            _uploadProgressCard(),
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
                          child: Text(
                            '${item.marketplaceLabel} · ${item.safeStoreName}',
                          ),
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
                            _message = null;
                            _error = null;
                            _clearUploadProgress();
                          });
                        },
                ),
                if (_activeAccounts.isEmpty) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Belum ada akun active. Auth marketplace dulu.',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_finalizeStatus.isNotEmpty) ...[
            _finalizeStatusCard(),
            const SizedBox(height: 14),
          ],
          _fileCard(
            title: '1. Order Export 90 Hari',
            subtitle:
                'Pakai file order dari TikTok/Shopee. Bisa pilih lebih dari 1 file sekaligus, termasuk ZIP order.',
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
                onPressed:
                    _busy || account == null || (_orderParsed == null && _incomeParsed == null)
                        ? null
                        : _uploadAll,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_outlined),
                label: Text(_busy ? 'Upload berjalan...' : 'Upload Order + Income'),
              ),
              FilledButton.icon(
                onPressed: _busy || account == null ? null : _validate,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Validasi Import'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || account == null ? null : _finalizeBootstrap,
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Finalize Bootstrap'),
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

  const _MetricLine({
    required this.label,
    required this.value,
  });

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
