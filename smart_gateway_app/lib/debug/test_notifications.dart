import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../main.dart' show notifications;

class TestNotificationsPanel extends StatelessWidget {
  const TestNotificationsPanel({super.key});

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      'test_channel',
      'Test Notifications',
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  Future<void> _showNow(BuildContext context) async {
    await notifications.show(
      900,
      'RxMeet – Test',
      'Immediate notification.',
      _details,
    );
    _snack(context, 'Immediate notification sent.');
  }

  Future<void> _inOneMinute(BuildContext context) async {
    final when = DateTime.now().add(const Duration(minutes: 1));
    await notifications.zonedSchedule(
      901,
      'RxMeet – Test (1 min)',
      'This will appear about 1 minute from now.',
      tz.TZDateTime.from(when, tz.local),
      _details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
    _snack(context, 'Scheduled for 1 minute from now.');
  }

  Future<void> _cancelAll(BuildContext context) async {
    await notifications.cancelAll();
    _snack(context, 'All notifications canceled.');
  }

  void _snack(BuildContext c, String msg) =>
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            const Text('RxMeet – Notification Test', style: TextStyle(fontWeight: FontWeight.bold)),
            ElevatedButton(
              onPressed: () => _showNow(context),
              child: const Text('Show now'),
            ),
            ElevatedButton(
              onPressed: () => _inOneMinute(context),
              child: const Text('In 1 minute'),
            ),
            TextButton(
              onPressed: () => _cancelAll(context),
              child: const Text('Cancel all'),
            ),
          ],
        ),
      ),
    );
  }
}
