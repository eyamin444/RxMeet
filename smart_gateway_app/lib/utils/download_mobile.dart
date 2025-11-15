import 'dart:typed_data';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> downloadBytes(Uint8List bytes, String suggestedName) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$suggestedName');
  await file.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles([XFile(file.path, name: suggestedName)]);
}

Future<void> openUrlExternal(String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok) throw 'Could not launch $url';
}
