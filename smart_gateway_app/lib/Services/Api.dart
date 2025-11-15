// lib/Services/api.dart
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Api {
  static late Dio _dio;
  static late String _base;

  /// Call once at app start (e.g. in main()).
  ///
  /// Priority for base URL:
  /// 1) [override] parameter
  /// 2) --dart-define=API_BASE_URL=...
  /// 3) Fallback "http://127.0.0.1:8000"
  static Future<void> init({String? override}) async {
    const env = String.fromEnvironment('API_BASE_URL');
    _base = override ?? (env.isNotEmpty ? env : 'http://127.0.0.1:8000');

    _dio = Dio(
      BaseOptions(
        baseUrl: _base,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 30),
        headers: const {
          'Content-Type': 'application/json',
        },
      ),
    );

    // Attach auth header from SharedPreferences on every request.
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final prefs = await SharedPreferences.getInstance();
          final tok = prefs.getString('token');
          if (tok != null && tok.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $tok';
          }
          handler.next(options);
        },
      ),
    );
  }

  static String get baseUrl => _base;

  /// Optional direct access to Dio if you ever need it.
  static Dio get client => _dio;

  // ---------------------------------------------------------------------------
  // Token helpers
  // ---------------------------------------------------------------------------

  static Future<void> setToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await prefs.remove('token');
    } else {
      await prefs.setString('token', token);
    }
  }

  // ---------------------------------------------------------------------------
  // Generic helpers
  // ---------------------------------------------------------------------------

  /// Simple health-check. Expects FastAPI `/ping` -> `{ "ok": true }`
  static Future<bool> ping() async {
    try {
      final res = await _dio.get('/ping');
      final data = res.data;
      if (data is Map && data['ok'] == true) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final res = await _dio.get(path, queryParameters: query);
    return res.data;
  }

  static Future<Uint8List> getBytes(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final res = await _dio.get<List<int>>(
      path,
      queryParameters: query,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(res.data ?? const <int>[]);
  }

  static Future<dynamic> post(
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    bool multipart = false,
    bool formUrlEncoded = false,
  }) async {
    final res = await _dio.post(
      path,
      data: data,
      queryParameters: query,
      options: multipart
          ? Options(contentType: 'multipart/form-data')
          : formUrlEncoded
              ? Options(contentType: Headers.formUrlEncodedContentType)
              : null,
    );
    return res.data;
  }

  static Future<dynamic> patch(
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
  }) async {
    final res = await _dio.patch(
      path,
      data: data,
      queryParameters: query,
    );
    return res.data;
  }

  static Future<dynamic> put(
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
  }) async {
    final res = await _dio.put(
      path,
      data: data,
      queryParameters: query,
    );
    return res.data;
  }

  static Future<dynamic> delete(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final res = await _dio.delete(
      path,
      queryParameters: query,
    );
    return res.data;
  }

  // ---------------------------------------------------------------------------
  // Business-level helpers
  // ---------------------------------------------------------------------------

  /// Join LiveKit video for a specific appointment.
  ///
  /// Backend endpoint: `POST /appointments/{id}/video/token`
  /// Expected response:
  /// `{ ok, url, room, token, identity, display_name }`
  static Future<Map<String, dynamic>> joinVideo(int appointmentId) async {
    final json = await post('/appointments/$appointmentId/video/token');
    return Map<String, dynamic>.from(json as Map);
  }
}
