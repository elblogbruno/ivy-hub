import 'dart:math';

import 'package:flutter/material.dart';

import 'ambient.dart';
import 'ha.dart';
import 'ui.dart';

/// Tariff periods 2.0TD, stacked bottom-up in this order. Colours are the
/// dataviz reference categorical slots (orange/blue/aqua, dark steps),
/// validated on `surface`.
const periodNames = ['Punta', 'Llano', 'Valle'];
const periodColors = [Color(0xFFD95926), Color(0xFF3987E5), Color(0xFF199E70)];

String num1(double v, [int d = 1]) => v.toStringAsFixed(d).replaceAll('.', ',');
String eur(double v) => '${num1(v, 2)} €';

/// One bar: kWh and € per period (P1, P2, P3).
class Bucket {
  final DateTime start;
  final List<double> kwh, cost;
  Bucket(this.start, this.kwh, this.cost);
  double get kwhTotal => kwh.fold(0, (a, b) => a + b);
  double get costTotal => cost.fold(0, (a, b) => a + b);
}

enum Span { hours, days, months }

/// Electricity page from the e-data integration (Datadis). Its data lives in
/// long-term statistics `edata:<cups>_*`, not in entity attributes; [entity]
/// is the `sensor.edata_<cups>` whose state is the last hour with data.
class EnergyPage extends StatefulWidget {
  final HA ha;
  final String entity;
  final bool active;
  const EnergyPage({
    super.key,
    required this.ha,
    required this.entity,
    required this.active,
  });
  @override
  State<EnergyPage> createState() => _EnergyPageState();
}

class _EnergyPageState extends State<EnergyPage> {
  Map<Span, List<Bucket>> _data = {};
  double? _powerCost, _energyCost, _maxKw;
  DateTime? _maxMonth, _lastDay, _at;
  bool _loading = false;
  String? _error;
  var _span = Span.days;
  var _euros = false;
  int? _sel;

  String get _cups => widget.entity.split('.').last.replaceFirst('edata_', '');

  @override
  void initState() {
    super.initState();
    widget.ha.addListener(_maybeLoad);
    _maybeLoad();
  }

  @override
  void didUpdateWidget(EnergyPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _maybeLoad();
  }

  @override
  void dispose() {
    widget.ha.removeListener(_maybeLoad);
    super.dispose();
  }

  /// Datadis publishes once a day: reload at most every 30 min.
  void _maybeLoad() {
    if (!widget.ha.connected || _loading) return;
    if (_at != null &&
        DateTime.now().difference(_at!) < const Duration(minutes: 30)) {
      return;
    }
    _load();
  }

  Future<Map<String, List>> _stats(
    String period,
    DateTime start,
    List<String> ids,
    List<String> types,
  ) async {
    final r = await widget.ha.call({
      'type': 'recorder/statistics_during_period',
      'start_time': start.toUtc().toIso8601String(),
      'statistic_ids': ids,
      'period': period,
      'types': types,
    });
    return Map<String, List>.from(r as Map);
  }

  Future<List<Bucket>> _buckets(String period, DateTime start) async {
    final c = 'edata:$_cups';
    final kwhIds = [for (var p = 1; p <= 3; p++) '${c}_p${p}_consumption'];
    final costIds = [for (var p = 1; p <= 3; p++) '${c}_p${p}_cost'];
    final r = await _stats(period, start, [...kwhIds, ...costIds], ['change']);
    final byStart = <int, Bucket>{};
    for (final (i, id) in [...kwhIds, ...costIds].indexed) {
      for (final row in r[id] ?? const []) {
        final ms = row['start'] as int;
        final b = byStart[ms] ??= Bucket(
          DateTime.fromMillisecondsSinceEpoch(ms),
          [0, 0, 0],
          [0, 0, 0],
        );
        final v = ((row['change'] as num?) ?? 0).toDouble();
        i < 3 ? b.kwh[i] = v : b.cost[i - 3] = v;
      }
    }
    return byStart.values.toList()..sort((a, b) => a.start.compareTo(b.start));
  }

  Future<void> _load() async {
    _loading = true;
    try {
      final last = DateTime.tryParse(
        widget.ha[widget.entity]?['state'] as String? ?? '',
      );
      final day = last == null
          ? DateTime.now().subtract(const Duration(days: 1))
          : DateTime(last.year, last.month, last.day);
      final month = DateTime(day.year, day.month);
      final hours = await _buckets('hour', day);
      final days = await _buckets(
        'day',
        day.subtract(const Duration(days: 29)),
      );
      final months = await _buckets('month', DateTime(day.year - 1, day.month));
      final c = 'edata:$_cups';
      final split = await _stats(
        'month',
        month,
        ['${c}_power_cost', '${c}_energy_cost'],
        ['change'],
      );
      final maxi = await _stats(
        'month',
        DateTime(day.year, day.month - 3),
        ['${c}_maximeter'],
        ['max'],
      );
      final lastMax = (maxi['${c}_maximeter'] ?? const [])
          .where((r) => r['max'] != null)
          .lastOrNull;
      double? change(String id) =>
          ((split[id]?.lastOrNull)?['change'] as num?)?.toDouble();
      setState(() {
        _lastDay = day;
        _data = {Span.hours: hours, Span.days: days, Span.months: months};
        _powerCost = change('${c}_power_cost');
        _energyCost = change('${c}_energy_cost');
        _maxKw = (lastMax?['max'] as num?)?.toDouble();
        _maxMonth = lastMax == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastMax['start'] as int);
        _error = null;
        _sel = null;
        _at = DateTime.now();
      });
    } catch (e) {
      debugPrint('Energy: $e');
      setState(() => _error = 'No se pudieron leer los datos de e-data');
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_at == null) {
      return Center(
        child: Text(_error ?? 'Cargando consumo…', style: gs(18, color: muted)),
      );
    }
    final day = _lastDay!;
    final months = _data[Span.months]!;
    final days = _data[Span.days]!;
    final cur = months.where((b) => b.start.month == day.month).lastOrNull;
    final prev = months
        .where((b) => b.start.isBefore(DateTime(day.year, day.month)))
        .lastOrNull;
    final lastDay = days.where((b) => b.start == day).lastOrNull;
    final daysInMonth = DateTime(day.year, day.month + 1, 0).day;
    final contract =
        (widget.ha[widget.entity]?['attributes']?['contract_p1_kw'] as num?)
            ?.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 104,
          child: Row(
            children: [
              _Kpi(
                title: 'Este mes',
                value: cur == null ? '--' : eur(cur.costTotal),
                sub: cur == null
                    ? ''
                    : '${num1(cur.kwhTotal, 0)} kWh · previsión ${eur(cur.costTotal / day.day * daysInMonth)}',
              ),
              _Kpi(
                title: prev == null
                    ? 'Mes pasado'
                    : _cap(monthNames[prev.start.month - 1]),
                value: prev == null ? '--' : eur(prev.costTotal),
                sub: prev == null ? '' : '${num1(prev.kwhTotal, 0)} kWh',
              ),
              _Kpi(
                title: 'Último día · ${dayLabel(day)}',
                value: lastDay == null ? '--' : '${num1(lastDay.kwhTotal)} kWh',
                sub: lastDay == null ? '' : eur(lastDay.costTotal),
              ),
              _PowerKpi(kw: _maxKw, contract: contract, month: _maxMonth),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 7, child: _chartPanel()),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: _Breakdown(
                  month: cur,
                  days: day.day,
                  power: _powerCost,
                  energy: _energyCost,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chartPanel() {
    final data = _data[_span]!;
    final sel = _sel != null && _sel! < data.length ? data[_sel!] : null;
    final total = data.fold<double>(
      0,
      (a, b) => a + (_euros ? b.costTotal : b.kwhTotal),
    );
    String fmt(double v) => _euros ? eur(v) : '${num1(v)} kWh';
    final headline = sel == null
        ? '${switch (_span) {
            Span.hours => dayLabel(_lastDay!),
            Span.days => 'Últimos 30 días',
            Span.months => 'Último año',
          }} · ${fmt(total)}'
        : '${_label(sel.start)} · ${fmt(_euros ? sel.costTotal : sel.kwhTotal)}';
    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: gs(17, weight: FontWeight.w500),
                ),
              ),
              _Toggle(
                labels: const ['Horas', 'Días', 'Meses'],
                index: _span.index,
                onTap: (i) => setState(() {
                  _span = Span.values[i];
                  _sel = null;
                }),
              ),
              const SizedBox(width: 8),
              _Toggle(
                labels: const ['kWh', '€'],
                index: _euros ? 1 : 0,
                onTap: (i) => setState(() => _euros = i == 1),
              ),
            ],
          ),
          SizedBox(
            height: 22,
            child: sel == null
                ? null
                : Row(
                    children: [
                      for (var p = 0; p < 3; p++) ...[
                        _Dot(periodColors[p]),
                        Text(
                          '${periodNames[p]} ${_euros ? eur(sel.cost[p]) : num1(sel.kwh[p])}   ',
                          style: gs(14, color: muted),
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: data.isEmpty
                ? Center(
                    child: Text('Sin datos', style: gs(16, color: muted)),
                  )
                : _Bars(
                    data: data,
                    euros: _euros,
                    selected: _sel,
                    label: (i) => _tick(data, i),
                    onTap: (i) => setState(() => _sel = _sel == i ? null : i),
                  ),
          ),
        ],
      ),
    );
  }

  String? _tick(List<Bucket> data, int i) {
    final t = data[i].start;
    return switch (_span) {
      Span.hours => t.hour % 3 == 0 ? '${t.hour}' : null,
      Span.days => (data.length - 1 - i) % 5 == 0 ? '${t.day}' : null,
      Span.months => monthNames[t.month - 1].substring(0, 3),
    };
  }

  String _label(DateTime t) => switch (_span) {
    Span.hours => '${two(t.hour)}:00–${two(t.hour + 1)}:00',
    Span.days => dayLabel(t),
    Span.months => '${_cap(monthNames[t.month - 1])} ${t.year}',
  };
}

String _cap(String s) => s[0].toUpperCase() + s.substring(1);

class _Kpi extends StatelessWidget {
  final String title, value, sub;
  const _Kpi({required this.title, required this.value, required this.sub});
  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, style: gs(14, color: muted)),
            const Spacer(),
            Text(value, maxLines: 1, style: gsd(28, height: 1.1)),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: gs(13, color: muted),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Peak demand (maxímetro) against the contracted power.
class _PowerKpi extends StatelessWidget {
  final double? kw, contract;
  final DateTime? month;
  const _PowerKpi({this.kw, this.contract, this.month});
  @override
  Widget build(BuildContext context) {
    final t = kw != null && contract != null
        ? (kw! / contract!).clamp(0.0, 1.0)
        : 0.0;
    return Expanded(
      child: Panel(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Potencia máx.${month == null ? '' : ' · ${monthNames[month!.month - 1]}'}',
              maxLines: 1,
              style: gs(14, color: muted),
            ),
            const Spacer(),
            Text(
              kw == null ? '--' : '${num1(kw!, 2)} kW',
              style: gsd(28, height: 1.1),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: t,
                minHeight: 6,
                color: t > 0.9 ? danger : accent,
                backgroundColor: surfaceHigh,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              contract == null
                  ? ''
                  : '${(t * 100).round()} % de ${num1(contract!)} kW contratados',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: gs(12, color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// This month by tariff period (doubles as the chart legend) + bill split.
class _Breakdown extends StatelessWidget {
  final Bucket? month;
  final int days;
  final double? power, energy;
  const _Breakdown({this.month, required this.days, this.power, this.energy});
  @override
  Widget build(BuildContext context) {
    final m = month;
    final total = m?.kwhTotal ?? 0;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            m == null
                ? 'Por periodo'
                : 'Por periodo · ${monthNames[m.start.month - 1]}',
            style: gs(15, weight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          for (var p = 0; p < 3; p++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _Dot(periodColors[p]),
                      Expanded(child: Text(periodNames[p], style: gs(15))),
                      Text(
                        total == 0
                            ? '--'
                            : '${(m!.kwh[p] / total * 100).round()} %',
                        style: gs(15, weight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : m!.kwh[p] / total,
                      minHeight: 4,
                      color: periodColors[p],
                      backgroundColor: surfaceHigh,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    m == null
                        ? ''
                        : '${num1(m.kwh[p], 0)} kWh · ${eur(m.cost[p])}',
                    style: gs(12, color: muted),
                  ),
                ],
              ),
            ),
          const Spacer(),
          const Divider(color: surfaceHigh, height: 12),
          if (m != null)
            _row(
              'Media diaria',
              '${num1(m.kwhTotal / days)} kWh · ${eur(m.costTotal / days)}',
            ),
          if (energy != null) _row('Energía', eur(energy!)),
          if (power != null) _row('Potencia', eur(power!)),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      children: [
        Expanded(
          child: Text(k, style: gs(14, color: muted)),
        ),
        Text(v, style: gs(14)),
      ],
    ),
  );
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot(this.color);
  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    margin: const EdgeInsets.only(right: 8),
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _Toggle extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onTap;
  const _Toggle({
    required this.labels,
    required this.index,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: surfaceHigh,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, l) in labels.indexed)
          GestureDetector(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: i == index ? onSurface : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(l, style: gs(14, color: i == index ? bg : onSurface)),
            ),
          ),
      ],
    ),
  );
}

/// Round step for gridlines: 1, 2, 2.5 or 5 × 10^n.
double niceStep(double max) {
  if (max <= 0) return 1;
  final raw = max / 3;
  final mag = pow(10, (log(raw) / ln10).floor()).toDouble();
  return [
    1.0,
    2.0,
    2.5,
    5.0,
    10.0,
  ].map((f) => f * mag).firstWhere((s) => s >= raw);
}

/// Stacked bars P1/P2/P3 from the baseline, 2 px surface gaps, rounded data
/// end, 3 recessive gridlines; tap selects a bar (the touch "tooltip").
class _Bars extends StatelessWidget {
  final List<Bucket> data;
  final bool euros;
  final int? selected;
  final String? Function(int) label;
  final ValueChanged<int> onTap;
  const _Bars({
    required this.data,
    required this.euros,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    List<double> vals(Bucket b) => euros ? b.cost : b.kwh;
    final max = data
        .map((b) => vals(b).fold(0.0, (a, v) => a + v))
        .reduce((a, b) => a > b ? a : b);
    final step = niceStep(max);
    final top = (max / step).ceil() * step;
    String axis(double v) =>
        step < 1 ? num1(v, step < 0.1 ? 2 : 1) : num1(v, 0);
    return LayoutBuilder(
      builder: (context, c) {
        const labelH = 20.0, axisW = 34.0;
        final h = c.maxHeight - labelH;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (var g = 0; g <= (top / step).round(); g++)
              Positioned(
                left: 0,
                right: 0,
                top: h - h * (g * step / top) - 8,
                child: Row(
                  children: [
                    SizedBox(
                      width: axisW,
                      child: Text(axis(g * step), style: gs(11, color: muted)),
                    ),
                    Expanded(
                      child: Container(
                        height: 1,
                        margin: const EdgeInsets.only(top: 1),
                        color: g == 0
                            ? muted.withValues(alpha: 0.5)
                            : surfaceHigh,
                      ),
                    ),
                  ],
                ),
              ),
            Positioned.fill(
              left: axisW,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, b) in data.indexed)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap(i),
                        child: Opacity(
                          opacity: selected == null || selected == i ? 1 : 0.4,
                          child: Column(
                            children: [
                              Expanded(child: _stack(vals(b), h, top)),
                              SizedBox(
                                height: labelH,
                                child: Center(
                                  child: Text(
                                    label(i) ?? '',
                                    maxLines: 1,
                                    style: gs(11, color: muted),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _stack(List<double> v, double h, double top) {
    final lastP = [2, 1, 0].firstWhere((p) => v[p] > 0, orElse: () => -1);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (var p = 2; p >= 0; p--)
            if (v[p] > 0)
              Container(
                height: max(1.0, h * v[p] / top - (p == lastP ? 0 : 2)),
                margin: EdgeInsets.only(top: p == lastP ? 0 : 2),
                decoration: BoxDecoration(
                  color: periodColors[p],
                  borderRadius: p == lastP
                      ? const BorderRadius.vertical(top: Radius.circular(4))
                      : null,
                ),
              ),
        ],
      ),
    );
  }
}
