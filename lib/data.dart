import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ha.dart';

class CalEvent {
  final String title, calendar;
  final DateTime start;
  final bool allDay;
  CalEvent(this.title, this.calendar, this.start, this.allDay);
}

DateTime? _parseStart(dynamic s) {
  if (s is String) return DateTime.tryParse(s)?.toLocal();
  if (s is Map) {
    final v = s['dateTime'] ?? s['date'];
    return v == null ? null : DateTime.tryParse(v)?.toLocal();
  }
  return null;
}

/// Next 7 days of events from the calendars in the Inicio view, refreshed every 15 minutes.
class Agenda extends ChangeNotifier {
  final HA ha;
  List<CalEvent> events = [];
  Agenda(this.ha) {
    ha.addListener(_firstLoad);
    Timer.periodic(const Duration(minutes: 15), (_) => refresh());
  }

  bool _loaded = false;
  void _firstLoad() {
    if (ha.connected && !_loaded) {
      _loaded = true;
      refresh();
    }
  }

  Future<void> refresh() async {
    final now = DateTime.now();
    final from = DateTime(
      now.year,
      now.month,
      now.day,
    ).toUtc().toIso8601String();
    final to = now.add(const Duration(days: 7)).toUtc().toIso8601String();
    final out = <CalEvent>[];
    for (final cal in ha.view('inicio')?.domain('calendar') ?? <Item>[]) {
      final id = cal.id;
      final name =
          cal.name ?? ha[id]?['attributes']?['friendly_name'] as String? ?? id;
      try {
        final list =
            await ha.rest('/api/calendars/$id?start=$from&end=$to') as List;
        for (final e in list) {
          final start = _parseStart(e['start']);
          if (start == null) continue;
          final allDay =
              e['start'] is Map && (e['start'] as Map).containsKey('date');
          out.add(
            CalEvent(e['summary'] ?? '(sin título)', name, start, allDay),
          );
        }
      } catch (e) {
        debugPrint('Agenda $id: $e');
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    events = out;
    notifyListeners();
  }

  /// Events not yet over (all-day events count for the whole day).
  List<CalEvent> upcoming([DateTime? at]) {
    final now = at ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return events
        .where(
          (e) => e.allDay ? !e.start.isBefore(today) : e.start.isAfter(now),
        )
        .toList();
  }
}

/// Daily + hourly forecast for weather.home, refreshed every 30 minutes.
class Forecast extends ChangeNotifier {
  final HA ha;
  List<Map<String, dynamic>> daily = [], hourly = [];
  Forecast(this.ha) {
    ha.addListener(_firstLoad);
    Timer.periodic(const Duration(minutes: 30), (_) => refresh());
  }

  bool _loaded = false;
  void _firstLoad() {
    if (ha.connected && !_loaded) {
      _loaded = true;
      refresh();
    }
  }

  Future<void> refresh() async {
    try {
      final d = await ha.serviceResponse(
        'weather',
        'get_forecasts',
        'weather.home',
        {'type': 'daily'},
      );
      final h = await ha.serviceResponse(
        'weather',
        'get_forecasts',
        'weather.home',
        {'type': 'hourly'},
      );
      daily = List<Map<String, dynamic>>.from(d['forecast']);
      hourly = List<Map<String, dynamic>>.from(h['forecast']);
      notifyListeners();
    } catch (e) {
      debugPrint('Forecast: $e');
    }
  }
}
