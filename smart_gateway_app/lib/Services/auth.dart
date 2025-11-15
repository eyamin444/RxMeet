import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import '../models.dart';

class AuthService {
  static Future<void> login(String username, String password) async {
    final form = FormData.fromMap({
      'username': username,
      'password': password,
    });
    final res = await Api.post('/auth/login', data: form);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', res['access_token']);
  }

  static Future<User> whoAmI() async {
    final res = await Api.get('/whoami');
    return User.fromJson(res);
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
  }

  static Future<void> registerPatient({
    required String name,
    required String password,
    String? email,
    String? phone,
  }) async {
    await Api.post('/auth/register', data: {
      'name': name,
      'password': password,
      'email': email,
      'phone': phone,
    });
  }
}
