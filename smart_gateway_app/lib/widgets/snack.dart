import 'package:flutter/material.dart';

void showSnack(BuildContext ctx, String msg) {
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
}
