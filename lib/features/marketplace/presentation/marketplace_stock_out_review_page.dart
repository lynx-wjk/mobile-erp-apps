import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../../../core/constants/app_roles.dart';
import '../../../models/app_user.dart';

class MarketplaceStockOutReviewPage extends StatefulWidget {
  final AppUser currentUser;

  const MarketplaceStockOutReviewPage({
    super.key,
    required this.currentUser,
  });

  @override
  State<MarketplaceStockOutReviewPage> createState() =>
      _MarketplaceStockOutReviewPageState();
}

class _MarketplaceStockOutReviewPageState
    extends State<MarketplaceStockOutReviewPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;
  String _filterStatus = 'pending';
  List<_StockOutReviewItem> _items = [];

  static const List<MapEntry<String, String>> _statuses = [
    MapEntry('pending', 'Pending'),
    MapEntry('matched', 'Matched'),
    MapEntry('needs_action', 'Perlu Tindak Lanjut'),
    MapEntry('ignored', 'Ignored'),
    MapEntry('all', 'All'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool prepare = true}) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (prepare) {
        try {
          await _client.rpc(
            'marketplace_prepare_stock_out_reviews',
            params: {
              'p_tenant_id': widget.currentUser.tenantId,
              'p_limit': 300,
            },
          );
        } catch (_) {
          // Review tetap bisa dibuka dari data yang sudah tersedia.
        }
      }

      dynamic query = _client
          .from('marketplace_stock_out_reviews_public')
          .select()
          .eq('tenant_id', widget.currentUser.tenantId);

      if (_filterStatus != 'all') {
        query = query.eq('review_status', _filterStatus);
      }

      final data =
          await query.order('stock_out_at', ascending: false).range(0, 299);

      if (!mounted) return;
      setState(() {
        _items = (data as List<dynamic>)
            .map((item) => _StockOutReviewItem.fromMap(
                Map<String, dynamic>.from(item as Map)))
            .toList();
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _cleanError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _submitReview({
    required _StockOutReviewItem item,
    required String status,
    required String title,
    required String confirmLabel,
  }) async {
    final noteController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Order: ${item.externalOrderId}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Resi: ${item.trackingNumber}'),
                const SizedBox(height: 4),
                Text('Produk: ${item.localSku} · ${item.productName}'),
                const SizedBox(height: 4),
                Text('Qty stock out: ${item.qtyText}'),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Catatan review',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => AppUi.safePop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => AppUi.safePop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      noteController.dispose();
      return;
    }

    final note = noteController.text.trim();
    noteController.dispose();

    setState(() => _isSaving = true);
    try {
      final response = await _client.rpc(
        'marketplace_submit_stock_out_review',
        params: {
          'p_review_id': item.reviewId,
          'p_review_status': status,
          'p_review_note': note.isEmpty ? null : note,
          'p_reviewer_user_id': widget.currentUser.userId.trim().isEmpty
              ? null
              : widget.currentUser.userId,
          'p_reviewer_name': widget.currentUser.nama,
          'p_reviewer_email': widget.currentUser.email,
          'p_reviewer_role': widget.currentUser.role.roleId,
        },
      );

      final isOk = response is Map && response['ok'] == true;
      final message = response is Map && response['message'] != null
          ? AppUi.userMessage(response['message'].toString())
          : isOk
              ? 'Review stock out marketplace tersimpan.'
              : 'Review gagal disimpan. Respons server belum sesuai.';

      if (!mounted) return;
      AppUi.safeSnack(context, message);
      if (!isOk) return;
      await _load(prepare: false);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Simpan review gagal: ${_cleanError(error)}')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebResponsiveScaffold(
      appBar: AppBar(
        title: const Text('Stok Keluar Monitor'),
        actions: [
          IconButton(
            onPressed: _isSaving ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Reload',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Cocokkan stok keluar manual atau marketplace dengan order, refund, cancel, dan return.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            _summaryChips(),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _filterStatus,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Status Review',
                border: OutlineInputBorder(),
              ),
              items: _statuses
                  .map((item) => DropdownMenuItem<String>(
                        value: item.key,
                        child: Text(item.value),
                      ))
                  .toList(),
              onChanged: _isSaving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _filterStatus = value);
                      _load(prepare: false);
                    },
            ),
            const SizedBox(height: 14),
            if (_errorMessage != null) _errorBox(_errorMessage!),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_items.isEmpty)
              _emptyBox('Belum ada stock out marketplace yang perlu direview.')
            else
              ..._items.map(_card),
          ],
        ),
      ),
    );
  }

  Widget _summaryChips() {
    final pending =
        _items.where((item) => item.reviewStatus == 'pending').length;
    final risk = _items.where((item) => item.isHighRisk).length;
    final matched =
        _items.where((item) => item.reviewStatus == 'matched').length;
    final action =
        _items.where((item) => item.reviewStatus == 'needs_action').length;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _statChip('Pending', pending.toString(), Icons.pending_actions_rounded),
        _statChip('Risk', risk.toString(), Icons.warning_amber_rounded),
        _statChip('Matched', matched.toString(), Icons.verified_rounded),
        _statChip('Aksi', action.toString(), Icons.report_problem_outlined),
      ],
    );
  }

  Widget _card(_StockOutReviewItem item) {
    final color = _statusColor(item.reviewStatus, item.isHighRisk);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NiceCard(
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      item.externalOrderId == '-'
                          ? item.trackingNumber
                          : item.externalOrderId,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  _badge(_reviewLabel(item.reviewStatus), color),
                ],
              ),
              const SizedBox(height: 8),
              Text('${item.marketplace} · ${item.accountName}'),
              const SizedBox(height: 4),
              Text('Resi: ${item.trackingNumber}'),
              const SizedBox(height: 4),
              Text('Status order: ${item.marketplaceOrderStatus}'),
              const SizedBox(height: 4),
              Text(
                  'Stok keluar: ${item.stockOutAtText} · User: ${item.createdByName} (${item.createdByRole})'),
              const Divider(height: 18),
              Text('${item.localSku} · ${item.productName}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('Qty keluar: ${item.qtyText} · Tujuan: ${item.tujuan}'),
              const SizedBox(height: 8),
              _riskBox(item),
              if ((item.reviewNote ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Catatan review: ${item.reviewNote}'),
              ],
              if (item.reviewedAtText != '-') ...[
                const SizedBox(height: 4),
                Text(
                    'Reviewed: ${item.reviewedAtText} · ${item.reviewedByName ?? '-'}'),
              ],
              if (item.reviewStatus == 'pending') ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _isSaving
                          ? null
                          : () => _submitReview(
                                item: item,
                                status: 'matched',
                                title: 'Tandai stock out sesuai order',
                                confirmLabel: 'Matched',
                              ),
                      icon: const Icon(Icons.verified_outlined),
                      label: const Text('Matched'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isSaving
                          ? null
                          : () => _submitReview(
                                item: item,
                                status: 'needs_action',
                                title: 'Butuh tindakan lanjut',
                                confirmLabel: 'Perlu Tindak Lanjut',
                              ),
                      icon: const Icon(Icons.report_problem_outlined),
                      label: const Text('Perlu Tindak Lanjut'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isSaving
                          ? null
                          : () => _submitReview(
                                item: item,
                                status: 'ignored',
                                title: 'Abaikan review ini',
                                confirmLabel: 'Ignore',
                              ),
                      icon: const Icon(Icons.visibility_off_outlined),
                      label: const Text('Ignore'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _riskBox(_StockOutReviewItem item) {
    final color = item.isHighRisk
        ? Colors.red.shade700
        : Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withOpacity(0.10),
        border: Border.all(color: color.withOpacity(0.22), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_riskLabel(item.riskFlag),
              style: TextStyle(color: color, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(item.riskMessage),
          if (item.hasBatalRequest ||
              item.cancelRequestStatus != '-' ||
              item.returnCaseStatus != '-') ...[
            const SizedBox(height: 4),
            Text(
                'Batal: ${item.cancelRequestStatus} · Return: ${item.returnCaseStatus}'),
          ],
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.65),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(value),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }

  Widget _errorBox(String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.errorContainer,
      ),
      child: Text(text,
          style:
              TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
    );
  }

  Widget _emptyBox(String text) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(
                Theme.of(context).brightness == Brightness.dark ? 0.28 : 0.44,
              ),
          width: 0.8,
        ),
      ),
      child: Text(text),
    );
  }

  Color _statusColor(String status, bool isHighRisk) {
    if (isHighRisk && status == 'pending') return Colors.red.shade700;
    switch (status) {
      case 'matched':
      case 'resolved':
        return Colors.green.shade700;
      case 'needs_action':
        return Colors.orange.shade800;
      case 'ignored':
        return Theme.of(context).colorScheme.onSurfaceVariant;
      case 'pending':
        return Theme.of(context).colorScheme.primary;
      default:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }

  String _reviewLabel(String status) {
    switch (status) {
      case 'matched':
        return 'Matched';
      case 'needs_action':
        return 'Perlu Tindak Lanjut';
      case 'ignored':
        return 'Ignored';
      case 'resolved':
        return 'Resolved';
      case 'pending':
        return 'Pending';
      default:
        return status.replaceAll('_', ' ');
    }
  }

  String _riskLabel(String flag) {
    switch (flag) {
      case 'marketplace_refund_cancel_risk':
        return 'Refund / Batal Risk';
      case 'manual_stock_out_without_resi':
        return 'Manual Tanpa Resi';
      case 'manual_match_required':
        return 'Manual Match Required';
      default:
        return flag.replaceAll('_', ' ');
    }
  }

  String _cleanError(Object error) {
    var text = error.toString().trim();
    text = text.replaceFirst(RegExp(r'^Exception:\s*'), '');
    text = text.replaceFirst(RegExp(r'^PostgrestException\(message:\s*'), '');
    return text;
  }
}

class _StockOutReviewItem {
  final String reviewId;
  final String marketplace;
  final String accountName;
  final String externalOrderId;
  final String trackingNumber;
  final String marketplaceOrderStatus;
  final String cancelRequestStatus;
  final String returnCaseStatus;
  final bool hasBatalRequest;
  final String localSku;
  final String productName;
  final num qty;
  final String tujuan;
  final String reviewStatus;
  final String matchStatus;
  final String riskFlag;
  final String riskMessage;
  final String createdByName;
  final String createdByRole;
  final String? reviewedByName;
  final String? reviewedAt;
  final String? reviewNote;
  final String? stockOutAt;

  const _StockOutReviewItem({
    required this.reviewId,
    required this.marketplace,
    required this.accountName,
    required this.externalOrderId,
    required this.trackingNumber,
    required this.marketplaceOrderStatus,
    required this.cancelRequestStatus,
    required this.returnCaseStatus,
    required this.hasBatalRequest,
    required this.localSku,
    required this.productName,
    required this.qty,
    required this.tujuan,
    required this.reviewStatus,
    required this.matchStatus,
    required this.riskFlag,
    required this.riskMessage,
    required this.createdByName,
    required this.createdByRole,
    required this.reviewedByName,
    required this.reviewedAt,
    required this.reviewNote,
    required this.stockOutAt,
  });

  factory _StockOutReviewItem.fromMap(Map<String, dynamic> map) {
    return _StockOutReviewItem(
      reviewId: _text(map['review_id']),
      marketplace: _text(map['marketplace'], '-'),
      accountName: _text(map['account_name'], '-'),
      externalOrderId: _text(map['external_order_id'], '-'),
      trackingNumber: _text(map['tracking_number'], '-'),
      marketplaceOrderStatus: _text(map['marketplace_order_status'], '-'),
      cancelRequestStatus: _text(map['cancel_request_status'], '-'),
      returnCaseStatus: _text(map['return_case_status'], '-'),
      hasBatalRequest: map['has_cancel_request'] == true,
      localSku: _text(map['local_sku'], '-'),
      productName: _text(map['product_name'], '-'),
      qty: _num(map['qty']),
      tujuan: _text(map['tujuan'], '-'),
      reviewStatus: _text(map['review_status'], 'pending'),
      matchStatus: _text(map['match_status'], 'pending'),
      riskFlag: _text(map['risk_flag'], 'manual_match_required'),
      riskMessage: _text(map['risk_message'], '-'),
      createdByName: _text(map['created_by_name'], '-'),
      createdByRole: _text(map['created_by_role'], '-'),
      reviewedByName: map['reviewed_by_name']?.toString(),
      reviewedAt: map['reviewed_at']?.toString(),
      reviewNote: map['review_note']?.toString(),
      stockOutAt: map['stock_out_at']?.toString(),
    );
  }

  bool get isHighRisk =>
      riskFlag == 'marketplace_refund_cancel_risk' || hasBatalRequest;

  String get qtyText => _formatQty(qty);

  String get reviewedAtText => _formatDate(reviewedAt);

  String get stockOutAtText => _formatDate(stockOutAt);

  static String _text(dynamic value, [String fallback = '']) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return fallback;
    return text;
  }

  static num _num(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value;
    return num.tryParse(value.toString()) ?? 0;
  }

  static String _formatQty(num value) {
    if (value % 1 == 0) return value.toStringAsFixed(0);
    return value.toString();
  }

  static String _formatDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  }
}
