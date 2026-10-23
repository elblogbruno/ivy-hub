import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ambient.dart' show isNightTime;

enum ScreenMode { normal, standby, off }

/// Light-driven display state, like the Smart Display: when the room goes dark
/// the photos give way to a big dim standby clock, then the panel goes black;
/// lights back on, a touch, or someone approaching (proximity) wakes it.
/// Without sensor data it falls back to the 23:00–07:00 night window.
class Presence extends ChangeNotifier {
  static const darkLux = 4.0, brightLux = 10.0; // hysteresis band
  static const toStandby = Duration(seconds: 15);
  static const toOff = Duration(minutes: 2);
  static const wakeFor = Duration(minutes: 1);

  double? lux; // flicker is handled by the hysteresis band + toStandby delay
  ScreenMode mode = ScreenMode.normal;
  DateTime? _darkSince, _standbySince, _wakeUntil;

  void onLux(double v, DateTime now) {
    lux = v;
    evaluate(now);
  }

  void onNear(bool near, DateTime now) {
    if (near && mode == ScreenMode.off) {
      mode = ScreenMode.standby;
      _standbySince = now;
      notifyListeners();
    }
  }

  void touch(DateTime now) {
    _wakeUntil = now.add(wakeFor);
    evaluate(now);
  }

  void evaluate(DateTime now) {
    final old = mode;
    final awake = _wakeUntil != null && now.isBefore(_wakeUntil!);
    final dark = lux == null
        ? isNightTime(now)
        : lux! < (mode == ScreenMode.normal ? darkLux : brightLux);
    if (!dark || awake) {
      mode = ScreenMode.normal;
      _darkSince = _standbySince = null;
    } else {
      _darkSince ??= now;
      if (mode == ScreenMode.normal &&
          now.difference(_darkSince!) >=
              (lux == null ? Duration.zero : toStandby)) {
        mode = ScreenMode.standby;
        _standbySince = now;
      } else if (mode == ScreenMode.standby &&
          lux !=
              null && // only blank on a real dark reading, never on the clock fallback
          now.difference(_standbySince!) >= toOff) {
        mode = ScreenMode.off;
      }
    }
    if (mode != old) notifyListeners();
  }

  /// Panel brightness for interactive use: follows the room on a log curve (-1 = system).
  double get roomBrightness =>
      lux == null ? -1 : (0.12 + log(lux! + 1) / ln10 / 3).clamp(0.12, 1.0);

  double get brightness => switch (mode) {
    ScreenMode.off => 0.0,
    ScreenMode.standby => 0.02,
    ScreenMode.normal => roomBrightness,
  };
}
