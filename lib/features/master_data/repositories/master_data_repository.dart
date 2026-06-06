import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/supplier.dart';
import '../models/work_location.dart';

class MasterDataRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<Supplier>> getSuppliers() async {
    final data = await _client.rpc('list_suppliers');

    return (data as List)
        .map(
          (item) => Supplier.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }

  Future<void> upsertSupplier({
    required String? supplierId,
    required String namaSupplier,
    required String? kontakPerson,
    required String? nomorHp,
    required String? alamat,
    required String? jenisBarang,
    required String? catatan,
    required String status,
  }) async {
    await _client.rpc(
      'upsert_supplier',
      params: {
        'p_supplier_id': supplierId,
        'p_nama_supplier': namaSupplier,
        'p_kontak_person': kontakPerson,
        'p_nomor_hp': nomorHp,
        'p_alamat': alamat,
        'p_jenis_barang': jenisBarang,
        'p_catatan': catatan,
        'p_status': status,
      },
    );
  }

  Future<List<WorkLocation>> getWorkLocations() async {
    final data = await _client.rpc('list_work_locations');

    return (data as List)
        .map(
          (item) => WorkLocation.fromMap(
        Map<String, dynamic>.from(item),
      ),
    )
        .toList();
  }

  Future<void> upsertWorkLocation({
    required String? locationId,
    required String namaLokasi,
    required double latitude,
    required double longitude,
    required double radiusMeter,
    required String? alamat,
    required String? catatan,
    required String status,
  }) async {
    await _client.rpc(
      'upsert_work_location',
      params: {
        'p_location_id': locationId,
        'p_nama_lokasi': namaLokasi,
        'p_latitude': latitude,
        'p_longitude': longitude,
        'p_radius_meter': radiusMeter,
        'p_alamat': alamat,
        'p_catatan': catatan,
        'p_status': status,
      },
    );
  }
}