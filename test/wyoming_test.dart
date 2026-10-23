import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ivy_display/wyoming.dart';

void main() {
  test(
    'fragmented UTF-8 data and binary payload preserve frame boundaries',
    () async {
      final raw =
          (BytesBuilder()
                ..add(
                  const WyomingEvent('synthesize', {
                    'text': 'Cocina: café ☕',
                  }).encode(),
                )
                ..add(
                  WyomingEvent('audio-chunk', const {
                    'rate': 22050,
                  }, Uint8List.fromList([0, 10, 255, 0])).encode(),
                )
                ..add(const WyomingEvent('ping', {'text': 'alive'}).encode()))
              .takeBytes();
      final events = await WyomingEvent.decode(
        Stream.fromIterable([
          for (final byte in raw) Uint8List.fromList([byte]),
        ]),
      ).toList();
      expect(events.map((e) => e.type), ['synthesize', 'audio-chunk', 'ping']);
      expect(events[0].data['text'], 'Cocina: café ☕');
      expect(events[1].payload, [0, 10, 255, 0]);
      expect(events[2].data['text'], 'alive');
    },
  );

  test(
    'inline data merges with external data as Python Wyoming does',
    () async {
      final extra = utf8.encode(jsonEncode({'text': 'sí'}));
      final raw =
          (BytesBuilder()
                ..add(
                  utf8.encode(
                    '${jsonEncode({
                      'type': 'transcript',
                      'data': {'language': 'es'},
                      'data_length': extra.length,
                    })}\n',
                  ),
                )
                ..add(extra))
              .takeBytes();
      final event = await WyomingEvent.decode(Stream.value(raw)).single;
      expect(event.data, {'language': 'es', 'text': 'sí'});
    },
  );

  test('reject oversized, negative and truncated network frames', () async {
    for (final frame in [
      '{"type":"x","payload_length":1048577}\n',
      '{"type":"x","data_length":-1}\n',
      '{"type":"x","data_length":3}\n{}',
      '{"type":"x","payload_length":2}\nx',
      '{"type":"x"}',
    ]) {
      await expectLater(
        WyomingEvent.decode(
          Stream.value(Uint8List.fromList(utf8.encode(frame))),
        ).toList(),
        throwsFormatException,
      );
    }
  });

  test('PCM stream format is validated and its length measured', () {
    final audio = WyomingAudio({'rate': 22050, 'width': 2, 'channels': 1})
      ..bytes = 44100;
    expect(audio.milliseconds, 1000);
    expect(
      () => WyomingAudio({'rate': 16000, 'width': 3, 'channels': 1}),
      throwsFormatException,
    );
  });

  test('HA discovery, mic, pause, probes, busy client and reconnect', () async {
    final errors = <Object>[];
    final connections = <bool>[];
    final incoming = <WyomingEvent>[];
    final satellite = WyomingSatellite(
      name: 'Ivy Cocina',
      area: 'Kitchen',
      onEvent: (e) async => incoming.add(e),
      onConnection: connections.add,
      onError: errors.add,
    );
    await satellite.start(address: InternetAddress.loopbackIPv4, port: 0);
    addTearDown(satellite.close);
    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      satellite.port,
    );
    addTearDown(client.destroy);
    final events = StreamIterator(WyomingEvent.decode(client));
    addTearDown(events.cancel);
    Future<WyomingEvent> next() async {
      expect(
        await events.moveNext().timeout(const Duration(seconds: 2)),
        isTrue,
      );
      return events.current;
    }

    client.add(const WyomingEvent('describe').encode());
    final info = await next();
    expect(info.data['satellite']['name'], 'Ivy Cocina');
    expect(info.data['satellite']['area'], 'Kitchen');
    expect(satellite.connected, isFalse);
    client.add(const WyomingEvent('run-satellite').encode());
    expect((await next()).data, {
      'start_stage': 'wake',
      'end_stage': 'tts',
      'restart_on_end': true,
    });
    expect((await next()).type, 'audio-start');
    satellite.onMic(Uint8List.fromList([1, 2]));
    satellite.send(const WyomingEvent('played'));
    expect((await next()).payload, [1, 2]);
    expect((await next()).type, 'played');
    client.add(const WyomingEvent('pause-satellite').encode());
    client.add(const WyomingEvent('ping', {'text': 'paused'}).encode());
    expect((await next()).data['text'], 'paused');
    satellite.onMic(Uint8List.fromList([3, 4]));
    client.add(const WyomingEvent('ping').encode());
    expect((await next()).type, 'pong'); // no mic packet while paused

    final probe = await Socket.connect(
      InternetAddress.loopbackIPv4,
      satellite.port,
    );
    final probeEvents = StreamIterator(WyomingEvent.decode(probe));
    probe.add(const WyomingEvent('describe').encode());
    expect(await probeEvents.moveNext(), isTrue);
    expect(probeEvents.current.type, 'info');
    probe.add(const WyomingEvent('run-satellite').encode());
    expect(await probeEvents.moveNext(), isFalse); // cannot steal the session
    await probeEvents.cancel();
    probe.destroy();
    expect(satellite.connected, isTrue);
    expect(errors, hasLength(1));

    client.add(const WyomingEvent('run-satellite').encode());
    expect((await next()).type, 'run-pipeline');
    expect((await next()).type, 'audio-start');
    satellite.muted = true;
    expect((await next()).type, 'audio-stop');
    satellite.onMic(Uint8List.fromList([5, 6]));
    client.add(const WyomingEvent('ping').encode());
    expect((await next()).type, 'pong');
    satellite.muted = false;
    expect((await next()).type, 'run-pipeline');
    expect((await next()).type, 'audio-start');
    await events.cancel();
    client.destroy();
    // A new HA connection is accepted after the old one closes.
    for (var i = 0; i < 100 && satellite.connected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(satellite.connected, isFalse);
    final reconnect = await Socket.connect(
      InternetAddress.loopbackIPv4,
      satellite.port,
    );
    final reconnected = StreamIterator(WyomingEvent.decode(reconnect));
    reconnect.add(const WyomingEvent('run-satellite').encode());
    expect(await reconnected.moveNext(), isTrue);
    expect(reconnected.current.type, 'run-pipeline');
    await reconnected.cancel();
    reconnect.destroy();
    expect(connections, containsAllInOrder([true, false, true]));
  });
}
