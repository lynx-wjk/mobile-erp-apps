import 'package:flutter/material.dart';
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
  late ScanMode _mode = widget.scanMode;

  void _handleDetect(BarcodeCapture capture) {
    if (_hasScanned) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final value = barcodes.first.rawValue;
    if (value == null || value.trim().isEmpty) return;
    setState(() => _hasScanned = true);
    AppUi.safePop(context, value.trim());
  }

  Rect _scanWindow(Size size) {
    if (_mode == ScanMode.barcode) {
      final width = size.width * 0.84;
      const height = 150.0;
      return Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: width, height: height);
    }
    final side = size.width * 0.72;
    return Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: side, height: side);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
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
          return Stack(
            children: [
              MobileScanner(
                scanWindow: window,
                onDetect: _handleDetect,
              ),
              Positioned.fromRect(
                rect: window,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 3),
                      borderRadius: BorderRadius.circular(_mode == ScanMode.barcode ? 14 : 20),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: 36,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.68), borderRadius: BorderRadius.circular(14)),
                  child: Text(
                    '${widget.instruction}\nMode: ${_mode == ScanMode.barcode ? 'Barcode' : _mode == ScanMode.qr ? 'QR Code' : 'Auto'}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
