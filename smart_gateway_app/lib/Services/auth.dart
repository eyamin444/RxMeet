// lib/Services/auth.dart
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import '../models.dart';

class AuthService {
  /// Login using username (email/phone) and password.
  /// Ensures Api client is initialized (defensive) before performing the request.
  static Future<void> login(String username, String password) async {
    // Ensure Api client is ready
    if (!Api.isReady) {
      await Api.init();
    }

    final form = FormData.fromMap({
      'username': username,
      'password': password,
    });

    final res = await Api.post('/auth/login', data: form);

    if (res == null || res['access_token'] == null) {
      throw Exception('Login failed: invalid response from server');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', res['access_token']);

    // Optionally, set Api.currentUserId now by calling whoAmI.
    // But many callers call whoAmI immediately after login, so it's okay to leave that to whoAmI().
  }

  /// Return current user object (whoami).
  /// Ensures Api is initialized and sets Api.currentUserId for convenience.
  static Future<User> whoAmI() async {
    if (!Api.isReady) {
      await Api.init();
    }

    final res = await Api.get('/whoami');
    final user = User.fromJson(res);

    try {
      Api.currentUserId = user.id;
    } catch (_) {}

    return user;
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    // Clear cached currentUserId
    Api.currentUserId = null;
  }

  static Future<void> registerPatient({
    required String name,
    required String password,
    String? email,
    String? phone,
  }) async {
    if (!Api.isReady) {
      await Api.init();
    }

    await Api.post('/auth/register', data: {
      'name': name,
      'password': password,
      'email': email,
      'phone': phone,
    });
  }
}
