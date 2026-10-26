import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// 扫码成功提示音（“嘀”）+ 震动。
class Beep {
  Beep._();
  static AudioPlayer? _player;

  static Future<void> play() async {
    HapticFeedback.mediumImpact();
    try {
      final p = _player ??= AudioPlayer()
        ..setPlayerMode(PlayerMode.lowLatency)
        ..setReleaseMode(ReleaseMode.stop);
      await p.stop();
      await p.play(AssetSource('beep.wav'), volume: 1.0);
    } catch (_) {
      SystemSound.play(SystemSoundType.click);
    }
  }
}
