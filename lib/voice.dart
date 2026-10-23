import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'ha.dart';
import 'openui.dart';
import 'ui.dart';
import 'wyoming.dart';

const voicePipeline =
    'Ivy'; // HA Assist pipeline: openWakeWord "okay_nabu" + faster-whisper (es)

enum VoiceState { idle, listening, thinking, speaking }

// ------------------------------------------------------------ controller

/// HA owns the complete voice pipeline; the screen supplies audio and renders replies.
class Voice extends ChangeNotifier {
  final HA ha;
  final VoidCallback onWake;
  final void Function(WyomingEvent) onTimer;
  Voice({required this.ha, required this.onWake, required this.onTimer});

  VoiceState state = VoiceState.idle;
  String? heard, reply;
  String? audioError;
  UiNode? ui;
  DateTime? shownAt;
  WyomingSatellite? _satellite;
  WyomingAudio? _audio;
  bool _paused = false,
      _disposed = false,
      _processing = false,
      _speaking = false,
      _manual = false,
      _legacyBusy = false,
      _discardAudio = false,
      _replyAudio = false;
  final _responseAudio = <String>[];
  String? _conversationId, _playing;
  int _playId = 0;
  Completer<void>? _spoken;
  Timer? _hide, _playTimeout, _retry, _stall, _noAudio;
  File? _speechFile;

  Future<void> start() async {
    try {
      final name = await native.invokeMethod<String>('deviceName');
      final id = await native.invokeMethod<String>('deviceId');
      final area = await native.invokeMethod<String>('deviceRoom');
      if (_disposed) return;
      final satellite = _satellite = WyomingSatellite(
        name: name?.trim().isNotEmpty == true ? name!.trim() : 'Ivy-$id',
        area: area,
        onEvent: _onWyoming,
        onConnection: (connected) {
          _retry?.cancel();
          if (!connected) {
            _manual = false;
            _audio = null;
            _replyAudio = false;
            _processing = false;
            _responseAudio.clear();
            _discardAudio = false;
            _stopSpeech();
            dismiss();
          }
        },
        onError: (e) => debugPrint('Wyoming: $e'),
      );
      await satellite.start();
      if (_disposed) {
        await satellite.close();
        return;
      }
      try {
        await native.invokeMethod('wyomingAdvertise', {
          'name': satellite.name,
          'port': satellite.port,
        });
      } catch (e) {
        debugPrint('Wyoming mDNS: $e; use manual IP/port');
      }
      await native.invokeMethod('micStart');
    } catch (e) {
      debugPrint('Wyoming start: $e');
      await _satellite?.close();
      _satellite = null;
    }
  }

  void _set(VoiceState s) {
    if (_disposed) return;
    state = s;
    shownAt = DateTime.now();
    notifyListeners();
  }

  void dismiss() {
    if (_disposed) return;
    heard = reply = null;
    ui = null;
    state = VoiceState.idle;
    notifyListeners();
  }

  bool get paused => _paused;
  set paused(bool value) {
    _paused = value;
    _processing = false;
    _satellite?.muted = value;
    if (value) {
      _manual = false;
      _audio = null;
      _stopSpeech();
      dismiss();
    }
  }

  Future<bool> listen() async {
    if (_disposed || _paused || _legacyBusy || _satellite?.ready != true) {
      return false;
    }
    _manual = true;
    await _onWyoming(const WyomingEvent('transcribe'));
    // A button press skips wake detection for one question, then restores it.
    _satellite!.run(startStage: 'asr', restartOnEnd: false);
    return true;
  }

  void onMic(Uint8List pcm) {
    if (!_paused &&
        !_legacyBusy &&
        _audio == null &&
        !_speaking &&
        !_processing) {
      _satellite?.onMic(pcm);
    }
  }

  void _stopSpeech() {
    ++_playId;
    _playing = null;
    audioError = null;
    _speaking = false;
    _playTimeout?.cancel();
    native.invokeMethod('speechStop');
    _speechFile?.delete().ignore();
    _speechFile = null;
  }

  void onTtsDone(String? id, {bool failed = false}) {
    if (_disposed) return;
    if (_playing != null && id == _playing) {
      _playing = null;
      _speaking = false;
      _processing = false;
      _playTimeout?.cancel();
      _speechFile?.delete().ignore();
      _speechFile = null;
      if (failed) {
        _satellite?.send(
          const WyomingEvent('error', {
            'code': 'playback-failed',
            'text': 'Audio playback failed',
          }),
        );
      } else {
        _satellite?.send(const WyomingEvent('played'));
      }
      _set(VoiceState.speaking);
      _hide?.cancel();
      _hide = Timer(Duration(seconds: ui == null ? 5 : 25), dismiss);
      if (_manual) {
        _manual = false;
        _satellite?.run();
      }
      // Incoming detect/transcribe events immediately reopen microphone capture.
    } else if (id == 'url' || id == 'ivy') {
      if (_spoken?.isCompleted == false) _spoken!.complete();
    }
  }

  Future<void> _onWyoming(WyomingEvent event) async {
    if (_disposed) return;
    final data = event.data;
    switch (event.type) {
      case 'detect':
        if (!_paused && _playing == null && _audio == null) _processing = false;
      case 'detection' || 'transcribe':
        if (_paused) return;
        _stopSpeech();
        _processing = false;
        if (_audio != null) {
          _audio = null;
          _discardAudio = true;
        }
        _replyAudio = false;
        _hide?.cancel();
        onWake();
        heard = reply = null;
        ui = null;
        if (event.type == 'detection') native.invokeMethod('earcon', 'wake');
        _set(VoiceState.listening);
      case 'transcript':
        _processing = true;
        heard = data['text'] as String?;
        _set(VoiceState.thinking);
      case 'synthesize':
        if (_paused) return;
        onWake();
        final original = data['text'] as String? ?? '';
        final (text, node) = splitReply(original);
        reply = text;
        ui = node;
        _set(VoiceState.speaking);
        if (node == null) {
          // Plain text: HA's own TTS stream follows and is played live as it arrives.
          _replyAudio = true;
          _hide?.cancel();
          _hide = Timer(const Duration(seconds: 30), dismiss); // if no audio comes
          // HA waits up to 10 min on a stuck OpenAI TTS call: speak it ourselves instead.
          _noAudio?.cancel();
          _noAudio = Timer(_ttsWait(text), () {
            if (!_replyAudio || _paused || _disposed) return;
            _replyAudio = false;
            final id = _playing = 'wyoming-${++_playId}';
            _responseAudio.add(id); // HA's late stream, if it ever comes
            _processing = false;
            unawaited(_speakReply(id, text.isNotEmpty ? text : 'Hecho.'));
          });
          return;
        }
        // A card: HA's audio would read the markup aloud, so speak only the summary.
        _stopSpeech();
        final id = _playing = 'wyoming-$_playId';
        // Keep late HA streams attached to their response, across newer questions.
        if (_audio != null) {
          _audio = null;
          _discardAudio = true;
        } else {
          _responseAudio.add(id);
        }
        _processing = false;
        unawaited(_speakReply(id, text.isNotEmpty ? text : 'Aquí lo tienes.'));
      case 'audio-start':
        _discardAudio = _responseAudio.isNotEmpty || _paused;
        if (_responseAudio.isNotEmpty) _responseAudio.removeAt(0);
        if (_discardAudio) return;
        _hide?.cancel();
        _stopSpeech();
        // Without a synthesize first it's an announcement: audio only, no text.
        if (!_replyAudio) {
          heard = reply = null;
          ui = null;
        }
        _replyAudio = false;
        _noAudio?.cancel();
        final audio = _audio = WyomingAudio(data);
        _playing = 'wyoming-${++_playId}';
        _processing = _speaking = true;
        onWake();
        _set(VoiceState.speaking);
        await native.invokeMethod('pcmStart', {
          'rate': audio.rate,
          'channels': audio.channels,
        });
      case 'audio-chunk':
        // Leftovers of a cancelled stream are dropped; they must not cost the connection.
        if (_discardAudio || _audio == null || event.payload == null) return;
        _audio!.bytes += event.payload!.length;
        native.invokeMethod('pcmWrite', event.payload);
        // HA sends no audio-stop if its TTS fails mid-stream: don't keep the mic closed.
        _stall?.cancel();
        _stall = Timer(const Duration(seconds: 5), () {
          if (_audio != null) _onWyoming(const WyomingEvent('audio-stop'));
        });
      case 'audio-stop':
        _stall?.cancel();
        final audio = _audio;
        _audio = null;
        if (_discardAudio) {
          _discardAudio = false;
          return;
        }
        if (audio == null) {
          if (_responseAudio.isNotEmpty) _responseAudio.removeAt(0);
          return;
        }
        final id = _playing;
        if (id == null) return;
        await native.invokeMethod('pcmEnd', id);
        _playTimeout?.cancel();
        _playTimeout = Timer(
          Duration(milliseconds: audio.milliseconds + 10000),
          () => onTtsDone(id, failed: true),
        );
      case 'error':
        _manual = false;
        debugPrint('Wyoming pipeline: $data');
        _audio = null;
        _replyAudio = false;
        _processing = false;
        _responseAudio.remove('wyoming-$_playId');
        _stopSpeech();
        dismiss();
        _retry?.cancel();
        _retry = Timer(const Duration(seconds: 3), () {
          if (!_paused && _satellite?.connected == true) _satellite!.run();
        });
      case 'timer-started' ||
          'timer-updated' ||
          'timer-cancelled' ||
          'timer-finished':
        onTimer(event);
    }
  }

  /// A card's spoken summary, as one TTS request: per-phrase requests left gaps.
  Future<void> _speakReply(String id, String text) async {
    try {
      final pipe = await _pipeline();
      for (var attempt = 0; ; attempt++) {
        if (_disposed || _playing != id) return;
        try {
          // A retry of the same text joins HA's stuck request; a zero-width space
          // changes HA's cache key, so each attempt is a new OpenAI call.
          final variant = text + '​' * attempt;
          final path = await _cacheSpeech(
            await _speechUrl(variant, pipe),
            id,
            _ttsWait(text),
          );
          if (path == null || _disposed || _playing != id) return;
          _speaking = true;
          await native.invokeMethod('wyomingSpeakUrl', {'path': path, 'id': id});
          _playTimeout?.cancel();
          _playTimeout = Timer(
            const Duration(minutes: 2),
            () => onTtsDone(id, failed: true),
          );
          return;
        } catch (_) {
          if (attempt == 2) rethrow;
        }
      }
    } catch (e) {
      debugPrint('Wyoming reply speech: $e');
      if (_disposed || _playing != id) return;
      native.invokeMethod('speechStop');
      audioError = 'No se ha podido reproducir la voz de Ivy.';
      onTtsDone(id, failed: true);
    }
  }

  // ponytail: OpenAI generates the whole clip before sending a byte (~1.5 s short,
  // ~7 s for 300 chars); twice that plus slack. Raise it if long replies time out.
  static Duration _ttsWait(String text) =>
      Duration(milliseconds: 5000 + 40 * text.length);

  Future<String?> _cacheSpeech(String url, String id, Duration limit) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    File? file;
    try {
      final bytes = await (() async {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('TTS HTTP ${response.statusCode}');
        }
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (buffer.length + chunk.length > 32 * 1024 * 1024) {
            throw const FormatException('TTS audio too large');
          }
          buffer.add(chunk);
        }
        if (buffer.isEmpty) throw const FormatException('Empty TTS audio');
        return buffer.takeBytes();
      })().timeout(limit);
      if (_disposed || _playing != id) return null;
      final dir = await native.invokeMethod<String>('filesDir');
      if (_disposed || _playing != id) return null;
      file = File('$dir/wyoming-speech-$id.mp3');
      await file.writeAsBytes(bytes, flush: true);
      if (_disposed || _playing != id) return null;
      _speechFile = file;
      return file.path;
    } finally {
      client.close(force: true);
      if (file != null && _speechFile != file) file.delete().ignore();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _hide?.cancel();
    _playTimeout?.cancel();
    _retry?.cancel();
    _stall?.cancel();
    _noAudio?.cancel();
    _satellite?.close();
    native.invokeMethod('wyomingStop');
    native.invokeMethod('speechStop');
    _speechFile?.delete().ignore();
    native.invokeMethod('micStop');
    super.dispose();
  }

  /// Text questions from the REST API or an OpenUI button use the existing agent.
  Future<void> ask(String text) async {
    if (_paused || _playing != null || _processing || _legacyBusy) return;
    _legacyBusy = true;
    try {
      onWake(); // also for API / OpenUI-button questions: wake the screen
      heard = text;
      ui = null;
      reply = null;
      _set(VoiceState.thinking);
      final pipe = await _pipeline();
      String speech;
      try {
        speech = await _converse(text, pipe);
      } catch (e) {
        speech = 'Lo siento, no he podido responder.';
        debugPrint('Voice ask: $e');
      }
      final (spoken, node) = splitReply(speech);
      reply = spoken;
      ui = node;
      _set(VoiceState.speaking);
      final done = _spoken = Completer<void>();
      // Never go silent: an empty reply still gets a word (a card = "aquí lo tienes",
      // otherwise "hecho"); failures already fall back to the apology above.
      await _speak(
        spoken.isEmpty ? (node == null ? 'Hecho.' : 'Aquí lo tienes.') : spoken,
        pipe,
      );
      await done.future.timeout(const Duration(seconds: 40), onTimeout: () {});
      native.invokeMethod('earcon', 'done');
      _hide?.cancel();
      _hide = Timer(Duration(seconds: ui == null ? 5 : 25), dismiss);
    } finally {
      _legacyBusy = false;
    }
  }

  /// Broadcast/announce: wake the screen, show [text] and speak it with the
  /// pipeline's OpenAI voice, after an attention chime. No agent, no mic — just
  /// says the message (used by HA's "announce" command and the voice tool).
  Future<void> announce(String text) async {
    if (_paused || _playing != null || _processing || _legacyBusy) return;
    _legacyBusy = true;
    try {
      onWake();
      heard = null;
      ui = null;
      reply = text;
      _set(VoiceState.speaking);
      native.invokeMethod('earcon', 'wake'); // attention chime first
      final pipe = await _pipeline();
      final done = _spoken = Completer<void>();
      await _speak(text, pipe);
      await done.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      final shown = shownAt;
      Future.delayed(const Duration(seconds: 6), () {
        if (shownAt == shown && state == VoiceState.speaking) dismiss();
      });
    } finally {
      _legacyBusy = false;
    }
  }

  /// The "Ivy" pipeline config (Settings > Voice assistants), read on each
  /// question so a change to its agent or TTS voice applies at once. {} on failure.
  Future<Map> _pipeline() async {
    try {
      final r = await ha
          .call({'type': 'assist_pipeline/pipeline/list'})
          .timeout(const Duration(seconds: 10));
      final list = r['pipelines'] as List;
      return (list.firstWhere(
            (p) => p['name'] == voicePipeline,
            orElse: () => {},
          )
          as Map);
    } catch (_) {
      return {};
    }
  }

  /// The pipeline's conversation agent (the OpenAI agent "Ivy") answers everything.
  Future<String> _converse(String text, Map pipe) async {
    // A generous cap: the agent may search the web or look at a camera, but
    // without it a lost/stalled reply would hang the whole voice loop in silence.
    final r =
        await ha
                .call({
                  'type': 'conversation/process',
                  'text': text,
                  'language': 'es',
                  'agent_id': pipe['conversation_engine'],
                  if (_conversationId != null)
                    'conversation_id': _conversationId,
                })
                .timeout(const Duration(seconds: 45))
            as Map;
    _conversationId = r['conversation_id'];
    return r['response']?['speech']?['plain']?['speech'] as String? ?? '';
  }

  Future<String> _speechUrl(String text, Map pipe) async {
    final engine = pipe['tts_engine'];
    if (engine == null) throw StateError('No TTS engine configured');
    final r = await ha
        .restPost('/api/tts_get_url', {
          'engine_id': engine,
          'message': text,
          'language': pipe['tts_language'] ?? 'es',
          if (pipe['tts_voice'] != null)
            'options': {'voice': pipe['tts_voice']},
        })
        .timeout(const Duration(seconds: 15));
    final url = (r as Map?)?['url'];
    if (url is! String) throw StateError('TTS did not return an audio URL');
    return url;
  }

  /// Text questions and announcements retain the configured voice on failures.
  Future<void> _speak(String text, Map pipe) async {
    try {
      audioError = null;
      final url = await _speechUrl(text, pipe);
      await native.invokeMethod('speakUrl', url);
    } catch (e) {
      debugPrint('Voice TTS (HA): $e');
      audioError = 'No se ha podido reproducir la voz de Ivy.';
      if (_spoken?.isCompleted == false) _spoken!.complete();
      if (!_disposed) notifyListeners();
    }
  }
}

// ------------------------------------------------------------ UI

const _googleDots = [
  Color(0xFF4285F4),
  Color(0xFFEA4335),
  Color(0xFFFBBC05),
  Color(0xFF34A853),
];

/// Google Assistant-style overlay: generated UI card above, voice plate with the four dots below.
class VoiceOverlay extends StatelessWidget {
  final Voice voice;
  const VoiceOverlay({super.key, required this.voice});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final v = voice;
        final visible = v.state != VoiceState.idle;
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            opacity: visible ? 1 : 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: v.dismiss,
              child: Container(
                color: const Color(0xB3000000),
                padding: const EdgeInsets.fromLTRB(40, 28, 40, 20),
                child: Column(
                  children: [
                    Expanded(
                      child: v.ui == null
                          ? const SizedBox()
                          : Center(
                              child: GestureDetector(
                                onTap: v.dismiss,
                                child: Container(
                                  constraints: const BoxConstraints(
                                    maxWidth: 820,
                                  ),
                                  padding: const EdgeInsets.all(20),
                                  decoration: BoxDecoration(
                                    color: bg,
                                    borderRadius: BorderRadius.circular(26),
                                  ),
                                  child: SingleChildScrollView(
                                    child: OpenUiView(
                                      node: v.ui!,
                                      onAssistant: v.ask,
                                      ha: v.ha,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: 14),
                    // Hidden dots must not keep the screen redrawing at 60 fps.
                    TickerMode(enabled: visible, child: _Plate(voice: v)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Plate extends StatelessWidget {
  final Voice voice;
  const _Plate({required this.voice});
  @override
  Widget build(BuildContext context) {
    final v = voice;
    final (String top, String? bottom) = switch (v.state) {
      VoiceState.listening => ('Te escucho…', null),
      VoiceState.thinking => ('Pensando…', v.heard),
      VoiceState.speaking => (v.reply ?? '', v.heard),
      VoiceState.idle => ('', null),
    };
    return Container(
      constraints: const BoxConstraints(maxWidth: 820),
      padding: const EdgeInsets.fromLTRB(22, 16, 26, 16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(32),
      ),
      child: Row(
        children: [
          _Dots(mode: v.state),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (bottom != null)
                  Text(
                    bottom,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: gs(14, color: muted),
                  ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    top,
                    key: ValueKey(top),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: gs(
                      v.state == VoiceState.listening ? 22 : 21,
                      color: v.state == VoiceState.listening
                          ? muted
                          : onSurface,
                    ),
                  ),
                ),
                if (v.audioError != null)
                  Text(v.audioError!, style: gs(14, color: muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The four Google dots: bouncing while listening, waving while thinking, pulsing while speaking.
class _Dots extends StatefulWidget {
  final VoiceState mode;
  const _Dots({required this.mode});
  @override
  State<_Dots> createState() => _DotsState();
}

class _DotsState extends State<_Dots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 40,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < 4; i++)
              Transform.translate(
                offset: Offset(0, switch (widget.mode) {
                  VoiceState.listening =>
                    -8 * max(0.0, sin(_c.value * 2 * pi - i * 0.7)),
                  VoiceState.thinking => 6 * sin(_c.value * 4 * pi - i * 1.1),
                  _ => 0,
                }),
                child: Container(
                  width: 11,
                  height: widget.mode == VoiceState.speaking
                      ? 11 + 10 * max(0.0, sin(_c.value * 6 * pi + i))
                      : 11,
                  decoration: BoxDecoration(
                    color: _googleDots[i],
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
