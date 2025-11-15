import 'dart:typed_data';
import 'package:printing/printing.dart';

Future<void> printPdfBytes(Uint8List bytes) async {
  await Printing.layoutPdf(onLayout: (format) async => bytes);
}
