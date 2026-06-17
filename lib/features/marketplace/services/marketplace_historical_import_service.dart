import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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
    final picked = await _pickFiles();
    if (picked.isEmpty) return null;
    return _parsePickedFiles(
      pickedFiles: picked,
      sourceLabel: 'order_export',
      normalizer: (row) => _normalizeOrderRow(row, marketplace),
    );
  }

  Future<HistoricalImportParseResult?> pickAndParseIncomeExport({
    required String marketplace,
  }) async {
    final picked = await _pickFiles();
    if (picked.isEmpty) return null;
    return _parsePickedFiles(
      pickedFiles: picked,
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

  Future<List<_PickedFile>> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'csv', 'zip'],
      withData: true,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return const <_PickedFile>[];

    final files = <_PickedFile>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw Exception(
          'File "${file.name}" belum bisa dibaca. Pilih file lokal XLSX/CSV/ZIP, bukan cloud placeholder.',
        );
      }
      files.add(_PickedFile(name: file.name, bytes: bytes));
    }
    return files;
  }

  HistoricalImportParseResult _parsePickedFiles({
    required List<_PickedFile> pickedFiles,
    required String sourceLabel,
    required Map<String, dynamic> Function(Map<String, String>) normalizer,
  }) {
    final allRows = <Map<String, String>>[];
    final headers = <String>{};
    final fileNames = <String>[];

    for (final picked in pickedFiles) {
      fileNames.add(picked.name);
      final parsed = _parseBytes(
        bytes: picked.bytes,
        fileName: picked.name,
      );
      allRows.addAll(parsed.rows);
      headers.addAll(parsed.headers);
    }

    if (allRows.isEmpty) {
      throw Exception(
        'Tidak ada row yang terbaca dari file. Export marketplace kadang kosong atau formatnya bukan XLSX/CSV valid, karena tentu saja file spreadsheet harus ikut bercanda.',
      );
    }

    final uploadRows = <Map<String, dynamic>>[];
    var validRows = 0;
    var cancelledRows = 0;
    var grossTotal = 0.0;
    var validGrossTotal = 0.0;

    for (var i = 0; i < allRows.length; i++) {
      final raw = allRows[i];
      final normalized = normalizer(raw);
      final status = (normalized['status'] ?? normalized['payout_status'] ?? '')
          .toString()
          .toLowerCase();
      final total = _toDouble(
        normalized['total_amount'] ?? normalized['payout_amount'],
      );
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
      fileName: fileNames.join(' + '),
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

  _ParsedRows _parseBytes({
    required Uint8List bytes,
    required String fileName,
  }) {
    final lower = fileName.toLowerCase().trim();

    if (lower.endsWith('.zip')) {
      return _parseOuterZip(bytes, fileName);
    }
    if (lower.endsWith('.xlsx')) {
      return _parseXlsx(bytes);
    }
    if (lower.endsWith('.csv')) {
      return _parseCsv(utf8.decode(bytes, allowMalformed: true));
    }

    throw Exception('Format file "$fileName" belum didukung. Pakai XLSX, CSV, atau ZIP.');
  }

  _ParsedRows _parseOuterZip(Uint8List bytes, String fileName) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final rows = <Map<String, String>>[];
    final headers = <String>{};

    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.toLowerCase();
      final content = _archiveFileBytes(entry);

      if (name.endsWith('.xlsx')) {
        final parsed = _parseXlsx(content);
        rows.addAll(parsed.rows);
        headers.addAll(parsed.headers);
      } else if (name.endsWith('.csv')) {
        final parsed = _parseCsv(utf8.decode(content, allowMalformed: true));
        rows.addAll(parsed.rows);
        headers.addAll(parsed.headers);
      }
    }

    return _ParsedRows(headers: headers.toList(growable: false), rows: rows);
  }

  Uint8List _archiveFileBytes(ArchiveFile entry) {
    final content = entry.content;
    if (content is Uint8List) return content;
    if (content is List<int>) return Uint8List.fromList(content);
    return Uint8List.fromList(List<int>.from(content as Iterable));
  }

  _ParsedRows _parseXlsx(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, ArchiveFile>{};
    for (final entry in archive.files) {
      if (entry.isFile) files[entry.name] = entry;
    }

    final sharedStrings = _readSharedStrings(files);
    final sheetNames = files.keys
        .where((name) =>
            name.toLowerCase().startsWith('xl/worksheets/') &&
            name.toLowerCase().endsWith('.xml'))
        .toList()
      ..sort();

    final allRows = <Map<String, String>>[];
    final allHeaders = <String>{};

    for (final sheetName in sheetNames) {
      final sheetXml = _decodeXmlFile(files[sheetName]);
      if (sheetXml.trim().isEmpty) continue;

      final matrix = _readSheetRows(sheetXml, sharedStrings);
      if (matrix.isEmpty) continue;

      var headerIndex = -1;
      for (var i = 0; i < matrix.length; i++) {
        final nonEmpty = matrix[i].where((x) => x.trim().isNotEmpty).length;
        if (nonEmpty >= 2) {
          headerIndex = i;
          break;
        }
      }
      if (headerIndex < 0) continue;

      final headers = matrix[headerIndex].map(_cleanHeader).toList(growable: false);
      allHeaders.addAll(headers.where((h) => h.isNotEmpty));

      for (var r = headerIndex + 1; r < matrix.length; r++) {
        final row = matrix[r];
        final map = <String, String>{};

        for (var c = 0; c < headers.length && c < row.length; c++) {
          final key = headers[c];
          if (key.isEmpty) continue;
          map[key] = row[c].trim();
        }

        if (map.values.any((v) => v.trim().isNotEmpty)) {
          allRows.add(map);
        }
      }
    }

    return _ParsedRows(
      headers: allHeaders.toList(growable: false),
      rows: allRows,
    );
  }

  List<String> _readSharedStrings(Map<String, ArchiveFile> files) {
    final xml = _decodeXmlFile(files['xl/sharedStrings.xml']);
    if (xml.trim().isEmpty) return const <String>[];

    final strings = <String>[];
    final siRegex = RegExp(r'<si\b[^>]*>(.*?)</si>', dotAll: true);
    final textRegex = RegExp(r'<t\b[^>]*>(.*?)</t>', dotAll: true);

    for (final si in siRegex.allMatches(xml)) {
      final body = si.group(1) ?? '';
      final parts = <String>[];
      for (final t in textRegex.allMatches(body)) {
        parts.add(_xmlUnescape(_stripXmlTags(t.group(1) ?? '')));
      }
      strings.add(parts.join());
    }

    return strings;
  }

  List<List<String>> _readSheetRows(String xml, List<String> sharedStrings) {
    final rows = <List<String>>[];
    final rowRegex = RegExp(r'<row\b[^>]*>(.*?)</row>', dotAll: true);
    final cellRegex = RegExp(r'<c\b([^>]*)>(.*?)</c>', dotAll: true);
    final attrRegex = RegExp(r'(\w+)="([^"]*)"');
    final vRegex = RegExp(r'<v\b[^>]*>(.*?)</v>', dotAll: true);
    final tRegex = RegExp(r'<t\b[^>]*>(.*?)</t>', dotAll: true);

    for (final rowMatch in rowRegex.allMatches(xml)) {
      final rowBody = rowMatch.group(1) ?? '';
      final values = <String>[];

      for (final cellMatch in cellRegex.allMatches(rowBody)) {
        final attrs = <String, String>{};
        for (final attr in attrRegex.allMatches(cellMatch.group(1) ?? '')) {
          attrs[attr.group(1) ?? ''] = attr.group(2) ?? '';
        }

        final ref = attrs['r'] ?? '';
        final index = _cellRefToIndex(ref);
        while (values.length <= index) {
          values.add('');
        }

        final cellType = attrs['t'] ?? '';
        final cellBody = cellMatch.group(2) ?? '';
        var value = '';

        final vMatch = vRegex.firstMatch(cellBody);
        if (vMatch != null) {
          value = _xmlUnescape(_stripXmlTags(vMatch.group(1) ?? ''));
          if (cellType == 's') {
            final sharedIndex = int.tryParse(value);
            if (sharedIndex != null &&
                sharedIndex >= 0 &&
                sharedIndex < sharedStrings.length) {
              value = sharedStrings[sharedIndex];
            }
          }
        } else if (cellType == 'inlineStr') {
          final parts = <String>[];
          for (final t in tRegex.allMatches(cellBody)) {
            parts.add(_xmlUnescape(_stripXmlTags(t.group(1) ?? '')));
          }
          value = parts.join();
        }

        values[index] = value.trim();
      }

      if (values.any((x) => x.trim().isNotEmpty)) {
        rows.add(values);
      }
    }

    return rows;
  }

  int _cellRefToIndex(String ref) {
    final letters = RegExp(r'^[A-Z]+', caseSensitive: false).firstMatch(ref)?.group(0) ?? 'A';
    var result = 0;
    for (final code in letters.toUpperCase().codeUnits) {
      result = result * 26 + (code - 64);
    }
    return result <= 0 ? 0 : result - 1;
  }

  String _decodeXmlFile(ArchiveFile? file) {
    if (file == null) return '';
    return utf8.decode(_archiveFileBytes(file), allowMalformed: true);
  }

  _ParsedRows _parseCsv(String text) {
    final lines = const LineSplitter()
        .convert(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
    final parsedLines = lines
        .map(_parseCsvLine)
        .where((row) => row.any((cell) => cell.trim().isNotEmpty))
        .toList();

    if (parsedLines.isEmpty) return const _ParsedRows(headers: [], rows: []);

    var headerIndex = 0;
    for (var i = 0; i < parsedLines.length; i++) {
      if (parsedLines[i].where((x) => x.trim().isNotEmpty).length >= 2) {
        headerIndex = i;
        break;
      }
    }

    final headers = parsedLines[headerIndex].map(_cleanHeader).toList(growable: false);
    final rows = <Map<String, String>>[];

    for (final row in parsedLines.skip(headerIndex + 1)) {
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
        if (needle.isNotEmpty &&
            entry.key.contains(needle) &&
            entry.value.trim().isNotEmpty) {
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
    return _xmlUnescape(_stripXmlTags(value))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _stripXmlTags(String value) {
    return value.replaceAll(RegExp(r'<[^>]+>'), '');
  }

  String _xmlUnescape(String value) {
    return value
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
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
