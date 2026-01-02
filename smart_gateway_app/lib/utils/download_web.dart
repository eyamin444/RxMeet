//lib\utils\download_web.dart
import 'dart:typed_data';
import 'dart:html' as html;

Future<void> downloadBytes(Uint8List bytes, String suggestedName) async {
  final blob = html.Blob([bytes]);
  final href = html.Url.createObjectUrlFromBlob(blob);
  final a = html.AnchorElement(href: href)..download = suggestedName;
  html.document.body?.append(a);
  a.click();
  a.remove();
  html.Url.revokeObjectUrl(href);
}

Future<void> openUrlExternal(String url) async {
  html.window.open(url, '_blank');
}
