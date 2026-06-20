import 'dart:html' as html;
import 'dart:typed_data';

Future<bool> downloadBytesAsFile({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
}) async {
  final blob = html.Blob(<Object>[bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..setAttribute('aria-label', fileName)
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.window.console.log('XLSX download requested: $fileName');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  html.Url.revokeObjectUrl(url);
  return true;
}
