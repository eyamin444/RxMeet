// lib/services/ringtone.dart
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class RingtoneService {
  static final AudioPlayer _player = AudioPlayer(playerId: 'ringtone_player');
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    _inited = true;
    // Nothing else now — unlockAudioOnce does the temporary play to acquire audio.
  }

  /// Do a short quiet play to unlock audio autoplay policies (especially on web).
  static Future<void> unlockAudioOnce() async {
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setVolume(0.0);
      if (kIsWeb) {
        final url = Uri.base.resolve('assets/ringtone/telehealth_incoming_ringtone.mp3').toString();
        await _player.play(UrlSource(url));
      } else {
        await _player.play(AssetSource('assets/ringtone/telehealth_incoming_ringtone.mp3'));
      }
      await Future.delayed(const Duration(milliseconds: 250));
      await _player.stop();
      await _player.setVolume(1.0);
    } catch (e) {
      print('RingtoneService.unlockAudioOnce error: $e');
    }
  }

  /// Play the ringtone in a loop (for the incoming call UI).
  static Future<void> playLooping() async {
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      if (kIsWeb) {
        final url = Uri.base.resolve('assets/ringtone/telehealth_incoming_ringtone.mp3').toString();
        await _player.play(UrlSource(url));
      } else {
        await _player.play(AssetSource('assets/ringtone/telehealth_incoming_ringtone.mp3'));
      }
    } catch (e) {
      print('RingtoneService.playLooping error: $e');
    }
  }

  static Future<void> stop() async {
    try {
      await _player.stop();
    } catch (e) {
      print('RingtoneService.stop error: $e');
    }
  }

  static Future<void> dispose() async {
    try {
      await _player.release();
    } catch (e) {}
  }
}
