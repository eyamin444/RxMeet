// lib/Services/Api.dart
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';

/// Central API client used across the app.
/// - Call Api.init() once at app start (idempotent).
/// - Api.currentUserId can be used by the UI to detect "me".
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
  static Future<void> init({String? override}) async {
    if (_ready) return;
    const env = String.fromEnvironment('API_BASE_URL');
    _base = override ?? (env.isNotEmpty ? env : 'http://127.0.0.1:8000');

    _dio = Dio(
      BaseOptions(
        baseUrl: _base,
        connectTimeout: const Duration(seconds: 15),
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

  static Future<void> _ensureReady() async {
    if (!_ready) await init();
  }
// ✅ Multipart helper (authenticated because _dio has interceptor)
static Future<dynamic> postMultipart(String path, {required FormData formData}) async {
  await _ensureReady();

  final res = await _dio.post(
    path,
    data: formData,
    options: Options(contentType: 'multipart/form-data'),
  );

  return res.data;
}

  // -------------------------
  // Generic helpers
  // -------------------------
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
  static Future<Map<String, dynamic>> joinVideo(int appointmentId) async {
    final json = await post('/appointments/$appointmentId/video/token');
    return Map<String, dynamic>.from(json as Map);
  }

  // -------------------------
  // Chat helpers
  // -------------------------
  /// GET chat listing (newer endpoint)
  static Future<Map<String, dynamic>> getChatMessages(int appointmentId,
      {int page = 1, int pageSize = 200}) async {
    final res = await get('/appointments/$appointmentId/chat', query: {'page': page, 'page_size': pageSize});
    if (res is Map) return Map<String, dynamic>.from(res);
    return {'items': res};
  }

  /// Legacy messages listing (keeps compatibility)
  static Future<Map<String, dynamic>> getMessages(int appointmentId,
      {int page = 1, int pageSize = 100}) async {
    final res = await get('/appointments/$appointmentId/messages', query: {'page': page, 'page_size': pageSize});
    if (res is Map) return Map<String, dynamic>.from(res);
    return {'data': res};
  }

  /// Post a text message. Tries chat/send then falls back to /messages.
  static Future<Map<String, dynamic>> postMessage(int appointmentId, String body, {String kind = 'text'}) async {
    final payload = {'body': body, 'kind': kind};
    await _ensureReady();

    // First try the chat/send endpoint (returns { ok: true, message: {...} })
    try {
      final res = await _dio.post('/appointments/$appointmentId/chat/send', data: payload);
      final data = res.data;
      if (data is Map && data['message'] is Map) {
        return Map<String, dynamic>.from(data['message']);
      } else if (data is Map && (data.containsKey('id') || data.containsKey('message'))) {
        return Map<String, dynamic>.from(data);
      }
    } catch (e) {
      // If 404 or not found, fall back
      if (e is DioError) {
        final status = e.response?.statusCode ?? 0;
        if (status != 404) {
          // for other errors let caller handle
          rethrow;
        }
      } else {
        rethrow;
      }
    }

    // Fallback: try /appointments/{id}/messages
    final res2 = await post('/appointments/$appointmentId/messages', data: payload);
    if (res2 is Map && res2['message'] is Map) return Map<String, dynamic>.from(res2['message']);
    if (res2 is Map) return Map<String, dynamic>.from(res2);
    return {'id': '', 'body': body};
  }

  /// Upload an image (multipart). Tries /chat/send then /chat/upload fallback.
  static Future<Map<String, dynamic>> postImageMessage(
    int appointmentId,
    Uint8List bytes, {
    String filename = 'image.jpg',
    String? note,
  }) async {
    await _ensureReady();

    final mimeType = lookupMimeType(filename, headerBytes: bytes) ?? 'image/jpeg';
    final parts = mimeType.split('/');
    final contentType = MediaType(parts.first, parts.length > 1 ? parts[1] : 'jpeg');

    final form = FormData.fromMap({
      'kind': 'image',
      'body': note ?? '',
      'file': MultipartFile.fromBytes(bytes, filename: filename, contentType: contentType),
    });

    final endpoints = [
      '/appointments/$appointmentId/chat/send',
      '/appointments/$appointmentId/chat/upload',
    ];

    DioError? lastError;
    for (final ep in endpoints) {
      try {
        // IMPORTANT: do not set Content-Type header manually; let Dio add boundary
        final res = await _dio.post(ep, data: form);
        final data = res.data;
        if (data is Map && data['message'] is Map) {
          return Map<String, dynamic>.from(data['message']);
        } else if (data is Map) {
          return Map<String, dynamic>.from(data);
        } else {
          return {'id': '', 'file_path': ''};
        }
      } on DioError catch (e) {
        lastError = e;
        final status = e.response?.statusCode;
        final respBody = e.response?.data;
        print('[Api] upload to $ep failed: status=$status body=$respBody');
        if (status == 404) {
          // try next
          continue;
        }
        rethrow;
      }
    }

    if (lastError != null) {
      final status = lastError.response?.statusCode ?? 0;
      final body = lastError.response?.data?.toString() ?? lastError.message;
      throw DioError(
        requestOptions: lastError.requestOptions,
        response: lastError.response,
        error: 'Image upload failed (status $status): $body',
        type: lastError.type,
      );
    }

    return {'id': '', 'file_path': ''};
  }

  static Future<bool> markMessagesRead(int appointmentId) async {
    try {
      await post('/appointments/$appointmentId/messages/mark_read', data: {});
      return true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------
  // Helpers
  // -------------------------
  /// Helper for websocket base url (http->ws, https->wss)
  static String wsBaseUrl() {
    final b = baseUrl;
    if (b.startsWith('https://')) return 'wss://${b.substring('https://'.length)}';
    if (b.startsWith('http://')) return 'ws://${b.substring('http://'.length)}';
    return b;
  }

  /// Convert server file_path -> public URL (assumes server serves /uploads/)
  static String filePathToUrl(String? filePath) {
    if (filePath == null || filePath.isEmpty) return '';
    // normalize backslashes
    var p = filePath.replaceAll(r'\', '/');
    // If already a full URL
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    // Remove leading slash if present
    if (p.startsWith('/')) p = p.substring(1);
    final base = _base.endsWith('/') ? _base : '$_base/';
    return '$base$p';
  }
}
