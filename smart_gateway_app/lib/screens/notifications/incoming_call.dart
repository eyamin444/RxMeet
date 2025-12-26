// lib/screens/notifications/incoming_call.dart
import 'package:flutter/material.dart';
import '../../Services/Api.dart';
import '../../widgets/snack.dart';
import '../../services/ringtone.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

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

  @override
  void initState() {
    super.initState();
    // Play looping ringtone while IncomingCallPage is shown
    RingtoneService.playLooping();
  }

  Future<void> _acceptCall() async {
    setState(() => _joining = true);
    await RingtoneService.stop();

    try {
      if (widget.callLogId != null) {
        await Api.post('/appointments/${widget.appointmentId}/call/answer',
            data: {'call_log_id': widget.callLogId.toString()});
      }

      final resp = await Api.post('/appointments/${widget.appointmentId}/video/token');
      final url = resp['url'] as String?;
      final token = resp['token'] as String?;
      if (url == null || token == null) {
        throw Exception('Missing token/url from server');
      }

      // TODO: Replace this placeholder navigation with the real VideoScreen navigation.
      // Example: Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => VideoScreen(...)));
      showSnack(context, 'Ready to join room ${widget.room}');

      setState(() => _joining = false);
    } catch (e) {
      showSnack(context, 'Failed to join call: $e');
      setState(() => _joining = false);
    }
  }

  Future<void> _declineCall() async {
    await RingtoneService.stop();
    if (widget.callLogId != null) {
      try {
        await Api.post('/appointments/${widget.appointmentId}/call/end',
            data: {'call_log_id': widget.callLogId.toString(), 'duration': '0'});
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    RingtoneService.stop();
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
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
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
