import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class HistoricalImportParseResult {
  final String fileName;
  final String sourceLabel;
  final List<String> headers;
  final List<Map<String, String>> rawRows;
  final List<Map<String, dynamic>> uploadRows;
  final int validRows;
  final int cancelledRows;
  final double grossTotal;
  final double validGrossTotal;

  const HistoricalImportParseResult({
    required this.fileName,
    required this.sourceLabel,
    required this.headers,
    required this.rawRows,
    required this.uploadRows,
    required this.validRows,
    required this.cancelledRows,
    required this.grossTotal,
    required this.validGrossTotal,
  });

  int get totalRows => rawRows.length;
  bool get isEmpty => rawRows.isEmpty;
}

class HistoricalImportUploadResult {
  final String batchId;
  final int totalRows;
  final int uploadedRows;

  const HistoricalImportUploadResult({
    required this.batchId,
    required this.totalRows,
    required this.uploadedRows,
  });
}

class MarketplaceHistoricalImportService {
  final SupabaseClient _client;

  MarketplaceHistoricalImportService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  Future<HistoricalImportParseResult?> pickAndParseOrderExport({
    required String marketplace,
  }) async {
    final picked = await _pickFile();
    if (picked == null) return null;
    return _parseBytes(
      bytes: picked.bytes,
      fileName: picked.name,
      sourceLabel: 'order_export',
      normalizer: (row) => _normalizeOrderRow(row, marketplace),
    );
  }

  Future<HistoricalImportParseResult?> pickAndParseIncomeExport({
    required String marketplace,
  }) async {
    final picked = await _pickFile();
    if (picked == null) return null;
    return _parseBytes(
      bytes: picked.bytes,
      fileName: picked.name,
      sourceLabel: 'finance_income_export',
      normalizer: (row) => _normalizeIncomeRow(row, marketplace),
    );
  }

  Future<HistoricalImportUploadResult> uploadOrderExport({
    required String marketplaceAccountId,
    required String marketplace,
    required HistoricalImportParseResult parsed,
  }) async {
    final batchId = await _client.rpc(
      'marketplace_create_order_export_import_batch',
      params: {
        'p_marketplace_account_id': marketplaceAccountId,
        'p_marketplace': marketplace,
        'p_source_type': 'order_export',
        'p_original_filename': parsed.fileName,
        'p_total_rows': parsed.totalRows,
        'p_valid_rows': parsed.validRows,
        'p_cancelled_rows': parsed.cancelledRows,
        'p_gross_total': parsed.grossTotal,
        'p_valid_gross_total': parsed.validGrossTotal,
      },
    );

    final id = batchId.toString();
    var uploaded = 0;
    for (final chunk in _chunks(parsed.uploadRows, 500)) {
      await _client.rpc(
        'marketplace_append_order_export_import_rows',
        params: {
          'p_batch_id': id,
          'p_rows': chunk,
        },
      );
      uploaded += chunk.length;
    }

    return HistoricalImportUploadResult(
      batchId: id,
      totalRows: parsed.totalRows,
      uploadedRows: uploaded,
    );
  }

  Future<HistoricalImportUploadResult> uploadIncomeExport({
    required String marketplaceAccountId,
    required String marketplace,
    required HistoricalImportParseResult parsed,
  }) async {
    final batchId = await _client.rpc(
      'marketplace_create_finance_income_import_batch',
      params: {
        'p_marketplace_account_id': marketplaceAccountId,
        'p_marketplace': marketplace,
        'p_source_type': 'finance_income_export',
        'p_original_filename': parsed.fileName,
        'p_total_rows': parsed.totalRows,
        'p_payout_total': parsed.validGrossTotal,
        'p_fee_total': 0,
        'p_adjustment_total': 0,
      },
    );

    final id = batchId.toString();
    var uploaded = 0;
    for (final chunk in _chunks(parsed.uploadRows, 500)) {
      await _client.rpc(
        'marketplace_append_finance_income_import_rows',
        params: {
          'p_batch_id': id,
          'p_rows': chunk,
        },
      );
      uploaded += chunk.length;
    }

    return HistoricalImportUploadResult(
      batchId: id,
      totalRows: parsed.totalRows,
      uploadedRows: uploaded,
    );
  }

  Future<Map<String, dynamic>> fetchValidationSnapshot({
    required String marketplaceAccountId,
  }) async {
    final result = await _client.rpc(
      'marketplace_import_validation_snapshot',
      params: {
        'p_account_id': marketplaceAccountId,
        'p_days': 90,
      },
    );
    return _map(result);
  }

  Future<Map<String, dynamic>> fetchPayoutReadiness({
    required String marketplaceAccountId,
  }) async {
    final result = await _client.rpc(
      'marketplace_payout_readiness_snapshot',
      params: {
        'p_account_id': marketplaceAccountId,
        'p_days': 90,
      },
    );
    return _map(result);
  }

  Future<Map<String, dynamic>> finalizeBootstrap({
    required String marketplaceAccountId,
    required int minValidOrders,
  }) async {
    final result = await _client.rpc(
      'marketplace_finalize_export_bootstrap',
      params: {
        'p_account_id': marketplaceAccountId,
        'p_min_valid_orders': minValidOrders,
        'p_force': false,
      },
    );
    return _map(result);
  }

  Future<_PickedFile?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'csv', 'zip'],
      withData: true,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('File belum bisa dibaca. Pilih file lokal XLSX/CSV/ZIP, bukan cloud placeholder.');
    }
    return _PickedFile(name: file.name, bytes: bytes);
  }

  HistoricalImportParseResult _parseBytes({
    required Uint8List bytes,
    required String fileName,
    required String sourceLabel,
    required Map<String, dynamic> Function(Map<String, String>) normalizer,
  }) {
    final lower = fileName.toLowerCase().trim();
    final allRows = <Map<String, String>>[];
    final headers = <String>{};

    if (lower.endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final name = entry.name.toLowerCase();
        final content = Uint8List.fromList(entry.content as List<int>);
        if (name.endsWith('.xlsx')) {
          final parsed = _parseXlsx(content);
          allRows.addAll(parsed.rows);
          headers.addAll(parsed.headers);
        } else if (name.endsWith('.csv')) {
          final parsed = _parseCsv(utf8.decode(content, allowMalformed: true));
          allRows.addAll(parsed.rows);
          headers.addAll(parsed.headers);
        }
      }
    } else if (lower.endsWith('.xlsx')) {
      final parsed = _parseXlsx(bytes);
      allRows.addAll(parsed.rows);
      headers.addAll(parsed.headers);
    } else if (lower.endsWith('.csv')) {
      final parsed = _parseCsv(utf8.decode(bytes, allowMalformed: true));
      allRows.addAll(parsed.rows);
      headers.addAll(parsed.headers);
    } else {
      throw Exception('Format file belum didukung. Pakai XLSX, CSV, atau ZIP berisi XLSX/CSV.');
    }

    final uploadRows = <Map<String, dynamic>>[];
    var validRows = 0;
    var cancelledRows = 0;
    var grossTotal = 0.0;
    var validGrossTotal = 0.0;

    for (var i = 0; i < allRows.length; i++) {
      final raw = allRows[i];
      final normalized = normalizer(raw);
      final status = (normalized['status'] ?? normalized['payout_status'] ?? '').toString().toLowerCase();
      final total = _toDouble(normalized['total_amount'] ?? normalized['payout_amount']);
      final isCancelled = status.contains('cancel') ||
          status.contains('batal') ||
          status.contains('dibatalkan');

      grossTotal += total;
      if (isCancelled) {
        cancelledRows++;
      } else {
        validRows++;
        validGrossTotal += total;
      }

      uploadRows.add({
        'row_index': i + 1,
        'raw': raw,
        'normalized': normalized,
      });
    }

    return HistoricalImportParseResult(
      fileName: fileName,
      sourceLabel: sourceLabel,
      headers: headers.toList(growable: false),
      rawRows: allRows,
      uploadRows: uploadRows,
      validRows: validRows,
      cancelledRows: cancelledRows,
      grossTotal: grossTotal,
      validGrossTotal: validGrossTotal,
    );
  }

  _ParsedRows _parseXlsx(Uint8List bytes) {
    final excel = Excel.decodeBytes(bytes);
    final rows = <Map<String, String>>[];
    final headerSet = <String>{};

    for (final table in excel.tables.values) {
      final sheetRows = table.rows
          .map((row) => row.map((cell) => _cleanCell(cell?.value?.toString() ?? '')).toList())
          .where((row) => row.any((cell) => cell.trim().isNotEmpty))
          .toList();

      if (sheetRows.isEmpty) continue;

      var headerIndex = 0;
      for (var i = 0; i < sheetRows.length; i++) {
        final nonEmpty = sheetRows[i].where((x) => x.trim().isNotEmpty).length;
        if (nonEmpty >= 2) {
          headerIndex = i;
          break;
        }
      }

      final headers = sheetRows[headerIndex]
          .map(_cleanHeader)
          .where((h) => h.isNotEmpty)
          .toList(growable: false);

      headerSet.addAll(headers);

      for (var r = headerIndex + 1; r < sheetRows.length; r++) {
        final row = sheetRows[r];
        final map = <String, String>{};
        for (var c = 0; c < headers.length && c < row.length; c++) {
          final key = headers[c];
          if (key.isEmpty) continue;
          map[key] = row[c].trim();
        }
        if (map.values.any((v) => v.trim().isNotEmpty)) rows.add(map);
      }
    }

    return _ParsedRows(headers: headerSet.toList(growable: false), rows: rows);
  }

  _ParsedRows _parseCsv(String text) {
    final lines = const LineSplitter().convert(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
    final parsedLines = lines
        .map(_parseCsvLine)
        .where((row) => row.any((cell) => cell.trim().isNotEmpty))
        .toList();

    if (parsedLines.isEmpty) return const _ParsedRows(headers: [], rows: []);

    final headers = parsedLines.first.map(_cleanHeader).toList(growable: false);
    final rows = <Map<String, String>>[];

    for (final row in parsedLines.skip(1)) {
      final map = <String, String>{};
      for (var i = 0; i < headers.length && i < row.length; i++) {
        final key = headers[i];
        if (key.isEmpty) continue;
        map[key] = row[i].trim();
      }
      if (map.values.any((v) => v.trim().isNotEmpty)) rows.add(map);
    }

    return _ParsedRows(headers: headers, rows: rows);
  }

  List<String> _parseCsvLine(String line) {
    final out = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        out.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    out.add(buffer.toString());
    return out;
  }

  Map<String, dynamic> _normalizeOrderRow(Map<String, String> row, String marketplace) {
    String? pick(List<String> aliases) => _pick(row, aliases);

    final status = pick([
      'status',
      'status pesanan',
      'order status',
      'order_status',
      'status pemesanan',
      'status pengiriman',
    ]);

    return {
      'marketplace': marketplace,
      'order_sn': pick([
        'order id',
        'order_id',
        'order sn',
        'order_sn',
        'nomor pesanan',
        'no. pesanan',
        'no pesanan',
        'id pesanan',
        'id order',
      ]),
      'status': status,
      'order_created_at': pick([
        'created time',
        'create time',
        'waktu pesanan dibuat',
        'tanggal pesanan dibuat',
        'order creation time',
        'waktu dibuat',
        'tanggal dibuat',
        'paid time',
        'waktu pembayaran',
      ]),
      'sku': pick([
        'seller sku',
        'sku penjual',
        'sku',
        'sku induk',
        'variation sku',
        'nomor referensi sku',
        'merchant sku',
      ]),
      'quantity': pick([
        'quantity',
        'qty',
        'jumlah',
        'jumlah produk di pesan',
        'jumlah produk dipesan',
        'kuantitas',
      ]),
      'total_amount': pick([
        'total amount',
        'total pembayaran',
        'jumlah dibayar pembeli',
        'total dibayar pembeli',
        'order amount',
        'subtotal',
        'harga total',
        'total harga produk',
        'gross amount',
      ]),
    }..removeWhere((_, value) => value == null || value.toString().trim().isEmpty);
  }

  Map<String, dynamic> _normalizeIncomeRow(Map<String, String> row, String marketplace) {
    String? pick(List<String> aliases) => _pick(row, aliases);

    return {
      'marketplace': marketplace,
      'order_sn': pick([
        'order id',
        'order_id',
        'order sn',
        'order_sn',
        'nomor pesanan',
        'no. pesanan',
        'no pesanan',
        'id pesanan',
        'id order',
      ]),
      'statement_id': pick([
        'statement id',
        'settlement id',
        'id settlement',
        'id pelepasan dana',
        'income id',
        'transaction id',
        'id transaksi',
      ]),
      'payout_status': pick([
        'status',
        'status payout',
        'status pelepasan',
        'status dana',
        'settlement status',
      ]),
      'payout_amount': pick([
        'payout',
        'payout amount',
        'released amount',
        'jumlah dilepas',
        'dana dilepas',
        'income',
        'pendapatan',
        'jumlah pendapatan',
        'total income',
        'net amount',
        'net income',
        'jumlah bersih',
      ]),
      'fee_amount': pick([
        'fee',
        'admin fee',
        'biaya admin',
        'commission fee',
        'komisi',
        'platform fee',
        'biaya layanan',
      ]),
      'adjustment_amount': pick([
        'adjustment',
        'penyesuaian',
        'refund',
        'pengembalian',
        'subsidi',
        'voucher',
      ]),
      'settlement_at': pick([
        'settlement time',
        'settlement date',
        'released time',
        'tanggal dilepas',
        'waktu dilepas',
        'tanggal settlement',
        'waktu settlement',
      ]),
    }..removeWhere((_, value) => value == null || value.toString().trim().isEmpty);
  }

  String? _pick(Map<String, String> row, List<String> aliases) {
    if (row.isEmpty) return null;
    final normalized = <String, String>{};
    for (final entry in row.entries) {
      normalized[_normKey(entry.key)] = entry.value;
    }
    for (final alias in aliases) {
      final value = normalized[_normKey(alias)];
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }

    for (final entry in normalized.entries) {
      for (final alias in aliases) {
        final needle = _normKey(alias);
        if (needle.isNotEmpty && entry.key.contains(needle) && entry.value.trim().isNotEmpty) {
          return entry.value.trim();
        }
      }
    }

    return null;
  }

  String _normKey(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '')
        .trim();
  }

  String _cleanHeader(String value) {
    return _cleanCell(value)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanCell(String value) {
    var v = value.trim();
    v = v.replaceAll(RegExp(r'^(TextCellValue|IntCellValue|DoubleCellValue|DateCellValue)\('), '');
    v = v.replaceAll(RegExp(r'\)$'), '');
    if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
      v = v.substring(1, v.length - 1);
    }
    return v.trim();
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    var text = value.toString().trim();
    if (text.isEmpty) return 0;
    text = text.replaceAll(RegExp(r'[^0-9,\.\-]'), '');
    if (RegExp(r'^-?[0-9]{1,3}(\.[0-9]{3})+(,[0-9]+)?$').hasMatch(text)) {
      text = text.replaceAll('.', '').replaceAll(',', '.');
    } else if (RegExp(r'^-?[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$').hasMatch(text)) {
      text = text.replaceAll(',', '');
    } else if (RegExp(r'^-?[0-9]+,[0-9]+$').hasMatch(text)) {
      text = text.replaceAll(',', '.');
    } else {
      text = text.replaceAll(',', '');
    }
    return double.tryParse(text) ?? 0;
  }

  List<List<Map<String, dynamic>>> _chunks(List<Map<String, dynamic>> rows, int size) {
    final out = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < rows.length; i += size) {
      out.add(rows.sublist(i, i + size > rows.length ? rows.length : i + size));
    }
    return out;
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
    return <String, dynamic>{'value': value};
  }
}

class _PickedFile {
  final String name;
  final Uint8List bytes;

  const _PickedFile({required this.name, required this.bytes});
}

class _ParsedRows {
  final List<String> headers;
  final List<Map<String, String>> rows;

  const _ParsedRows({required this.headers, required this.rows});
}
