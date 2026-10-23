import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'ambient.dart' show hhmm, MinuteClock;
import 'clock.dart' show fmtDuration;
import 'ui.dart';

const spotifyGreen = Color(0xFF1DB954);

class LyricLine {
  final int ms; // -1 when unsynced
  final String text;
  const LyricLine(this.ms, this.text);
}

class Lyrics {
  final List<LyricLine> lines;
  final bool synced;
  final Color? background, text, highlight;
  final String source;
  const Lyrics(
    this.lines, {
    required this.synced,
    required this.source,
    this.background,
    this.text,
    this.highlight,
  });
}

Color? _argb(dynamic v) => v is int ? Color(v | 0xFF000000) : null;

/// Spotify's color-lyrics JSON (fetched by our librespot patch).
Lyrics? parseSpotifyLyrics(String json) {
  if (json.trim().isEmpty) return null;
  final j = jsonDecode(json) as Map<String, dynamic>;
  final l = j['lyrics'] as Map<String, dynamic>?;
  final lines = [
    for (final x in (l?['lines'] as List? ?? []))
      if ((x['words'] as String? ?? '').trim().isNotEmpty && x['words'] != '♪')
        LyricLine(int.tryParse('${x['startTimeMs']}') ?? -1, x['words']),
  ];
  if (lines.isEmpty) return null;
  final c = j['colors'] as Map<String, dynamic>?;
  return Lyrics(
    lines,
    synced: l?['syncType'] == 'LINE_SYNCED',
    source: 'Spotify',
    background: _argb(c?['background']),
    text: _argb(c?['text']),
    highlight: _argb(c?['highlightText']),
  );
}

/// LRC ("[mm:ss.xx] text") as returned by lrclib.net.
List<LyricLine> parseLrc(String lrc) => [
  for (final m in RegExp(
    r'^\[(\d+):(\d+(?:\.\d+)?)\](.*)$',
    multiLine: true,
  ).allMatches(lrc))
    if (m[3]!.trim().isNotEmpty)
      LyricLine(
        (int.parse(m[1]!) * 60000 + double.parse(m[2]!) * 1000).round(),
        m[3]!.trim(),
      ),
];

/// State of the built-in Spotify Connect receiver (librespot, see SpotifyConnect.kt),
/// fed by its --onevent hook; commands go back through librespot's stdin.
class Spotify extends ChangeNotifier {
  String? name, artists, album, cover, trackId;
  int durationMs = 0, _positionMs = 0;
  DateTime _posAt = DateTime.now();
  bool playing = false, shuffle = false, repeat = false;
  double? volume;
  DateTime? volumeAt, _lastPlaying;
  Lyrics? lyrics;
  bool lyricsLoading = false;
  String? _lyricsFor;

  void send(String cmd) => native.invokeMethod('spotifyCmd', cmd);

  void apply(Map<String, String> ev, [DateTime? at]) {
    final now = at ?? DateTime.now();
    int? n(String k) => int.tryParse(ev[k] ?? '');
    void pos() {
      if (n('position_ms') case final p?) {
        _positionMs = p;
        _posAt = now;
      }
    }

    switch (ev['event']) {
      case 'track_changed':
        name = _nz(ev['name']);
        artists = _nz(ev['artists'])?.split(', ').toSet().join(', '); // librespot repeats featured artists
        album = _nz(ev['album']);
        cover = _nz(ev['cover']);
        trackId = _nz(ev['track_id']);
        durationMs = n('duration_ms') ?? 0;
        _positionMs = 0;
        _posAt = now;
        lyrics = null;
        _lyricsFor = null;
      case 'playing':
        playing = true;
        pos();
      case 'paused':
        _positionMs = positionAt(now);
        playing = false;
        pos();
      case 'seeked' || 'position_correction':
        pos();
      case 'stopped' || 'session_disconnected':
        playing = false;
        _lastPlaying = null;
        name = null;
      case 'volume_changed':
        volume = (n('volume') ?? 0) / 65535;
        volumeAt = now;
      case 'shuffle_changed':
        shuffle = ev['shuffle'] == 'true';
      case 'repeat_changed':
        repeat = ev['repeat'] == 'true';
    }
    if (playing) _lastPlaying = now;
    notifyListeners();
  }

  static String? _nz(String? s) => s == null || s.isEmpty ? null : s;

  int positionAt(DateTime now) =>
      (playing
              ? _positionMs + now.difference(_posAt).inMilliseconds
              : _positionMs)
          .clamp(0, durationMs > 0 ? durationMs : 1 << 31);

  /// Takes over the ambient screen while playing and for 10 min after a pause.
  bool activeAt(DateTime now) =>
      name != null &&
      (playing ||
          (_lastPlaying != null &&
              now.difference(_lastPlaying!) < const Duration(minutes: 10)));
  bool get active => activeAt(DateTime.now());

  /// Asks librespot for Spotify's own lyrics; [onLyrics] falls back to LRCLIB.
  void loadLyrics() {
    if (trackId == null || _lyricsFor == trackId) return;
    _lyricsFor = trackId;
    lyricsLoading = true;
    notifyListeners();
    send('lyrics $trackId');
  }

  Future<void> onLyrics(String id, String json) async {
    if (id != trackId) return;
    Lyrics? l;
    try {
      l = parseSpotifyLyrics(json);
    } catch (e) {
      debugPrint('Lyrics parse: $e');
    }
    l ??= await _lrclib();
    if (id != trackId) return;
    lyrics = l;
    lyricsLoading = false;
    notifyListeners();
  }

  Future<Lyrics?> _lrclib() async {
    final client = HttpClient()
      ..userAgent = 'IvyDisplay/1.0 (Lenovo Smart Display)';
    try {
      final uri = Uri.https('lrclib.net', '/api/get', {
        'track_name': name ?? '',
        'artist_name': (artists ?? '').split(', ').first,
        if (album != null) 'album_name': album!,
        if (durationMs > 0) 'duration': '${(durationMs / 1000).round()}',
      });
      final res = await (await client.getUrl(
        uri,
      )).close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final j =
          jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      final synced = parseLrc(j['syncedLyrics'] as String? ?? '');
      if (synced.isNotEmpty)
        return Lyrics(synced, synced: true, source: 'LRCLIB');
      final plain = (j['plainLyrics'] as String? ?? '')
          .split('\n')
          .where((s) => s.trim().isNotEmpty);
      return plain.isEmpty
          ? null
          : Lyrics(
              [for (final s in plain) LyricLine(-1, s)],
              synced: false,
              source: 'LRCLIB',
            );
    } catch (e) {
      debugPrint('LRCLIB: $e');
      return null;
    } finally {
      client.close();
    }
  }
}

/// Full-screen "now playing" (Google's quartz_media_view) with controls and lyrics.
class SpotifyView extends StatefulWidget {
  final Spotify spotify;
  const SpotifyView({super.key, required this.spotify});
  @override
  State<SpotifyView> createState() => _SpotifyViewState();
}

class _SpotifyViewState extends State<SpotifyView> {
  Timer? _tick;
  bool _showLyrics = false;
  double? _dragVolume;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final s = widget.spotify;
      if (mounted && (s.playing || s.volumeAt != null)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.spotify;
    final now = DateTime.now();
    final cover = s.cover;
    final pos = s.positionAt(now);
    final panelBg = _showLyrics ? s.lyrics?.background : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: bg),
        // Cheap blur: 24 px decode upscaled by the GPU gives the cover's colours.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 900),
          child: cover == null
              ? const SizedBox.expand()
              : Image(
                  key: ValueKey(cover),
                  image: ResizeImage(NetworkImage(cover), width: 24),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => const SizedBox.expand(),
                ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          color: panelBg?.withValues(alpha: 0.92) ?? const Color(0x99000000),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(48, 36, 48, 28),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                width: _showLyrics ? 240 : 330,
                height: _showLyrics ? 240 : 330,
                decoration: BoxDecoration(
                  color: surfaceHigh,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x88000000),
                      blurRadius: 30,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 600),
                  child: cover == null
                      ? const Icon(Icons.music_note, size: 96, color: muted)
                      : Image(
                          key: ValueKey(cover),
                          image: ResizeImage(NetworkImage(cover), width: 660),
                          fit: BoxFit.cover,
                          width: 330,
                          height: 330,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.music_note,
                            size: 96,
                            color: muted,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 40),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.graphic_eq,
                          color: spotifyGreen,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          s.playing
                              ? 'Spotify · Reproduciendo'
                              : 'Spotify · En pausa',
                          style: gs(15, color: const Color(0xCCFFFFFF)),
                        ),
                        const Spacer(),
                        MinuteClock(
                          builder: (_, t) => Text(
                            hhmm(t),
                            style: gsd(26, color: const Color(0xDDFFFFFF)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: _showLyrics ? _lyricsPanel(s, pos) : _info(s),
                    ),
                    const SizedBox(height: 12),
                    _progress(s, pos),
                    const SizedBox(height: 8),
                    _controls(s),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (s.volumeAt != null &&
            now.difference(s.volumeAt!) < const Duration(seconds: 2) &&
            _dragVolume == null)
          Positioned(
            top: 20,
            left: 0,
            right: 0,
            child: Center(child: _volumeOsd(s.volume ?? 0)),
          ),
      ],
    );
  }

  Widget _info(Spotify s) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 500),
    child: Column(
      key: ValueKey(s.name),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.name ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: gs(
            36,
            weight: FontWeight.w500,
            height: 1.15,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 10),
        if (s.artists != null)
          Text(
            s.artists!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: gs(21, color: const Color(0xDDFFFFFF)),
          ),
        if (s.album != null)
          Text(
            s.album!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: gs(16, color: const Color(0x99FFFFFF)),
          ),
      ],
    ),
  );

  Widget _lyricsPanel(Spotify s, int pos) {
    final l = s.lyrics;
    if (l == null) {
      return Center(
        child: s.lyricsLoading
            ? const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              )
            : Text(
                'No hay letra para esta canción',
                style: gs(20, color: const Color(0xAAFFFFFF)),
              ),
      );
    }
    return _LyricsList(
      lyrics: l,
      position: pos,
      onSeek: (ms) => s.send('seek $ms'),
    );
  }

  Widget _progress(Spotify s, int pos) {
    if (s.durationMs <= 0) return const SizedBox(height: 24);
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, c) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => s.send(
              'seek ${(d.localPosition.dx / c.maxWidth * s.durationMs).round()}',
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(
                value: pos / s.durationMs,
                minHeight: 5,
                color: Colors.white,
                backgroundColor: const Color(0x33FFFFFF),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
        Row(
          children: [
            Text(
              fmtDuration(Duration(milliseconds: pos)),
              style: gs(13, color: const Color(0xAAFFFFFF)),
            ),
            const Spacer(),
            Text(
              fmtDuration(Duration(milliseconds: s.durationMs)),
              style: gs(13, color: const Color(0xAAFFFFFF)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _controls(Spotify s) {
    Widget btn(
      IconData icon,
      VoidCallback onTap, {
      bool on = false,
      double size = 30,
    }) => IconButton(
      onPressed: onTap,
      iconSize: size,
      icon: Icon(icon, color: on ? spotifyGreen : Colors.white),
    );
    final vol = _dragVolume ?? s.volume ?? 0.7;
    return Row(
      children: [
        btn(
          Icons.shuffle,
          () => s.send('shuffle ${s.shuffle ? 0 : 1}'),
          on: s.shuffle,
          size: 24,
        ),
        btn(Icons.skip_previous, () => s.send('prev'), size: 36),
        Material(
          color: Colors.white,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => s.send('play_pause'),
            child: SizedBox(
              width: 60,
              height: 60,
              child: Icon(
                s.playing ? Icons.pause : Icons.play_arrow,
                size: 36,
                color: Colors.black,
              ),
            ),
          ),
        ),
        btn(Icons.skip_next, () => s.send('next'), size: 36),
        btn(
          Icons.repeat,
          () => s.send('repeat ${s.repeat ? 0 : 1}'),
          on: s.repeat,
          size: 24,
        ),
        const Spacer(),
        Icon(
          vol == 0 ? Icons.volume_off : Icons.volume_up,
          color: const Color(0xCCFFFFFF),
          size: 22,
        ),
        SizedBox(
          width: 130,
          child: SliderTheme(
            data: const SliderThemeData(
              trackHeight: 4,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: vol.clamp(0.0, 1.0),
              activeColor: Colors.white,
              inactiveColor: const Color(0x33FFFFFF),
              onChanged: (v) => setState(() => _dragVolume = v),
              onChangeEnd: (v) {
                s.send('volume ${(v * 65535).round()}');
                setState(() => _dragVolume = null);
              },
            ),
          ),
        ),
        IconButton(
          tooltip: 'Letra',
          onPressed: () {
            setState(() => _showLyrics = !_showLyrics);
            if (_showLyrics) s.loadLyrics();
          },
          icon: Icon(
            Icons.lyrics_outlined,
            color: _showLyrics ? spotifyGreen : Colors.white,
            size: 26,
          ),
        ),
      ],
    );
  }

  Widget _volumeOsd(double v) => Container(
    width: 280,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(
      color: const Color(0xCC202124),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      children: [
        Icon(v == 0 ? Icons.volume_off : Icons.volume_up, color: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: LinearProgressIndicator(
            value: v,
            minHeight: 6,
            color: Colors.white,
            backgroundColor: const Color(0x33FFFFFF),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ],
    ),
  );
}

/// Synced lyrics: current line highlighted and kept ~1/3 from the top; tap a line to seek.
class _LyricsList extends StatefulWidget {
  final Lyrics lyrics;
  final int position;
  final ValueChanged<int> onSeek;
  const _LyricsList({
    required this.lyrics,
    required this.position,
    required this.onSeek,
  });
  @override
  State<_LyricsList> createState() => _LyricsListState();
}

class _LyricsListState extends State<_LyricsList> {
  final _keys = <int, GlobalKey>{};
  int _current = -1;

  int _indexAt(int pos) {
    if (!widget.lyrics.synced) return -1;
    var i = -1;
    for (var k = 0; k < widget.lyrics.lines.length; k++) {
      if (widget.lyrics.lines[k].ms <= pos + 300) i = k;
    }
    return i;
  }

  @override
  void didUpdateWidget(_LyricsList old) {
    super.didUpdateWidget(old);
    final i = _indexAt(widget.position);
    if (i != _current) {
      _current = i;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _keys[i]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.3,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.lyrics;
    final text = l.text ?? const Color(0x88FFFFFF);
    final hi = l.highlight ?? Colors.white;
    return ShaderMask(
      // Fade top/bottom edges like Spotify.
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: [0, 0.08, 0.88, 1],
      ).createShader(r),
      blendMode: BlendMode.dstIn,
      // Not a lazy ListView: off-screen lines need a context for ensureVisible
      // (opening the lyrics mid-song must jump to the current line).
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          for (final (i, line) in l.lines.indexed)
            GestureDetector(
              key: _keys.putIfAbsent(i, GlobalKey.new),
              onTap: line.ms >= 0 ? () => widget.onSeek(line.ms) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 300),
                  style: gs(
                    l.synced ? 28 : 22,
                    weight: FontWeight.w500,
                    height: 1.25,
                    color: !l.synced || i == _current
                        ? hi
                        : (i < _current ? text.withValues(alpha: 0.6) : text),
                  ),
                  child: Text(line.text),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'Letra: ${l.source}',
              style: gs(13, color: const Color(0x88FFFFFF)),
            ),
          ),
          ],
        ),
      ),
    );
  }
}
