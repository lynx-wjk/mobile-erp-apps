import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/product.dart';

class ProductRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<Product>> getProducts({
    String? search,
    bool activeOnly = false,
  }) async {
    dynamic query = _client.from('products').select('''
      product_id,
      kode_sku,
      kode_barcode,
      nama_barang,
      kategori,
      satuan,
      stock_awal,
      stock_saat_ini,
      low_stock_limit,
      lokasi_rak,
      status,
      created_at
    ''');

    if (activeOnly) {
      query = query.eq('status', 'active');
    }

    final keyword = search?.trim();

    if (keyword != null && keyword.isNotEmpty) {
      query = query.or(
        'kode_sku.ilike.%$keyword%,kode_barcode.ilike.%$keyword%,nama_barang.ilike.%$keyword%',
      );
    }

    final data = await query.order('created_at', ascending: false);

    return (data as List)
        .map((item) => Product.fromMap(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<Product?> getProductByQrValue(String qrValue) async {
    final value = qrValue.trim();

    if (value.isEmpty) return null;

    final data = await _client.from('products').select('''
          product_id,
          kode_sku,
          kode_barcode,
          nama_barang,
          kategori,
          satuan,
          stock_awal,
          stock_saat_ini,
          low_stock_limit,
          lokasi_rak,
          status
        ''').eq('kode_barcode', value).eq('status', 'active').maybeSingle();

    if (data == null) {
      return null;
    }

    return Product.fromMap(data);
  }

  Future<List<Product>> getLowStockProducts() async {
    final products = await getProducts(activeOnly: true);
    return products.where((product) => product.isLowStock).toList();
  }

  Future<void> createProduct({
    required String kodeSku,
    required String kodeBarcode,
    required String namaBarang,
    required String? kategori,
    required String satuan,
    required double stockAwal,
    required double lowStockLimit,
    required String? lokasiRak,
  }) async {
    await _client.from('products').insert({
      'kode_sku': kodeSku.trim(),
      'kode_barcode': kodeBarcode.trim(),
      'nama_barang': namaBarang.trim(),
      'kategori': kategori?.trim().isEmpty == true ? null : kategori?.trim(),
      'satuan': satuan.trim().isEmpty ? 'pcs' : satuan.trim(),
      'stock_awal': stockAwal,
      'stock_saat_ini': stockAwal,
      'low_stock_limit': lowStockLimit,
      'lokasi_rak':
          lokasiRak?.trim().isEmpty == true ? null : lokasiRak?.trim(),
      'status': 'active',
    });
  }

  Future<void> updateProduct({
    required String productId,
    required String kodeSku,
    required String kodeBarcode,
    required String namaBarang,
    required String? kategori,
    required String satuan,
    required double lowStockLimit,
    required String? lokasiRak,
    required String status,
  }) async {
    await _client.from('products').update({
      'kode_sku': kodeSku.trim(),
      'kode_barcode': kodeBarcode.trim(),
      'nama_barang': namaBarang.trim(),
      'kategori': kategori?.trim().isEmpty == true ? null : kategori?.trim(),
      'satuan': satuan.trim().isEmpty ? 'pcs' : satuan.trim(),
      'low_stock_limit': lowStockLimit,
      'lokasi_rak':
          lokasiRak?.trim().isEmpty == true ? null : lokasiRak?.trim(),
      'status': status,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('product_id', productId);
  }
}
