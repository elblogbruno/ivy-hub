import 'dart:async';
import 'dart:math';

import 'package:flare_flutter/flare_actor.dart';
import 'package:flutter/material.dart';

import 'ha.dart';

/// Google Weather Frog interlude. Assets (Google's) and the selection scheme
/// come from github.com/R0rt1z2/Froggy: assets/froggy/{scene}_{daypart}_{condition}_{bg.webp|frog.flr}.
const _scenes = ['fields', 'hill', 'mushroom'];

/// False when the Froggy assets aren't bundled (they're not in the public repo).
bool hasFrog = false;

String _condition(String? haWeather) => switch (haWeather) {
  'sunny' || 'clear-night' => 'sunny',
  'fog' => 'hazy',
  'rainy' || 'pouring' || 'lightning' || 'lightning-rainy' || 'hail' => 'rainy',
  'snowy' || 'snowy-rainy' => 'snowy',
  _ => 'cloudy',
};

/// Today's occurrence of an HA sun.sun "next_*" timestamp.
DateTime? _today(String? iso, DateTime now) {
  final t = DateTime.tryParse(iso ?? '')?.toLocal();
  if (t == null) return null;
  return t.day == now.day ? t : t.subtract(const Duration(days: 1));
}

/// Same day-part boundaries as Froggy (morning = 2.5 h after sunrise, sunset = -1 h/+30 min).
String dayPart(HA ha, DateTime now) {
  final sun = ha['sun.sun']?['attributes'];
  final rise = _today(sun?['next_rising'], now),
      set = _today(sun?['next_setting'], now);
  if (rise != null && set != null) {
    if (now.isBefore(rise)) return 'night';
    if (now.isBefore(rise.add(const Duration(minutes: 150)))) return 'morning';
    if (now.isBefore(set.subtract(const Duration(hours: 1)))) return 'day';
    if (now.isBefore(set.add(const Duration(minutes: 30)))) return 'sunset';
    return 'night';
  }
  final h = now.hour;
  return h >= 6 && h < 9
      ? 'morning'
      : h >= 9 && h < 17
      ? 'day'
      : h >= 17 && h < 19
      ? 'sunset'
      : 'night';
}

/// Picks a random scene for the current weather and time of day.
String frogScene(HA ha, Random rnd) {
  final cond = _condition(ha['weather.home']?['state'] as String?);
  return 'assets/froggy/${_scenes[rnd.nextInt(_scenes.length)]}_${dayPart(ha, DateTime.now())}_$cond';
}

class FrogScene extends StatefulWidget {
  final String base; // assets/froggy/{scene}_{daypart}_{condition}
  const FrogScene({super.key, required this.base});
  @override
  State<FrogScene> createState() => _FrogSceneState();
}

class _FrogSceneState extends State<FrogScene> {
  static const _animation = 'Hero-Action';
  final _rnd = Random();
  String? _playing = _animation;
  Timer? _gap;

  @override
  void dispose() {
    _gap?.cancel();
    super.dispose();
  }

  // Like the Nest: play the action, rest 2.5–10 s, play again.
  void _done(String _) {
    if (!mounted) return;
    setState(() => _playing = null);
    _gap = Timer(Duration(milliseconds: 2500 + _rnd.nextInt(7500)), () {
      if (mounted) setState(() => _playing = _animation);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          '${widget.base}_bg.webp',
          fit: BoxFit.cover,
          cacheWidth: 1280,
          filterQuality: FilterQuality.medium,
        ),
        RepaintBoundary(
          child: FlareActor(
            '${widget.base}_frog.flr',
            alignment: Alignment.center,
            fit: BoxFit.cover,
            animation: _playing,
            callback: _done,
          ),
        ),
      ],
    );
  }
}
