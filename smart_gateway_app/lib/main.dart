import 'dart:async';
import 'package:flutter/material.dart';

import 'services/api.dart';
import 'services/auth.dart';
import 'models.dart';
import 'widgets/snack.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;

import 'app_config.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

// Aliases prevent naming clashes
import 'screens/admin/dashboard.dart' as admin show AdminDashboard;
import 'screens/doctor/dashboard.dart' as doctor show DoctorDashboard;
import 'screens/patient/dashboard.dart' as patient show PatientDashboard;

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(
    const InitializationSettings(android: androidInit),
  );

  // ---- Timezone: fixed to Asia/Dhaka ----
  tzdata.initializeTimeZones();
  // If you want **always** Asia/Dhaka:
  tz.setLocalLocation(tz.getLocation('Asia/Dhaka'));

  // If later you want dynamic device TZ instead:
  // final info = await FlutterTimezone.getLocalTimezone();
  // tz.setLocalLocation(tz.getLocation(info)); // info is String in latest versions

  final androidImpl = notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.requestNotificationsPermission();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await lk.LiveKitClient.initialize();
  await initNotifications();
  await Api.init(override: AppConfig.apiBaseUrl);
  runApp(const SmartGatewayApp());
}

class SmartGatewayApp extends StatelessWidget {
  const SmartGatewayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RxMeet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        typography: Typography.material2021(),
      ),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  User? me;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      me = await AuthService.whoAmI();
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (me == null) return const LoginPage();
    return HomeRouter(me: me!);
  }
}

class HomeRouter extends StatelessWidget {
  const HomeRouter({super.key, required this.me});
  final User me;

  @override
  Widget build(BuildContext context) {
    switch (me.role) {
      case 'admin':
        return admin.AdminDashboard(me: me);
      case 'doctor':
        return doctor.DoctorDashboard(me: me);
      default:
        return patient.PatientDashboard(me: me);
    }
  }
}

/// =====================
/// LOGIN + REGISTER PAGE
/// =====================

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final pass = TextEditingController();
  bool busy = false;

  void _prefill(String role) {
    if (role == 'patient') {
      email.text = 'patient1@test.com';
      pass.text = 'patientpass';
    } else if (role == 'doctor') {
      email.text = 'alice@clinic.tes';
      pass.text = 'alicepass';
    } else if (role == 'admin') {
      email.text = 'admin@example.com';
      pass.text = 'admin';
    }
  }

  Future<void> _login() async {
    setState(() => busy = true);
    try {
      await AuthService.login(email.text.trim(), pass.text);
      final me = await AuthService.whoAmI();
      if (context.mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => HomeRouter(me: me)),
        );
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'Login failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _ping() async {
    try {
      final pong = await Api.get('/ping');
      if (mounted) showSnack(context, 'API OK: $pong @ ${Api.baseUrl}');
    } catch (e) {
      if (mounted) {
        showSnack(
            context, 'API NOT REACHABLE @ ${Api.baseUrl}\n$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final double w =
        MediaQuery.of(context).size.width.clamp(320.0, 520.0).toDouble();
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Gateway — Login')),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: w),
          child: Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('API: ${Api.baseUrl}',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                FilledButton.icon(
                  onPressed: _ping,
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('Ping API'),
                ),
                const Divider(height: 24),
                TextField(
                  controller: email,
                  decoration: const InputDecoration(
                    labelText: 'Email or Phone',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _prefill('admin'),
                        child: const Text('Fill Admin'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _prefill('doctor'),
                        child: const Text('Fill Doctor'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _prefill('patient'),
                        child: const Text('Fill Patient'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy ? null : _login,
                  child: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Login'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const RegisterPage(),
                    ),
                  ),
                  child: const Text('Register as Patient'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();
  final pass = TextEditingController();
  bool busy = false;

  Future<void> _register() async {
    setState(() => busy = true);
    try {
      await AuthService.registerPatient(
        name: name.text,
        email: email.text.isEmpty ? null : email.text,
        phone: phone.text.isEmpty ? null : phone.text,
        password: pass.text,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Registered! Now login.')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Register failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double w =
        MediaQuery.of(context).size.width.clamp(320.0, 520.0).toDouble();
    return Scaffold(
      appBar: AppBar(title: const Text('Register (Patient)')),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: w),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: email,
                  decoration: const InputDecoration(
                    labelText: 'Email (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy ? null : _register,
                  child: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create account'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
