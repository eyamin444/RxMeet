// lib/screens/video/video_screen.dart
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:smart_gateway_app/services/api.dart';

class VideoScreen extends StatefulWidget {
  final int appointmentId;
  const VideoScreen({super.key, required this.appointmentId});

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late Future<Map<String, dynamic>> _future;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    // Backend should mint LiveKit token + URL for this appointment.
    _future = Api.joinVideo(widget.appointmentId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video visit')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final data = snapshot.data ?? const <String, dynamic>{};
          final ok = data['ok'] == true;
          if (!ok) {
            return const Center(child: Text('Unable to mint video token'));
          }

          final url = (data['url'] ?? '').toString();
          final roomName = (data['room'] ?? '').toString();
          final who = (data['display_name'] ?? '').toString();
          final token = (data['token'] ?? '').toString();

          if (url.isEmpty || token.isEmpty) {
            return const Center(child: Text('Invalid video configuration'));
          }

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ready to join',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text('Server: $url'),
                Text('Room:   $roomName'),
                Text('User:   $who'),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: _joining
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.videocam_outlined),
                    label: Text(_joining ? 'Joining…' : 'Join room'),
                    onPressed: _joining
                        ? null
                        : () async {
                            setState(() => _joining = true);
                            try {
                              final room = lk.Room(
                                roomOptions: const lk.RoomOptions(
                                  defaultCameraCaptureOptions:
                                      lk.CameraCaptureOptions(),
                                  defaultAudioCaptureOptions:
                                      lk.AudioCaptureOptions(),
                                ),
                              );

                              await room.connect(url, token);

                              if (!mounted) return;

                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => _LiveKitCallPage(
                                    room: room,
                                    roomName: roomName,
                                  ),
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content:
                                      Text('Failed to join LiveKit room: $e'),
                                ),
                              );
                            } finally {
                              if (mounted) {
                                setState(() => _joining = false);
                              }
                            }
                          },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LiveKitCallPage extends StatefulWidget {
  const _LiveKitCallPage({
    super.key,
    required this.room,
    this.roomName,
  });

  final lk.Room room;
  final String? roomName;

  @override
  State<_LiveKitCallPage> createState() => _LiveKitCallPageState();
}

class _LiveKitCallPageState extends State<_LiveKitCallPage> {
  @override
  void initState() {
    super.initState();
    final lp = widget.room.localParticipant;
    lp
      ?..setMicrophoneEnabled(true)
      ..setCameraEnabled(true);
  }

  @override
  void dispose() {
    widget.room.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = (widget.roomName != null &&
            widget.roomName!.trim().isNotEmpty)
        ? 'Video — ${widget.roomName}'
        : 'Video call';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          const Expanded(
            child: Center(
              // Later you can replace this with LiveKit video widgets.
              child: Text('Connected to LiveKit room'),
            ),
          ),
          _CallControls(room: widget.room),
        ],
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({required this.room});

  final lk.Room room;

  @override
  Widget build(BuildContext context) {
    final lp = room.localParticipant;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Toggle mic',
            onPressed: () async {
              final enabled = lp?.isMicrophoneEnabled() ?? false;
              await lp?.setMicrophoneEnabled(!enabled);
            },
            icon: const Icon(Icons.mic_none),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: 'Toggle camera',
            onPressed: () async {
              final enabled = lp?.isCameraEnabled() ?? false;
              await lp?.setCameraEnabled(!enabled);
            },
            icon: const Icon(Icons.videocam_outlined),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: () async {
              await room.disconnect();
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.call_end),
            label: const Text('Leave'),
          ),
        ],
      ),
    );
  }
}
