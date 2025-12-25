// lib/services/ringtone.dart
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class RingtoneService {
  static final AudioPlayer _player = AudioPlayer(playerId: 'ringtone_player');
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    _inited = true;
  }

  static Future<void> unlockAudioOnce() async {
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setVolume(0.0);
      if (kIsWeb) {
        // Use URLSource on web (resolve to /assets/...)
        final url = Uri.base.resolve('assets/ringtone/telehealth_incoming_ringtone.ogg').toString();
        await _player.play(UrlSource(url));
      } else {
        await _player.play(AssetSource('assets/ringtone/telehealth_incoming_ringtone.ogg'));
      }
      await Future.delayed(const Duration(milliseconds: 250));
      await _player.stop();
      await _player.setVolume(1.0);
    } catch (e) {
      print('RingtoneService.unlockAudioOnce error: $e');
    }
  }

  static Future<void> playLooping() async {
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      if (kIsWeb) {
        final url = Uri.base.resolve('assets/ringtone/telehealth_incoming_ringtone.ogg').toString();
        await _player.play(UrlSource(url));
      } else {
        await _player.play(AssetSource('assets/ringtone/telehealth_incoming_ringtone.ogg'));
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
