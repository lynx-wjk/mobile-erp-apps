import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../ui/app_ui.dart';
import '../models/photo_evidence.dart';
import '../services/photo_evidence_service.dart';

class EvidenceCameraField extends StatefulWidget {
  final String label;
  final String moduleName;
  final String purpose;
  final String? referenceId;
  final String? initialPhotoUrl;
  final String? helperText;
  final bool requireInsideWorkLocation;
  final bool allowGallery;
  final ValueChanged<PhotoEvidence> onUploaded;

  const EvidenceCameraField({
    super.key,
    required this.label,
    required this.moduleName,
    required this.purpose,
    required this.onUploaded,
    this.referenceId,
    this.initialPhotoUrl,
    this.helperText,
    this.requireInsideWorkLocation = false,
    this.allowGallery = false,
  });

  @override
  State<EvidenceCameraField> createState() => _EvidenceCameraFieldState();
}

class _EvidenceCameraFieldState extends State<EvidenceCameraField> {
  final _service = PhotoEvidenceService();
  final _picker = ImagePicker();
  final SupabaseClient _client = Supabase.instance.client;

  bool _isUploading = false;
  PhotoEvidence? _evidence;
  String? _photoUrl;
  Uint8List? _localBytes;

  @override
  void initState() {
    super.initState();
    _photoUrl = _cleanUrl(widget.initialPhotoUrl);
  }

  @override
  void didUpdateWidget(covariant EvidenceCameraField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newUrl = _cleanUrl(widget.initialPhotoUrl);
    if (newUrl != _photoUrl) {
      setState(() => _photoUrl = newUrl);
    }
  }

  String? _cleanUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty || text == '-') return null;
    return text;
  }

  String? _driveFileId(String url) {
    final patterns = <RegExp>[
      RegExp(r'/file/d/([^/]+)'),
      RegExp(r'[?&]id=([^&]+)'),
      RegExp(r'/d/([^/]+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match != null && match.groupCount >= 1) {
        return match.group(1);
      }
    }

    return null;
  }

  String _previewUrl(String url) {
    final id = _driveFileId(url);
    if (id == null) return url;
    return 'https://drive.google.com/thumbnail?id=$id&sz=w1200';
  }

  Future<Position> _getCurrentPositionForValidation() async {
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

  Future<void> _validateInsideActiveWorkLocation() async {
    if (!widget.requireInsideWorkLocation) return;

    final position = await _getCurrentPositionForValidation();

    final response = await _client
        .from('work_locations')
        .select(
            'location_id, nama_lokasi, latitude, longitude, radius_meter, status')
        .eq('status', 'active');

    final locations = (response as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    if (locations.isEmpty) {
      throw Exception('Belum ada master lokasi aktif. Upload bukti ditolak.');
    }

    Map<String, dynamic>? nearest;
    double? nearestDistance;

    for (final location in locations) {
      final latitude = AppUi.toNum(location['latitude']).toDouble();
      final longitude = AppUi.toNum(location['longitude']).toDouble();
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        latitude,
        longitude,
      );

      if (nearestDistance == null || distance < nearestDistance) {
        nearestDistance = distance;
        nearest = location;
      }
    }

    final radius = AppUi.toNum(nearest?['radius_meter']).toDouble();
    final locationName = AppUi.text(nearest?['nama_lokasi'], 'lokasi aktif');
    final distance = nearestDistance ?? double.infinity;

    if (distance > radius) {
      throw Exception(
        'Di luar area $locationName (${distance.toStringAsFixed(0)} meter dari titik, radius ${radius.toStringAsFixed(0)} meter). Upload bukti ditolak.',
      );
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    if (_isUploading) return;

    try {
      await _validateInsideActiveWorkLocation();

      final pickedFile = await _picker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 1400,
      );

      if (pickedFile == null) return;

      final previewBytes = await pickedFile.readAsBytes();

      if (!mounted) return;
      setState(() {
        _isUploading = true;
        _localBytes = previewBytes;
        _photoUrl = null;
        _evidence = null;
      });

      AppUi.showSnack('Foto ditampilkan. Upload sedang diproses.');

      final evidence = await _service.uploadPickedImage(
        pickedFile: pickedFile,
        moduleName: widget.moduleName,
        purpose: widget.purpose,
        referenceId: widget.referenceId,
      );

      if (!mounted) return;

      setState(() {
        _evidence = evidence;
        _photoUrl = evidence.publicUrl;
      });

      widget.onUploaded(evidence);

      AppUi.showSnack('Foto berhasil diunggah. Lokasi dan waktu tersimpan.');
    } catch (error) {
      if (!mounted) return;
      AppUi.showSnack('Upload foto gagal: ${_cleanError(error)}');
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  bool get _canPickFromGallery => widget.allowGallery || kIsWeb;

  Future<void> _capture() => _pickPhoto(ImageSource.camera);

  Future<void> _pickFromGallery() => _pickPhoto(ImageSource.gallery);

  String _cleanError(Object error) {
    var text = error.toString().trim();
    text = text.replaceFirst(RegExp(r'^Exception:\s*'), '');
    if (text.contains('No host specified') ||
        text.contains('file:///api/upload-drive')) {
      return 'Endpoint upload foto belum memakai URL lengkap. Isi GOOGLE_DRIVE_UPLOAD_URL atau PHOTO_UPLOAD_PROXY_URL dengan URL https absolut.';
    }
    return text.length > 420 ? '${text.substring(0, 420)}...' : text;
  }

  String _formatDate(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.day)}/${two(value.month)}/${value.year} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final evidence = _evidence;
    final photoUrl = _photoUrl;
    final previewUrl = photoUrl == null ? null : _previewUrl(photoUrl);
    final localBytes = _localBytes;
    final hasLocalPreview = localBytes != null && localBytes.isNotEmpty;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.label,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            if ((widget.helperText ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                widget.helperText!.trim(),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
              ),
            ],
            const SizedBox(height: 10),
            if (previewUrl != null || hasLocalPreview) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: 120,
                  maxHeight: 220,
                  minWidth: double.infinity,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: hasLocalPreview
                      ? Image.memory(
                          localBytes,
                          height: 190,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        )
                      : Image.network(
                          previewUrl!,
                          height: 190,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const SizedBox(
                              height: 160,
                              child: Center(child: CircularProgressIndicator()),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              height: 132,
                              width: double.infinity,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                              child: const Text(
                                'Foto tersimpan, tetapi preview belum dapat dimuat. Periksa akses viewer Google Drive.',
                                textAlign: TextAlign.center,
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 10),
              if (evidence != null) ...[
                Text('Latitude: ${evidence.latitude}'),
                Text('Longitude: ${evidence.longitude}'),
                Text(
                    'Akurasi: ${evidence.accuracyMeter?.toStringAsFixed(1) ?? '-'} meter'),
                Text('Waktu foto: ${_formatDate(evidence.capturedAt)}'),
              ] else ...[
                const Text('Foto ditampilkan. Menunggu upload selesai.'),
              ],
              const SizedBox(height: 10),
            ],
            if (_canPickFromGallery)
              Row(
                children: [
                  Expanded(child: _photoButton(photoUrl: photoUrl)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isUploading ? null : _pickFromGallery,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(kIsWeb ? 'File/Galeri' : 'Galeri'),
                    ),
                  ),
                ],
              )
            else
              SizedBox(
                  width: double.infinity,
                  child: _photoButton(photoUrl: photoUrl)),
          ],
        ),
      ),
    );
  }

  Widget _photoButton({required String? photoUrl}) {
    return FilledButton.icon(
      onPressed: _isUploading ? null : _capture,
      icon: _isUploading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.camera_alt_outlined),
      label: Text(
        _isUploading
            ? 'Mengunggah foto...'
            : photoUrl == null
                ? 'Ambil Foto'
                : 'Ambil Ulang',
      ),
    );
  }
}
