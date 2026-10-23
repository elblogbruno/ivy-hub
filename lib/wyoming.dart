import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Wyoming framing: JSON header, optional UTF-8 data, then binary payload.
class WyomingEvent {
  final String type;
  final Map<String, dynamic> data;
  final Uint8List? payload;
  const WyomingEvent(this.type, [this.data = const {}, this.payload]);

  Uint8List encode() {
    final body = utf8.encode(jsonEncode(data));
    return (BytesBuilder(copy: false)
          ..add(
            utf8.encode(
              '${jsonEncode({'type': type, 'data_length': body.length, if (payload != null) 'payload_length': payload!.length})}\n',
            ),
          )
          ..add(body)
          ..add(payload ?? const []))
        .takeBytes();
  }

  static Stream<WyomingEvent> decode(Stream<Uint8List> input) async* {
    final chunks = StreamIterator(input);
    var chunk = Uint8List(0), offset = 0;
    Future<bool> available() async {
      while (offset == chunk.length) {
        if (!await chunks.moveNext()) return false;
        chunk = chunks.current;
        offset = 0;
      }
      return true;
    }

    Future<Uint8List> take(int length) async {
      final bytes = BytesBuilder(copy: false);
      while (length > 0) {
        if (!await available()) throw const FormatException('Truncated event');
        final end = (offset + length).clamp(0, chunk.length);
        bytes.add(Uint8List.sublistView(chunk, offset, end));
        length -= end - offset;
        offset = end;
      }
      return bytes.takeBytes();
    }

    int length(Map header, String key) {
      final n = header[key] ?? 0;
      if (n is! int || n < 0 || n > 1024 * 1024) {
        throw FormatException('Invalid $key');
      }
      return n;
    }

    try {
      while (await available()) {
        final line = BytesBuilder(copy: false);
        while (true) {
          if (!await available()) {
            throw const FormatException('Truncated header');
          }
          final newline = chunk.indexOf(10, offset);
          final end = newline < 0 ? chunk.length : newline;
          line.add(Uint8List.sublistView(chunk, offset, end));
          offset = end + (newline < 0 ? 0 : 1);
          if (line.length > 65536) {
            throw const FormatException('Header too large');
          }
          if (newline >= 0) break;
        }
        final header = jsonDecode(utf8.decode(line.takeBytes())) as Map;
        if (header['type'] is! String) {
          throw const FormatException('Missing type');
        }
        final data = Map<String, dynamic>.from(header['data'] as Map? ?? {});
        final dataLength = length(header, 'data_length');
        if (dataLength > 0) {
          data.addAll(
            Map<String, dynamic>.from(
              jsonDecode(utf8.decode(await take(dataLength))) as Map,
            ),
          );
        }
        final payloadLength = length(header, 'payload_length');
        yield WyomingEvent(
          header['type'] as String,
          data,
          payloadLength == 0 ? null : await take(payloadLength),
        );
      }
    } finally {
      await chunks.cancel();
    }
  }
}

/// A single HA session owns the mic; discovery probes never take it over.
class WyomingSatellite {
  final String name;
  final String? area;
  final Future<void> Function(WyomingEvent) onEvent;
  final void Function(bool) onConnection;
  final void Function(Object) onError;
  ServerSocket? _server;
  Socket? _client;
  final _sockets = <Socket>{};
  final _writes = <Socket, Future<void>>{};
  bool _streaming = false, _muted = false, _ready = false, _sending = false;
  bool get connected => _client != null;
  bool get ready => connected && _ready && !_muted;
  int get port => _server!.port;

  WyomingSatellite({
    required this.name,
    this.area,
    required this.onEvent,
    required this.onConnection,
    required this.onError,
  });

  Future<void> start({InternetAddress? address, int port = 10700}) async {
    _server = await ServerSocket.bind(address ?? InternetAddress.anyIPv4, port);
    _server!.listen(_accept, onError: onError);
  }

  Future<void> _write(Socket socket, WyomingEvent event) {
    // Socket.flush binds its sink; serialize control messages with microphone audio.
    final bytes = event.encode();
    final pending = (_writes[socket] ?? Future<void>.value())
        .then((_) async {
          if (!_sockets.contains(socket)) return;
          socket.add(bytes);
          await socket.flush();
        })
        .catchError((Object e) {
          onError(e);
          socket.destroy();
        });
    _writes[socket] = pending;
    return pending;
  }

  void send(WyomingEvent event) {
    final socket = _client;
    if (socket != null) _write(socket, event);
  }

  void run({String startStage = 'wake', bool restartOnEnd = true}) {
    if (!_ready || _muted) return;
    send(
      WyomingEvent('run-pipeline', {
        'start_stage': startStage,
        'end_stage': 'tts',
        'restart_on_end': restartOnEnd,
      }),
    );
    send(
      const WyomingEvent('audio-start', {
        'rate': 16000,
        'width': 2,
        'channels': 1,
      }),
    );
    _streaming = true;
  }

  set muted(bool value) {
    if (_muted == value) return;
    _muted = value;
    if (value) {
      send(const WyomingEvent('audio-stop'));
    } else if (connected && _ready) {
      run();
    }
  }

  void onMic(Uint8List pcm) {
    if (!connected || !_streaming || _muted || _sending) return;
    final socket = _client!;
    _sending = true;
    _write(
      socket,
      WyomingEvent('audio-chunk', const {
        'rate': 16000,
        'width': 2,
        'channels': 1,
      }, pcm),
    ).whenComplete(() {
      if (_client == socket) _sending = false;
    });
  }

  Future<void> _accept(Socket socket) async {
    _sockets.add(socket);
    try {
      await for (final event in WyomingEvent.decode(socket)) {
        switch (event.type) {
          case 'describe':
            _write(
              socket,
              WyomingEvent('info', {
                'satellite': {
                  'name': name,
                  'description': 'Ivy voice satellite',
                  'attribution': {
                    'name': 'Ivy',
                    'url':
                        'https://www.home-assistant.io/integrations/wyoming/',
                  },
                  'installed': true,
                  'version': '1.0.0',
                  'area': area,
                  'has_vad': false,
                  'supports_trigger': false,
                },
              }),
            );
          case 'ping':
            _write(socket, WyomingEvent('pong', event.data));
          case 'run-satellite':
            if (_client != null && _client != socket) {
              throw const FormatException('Satellite already in use');
            }
            final wasConnected = connected;
            _client = socket;
            _ready = true;
            if (!wasConnected) onConnection(true);
            if (!_muted) run();
          case 'pause-satellite':
            if (_client == socket) {
              _streaming = false;
              _ready = false;
            }
          default:
            if (_client == socket) await onEvent(event);
        }
      }
    } catch (e) {
      onError(e);
    } finally {
      if (_client == socket) {
        _client = null;
        _streaming = false;
        _ready = false;
        _sending = false;
        onConnection(false);
      }
      _sockets.remove(socket);
      _writes.remove(socket);
      socket.destroy();
    }
  }

  Future<void> close() async {
    await _server?.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
  }
}

/// One HA audio stream; it's played live, so only its format and length are kept.
class WyomingAudio {
  final int rate, width, channels;
  int bytes = 0;
  WyomingAudio(Map data)
    : rate = data['rate'] as int,
      width = data['width'] as int,
      channels = data['channels'] as int {
    if (rate < 8000 ||
        rate > 96000 ||
        width != 2 ||
        channels < 1 ||
        channels > 2) {
      throw const FormatException('Unsupported PCM format');
    }
  }

  int get milliseconds => bytes * 1000 ~/ (rate * width * channels);
}
