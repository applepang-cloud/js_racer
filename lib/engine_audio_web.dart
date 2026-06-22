// Web implementation: binds to the global functions defined in web/engine_audio.js.
import 'dart:js_interop';

@JS('__engineStart')
external void engineStart();

@JS('__engineSetRpm')
external void engineSetRpm(double v);

@JS('__engineOffroad')
external void engineOffroad(bool on);

@JS('__engineCrash')
external void engineCrash();

@JS('__engineStop')
external void engineStop();
