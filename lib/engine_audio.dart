// Public audio facade. Delegates to a web (Web Audio) implementation when
// compiled for the web, and to a no-op stub everywhere else (VM tests, mobile).
import 'engine_audio_stub.dart'
    if (dart.library.js_interop) 'engine_audio_web.dart' as impl;

class EngineAudio {
  static void start() => impl.engineStart();
  static void setRpm(double v) => impl.engineSetRpm(v);
  static void offroad(bool on) => impl.engineOffroad(on);
  static void crash() => impl.engineCrash();
  static void stop() => impl.engineStop();

  static void sfxCheckpoint() => impl.sfxCheckpoint();
  static void sfxFinish() => impl.sfxFinish();
  static void sfxGameOver() => impl.sfxGameOver();

  static void musicPlay(String url) => impl.musicPlay(url);
  static void musicSetMuted(bool m) => impl.musicSetMuted(m);
}
