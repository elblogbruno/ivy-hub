import 'dart:async';

import 'package:flutter/material.dart';

import 'ha.dart';
import 'rooms.dart' show friendly;
import 'ui.dart';

// media_player supported_features bits
const _pause = 1,
    _volumeSet = 4,
    _prev = 16,
    _next = 32,
    _turnOn = 128,
    _turnOff = 256,
    _play = 16384;

const _stateNames = {
  'playing': 'Reproduciendo',
  'paused': 'En pausa',
  'idle': 'Inactivo',
  'on': 'Encendido',
  'off': 'Apagado',
  'standby': 'En espera',
  'buffering': 'Cargando',
};

int _rank(String? s) => switch (s) {
  'playing' => 0,
  'paused' => 1,
  'buffering' => 1,
  'on' || 'idle' => 2,
  _ => 3,
};

/// Players worth showing (online), most active first.
List<String> livePlayers(HA ha) =>
    ha.mediaPlayers
        .where((id) => !isOffline(ha[id]?['state'] as String?))
        .toList()
      ..sort(
        (a, b) => _rank(ha[a]?['state']).compareTo(_rank(ha[b]?['state'])),
      );

String? artworkUrl(HA ha, String id) {
  final p = ha[id]?['attributes']?['entity_picture'] as String?;
  return p == null ? null : (p.startsWith('http') ? p : '$haBase$p');
}

IconData playerIcon(HA ha, String id) {
  final n =
      '${ha[id]?['attributes']?['device_class'] ?? ''} ${friendly(ha, id)}'
          .toLowerCase();
  return n.contains('tv')
      ? Icons.tv
      : n.contains('display') || n.contains('hub')
      ? Icons.smart_display
      : Icons.speaker;
}

class MediaPage extends StatefulWidget {
  final HA ha;
  const MediaPage({super.key, required this.ha});
  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final ha = widget.ha;
    return ListenableBuilder(
      listenable: ha,
      builder: (context, _) {
        final players = livePlayers(ha);
        if (players.isEmpty) {
          return Center(
            child: Text(
              ha.connected ? 'No hay reproductores disponibles' : 'Conectando…',
              style: gs(18, color: muted),
            ),
          );
        }
        final sel = players.contains(_selected) ? _selected! : players.first;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 270,
              child: ListView(
                children: [
                  for (final id in players)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: id == sel ? surfaceHigh : surface,
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => setState(() => _selected = id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  playerIcon(ha, id),
                                  color: ha[id]?['state'] == 'playing'
                                      ? accent
                                      : muted,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        friendly(ha, id),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: gs(16),
                                      ),
                                      Text(
                                        _stateNames[ha[id]?['state']] ??
                                            '${ha[id]?['state']}',
                                        style: gs(13, color: muted),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: NowPlaying(ha: ha, entity: sel),
            ),
          ],
        );
      },
    );
  }
}

class NowPlaying extends StatefulWidget {
  final HA ha;
  final String entity;
  const NowPlaying({super.key, required this.ha, required this.entity});
  @override
  State<NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<NowPlaying> {
  Timer? _tick;
  double? _volume;

  @override
  void initState() {
    super.initState();
    // Progress bar only; HA sends position + timestamp, we extrapolate.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.ha[widget.entity]?['state'] == 'playing')
        setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _svc(String service, [Map<String, dynamic> data = const {}]) => widget.ha
      .service('media_player', service, {'entity_id': widget.entity, ...data});

  @override
  Widget build(BuildContext context) {
    final ha = widget.ha;
    final s = ha[widget.entity];
    final state = s?['state'] as String?;
    final a = (s?['attributes'] ?? const {}) as Map;
    final f = (a['supported_features'] as num?)?.toInt() ?? 0;
    final art = artworkUrl(ha, widget.entity);
    final title = a['media_title'] as String?;
    final sub = [
      a['media_artist'],
      a['media_album_name'],
    ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
    final playing = state == 'playing';
    final off = state == 'off' || state == 'standby';
    final dur = (a['media_duration'] as num?)?.toDouble();
    var pos = (a['media_position'] as num?)?.toDouble();
    final updated = DateTime.tryParse(
      a['media_position_updated_at'] as String? ?? '',
    );
    if (pos != null && updated != null && playing)
      pos += DateTime.now().difference(updated).inMilliseconds / 1000;

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: surface),
          // Cheap "blur": decode artwork at 24px and let the GPU upscale it.
          if (art != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              child: Image(
                key: ValueKey(art),
                image: ResizeImage(NetworkImage(art), width: 24),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const SizedBox(),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(color: Color(0xA6000000)),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(playerIcon(ha, widget.entity), color: muted, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          friendly(ha, widget.entity),
                          a['app_name'],
                        ].whereType<String>().join('  ·  '),
                        style: gs(15, color: muted),
                      ),
                    ),
                    if (f & (_turnOn | _turnOff) != 0)
                      IconButton(
                        onPressed: () => _svc(off ? 'turn_on' : 'turn_off'),
                        icon: Icon(
                          Icons.power_settings_new,
                          color: off ? muted : good,
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: 170,
                        height: 170,
                        color: surfaceHigh,
                        child: art == null
                            ? Icon(
                                playerIcon(ha, widget.entity),
                                size: 72,
                                color: muted,
                              )
                            : Image(
                                image: ResizeImage(
                                  NetworkImage(art),
                                  width: 340,
                                ),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Icon(
                                  playerIcon(ha, widget.entity),
                                  size: 72,
                                  color: muted,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 22),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title ?? (_stateNames[state] ?? ''),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: gs(
                              28,
                              weight: FontWeight.w500,
                              height: 1.15,
                            ),
                          ),
                          if (sub.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: gs(17, color: muted),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (dur != null && dur > 0 && pos != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (pos / dur).clamp(0.0, 1.0),
                      minHeight: 4,
                      color: onSurface,
                      backgroundColor: const Color(0x33FFFFFF),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (f & _prev != 0)
                      IconButton(
                        iconSize: 36,
                        onPressed: () => _svc('media_previous_track'),
                        icon: const Icon(Icons.skip_previous, color: onSurface),
                      ),
                    if (f & (_play | _pause) != 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Material(
                          color: onSurface,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _svc('media_play_pause'),
                            child: SizedBox(
                              width: 64,
                              height: 64,
                              child: Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                                size: 36,
                                color: bg,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (f & _next != 0)
                      IconButton(
                        iconSize: 36,
                        onPressed: () => _svc('media_next_track'),
                        icon: const Icon(Icons.skip_next, color: onSurface),
                      ),
                    const Spacer(),
                    if (f & _volumeSet != 0) ...[
                      const Icon(Icons.volume_up, color: muted),
                      SizedBox(
                        width: 200,
                        child: Slider(
                          value:
                              _volume ??
                              ((a['volume_level'] as num?)?.toDouble() ?? 0),
                          activeColor: onSurface,
                          inactiveColor: const Color(0x33FFFFFF),
                          onChanged: (v) => setState(() => _volume = v),
                          onChangeEnd: (v) {
                            _svc('volume_set', {'volume_level': v});
                            Future.delayed(
                              const Duration(seconds: 2),
                              () => mounted
                                  ? setState(() => _volume = null)
                                  : null,
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
