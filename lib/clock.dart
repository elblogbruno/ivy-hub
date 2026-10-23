import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'ambient.dart';
import 'ui.dart';
import 'wyoming.dart';

String fmtDuration(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

String fmtLength(Duration d) => d.inMinutes >= 60
    ? '${d.inHours} h ${d.inMinutes % 60 > 0 ? '${d.inMinutes % 60} min' : ''}'
          .trim()
    : '${d.inMinutes} min';

class IvyTimer {
  final Duration total;
  DateTime? end;
  Duration? left; // set while paused
  IvyTimer(this.total) : end = DateTime.now().add(total);
  bool get paused => end == null;
  Duration remaining(DateTime now) => end?.difference(now) ?? left!;
}

class Alarm {
  int hour, minute;
  Set<int> days; // DateTime.weekday values; empty = once
  bool enabled;
  Alarm(this.hour, this.minute, {Set<int>? days, this.enabled = true})
    : days = days ?? {};
  Map<String, dynamic> toJson() => {
    'h': hour,
    'm': minute,
    'd': days.toList(),
    'e': enabled,
  };
  factory Alarm.fromJson(Map<String, dynamic> j) => Alarm(
    j['h'],
    j['m'],
    days: Set<int>.from(j['d'] ?? []),
    enabled: j['e'] ?? true,
  );
}

const weekdayLetters = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];

/// Local timers and alarms (Google's "quartz_timer"/"quartz_alarm"), checked every second.
class Clocks extends ChangeNotifier {
  final timers = <IvyTimer>[];
  List<Alarm> alarms = [];
  String? ringing;
  bool ringingAlarm = false;
  String? _firedKey;
  File? _file;
  final _satelliteTimers = <String, String>{};

  /// HA owns these clocks; only its finished event may sound the alarm.
  void onSatelliteTimer(WyomingEvent event) {
    final id = event.data['id'] as String;
    switch (event.type) {
      case 'timer-started':
        _satelliteTimers[id] = event.data['name'] as String? ?? 'Temporizador';
      case 'timer-cancelled':
        _satelliteTimers.remove(id);
      case 'timer-finished':
        _ring(_satelliteTimers.remove(id) ?? 'Temporizador', alarm: false);
    }
  }

  Clocks() {
    _load();
    Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  Future<void> _load() async {
    try {
      _file = File(
        '${await native.invokeMethod<String>('filesDir')}/alarms.json',
      );
      if (await _file!.exists()) {
        alarms = [
          for (final j in jsonDecode(await _file!.readAsString()))
            Alarm.fromJson(j),
        ];
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Clocks load: $e');
    }
  }

  void save() {
    _file?.writeAsString(jsonEncode([for (final a in alarms) a.toJson()]));
    notifyListeners();
  }

  void _check() {
    final now = DateTime.now();
    for (final t in [...timers]) {
      if (!t.paused && !t.end!.isAfter(now)) {
        timers.remove(t);
        _ring('Temporizador de ${fmtLength(t.total)}', alarm: false);
      }
    }
    final key = '${now.day} ${now.hour}:${now.minute}';
    for (final a in alarms) {
      if (a.enabled &&
          a.hour == now.hour &&
          a.minute == now.minute &&
          _firedKey != key &&
          (a.days.isEmpty || a.days.contains(now.weekday))) {
        _firedKey = key;
        if (a.days.isEmpty) a.enabled = false;
        save();
        _ring('Alarma ${two(a.hour)}:${two(a.minute)}', alarm: true);
      }
    }
    if (timers.isNotEmpty || ringing != null) notifyListeners();
  }

  void _ring(String label, {required bool alarm}) {
    ringing = label;
    ringingAlarm = alarm;
    native.invokeMethod('wake');
    native.invokeMethod('ringStart');
    notifyListeners();
  }

  void stopRing() {
    ringing = null;
    native.invokeMethod('ringStop');
    notifyListeners();
  }

  void snooze() {
    final wasAlarm = ringingAlarm;
    stopRing();
    add(Duration(minutes: wasAlarm ? 10 : 1));
  }

  void add(Duration d) {
    timers.add(IvyTimer(d));
    notifyListeners();
  }

  void togglePause(IvyTimer t) {
    final now = DateTime.now();
    if (t.paused) {
      t.end = now.add(t.left!);
      t.left = null;
    } else {
      t.left = t.end!.difference(now);
      t.end = null;
    }
    notifyListeners();
  }

  void addMinute(IvyTimer t) {
    t.paused
        ? t.left = t.left! + const Duration(minutes: 1)
        : t.end = t.end!.add(const Duration(minutes: 1));
    notifyListeners();
  }

  void cancel(IvyTimer t) {
    timers.remove(t);
    notifyListeners();
  }

  /// Next enabled alarm occurrence, for the ambient ticker.
  DateTime? nextAlarm() {
    final now = DateTime.now();
    DateTime? best;
    for (final a in alarms.where((a) => a.enabled)) {
      for (var i = 0; i < 8; i++) {
        final d = DateTime(now.year, now.month, now.day + i, a.hour, a.minute);
        if (d.isAfter(now) && (a.days.isEmpty || a.days.contains(d.weekday))) {
          if (best == null || d.isBefore(best)) best = d;
          break;
        }
      }
    }
    return best;
  }
}

class ClockPage extends StatelessWidget {
  final Clocks clocks;
  const ClockPage({super.key, required this.clocks});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: clocks,
      builder: (context, _) {
        final now = DateTime.now();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 6,
              child: Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Temporizadores',
                      style: gs(20, weight: FontWeight.w500),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final m in [1, 3, 5, 10, 15, 30, 60])
                          ActionChip(
                            label: Text(
                              m == 60 ? '1 h' : '$m min',
                              style: gs(15),
                            ),
                            backgroundColor: surfaceHigh,
                            side: BorderSide.none,
                            shape: const StadiumBorder(),
                            onPressed: () => clocks.add(Duration(minutes: m)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: clocks.timers.isEmpty
                          ? Center(
                              child: Text(
                                'Elige una duración para empezar',
                                style: gs(16, color: muted),
                              ),
                            )
                          : ListView(
                              children: [
                                for (final t in clocks.timers)
                                  _TimerRow(clocks: clocks, t: t, now: now),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Alarmas', style: gs(20, weight: FontWeight.w500)),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () async {
                            final t = await showTimePicker(
                              context: context,
                              initialTime: const TimeOfDay(hour: 7, minute: 30),
                            );
                            if (t != null) {
                              clocks.alarms.add(
                                Alarm(t.hour, t.minute, days: {1, 2, 3, 4, 5}),
                              );
                              clocks.save();
                            }
                          },
                          icon: const Icon(Icons.add_alarm, color: accent),
                          label: Text('Añadir', style: gs(15, color: accent)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: clocks.alarms.isEmpty
                          ? Center(
                              child: Text(
                                'Sin alarmas',
                                style: gs(16, color: muted),
                              ),
                            )
                          : ListView(
                              children: [
                                for (final a in clocks.alarms)
                                  _AlarmRow(clocks: clocks, a: a),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimerRow extends StatelessWidget {
  final Clocks clocks;
  final IvyTimer t;
  final DateTime now;
  const _TimerRow({required this.clocks, required this.t, required this.now});

  @override
  Widget build(BuildContext context) {
    final left = t.remaining(now);
    final frac = (left.inMilliseconds / t.total.inMilliseconds).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              value: frac,
              strokeWidth: 5,
              color: t.paused ? muted : accent,
              backgroundColor: surfaceHigh,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fmtDuration(left),
                  style: gsd(
                    34,
                    color: t.paused ? muted : onSurface,
                    height: 1.1,
                  ),
                ),
                Text(fmtLength(t.total), style: gs(14, color: muted)),
              ],
            ),
          ),
          IconButton(
            onPressed: () => clocks.addMinute(t),
            icon: const Icon(Icons.more_time, color: onSurface),
          ),
          IconButton(
            onPressed: () => clocks.togglePause(t),
            icon: Icon(
              t.paused ? Icons.play_arrow : Icons.pause,
              color: onSurface,
            ),
          ),
          IconButton(
            onPressed: () => clocks.cancel(t),
            icon: const Icon(Icons.close, color: muted),
          ),
        ],
      ),
    );
  }
}

class _AlarmRow extends StatelessWidget {
  final Clocks clocks;
  final Alarm a;
  const _AlarmRow({required this.clocks, required this.a});

  @override
  Widget build(BuildContext context) {
    final fg = a.enabled ? onSurface : muted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${two(a.hour)}:${two(a.minute)}',
                style: gsd(36, color: fg, height: 1),
              ),
              const Spacer(),
              IconButton(
                onPressed: () {
                  clocks.alarms.remove(a);
                  clocks.save();
                },
                icon: const Icon(Icons.delete_outline, color: muted),
              ),
              Switch(
                value: a.enabled,
                activeTrackColor: accent,
                onChanged: (v) {
                  a.enabled = v;
                  clocks.save();
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var d = 1; d <= 7; d++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      a.days.contains(d) ? a.days.remove(d) : a.days.add(d);
                      clocks.save();
                    },
                    child: CircleAvatar(
                      radius: 15,
                      backgroundColor: a.days.contains(d)
                          ? accent
                          : surfaceHigh,
                      child: Text(
                        weekdayLetters[d - 1],
                        style: gs(
                          13,
                          weight: FontWeight.w500,
                          color: a.days.contains(d) ? bg : muted,
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Text(
                a.days.isEmpty ? 'Una vez' : '',
                style: gs(13, color: muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Full-screen ringing view for timers and alarms.
class RingOverlay extends StatefulWidget {
  final Clocks clocks;
  const RingOverlay({super.key, required this.clocks});
  @override
  State<RingOverlay> createState() => _RingOverlayState();
}

class _RingOverlayState extends State<RingOverlay>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clocks;
    return ColoredBox(
      color: bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: Tween(begin: 0.9, end: 1.1).animate(
                CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
              ),
              child: CircleAvatar(
                radius: 56,
                backgroundColor: accent,
                child: Icon(
                  c.ringingAlarm ? Icons.alarm : Icons.timer,
                  size: 56,
                  color: bg,
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(c.ringing ?? '', style: gs(30, weight: FontWeight.w500)),
            const SizedBox(height: 8),
            MinuteClock(
              builder: (_, now) => Text(hhmm(now), style: gs(20, color: muted)),
            ),
            const SizedBox(height: 36),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: onSurface,
                    side: const BorderSide(color: muted),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 18,
                    ),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: c.snooze,
                  child: Text(
                    c.ringingAlarm ? 'Posponer 10 min' : '+1 min',
                    style: gs(18),
                  ),
                ),
                const SizedBox(width: 18),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: bg,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 44,
                      vertical: 18,
                    ),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: c.stopRing,
                  child: Text(
                    'Detener',
                    style: gs(18, color: bg, weight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
