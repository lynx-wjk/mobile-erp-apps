import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/sound/scan_feedback_service.dart';
import '../../../core/ui/app_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

enum ScanMode { auto, barcode, qr }

class QrScanPage extends StatefulWidget {
  final String title;
  final String instruction;
  final ScanMode scanMode;

  const QrScanPage({
    super.key,
    this.title = 'Scan QR / Barcode',
    this.instruction = 'Arahkan kamera ke QR code atau barcode.',
    this.scanMode = ScanMode.auto,
  });

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _hasScanned = false;
  String? _scannedValue;
  Timer? _completeTimer;
  late ScanMode _mode = widget.scanMode;
  double _zoomScale = 0.0; // 0.0 is 1.0x, 0.25 is ~1.5x, 0.5 is ~2.0x
  bool _isTorchOn = false;
  Offset? _focusPoint;
  Timer? _focusTimer;

  final MobileScannerController _controller = MobileScannerController(
    facing: CameraFacing.back,
    detectionSpeed: DetectionSpeed.normal,
    torchEnabled: false,
  );

  @override
  void initState() {
    super.initState();
    _setupOptimalLens();
  }

  Future<void> _setupOptimalLens() async {
    try {
      final bestLens = await _controller.getBestCloseRangeScanningLens(
        facing: CameraFacing.back,
      );
      final supported = await _controller.getSupportedLenses(
        facing: CameraFacing.back,
      );

      if (bestLens != null && supported.contains(bestLens)) {
        await _controller.switchCamera(
          SelectCamera(
            facingDirection: CameraFacing.back,
            lensType: bestLens,
          ),
        );
      }
    } catch (_) {
      // Fallback seamlessly to default camera if lens switching unsupported
    }
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _completeTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_hasScanned) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final value = barcodes.first.rawValue;
    if (value == null || value.trim().isEmpty) return;

    final code = value.trim();
    setState(() {
      _hasScanned = true;
      _scannedValue = code;
    });

    // 1. Play audible scanner beep and trigger physical haptic feedback
    ScanFeedbackService.instance.playScanSuccess();

    // 2. Give user immediate visual confirmation for 400ms then pop result
    _completeTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        AppUi.safePop(context, code);
      }
    });
  }

  Future<void> _setZoom(double zoom) async {
    setState(() => _zoomScale = zoom);
    try {
      await _controller.setZoomScale(zoom);
    } catch (_) {}
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      setState(() => _isTorchOn = !_isTorchOn);
    } catch (_) {}
  }

  Future<void> _handleTapFocus(TapUpDetails details, BoxConstraints constraints) async {
    final dx = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final dy = (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    setState(() {
      _focusPoint = details.localPosition;
    });

    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _focusPoint = null);
    });

    try {
      await _controller.setFocusPoint(Offset(dx, dy));
    } catch (_) {}
  }

  Rect _scanWindow(Size size) {
    if (_mode == ScanMode.barcode) {
      final width = size.width * 0.84;
      const height = 150.0;
      return Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: width,
        height: height,
      );
    }
    final side = size.width * 0.72;
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side,
      height: side,
    );
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: _toggleTorch,
            icon: Icon(
              _isTorchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
              color: _isTorchOn ? Colors.amber.shade600 : iconColor,
            ),
            tooltip: 'Flashlight',
          ),
          PopupMenuButton<ScanMode>(
            initialValue: _mode,
            onSelected: (value) => setState(() => _mode = value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: ScanMode.auto, child: Text('Auto')),
              PopupMenuItem(value: ScanMode.barcode, child: Text('Barcode')),
              PopupMenuItem(value: ScanMode.qr, child: Text('QR Code')),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final window = _scanWindow(size);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _handleTapFocus(details, constraints),
            child: Stack(
              children: [
                MobileScanner(
                  controller: _controller,
                  scanWindow: window,
                  onDetect: _handleDetect,
                ),
                // Scan Window Frame
                Positioned.fromRect(
                  rect: window,
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _hasScanned ? const Color(0xFF10B981) : Colors.white,
                          width: _hasScanned ? 4 : 3,
                        ),
                        borderRadius: BorderRadius.circular(
                          _mode == ScanMode.barcode ? 14 : 20,
                        ),
                        boxShadow: _hasScanned
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.5),
                                  blurRadius: 18,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                      child: _hasScanned
                          ? Center(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.9),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.3),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                  size: 38,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
                // Top floating notification banner when scan is done
                if (_hasScanned && _scannedValue != null)
                  Positioned(
                    top: 16,
                    left: 16,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_rounded, color: Colors.white, size: 24),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Scan Berhasil!',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  _scannedValue!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Tap to Focus Ring indicator
                if (_focusPoint != null)
                  Positioned(
                    left: _focusPoint!.dx - 28,
                    top: _focusPoint!.dy - 28,
                    child: IgnorePointer(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.amberAccent, width: 2),
                        ),
                      ),
                    ),
                  ),
                // Unified Bottom Control Panel (Zoom Pills + Tips Box)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Zoom selector pills
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.22),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _zoomPill('1x', 0.0),
                              const SizedBox(width: 4),
                              _zoomPill('1.5x', 0.25),
                              const SizedBox(width: 4),
                              _zoomPill('2x', 0.5),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Instruction & Tips box
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.78),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.16),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            '${widget.instruction}\nMode: ${_mode == ScanMode.barcode ? 'Barcode' : _mode == ScanMode.qr ? 'QR Code' : 'Auto'} · Ketuk layar untuk fokus\nTips iPhone: Gunakan zoom 1.5x / 2x & jaga jarak 15–20cm.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _zoomPill(String label, double zoom) {
    final isSelected = (_zoomScale - zoom).abs() < 0.05;
    return InkWell(
      onTap: () => _setZoom(zoom),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
