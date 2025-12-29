// lib/screens/notifications/incoming_call.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../../Services/Api.dart';
import '../../widgets/snack.dart';
import '../../services/ringtone.dart';
import '../video/video_screen.dart';
import '../../services/notification_center.dart';

class IncomingCallPage extends StatefulWidget {
  final int appointmentId;
  final String room;
  final String doctorName;
  final int? callLogId;

  const IncomingCallPage({
    super.key,
    required this.appointmentId,
    required this.room,
    required this.doctorName,
    this.callLogId,
  });

  @override
  State<IncomingCallPage> createState() => _IncomingCallPageState();
}

class _IncomingCallPageState extends State<IncomingCallPage> {
  bool _joining = false;
  StreamSubscription<LocalNotice>? _noticeSub;
  bool _closedByRemote = false; // to avoid double-close race
  bool _ringPlaying = false;

  @override
  void initState() {
    super.initState();

    // Initialize ringtone service and perform a short "unlock" play to acquire audio focus.
    // Run in async closure so initState is not async.
    () async {
      try {
        await RingtoneService.init();
        await RingtoneService.unlockAudioOnce();
        await RingtoneService.playLooping();
        _ringPlaying = true;
      } catch (e) {
        debugPrint('IncomingCallPage: ringtone init/play failed: $e');
      }
    }();

    // Subscribe to NotificationCenter push stream so we can close if call ended remotely
    _noticeSub = NotificationCenter().pushStream.listen((LocalNotice notice) {
      try {
        if (notice.type == 'video_end' || notice.type == 'call_end' || notice.type == 'missed_call') {
          if (notice.appointmentId == widget.appointmentId) {
            // If callLogId present, match it (preferred). Otherwise, match appointment.
            if (widget.callLogId != null) {
              if (notice.callLogId != null && notice.callLogId == widget.callLogId) {
                _closeBecauseRemote();
              } else {
                // If notice has no callLogId, still assume appointment-level end should close
                _closeBecauseRemote();
              }
            } else {
              // No callLogId on the incoming page; close for appointment-level end.
              _closeBecauseRemote();
            }
          }
        }
      } catch (e) {
        debugPrint('IncomingCallPage _noticeSub error: $e');
      }
    });
  }

  void _closeBecauseRemote() {
    if (_closedByRemote) return;
    _closedByRemote = true;
    // Stop ringtone, pop UI
    () async {
      try {
        await RingtoneService.stop();
      } catch (_) {}
      if (mounted) Navigator.of(context).pop();
    }();
  }

  Future<void> _acceptCall() async {
    setState(() => _joining = true);
    try {
      try {
        if (_ringPlaying) {
          await RingtoneService.stop();
          _ringPlaying = false;
        }
      } catch (_) {}

      // Ensure Api init
      try {
        if (!Api.isReady) await Api.init();
      } catch (e) {
        debugPrint('IncomingCallPage: Api.init failed: $e');
      }

      // Tell server we answered (if call log exists)
      if (widget.callLogId != null) {
        try {
          await Api.post(
            '/appointments/${widget.appointmentId}/call/answer',
            data: {'call_log_id': widget.callLogId.toString()},
          );
        } catch (e) {
          debugPrint('IncomingCallPage: call/answer warning: $e');
        }
      }

      // Request video token and join info
      final resp = await Api.post('/appointments/${widget.appointmentId}/video/token');
      final url = resp['url'] as String?;
      final token = resp['token'] as String?;
      if (url == null || token == null) throw Exception('Missing token/url');

      if (!mounted) return;
      // Navigate into VideoScreen which auto-joins
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => VideoScreen(
            appointmentId: widget.appointmentId,
            isDoctor: false,
          ),
        ),
      );
    } catch (e) {
      showSnack(context, 'Failed to join call: $e');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _declineCall() async {
    // stop ringtone
    try {
      if (_ringPlaying) {
        await RingtoneService.stop();
        _ringPlaying = false;
      }
    } catch (_) {}

    // notify server (ensure we only call once)
    try {
      if (!Api.isReady) await Api.init();
      await Api.post('/appointments/${widget.appointmentId}/call/end',
          data: {
            'call_log_id': widget.callLogId?.toString(),
            'duration': '0',
          });
    } catch (e) {
      debugPrint('IncomingCallPage: call/end failed: $e');
    }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _noticeSub?.cancel();
    // ensure ringtone is stopped
    try {
      RingtoneService.stop();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Incoming call')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(widget.doctorName, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('is calling you', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                onPressed: _joining ? null : _acceptCall,
                icon: const Icon(Icons.call),
                label: _joining
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Accept'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: _declineCall,
                icon: const Icon(Icons.call_end),
                label: const Text('Decline'),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}
