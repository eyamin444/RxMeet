//lib\utils\download_stub.dart
import 'dart:typed_data';

Future<void> downloadBytes(Uint8List bytes, String suggestedName) async {
  throw UnsupportedError('downloadBytes is not supported on this platform.');
}

Future<void> openUrlExternal(String url) async {
  throw UnsupportedError('openUrlExternal is not supported on this platform.');
}
