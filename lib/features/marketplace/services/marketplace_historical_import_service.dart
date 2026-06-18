import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef HistoricalImportUploadProgress = void Function(
  int uploadedRows,
  int totalRows,
);

typedef HistoricalFinalizeProgress = void Function(
  Map<String, dynamic> status,
);

class HistoricalImportParseResult {
  final String fileName;
  final String sourceLabel;
  final List<String> headers;
  final int totalRows;
  final List<Map<String, dynamic>> uploadRows;
  final int validRows;
  final int cancelledRows;
  final double grossTotal;
  final double validGrossTotal;

  const HistoricalImportParseResult({
    required this.fileName,
    required this.sourceLabel,
    required this.headers,
    required this.totalRows,
    required this.uploadRows,
    required this.validRows,
    required this.cancelledRows,
    required this.grossTotal,
    required this.validGrossTotal,
  });

  bool get isEmpty => totalRows <= 0;
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

    return _HistoricalImportParser.parsePayload(
      marketplace: marketplace,
      sourceLabel: 'order_export',
      pickedFiles: picked,
    );
  }

  Future<HistoricalImportParseResult?> pickAndParseIncomeExport({
    required String marketplace,
  }) async {
    final picked = await _pickFiles();
    if (picked.isEmpty) return null;

    return _HistoricalImportParser.parsePayload(
      marketplace: marketplace,
      sourceLabel: 'finance_income_export',
      pickedFiles: picked,
    );
  }

  Future<HistoricalImportUploadResult> uploadOrderExport({
    required String marketplaceAccountId,
    required String marketplace,
    required HistoricalImportParseResult parsed,
    HistoricalImportUploadProgress? onProgress,
  }) async {
    final batchId = await _rpcWithRetry(
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
    onProgress?.call(uploaded, parsed.totalRows);

    for (final chunk in _chunks(parsed.uploadRows, 100)) {
      await _rpcWithRetry(
        'marketplace_append_order_export_import_rows',
        params: {
          'p_batch_id': id,
          'p_rows': chunk,
        },
      );
      uploaded += chunk.length;
      onProgress?.call(uploaded, parsed.totalRows);
      await Future<void>.delayed(const Duration(milliseconds: 80));
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
    HistoricalImportUploadProgress? onProgress,
  }) async {
    final batchId = await _rpcWithRetry(
      'marketplace_create_finance_income_import_batch',
      params: {
        'p_marketplace_account_id': marketplaceAccountId,
        'p_marketplace': marketplace,
        'p_source_type': 'finance_income_export',
        'p_original_filename': parsed.fileName,
        'p_total_rows': parsed.totalRows,
        'p_payout_total': parsed.validGrossTotal,
        'p_fee_total': _sumNormalized(parsed.uploadRows, 'fee_amount'),
        'p_adjustment_total': _sumNormalized(parsed.uploadRows, 'adjustment_amount'),
      },
    );

    final id = batchId.toString();
    var uploaded = 0;
    onProgress?.call(uploaded, parsed.totalRows);

    for (final chunk in _chunks(parsed.uploadRows, 100)) {
      await _rpcWithRetry(
        'marketplace_append_finance_income_import_rows',
        params: {
          'p_batch_id': id,
          'p_rows': chunk,
        },
      );
      uploaded += chunk.length;
      onProgress?.call(uploaded, parsed.totalRows);
      await Future<void>.delayed(const Duration(milliseconds: 80));
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
    final result = await _rpcWithRetry(
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
    final result = await _rpcWithRetry(
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
    HistoricalFinalizeProgress? onProgress,
  }) async {
    var status = _map(
      await _rpcWithRetry(
        'marketplace_historical_finalize_start',
        params: {
          'p_account_id': marketplaceAccountId,
          'p_min_valid_orders': minValidOrders,
          'p_force': false,
        },
      ),
    );

    onProgress?.call(status);

    final jobId = status['job_id']?.toString();
    if (jobId == null || jobId.isEmpty) {
      return status;
    }

    for (var step = 0; step < 5000; step++) {
      final state = status['status']?.toString();
      if (state == 'done') {
        await _backfillFinanceBreakdown(
          marketplaceAccountId: marketplaceAccountId,
        );
        return status;
      }
      if (state == 'error') return status;

      await Future<void>.delayed(const Duration(milliseconds: 150));

      status = _map(
        await _rpcWithRetry(
          'marketplace_historical_finalize_process_step',
          params: {
            'p_job_id': jobId,
            'p_limit': 25,
          },
        ),
      );

      onProgress?.call(status);
    }

    return {
      ...status,
      'ok': false,
      'message':
          'Finalisasi masih berjalan. Halaman ini akan terus memproses selama tetap terbuka. Jika halaman tertutup, klik Finalize Bootstrap lagi untuk melanjutkan job yang sama.',
    };
  }


  Future<List<Map<String, dynamic>>> fetchFinalizeStatus() async {
    final result = await _rpcWithRetry(
      'marketplace_historical_import_status_snapshot',
    );

    if (result is Map && result['accounts'] is List) {
      return (result['accounts'] as List)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }

    return const <Map<String, dynamic>>[];
  }

  double _sumNormalized(
    List<Map<String, dynamic>> rows,
    String key,
  ) {
    return rows.fold<double>(0, (sum, row) {
      final normalized = row['normalized'];
      if (normalized is! Map) return sum;
      return sum + _HistoricalImportParser.parseNumber(normalized[key]);
    });
  }

  Future<void> _backfillFinanceBreakdown({
    required String marketplaceAccountId,
  }) async {
    try {
      await _rpcWithRetry(
        'marketplace_backfill_finance_report_breakdown_from_staging',
        params: {'p_account_id': marketplaceAccountId},
      );
    } catch (_) {
      // Recovery metadata only. Finalize tetap valid kalau backfill gagal.
    }
  }

  Future<dynamic> _rpcWithRetry(
    String functionName, {
    Map<String, dynamic>? params,
  }) async {
    Object? lastError;

    for (var attempt = 1; attempt <= 5; attempt++) {
      try {
        return await _client
            .rpc(functionName, params: params)
            .timeout(const Duration(seconds: 90));
      } catch (error) {
        lastError = error;

        if (attempt >= 5) {
          throw Exception(
            'RPC $functionName gagal setelah $attempt percobaan: $error',
          );
        }

        await Future<void>.delayed(
          Duration(milliseconds: 700 * attempt * attempt),
        );
      }
    }

    throw Exception('RPC $functionName gagal: $lastError');
  }

  Future<List<_PickedFile>> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'csv', 'zip'],
      withData: true,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) {
      return const <_PickedFile>[];
    }

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

  List<List<Map<String, dynamic>>> _chunks(
    List<Map<String, dynamic>> rows,
    int size,
  ) {
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

class _HistoricalImportParser {
  static HistoricalImportParseResult parsePayload({
    required String marketplace,
    required String sourceLabel,
    required List<_PickedFile> pickedFiles,
  }) {
    final expectedMarketplace = _normalizeMarketplace(marketplace);
    final allRows = <Map<String, String>>[];
    final headers = <String>{};
    final fileNames = <String>[];

    for (final picked in pickedFiles) {
      fileNames.add(picked.name);
      final parsed = _parseBytes(bytes: picked.bytes, fileName: picked.name);

      final detectedMarketplace = _detectMarketplace(
        fileName: picked.name,
        headers: parsed.headers,
        rows: parsed.rows,
      );

      if (detectedMarketplace != 'unknown' &&
          expectedMarketplace != 'unknown' &&
          detectedMarketplace != expectedMarketplace) {
        throw Exception(
          'File "${picked.name}" terdeteksi sebagai ${_marketplaceHuman(detectedMarketplace)}, '
          'tapi akun yang dipilih adalah ${_marketplaceHuman(expectedMarketplace)}. '
          'File Shopee tidak boleh diupload ke akun TikTok, dan file TikTok tidak boleh diupload ke akun Shopee.',
        );
      }

      final detectedKind = _detectExportKind(parsed.headers, parsed.rows);
      if (sourceLabel == 'order_export' &&
          detectedKind == 'finance_income_export') {
        throw Exception(
          'File "${picked.name}" terlihat seperti file Income/Payout, bukan Order Export.',
        );
      }
      if (sourceLabel == 'finance_income_export' &&
          detectedKind == 'order_export') {
        throw Exception(
          'File "${picked.name}" terlihat seperti file Order Export, bukan Income/Payout.',
        );
      }

      allRows.addAll(parsed.rows);
      headers.addAll(parsed.headers);
    }

    if (allRows.isEmpty) {
      throw Exception(
        'Tidak ada row yang terbaca dari file. Export marketplace kosong atau formatnya bukan XLSX/CSV valid.',
      );
    }

    final uploadRows = <Map<String, dynamic>>[];
    var validRows = 0;
    var cancelledRows = 0;
    var grossTotal = 0.0;
    var validGrossTotal = 0.0;

    for (var i = 0; i < allRows.length; i++) {
      final raw = allRows[i];
      final normalized = sourceLabel == 'finance_income_export'
          ? _normalizeIncomeRow(raw, marketplace)
          : _normalizeOrderRow(raw, marketplace);

      if (_shouldSkipParsedRow(
        raw: raw,
        normalized: normalized,
        sourceLabel: sourceLabel,
        marketplace: marketplace,
      )) {
        continue;
      }

      if (_shouldSkipParsedRow(
        raw: raw,
        normalized: normalized,
        sourceLabel: sourceLabel,
        marketplace: marketplace,
      )) {
        continue;
      }

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
        'raw': {
          ...raw,
          '_row_index': '${i + 1}',
          '_source': sourceLabel,
          '_selected_marketplace': expectedMarketplace,
        },
        'normalized': normalized,
      });
    }

    return HistoricalImportParseResult(
      fileName: fileNames.join(' + '),
      sourceLabel: sourceLabel,
      headers: headers.toList(growable: false),
      totalRows: allRows.length,
      uploadRows: uploadRows,
      validRows: validRows,
      cancelledRows: cancelledRows,
      grossTotal: grossTotal,
      validGrossTotal: validGrossTotal,
    );
  }

  static _ParsedRows _parseBytes({
    required Uint8List bytes,
    required String fileName,
  }) {
    final lower = fileName.toLowerCase().trim();

    if (lower.endsWith('.zip')) return _parseOuterZip(bytes);
    if (lower.endsWith('.xlsx')) return _parseXlsx(bytes);
    if (lower.endsWith('.csv')) {
      return _parseCsv(utf8.decode(bytes, allowMalformed: true));
    }

    throw Exception(
      'Format file "$fileName" belum dig. Pakai XLSX, CSV, atau ZIP.',
    );
  }

  static _ParsedRows _parseOuterZip(Uint8List bytes) {
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

  static Uint8List _archiveFileBytes(ArchiveFile entry) {
    final content = entry.content;
    if (content is Uint8List) return content;
    if (content is List<int>) return Uint8List.fromList(content);
    return Uint8List.fromList(List<int>.from(content as Iterable));
  }

  static _ParsedRows _parseXlsx(Uint8List bytes) {
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

      final headerIndex = _findHeaderIndex(matrix);
      if (headerIndex < 0) continue;

      final headerRow =
          matrix[headerIndex].map(_cleanHeader).toList(growable: false);
      allHeaders.addAll(headerRow.where((h) => h.isNotEmpty));

      for (var r = headerIndex + 1; r < matrix.length; r++) {
        final row = matrix[r];
        final map = <String, String>{};

        for (var c = 0; c < headerRow.length && c < row.length; c++) {
          final key = headerRow[c];
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

  static List<String> _readSharedStrings(Map<String, ArchiveFile> files) {
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

  static List<List<String>> _readSheetRows(
    String xml,
    List<String> sharedStrings,
  ) {
    final byRow = <int, List<String>>{};
    final rowRegex = RegExp(r'<row\b([^>]*)>(.*?)</row>', dotAll: true);
    final cellRegex = RegExp(r'<c\b([^>]*)>(.*?)</c>', dotAll: true);
    final attrRegex = RegExp(r'(\w+)="([^"]*)"');
    final vRegex = RegExp(r'<v\b[^>]*>(.*?)</v>', dotAll: true);
    final tRegex = RegExp(r'<t\b[^>]*>(.*?)</t>', dotAll: true);
    var fallbackRow = 0;

    for (final rowMatch in rowRegex.allMatches(xml)) {
      final rowAttrs = <String, String>{};
      for (final attr in attrRegex.allMatches(rowMatch.group(1) ?? '')) {
        rowAttrs[attr.group(1) ?? ''] = attr.group(2) ?? '';
      }

      final rowNumber = int.tryParse(rowAttrs['r'] ?? '') ?? ++fallbackRow;
      final values = byRow.putIfAbsent(rowNumber, () => <String>[]);
      final rowBody = rowMatch.group(2) ?? '';

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
    }

    final keys = byRow.keys.toList()..sort();
    return keys
        .map((key) => byRow[key] ?? <String>[])
        .where((row) => row.any((x) => x.trim().isNotEmpty))
        .toList(growable: false);
  }

  static _ParsedRows _parseCsv(String text) {
    final lines = const LineSplitter()
        .convert(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
    final parsedLines = lines
        .map(_parseCsvLine)
        .where((row) => row.any((cell) => cell.trim().isNotEmpty))
        .toList();

    if (parsedLines.isEmpty) return const _ParsedRows(headers: [], rows: []);

    final headerIndex = _findHeaderIndex(parsedLines);
    final safeHeaderIndex = headerIndex < 0 ? 0 : headerIndex;
    final headers =
        parsedLines[safeHeaderIndex].map(_cleanHeader).toList(growable: false);

    final rows = <Map<String, String>>[];
    for (final row in parsedLines.skip(safeHeaderIndex + 1)) {
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

  static List<String> _parseCsvLine(String line) {
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

  static int _findHeaderIndex(List<List<String>> matrix) {
    var bestIndex = -1;
    var bestScore = -1;

    final maxScan = matrix.length > 80 ? 80 : matrix.length;
    for (var i = 0; i < maxScan; i++) {
      final row = matrix[i];
      final nonEmpty = row.where((x) => x.trim().isNotEmpty).length;
      if (nonEmpty < 2) continue;

      final score = _headerScore(row);
      if (score > bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }

    if (bestIndex >= 0 && bestScore > 0) return bestIndex;

    for (var i = 0; i < matrix.length; i++) {
      if (matrix[i].where((x) => x.trim().isNotEmpty).length >= 2) return i;
    }

    return -1;
  }

  static int _headerScore(List<String> row) {
    final joined = row.map(_normKey).join('|');
    var score = 0;

    const needles = [
      'orderid',
      'ordersn',
      'nomorpesanan',
      'nopesanan',
      'idpesanan',
      'statuspesanan',
      'orderstatus',
      'sellersku',
      'skupenjual',
      'sku',
      'quantity',
      'qty',
      'jumlah',
      'createdtime',
      'waktupemesanan',
      'waktupesanan',
      'waktupembayaran',
      'totalpembayaran',
      'jumlahdibayar',
      'orderamount',
      'totalamount',
      'totalpendapatan',
      'pendapatan',
      'jumlahpenyelesaianpembayaran',
      'danadilepaskan',
      'tanggaldanadilepaskan',
      'biayaprosespesanan',
      'biayalayanan',
      'settlement',
      'payout',
      'dilepas',
    ];

    for (final needle in needles) {
      final clean = _normKey(needle);
      if (clean.isNotEmpty && joined.contains(clean)) score++;
    }

    return score;
  }

  static String _detectMarketplace({
    required String fileName,
    required List<String> headers,
    required List<Map<String, String>> rows,
  }) {
    final headerText = [
      fileName,
      ...headers,
      ...rows.take(2).expand((row) => row.keys),
    ].map(_normKey).join('|');

    var tiktok = 0;
    var shopee = 0;

    const tiktokNeedles = [
      'tiktok',
      'tiktokshop',
      'orderid',
      'orderstatus',
      'ordersubstatus',
      'skuid',
      'sellersku',
      'idpesananpenyesuaian',
      'jenistransaksi',
      'jumlahpenyelesaianpembayaran',
      'totalpendapatan',
    ];

    const shopeeNeedles = [
      'shopee',
      'nopesanan',
      'statuspesanan',
      'nopengajuan',
      'usernamepembeli',
      'metodepembayaranpembeli',
      'tanggaldanadilepaskan',
      'hargaasliproduk',
      'totaldiskonproduk',
      'opsipengiriman',
    ];

    for (final needle in tiktokNeedles) {
      if (headerText.contains(_normKey(needle))) tiktok++;
    }
    for (final needle in shopeeNeedles) {
      if (headerText.contains(_normKey(needle))) shopee++;
    }

    if (tiktok >= shopee + 2 && tiktok >= 2) return 'tiktok_shop';
    if (shopee >= tiktok + 2 && shopee >= 2) return 'shopee';
    if (headerText.contains('tiktok')) return 'tiktok_shop';
    if (headerText.contains('shopee')) return 'shopee';
    return 'unknown';
  }

  static String _detectExportKind(
    List<String> headers,
    List<Map<String, String>> rows,
  ) {
    final headerText = [
      ...headers,
      ...rows.take(2).expand((row) => row.keys),
    ].map(_normKey).join('|');

    var orderScore = 0;
    var incomeScore = 0;

    const orderNeedles = [
      'orderstatus',
      'statuspesanan',
      'cancellationreturntype',
      'statuspembatalanpengembalian',
      'noresi',
      'sellersku',
      'skupenjual',
      'quantity',
      'variation',
      'opsipengiriman',
    ];

    const incomeNeedles = [
      'idpesananpenyesuaian',
      'jenistransaksi',
      'jumlahpenyelesaianpembayaran',
      'totalpendapatan',
      'danadilepaskan',
      'tanggaldanadilepaskan',
      'biayaprosespesanan',
      'nopengajuan',
      'settlement',
      'payout',
    ];

    for (final needle in orderNeedles) {
      if (headerText.contains(_normKey(needle))) orderScore++;
    }
    for (final needle in incomeNeedles) {
      if (headerText.contains(_normKey(needle))) incomeScore++;
    }

    if (incomeScore >= 3 && incomeScore > orderScore + 1) {
      return 'finance_income_export';
    }
    if (orderScore >= 3 && orderScore > incomeScore + 1) {
      return 'order_export';
    }
    return 'unknown';
  }


  static bool _shouldSkipParsedRow({
    required Map<String, String> raw,
    required Map<String, dynamic> normalized,
    required String sourceLabel,
    required String marketplace,
  }) {
    final market = _normalizeMarketplace(marketplace);
    final source = sourceLabel.trim().toLowerCase();

    if (source == 'finance_income_export') {
      final orderSn = normalized['order_sn']?.toString().trim() ?? '';
      final payout = _toDouble(normalized['payout_amount']);
      final fee = _toDouble(normalized['fee_amount']);
      final adjustment = _toDouble(normalized['adjustment_amount']);

      if (market == 'tiktok_shop') {
        final hasTikTokIncomeShape = raw.keys.any((key) {
          final norm = _normKey(key);
          return norm == 'idpesananpenyesuaian' ||
              norm == 'jumlahpenyelesaianpembayaran' ||
              norm == 'jenistransaksi';
        });

        if (!hasTikTokIncomeShape) return true;
      }

      return orderSn.isEmpty && payout == 0 && fee == 0 && adjustment == 0;
    }

    if (source == 'order_export') {
      final orderSn = normalized['order_sn']?.toString().trim() ?? '';
      final sku = normalized['sku']?.toString().trim() ?? '';
      return orderSn.isEmpty && sku.isEmpty;
    }

    return false;
  }

  static String? _sumNumbers(List<String?> values) {
    var found = false;
    var total = 0.0;

    for (final value in values) {
      if (value == null || value.trim().isEmpty) continue;
      found = true;
      total += _toDouble(value);
    }

    if (!found) return null;
    return total.toStringAsFixed(2);
  }

  static String? _sumPicked(
    Map<String, String> row,
    List<String> aliases,
  ) {
    if (row.isEmpty) return null;

    final normalized = <String, String>{};
    for (final entry in row.entries) {
      normalized[_normKey(entry.key)] = entry.value;
    }

    var found = false;
    var total = 0.0;

    for (final alias in aliases) {
      final value = normalized[_normKey(alias)];
      if (value == null || value.trim().isEmpty) continue;
      found = true;
      total += _toDouble(value);
    }

    if (!found) return null;
    return total.toStringAsFixed(2);
  }

  static double parseNumber(dynamic value) => _toDouble(value);

  static Map<String, dynamic> _normalizeOrderRow(
    Map<String, String> row,
    String marketplace,
  ) {
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
      'order_substatus': pick([
        'order substatus',
        'order_substatus',
        'substatus pesanan',
      ]),
      'cancel_return_type': pick([
        'cancelation/return type',
        'cancellation/return type',
        'cancelation return type',
        'cancellation return type',
        'status pembatalan/pengembalian',
        'tipe pembatalan/pengembalian',
      ]),
      'tracking_number': pick([
        'tracking id',
        'tracking_id',
        'tracking number',
        'awb',
        'resi',
        'no resi',
        'nomor resi',
      ]),
      'order_created_at': pick([
        'created time',
        'create time',
        'waktu pesanan dibuat',
        'tanggal pesanan dibuat',
        'order creation time',
        'waktu dibuat',
        'tanggal dibuat',
      ]),
      'paid_at': pick([
        'paid time',
        'waktu pembayaran',
        'waktu pembayaran pesanan',
      ]),
      'rts_at': pick([
        'rts time',
        'ready to ship time',
      ]),
      'shipped_at': pick([
        'shipped time',
        'waktu dikirim',
      ]),
      'delivered_at': pick([
        'delivered time',
        'waktu terkirim',
      ]),
      'cancelled_at': pick([
        'cancelled time',
        'canceled time',
        'waktu dibatalkan',
      ]),
      'sku': pick([
        'seller sku',
        'seller_sku',
        'sku penjual',
        'sku',
        'sku induk',
        'variation sku',
        'nomor referensi sku',
        'merchant sku',
      ]),
      'marketplace_sku_id': pick([
        'sku id',
        'skuid',
        'marketplace sku id',
      ]),
      'product_name': pick([
        'product name',
        'nama produk',
      ]),
      'variation': pick([
        'variation',
        'variasi',
        'nama variasi',
      ]),
      'quantity': pick([
        'quantity',
        'qty',
        'jumlah',
        'jumlah produk di pesan',
        'jumlah produk dipesan',
        'kuantitas',
      ]),
      'seller_discount': _sumPicked(row, [
        'sku seller discount',
        'seller discount',
        'diskon penjual',
      ]),
      'platform_discount': _sumPicked(row, [
        'sku platform discount',
        'platform discount',
        'diskon platform',
      ]),
      'refund_amount': _sumPicked(row, [
        'order refund amount',
        'refund amount',
        'jumlah refund',
      ]),
      'total_amount': _pickOrderAmount(row, marketplace),
      'payment_method': pick([
        'payment method',
        'metode pembayaran',
      ]),
    }..removeWhere((_, value) => value == null || value.toString().trim().isEmpty);
  }

  static String? _pickOrderAmount(Map<String, String> row, String marketplace) {
    final market = _normalizeMarketplace(marketplace);

    if (market == 'shopee') {
      return _pick(row, [
        'total pembayaran',
        'jumlah dibayar pembeli',
        'total dibayar pembeli',
        'total harga produk',
        'harga total',
      ]);
    }

    if (market == 'tiktok_shop') {
      return _pick(row, [
        'order amount',
        'total amount',
        'jumlah dibayar pembeli',
        'total pembayaran',
        'sku subtotal after discount',
        'subtotal after discount',
      ]);
    }

    return _pick(row, [
      'total amount',
      'total pembayaran',
      'jumlah dibayar pembeli',
      'order amount',
      'subtotal',
      'harga total',
      'gross amount',
    ]);
  }

  static Map<String, dynamic> _normalizeIncomeRow(
    Map<String, String> row,
    String marketplace,
  ) {
    String? pick(List<String> aliases) => _pick(row, aliases);

    final sellerDiscount = _sumPicked(row, [
      'diskon penjual',
      'seller discount',
      'seller voucher',
      'voucher penjual',
    ]);

    final platformDiscount = _sumPicked(row, [
      'voucher gmv max',
      'diskon platform',
      'platform discount',
      'platform voucher',
      'voucher platform',
    ]);

    final platformFee = _sumPicked(row, [
      'biaya layanan program bebas ongkir',
      'biaya layanan khusus live',
      'biaya layanan program eams',
      'program layanan terkelola (biaya per pesanan)',
      'platform fee',
      'biaya platform',
      'biaya layanan',
    ]);

    final commissionFee = _sumPicked(row, [
      'biaya komisi platform',
      'commission fee',
      'komisi platform',
      'komisi',
    ]);

    final affiliateFee = _sumPicked(row, [
      'komisi afiliasi',
      'komisi mitra afiliasi',
      'komisi iklan toko afiliasi',
      'komisi iklan toko mitra afiliasi',
      'affiliate fee',
      'affiliate commission',
    ]);

    final shippingFee = _sumPicked(row, [
      'ongkir',
      'subsidi ongkir',
      'biaya layanan logistik',
      'ongkir pesanan gagal kirim',
      'ongkir pengembalian barang karena kesalahan pembeli',
      'shipping fee',
      'shipping cost',
      'logistics fee',
    ]);

    final paymentFee = _sumPicked(row, [
      'biaya pembayaran',
      'biaya pemrosesan pesanan',
      'payment fee',
      'transaction fee',
      'processing fee',
    ]);

    final refundAmount = _sumPicked(row, [
      'subtotal pengembalian dana setelah diskon penjual',
      'subtotal pengembalian dana sebelum diskon penjual',
      'pengembalian dana diskon penjual',
      'refund amount',
      'return amount',
    ]);

    final taxAmount = _sumPicked(row, [
      'pajak penjualan atas voucher gmv max',
      'program layanan terkelola (pajak penjualan)',
      'pajak',
      'tax',
      'ppn',
      'pph',
    ]);

    final adjustmentAmount = _sumPicked(row, [
      'biaya iklan gmv max',
      'penalti platform',
      'adjustment',
      'penyesuaian',
    ]);

    final totalFees = _sumPicked(row, [
      'total biaya',
      'total fees',
      'total fee',
    ]);

    final computedFee = _sumNumbers([
      platformFee,
      commissionFee,
      affiliateFee,
      shippingFee,
      paymentFee,
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
        'id pesanan/penyesuaian',
      ]),
      'transaction_type': pick([
        'jenis transaksi',
        'transaction type',
      ]),
      'statement_id': pick([
        'statement id',
        'settlement id',
        'id settlement',
        'id pelepasan dana',
        'income id',
        'transaction id',
        'id transaksi',
        'no. pengajuan',
        'no pengajuan',
      ]),
      'payout_status': pick([
        'status',
        'status payout',
        'status pelepasan',
        'status dana',
        'settlement status',
      ]),
      'payout_amount': _pickIncomePayout(row, marketplace),
      'gross_income': pick([
        'total pendapatan',
        'total income',
      ]),
      'seller_discount': sellerDiscount,
      'platform_discount': platformDiscount,
      'discount_amount': _sumNumbers([sellerDiscount, platformDiscount]),
      'platform_fee': platformFee,
      'commission_fee': commissionFee,
      'affiliate_fee': affiliateFee,
      'shipping_fee': shippingFee,
      'payment_transaction_fee': paymentFee,
      'refund_amount': refundAmount,
      'tax_amount': taxAmount,
      'adjustment_amount': adjustmentAmount,
      'fee_amount': totalFees ?? computedFee,
      'total_fees': totalFees ?? computedFee,
      'settlement_at': pick([
        'settlement time',
        'settlement date',
        'released time',
        'tanggal dilepas',
        'waktu dilepas',
        'tanggal dana dilepaskan',
        'tanggal settlement',
        'waktu settlement',
        'waktu pembayaran pesanan',
        'waktu pemesanan',
      ]),
    }..removeWhere((_, value) => value == null || value.toString().trim().isEmpty);
  }

  static String? _pickIncomePayout(Map<String, String> row, String marketplace) {
    final market = _normalizeMarketplace(marketplace);

    if (market == 'shopee') {
      return _pick(row, [
        'dana dilepaskan',
        'jumlah dana dilepaskan',
        'jumlah dana yang dilepaskan',
        'total dana dilepaskan',
        'nominal dana dilepaskan',
        'pendapatan bersih',
        'penghasilan bersih',
        'total penghasilan',
        'total pendapatan',
        'jumlah penghasilan',
        'total pembayaran',
        'jumlah dibayar pembeli',
      ]);
    }

    if (market == 'tiktok_shop') {
      return _pick(row, [
        'jumlah penyelesaian pembayaran',
        'total pendapatan',
        'pendapatan',
        'payout',
        'payout amount',
        'settlement amount',
        'net amount',
        'net income',
        'jumlah bersih',
      ]);
    }

    return _pick(row, [
      'jumlah penyelesaian pembayaran',
      'dana dilepaskan',
      'jumlah dana dilepaskan',
      'total pendapatan',
      'pendapatan bersih',
      'payout',
      'net amount',
    ]);
  }

  static String? _pick(Map<String, String> row, List<String> aliases) {
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
        if (needle.length >= 7 &&
            entry.key.contains(needle) &&
            entry.value.trim().isNotEmpty) {
          return entry.value.trim();
        }
      }
    }

    return null;
  }

  static int _cellRefToIndex(String ref) {
    final letters =
        RegExp(r'^[A-Z]+', caseSensitive: false).firstMatch(ref)?.group(0) ??
            'A';
    var result = 0;
    for (final code in letters.toUpperCase().codeUnits) {
      result = result * 26 + (code - 64);
    }
    return result <= 0 ? 0 : result - 1;
  }

  static String _decodeXmlFile(ArchiveFile? file) {
    if (file == null) return '';
    return utf8.decode(_archiveFileBytes(file), allowMalformed: true);
  }

  static String _cleanHeader(String value) {
    return _xmlUnescape(_stripXmlTags(value))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _normalizeMarketplace(String value) {
    final clean = _normKey(value);
    if (clean.contains('shopee') || clean.contains('shoppe')) return 'shopee';
    if (clean.contains('tiktok')) return 'tiktok_shop';
    return 'unknown';
  }

  static String _marketplaceHuman(String value) {
    if (value == 'shopee') return 'Shopee';
    if (value == 'tiktok_shop') return 'TikTok Shop';
    return value;
  }

  static String _normKey(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '')
        .trim();
  }

  static String _stripXmlTags(String value) {
    return value.replaceAll(RegExp(r'<[^>]+>'), '');
  }

  static String _xmlUnescape(String value) {
    return value
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0;

    var text = value.toString().trim();
    if (text.isEmpty) return 0;

    text = text.replaceAll(RegExp(r'[^0-9,\.\-]'), '');

    if (RegExp(r'^-?[0-9]{1,3}(\.[0-9]{3})+(,[0-9]+)?$').hasMatch(text)) {
      text = text.replaceAll('.', '').replaceAll(',', '.');
    } else if (RegExp(r'^-?[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$')
        .hasMatch(text)) {
      text = text.replaceAll(',', '');
    } else if (RegExp(r'^-?[0-9]+,[0-9]+$').hasMatch(text)) {
      text = text.replaceAll(',', '.');
    } else {
      text = text.replaceAll(',', '');
    }

    return double.tryParse(text) ?? 0;
  }
}

class _PickedFile {
  final String name;
  final Uint8List bytes;

  const _PickedFile({
    required this.name,
    required this.bytes,
  });
}

class _ParsedRows {
  final List<String> headers;
  final List<Map<String, String>> rows;

  const _ParsedRows({
    required this.headers,
    required this.rows,
  });
}
