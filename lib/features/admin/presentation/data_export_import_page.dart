import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/app_roles.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/utils/file_download.dart';

class DataExportImportPage extends StatefulWidget {
  const DataExportImportPage({super.key});

  @override
  State<DataExportImportPage> createState() => _DataExportImportPageState();
}

class _DataExportImportPageState extends State<DataExportImportPage> {
  final SupabaseClient _client = Supabase.instance.client;

  bool _busy = false;
  String _log = 'Siap. Export data XLSX atau import update SKU/stock.';
  String _roleId = '';
  String? _tenantId;

  static const List<String> _tablesToExport = [
    'roles',
    'users',
    'products',
    'stock_transactions',
    'suppliers',
    'purchases',
    'purchase_items',
    'purchase_receipts',
    'finance_verifications',
    'production_progress',
    'attendance',
    'attendance_logs',
    'tasks',
    'task_comments',
    'live_schedules',
    'live_proofs',
    'live_verifications',
    'host_live_sessions',
    'content_tasks',
    'content_proofs',
    'content_task',
    'work_locations',
    'module_records',
    'photo_evidences',
    'audit_logs',
  ];

  static const List<String> _financeTables = [
    // Internal finance data.
    'purchases',
    'purchase_items',
    'purchase_receipts',
    'finance_verifications',
    'finance_operational_expenses',
    'finance_sku_margin_settings',
    'suppliers',

    // Marketplace finance/report data used by Laporan Keuangan.
    'marketplace_accounts',
    'marketplace_finance_reports',
    'marketplace_finance_items',
    'marketplace_finance_reconciliations',
    'marketplace_orders',
    'marketplace_order_items',
    'marketplace_sku_maps',
    'marketplace_return_refund_cases',
    'marketplace_return_reviews',
    'marketplace_return_item_reviews',
    'marketplace_closing_books',
    'marketplace_closing_book_files',
  ];

  static const Set<String> _globalStaticExportTables = {
    'roles',
  };

  static const Set<String> _tenantScopedExportTables = {
    'users',
    'products',
    'stock_transactions',
    'suppliers',
    'purchases',
    'purchase_items',
    'purchase_receipts',
    'finance_verifications',
    'production_progress',
    'attendance',
    'attendance_logs',
    'tasks',
    'task_comments',
    'live_schedules',
    'live_proofs',
    'live_verifications',
    'host_live_sessions',
    'content_tasks',
    'content_proofs',
    'content_task',
    'work_locations',
    'module_records',
    'photo_evidences',
    'audit_logs',
    'finance_operational_expenses',
    'finance_sku_margin_settings',
    'marketplace_accounts',
    'marketplace_finance_reports',
    'marketplace_finance_items',
    'marketplace_finance_reconciliations',
    'marketplace_orders',
    'marketplace_order_items',
    'marketplace_sku_maps',
    'marketplace_return_refund_cases',
    'marketplace_return_reviews',
    'marketplace_return_item_reviews',
    'marketplace_closing_books',
    'marketplace_closing_book_files',
  };

  static const Set<String> _redactedExportColumns = {
    'access_token',
    'refresh_token',
    'access_token_encrypted',
    'refresh_token_encrypted',
    'token_encrypted',
    'app_secret',
    'client_secret',
    'partner_key',
    'secret_key',
    'service_role_key',
    'anon_key',
    'api_key',
    'authorization',
    'password',
    'encrypted_password',
    'raw_shop_response',
    'request_headers',
    'response_headers',
  };

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  bool _isSuperRole(String roleId) {
    return AppRolePermissions.isSuperRoleId(roleId);
  }

  bool _isFinanceRole(String roleId) {
    final role = roleId.toLowerCase().trim().replaceAll(' ', '_');
    return role == 'finance';
  }

  Future<void> _loadRole() async {
    try {
      final authUser = _client.auth.currentUser;
      if (authUser == null) return;

      final user = await _client
          .from('users')
          .select('role_id, tenant_id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      if (!mounted) return;
      setState(() {
        _roleId = user?['role_id']?.toString() ?? '';
        _tenantId = user?['tenant_id']?.toString();
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _roleId = '';
          _tenantId = null;
        });
      }
    }
  }

  Future<void> _guardSuperAdmin() async {
    if (!_isSuperRole(_roleId)) {
      await _loadRole();
    }

    if (!_isSuperRole(_roleId)) {
      throw Exception('Fitur ini khusus Super Admin / Owner.');
    }
  }

  Future<void> _guardFinanceOrSuper() async {
    if (_roleId.isEmpty) await _loadRole();

    if (!_isSuperRole(_roleId) && !_isFinanceRole(_roleId)) {
      throw Exception('Download finance hanya untuk Finance dan Super Admin.');
    }
  }

  String _requireTenantIdForDataAction(String action) {
    final tenantId = _tenantId?.trim() ?? '';
    if (tenantId.isEmpty) {
      throw Exception('Tenant aktif tidak terbaca. $action dibatalkan.');
    }
    return tenantId;
  }

  CellValue _cell(dynamic value) {
    if (value == null) return TextCellValue('');
    if (value is DateTime) return TextCellValue(value.toIso8601String());
    return TextCellValue(value.toString());
  }

  String _cellText(Data? cell) {
    final value = cell?.value;
    if (value == null) return '';
    return value.toString().trim();
  }

  String _normalizeProductStatus(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return '';
    if (value == 'aktif' || value == 'active') return 'active';
    if (value == 'nonaktif' || value == 'non-active' || value == 'inactive') {
      return 'inactive';
    }
    return value;
  }

  num? _parseNumber(String raw) {
    var cleaned = raw.trim().replaceAll('Rp', '').replaceAll(' ', '');
    if (cleaned.isEmpty) return null;

    cleaned = cleaned.replaceAll(RegExp(r'[^0-9,.-]'), '');
    if (cleaned.isEmpty || cleaned == '-' || cleaned == ',' || cleaned == '.') {
      return null;
    }

    if (cleaned.contains(',') && cleaned.contains('.')) {
      cleaned = cleaned.lastIndexOf(',') > cleaned.lastIndexOf('.')
          ? cleaned.replaceAll('.', '').replaceAll(',', '.')
          : cleaned.replaceAll(',', '');
    } else if (RegExp(r'^-?\d{1,3}(\.\d{3})+$').hasMatch(cleaned)) {
      cleaned = cleaned.replaceAll('.', '');
    } else if (RegExp(r'^-?\d{1,3}(,\d{3})+$').hasMatch(cleaned)) {
      cleaned = cleaned.replaceAll(',', '');
    } else {
      cleaned = cleaned.replaceAll(',', '.');
    }

    return num.tryParse(cleaned);
  }

  Future<void> _shareWorkbook(
    Excel workbook,
    String fileName, {
    required String subject,
    required String text,
  }) async {
    final bytes = workbook.save();
    if (bytes == null) throw Exception('Gagal membuat file XLSX');
    final data = Uint8List.fromList(bytes);
    const mimeType =
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

    final downloaded = await downloadBytesAsFile(
      bytes: data,
      fileName: fileName,
      mimeType: mimeType,
    );
    if (downloaded) {
      if (mounted) {
        setState(() => _log = 'Download dimulai: $fileName');
        AppUi.safeSnack(context, 'Download dimulai: $fileName');
      }
      return;
    }

    await Share.shareXFiles(
      [
        XFile.fromData(
          data,
          name: fileName,
          mimeType: mimeType,
        ),
      ],
      subject: subject,
      text: text,
    );
  }

  void _appendMapSheet(
    Excel workbook,
    String sheetName,
    List<Map<String, dynamic>> rows,
  ) {
    final cleanName =
        sheetName.length > 31 ? sheetName.substring(0, 31) : sheetName;
    final sheet = workbook[cleanName];

    final headers = <String>[];
    for (final row in rows) {
      for (final key in row.keys) {
        if (!headers.contains(key)) headers.add(key);
      }
    }

    if (headers.isEmpty) {
      sheet.appendRow(<CellValue>[TextCellValue('empty')]);
      return;
    }

    sheet.appendRow(headers.map<CellValue>((h) => TextCellValue(h)).toList());
    for (final row in rows) {
      sheet.appendRow(headers.map<CellValue>((h) => _cell(row[h])).toList());
    }
  }

  bool get _isPlatformOwner => AppRolePermissions.isPlatformOwnerId(_roleId);

  bool _isKnownExportTable(String table) {
    return _globalStaticExportTables.contains(table) ||
        _tenantScopedExportTables.contains(table);
  }

  bool _needsTenantFilter(String table) {
    if (_isPlatformOwner) return false;
    return _tenantScopedExportTables.contains(table);
  }

  void _assertExportAllowed(String table) {
    if (!_isKnownExportTable(table)) {
      throw Exception(
          'Table "$table" belum dikonfigurasi sebagai export aman.');
    }

    if (_needsTenantFilter(table) &&
        (_tenantId == null || _tenantId!.isEmpty)) {
      throw Exception(
          'Tenant aktif tidak terbaca. Export "$table" dibatalkan.');
    }
  }

  Map<String, dynamic> _redactExportRow(Map<String, dynamic> row) {
    final out = <String, dynamic>{};
    for (final entry in row.entries) {
      final key = entry.key;
      final lowerKey = key.toLowerCase().trim();
      final shouldRedact = _redactedExportColumns.contains(lowerKey) ||
          lowerKey.contains('access_token') ||
          lowerKey.contains('refresh_token') ||
          lowerKey.contains('secret') ||
          lowerKey.contains('password') ||
          lowerKey.contains('encrypted');

      out[key] = shouldRedact ? '[REDACTED]' : entry.value;
    }
    return out;
  }

  Future<void> _exportTables({
    required List<String> tables,
    required String filePrefix,
    required String subject,
  }) async {
    final workbook = Excel.createExcel();
    final errors = <Map<String, dynamic>>[];

    for (final table in tables) {
      try {
        _assertExportAllowed(table);

        dynamic query = _client.from(table).select('*');
        if (_needsTenantFilter(table)) {
          query = query.eq('tenant_id', _tenantId!);
        }

        final response = await query.limit(50000);
        final rows = (response as List)
            .map((e) => _redactExportRow(Map<String, dynamic>.from(e)))
            .toList();
        _appendMapSheet(workbook, table, rows);
      } catch (error) {
        errors.add({'table': table, 'error': error.toString()});
      }
    }

    if (errors.isNotEmpty) _appendMapSheet(workbook, 'EXPORT_ERRORS', errors);

    final defaultSheet = workbook.getDefaultSheet();
    if (defaultSheet != null && workbook.tables.length > 1) {
      workbook.delete(defaultSheet);
    }

    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final fileName = '${filePrefix}_$stamp.xlsx';
    await _shareWorkbook(
      workbook,
      fileName,
      subject: subject,
      text: 'File export berhasil dibuat.',
    );

    setState(() => _log = 'Berhasil export: $fileName');
  }

  Future<void> _exportAllData() async {
    setState(() {
      _busy = true;
      _log = 'Export semua data berjalan...';
    });

    try {
      await _guardSuperAdmin();
      await _exportTables(
        tables: _tablesToExport,
        filePrefix: 'stock_role_all_data',
        subject: 'Export semua data Stock Role App',
      );
    } catch (error) {
      setState(() => _log = 'Gagal export: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportFinanceData() async {
    setState(() {
      _busy = true;
      _log = 'Export data finance dan marketplace tenant berjalan...';
    });

    try {
      await _guardFinanceOrSuper();
      await _exportTables(
        tables: _financeTables,
        filePrefix: 'stock_role_finance_marketplace_data',
        subject: 'Export data finance dan marketplace Stock Role App',
      );
    } catch (error) {
      setState(() => _log = 'Gagal export finance: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportProductTemplate() async {
    setState(() {
      _busy = true;
      _log = 'Membuat template update SKU/stock...';
    });

    try {
      await _guardSuperAdmin();
      final tenantId = _requireTenantIdForDataAction('Export template produk');

      final response = await _client
          .from('products')
          .select(
            'product_id, nama_barang, kode_sku, kode_barcode, kategori, satuan, harga_hpp_default, stock_saat_ini, low_stock_limit, lokasi_rak, status',
          )
          .eq('tenant_id', tenantId)
          .order('nama_barang');

      final rows =
          (response as List).map((e) => Map<String, dynamic>.from(e)).toList();

      final workbook = Excel.createExcel();
      final sheet = workbook['UPDATE_SKU_STOCK'];
      const headers = [
        'product_id',
        'nama_barang',
        'kode_sku',
        'kode_barcode',
        'kategori',
        'satuan',
        'harga_hpp_default',
        'stock_saat_ini',
        'low_stock_limit',
        'lokasi_rak',
        'status',
      ];

      sheet.appendRow(headers.map<CellValue>((h) => TextCellValue(h)).toList());
      for (final row in rows) {
        sheet.appendRow(headers.map<CellValue>((h) => _cell(row[h])).toList());
      }

      final readme = workbook['README'];
      readme.appendRow(<CellValue>[TextCellValue('Cara pakai')]);
      readme.appendRow(
          <CellValue>[TextCellValue('Edit sheet UPDATE_SKU_STOCK saja.')]);
      readme.appendRow(<CellValue>[
        TextCellValue(
            'Jangan menambah kolom qr_code_value karena generated column.')
      ]);
      readme.appendRow(<CellValue>[
        TextCellValue('Isi stock_saat_ini untuk update stock massal.')
      ]);
      readme.appendRow(<CellValue>[
        TextCellValue('Kosongkan product_id untuk tambah produk baru.')
      ]);
      readme.appendRow(<CellValue>[
        TextCellValue(
            'Jika product_id kosong tapi barcode sudah ada, data lama direplace.')
      ]);

      final defaultSheet = workbook.getDefaultSheet();
      if (defaultSheet != null && workbook.tables.length > 1) {
        workbook.delete(defaultSheet);
      }

      const fileName = 'template_update_sku_stock.xlsx';
      await _shareWorkbook(
        workbook,
        fileName,
        subject: 'Template update SKU dan stock',
        text: 'Edit file ini lalu import kembali dari menu Super Admin.',
      );

      setState(() => _log = 'Template berhasil dibuat: $fileName');
    } catch (error) {
      setState(() => _log = 'Gagal membuat template: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List?> _pickXlsxBytes() async {
    final file = await fs.openFile(
      acceptedTypeGroups: const [
        fs.XTypeGroup(
          label: 'Excel XLSX',
          extensions: ['xlsx'],
          mimeTypes: [
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ],
        ),
      ],
    );

    if (file == null) return null;
    return file.readAsBytes();
  }

  String _normalizeHeader(String value) {
    final cleaned = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-/]+'), '_')
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '')
        .replaceAll(RegExp(r'_+'), '_');
    return cleaned.replaceAll(RegExp(r'^_|_$'), '');
  }

  Future<void> _importProductUpdate() async {
    setState(() {
      _busy = true;
      _log = 'Membuka file XLSX...';
    });

    try {
      await _guardSuperAdmin();
      final tenantId = _requireTenantIdForDataAction('Import produk');

      final bytes = await _pickXlsxBytes();
      if (bytes == null) {
        setState(() => _log = 'Import dibatalkan. Tidak ada file dipilih.');
        return;
      }

      final workbook = Excel.decodeBytes(bytes);
      final sheet =
          workbook.tables['UPDATE_SKU_STOCK'] ?? workbook.tables.values.first;
      if (sheet.rows.isEmpty) throw Exception('Sheet kosong');

      final headers = sheet.rows.first
          .map((cell) => _normalizeHeader(_cellText(cell)))
          .toList();
      int indexOf(List<String> names) {
        final normalized = names.map(_normalizeHeader).toSet();
        return headers.indexWhere(normalized.contains);
      }

      final productIdIndex = indexOf(['product_id', 'id']);
      final skuIndex = indexOf(['kode_sku', 'sku', 'local_sku']);
      final barcodeIndex = indexOf(['kode_barcode', 'barcode']);
      final nameIndex =
          indexOf(['nama_barang', 'nama_produk', 'produk', 'product_name']);
      final categoryIndex = indexOf(['kategori', 'category']);
      final unitIndex = indexOf(['satuan', 'unit']);
      final stockIndex =
          indexOf(['stock_saat_ini', 'stok_saat_ini', 'stock', 'stok']);
      final lowStockIndex =
          indexOf(['low_stock_limit', 'min_stock', 'limit_stok']);
      final hppIndex = indexOf(['harga_hpp_default', 'harga_hpp', 'hpp']);
      final marginIndex =
          indexOf(['target_margin_percent', 'margin_target', 'target_margin']);
      final locationIndex = indexOf(['lokasi_rak', 'lokasi', 'rak']);
      final statusIndex = indexOf(['status']);

      final forbiddenHeaders = {
        'marketplace',
        'marketplace_sku',
        'marketplace_sku_id',
        'seller_sku',
        'remote_sku',
        'order_id',
        'resi',
        'payout',
        'gross',
        'statement_id',
      };
      final looksLikeMarketplaceMapping =
          headers.any(forbiddenHeaders.contains);
      if (looksLikeMarketplaceMapping) {
        throw Exception(
            'File ini bukan template Update SKU / Stock. Import produk lokal hanya menerima template UPDATE_SKU_STOCK dari menu Backup Data. Template mapping/HPP marketplace tidak boleh dipakai di sini.');
      }
      if (barcodeIndex < 0) {
        throw Exception('Kolom kode_barcode wajib ada.');
      }
      if (nameIndex < 0 && productIdIndex < 0 && barcodeIndex < 0) {
        throw Exception(
            'Template tidak valid. Minimal harus ada nama_barang dan kode_barcode.');
      }

      String valueAt(List<Data?> row, int index) {
        if (index < 0 || index >= row.length) return '';
        return _cellText(row[index]).trim();
      }

      int inserted = 0;
      int updated = 0;
      int skipped = 0;
      final errors = <String>[];
      final notes = <String>[];

      Future<Map<String, dynamic>?> findProduct(
          String column, String value) async {
        final trimmed = value.trim();
        if (trimmed.isEmpty) return null;
        final found = await _client
            .from('products')
            .select('product_id,kode_sku,kode_barcode')
            .eq('tenant_id', tenantId)
            .eq(column, trimmed)
            .maybeSingle();
        return found == null ? null : Map<String, dynamic>.from(found);
      }

      Future<void> updateByProductId(
          String productId, Map<String, dynamic> payload) async {
        await _client
            .from('products')
            .update(payload)
            .eq('tenant_id', tenantId)
            .eq('product_id', productId);
      }

      for (int rowIndex = 1; rowIndex < sheet.rows.length; rowIndex++) {
        final row = sheet.rows[rowIndex];
        final productId = valueAt(row, productIdIndex);
        final inputSku = valueAt(row, skuIndex);
        final inputBarcode = valueAt(row, barcodeIndex);
        final name = valueAt(row, nameIndex);
        final category = valueAt(row, categoryIndex);
        final unit = valueAt(row, unitIndex);
        final location = valueAt(row, locationIndex);
        final rawStatus = valueAt(row, statusIndex);
        final status = _normalizeProductStatus(rawStatus);
        final stock = _parseNumber(valueAt(row, stockIndex));
        final lowStock = _parseNumber(valueAt(row, lowStockIndex));
        final hpp = _parseNumber(valueAt(row, hppIndex));
        final margin = _parseNumber(valueAt(row, marginIndex));

        if (productId.isEmpty &&
            inputSku.isEmpty &&
            inputBarcode.isEmpty &&
            name.isEmpty) {
          skipped++;
          continue;
        }
        if (productId.isEmpty && inputBarcode.isEmpty) {
          skipped++;
          errors.add('Baris ${rowIndex + 1}: kode_barcode wajib diisi');
          continue;
        }

        final update = <String, dynamic>{};
        if (inputSku.isNotEmpty) update['kode_sku'] = inputSku;
        if (inputBarcode.isNotEmpty) update['kode_barcode'] = inputBarcode;
        if (name.isNotEmpty) update['nama_barang'] = name;
        if (category.isNotEmpty) update['kategori'] = category;
        if (unit.isNotEmpty) update['satuan'] = unit;
        if (location.isNotEmpty) update['lokasi_rak'] = location;
        if (status.isNotEmpty) update['status'] = status;
        if (stock != null) update['stock_saat_ini'] = stock;
        if (lowStock != null) update['low_stock_limit'] = lowStock;
        if (hpp != null) update['harga_hpp_default'] = hpp;
        if (margin != null) update['target_margin_percent'] = margin;
        update['updated_at'] = DateTime.now().toIso8601String();

        Map<String, dynamic>? existing;
        try {
          existing = productId.isNotEmpty
              ? await findProduct('product_id', productId)
              : null;
          existing ??= inputBarcode.isNotEmpty
              ? await findProduct('kode_barcode', inputBarcode)
              : null;

          if (existing != null) {
            if (update.length == 1) {
              skipped++;
              continue;
            }
            final id = '${existing['product_id']}';
            try {
              await updateByProductId(id, update);
            } on PostgrestException catch (error) {
              if (error.code == '23505' && update.containsKey('kode_barcode')) {
                errors.add(
                    'Baris ${rowIndex + 1}: kode_barcode "$inputBarcode" sudah dipakai produk lain.');
                skipped++;
                continue;
              } else {
                rethrow;
              }
            }
            updated++;
          } else {
            if (inputBarcode.isEmpty || name.isEmpty) {
              skipped++;
              errors.add(
                  'Baris ${rowIndex + 1}: produk baru wajib punya kode_barcode dan nama_barang');
              continue;
            }
            final insert = <String, dynamic>{
              'tenant_id': tenantId,
              'kode_sku': inputSku.isNotEmpty ? inputSku : inputBarcode,
              'kode_barcode': inputBarcode,
              'nama_barang': name,
              'kategori': category.isNotEmpty ? category : '-',
              'satuan': unit.isNotEmpty ? unit : 'pcs',
              'stock_saat_ini': stock ?? 0,
              'low_stock_limit': lowStock ?? 0,
              'harga_hpp_default': hpp ?? 0,
              'target_margin_percent': margin ?? 0,
              'lokasi_rak': location,
              'status': status.isNotEmpty ? status : 'active',
              'created_at': DateTime.now().toIso8601String(),
              'updated_at': DateTime.now().toIso8601String(),
            };
            try {
              await _client.from('products').insert(insert);
              inserted++;
            } on PostgrestException catch (error) {
              if (error.code == '23505') {
                final fallback =
                    await findProduct('kode_barcode', inputBarcode);
                if (fallback != null) {
                  final retry = Map<String, dynamic>.from(update);
                  if (retry.length > 1) {
                    await updateByProductId('${fallback['product_id']}', retry);
                    updated++;
                    continue;
                  }
                }
              }
              rethrow;
            }
          }
        } on PostgrestException catch (error) {
          skipped++;
          errors.add('Baris ${rowIndex + 1}: ${error.message}');
        } catch (error) {
          skipped++;
          errors.add('Baris ${rowIndex + 1}: $error');
        }
      }

      final summary =
          'Import selesai. Produk baru: $inserted, update: $updated, skip: $skipped, error: ${errors.length}.';
      final detail = [
        ...notes,
        ...errors.take(10),
      ].join('\n');
      setState(() {
        _log = detail.isEmpty ? summary : '$summary\n$detail';
      });
    } catch (error) {
      setState(() => _log = 'Gagal import: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _actionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return NiceCard(
      onTap: _busy ? null : onTap,
      child: Row(
        children: [
          CircleAvatar(child: Icon(icon)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text(subtitle),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSuper = _isSuperRole(_roleId);
    final isFinance = _isFinanceRole(_roleId);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup Data'),
        actions: [
          IconButton(
              onPressed: _busy ? null : _loadRole,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FuturisticHeader(
            icon: Icons.table_view_outlined,
            title: 'Export & Bulk Update',
            subtitle: isFinance && !isSuper
                ? 'Finance bisa download data keuangan dan seluruh marketplace yang masuk laporan.'
                : 'Super Admin bisa export semua data dan import update SKU/stock massal.',
            stats: [
              const StatPill(label: 'Format', value: 'XLSX'),
              StatPill(label: 'Role', value: _roleId.isEmpty ? '-' : _roleId),
            ],
          ),
          const SizedBox(height: 14),
          if (isSuper)
            _actionCard(
              icon: Icons.download_outlined,
              title: 'Download Semua Data',
              subtitle:
                  'Export semua tabel utama ke satu file XLSX multi sheet.',
              onTap: _exportAllData,
            ),
          if (isSuper || isFinance)
            _actionCard(
              icon: Icons.payments_outlined,
              title: 'Download Data Finance + Marketplace',
              subtitle:
                  'Export pembelian, biaya, laporan marketplace, order, item, mapping SKU, retur/refund, dan abnormal.',
              onTap: _exportFinanceData,
            ),
          if (isSuper)
            _actionCard(
              icon: Icons.inventory_2_outlined,
              title: 'Download Template Update SKU / Stock',
              subtitle:
                  'Template aman tanpa qr_code_value, karena kolom itu generated.',
              onTap: _exportProductTemplate,
            ),
          if (isSuper)
            _actionCard(
              icon: Icons.upload_file_outlined,
              title: 'Import Update SKU / Stock',
              subtitle:
                  'Upload XLSX dari template untuk update master SKU dan stock massal.',
              onTap: _importProductUpdate,
            ),
          if (!isSuper && !isFinance)
            const EmptyState(
              title: 'Akses dibatasi',
              subtitle: 'Menu ini hanya berguna untuk Super Admin dan Finance.',
            ),
          const SizedBox(height: 14),
          NiceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (_busy)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    if (_busy) const SizedBox(width: 10),
                    const Text('Log',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(_log),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
