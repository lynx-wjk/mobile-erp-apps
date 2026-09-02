import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service to handle beep sounds and haptic vibrations during barcode/QR scanning.
class ScanFeedbackService {
  ScanFeedbackService._();
  static final ScanFeedbackService instance = ScanFeedbackService._();

  AudioPlayer? _player;
  bool _isInitialized = false;

  void _init() {
    if (_isInitialized) return;
    try {
      _player = AudioPlayer();
      _player?.setReleaseMode(ReleaseMode.stop);
      _player?.setPlayerMode(PlayerMode.lowLatency);
      _isInitialized = true;
    } catch (e) {
      debugPrint('[ScanFeedbackService] Failed to initialize AudioPlayer: $e');
    }
  }

  /// Plays the scanner beep sound and triggers haptic vibration.
  Future<void> playScanSuccess() async {
    // 1. Haptic vibration (immediate physical response)
    try {
      await HapticFeedback.mediumImpact();
    } catch (_) {}

    // 2. Audible beep
    try {
      _init();
      if (_player != null) {
        // In audioplayers, AssetSource resolves inside 'assets/'
        await _player!.stop();
        await _player!.play(AssetSource('sounds/barcode_beep.wav'), volume: 1.0);
        return;
      }
    } catch (e) {
      debugPrint('[ScanFeedbackService] Audio playback error: $e');
    }

    // 3. Fallback to SystemSound if player failed
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }

  /// Triggers a negative / error feedback for unrecognized barcodes.
  Future<void> playScanError() async {
    try {
      await HapticFeedback.heavyImpact();
    } catch (_) {}

    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }

  void dispose() {
    try {
      _player?.dispose();
    } catch (_) {}
    _player = null;
    _isInitialized = false;
  }
}