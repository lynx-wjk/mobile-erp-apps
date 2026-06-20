import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/photo_evidence.dart';

class PhotoEvidenceService {
  final SupabaseClient _client = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  Future<PhotoEvidence> captureAndUpload({
    required String moduleName,
    required String purpose,
    String? referenceId,
  }) async {
    final pickedFile = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 70,
      maxWidth: 1400,
    );

    if (pickedFile == null) {
      throw Exception('Foto dibatalkan');
    }

    return uploadPickedImage(
      pickedFile: pickedFile,
      moduleName: moduleName,
      purpose: purpose,
      referenceId: referenceId,
    );
  }

  Future<PhotoEvidence> uploadPickedImage({
    required XFile pickedFile,
    required String moduleName,
    required String purpose,
    String? referenceId,
  }) async {
    final bytes = await pickedFile.readAsBytes();

    if (bytes.isEmpty) {
      throw Exception('File foto kosong');
    }

    final position = await _getCurrentPosition();
    final now = DateTime.now();
    final userId = _client.auth.currentUser?.id;

    final fileName = _buildFileName(
      moduleName: moduleName,
      purpose: purpose,
      userId: userId,
      now: now,
    );

    final driveResult = await _uploadToGoogleDrive(
      fileName: fileName,
      mimeType: 'image/jpeg',
      bytes: bytes,
    );

    final publicUrl = driveResult.publicUrl;
    final storagePath = 'google_drive:${driveResult.fileId}';

    Map<String, dynamic>? inserted;

    try {
      final insertData = <String, dynamic>{
        'module_name': moduleName,
        'purpose': purpose,
        'reference_id': referenceId,
        'bucket_id': 'google_drive',
        'file_path': driveResult.fileId,
        'public_url': publicUrl,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy_meter': position.accuracy,
        'captured_at': now.toIso8601String(),
        'created_by': userId,
      };

      final response = await _client
          .from('photo_evidences')
          .insert(insertData)
          .select()
          .maybeSingle();

      if (response != null) {
        inserted = Map<String, dynamic>.from(response);
      }
    } catch (_) {
      inserted = null;
    }

    return PhotoEvidence(
      evidenceId: inserted?['evidence_id']?.toString() ?? driveResult.fileId,
      moduleName: moduleName,
      purpose: purpose,
      referenceId: referenceId,
      publicUrl: publicUrl,
      storagePath: storagePath,
      localPath: pickedFile.path,
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeter: position.accuracy,
      capturedAt: now,
      createdBy: userId,
      createdAt: now,
    );
  }

  Future<String> uploadBytesToDrive({
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    if (bytes.isEmpty) {
      throw Exception('File kosong');
    }

    final safeName = fileName.trim().isEmpty
        ? 'production_file_${DateTime.now().millisecondsSinceEpoch}'
        : fileName.trim();

    final driveResult = await _uploadToGoogleDrive(
      fileName: safeName,
      mimeType: mimeType.trim().isEmpty ? 'application/octet-stream' : mimeType,
      bytes: bytes,
    );

    return driveResult.publicUrl;
  }

  Future<_DriveUploadResult> _uploadToGoogleDrive({
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final uri = _resolveUploadUri();

    final payload = <String, dynamic>{
      'fileName': fileName,
      'mimeType': mimeType,
      'base64Data': base64Encode(bytes),
    };

    // Android/native lama masih boleh direct ke Apps Script.
    // Web default-nya lewat Vercel proxy supaya tidak kena CORS dan token tidak kebuka di browser.
    if (!kIsWeb && !_isProxyUri(uri)) {
      final token = dotenv.env['GOOGLE_DRIVE_UPLOAD_TOKEN']?.trim() ?? '';
      if (token.isEmpty) {
        throw Exception('GOOGLE_DRIVE_UPLOAD_TOKEN belum diisi di .env');
      }
      payload['token'] = token;
    }

    final responseBody = await _postJson(
      uri: uri,
      payload: payload,
    );

    final decoded = jsonDecode(responseBody);

    if (decoded is! Map<String, dynamic>) {
      throw Exception('Respons upload foto belum sesuai.');
    }

    if (decoded['ok'] != true) {
      throw Exception(decoded['message']?.toString() ?? 'Upload Drive gagal');
    }

    final fileId = decoded['fileId']?.toString() ?? '';
    final publicUrl = decoded['publicUrl']?.toString() ?? '';

    if (fileId.isEmpty || publicUrl.isEmpty) {
      throw Exception(
          'Data foto berhasil dikirim, tetapi tautan hasil upload belum lengkap.');
    }

    return _DriveUploadResult(
      fileId: fileId,
      publicUrl: publicUrl,
      viewUrl: decoded['viewUrl']?.toString(),
    );
  }

  Uri _resolveUploadUri() {
    final proxyUrl = dotenv.env['PHOTO_UPLOAD_PROXY_URL']?.trim() ?? '';
    final directUrl = dotenv.env['GOOGLE_DRIVE_UPLOAD_URL']?.trim() ?? '';

    if (kIsWeb) {
      if (proxyUrl.isNotEmpty) {
        return _validateHttpUri(
          _parseWebUri(proxyUrl),
          envName: 'PHOTO_UPLOAD_PROXY_URL',
        );
      }
      return _validateHttpUri(
        Uri.base.resolve('/functions/v1/upload-drive'),
        envName: 'PHOTO_UPLOAD_PROXY_URL',
      );
    }

    // Android/iOS tidak punya origin web. Nilai seperti /api/upload-drive akan
    // berubah menjadi file:///api/upload-drive dan memicu error "No host specified".
    // Karena itu native wajib memakai URL absolut. Prioritasnya: Apps Script langsung,
    // lalu proxy absolut kalau memang disediakan.
    if (directUrl.isNotEmpty) {
      return _validateHttpUri(Uri.parse(directUrl),
          envName: 'GOOGLE_DRIVE_UPLOAD_URL');
    }

    if (proxyUrl.isNotEmpty) {
      final parsed = Uri.tryParse(proxyUrl);
      if (parsed == null || !parsed.hasScheme) {
        throw Exception(
          'PHOTO_UPLOAD_PROXY_URL harus berupa URL absolut untuk Android/iOS. '
          'Contoh: https://domain-vercel.vercel.app/api/upload-drive. '
          'Jangan gunakan /api/upload-drive di aplikasi native.',
        );
      }
      return _validateHttpUri(parsed, envName: 'PHOTO_UPLOAD_PROXY_URL');
    }

    throw Exception(
      'Endpoint upload foto belum dikonfigurasi. Isi GOOGLE_DRIVE_UPLOAD_URL untuk Android/iOS, '
      'atau isi PHOTO_UPLOAD_PROXY_URL dengan URL https absolut.',
    );
  }

  Uri _parseWebUri(String value) {
    final parsed = Uri.tryParse(value);
    if (parsed == null) return Uri.base.resolve(value);
    if (parsed.hasScheme) return parsed;
    return Uri.base.resolve(value);
  }

  Uri _validateHttpUri(
    Uri uri, {
    required String envName,
  }) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw Exception(
          '$envName harus memakai URL http/https, bukan ${uri.scheme.isEmpty ? 'relative/file' : uri.scheme}.');
    }
    if (uri.host.trim().isEmpty) {
      throw Exception(
          '$envName tidak valid: host URL kosong. Gunakan URL lengkap, misalnya https://domain/api/upload-drive.');
    }
    return uri;
  }

  bool _isProxyUri(Uri uri) {
    return uri.path.contains('/api/upload-drive') || uri.path.contains('/functions/v1/upload-drive');
  }

  Future<String> _postJson({
    required Uri uri,
    required Map<String, dynamic> payload,
  }) async {
    final client = http.Client();
    final body = jsonEncode(payload);
    final postHeaders = const {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final getHeaders = const {
      'Accept': 'application/json,text/plain,*/*',
    };

    try {
      var currentUri = uri;
      var method = 'POST';

      for (var attempt = 0; attempt < 6; attempt++) {
        final response = method == 'POST'
            ? await client
                .post(
                  currentUri,
                  headers: postHeaders,
                  body: body,
                )
                .timeout(const Duration(seconds: 120))
            : await client
                .get(
                  currentUri,
                  headers: getHeaders,
                )
                .timeout(const Duration(seconds: 120));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response.body;
        }

        if (_isRedirectStatus(response.statusCode)) {
          final location = _extractRedirectLocation(response);
          if (location == null || location.trim().isEmpty) {
            throw Exception(
              'Upload foto belum selesai karena server penyimpanan belum memberikan alamat tujuan.',
            );
          }

          currentUri = currentUri.resolve(location.trim());

          // Google Apps Script biasanya menjalankan doPost lebih dulu, lalu
          // mengembalikan 302 ke script.googleusercontent.com untuk mengambil
          // output JSON. Redirect itu harus diambil dengan GET, bukan POST lagi,
          // supaya foto tidak ter-upload dua kali.
          if (response.statusCode == 301 ||
              response.statusCode == 302 ||
              response.statusCode == 303) {
            method = 'GET';
          }

          continue;
        }

        throw Exception(
          'Upload foto gagal. Coba lagi atau periksa koneksi internet.',
        );
      }

      throw Exception(
          'Upload foto gagal. Redirect terlalu banyak. Periksa URL Apps Script/Drive upload.');
    } finally {
      client.close();
    }
  }

  bool _isRedirectStatus(int statusCode) {
    return statusCode == 301 ||
        statusCode == 302 ||
        statusCode == 303 ||
        statusCode == 307 ||
        statusCode == 308;
  }

  String? _extractRedirectLocation(http.Response response) {
    final headerLocation = response.headers['location'];
    if (headerLocation != null && headerLocation.trim().isNotEmpty) {
      return headerLocation.trim();
    }

    // Beberapa response Google Apps Script mengirim body HTML seperti:
    // The document has moved <A HREF="https://script.googleusercontent.com/...">
    final body = response.body;
    final hrefMatch = RegExp(
      r'''<a\s+href=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(body);

    final movedMatch = hrefMatch ??
        RegExp(
          r'''HREF=["']?([^"' >]+)''',
          caseSensitive: false,
        ).firstMatch(body);

    final raw = movedMatch?.group(1);
    if (raw == null || raw.trim().isEmpty) return null;

    return raw
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  Future<Position> _getCurrentPosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      throw Exception('GPS belum aktif');
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception('Izin lokasi ditolak');
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception(
          'Izin lokasi ditolak permanen. Aktifkan dari Settings browser/perangkat.');
    }

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  String _buildFileName({
    required String moduleName,
    required String purpose,
    required String? userId,
    required DateTime now,
  }) {
    String safe(String value) {
      final cleaned = value
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
          .replaceAll(RegExp(r'_+'), '_')
          .replaceAll(RegExp(r'^_|_$'), '');
      return cleaned.isEmpty ? 'evidence' : cleaned;
    }

    final timestamp = now.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final userPart = (userId ?? 'unknown').replaceAll('-', '').trim();

    return '${safe(moduleName)}_${safe(purpose)}_${userPart}_$timestamp.jpg';
  }
}

class _DriveUploadResult {
  final String fileId;
  final String publicUrl;
  final String? viewUrl;

  const _DriveUploadResult({
    required this.fileId,
    required this.publicUrl,
    this.viewUrl,
  });
}
