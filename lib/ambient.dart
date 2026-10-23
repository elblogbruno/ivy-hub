import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';

import 'clock.dart';
import 'data.dart';
import 'frog.dart';
import 'ha.dart';
import 'media.dart';
import 'rooms.dart' show friendly;
import 'spotify.dart';
import 'ui.dart';

const _photosRoot =
    'media-source://media_source/local/Viajes/Imagenes Viajes/Viajes';
const _days = [
  'lunes',
  'martes',
  'miércoles',
  'jueves',
  'viernes',
  'sábado',
  'domingo',
];
const monthNames = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

String two(int n) => n.toString().padLeft(2, '0');
String hhmm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';
String longDate(DateTime t) {
  final s = '${_days[t.weekday - 1]}, ${t.day} de ${monthNames[t.month - 1]}';
  return s[0].toUpperCase() + s.substring(1);
}

/// "Hoy", "Mañana" or "Lunes 19".
String dayLabel(DateTime d) {
  final now = DateTime.now();
  final diff = DateTime(
    d.year,
    d.month,
    d.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (diff == 0) return 'Hoy';
  if (diff == 1) return 'Mañana';
  final s = '${_days[d.weekday - 1]} ${d.day}';
  return s[0].toUpperCase() + s.substring(1);
}

/// Google Smart Display sleep window: dim clock instead of photos.
bool isNightTime(DateTime t) => t.hour >= 23 || t.hour < 7;

const weatherInfo = <String, (IconData, String)>{
  'clear-night': (Icons.nightlight_round, 'Despejado'),
  'cloudy': (Icons.cloud, 'Nublado'),
  'exceptional': (Icons.warning_amber, 'Excepcional'),
  'fog': (Icons.foggy, 'Niebla'),
  'hail': (Icons.grain, 'Granizo'),
  'lightning': (Icons.flash_on, 'Tormenta'),
  'lightning-rainy': (Icons.thunderstorm, 'Tormenta'),
  'partlycloudy': (Icons.wb_cloudy, 'Parcialmente nublado'),
  'pouring': (Icons.water_drop, 'Lluvia intensa'),
  'rainy': (Icons.umbrella, 'Lluvia'),
  'snowy': (Icons.ac_unit, 'Nieve'),
  'snowy-rainy': (Icons.ac_unit, 'Aguanieve'),
  'sunny': (Icons.wb_sunny, 'Soleado'),
  'windy': (Icons.air, 'Viento'),
  'windy-variant': (Icons.air, 'Viento'),
};

/// Rebuilds once per minute boundary instead of every second.
class MinuteClock extends StatefulWidget {
  final Widget Function(BuildContext, DateTime) builder;
  const MinuteClock({super.key, required this.builder});
  @override
  State<MinuteClock> createState() => _MinuteClockState();
}

class _MinuteClockState extends State<MinuteClock> {
  DateTime _now = DateTime.now();
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _t = Timer(Duration(seconds: 60 - DateTime.now().second), () {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _schedule();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}

class AmbientPage extends StatefulWidget {
  final HA ha;
  final Agenda agenda;
  final Forecast forecast;
  final Clocks clocks;
  final Spotify spotify;
  final bool night, off;
  final VoidCallback onOpen, onMedia, onWake;

  /// Drag that starts at the right edge moves the page itself (live), like Google.
  final ValueChanged<double> onEdgeDrag, onEdgeEnd;
  const AmbientPage({
    super.key,
    required this.ha,
    required this.agenda,
    required this.forecast,
    required this.clocks,
    required this.spotify,
    required this.night,
    required this.off,
    required this.onOpen,
    required this.onMedia,
    required this.onWake,
    required this.onEdgeDrag,
    required this.onEdgeEnd,
  });
  @override
  State<AmbientPage> createState() => _AmbientPageState();
}

class _Photo {
  final String id, album;
  const _Photo(this.id, this.album);
}

/// One ambient "slide": a landscape photo, two portraits side by side,
/// a single portrait on a blurred fill, or the frog interlude.
class _Slide {
  final List<NetworkImage> photos;
  final bool portrait;
  final String? album;
  final DateTime? date; // taken from the photo's file name, if parseable
  final String? place; // reverse-geocoded from EXIF GPS, if present
  final String? camera; // EXIF camera model, if present
  final String? frog; // Froggy asset base path
  const _Slide(
    this.photos, {
    this.portrait = false,
    this.album,
    this.date,
    this.place,
    this.camera,
    this.frog,
  });
}

const _frogEvery = 8; // every Nth slide is the frog

// ponytail: decode at screen width so 12MP photos don't exhaust RAM on this 2GB device
ImageProvider _big(NetworkImage n) =>
    ResizeImage(n, width: 1280, policy: ResizeImagePolicy.fit);

class _AmbientPageState extends State<AmbientPage> {
  final _rnd = Random();
  List<(String, String)> _albums = []; // (media_content_id, trip title)
  bool _loading = false, _busy = false;
  int _key = 0, _count = 0;
  Timer? _timer;

  /// Recently shown slides; swiping walks back/forward through them.
  final _history = <_Slide>[];
  int _pos = -1;
  _Slide? get _slide => _pos < 0 ? null : _history[_pos];
  static const _keep = 15;
  static const _slideTime = Duration(seconds: 30);

  bool _edge = false;
  double _dx = 0;

  @override
  void initState() {
    super.initState();
    widget.ha.addListener(_maybeLoad);
    _maybeLoad();
    _restartTimer();
  }

  @override
  void dispose() {
    widget.ha.removeListener(_maybeLoad);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _maybeLoad() async {
    if (!widget.ha.connected || _albums.isNotEmpty || _loading) return;
    _loading = true;
    try {
      final root = await widget.ha.call({
        'type': 'media_source/browse_media',
        'media_content_id': _photosRoot,
      });
      // Just the trip folders; individual photos are fetched lazily per slide —
      // there are ~80k across nested sub-folders, far too many to list up front.
      _albums = [
        for (final a in (root['children'] as List? ?? []))
          if (a['can_expand'] == true)
            (a['media_content_id'] as String, a['title'] as String? ?? ''),
      ];
      debugPrint('Ambient: ${_albums.length} álbumes');
      _next();
    } catch (e) {
      debugPrint('Ambient: $e');
    } finally {
      _loading = false;
    }
  }

  static final _imgExt = RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false);

  /// Picks one random image from a trip by walking its sub-folders down to a
  /// leaf — a handful of browse calls, no full listing. Null if it has none.
  Future<_Photo?> _pickPhoto((String, String) album) async {
    var id = album.$1;
    for (var depth = 0; depth < 6; depth++) {
      final res = await widget.ha.call({
        'type': 'media_source/browse_media',
        'media_content_id': id,
      });
      final children = (res['children'] as List? ?? []);
      final imgs = [
        for (final c in children)
          if (c['can_expand'] != true &&
              _imgExt.hasMatch(c['media_content_id'] as String? ?? ''))
            c['media_content_id'] as String,
      ];
      final dirs = [
        for (final c in children)
          if (c['can_expand'] == true) c['media_content_id'] as String,
      ];
      // Take an image here if there's one and (no sub-folders or a coin flip);
      // otherwise descend into a random sub-folder.
      if (imgs.isNotEmpty && (dirs.isEmpty || _rnd.nextBool())) {
        return _Photo(imgs[_rnd.nextInt(imgs.length)], album.$2);
      }
      if (dirs.isEmpty) return null;
      id = dirs[_rnd.nextInt(dirs.length)];
    }
    return null;
  }

  static const _shortMonth = [
    'ene', 'feb', 'mar', 'abr', 'may', 'jun', //
    'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
  ];

  /// Best-effort date from the file name: 20170104_092804.jpg, IMG20231201163224.jpg,
  /// or a 13-digit epoch like 1437042451140.jpg. Null when nothing looks like a date.
  static DateTime? _photoDate(String id) {
    final name = id.split('/').last;
    final m = RegExp(r'(20[0-2]\d)(\d{2})(\d{2})').firstMatch(name);
    if (m != null) {
      final mo = int.parse(m[2]!), d = int.parse(m[3]!);
      if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
        return DateTime(int.parse(m[1]!), mo, d);
      }
    }
    final e = RegExp(r'(?<!\d)(1\d{12})(?!\d)').firstMatch(name);
    if (e != null) {
      final t = DateTime.fromMillisecondsSinceEpoch(int.parse(e[1]!));
      if (t.year >= 2000 && t.year <= DateTime.now().year) return t;
    }
    return null;
  }

  static String _photoWhen(DateTime d) =>
      '${d.day} ${_shortMonth[d.month - 1]} ${d.year}';

  /// EXIF camera model and GPS place name for a photo, both best-effort/null.
  /// Reads only the file's first chunk (EXIF lives at the start), not the whole image.
  Future<(String?, String?)> _meta(_Photo p) async {
    try {
      final res = await widget.ha.call({
        'type': 'media_source/resolve_media',
        'media_content_id': p.id,
      });
      final u = res['url'] as String;
      final bytes = await _head(u.startsWith('http') ? u : '$haBase$u', 262144);
      if (bytes == null) return (null, null);
      final tags = await readExifFromBytes(bytes);
      var camera = tags['Image Model']?.printable.trim();
      if (camera != null && camera.isEmpty) camera = null;
      final lat = _dms(tags['GPS GPSLatitude'], tags['GPS GPSLatitudeRef']?.printable);
      final lon = _dms(tags['GPS GPSLongitude'], tags['GPS GPSLongitudeRef']?.printable);
      final place = (lat != null && lon != null) ? await _place(lat, lon) : null;
      return (place, camera);
    } catch (_) {
      return (null, null);
    }
  }

  /// First [max] bytes of a URL (honours Range, but also caps manually in case
  /// the server ignores it, so we never pull a whole multi-MB photo for EXIF).
  Future<List<int>?> _head(String url, int max) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.add(HttpHeaders.rangeHeader, 'bytes=0-${max - 1}');
      final res = await req.close();
      final out = <int>[];
      await for (final chunk in res) {
        out.addAll(chunk);
        if (out.length >= max) break;
      }
      return out;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// EXIF GPS coordinate (degrees/minutes/seconds ratios) to a signed decimal.
  static double? _dms(IfdTag? tag, String? ref) {
    if (tag == null) return null;
    final v = tag.values.toList();
    if (v.length < 3) return null;
    try {
      var dd = (v[0] as Ratio).toDouble() +
          (v[1] as Ratio).toDouble() / 60 +
          (v[2] as Ratio).toDouble() / 3600;
      if (ref == 'S' || ref == 'W') dd = -dd;
      return dd;
    } catch (_) {
      return null;
    }
  }

  // Reverse-geocode cache, keyed by coords rounded to ~11 km, so a whole trip's
  // photos cost at most a couple of OpenStreetMap lookups.
  static final _places = <String, String?>{};
  Future<String?> _place(double lat, double lon) async {
    final key = '${lat.toStringAsFixed(1)},${lon.toStringAsFixed(1)}';
    if (_places.containsKey(key)) return _places[key];
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=10'
          '&lat=$lat&lon=$lon&accept-language=es',
        ),
      );
      req.headers.add(HttpHeaders.userAgentHeader, 'ivy-display/1.0 (home photo frame)');
      final res = await req.close();
      final a = (jsonDecode(await utf8.decodeStream(res))['address'] as Map?) ?? {};
      final city = a['city'] ?? a['town'] ?? a['village'] ?? a['county'] ?? a['state'];
      final place = [city, a['country']].where((x) => x != null).join(', ');
      return _places[key] = place.isEmpty ? null : place;
    } catch (_) {
      return _places[key] = null;
    } finally {
      client.close(force: true);
    }
  }

  /// Resolves, downloads and decodes one photo; returns it and whether it is portrait.
  Future<(NetworkImage, bool)> _load(_Photo p) async {
    final res = await widget.ha.call({
      'type': 'media_source/resolve_media',
      'media_content_id': p.id,
    });
    final url = res['url'] as String;
    final n = NetworkImage(url.startsWith('http') ? url : '$haBase$url');
    final c = Completer<Size>();
    final stream = _big(n).resolve(ImageConfiguration.empty);
    late final ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) {
        if (!c.isCompleted)
          c.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()),
          );
        stream.removeListener(l);
      },
      onError: (e, _) {
        if (!c.isCompleted) c.completeError(e);
        stream.removeListener(l);
      },
    );
    stream.addListener(l);
    final size = await c.future.timeout(const Duration(seconds: 40));
    return (n, size.height > size.width * 1.1);
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_slideTime, (_) => _next());
  }

  void _prev() {
    if (_pos <= 0) return;
    setState(() {
      _pos--;
      _key++;
    });
  }

  /// Advance: instant when the next slide is already prefetched, otherwise
  /// show it as soon as the background load finishes.
  void _next() {
    if (_pos < _history.length - 1) {
      setState(() {
        _pos++;
        _key++;
      });
    } else {
      _wantNext = true;
    }
    _prefetch();
  }

  bool _wantNext = false;

  /// Keeps one slide loaded ahead of the one on screen; never moves the
  /// position itself unless the user (or the timer) asked for it.
  Future<void> _prefetch() async {
    if (_busy ||
        widget.spotify.active ||
        _pos < _history.length - 1 ||
        _albums.isEmpty ||
        !widget.ha.connected ||
        widget.night) {
      return;
    }
    _busy = true;
    try {
      final slide = await _build();
      if (!mounted) return;
      setState(() {
        _history.add(slide);
        if (_history.length > _keep) {
          for (final n in _history.removeAt(0).photos) {
            imageCache.evict(_big(n));
          }
          _pos--;
        }
        if (_wantNext) {
          _wantNext = false;
          _pos = _history.length - 1;
          _key++;
        }
      });
    } catch (e) {
      debugPrint('Ambient prefetch: $e');
    } finally {
      _busy = false;
    }
    // Stay one ahead (also retries after a failed load), without hammering HA.
    if (mounted && _pos == _history.length - 1) {
      Future.delayed(const Duration(seconds: 2), _prefetch);
    }
  }

  Future<_Slide> _build() async {
    if (hasFrog && ++_count % _frogEvery == 0) {
      return _Slide(const [], frog: frogScene(widget.ha, _rnd));
    }
    // Pick a trip first, then a random photo in it, so every trip shows equally
    // often regardless of size (otherwise the biggest album drowns out the rest).
    _Photo? first;
    (String, String)? album;
    for (var i = 0; i < 6 && first == null; i++) {
      album = _albums[_rnd.nextInt(_albums.length)];
      first = await _pickPhoto(album);
    }
    if (first == null) throw 'no photo found';
    final date = _photoDate(first.id);
    final (place, camera) = await _meta(first);
    final (img, portrait) = await _load(first);
    if (!portrait) {
      return _Slide(
        [img],
        album: first.album,
        date: date,
        place: place,
        camera: camera,
      );
    }
    // Google pairs portraits from the same trip (same moment).
    NetworkImage? second;
    for (var i = 0; i < 3 && second == null; i++) {
      final p = await _pickPhoto(album!);
      if (p == null || p.id == first.id) continue;
      try {
        final (img2, portrait2) = await _load(p);
        if (portrait2) {
          second = img2;
        } else {
          imageCache.evict(_big(img2));
        }
      } catch (_) {}
    }
    return _Slide(
      [img, ?second],
      portrait: true,
      album: first.album,
      date: date,
      place: place,
      camera: camera,
    );
  }

  Widget _slideView(_Slide s) {
    if (s.frog != null) return FrogScene(key: ValueKey(_key), base: s.frog!);
    if (s.photos.length == 2) {
      return KenBurns(
        key: ValueKey(_key),
        seed: _key,
        child: Row(
          children: [
            Expanded(child: _photo(s.photos[0])),
            const SizedBox(width: 6),
            Expanded(child: _photo(s.photos[1])),
          ],
        ),
      );
    }
    if (s.portrait) {
      // Single portrait: blurred cover fill behind the contained photo.
      return Stack(
        key: ValueKey(_key),
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: _photo(s.photos[0]),
          ),
          const ColoredBox(color: Color(0x55000000)),
          Image(
            image: _big(s.photos[0]),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ],
      );
    }
    return KenBurns(
      key: ValueKey(_key),
      seed: _key,
      child: _photo(s.photos[0]),
    );
  }

  Widget _photo(NetworkImage n) => Image(
    image: _big(n),
    fit: BoxFit.cover,
    gaplessPlayback: true,
    filterQuality: FilterQuality.medium,
  );

  /// Rotating ambient line (Google's "hambient ticker").
  List<(IconData, String)> _tickerMessages() {
    final out = <(IconData, String)>[];
    final now = DateTime.now();
    for (final t in widget.clocks.timers.where((t) => !t.paused)) {
      out.add((Icons.timer, 'Temporizador · termina a las ${hhmm(t.end!)}'));
    }
    final alarm = widget.clocks.nextAlarm();
    if (alarm != null && alarm.difference(now) < const Duration(hours: 14)) {
      out.add((
        Icons.alarm,
        'Alarma ${dayLabel(alarm).toLowerCase()} a las ${hhmm(alarm)}',
      ));
    }
    for (final e
        in widget.agenda
            .upcoming()
            .where((e) => e.start.difference(now).inDays < 2)
            .take(2)) {
      out.add((
        Icons.event,
        '${dayLabel(e.start)}${e.allDay ? '' : ' ${hhmm(e.start)}'} · ${e.title}',
      ));
    }
    if (widget.forecast.daily.isNotEmpty) {
      final d = widget.forecast.daily.first;
      final rain = d['precipitation_probability'] as num?;
      out.add((
        weatherInfo[d['condition']]?.$1 ?? Icons.thermostat,
        'Máx ${(d['temperature'] as num).round()}° · Mín ${(d['templow'] as num?)?.round() ?? '--'}°'
            '${rain != null && rain >= 20 ? ' · Lluvia $rain %' : ''}',
      ));
    }
    for (final MapEntry(key: id, value: st) in widget.ha.states.entries) {
      if (id.startsWith('vacuum.') && st['state'] == 'cleaning') {
        out.add((
          Icons.cleaning_services,
          '${st['attributes']?['friendly_name'] ?? 'El robot'} está limpiando',
        ));
      }
    }
    return out;
  }

  @override
  void didUpdateWidget(AmbientPage old) {
    super.didUpdateWidget(old);
    if (old.night && !widget.night) _next();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.off) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onWake,
        child: const ColoredBox(color: Colors.black),
      );
    }
    // Music from Spotify Connect takes over the ambient screen (dark room still blanks it).
    if (widget.spotify.active) {
      // Buttons need plain taps; the right-edge drag still moves to the next screen.
      // Only the bezel strip: the lyrics button ends 48 px from the edge.
      return GestureDetector(
        onHorizontalDragStart: (d) =>
            _edge = d.localPosition.dx > context.size!.width - 24,
        onHorizontalDragUpdate: (d) =>
            _edge ? widget.onEdgeDrag(d.delta.dx) : null,
        onHorizontalDragEnd: (d) =>
            _edge ? widget.onEdgeEnd(d.primaryVelocity ?? 0) : null,
        child: SpotifyView(spotify: widget.spotify),
      );
    }
    if (widget.night)
      return NightView(clocks: widget.clocks, onWake: widget.onWake);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onOpen,
      onHorizontalDragStart: (d) {
        _edge = d.localPosition.dx > context.size!.width - 56;
        _dx = 0;
      },
      onHorizontalDragUpdate: (d) =>
          _edge ? widget.onEdgeDrag(d.delta.dx) : _dx += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_edge) return widget.onEdgeEnd(v);
        if (_dx < -60 || v < -500) {
          _next();
        } else if (_dx > 60 || v > 500) {
          _prev();
        }
        _restartTimer(); // a manually chosen photo gets its full time
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 1600),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            layoutBuilder: (cur, prev) =>
                Stack(fit: StackFit.expand, children: [...prev, ?cur]),
            child: _slide == null
                ? const SizedBox.expand()
                : _slideView(_slide!),
          ),
          // Legibility scrim behind the clock
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment(0, 0.1),
                colors: [Color(0x99000000), Color(0x00000000)],
              ),
            ),
          ),
          Positioned(
            left: 40,
            bottom: 24,
            right: 340,
            child: _Overlay(ha: widget.ha, messages: _tickerMessages),
          ),
          Positioned(
            top: 22,
            left: 24,
            child: NowPlayingPill(ha: widget.ha, onTap: widget.onMedia),
          ),
          Positioned(
            right: 26,
            bottom: 26,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 800),
              child: (_slide?.album ?? '').isEmpty
                  ? const SizedBox()
                  : Row(
                      key: ValueKey('${_slide!.album}|${_slide!.date}'),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Icon(
                          Icons.photo_library_outlined,
                          color: Color(0xDDFFFFFF),
                          size: 18,
                          shadows: _shadow,
                        ),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _slide!.album!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _sub.copyWith(
                                  fontSize: 17,
                                  color: const Color(0xDDFFFFFF),
                                ),
                              ),
                              if (_slide!.date != null)
                                Text(
                                  _photoWhen(_slide!.date!),
                                  style: _sub.copyWith(
                                    fontSize: 13,
                                    color: const Color(0xAAFFFFFF),
                                  ),
                                ),
                              if (_slide!.place != null || _slide!.camera != null)
                                Text(
                                  [
                                    if (_slide!.place != null) _slide!.place!,
                                    if (_slide!.camera != null) _slide!.camera!,
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: _sub.copyWith(
                                    fontSize: 12,
                                    color: const Color(0x99FFFFFF),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const Positioned(
            right: 18,
            top: 0,
            bottom: 0,
            child: Center(child: _Hint()),
          ),
        ],
      ),
    );
  }
}

class KenBurns extends StatelessWidget {
  final Widget child;
  final int seed;
  const KenBurns({super.key, required this.child, required this.seed});

  @override
  Widget build(BuildContext context) {
    final r = Random(seed);
    final from = Alignment(r.nextDouble() * 2 - 1, r.nextDouble() * 2 - 1);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(seconds: 32),
      builder: (_, t, child) =>
          Transform.scale(scale: 1.0 + 0.08 * t, alignment: from, child: child),
      child: child,
    );
  }
}

const _shadow = [
  Shadow(color: Color(0xCC000000), blurRadius: 14, offset: Offset(0, 2)),
];

class _Overlay extends StatelessWidget {
  final HA ha;
  final List<(IconData, String)> Function() messages;
  const _Overlay({required this.ha, required this.messages});

  @override
  Widget build(BuildContext context) {
    return MinuteClock(
      builder: (context, now) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hhmm(now),
            style: const TextStyle(
              fontFamily: 'GoogleSansDisplay',
              fontSize: 104,
              height: 1,
              color: Colors.white,
              shadows: _shadow,
            ),
          ),
          const SizedBox(height: 10),
          ListenableBuilder(
            listenable: ha,
            builder: (context, _) {
              final w = ha['weather.home'];
              final info = weatherInfo[w?['state']];
              final temp = w?['attributes']?['temperature'];
              return Row(
                children: [
                  Text(longDate(now), style: _sub),
                  if (temp != null) ...[
                    const SizedBox(width: 18),
                    Icon(
                      info?.$1 ?? Icons.thermostat,
                      color: Colors.white,
                      size: 26,
                      shadows: _shadow,
                    ),
                    const SizedBox(width: 8),
                    Text('${(temp as num).round()}°', style: _sub),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Ticker(messages: messages),
        ],
      ),
    );
  }
}

const _sub = TextStyle(
  fontFamily: 'GoogleSans',
  fontSize: 26,
  color: Colors.white,
  shadows: _shadow,
);

// Static on purpose: a pulsing hint redraws the whole screen at 60 fps forever,
// which starves the mic and Wyoming socket on this SoC.
class _Hint extends StatelessWidget {
  const _Hint();
  @override
  Widget build(BuildContext context) =>
      const Icon(Icons.chevron_left, color: Colors.white54, size: 44);
}

class Ticker extends StatefulWidget {
  final List<(IconData, String)> Function() messages;
  const Ticker({super.key, required this.messages});
  @override
  State<Ticker> createState() => _TickerState();
}

class _TickerState extends State<Ticker> {
  int _i = 0;
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(
      const Duration(seconds: 7),
      (_) => setState(() => _i++),
    );
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.messages();
    final cur = m.isEmpty ? null : m[_i % m.length];
    return SizedBox(
      height: 30,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.4),
              end: Offset.zero,
            ).animate(a),
            child: child,
          ),
        ),
        child: cur == null
            ? const SizedBox()
            : Row(
                key: ValueKey(cur.$2),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    cur.$1,
                    color: const Color(0xDDFFFFFF),
                    size: 20,
                    shadows: _shadow,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      cur.$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _sub.copyWith(
                        fontSize: 19,
                        color: const Color(0xDDFFFFFF),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Small "now playing" chip over the photos, like the Smart Display ambient screen.
class NowPlayingPill extends StatelessWidget {
  final HA ha;
  final VoidCallback onTap;
  const NowPlayingPill({super.key, required this.ha, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ha,
      builder: (context, _) {
        final id = livePlayers(
          ha,
        ).where((id) => ha[id]?['state'] == 'playing').firstOrNull;
        final a = id == null ? null : ha[id]?['attributes'] as Map?;
        final title = a?['media_title'] as String?;
        final art = id == null ? null : artworkUrl(ha, id);
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: title == null || id == null
              ? const SizedBox()
              : GestureDetector(
                  key: ValueKey(title),
                  onTap: onTap,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 380),
                    padding: const EdgeInsets.fromLTRB(6, 6, 18, 6),
                    decoration: BoxDecoration(
                      color: const Color(0x99000000),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: surfaceHigh,
                          foregroundImage: art == null
                              ? null
                              : ResizeImage(NetworkImage(art), width: 80),
                          child: Icon(
                            playerIcon(ha, id),
                            size: 20,
                            color: muted,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: gs(15, color: Colors.white),
                              ),
                              Text(
                                a?['media_artist'] as String? ??
                                    friendly(ha, id),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: gs(12, color: const Color(0xBBFFFFFF)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// Night mode: big dim clock on black (Google's quartz_sleep), tap to wake.
class NightView extends StatelessWidget {
  final Clocks clocks;
  final VoidCallback onWake;
  const NightView({super.key, required this.clocks, required this.onWake});

  @override
  Widget build(BuildContext context) {
    const dim = Color(0xFF5F6368), dimmer = Color(0xFF3C4043);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onWake,
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: MinuteClock(
            builder: (context, now) {
              final alarm = clocks.nextAlarm();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(hhmm(now), style: gsd(150, color: dim, height: 1)),
                  const SizedBox(height: 8),
                  Text(longDate(now), style: gs(22, color: dimmer)),
                  if (alarm != null &&
                      alarm.difference(now) < const Duration(hours: 14)) ...[
                    const SizedBox(height: 18),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.alarm, color: dimmer, size: 20),
                        const SizedBox(width: 6),
                        Text(hhmm(alarm), style: gs(20, color: dimmer)),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
