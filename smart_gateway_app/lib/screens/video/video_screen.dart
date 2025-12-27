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
  bool _connecting = false; // show spinner while connecting
  bool _autoJoinStarted = false; // ensure we only auto-join once

  double pipTop = 24;
  double pipRight = 16;

  // Listen for push events (e.g., video_end)
  StreamSubscription<LocalNotice>? _noticeSub;

  // track whether there was a remote participant previously so we can detect remote-leave
  bool _hadRemote = false;

  // NEW: track whether this appointment call has been ended/closed.
  // When true we NEVER show the Join button again.
  bool _callEnded = false;

  @override
  void initState() {
    super.initState();
    _future = _loadJoinPayload();
    WakelockPlus.enable();

    // Listen for server pushes (video_end, etc.)
    _noticeSub = NotificationCenter().pushStream.listen(_handlePushNotice);

    // Start async auto-join once token arrives
    _future!.then((data) {
      // auto-join once token is available
      if (!_autoJoinStarted && !_callEnded) {
        _autoJoinStarted = true;
        _startAutoJoin(data);
      }
    }).catchError((e) {
      // ignore - handled by FutureBuilder too
      print('VideoScreen: _future error: $e');
    });
  }

  Future<void> _startAutoJoin(Map<String, dynamic> data) async {
    if (_callEnded) return; // guard: don't auto-join if call already ended
    final wsUrl = data['url'] as String?;
    final token = data['token'] as String?;
    if (wsUrl == null || token == null) return;
    // don't block UI; show spinner and connect
    setState(() => _connecting = true);
    try {
      await _connect(wsUrl, token);
    } catch (e) {
      // No automatic retry. Show a snack and leave screen so user can retry manually if desired.
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to join call: $e')));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  void dispose() {
    _callTimer?.cancel();
    _participantWatcher?.cancel();
    _noticeSub?.cancel();
    _room?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<Map<String, dynamic>> _loadJoinPayload() async {
    if (!Api.isReady) await Api.init();
    // joinVideo returns {ok:true, url:..., token:...}
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
    // If call already ended, do not connect
    if (_callEnded) throw 'Call already ended';

    // If we're already connected, ignore
    if (_room != null) return;

    // Create the room
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
      ),
    );

    // Connect with timeout to avoid long waiting periods (no auto retry).
    try {
      // Connect with 10s timeout
      await room.connect(wsUrl, token).timeout(const Duration(seconds: 10));
    } on TimeoutException catch (e) {
      await room.dispose();
      throw 'Connection timeout';
    } catch (e) {
      await room.dispose();
      rethrow;
    }

    // enable camera and mic (best-effort)
    try {
      await room.localParticipant?.setCameraEnabled(true);
    } catch (_) {}
    try {
      await room.localParticipant?.setMicrophoneEnabled(true);
    } catch (_) {}

    _room = room;

    // --- DOCTOR vs PATIENT behavior
    if (widget.isDoctor) {
      doctorOnline = true;

      try {
        print(
            'VIDEO_SCREEN: doctor connecting -> will notify backend for appt ${widget.appointmentId}');
        final resp =
            await Api.post('/appointments/${widget.appointmentId}/call/start',
                data: {});
        print('VIDEO_SCREEN: backend call/start response: $resp');
      } catch (e, st) {
        // If backend call fails, still keep the room connected but log & push local notice
        print('VIDEO_SCREEN: Failed to notify backend to start call: $e');
        print(st);
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

    // start watcher and update UI
    _startParticipantWatcher();
    if (mounted) setState(() {});
  }

  // ---------------- PARTICIPANT WATCHER ----------------
  void _startParticipantWatcher() {
    _participantWatcher?.cancel();
    _participantWatcher =
        Timer.periodic(const Duration(milliseconds: 400), (_) async {
      if (_room == null) return;

      final hasRemote = _room!.remoteParticipants.isNotEmpty;

      // detect remote-join/leave transitions
      if (hasRemote && !_hadRemote) {
        _hadRemote = true;
        if (!_timerStarted) _startCallTimerOnce();
      }

      if (!hasRemote && _hadRemote) {
        // remote participant left — end the call locally immediately
        _hadRemote = false;
        print('VideoScreen: remote participant left — ending call locally');
        _callTimer?.cancel();
        _participantWatcher?.cancel();

        // Mark call as ended so UI will not show Join
        _callEnded = true;

        try {
          // disconnect room (no retry)
          if (_room != null) {
            await _room!.disconnect();
            if (mounted) setState(() => _room = null);
          }
          // Emit local notice so other parts of app can react
          await NotificationCenter().push(
            title: 'Call ended',
            body: 'Remote participant left the call',
            type: 'video_end',
            appointmentId: widget.appointmentId,
            alsoShowSystemToast: false,
          );
        } catch (e) {
          print('VideoScreen: error handling remote-left: $e');
        }
      }

      // start timer if remote present
      if (hasRemote && !_timerStarted) _startCallTimerOnce();

      // when patient joins, doctor is already online
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

  Future<void> _handlePushNotice(LocalNotice notice) async {
    try {
      if (notice.type == 'video_end' &&
          notice.appointmentId == widget.appointmentId) {
        print('VideoScreen: received video_end for appt ${notice.appointmentId}');
        // Stop timers and disconnect room
        _callTimer?.cancel();
        _participantWatcher?.cancel();

        // Mark call ended so UI will not allow re-join
        _callEnded = true;

        if (_room != null) {
          try {
            await _room!.disconnect();
          } catch (e) {
            print('VideoScreen: error disconnecting room: $e');
          }
          if (mounted) {
            setState(() {
              _room = null;
            });
          }
        }

        // Optionally show a toast
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Call ended')),
          );
        }
      }
    } catch (e) {
      print('VideoScreen: _handlePushNotice error: $e');
    }
  }

  // ---------------- UI & Build ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          // While initial token request in progress we show spinner or the connecting overlay
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snap.data!;
          if (data['ok'] != true) {
            return const Center(child: Text('Unable to join call'));
          }

          final wsUrl = data['url'] as String;
          final token = data['token'] as String;

          // ================= PRE JOIN (we auto-join) =================
          if (_room == null) {
            // If call ended, show call ended UI and no Join option
            if (_callEnded) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Call ended',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
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

            // if connecting show overlay progress
            if (_connecting) {
              return const Center(child: CircularProgressIndicator());
            }

            // If auto-join failed previously, show single Join button that triggers a manual attempt.
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
                      onPressed: () async {
                        // If call ended, do nothing
                        if (_callEnded) return;
                        setState(() => _connecting = true);
                        try {
                          await _connect(wsUrl, token);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Failed to join: $e')));
                          }
                        } finally {
                          if (mounted) setState(() => _connecting = false);
                        }
                      },
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

                            // Notify server that this side ended the call so server
                            // can notify the other party.
                            try {
                              if (Api.isReady == false) await Api.init();
                              await Api.post('/appointments/${widget.appointmentId}/call/end');
                            } catch (e) {
                              print('VideoScreen: failed to notify server call/end: $e');
                            }

                            // Mark call ended so UI won't show join again later
                            _callEnded = true;

                            await NotificationCenter().push(
                              title: 'Video call ended',
                              body: 'Duration: ${_fmt(_callDuration)}',
                              type: 'video_end',
                              appointmentId: widget.appointmentId,
                              alsoShowSystemToast: false,
                            );

                            // disconnect local room (no retry)
                            try {
                              await _room!.disconnect();
                            } catch (e) {
                              print('VideoScreen: error disconnecting: $e');
                            }
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
