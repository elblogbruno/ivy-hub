import 'package:flutter/material.dart';

import 'ambient.dart';
import 'camera.dart';
import 'data.dart';
import 'ha.dart';
import 'rooms.dart';
import 'ui.dart';

/// The few MDI icons the dashboard uses; anything else falls back per domain.
const _mdi = {
  'mdi:weather-sunset-up': Icons.wb_twilight,
  'mdi:weather-night': Icons.bedtime,
  'mdi:sleep': Icons.bedtime,
  'mdi:bed': Icons.bedtime,
  'mdi:home': Icons.home,
  'mdi:home-import-outline': Icons.home,
  'mdi:walk': Icons.directions_walk,
  'mdi:exit-run': Icons.directions_walk,
  'mdi:movie': Icons.movie,
  'mdi:lightbulb': Icons.lightbulb,
  'mdi:television': Icons.tv,
};

IconData itemIcon(Item i) =>
    _mdi[i.icon] ??
    switch (i.id.split('.').first) {
      'scene' => Icons.palette,
      'script' => Icons.play_arrow,
      _ => Icons.circle,
    };

/// Native Inicio page; which people, vacuum, camera, quick actions and
/// calendars it shows comes from the `inicio` view of [ivyDashboard].
class HomePage extends StatelessWidget {
  final HA ha;
  final Agenda agenda;
  final Forecast forecast;
  final bool active;
  const HomePage({
    super.key,
    required this.ha,
    required this.agenda,
    required this.forecast,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final v = ha.view('inicio') ?? defaultViews.first;
    final people = v.domain('person').toList();
    final vacuum = v.domain('vacuum').firstOrNull;
    final camera = v.domain('camera').firstOrNull;
    final actions = v.items
        .where((i) => i.id.startsWith('scene.') || i.id.startsWith('script.'))
        .toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListenableBuilder(
                listenable: ha,
                builder: (context, _) => Column(
                  children: [
                    if (people.isNotEmpty) ...[
                      SizedBox(
                        height: 84,
                        child: Row(
                          children: [
                            for (final (i, p) in people.indexed) ...[
                              if (i > 0) const SizedBox(width: 12),
                              Expanded(
                                child: PersonTile(
                                  ha: ha,
                                  entity: p.id,
                                  name: p.name ?? friendly(ha, p.id),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      height: 84,
                      child: Row(
                        children: [
                          if (vacuum != null) ...[
                            Expanded(
                              child: VacuumTile(
                                ha: ha,
                                entity: vacuum.id,
                                name: vacuum.name ?? friendly(ha, vacuum.id),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: WeatherTile(ha: ha, forecast: forecast),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(child: AgendaCard(agenda: agenda)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (camera != null)
                Expanded(
                  child: CameraCard(
                    ha: ha,
                    entity: camera.id,
                    name: camera.name ?? friendly(ha, camera.id),
                    active: active,
                  ),
                )
              else
                const Spacer(),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      for (final (i, a) in actions.take(4).indexed) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(
                          child: _QuickAction(
                            ha: ha,
                            entity: a.id,
                            name: a.name ?? friendly(ha, a.id),
                            icon: itemIcon(a),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  final HA ha;
  final String entity, name;
  final IconData icon;
  const _QuickAction({
    required this.ha,
    required this.entity,
    required this.name,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: surface,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () {
          ha.service(entity.split('.').first, 'turn_on', {'entity_id': entity});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$name activado', style: gs(16)),
              backgroundColor: surfaceHigh,
              behavior: SnackBarBehavior.floating,
              width: 320,
              duration: const Duration(seconds: 2),
            ),
          );
        },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: accent, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: gs(15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _vacuumStates = {
  'cleaning': 'Limpiando',
  'docked': 'En la base',
  'returning': 'Volviendo a la base',
  'idle': 'En espera',
  'paused': 'En pausa',
  'error': 'Error',
};

class VacuumTile extends StatelessWidget {
  final HA ha;
  final String entity, name;
  const VacuumTile({
    super.key,
    required this.ha,
    required this.entity,
    required this.name,
  });
  @override
  Widget build(BuildContext context) {
    final state = ha[entity]?['state'] as String?;
    final cleaning = state == 'cleaning';
    return Tile(
      icon: Icons.cleaning_services,
      name: name,
      state: _vacuumStates[state] ?? unavailableLabel(state),
      on: cleaning,
      offline: isOffline(state),
      onColor: accent,
      onTap: () => ha.service('vacuum', cleaning ? 'return_to_base' : 'start', {
        'entity_id': entity,
      }),
      onMore: () =>
          showIvySheet(context, VacuumSheet(ha: ha, entity: entity, name: name)),
    );
  }
}

class VacuumSheet extends StatelessWidget {
  final HA ha;
  final String entity, name;
  const VacuumSheet({
    super.key,
    required this.ha,
    required this.entity,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ha,
      builder: (context, _) {
        final s = ha[entity];
        final state = s?['state'] as String?;
        final a = (s?['attributes'] ?? const {}) as Map;
        final speeds = List<String>.from(a['fan_speed_list'] ?? const []);
        void cmd(String service) =>
            ha.service('vacuum', service, {'entity_id': entity});
        Widget button(IconData icon, String label, String service) => Column(
          children: [
            IconButton.filledTonal(
              iconSize: 30,
              padding: const EdgeInsets.all(16),
              onPressed: isOffline(state) ? null : () => cmd(service),
              icon: Icon(icon),
            ),
            const SizedBox(height: 6),
            Text(label, style: gs(15, color: muted)),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cleaning_services, color: accent, size: 30),
                const SizedBox(width: 12),
                Text(name, style: gs(24, weight: FontWeight.w500)),
                const Spacer(),
                Text(
                  _vacuumStates[state] ?? unavailableLabel(state),
                  style: gs(18, color: muted),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                button(Icons.play_arrow, 'Limpiar', 'start'),
                button(Icons.pause, 'Pausar', 'pause'),
                button(Icons.home, 'A la base', 'return_to_base'),
                button(Icons.volume_up, 'Localizar', 'locate'),
              ],
            ),
            if (speeds.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text('Potencia', style: gs(16, color: muted)),
              const SizedBox(height: 10),
              OptionChips(
                options: speeds,
                selected: a['fan_speed'] as String?,
                label: (o) => ha.stateName(entity, o, 'fan_speed') ?? o,
                onSelected: (o) => ha.service('vacuum', 'set_fan_speed', {
                  'entity_id': entity,
                  'fan_speed': o,
                }),
              ),
            ],
          ],
        );
      },
    );
  }
}

class PersonTile extends StatelessWidget {
  final HA ha;
  final String entity, name;
  const PersonTile({
    super.key,
    required this.ha,
    required this.entity,
    required this.name,
  });
  @override
  Widget build(BuildContext context) {
    final s = ha[entity];
    final state = s?['state'] as String?;
    final pic = s?['attributes']?['entity_picture'] as String?;
    final home = state == 'home';
    final label = home
        ? 'En casa'
        : state == 'not_home'
        ? 'Fuera'
        : state == null || state == 'unknown'
        ? 'Desconocido'
        : state;
    return Tile(
      icon: Icons.person,
      name: name,
      state: label,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: surfaceHigh,
            foregroundImage: pic == null
                ? null
                : ResizeImage(NetworkImage('$haBase$pic'), width: 96),
            child: const Icon(Icons.person, color: accent),
          ),
          if (home)
            const Positioned(
              right: -2,
              bottom: -2,
              child: CircleAvatar(
                radius: 9,
                backgroundColor: good,
                child: Icon(Icons.home, size: 12, color: bg),
              ),
            ),
        ],
      ),
    );
  }
}

class WeatherTile extends StatelessWidget {
  final HA ha;
  final Forecast forecast;
  const WeatherTile({super.key, required this.ha, required this.forecast});
  @override
  Widget build(BuildContext context) {
    final w = ha['weather.home'];
    final info = weatherInfo[w?['state']];
    final temp = w?['attributes']?['temperature'] as num?;
    return Tile(
      icon: info?.$1 ?? Icons.thermostat,
      name: temp == null ? 'Tiempo' : '${temp.round()} °C',
      state: info?.$2 ?? unavailableLabel(w?['state']),
      onTap: () =>
          showIvySheet(context, WeatherSheet(ha: ha, forecast: forecast)),
    );
  }
}

class WeatherSheet extends StatelessWidget {
  final HA ha;
  final Forecast forecast;
  const WeatherSheet({super.key, required this.ha, required this.forecast});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: forecast,
      builder: (context, _) {
        final w = ha['weather.home'];
        final a = w?['attributes'] ?? {};
        final info = weatherInfo[w?['state']];
        final today = forecast.daily.isEmpty ? null : forecast.daily.first;
        final now = DateTime.now();
        final hours = forecast.hourly
            .where(
              (h) => DateTime.parse(
                h['datetime'],
              ).toLocal().isAfter(now.subtract(const Duration(hours: 1))),
            )
            .take(8)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(info?.$1 ?? Icons.thermostat, color: accent, size: 64),
                const SizedBox(width: 18),
                Text(
                  '${(a['temperature'] as num?)?.round() ?? '--'}°',
                  style: gsd(72, height: 1),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info?.$2 ?? '',
                        style: gs(22, weight: FontWeight.w500),
                      ),
                      if (today != null)
                        Text(
                          'Máx ${(today['temperature'] as num).round()}°  ·  Mín ${(today['templow'] as num?)?.round() ?? '--'}°',
                          style: gs(17, color: muted),
                        ),
                      Text(
                        'Humedad ${a['humidity'] ?? '--'} %  ·  Viento ${(a['wind_speed'] as num?)?.round() ?? '--'} km/h',
                        style: gs(15, color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final h in hours)
                  Column(
                    children: [
                      Text(
                        two(DateTime.parse(h['datetime']).toLocal().hour),
                        style: gs(15, color: muted),
                      ),
                      const SizedBox(height: 6),
                      Icon(
                        weatherInfo[h['condition']]?.$1 ?? Icons.cloud,
                        color: onSurface,
                        size: 26,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${(h['temperature'] as num).round()}°',
                        style: gs(17),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 18),
            const Divider(color: surfaceHigh),
            for (final d in forecast.daily.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        dayLabel(DateTime.parse(d['datetime']).toLocal()),
                        style: gs(17),
                      ),
                    ),
                    Icon(
                      weatherInfo[d['condition']]?.$1 ?? Icons.cloud,
                      color: accent,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        weatherInfo[d['condition']]?.$2 ?? '',
                        style: gs(15, color: muted),
                      ),
                    ),
                    if ((d['precipitation_probability'] as num? ?? 0) > 0)
                      Text(
                        '${d['precipitation_probability']} %   ',
                        style: gs(15, color: accent),
                      ),
                    Text(
                      '${(d['temperature'] as num).round()}°',
                      style: gs(17, weight: FontWeight.w500),
                    ),
                    Text(
                      '  ${(d['templow'] as num?)?.round() ?? '--'}°',
                      style: gs(17, color: muted),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class AgendaCard extends StatelessWidget {
  final Agenda agenda;
  const AgendaCard({super.key, required this.agenda});

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      child: ListenableBuilder(
        listenable: agenda,
        builder: (context, _) {
          final events = agenda.upcoming().take(4).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.calendar_today, color: accent, size: 18),
                  const SizedBox(width: 8),
                  Text('Agenda', style: gs(17, weight: FontWeight.w500)),
                ],
              ),
              const SizedBox(height: 10),
              if (events.isEmpty)
                Text('Nada en los próximos días', style: gs(15, color: muted)),
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 4,
                        height: 38,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          color: _calColor(e.calendar),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: gs(16),
                            ),
                            Text(
                              '${dayLabel(e.start)}${e.allDay ? '' : ' · ${hhmm(e.start)}'}  ·  ${e.calendar}',
                              style: gs(13, color: muted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

Color _calColor(String cal) => switch (cal) {
  'Familia' => good,
  'Cumpleaños' => const Color(0xFFF28B82),
  'Festivos' => heatColor,
  _ => accent,
};
