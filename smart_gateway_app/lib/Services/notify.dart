\
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(const InitializationSettings(android: androidInit));

  tz.initializeTimeZones();
  final localTz = await FlutterTimezone.getLocalTimezone();
  tz.setLocalLocation(tz.getLocation(localTz));

  final androidImpl = notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.requestNotificationsPermission();
}

/// Schedule a notification at [when].
Future<void> scheduleOnce({
  required int id,
  required String title,
  required String body,
  required DateTime when,
}) async {
  await notifications.zonedSchedule(
    id,
    title,
    body,
    tz.TZDateTime.from(when, tz.local),
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'rxmeet_channel',
        'RxMeet Reminders',
        channelDescription: 'Appointment reminders',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
  );
}

/// Schedule reminders at T-1 day and T-1 hour for an appointment [at].
Future<void> scheduleAppointmentReminders({
  required int appointmentId,
  required DateTime at,
  required String doctorName,
}) async {
  final oneDayBefore = at.subtract(const Duration(days: 1));
  final oneHourBefore = at.subtract(const Duration(hours: 1));

  if (oneDayBefore.isAfter(DateTime.now())) {
    await scheduleOnce(
      id: appointmentId * 10 + 1,
      title: 'Appointment Tomorrow',
      body: 'You have an appointment with $doctorName tomorrow at ${at.hour.toString().padLeft(2,'0')}:${at.minute.toString().padLeft(2,'0')}.',
      when: oneDayBefore,
    );
  }
  if (oneHourBefore.isAfter(DateTime.now())) {
    await scheduleOnce(
      id: appointmentId * 10 + 2,
      title: 'Appointment in 1 hour',
      body: 'Your appointment with $doctorName starts in 1 hour.',
      when: oneHourBefore,
    );
  }
}
