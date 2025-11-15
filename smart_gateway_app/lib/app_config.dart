import 'package:flutter/foundation.dart';

class AppConfig {
  /// Priority:
  /// 1) --dart-define=API_BASE_URL=...
  /// 2) On web: http://<current-host>:8000  (so Chrome → http://localhost:8000)
  /// 3) Otherwise: http://127.0.0.1:8000  (pairs well with `adb reverse`)
  static String get apiBaseUrl {
    const defined = String.fromEnvironment('API_BASE_URL');
    if (defined.isNotEmpty) return defined;

    if (kIsWeb) {
      final host = Uri.base.host; // e.g., localhost or 127.0.0.1
      final h = (host.isEmpty || host == '0.0.0.0') ? '127.0.0.1' : host;
      return 'http://$h:8000';
    }

    return 'http://127.0.0.1:8000';
  }
}
