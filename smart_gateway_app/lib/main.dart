// smart_gateway_app/lib/main.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

// App-specific imports
import 'services/api.dart';
import 'services/auth.dart';
import 'models.dart';
import 'widgets/snack.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:permission_handler/permission_handler.dart';

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

// Local notifications plugin instance (shared)
final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();

// Notification channel IDs
const String kDefaultChannelId = 'default_channel';
const String kCallsChannelId = 'calls_channel';

/// Background handler required by firebase_messaging. Keep top-level.
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // You can do minimal background handling if needed.
  print('FCM background message: ${message.messageId}, data: ${message.data}');
}

/// Initialize local notifications, timezone and channels.
Future<void> initNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');

  await notifications.initialize(
    const InitializationSettings(android: androidInit),
    // Optionally: onSelectNotification handler if you want to handle clicks
    // onDidReceiveNotificationResponse: (details) { ... },
  );

  // ---- Timezone ----
  tzdata.initializeTimeZones();
  // If you want to force Asia/Dhaka as previously:
  tz.setLocalLocation(tz.getLocation('Asia/Dhaka'));
  // If you prefer device timezone uncomment below:
  // final info = await FlutterTimezone.getLocalTimezone();
  // tz.setLocalLocation(tz.getLocation(info));

  // Create Android channels
  if (Platform.isAndroid) {
    final androidImpl = notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // Request permission for notifications on Android (useful on Android 13+)
    await androidImpl?.requestNotificationsPermission();

    // Default channel
    final defaultChannel = AndroidNotificationChannel(
      kDefaultChannelId,
      'General',
      description: 'General notifications',
      importance: Importance.defaultImportance,
    );

    final callChannel = AndroidNotificationChannel(
      kCallsChannelId,
      'Incoming Calls',
      description: 'Incoming call notifications that should be high-priority',
      importance: Importance.max,
      // set sound / vibration etc if you want a distinct sound or vibration pattern
    );

    try {
      await androidImpl?.createNotificationChannel(defaultChannel);
      await androidImpl?.createNotificationChannel(callChannel);
    } catch (e) {
      // ignore - some versions may throw if channel exists
      print('createNotificationChannel error: $e');
    }
  }
}

/// Helper to show a local notification. If `isCall` true, show high-priority full-screen style.
Future<void> showLocalNotification(RemoteMessage message, {bool isCall = false}) async {
  final data = message.data;
  final title = message.notification?.title ?? data['title'] ?? (isCall ? 'Incoming call' : 'Notification');
  final body = message.notification?.body ?? data['body'] ?? data['message'] ?? '';

  final androidDetails = AndroidNotificationDetails(
    isCall ? kCallsChannelId : kDefaultChannelId,
    isCall ? 'Incoming Calls' : 'General',
    channelDescription: isCall ? 'Incoming call notifications' : 'General notifications',
    importance: isCall ? Importance.max : Importance.high,
    priority: isCall ? Priority.high : Priority.high,
    playSound: true,
    // Show full-screen intent for calls (this will open your activity/route)
    fullScreenIntent: isCall,
    // Category call may help for some devices
    category: isCall ? AndroidNotificationCategory.call : AndroidNotificationCategory.message,
    // ticker: 'ticker',
  );

  final details = NotificationDetails(android: androidDetails);

  // Use message.messageId as id if present, else 0
  final id = (message.messageId != null) ? message.messageId.hashCode : DateTime.now().microsecond;

  await notifications.show(id, title, body, details, payload: data.isNotEmpty ? data.toString() : null);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Initialize LiveKit and local notifications
  await lk.LiveKitClient.initialize();
  await initNotifications();

  // Initialize API
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

  /// Bootstrap: get current user, register FCM (patients), and setup message listeners.
  Future<void> _bootstrap() async {
    try {
      // fetch current user
      me = await AuthService.whoAmI();
    } catch (_) {
      me = null;
    }

    // If user is a patient, request notification permission and register token
    if (me != null && me!.role == 'patient') {
      // Android 13+ notification runtime permission
      if (Platform.isAndroid) {
        try {
          var status = await Permission.notification.status;
          if (status.isDenied || status.isRestricted || status.isPermanentlyDenied) {
            // Request permission
            status = await Permission.notification.request();
            // if denied, still try to register token - device may still receive it
          }
        } catch (e) {
          // permission_handler might throw on some environments — ignore for now
          print('Permission request error: $e');
        }
      }

      // Register FCM token
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null && token.isNotEmpty) {
          await Api.post('/me/device_token', data: {'token': token});
          print('FCM token sent to server: $token');
        }
      } catch (e) {
        print('Failed to register FCM token: $e');
      }

      // Keep server updated on token refresh
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        try {
          await Api.post('/me/device_token', data: {'token': newToken});
          print('FCM token refreshed and sent: $newToken');
        } catch (e) {
          print('Failed to update refreshed FCM token: $e');
        }
      });
    }

    // Foreground messages: show local notification (and optionally UI)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final isCall = (message.data['type'] == 'doctor_call');
      print('FCM onMessage (foreground) received: ${message.data}');
      showLocalNotification(message, isCall: isCall);
    });

    // When the app is opened from a notification (tap)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('FCM onMessageOpenedApp with data: ${message.data}');
      if (message.data['type'] == 'doctor_call') {
        // navigate to appointment detail
        final apptId = message.data['appointment_id'];
        if (apptId != null && apptId.toString().isNotEmpty && mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _AppointmentDetailPage(apptId: int.parse(apptId)),
            ),
          );
        }
      } else {
        // handle other notification tap types if needed
      }
    });

    // Also handle case app opened by a terminated state via getInitialMessage
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null && initialMessage.data['type'] == 'doctor_call') {
      final apptId = initialMessage.data['appointment_id'];
      if (apptId != null && apptId.toString().isNotEmpty) {
        // delay navigation until after build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => _AppointmentDetailPage(apptId: int.parse(apptId)),
              ),
            );
          }
        });
      }
    }

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
        showSnack(context, 'API NOT REACHABLE @ ${Api.baseUrl}\n$e');
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
                Text('API: ${Api.baseUrl}', style: Theme.of(context).textTheme.bodySmall),
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
                    Expanded(child: OutlinedButton(onPressed: () => _prefill('admin'), child: const Text('Fill Admin'))),
                    const SizedBox(width: 8),
                    Expanded(child: OutlinedButton(onPressed: () => _prefill('doctor'), child: const Text('Fill Doctor'))),
                    const SizedBox(width: 8),
                    Expanded(child: OutlinedButton(onPressed: () => _prefill('patient'), child: const Text('Fill Patient'))),
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
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterPage())),
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Registered! Now login.')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Register failed: $e')));
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
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(controller: email, decoration: const InputDecoration(labelText: 'Email (optional)', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone (optional)', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                FilledButton(onPressed: busy ? null : _register, child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Create account')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// NOTE: _AppointmentDetailPage is referenced above (you already have this in repo).
// If it's named differently in your project, adjust the navigation target accordingly.
