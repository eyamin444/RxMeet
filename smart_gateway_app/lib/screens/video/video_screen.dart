// lib/screens/video/video_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../Services/Api.dart';
import '../../services/notification_center.dart';

class VideoScreen extends StatefulWidget {
  final int appointmentId;
  final bool isDoctor;

  const VideoScreen({
    super.key,
    required this.appointmentId,
    required this.isDoctor,
  });

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  Future<Map<String, dynamic>>? _future;
  lk.Room? _room;

  Timer? _callTimer;
  Timer? _participantWatcher;

  Duration _callDuration = Duration.zero;

  /// online flags
  bool doctorOnline = false;
  bool patientOnline = false;

  bool _timerStarted = false;

  double pipTop = 24;
  double pipRight = 16;

  @override
  void initState() {
    super.initState();
    _future = _loadJoinPayload();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    _callTimer?.cancel();
    _participantWatcher?.cancel();
    _room?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<Map<String, dynamic>> _loadJoinPayload() async {
    if (!Api.isReady) await Api.init();
    return Api.joinVideo(widget.appointmentId);
  }

  // ---------------- TIMER ----------------
  void _startCallTimerOnce() {
    if (_timerStarted) return;
    _timerStarted = true;

    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _callDuration += const Duration(seconds: 1);
      });
    });
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ---------------- CONNECT ----------------
  Future<void> _connect(String wsUrl, String token) async {
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
      ),
    );

    await room.connect(wsUrl, token);
    await room.localParticipant?.setCameraEnabled(true);
    await room.localParticipant?.setMicrophoneEnabled(true);

    _room = room;

   if (widget.isDoctor) {
  doctorOnline = true;

  // Tell the backend that the doctor has joined and ask the server to notify
  // the patient(s). The server should send a data-only FCM with type='doctor_call'
  // so the patient app will open the IncomingCallPage.
  try {
    await Api.post('/appointments/${widget.appointmentId}/call/start', data: {});
  } catch (e) {
    // If backend notification fails, fallback to a local notice for the doctor only.
    // (This keeps doctor informed but won't disturb patient flow.)
    print('Failed to notify backend to start call: $e');
    await NotificationCenter().push(
      title: 'Doctor is ready (local)',
      body: 'Doctor is ready, but notifying patient failed.',
      type: 'video_ready',
      appointmentId: widget.appointmentId,
    );
  }
} else {
  patientOnline = true;
}


    _startParticipantWatcher();

    if (mounted) setState(() {});
  }

  // ---------------- PARTICIPANT WATCHER ----------------
  void _startParticipantWatcher() {
    _participantWatcher?.cancel();
    _participantWatcher =
        Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_room == null) return;

      final hasRemote = _room!.remoteParticipants.isNotEmpty;

      /// both online → start timer
      if (hasRemote && !_timerStarted) {
        _startCallTimerOnce();
      }

      /// when patient joins, doctor is already online
      if (!widget.isDoctor && hasRemote && doctorOnline) {
        patientOnline = true;
      }
    });
  }

  // ---------------- VIDEO TILE ----------------
  Widget _videoTile(lk.TrackPublication pub, {bool mirror = false}) {
    final track = pub.track;
    if (track is! lk.VideoTrack) return const SizedBox();

    return lk.VideoTrackRenderer(
      track,
      fit: lk.VideoViewFit.contain,
      mirrorMode:
          mirror ? lk.VideoViewMirrorMode.mirror : lk.VideoViewMirrorMode.off,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snap.data!;
          if (data['ok'] != true) {
            return const Center(child: Text('Unable to join call'));
          }

          final wsUrl = data['url'] as String;
          final token = data['token'] as String;

          // ================= PRE JOIN =================
          if (_room == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.isDoctor
                          ? 'Start Video Consultation'
                          : doctorOnline
                              ? 'Doctor is ready'
                              : 'Waiting for Doctor',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (!widget.isDoctor && doctorOnline)
                      const Text(
                        'Your doctor is already online',
                        style: TextStyle(color: Colors.greenAccent),
                      ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => _connect(wsUrl, token),
                      icon: const Icon(Icons.video_call),
                      label: const Text('Join Video Call'),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                    ),
                  ],
                ),
              ),
            );
          }

          // ================= IN CALL =================
          lk.TrackPublication? remoteVideo;
          for (final p in _room!.remoteParticipants.values) {
            for (final pub in p.videoTrackPublications) {
              if (pub.subscribed) {
                remoteVideo = pub;
                break;
              }
            }
          }

          lk.TrackPublication? localVideo;
          final lp = _room!.localParticipant;
          if (lp != null) {
            for (final pub in lp.videoTrackPublications) {
              if (!pub.muted) localVideo = pub;
            }
          }

          return Stack(
            children: [
              Positioned.fill(
                child: remoteVideo == null
                    ? const Center(
                        child: Text(
                          'Waiting for participant…',
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : _videoTile(remoteVideo),
              ),

              // timer
              Positioned(
                top: 40,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _fmt(_callDuration),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),

              if (localVideo != null)
                Positioned(
                  top: pipTop,
                  right: pipRight,
                  width: 140,
                  height: 200,
                  child: GestureDetector(
                    onPanUpdate: (d) {
                      setState(() {
                        pipTop += d.delta.dy;
                        pipRight -= d.delta.dx;
                      });
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        decoration: BoxDecoration(
                          border:
                              Border.all(color: Colors.white, width: 2),
                        ),
                        child: _videoTile(localVideo, mirror: true),
                      ),
                    ),
                  ),
                ),

              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    color: Colors.black54,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          icon: Icon(
                            _room!.localParticipant!.isMicrophoneEnabled()
                                ? Icons.mic
                                : Icons.mic_off,
                            color: Colors.white,
                          ),
                          onPressed: () async {
                            final lp = _room!.localParticipant!;
                            await lp.setMicrophoneEnabled(
                                !lp.isMicrophoneEnabled());
                            setState(() {});
                          },
                        ),
                        IconButton(
                          icon: Icon(
                            _room!.localParticipant!.isCameraEnabled()
                                ? Icons.videocam
                                : Icons.videocam_off,
                            color: Colors.white,
                          ),
                          onPressed: () async {
                            final lp = _room!.localParticipant!;
                            await lp.setCameraEnabled(
                                !lp.isCameraEnabled());
                            setState(() {});
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.call_end, color: Colors.red),
                          onPressed: () async {
                            _callTimer?.cancel();

                            await NotificationCenter().push(
                              title: 'Video call ended',
                              body: 'Duration: ${_fmt(_callDuration)}',
                              type: 'video_end',
                              appointmentId: widget.appointmentId,
                              alsoShowSystemToast: false,
                            );

                            await _room!.disconnect();
                            setState(() => _room = null);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
