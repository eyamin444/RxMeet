// lib/services/notification_center.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show notifications, navigatorKey;
import 'ringtone.dart' show RingtoneService;
import '../screens/notifications/incoming_call.dart' show IncomingCallPage;
import '../services/auth.dart' show AuthService; // use AuthService to get current user
import '../models.dart' show User; // for typing the returned user, if needed

class LocalNotice {
  final int id; // unique
  final String title;
  final String body;
  final DateTime at;
  final bool read;
  final String type; // 'approved'|'rejected'|'completed'|'reminder'|'video_ready' etc
  final int? appointmentId;
  final String? room;
  final int? callLogId;

  LocalNotice({
    required this.id,
    required this.title,
    required this.body,
    required this.at,
    this.read = false,
    required this.type,
    this.appointmentId,
    this.room,
    this.callLogId,
  });

  LocalNotice copyWith({bool? read}) => LocalNotice(
        id: id,
        title: title,
        body: body,
        at: at,
        read: read ?? this.read,
        type: type,
        appointmentId: appointmentId,
        room: room,
        callLogId: callLogId,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'body': body,
        'at': at.toIso8601String(),
        'read': read,
        'type': type,
        'appointmentId': appointmentId,
        'room': room,
        'callLogId': callLogId,
      };

  static LocalNotice fromMap(Map<String, dynamic> m) => LocalNotice(
        id: m['id'] as int,
        title: m['title'] as String,
        body: m['body'] as String,
        at: DateTime.parse(m['at'] as String),
        read: m['read'] as bool? ?? false,
        type: m['type'] as String? ?? 'info',
        appointmentId: m['appointmentId'] as int?,
        room: m['room'] as String?,
        callLogId: m['callLogId'] as int?,
      );
}

class NotificationCenter {
  static final NotificationCenter _i = NotificationCenter._();
  NotificationCenter._();
  factory NotificationCenter() => _i;

  static const _k = 'local_notices_v1';

  /// Serialize all mutations to avoid lost updates (e.g., delete racing with push).
  static Future<void> _lock = Future.value();

  final _unread$ = StreamController<int>.broadcast();
  Stream<int> get unreadCountStream => _unread$.stream;

  Future<List<LocalNotice>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_k);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List)
        .map((e) => LocalNotice.fromMap((e as Map).cast<String, dynamic>()))
        .toList();
    return list;
  }

  Future<void> _save(List<LocalNotice> items) async {
    final prefs = await SharedPreferences.getInstance();
    // Dedup by (id) for safety
    final seen = <int>{};
    final dedup = <LocalNotice>[];
    for (final n in items) {
      if (seen.add(n.id)) dedup.add(n);
    }
    await prefs.setString(
      _k,
      jsonEncode(dedup.map((e) => e.toMap()).toList()),
    );
    _unread$.add(dedup.where((e) => !e.read).length);
  }

  Future<int> unreadCount() async => (await _load()).where((e) => !e.read).length;

  Future<List<LocalNotice>> list() async => await _load();

  // --- Mutations (serialized) ---
  Future<void> markAllRead() {
    _lock = _lock.then((_) async {
      final list = await _load();
      await _save([for (final n in list) n.copyWith(read: true)]);
    });
    return _lock;
  }

  Future<void> markRead(int id) {
    _lock = _lock.then((_) async {
      final list = await _load();
      await _save([
        for (final n in list) n.id == id ? n.copyWith(read: true) : n
      ]);
    });
    return _lock;
  }

  Future<void> delete(int id) {
    _lock = _lock.then((_) async {
      final list = await _load();
      await _save(list.where((n) => n.id != id).toList());
    });
    return _lock;
  }

  Future<void> deleteMany(Set<int> ids) {
    _lock = _lock.then((_) async {
      final list = await _load();
      await _save(list.where((n) => !ids.contains(n.id)).toList());
    });
    return _lock;
  }

  Future<void> clear() {
    _lock = _lock.then((_) async {
      await _save(const []);
    });
    return _lock;
  }

  /// Push a notification into the local store and optionally show a system toast.
  Future<void> push({
    required String title,
    required String body,
    required String type,
    int? appointmentId,
    String? room,
    int? callLogId,
    bool alsoShowSystemToast = true,
  }) {
    _lock = _lock.then((_) async {
      final now = DateTime.now();
      final id = now.millisecondsSinceEpoch % 0x7fffffff;

      // Always re-load inside the lock to merge with latest state
      final list = await _load();
      final next = [
        LocalNotice(
          id: id,
          title: title,
          body: body,
          at: now,
          read: false,
          type: type,
          appointmentId: appointmentId,
          room: room,
          callLogId: callLogId,
        ),
        ...list,
      ];
      await _save(next);

      if (alsoShowSystemToast) {
        const android = AndroidNotificationDetails(
          'events',
          'In-app events',
          importance: Importance.high,
          priority: Priority.high,
        );
        try {
          await notifications.show(
            id,
            title,
            body,
            const NotificationDetails(android: android),
          );
        } catch (e) {
          // ignore local notification errors
          print('NotificationCenter: notifications.show error: $e');
        }
      }

      // handle special call/type that should open IncomingCallPage for patients only
      if (type == 'video_ready' || type == 'doctor_call') {
        try {
          final nav = navigatorKey.currentState;
          if (nav == null) return;

          // Obtain current user info asynchronously using AuthService.whoAmI().
          // If it fails, default to showing the incoming UI (safe behavior).
          bool isDoctor = false;
          try {
            final User? user = await AuthService.whoAmI();
            if (user != null && user.role != null && user.role == 'doctor') {
              isDoctor = true;
            }
          } catch (_) {
            isDoctor = false;
          }

          if (!isDoctor) {
            // Open incoming call UI for patients only.
            nav.push(MaterialPageRoute(
              builder: (_) => IncomingCallPage(
                appointmentId: appointmentId ?? 0,
                room: room ?? '',
                doctorName: title,
                callLogId: callLogId,
              ),
            ));
            // IncomingCallPage will start ringtone in its initState.
          } else {
            // Doctor: do not open incoming UI; log and keep local notice instead.
            print('NotificationCenter: doctor received call-notice; not opening IncomingCallPage.');
            // Optional: show a tiny local toast for doctor only (no ringtone)
            try {
              await notifications.show(
                id + 1,
                'Call initiated',
                'Patient(s) will be notified',
                const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'events',
                    'In-app events',
                    importance: Importance.low,
                    priority: Priority.low,
                  ),
                ),
              );
            } catch (_) {}
          }
        } catch (e) {
          print('NotificationCenter: failed to handle call UI: $e');
        }
      }
    });
    return _lock;
  }
}
