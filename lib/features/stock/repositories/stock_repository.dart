import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/stock_transaction_item.dart';

class StockOutRequestItem {
  final String productId;
  final double qty;

  const StockOutRequestItem({
    required this.productId,
    required this.qty,
  });

  Map<String, dynamic> toJson() {
    return {
      'product_id': productId,
      'qty': qty,
    };
  }
}

class StockRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<void> stockIn({
    required String productId,
    required double qty,
    required String sumber,
    required String? catatan,
  }) async {
    await _client.rpc(
      'register_stock_transaction',
      params: {
        'p_product_id': productId,
        'p_transaction_type': 'IN',
        'p_qty': qty,
        'p_sumber_tujuan': sumber,
        'p_catatan': catatan,
        'p_latitude': null,
        'p_longitude': null,
      },
    );
  }

  Future<void> stockOut({
    required String productId,
    required double qty,
    required String tujuan,
    required String? catatan,
    String? nomorResi,
  }) async {
    await stockOutBatch(
      nomorResi: nomorResi,
      tujuan: tujuan,
      catatan: catatan,
      items: [
        StockOutRequestItem(
          productId: productId,
          qty: qty,
        ),
      ],
    );
  }

  Future<void> stockOutBatch({
    required String? nomorResi,
    required String tujuan,
    required List<StockOutRequestItem> items,
    required String? catatan,
  }) async {
    await _client.rpc(
      'register_stock_out_batch',
      params: {
        'p_nomor_resi': nomorResi,
        'p_tujuan': tujuan,
        'p_items': items.map((item) => item.toJson()).toList(),
        'p_catatan': catatan,
      },
    );
  }

  Future<List<StockTransactionItem>> getRecentTransactions() async {
    final data = await _client.from('stock_transactions').select('''
      stock_transaction_id,
      transaction_type,
      qty,
      sumber_tujuan,
      nomor_resi,
      stock_before,
      stock_after,
      catatan,
      created_at,
      product:products(
        kode_sku,
        nama_barang
      ),
      user:users(
        nama,
        email,
        username
      )
    ''').order('created_at', ascending: false).limit(100);

    return (data as List)
        .map(
          (item) => StockTransactionItem.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }
}