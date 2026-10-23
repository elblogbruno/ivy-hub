import 'package:flutter/material.dart';

import 'ambient.dart';
import 'camera.dart';
import 'ha.dart';
import 'home.dart';
import 'rooms.dart';
import 'ui.dart';

const _classIcons = {
  'battery': Icons.battery_std,
  'temperature': Icons.thermostat,
  'humidity': Icons.water_drop,
  'duration': Icons.timer,
  'power': Icons.bolt,
  'energy': Icons.bolt,
  'motion': Icons.directions_run,
  'door': Icons.door_front_door,
  'window': Icons.window,
  'enum': Icons.list,
  'timestamp': Icons.schedule,
};

const _domainIcons = {
  'sensor': Icons.sensors,
  'binary_sensor': Icons.radio_button_checked,
  'media_player': Icons.speaker,
  'device_tracker': Icons.location_on,
  'select': Icons.list,
  'input_select': Icons.list,
  'number': Icons.tune,
  'input_number': Icons.tune,
  'button': Icons.touch_app,
  'input_button': Icons.touch_app,
};

/// Human state: rounded numbers + unit, dates, HA's Spanish names; else raw.
String stateLabel(HA ha, String id) {
  final s = ha[id];
  final st = s?['state'] as String?;
  if (isOffline(st)) return unavailableLabel(st);
  final a = (s?['attributes'] ?? const {}) as Map;
  if (a['device_class'] == 'timestamp') {
    final t = DateTime.tryParse(st!)?.toLocal();
    if (t != null) return '${dayLabel(t)} · ${hhmm(t)}';
  }
  final n = num.tryParse(st!);
  final v = n == null
      ? ha.stateName(id, st) ??
            const {'on': 'Activado', 'off': 'Desactivado'}[st] ??
            st
      : n % 1 == 0
      ? '${n.round()}'
      : n.toStringAsFixed(1);
  final unit = a['unit_of_measurement'];
  return unit == null ? v : '$v $unit';
}

/// One tile for any entity: native tiles where they exist, a read-only
/// state tile for everything else.
Widget entityWidget(BuildContext context, HA ha, Item i) {
  final id = i.id;
  final domain = id.split('.').first;
  final name = i.name ?? friendly(ha, id);
  final state = ha[id]?['state'] as String?;
  final a = (ha[id]?['attributes'] ?? const {}) as Map;
  final offline = isOffline(state);
  final icon =
      _classIcons[a['device_class']] ?? _domainIcons[domain] ?? Icons.info_outline;
  switch (domain) {
    case 'light' ||
        'climate' ||
        'cover' ||
        'lock' ||
        'switch' ||
        'fan' ||
        'input_boolean':
      return EntityTile(ha: ha, entity: id, name: i.name);
    case 'person':
      return PersonTile(ha: ha, entity: id, name: name);
    case 'vacuum':
      return VacuumTile(ha: ha, entity: id, name: name);
    case 'scene' || 'script':
      return Tile(
        icon: itemIcon(i),
        name: name,
        state: 'Activar',
        onTap: () => ha.service(domain, 'turn_on', {'entity_id': id}),
      );
    case 'button' || 'input_button':
      return Tile(
        icon: icon,
        name: name,
        state: 'Pulsar',
        offline: state == 'unavailable',
        onTap: () => ha.service(domain, 'press', {'entity_id': id}),
      );
    case 'select' || 'input_select':
      return Tile(
        icon: icon,
        name: name,
        state: stateLabel(ha, id),
        offline: offline,
        onTap: () => showIvySheet(
          context,
          ListenableBuilder(
            listenable: ha,
            builder: (_, _) => _SheetBody(
              title: name,
              child: OptionChips(
                options: List<String>.from(
                  ha[id]?['attributes']?['options'] ?? const [],
                ),
                selected: ha[id]?['state'] as String?,
                label: (o) => ha.stateName(id, o) ?? o,
                onSelected: (o) => ha.service(domain, 'select_option', {
                  'entity_id': id,
                  'option': o,
                }),
              ),
            ),
          ),
        ),
      );
    case 'number' || 'input_number':
      final min = (a['min'] as num?) ?? 0, max = (a['max'] as num?) ?? 100;
      final step = (a['step'] as num?) ?? 1;
      num at(double t) => ((min + t * (max - min)) / step).round() * step;
      final cur = num.tryParse(state ?? '') ?? min;
      return Tile(
        icon: icon,
        name: name,
        state: stateLabel(ha, id),
        offline: offline,
        onTap: () => showIvySheet(
          context,
          _SheetBody(
            title: name,
            child: FillSlider(
              value: max == min ? 0 : ((cur - min) / (max - min)).toDouble(),
              label: (t) => '${at(t)} ${a['unit_of_measurement'] ?? ''}',
              onChanged: (_) {},
              onChangeEnd: (t) => ha.service(domain, 'set_value', {
                'entity_id': id,
                'value': at(t),
              }),
              color: accent,
            ),
          ),
        ),
      );
    default:
      return Tile(
        icon: icon,
        name: name,
        state: stateLabel(ha, id),
        on: domain == 'binary_sensor' && state == 'on',
        onColor: accent,
        offline: offline,
      );
  }
}

class _SheetBody extends StatelessWidget {
  final String title;
  final Widget child;
  const _SheetBody({required this.title, required this.child});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: gs(24, weight: FontWeight.w500)),
      const SizedBox(height: 18),
      child,
    ],
  );
}

bool _visual(Item i) =>
    i.id.startsWith('camera.') || i.id.startsWith('image.');

/// Any dashboard view without a native page: cameras/images (e.g. the
/// Roborock map) on the left, a tile per remaining entity on the right.
class ViewPage extends StatelessWidget {
  final HA ha;
  final IvyView view;
  final bool active;
  const ViewPage({
    super.key,
    required this.ha,
    required this.view,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final visuals = view.items.where(_visual).toList();
    final tiles = view.items.where((i) => !_visual(i)).toList();
    if (view.items.isEmpty) {
      return Center(
        child: Text(
          'Añade tarjetas a la vista "${view.title}" en Home Assistant',
          style: gs(18, color: muted),
        ),
      );
    }
    final grid = ListenableBuilder(
      listenable: ha,
      builder: (context, _) => GridView(
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: visuals.isEmpty ? 3 : 1,
          mainAxisExtent: 84,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        children: [for (final i in tiles) entityWidget(context, ha, i)],
      ),
    );
    if (visuals.isEmpty) return grid;
    final big = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (n, i) in visuals.indexed) ...[
          if (n > 0) const SizedBox(height: 12),
          Expanded(
            child: i.id.startsWith('camera.')
                ? CameraCard(
                    ha: ha,
                    entity: i.id,
                    name: i.name ?? friendly(ha, i.id),
                    active: active,
                  )
                : HaImage(ha: ha, item: i),
          ),
        ],
      ],
    );
    if (tiles.isEmpty) return big;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 6, child: big),
        const SizedBox(width: 16),
        Expanded(flex: 5, child: grid),
      ],
    );
  }
}

/// image.* entity (Roborock map, etc.): reloads whenever its state (the
/// last-update timestamp) or its rotating access token changes.
class HaImage extends StatelessWidget {
  final HA ha;
  final Item item;
  const HaImage({super.key, required this.ha, required this.item});

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: ListenableBuilder(
          listenable: ha,
          builder: (context, _) {
            final s = ha[item.id];
            final pic = s?['attributes']?['entity_picture'] as String?;
            final placeholder = Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.image_not_supported, color: muted, size: 40),
                  const SizedBox(height: 8),
                  Text(
                    '${item.name ?? friendly(ha, item.id)}: sin imagen',
                    style: gs(16, color: muted),
                  ),
                ],
              ),
            );
            if (pic == null || isOffline(s?['state'] as String?)) {
              return placeholder;
            }
            return Image.network(
              '$haBase$pic${pic.contains('?') ? '&' : '?'}v=${Uri.encodeQueryComponent('${s?['state']}')}',
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
            );
          },
        ),
      ),
    );
  }
}
