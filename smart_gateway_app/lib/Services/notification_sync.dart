// lib/services/notification_sync.dart
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../services/notification_center.dart';
import '../utils/appointment_reminders.dart' as ar;

class NotificationSync {
  static final NotificationSync _i = NotificationSync._();
  NotificationSync._();
  factory NotificationSync() => _i;

  Future<void> onAppointmentsFetched(
    List<Appointment> appts, {
    String? patientName,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    for (final a in appts) {
      // --- status change detection
      final statusKey = 'appt_status_${a.id}';
      final prevStatus = prefs.getString(statusKey);
      if (prevStatus != a.status) {
        await prefs.setString(statusKey, a.status);

        if (a.status == 'approved') {
          await NotificationCenter().push(
            title: 'Appointment approved',
            body: 'Your appointment on ${a.start} has been approved.',
            type: 'approved',
            appointmentId: a.id,
          );
          await ar.scheduleAppointmentReminders(
            appointmentId: a.id,
            appointmentStartLocal: a.start,
            patientName: patientName ?? 'Patient',
          );
        } else if (a.status == 'rejected') {
          await NotificationCenter().push(
            title: 'Appointment rejected',
            body: 'Your appointment on ${a.start} was rejected.',
            type: 'rejected',
            appointmentId: a.id,
          );
          await ar.cancelAppointmentReminders(a.id);
        } else if (a.status == 'completed') {
          await NotificationCenter().push(
            title: 'Appointment completed',
            body: 'Your appointment on ${a.start} is marked completed.',
            type: 'completed',
            appointmentId: a.id,
          );
          await ar.cancelAppointmentReminders(a.id);
        }
      }

      // --- completion via progress field (if your model uses it)
      final progressKey = 'appt_progress_${a.id}';
      final prevProg = prefs.getString(progressKey);
      if (prevProg != a.progress) {
        await prefs.setString(progressKey, a.progress);
        if (a.progress == 'completed') {
          await NotificationCenter().push(
            title: 'Appointment completed',
            body: 'Your appointment on ${a.start} is marked completed.',
            type: 'completed',
            appointmentId: a.id,
          );
          await ar.cancelAppointmentReminders(a.id);
        }
      }
    }
  }
}
