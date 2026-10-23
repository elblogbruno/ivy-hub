import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/ha.dart';
import '../lib/ui.dart';
import '../lib/voice.dart';
import '../lib/wyoming.dart';

class FakeHA implements HA {
  final speech = <String>[];
  final delayed = <String, Completer<Map<String, dynamic>>>{};
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #call) {
      return Future<Map<String, dynamic>>.value({
        'pipelines': <dynamic>[
          {'name': 'Ivy', 'tts_engine': 'tts.test', 'tts_language': 'es'},
        ],
      });
    }
    if (invocation.memberName == #restPost) {
      final body = invocation.positionalArguments[1] as Map;
      speech.add(body['message'] as String);
      if (delayed[body['message']] case final pending?) return pending.future;
      return Future<Map<String, dynamic>>.value({
        'url':
            'https://example.invalid/${Uri.encodeComponent(body['message'] as String)}.mp3',
      });
    }
    return super.noSuchMethod(invocation);
  }
}

String card(String speech) =>
    '$speech\n```openui\nroot = TextContent("Tarjeta");\n```';

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

class SpeechClient implements HttpClient {
  static final requests = <Uri>[];
  static final delayed = <String, Completer<HttpClientResponse>>{};
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return SpeechRequest(url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter || invocation.memberName == #close) return null;
    return super.noSuchMethod(invocation);
  }
}

class SpeechRequest implements HttpClientRequest {
  final Uri url;
  SpeechRequest(this.url);
  @override
  Future<HttpClientResponse> close() async =>
      await (SpeechClient.delayed[url.toString()]?.future ??
          Future.value(SpeechResponse(url)));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SpeechResponse extends Stream<List<int>> implements HttpClientResponse {
  final Uri url;
  SpeechResponse(this.url);
  @override
  int get statusCode => url.path.contains('http-error') ? 500 : HttpStatus.ok;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(url.toString())).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> run() =>
    HttpOverrides.runZoned(_run, createHttpClient: (_) => SpeechClient());

Future<void> _run() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final played = <MethodCall>[];
  final rendered = <String>[];
  final fallback = <MethodCall>[];
  final pcm = <MethodCall>[];
  final directory = Directory('.dart_tool/voice-audio-test')..createSync();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(native, (call) async {
        switch (call.method) {
          case 'deviceName':
            return 'Voice selfcheck';
          case 'deviceId':
            return 'test';
          case 'deviceRoom':
            return 'test';
          case 'filesDir':
            return directory.absolute.path;
          case 'wyomingSpeakUrl':
            played.add(call);
            final path = (call.arguments as Map)['path'] as String;
            check(
              !path.startsWith('http'),
              'Android still fetches the remote URL',
            );
            if (path.endsWith('.mp3'))
              rendered.add(File(path).readAsStringSync());
            return null;
          case 'wyomingSpeak':
            fallback.add(call);
            return null;
          case 'pcmStart' || 'pcmWrite' || 'pcmEnd':
            pcm.add(call);
            return null;
          default:
            return null;
        }
      });
  final ha = FakeHA();
  final voice = Voice(ha: ha, onWake: () {}, onTimer: (_) {});
  Socket? client;
  StreamIterator<WyomingEvent>? events;
  Future<void> speechCount(int count) async {
    for (var i = 0; i < 800 && played.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    check(
      played.length == count,
      'Expected $count player starts, got ${played.length}',
    );
  }

  Future<WyomingEvent> next() async {
    check(
      await events!.moveNext().timeout(const Duration(seconds: 3)),
      'Disconnected',
    );
    return events!.current;
  }

  try {
    check(!await voice.listen(), 'Offline screen accepted a button press');
    await voice.start();
    client = await Socket.connect(InternetAddress.loopbackIPv4, 10700);
    events = StreamIterator(WyomingEvent.decode(client));
    client.add(const WyomingEvent('run-satellite').encode());
    check((await next()).type == 'run-pipeline', 'Missing pipeline');
    check((await next()).type == 'audio-start', 'Missing microphone');
    check(await voice.listen(), 'Connected screen rejected a button press');
    final manual = await next();
    check(
      manual.type == 'run-pipeline' &&
          manual.data['start_stage'] == 'asr' &&
          manual.data['restart_on_end'] == false,
      'Button must skip wake detection for one question only',
    );
    check((await next()).type == 'audio-start', 'Button did not open the mic');
    check(voice.state == VoiceState.listening, 'Button did not show listening');
    voice.onMic(Uint8List.fromList([8, 9]));
    check((await next()).payload?.last == 9, 'Button mic was not forwarded');
    client.add(
      const WyomingEvent('synthesize', {
        'text': 'Hola.\n```openui\nroot = TextContent("Tarjeta");\n```',
      }).encode(),
    );
    await speechCount(1);
    check(ha.speech.single == 'Hola.', 'Markup was sent to TTS');
    // The player must start before any HA PCM is received.
    client.add(
      const WyomingEvent('audio-start', {
        'rate': 22050,
        'width': 2,
        'channels': 1,
      }).encode(),
    );
    client.add(
      WyomingEvent('audio-chunk', {}, Uint8List.fromList([0, 0])).encode(),
    );
    client.add(const WyomingEvent('audio-stop').encode());
    client.add(const WyomingEvent('ping').encode());
    check((await next()).type == 'pong', 'PCM stream failed');
    check(played.length == 1 && pcm.isEmpty, 'Card was spoken twice');
    voice.onTtsDone((played.single.arguments as Map)['id'] as String);
    check((await next()).type == 'played', 'Missing played acknowledgement');
    check(
      (await next()).data['start_stage'] == 'wake',
      'Wake detection not restored',
    );
    check((await next()).type == 'audio-start', 'Wake microphone not restored');
    voice.paused = true;
    check(!await voice.listen(), 'Button opened the mic during a call');
    check((await next()).type == 'audio-stop', 'Pause did not close the mic');
    voice.paused = false;
    check(
      (await next()).data['start_stage'] == 'wake',
      'Call did not restore wake',
    );
    check((await next()).type == 'audio-start', 'Call did not restore mic');
    client.add(
      const WyomingEvent('synthesize', {'text': 'Respuesta.'}).encode(),
    );
    client.add(
      const WyomingEvent('audio-start', {
        'rate': 22050,
        'width': 2,
        'channels': 1,
      }).encode(),
    );
    client.add(
      WyomingEvent('audio-chunk', {}, Uint8List.fromList([5, 6])).encode(),
    );
    client.add(const WyomingEvent('ping').encode());
    check((await next()).type == 'pong', 'Plain reply stream failed');
    voice.onMic(Uint8List.fromList([1, 1]));
    client.add(const WyomingEvent('audio-stop').encode());
    client.add(const WyomingEvent('ping').encode());
    check((await next()).type == 'pong', 'Mic leaked while the reply played');
    check(
      ha.speech.length == 1 &&
          voice.reply == 'Respuesta.' &&
          pcm.map((c) => c.method).join(',') == 'pcmStart,pcmWrite,pcmEnd' &&
          (pcm[1].arguments as Uint8List).last == 6,
      'Plain reply was not played live from HA audio',
    );
    voice.onTtsDone(pcm.last.arguments as String);
    check((await next()).type == 'played', 'Missing live reply acknowledgement');
    // Stray chunks (e.g. after an error) are ignored instead of dropping the connection.
    client.add(
      WyomingEvent('audio-chunk', {}, Uint8List.fromList([1, 2])).encode(),
    );
    client.add(const WyomingEvent('ping').encode());
    check((await next()).type == 'pong', 'Stray chunk dropped the connection');
    pcm.clear();
    client.add(
      const WyomingEvent('audio-start', {
        'rate': 22050,
        'width': 2,
        'channels': 1,
      }).encode(),
    );
    client.add(
      WyomingEvent(
        'audio-chunk',
        {},
        Uint8List.fromList([1, 2, 3, 4]),
      ).encode(),
    );
    client.add(const WyomingEvent('audio-stop').encode());
    client.add(const WyomingEvent('ping').encode());
    check((await next()).type == 'pong', 'Announcement stream failed');
    check(
      pcm.length == 3 &&
          (pcm[1].arguments as Uint8List).length == 4 &&
          voice.reply == null,
      'Announcement was not played live',
    );
    voice.onTtsDone(pcm.last.arguments as String);
    check(
      (await next()).type == 'played',
      'Missing announcement acknowledgement',
    );
    final weather = Completer<Map<String, dynamic>>();
    ha.delayed['El tiempo.'] = weather;
    client.add(
      const WyomingEvent('synthesize', {
        'text': 'El tiempo.\n```openui\nroot = TextContent("Tiempo");\n```',
      }).encode(),
    );
    for (var i = 0; i < 200 && !ha.speech.contains('El tiempo.'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    check(ha.speech.last == 'El tiempo.', 'Weather TTS request did not start');
    voice.onMic(Uint8List.fromList([7, 8]));
    check(
      (await next()).type == 'audio-chunk',
      'Mic blocked while generating TTS',
    );
    client.add(const WyomingEvent('detection').encode());
    client.add(
      WyomingEvent('synthesize', {'text': card('Un chiste.')}).encode(),
    );
    client.add(const WyomingEvent('ping').encode());
    check((await next()).type == 'pong', 'New question was not received');
    weather.complete({'url': 'https://example.invalid/stale-weather.mp3'});
    await speechCount(2);
    check(
      rendered.last.contains('Un%20chiste.'),
      'An old weather response played after the joke was displayed',
    );
    voice.onMic(Uint8List.fromList([9, 10]));
    // Both old HA PCM streams can arrive after the current text and native voice.
    for (var i = 0; i < 2; i++) {
      client.add(
        const WyomingEvent('audio-start', {
          'rate': 22050,
          'width': 2,
          'channels': 1,
        }).encode(),
      );
      client.add(
        WyomingEvent('audio-chunk', {}, Uint8List.fromList([1, 2])).encode(),
      );
      client.add(const WyomingEvent('audio-stop').encode());
    }
    client.add(const WyomingEvent('ping').encode());
    check(
      (await next()).type == 'pong',
      'Late PCM not drained or mic leaked during playback',
    );
    check(played.length == 2, 'Old PCM replayed over the current answer');
    voice.onTtsDone((played.last.arguments as Map)['id'] as String);
    check(
      (await next()).type == 'played',
      'Missing current reply acknowledgement',
    );
    final slowUrl = Uri.parse(
      'https://example.invalid/Antigua%20descargando..mp3',
    );
    final slowDownload = Completer<HttpClientResponse>();
    SpeechClient.delayed[slowUrl.toString()] = slowDownload;
    client.add(
      WyomingEvent('synthesize', {
        'text': card('Antigua descargando.'),
      }).encode(),
    );
    for (var i = 0; i < 200 && !SpeechClient.requests.contains(slowUrl); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    check(
      SpeechClient.requests.contains(slowUrl),
      'Old download did not start',
    );
    client.add(const WyomingEvent('transcribe').encode());
    client.add(
      WyomingEvent('synthesize', {'text': card('Otra nueva.')}).encode(),
    );
    await speechCount(3);
    check(
      rendered.last.contains('Otra%20nueva.'),
      'Wrong downloaded audio played',
    );
    slowDownload.complete(SpeechResponse(slowUrl));
    for (var i = 0; i < 2; i++)
      client.add(const WyomingEvent('audio-stop').encode());
    client.add(const WyomingEvent('ping').encode());
    check((await next()).type == 'pong', 'Missing download-race barrier');
    check(played.length == 3, 'An obsolete download started playback');
    voice.onTtsDone((played.last.arguments as Map)['id'] as String);
    check(
      (await next()).type == 'played',
      'Missing downloaded reply acknowledgement',
    );
    client.add(
      WyomingEvent('synthesize', {'text': card('http-error')}).encode(),
    );
    check(
      (await next()).type == 'error' &&
          fallback.isEmpty &&
          voice.audioError != null &&
          SpeechClient.requests
                  .where((u) => u.path.contains('http-error'))
                  .length ==
              3 &&
          ha.speech.toSet().length == ha.speech.length,
      'A failed download changed to the Android voice or hid the failure',
    );
    client.add(const WyomingEvent('audio-stop').encode());
    client.add(
      WyomingEvent('synthesize', {
        'text': card('Primera frase. Segunda frase.'),
      }).encode(),
    );
    await speechCount(4);
    check(
      ha.speech.last == 'Primera frase. Segunda frase.' &&
          rendered.last.contains('Primera%20frase.%20Segunda%20frase.'),
      'Card summary was split into several TTS requests',
    );
    final summary = File((played.last.arguments as Map)['path'] as String);
    voice.onTtsDone((played.last.arguments as Map)['id'] as String);
    check((await next()).type == 'played', 'Missing card acknowledgement');
    check(!summary.existsSync(), 'Played summary file was not deleted');
    client.add(const WyomingEvent('audio-stop').encode());
    // HA's own TTS hangs at times (OpenAI call, 10-min client timeout): speak it ourselves.
    client.add(
      const WyomingEvent('synthesize', {'text': 'Sin audio.'}).encode(),
    );
    await speechCount(5);
    check(ha.speech.last == 'Sin audio.', 'Plain reply without HA audio stayed silent');
    voice.onTtsDone((played.last.arguments as Map)['id'] as String);
    check((await next()).type == 'played', 'Missing fallback acknowledgement');
    print(
      'PASS: button ASR and wake restoration; plain replies and announcements stream live; card summary as one TTS request; cancellation and stale audio; OpenAI failure stays visible without Android voice; mic gates and PCM announcements',
    );
  } finally {
    await events?.cancel();
    client?.destroy();
    voice.dispose();
    for (
      var i = 0;
      i < 100 &&
          directory.listSync().whereType<File>().any(
            (f) => f.path.endsWith('.mp3'),
          );
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (directory.existsSync()) directory.deleteSync();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cards speak their summary; plain replies and announcements play HA audio live',
    run,
  );
}
