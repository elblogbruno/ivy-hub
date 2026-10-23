import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'ha.dart';
import 'ui.dart';

const _areaNames = {
  'Bedroom': 'Dormitorio',
  'Kitchen': 'Cocina',
  'Living Room': 'Salón',
  'Garden': 'Jardín',
  'Garage': 'Garaje',
  '2n Floor': 'Segunda planta',
  'Entryway': 'Recibidor',
};

String friendly(HA ha, String id) =>
    (ha[id]?['attributes']?['friendly_name'] as String?)?.trim() ??
    id.split('.').last.replaceAll('_', ' ');

/// Offline switches are mostly integration leftovers; lights/climate/covers stay visible (dimmed).
bool _visible(HA ha, String id) =>
    !isOffline(ha[id]?['state'] as String?) ||
    const {'light', 'climate', 'cover'}.contains(id.split('.').first);

/// Touch volume control for the device speaker (STREAM_MUSIC via the native
/// 'volume'/'getVolume' methods). These displays have no reliable hardware volume
/// keys once Google Assistant is gone, so the app offers its own.
class VolumeControl extends StatefulWidget {
  const VolumeControl({super.key});
  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  double _v = 50;

  @override
  void initState() {
    super.initState();
    native.invokeMethod<int>('getVolume').then((v) {
      if (mounted && v != null) setState(() => _v = v.toDouble());
    });
  }

  void _set(double v) {
    setState(() => _v = v.clamp(0, 100));
    native.invokeMethod('volume', _v.round());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      decoration: BoxDecoration(
        color: surfaceHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(_v == 0 ? Icons.volume_off : Icons.volume_down, color: muted),
            onPressed: () => _set(_v - 10),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: accent,
                thumbColor: accent,
                inactiveTrackColor: const Color(0x4D9AA0A6),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: _v,
                max: 100,
                onChanged: _set,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.volume_up, color: muted),
            onPressed: () => _set(_v + 10),
          ),
          SizedBox(
            width: 40,
            child: Text('${_v.round()}', style: gs(15, color: muted),
                textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class RoomsPage extends StatelessWidget {
  final HA ha;
  final String? myRoom; // this screen's own HA area name, shown first
  final (String, String)? peer; // the other screen (ip, name) for the call button
  final VoidCallback? onCall;
  const RoomsPage({
    super.key,
    required this.ha,
    this.myRoom,
    this.peer,
    this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ha,
      builder: (context, _) {
        final rooms = [
          for (final r in ha.rooms)
            if (r.entities.where((id) => _visible(ha, id)).toList()
                case final ids when ids.isNotEmpty)
              (r, ids),
        ];
        // This screen's own room first (e.g. the kitchen screen leads with the kitchen).
        if (myRoom != null) {
          rooms.sort((a, b) {
            final am = a.$1.name == myRoom, bm = b.$1.name == myRoom;
            return am == bm ? 0 : (am ? -1 : 1);
          });
        }
        if (rooms.isEmpty && onCall == null) {
          return Center(
            child: Text(
              ha.connected
                  ? 'No hay dispositivos en habitaciones'
                  : 'Conectando…',
              style: gs(18, color: muted),
            ),
          );
        }
        return CustomScrollView(
          slivers: [
            if (onCall != null && peer != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: GestureDetector(
                    onTap: onCall,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.videocam, color: bg, size: 24),
                          const SizedBox(width: 12),
                          Text(
                            'Videollamada · ${peer!.$2}',
                            style: gs(17, color: bg, weight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: VolumeControl(),
              ),
            ),
            for (final (room, ids) in rooms) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 0, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _areaNames[room.name] ?? room.name,
                        style: gs(20, weight: FontWeight.w500),
                      ),
                      if (room.name == myRoom) ...[
                        const SizedBox(width: 10),
                        Text('Esta pantalla', style: gs(13, color: muted)),
                      ],
                    ],
                  ),
                ),
              ),
              SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisExtent: 84,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                delegate: SliverChildListDelegate([
                  for (final id in ids) EntityTile(ha: ha, entity: id),
                ]),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 18)),
            ],
          ],
        );
      },
    );
  }
}

const hvacNames = {
  'off': 'Apagado',
  'heat': 'Calor',
  'cool': 'Frío',
  'auto': 'Auto',
  'heat_cool': 'Calor/Frío',
  'dry': 'Deshumidificar',
  'fan_only': 'Ventilador',
};

class EntityTile extends StatelessWidget {
  final HA ha;
  final String entity;
  final String? name;
  const EntityTile({
    super.key,
    required this.ha,
    required this.entity,
    this.name,
  });

  @override
  Widget build(BuildContext context) {
    final s = ha[entity];
    final state = s?['state'] as String?;
    final a = (s?['attributes'] ?? const {}) as Map;
    final name = this.name ?? friendly(ha, entity);
    final offline = isOffline(state);
    final domain = entity.split('.').first;
    final on = state == 'on' || state == 'open' || state == 'unlocked';
    void toggle() => ha.service(domain, 'toggle', {'entity_id': entity});

    switch (domain) {
      case 'light':
        final bri = a['brightness'] as num?;
        return Tile(
          icon: on ? Icons.lightbulb : Icons.lightbulb_outline,
          name: name,
          state: offline
              ? unavailableLabel(state)
              : on
              ? (bri != null ? '${(bri / 2.55).round()} %' : 'Encendida')
              : 'Apagada',
          on: on,
          offline: offline,
          onTap: toggle,
          onMore: () =>
              showIvySheet(context, LightSheet(ha: ha, entity: entity)),
        );
      case 'climate':
        final t = a['temperature'] as num?;
        return Tile(
          icon: Icons.thermostat,
          name: name,
          state: offline
              ? unavailableLabel(state)
              : '${hvacNames[state] ?? state}${t != null && state != 'off' ? ' · ${t.round()}°' : ''}',
          on: !offline && state != 'off',
          onColor: state == 'cool' ? coolColor : heatColor,
          offline: offline,
          onTap: () =>
              showIvySheet(context, ThermostatSheet(ha: ha, entity: entity)),
        );
      case 'cover':
        final pos = a['current_position'] as num?;
        return Tile(
          icon: Icons.blinds,
          name: name,
          state: offline
              ? unavailableLabel(state)
              : on
              ? (pos != null ? 'Abierta $pos %' : 'Abierta')
              : 'Cerrada',
          on: on,
          onColor: accent,
          offline: offline,
          onTap: toggle,
        );
      case 'lock':
        return Tile(
          icon: on ? Icons.lock_open : Icons.lock,
          name: name,
          state: on ? 'Abierta' : 'Cerrada',
          on: on,
          onColor: danger,
          offline: offline,
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                backgroundColor: surface,
                title: Text(
                  on ? '¿Cerrar $name?' : '¿Abrir $name?',
                  style: gs(20),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: Text(on ? 'Cerrar' : 'Abrir'),
                  ),
                ],
              ),
            );
            if (ok == true)
              ha.service('lock', on ? 'lock' : 'unlock', {'entity_id': entity});
          },
        );
      default: // switch, fan
        return Tile(
          icon: domain == 'fan' ? Icons.mode_fan_off : Icons.power_settings_new,
          name: name,
          state: offline
              ? unavailableLabel(state)
              : on
              ? 'Encendido'
              : 'Apagado',
          on: on,
          onColor: accent,
          offline: offline,
          onTap: toggle,
        );
    }
  }
}

/// Sends at most every 250 ms while dragging, plus a final value on release.
class _Throttle {
  DateTime _last = DateTime(0);
  void call(void Function() f) {
    final now = DateTime.now();
    if (now.difference(_last) > const Duration(milliseconds: 250)) {
      _last = now;
      f();
    }
  }
}

const _swatches = <(double, double)>[
  (0, 0),
  (0, 100),
  (25, 100),
  (50, 100),
  (120, 90),
  (180, 90),
  (220, 100),
  (275, 80),
  (320, 80),
];

class LightSheet extends StatelessWidget {
  final HA ha;
  final String entity;
  LightSheet({super.key, required this.ha, required this.entity});
  final _throttle = _Throttle();

  void _turnOn(Map<String, dynamic> data) =>
      ha.service('light', 'turn_on', {'entity_id': entity, ...data});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ha,
      builder: (context, _) {
        final s = ha[entity];
        final a = (s?['attributes'] ?? const {}) as Map;
        final on = s?['state'] == 'on';
        final modes = List<String>.from(a['supported_color_modes'] ?? const []);
        final dimmable = modes.any((m) => m != 'onoff');
        final colour = modes.any(
          (m) => const {'hs', 'rgb', 'xy', 'rgbw', 'rgbww'}.contains(m),
        );
        final temp = modes.contains('color_temp');
        final bri = ((a['brightness'] as num?) ?? 0) / 255;
        final hs = (a['hs_color'] as List?)?.cast<num>();
        final minK = (a['min_color_temp_kelvin'] as num?) ?? 2000;
        final maxK = (a['max_color_temp_kelvin'] as num?) ?? 6500;
        final k = (a['color_temp_kelvin'] as num?) ?? (minK + maxK) / 2;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  on ? Icons.lightbulb : Icons.lightbulb_outline,
                  color: on ? lightOn : muted,
                  size: 30,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    friendly(ha, entity),
                    style: gs(24, weight: FontWeight.w500),
                  ),
                ),
                Switch(
                  value: on,
                  activeTrackColor: lightOn,
                  onChanged: (_) =>
                      ha.service('light', 'toggle', {'entity_id': entity}),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (dimmable)
              FillSlider(
                value: on ? bri : 0,
                label: (v) => v == 0 ? 'Apagada' : '${(v * 100).round()} %',
                onChanged: (v) => _throttle(
                  () => _turnOn({'brightness_pct': max(1, (v * 100).round())}),
                ),
                onChangeEnd: (v) => v < 0.01
                    ? ha.service('light', 'turn_off', {'entity_id': entity})
                    : _turnOn({'brightness_pct': (v * 100).round()}),
              ),
            if (colour) ...[
              const SizedBox(height: 22),
              Text('Color', style: gs(16, color: muted)),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final (h, sat) in _swatches)
                    GestureDetector(
                      onTap: () => _turnOn({
                        'hs_color': [h, sat],
                      }),
                      child: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: HSVColor.fromAHSV(
                            1,
                            h,
                            sat / 100,
                            1,
                          ).toColor(),
                          border: Border.all(
                            width: 3,
                            color:
                                hs != null &&
                                    (hs[0] - h).abs() < 8 &&
                                    (hs[1] - sat).abs() < 15
                                ? onSurface
                                : Colors.transparent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (temp) ...[
              const SizedBox(height: 22),
              Text('Blanco', style: gs(16, color: muted)),
              const SizedBox(height: 10),
              FillSlider(
                value: ((k - minK) / (maxK - minK)).clamp(0.0, 1.0).toDouble(),
                track: const LinearGradient(
                  colors: [
                    Color(0xFFFFB46B),
                    Color(0xFFFFF4E5),
                    Color(0xFFCFE3FF),
                  ],
                ),
                label: (v) => '${(minK + v * (maxK - minK)).round()} K',
                onChanged: (v) => _throttle(
                  () => _turnOn({
                    'color_temp_kelvin': (minK + v * (maxK - minK)).round(),
                  }),
                ),
                onChangeEnd: (v) => _turnOn({
                  'color_temp_kelvin': (minK + v * (maxK - minK)).round(),
                }),
              ),
            ],
          ],
        );
      },
    );
  }
}

class ThermostatSheet extends StatefulWidget {
  final HA ha;
  final String entity;
  const ThermostatSheet({super.key, required this.ha, required this.entity});
  @override
  State<ThermostatSheet> createState() => _ThermostatSheetState();
}

class _ThermostatSheetState extends State<ThermostatSheet> {
  double? _target;
  Timer? _debounce;

  Map get _a => (widget.ha[widget.entity]?['attributes'] ?? const {}) as Map;
  double get _min => ((_a['min_temp'] as num?) ?? 16).toDouble();
  double get _max => ((_a['max_temp'] as num?) ?? 30).toDouble();
  double get _step => ((_a['target_temp_step'] as num?) ?? 0.5).toDouble();

  void _set(double v) {
    final t = ((v / _step).round() * _step).clamp(_min, _max).toDouble();
    setState(() => _target = t);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () {
      widget.ha.service('climate', 'set_temperature', {
        'entity_id': widget.entity,
        'temperature': t,
      });
    });
  }

  void _drag(Offset p, Size size) {
    final c = size.center(Offset.zero);
    var rel = atan2(p.dy - c.dy, p.dx - c.dx) - _arcStart;
    rel = (rel % (2 * pi) + 2 * pi) % (2 * pi);
    if (rel > _arcSweep)
      rel = rel < _arcSweep + (2 * pi - _arcSweep) / 2 ? _arcSweep : 0;
    _set(_min + rel / _arcSweep * (_max - _min));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ha,
      builder: (context, _) {
        final state = widget.ha[widget.entity]?['state'] as String?;
        final offline = isOffline(state);
        final target =
            _target ??
            ((_a['temperature'] as num?)?.toDouble() ?? (_min + _max) / 2);
        final current = _a['current_temperature'] as num?;
        final color = state == 'cool'
            ? coolColor
            : state == 'off' || offline
            ? muted
            : heatColor;
        final modes = List<String>.from(_a['hvac_modes'] ?? const []);
        const size = Size(260, 260);
        return Column(
          children: [
            Text(
              friendly(widget.ha, widget.entity),
              style: gs(22, weight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RoundButton(
                  icon: Icons.remove,
                  onTap: offline ? null : () => _set(target - _step),
                ),
                const SizedBox(width: 28),
                GestureDetector(
                  onPanDown: offline
                      ? null
                      : (d) => _drag(d.localPosition, size),
                  onPanUpdate: offline
                      ? null
                      : (d) => _drag(d.localPosition, size),
                  child: CustomPaint(
                    size: size,
                    painter: _ArcPainter(
                      ((target - _min) / (_max - _min)).clamp(0.0, 1.0),
                      color,
                    ),
                    child: SizedBox.fromSize(
                      size: size,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            offline
                                ? 'Sin conexión'
                                : hvacNames[state] ?? state ?? '',
                            style: gs(16, color: color),
                          ),
                          Text(
                            offline
                                ? '--'
                                : '${target.toStringAsFixed(_step < 1 ? 1 : 0)}°',
                            style: gsd(68, height: 1.1),
                          ),
                          if (current != null)
                            Text(
                              'Ahora $current°',
                              style: gs(15, color: muted),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 28),
                _RoundButton(
                  icon: Icons.add,
                  onTap: offline ? null : () => _set(target + _step),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                for (final m in modes)
                  ChoiceChip(
                    label: Text(
                      hvacNames[m] ?? m,
                      style: gs(15, color: m == state ? bg : onSurface),
                    ),
                    selected: m == state,
                    selectedColor: color,
                    backgroundColor: surfaceHigh,
                    showCheckmark: false,
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    onSelected: offline
                        ? null
                        : (_) => widget.ha.service('climate', 'set_hvac_mode', {
                            'entity_id': widget.entity,
                            'hvac_mode': m,
                          }),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

const _arcStart = 3 * pi / 4; // 7:30 position
const _arcSweep = 3 * pi / 2; // 270°

class _ArcPainter extends CustomPainter {
  final double t;
  final Color color;
  _ArcPainter(this.t, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 - 14,
    );
    final track = Paint()
      ..color = surfaceHigh
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _arcStart, _arcSweep, false, track);
    canvas.drawArc(rect, _arcStart, _arcSweep * t, false, track..color = color);
    final a = _arcStart + _arcSweep * t;
    final knob = rect.center + Offset(cos(a), sin(a)) * (rect.width / 2);
    canvas.drawCircle(knob, 14, Paint()..color = Colors.white);
    canvas.drawCircle(knob, 8, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.t != t || old.color != color;
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _RoundButton({required this.icon, this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: surfaceHigh,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: SizedBox(
        width: 64,
        height: 64,
        child: Icon(icon, size: 30, color: onTap == null ? muted : onSurface),
      ),
    ),
  );
}
