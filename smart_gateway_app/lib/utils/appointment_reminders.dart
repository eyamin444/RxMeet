// lib/utils/appointment_reminders.dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import '../main.dart' show notifications; // your FlutterLocalNotificationsPlugin instance

const String _channelId = 'appointments';
const String _channelName = 'Appointment Alerts';

Future<void> scheduleAppointmentReminders({
  required int appointmentId,
  required DateTime appointmentStartLocal,
  required String patientName,
}) async {
  final details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  // Fire 30 minutes before start
  final at = appointmentStartLocal.subtract(const Duration(minutes: 30));
  if (at.isAfter(DateTime.now())) {
    await notifications.zonedSchedule(
      appointmentId * 10 + 3, // distinct id namespace
      'Upcoming appointment',
      'Hi $patientName, your appointment starts in 30 minutes.',
      tz.TZDateTime.from(at, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: null, // keep broad compatibility
      
    );
  }
}

Future<void> cancelAppointmentReminders(int appointmentId) async {
  await notifications.cancel(appointmentId * 10 + 3);
}
