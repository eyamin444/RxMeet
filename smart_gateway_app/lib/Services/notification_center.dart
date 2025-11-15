// lib/services/notification_center.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart' show notifications;

class LocalNotice {
  final int id; // unique
  final String title;
  final String body;
  final DateTime at;
  final bool read;
  final String type; // 'approved'|'rejected'|'completed'|'reminder'
  final int? appointmentId;

  LocalNotice({
    required this.id,
    required this.title,
    required this.body,
    required this.at,
    this.read = false,
    required this.type,
    this.appointmentId,
  });

  LocalNotice copyWith({bool? read}) => LocalNotice(
        id: id,
        title: title,
        body: body,
        at: at,
        read: read ?? this.read,
        type: type,
        appointmentId: appointmentId,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'body': body,
        'at': at.toIso8601String(),
        'read': read,
        'type': type,
        'appointmentId': appointmentId,
      };

  static LocalNotice fromMap(Map<String, dynamic> m) => LocalNotice(
        id: m['id'] as int,
        title: m['title'] as String,
        body: m['body'] as String,
        at: DateTime.parse(m['at'] as String),
        read: m['read'] as bool? ?? false,
        type: m['type'] as String? ?? 'info',
        appointmentId: m['appointmentId'] as int?,
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

  Future<int> unreadCount() async =>
      (await _load()).where((e) => !e.read).length;

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

  Future<void> push({
    required String title,
    required String body,
    required String type,
    int? appointmentId,
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
        await notifications.show(
          id,
          title,
          body,
          const NotificationDetails(android: android),
        );
      }
    });
    return _lock;
  }
}
