import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ambient.dart';
import 'call.dart';
import 'cameras.dart';
import 'clock.dart';
import 'data.dart';
import 'doorbell.dart';
import 'energy.dart';
import 'ha.dart';
import 'home.dart';
import 'media.dart';
import 'network.dart';
import 'packages.dart';
import 'rooms.dart';
import 'screen.dart';
import 'spotify.dart';
import 'voice.dart';
import 'ui.dart';
import 'views.dart';

const _idleTimeout = Duration(seconds: 45);

/// Required as ?token= by the :2971 camera endpoints (HA's MJPEG camera uses it).
const cameraToken = String.fromEnvironment('CAMERA_TOKEN');
final _nav = GlobalKey<NavigatorState>();

Future<void> main() async {
  HttpOverrides.global = HaHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();
  hasFrog = await rootBundle
      .load('assets/froggy/fields_day_sunny_bg.webp')
      .then((_) => true, onError: (_) => false);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final ha = HA({
    'weather.home',
    'sun.sun',
    'camera.entryway_entryway', // doorbell overlay
    doorbellEvent,
  })..run();
  runApp(IvyApp(ha: ha));
}

class IvyApp extends StatelessWidget {
  final HA ha;
  const IvyApp({super.key, required this.ha});
  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _nav,
    debugShowCheckedModeBanner: false,
    locale: const Locale('es'),
    supportedLocales: const [Locale('es')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'GoogleSans',
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(primary: accent, surface: surface),
    ),
    home: Shell(ha: ha),
  );
}

class Shell extends StatefulWidget {
  final HA ha;
  const Shell({super.key, required this.ha});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final _pager = PageController();
  late final _agenda = Agenda(widget.ha);
  late final _forecast = Forecast(widget.ha);
  final _clocks = Clocks();
  int _page = 0;
  Timer? _idle, _minute, _bellTimer, _motionOff;
  bool _moving = false;
  HttpServer? _api;
  DateTime? _bellAt;
  final _presence = Presence();
  final _spotify = Spotify();
  bool _urlPlaying = false; // the native player is on a radio/stream URL
  String? _urlTitle;
  late final _voice = Voice(
    ha: widget.ha,
    onTimer: _clocks.onSatelliteTimer,
    onWake: () {
      _presence.touch(DateTime.now());
      _applyBrightness();
    },
  );
  String? _lastBell;
  double? _brightness;

  late final _call = Call(
    onStart: () => _voice.paused = true,
    onStop: () => _voice.paused = false,
  );

  String?
  _room; // this screen's HA area (e.g. "Kitchen"), for per-room controls
  (String, String)?
  _peer; // the other screen to offer a call button to: (ip, name)

  @override
  void initState() {
    super.initState();
    _startApi();
    native.invokeMethod<String>('deviceRoom').then((r) {
      if (mounted && r != null && r.isNotEmpty) setState(() => _room = r);
      // HA drops states set over REST on restart: re-publish the motion sensor.
      _publishMotion();
    });
    native.invokeMethod<Map>('callPeer').then((p) {
      if (mounted && p != null) {
        setState(() => _peer = (p['ip'] as String, p['name'] as String));
      }
    });
    _call.init();
    widget.ha.views.addListener(_onViews);
    widget.ha.addListener(_watchDoorbell);
    _clocks.addListener(() {
      if (_clocks.ringing != null) {
        _presence.touch(DateTime.now());
        _nav.currentState?.popUntil((r) => r.isFirst);
      }
      _applyBrightness();
    });
    // Light/proximity events from MainActivity.kt
    native.setMethodCallHandler((call) async {
      final now = DateTime.now();
      if (call.method == 'lux')
        _presence.onLux((call.arguments as num).toDouble(), now);
      if (call.method == 'near') _presence.onNear(call.arguments as bool, now);
      if (call.method == 'motion') _onMotion(now);
      if (call.method == 'mic') _voice.onMic(call.arguments as Uint8List);
      if (call.method == 'ttsDone') _voice.onTtsDone(call.arguments as String?);
      if (call.method == 'ttsError') {
        _voice.onTtsDone(call.arguments as String?, failed: true);
      }
      if (call.method == 'mediaDone') _urlPlaying = false;
      if (call.method == 'spotifyLyrics') {
        _spotify.onLyrics(
          call.arguments['id'] as String,
          call.arguments['json'] as String,
        );
      }
      if (call.method == 'spotify') {
        _spotify.apply(Map<String, String>.from(call.arguments as Map), now);
        // Music starting from the phone wakes the screen and shows it, like casting did.
        if (call.arguments['event'] == 'playing') {
          _presence.touch(now);
          if (_page != 0 && _bellAt == null) _go(0);
        }
      }
    });
    _voice.start();
    _presence.addListener(() => setState(_applyBrightness));
    // Motion detection needs light: the camera rests while the room is dark.
    var motionOn = _presence.mode != ScreenMode.off;
    native.invokeMethod('cameraMotion', motionOn);
    _presence.addListener(() {
      if ((_presence.mode != ScreenMode.off) != motionOn) {
        motionOn = !motionOn;
        native.invokeMethod('cameraMotion', motionOn);
      }
    });
    native.invokeMethod('sensors');
    Timer.periodic(const Duration(minutes: 10), (_) => _publishMotion());
    _applyQuiet();
    _minute = Timer.periodic(const Duration(seconds: 15), (_) {
      _presence.evaluate(DateTime.now());
      _applyBrightness();
      _applyQuiet();
    });
    _applyBrightness();
  }

  @override
  void dispose() {
    _idle?.cancel();
    _minute?.cancel();
    _bellTimer?.cancel();
    _api?.close(force: true);
    _voice.dispose();
    super.dispose();
  }

  /// Dashboard saved in HA: rebuild tabs; leave a page that no longer exists.
  void _onViews() {
    if (_page > widget.ha.views.value.length) _pager.jumpToPage(0);
    setState(() {});
  }

  /// Page index of a dashboard view (ambient is page 0); first tab if absent.
  int _pageOf(String path) {
    final i = widget.ha.views.value.indexWhere((v) => v.path == path);
    return i < 0 ? 1 : i + 1;
  }

  /// Ambient page follows the light state (standby dim / off); other pages and
  /// alerts track the room's light level; alerts always go full brightness.
  void _applyBrightness() {
    final alert = _bellAt != null || _clocks.ringing != null;
    final b = alert
        ? 1.0
        : (_page == 0 ? _presence.brightness : _presence.roomBrightness);
    if (_brightness == null || (b - _brightness!).abs() > 0.03) {
      _brightness = b;
      native.invokeMethod('brightness', b);
    }
  }

  void _watchDoorbell() {
    final st = widget.ha[doorbellEvent]?['state'] as String?;
    if (st == null || isOffline(st)) return;
    if (_lastBell != null && st != _lastBell) _showBell();
    _lastBell = st;
  }

  void _showBell() {
    _bellTimer?.cancel();
    _bellTimer = Timer(const Duration(seconds: 60), _closeBell);
    // Sheets and full-screen cameras are routes above the Shell's overlays.
    _nav.currentState?.popUntil((r) => r.isFirst);
    native.invokeMethod('wake');
    _presence.touch(DateTime.now());
    setState(() => _bellAt = DateTime.now());
    _applyBrightness();
  }

  void _closeBell() {
    _bellTimer?.cancel();
    setState(() => _bellAt = null);
    _applyBrightness();
  }

  void _go(int page) {
    if (!_pager.hasClients) return;
    _pager.animateToPage(
      page,
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeInOutCubic,
    );
  }

  void _touch() {
    _presence.touch(DateTime.now());
    _idle?.cancel();
    if (_page != 0) {
      _idle = Timer(_idleTimeout, () {
        _nav.currentState?.popUntil((r) => r.isFirst);
        _go(0);
      });
    }
  }

  /// Night mode 23:00–08:00: voice replies, spoken announcements (doorbell)
  /// and earcons play at a quarter volume. Alarms and music are untouched.
  bool? _quiet;
  void _applyQuiet() {
    final h = DateTime.now().hour;
    final q = h >= 23 || h < 8;
    if (q != _quiet) {
      _quiet = q;
      native.invokeMethod('quiet', q);
    }
  }

  /// Camera motion wakes the screen (like walking up to it) and drives
  /// binary_sensor.ivy_movimiento_(room) in HA, which clears after 60 s of stillness.
  void _onMotion(DateTime now) {
    _presence.touch(now);
    _motionOff?.cancel();
    _motionOff = Timer(const Duration(seconds: 60), () {
      _moving = false;
      _publishMotion();
    });
    if (!_moving) {
      _moving = true;
      _publishMotion();
    }
  }

  /// One sensor per screen (binary_sensor.ivy_movimiento_kitchen, ..._bedroom):
  /// with a shared one the two screens overwrote each other's on/off.
  void _publishMotion() => widget.ha
      .restPost(
        '/api/states/binary_sensor.ivy_movimiento'
        '${_room == null ? '' : '_${_room!.toLowerCase()}'}',
        {
          'state': _moving ? 'on' : 'off',
          'attributes': {
            'device_class': 'motion',
            'friendly_name': 'Ivy movimiento ${_room ?? ''}'.trim(),
          },
        },
      )
      .catchError((e) => debugPrint('Motion: $e'));

  void _wake() {
    _presence.touch(DateTime.now());
    _applyBrightness();
  }

  /// Drop-in replacement for WallPanel's REST API so the existing HA doorbell
  /// automation (rest_command.ivy_command -> :2971/api/command) keeps working.
  Future<void> _startApi() async {
    try {
      _api = await HttpServer.bind(InternetAddress.anyIPv4, 2971, shared: true);
    } catch (e) {
      debugPrint('API: no se pudo abrir :2971 ($e)');
      return;
    }
    // Concurrent: an MJPEG stream stays open while other requests come in.
    _api!.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response..headers.contentType = ContentType.json;
    if (req.uri.path.startsWith('/api/camera')) return _camera(req, res);
    try {
      if (req.method == 'POST' && req.uri.path == '/api/command') {
        _command(
          jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>,
        );
        res.write(
          jsonEncode({
            'result': 'ok',
            'volume': await _volume(),
            'media': await _mediaState(),
            ..._clocksState(),
          }),
        );
      } else if (req.uri.path == '/api/state') {
        res.write(
          jsonEncode({
            'currentUrl': _page == 0
                ? '/lovelace-ivy/photos'
                : '/lovelace-ivy/controls',
            'page': _page,
            'screen': _presence.mode.name,
            'lux': _presence.lux,
            'screenOn': true,
            'volume': await _volume(),
            'media': await _mediaState(),
            ..._clocksState(),
          }),
        );
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      res.statusCode = HttpStatus.badRequest;
    }
    await res.close();
  }

  /// /api/camera.jpg (snapshot) and /api/camera.mjpeg (~4 fps) from the
  /// display's camera, for HA's MJPEG camera. The camera only runs on demand.
  Future<void> _camera(HttpRequest req, HttpResponse res) async {
    Future<Uint8List?> jpeg() => native.invokeMethod<Uint8List>('cameraJpeg');
    try {
      if (cameraToken.isEmpty ||
          req.uri.queryParameters['token'] != cameraToken) {
        res.statusCode = HttpStatus.unauthorized;
      } else if (req.uri.path == '/api/camera.jpg') {
        final j = await jpeg();
        if (j == null) {
          res.statusCode = HttpStatus.serviceUnavailable;
        } else {
          res.headers.contentType = ContentType('image', 'jpeg');
          res.add(j);
        }
      } else if (req.uri.path == '/api/camera.mjpeg') {
        res.headers.set(
          'Content-Type',
          'multipart/x-mixed-replace; boundary=ivyframe',
        );
        res.bufferOutput = false;
        // Ends when the client disconnects (the write/flush throws).
        while (true) {
          final j = await jpeg();
          if (j != null) {
            res.write(
              '--ivyframe\r\nContent-Type: image/jpeg\r\n'
              'Content-Length: ${j.length}\r\n\r\n',
            );
            res.add(j);
            res.write('\r\n');
            await res.flush();
          }
          await Future.delayed(const Duration(milliseconds: 250));
        }
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      // client went away mid-stream
    }
    await res.close().catchError((_) {});
  }

  void _command(Map<String, dynamic> cmd) {
    if (cmd['wake'] == true) {
      native.invokeMethod('wake');
      _wake();
    }
    if (cmd['speak'] is String) native.invokeMethod('speak', cmd['speak']);
    if (cmd['volume'] is num) {
      native.invokeMethod('volume', (cmd['volume'] as num).round());
    }
    if (cmd['doorbell'] == true) _showBell();
    if (cmd['ask'] is String) _voice.ask(cmd['ask']);
    if (cmd['announce'] is String) _voice.announce(cmd['announce'] as String);
    if (cmd['call'] is Map) _onCall(cmd['call'] as Map);
    final url = cmd['url'];
    if (url is String) {
      if (url.contains('controls')) {
        _go(_pageOf('inicio'));
      } else {
        _closeBell();
        _go(0);
      }
    }
    // Timers and alarms: the HA scripts the voice agent uses as tools send these.
    final timer = cmd['timer'];
    if (timer is num && timer > 0) {
      _clocks.add(Duration(seconds: timer.round()));
    }
    if (cmd['cancel_timers'] == true) {
      for (final t in [..._clocks.timers]) {
        _clocks.cancel(t);
      }
    }
    final alarm = cmd['alarm'];
    if (alarm is String) {
      final [h, m] = alarm.split(':').take(2).map(int.parse).toList();
      if (h > 23 || m > 59) throw FormatException('alarm $alarm');
      _clocks.alarms.add(
        Alarm(h, m, days: {for (final d in cmd['days'] ?? []) d as int}),
      );
      _clocks.save();
    }
    final drop = cmd['cancel_alarm'];
    if (drop is String) {
      _clocks.alarms.removeWhere(
        (a) => drop == 'all' || _hm(a.hour, a.minute) == drop.substring(0, 5),
      );
      _clocks.save();
    }
    if (cmd['media'] is Map) _media(cmd['media'] as Map);
    // An empty command is just a status query: don't wake the screen for it.
    if (cmd.isNotEmpty) _touch();
  }

  /// Media control for the HA "Ivy" media_player: a radio/stream URL plays on the
  /// native player; Spotify (librespot) handles play/pause/next/prev. The two don't
  /// overlap: starting a URL pauses Spotify first.
  /// Screen-to-screen call signalling (device-to-device over :2971, see call.dart).
  void _onCall(Map c) {
    switch (c['action']) {
      case 'invite': // start an outgoing call (from a button, the voice tool, or a test)
        if (c['to_ip'] is String) {
          _call.invite(c['to_ip'] as String, c['to_name'] as String? ?? 'Ivy');
        }
      case 'ring': // the peer is calling us
        if (c['from_ip'] is String) {
          _call.onRing(
            c['from_ip'] as String,
            c['from_name'] as String? ?? 'Ivy',
          );
        }
      case 'accept': // the screen we called picked up
        _call.onAccept();
      case 'accept_local': // accept an incoming ring (voice tool / test)
        _call.accept();
      case 'end': // the peer hung up or rejected
        _call.onEnd();
    }
  }

  void _media(Map m) {
    final url = m['url'];
    switch (m['action']) {
      case 'play_url':
        if (url is String) {
          if (_spotify.playing) _spotify.send('play_pause');
          _urlTitle = m['title'] as String?;
          _urlPlaying = true;
          native.invokeMethod('playMedia', url);
          _go(0);
        }
      case 'play':
        if (_urlPlaying) {
          native.invokeMethod('mediaControl', 'resume');
        } else if (!_spotify.playing) {
          _spotify.send('play_pause');
        }
      case 'pause':
        if (_urlPlaying) {
          native.invokeMethod('mediaControl', 'pause');
        } else if (_spotify.playing) {
          _spotify.send('play_pause');
        }
      case 'stop':
        if (_urlPlaying) {
          native.invokeMethod('mediaControl', 'stop');
          _urlPlaying = false;
        }
        if (_spotify.playing) _spotify.send('play_pause');
      case 'next':
        _spotify.send('next');
      case 'previous':
        _spotify.send('prev');
    }
  }

  /// The media_player state the HA component polls: the radio URL if one is
  /// playing, otherwise Spotify, otherwise idle.
  Future<Map<String, dynamic>> _mediaState() async {
    if (_urlPlaying) {
      Map? info;
      try {
        info = await native.invokeMethod<Map>('mediaInfo');
      } catch (_) {}
      if (info != null) {
        final dur = (info['duration_ms'] as num?) ?? 0;
        return {
          'state': info['playing'] == true ? 'playing' : 'paused',
          'source': 'Radio',
          'title': _urlTitle ?? 'Audio',
          'position': (((info['position_ms'] as num?) ?? 0) / 1000).round(),
          if (dur > 0) 'duration': (dur / 1000).round(),
        };
      }
    }
    final s = _spotify;
    if (s.active && s.name != null) {
      return {
        'state': s.playing ? 'playing' : 'paused',
        'source': 'Spotify',
        'title': s.name,
        'artist': s.artists,
        'album': s.album,
        'position': (s.positionAt(DateTime.now()) / 1000).round(),
        if (s.durationMs > 0) 'duration': (s.durationMs / 1000).round(),
        if (s.cover != null) 'cover': s.cover,
      };
    }
    return {'state': 'idle'};
  }

  String _hm(int h, int m) => '${two(h)}:${two(m)}';

  /// Current media volume 0..100, so the agent can read it before changing it.
  Future<int?> _volume() async {
    try {
      return await native.invokeMethod<int>('getVolume');
    } catch (_) {
      return null;
    }
  }

  /// Timers and alarms, returned with every API reply so the agent's tools see them.
  Map<String, dynamic> _clocksState() {
    final now = DateTime.now();
    return {
      'timers': [
        for (final t in _clocks.timers)
          {
            'remaining_s': t.remaining(now).inSeconds,
            'total_s': t.total.inSeconds,
            'paused': t.paused,
          },
      ],
      'alarms': [
        for (final a in _clocks.alarms)
          {
            'time': _hm(a.hour, a.minute),
            'days': a.days.toList()..sort(),
            'enabled': a.enabled,
          },
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final ha = widget.ha;
    Widget page(Widget child) => ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 84, 28, 22),
        child: child,
      ),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        onPointerDown: (_) => _touch(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView(
              controller: _pager,
              // On the photos, horizontal swipes browse photos; only the right-edge
              // drag (handled by AmbientPage) moves to the next screen.
              physics: _page == 0 ? const NeverScrollableScrollPhysics() : null,
              onPageChanged: (p) {
                setState(() => _page = p);
                _touch();
                _applyBrightness();
              },
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([_agenda, _forecast, _spotify]),
                  builder: (_, _) => AmbientPage(
                    ha: ha,
                    agenda: _agenda,
                    forecast: _forecast,
                    clocks: _clocks,
                    spotify: _spotify,
                    night: _presence.mode != ScreenMode.normal,
                    off: _presence.mode == ScreenMode.off,
                    onOpen: () => _go(1),
                    onMedia: () => _go(_pageOf('multimedia')),
                    onWake: _wake,
                    onEdgeDrag: (dx) => _pager.jumpTo(
                      (_pager.offset - dx).clamp(
                        0.0,
                        _pager.position.viewportDimension,
                      ),
                    ),
                    onEdgeEnd: (v) => _go(
                      _pager.offset > _pager.position.viewportDimension * 0.3 ||
                              v < -400
                          ? 1
                          : 0,
                    ),
                  ),
                ),
                for (final (i, v) in ha.views.value.indexed)
                  page(switch (v.path) {
                    'inicio' => HomePage(
                      ha: ha,
                      agenda: _agenda,
                      forecast: _forecast,
                      active: _page == i + 1 && _bellAt == null,
                    ),
                    'casa' => RoomsPage(
                      ha: ha,
                      myRoom: _room,
                      peer: _peer,
                      onCall: _peer == null
                          ? null
                          : () => _call.invite(_peer!.$1, _peer!.$2),
                    ),
                    'multimedia' => MediaPage(ha: ha),
                    'reloj' => ClockPage(clocks: _clocks),
                    'paquetes' => PackagesPage(ha: ha, active: _page == i + 1),
                    'camaras' => CamerasPage(
                      ha: ha,
                      view: v,
                      active: _page == i + 1 && _bellAt == null,
                    ),
                    // Any view holding an e-data sensor is the electricity page.
                    _
                        when v
                            .domain('sensor')
                            .any((i) => i.id.startsWith('sensor.edata_')) =>
                      EnergyPage(
                        ha: ha,
                        entity: v
                            .domain('sensor')
                            .firstWhere((i) => i.id.startsWith('sensor.edata_'))
                            .id,
                        active: _page == i + 1,
                      ),
                    _ => ViewPage(
                      ha: ha,
                      view: v,
                      active: _page == i + 1 && _bellAt == null,
                    ),
                  }),
              ],
            ),
            _Header(
              pager: _pager,
              ha: ha,
              onTab: _go,
              onNetwork: () => _nav.currentState!.push(
                MaterialPageRoute(builder: (_) => NetworkPage(onTouch: _touch)),
              ),
            ),
            if (_presence.mode != ScreenMode.off)
              Positioned(
                right: 24,
                bottom: 100,
                child: FilledButton.icon(
                  onPressed: () async {
                    if (!await _voice.listen() && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Ivy no está disponible ahora.'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.mic),
                  label: const Text('Hablar con Ivy'),
                ),
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (c, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(
                  scale: Tween(begin: 0.96, end: 1.0).animate(a),
                  child: c,
                ),
              ),
              child: _bellAt == null
                  ? const SizedBox()
                  : DoorbellOverlay(ha: ha, at: _bellAt!, onClose: _closeBell),
            ),
            VoiceOverlay(voice: _voice),
            CallOverlay(call: _call),
            ListenableBuilder(
              listenable: _clocks,
              builder: (_, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _clocks.ringing == null
                    ? const SizedBox()
                    : RingOverlay(clocks: _clocks),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Clock + tab strip shown on every page except ambient; fades with the swipe.
class _Header extends StatelessWidget {
  final PageController pager;
  final HA ha;
  final ValueChanged<int> onTab;
  final VoidCallback onNetwork;
  const _Header({
    required this.pager,
    required this.ha,
    required this.onTab,
    required this.onNetwork,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pager,
      builder: (context, _) {
        final p = pager.hasClients && pager.position.haveDimensions
            ? pager.page ?? 0
            : 0.0;
        final t = p.clamp(0.0, 1.0);
        if (t == 0) return const SizedBox();
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Opacity(
            opacity: t,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 20, 20, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  MinuteClock(
                    builder: (_, now) => Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(hhmm(now), style: gsd(36, height: 1)),
                        const SizedBox(width: 14),
                        Text(longDate(now), style: gs(17, color: muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Many tabs: right-aligned strip that scrolls instead of overlapping the date.
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      child: Row(
                        children: [
                          for (final (i, v) in ha.views.value.indexed)
                            _Tab(
                              name: v.title,
                              selected: (p.round()) == i + 1,
                              onTap: () => onTab(i + 1),
                            ),
                        ],
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: ha,
                    builder: (_, _) => ha.connected
                        ? const SizedBox()
                        : const Padding(
                            padding: EdgeInsets.only(left: 12, right: 8),
                            child: Icon(
                              Icons.cloud_off,
                              color: muted,
                              size: 20,
                            ),
                          ),
                  ),
                  IconButton(
                    onPressed: onNetwork,
                    icon: const Icon(Icons.settings, color: muted, size: 22),
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

class _Tab extends StatefulWidget {
  final String name;
  final bool selected;
  final VoidCallback onTap;
  const _Tab({required this.name, required this.selected, required this.onTap});
  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  /// The strip scrolls when tabs don't fit: keep the current one in view
  /// (also when the header is rebuilt on leaving the photos).
  @override
  void initState() {
    super.initState();
    if (widget.selected) _reveal();
  }

  @override
  void didUpdateWidget(_Tab old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final _Tab(:name, :selected, :onTap) = widget;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            name,
            style: gs(
              15,
              color: selected ? onSurface : muted,
              weight: selected ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
