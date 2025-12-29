// lib/Services/Api.dart
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Central API client used across the app.
/// - Defensive: callers may call Api.init() again; post/get call init if missed.
/// - Exposes Api.currentUserId so UI code can detect "me".
class Api {
  static late Dio _dio;
  static late String _base;
  static bool _ready = false;

  /// Public fields
  static bool get isReady => _ready;
  static String get baseUrl => _base;
  static Dio get client => _dio;

  /// Optional helper so UI code can quickly tell "is this message mine?"
  static int? currentUserId;

  /// Initialize the API client. Call once at app start.
  /// You can call multiple times; the implementation is idempotent.
  static Future<void> init({String? override}) async {
    if (_ready) return;
    const env = String.fromEnvironment('API_BASE_URL');
    _base = override ?? (env.isNotEmpty ? env : 'http://127.0.0.1:8000');

    _dio = Dio(
      BaseOptions(
        baseUrl: _base,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 30),
        headers: const {'Content-Type': 'application/json'},
      ),
    );

    // Attach interceptor to add Authorization header (if token present).
    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final tok = prefs.getString('token');
          if (tok != null && tok.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $tok';
          }
        } catch (_) {
          // ignore
        }
        handler.next(options);
      }),
    );

    _ready = true;
  }

  // -------------------------
  // Generic helpers (defensive)
  // -------------------------
  static Future<void> _ensureReady() async {
    if (!_ready) {
      await init();
    }
  }

  static Future<bool> ping() async {
    try {
      await _ensureReady();
      final res = await _dio.get('/ping');
      final data = res.data;
      return data is Map && data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    await _ensureReady();
    final res = await _dio.get(path, queryParameters: query);
    return res.data;
  }

  static Future<Uint8List> getBytes(String path, {Map<String, dynamic>? query}) async {
    await _ensureReady();
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
    await _ensureReady();
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

  static Future<dynamic> patch(String path, {dynamic data, Map<String, dynamic>? query}) async {
    await _ensureReady();
    final res = await _dio.patch(path, data: data, queryParameters: query);
    return res.data;
  }

  static Future<dynamic> put(String path, {dynamic data, Map<String, dynamic>? query}) async {
    await _ensureReady();
    final res = await _dio.put(path, data: data, queryParameters: query);
    return res.data;
  }

  static Future<dynamic> delete(String path, {Map<String, dynamic>? query}) async {
    await _ensureReady();
    final res = await _dio.delete(path, queryParameters: query);
    return res.data;
  }

  // -------------------------
  // Business helpers
  // -------------------------

  /// LiveKit video token mint
  /// Backend: POST /appointments/{id}/video/token
  /// Returns: { ok, url, room, token, identity, display_name }
  static Future<Map<String, dynamic>> joinVideo(int appointmentId) async {
    final json = await post('/appointments/$appointmentId/video/token');
    return Map<String, dynamic>.from(json as Map);
  }

  // -------------------------
  // Chat helpers
  // -------------------------
  //
  // API expectations:
  // GET  /appointments/{id}/messages?page=1&page_size=50
  // POST /appointments/{id}/messages  { body: "...", kind: "text" }
  // POST /appointments/{id}/messages/mark_read

  /// Fetch messages for an appointment (paged). Returns server object or list.
  static Future<Map<String, dynamic>> getMessages(int appointmentId,
      {int page = 1, int pageSize = 100}) async {
    final res = await get('/appointments/$appointmentId/messages',
        query: {'page': page, 'page_size': pageSize});
    // Ensure it's a Map
    if (res is Map) return Map<String, dynamic>.from(res);
    return {'data': res};
  }

  /// Post a chat message. Returns the created message object.
  static Future<Map<String, dynamic>> postMessage(int appointmentId, String body,
      {String kind = 'text'}) async {
    final payload = {'body': body, 'kind': kind};
    final res = await post('/appointments/$appointmentId/messages', data: payload);
    return Map<String, dynamic>.from(res as Map);
  }

  /// Mark messages read for this appointment (server-side). Often no body required.
  static Future<bool> markMessagesRead(int appointmentId) async {
    try {
      await post('/appointments/$appointmentId/messages/mark_read', data: {});
      return true;
    } catch (_) {
      return false;
    }
  }
}
