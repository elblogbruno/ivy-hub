import 'package:flutter_test/flutter_test.dart';
import 'package:ivy_display/ambient.dart';
import 'package:ivy_display/ha.dart';
import 'package:ivy_display/screen.dart';
import 'package:ivy_display/spotify.dart';
import 'package:ivy_display/openui.dart';

void main() {
  test('fecha y hora en español', () {
    final t = DateTime(2026, 10, 16, 9, 5);
    expect(hhmm(t), '09:05');
    expect(longDate(t), 'Viernes, 16 de octubre');
    expect(longDate(DateTime(2026, 3, 1)), 'Domingo, 1 de marzo');
  });

  test('subscribe_entities: alta, cambio y baja', () {
    final ha = HA({'light.x'});
    ha.applyEntities({
      'a': {
        'light.x': {
          's': 'off',
          'a': {'friendly_name': 'X', 'brightness': 10},
        },
      },
    });
    expect(ha['light.x']!['state'], 'off');
    ha.applyEntities({
      'c': {
        'light.x': {
          '+': {
            's': 'on',
            'a': {'brightness': 255},
          },
          '-': {
            'a': ['friendly_name'],
          },
        },
      },
    });
    expect(ha['light.x']!['state'], 'on');
    expect(ha['light.x']!['attributes'], {'brightness': 255});
    ha.applyEntities({
      'r': ['light.x'],
    });
    expect(ha['light.x'], isNull);
  });

  test(
    'sensor de luz: oscuro -> reposo -> apagado, luz o toque despiertan',
    () {
      final p = Presence();
      var t = DateTime(2026, 10, 16, 12);
      p.onLux(200, t);
      expect(p.mode, ScreenMode.normal);
      p.onLux(0, t);
      expect(p.mode, ScreenMode.normal); // not yet 15 s
      t = t.add(const Duration(seconds: 16));
      p.evaluate(t);
      expect(p.mode, ScreenMode.standby);
      t = t.add(const Duration(minutes: 3));
      p.evaluate(t);
      expect(p.mode, ScreenMode.off);
      p.onNear(true, t);
      expect(p.mode, ScreenMode.standby);
      p.touch(t);
      expect(p.mode, ScreenMode.normal);
      t = t.add(const Duration(minutes: 2)); // touch wake expired, still dark
      p.evaluate(t); // dark timer restarts...
      t = t.add(const Duration(seconds: 16));
      p.evaluate(t); // ...and after 15 s it is back to standby
      expect(p.mode, isNot(ScreenMode.normal));
      p.onLux(6, t); // inside hysteresis band: stays dark
      expect(p.mode, isNot(ScreenMode.normal));
      p.onLux(150, t);
      expect(p.mode, ScreenMode.normal);
      expect(p.brightness, greaterThan(0.5));
    },
  );

  test('spotify: canción, posición, pausa y caducidad', () {
    final sp = Spotify();
    var t = DateTime(2026, 10, 16, 23);
    sp.apply({
      'event': 'track_changed',
      'name': 'Canción',
      'artists': 'A, B',
      'duration_ms': '200000',
    }, t);
    sp.apply({'event': 'playing', 'position_ms': '1000'}, t);
    t = t.add(const Duration(seconds: 10));
    expect(sp.positionAt(t), 11000);
    expect(sp.activeAt(t), isTrue);
    sp.apply({'event': 'paused', 'position_ms': '11000'}, t);
    t = t.add(const Duration(minutes: 5));
    expect(sp.positionAt(t), 11000); // frozen while paused
    expect(sp.activeAt(t), isTrue);
    t = t.add(const Duration(minutes: 6));
    expect(sp.activeAt(t), isFalse); // back to photos after 10 min paused
    sp.apply({'event': 'volume_changed', 'volume': '32767'}, t);
    expect(sp.volume, closeTo(0.5, 0.01));
  });

  test('letras: LRC de LRCLIB y JSON de Spotify', () {
    final lrc = parseLrc('[00:12.50] Hola\n[01:02.00] Adiós\n[01:05.00]   \n');
    expect(lrc.map((l) => l.ms), [12500, 62000]);
    expect(lrc.last.text, 'Adiós');
    final sp = parseSpotifyLyrics(
      '{"lyrics":{"syncType":"LINE_SYNCED","lines":[{"startTimeMs":"1000","words":"Uno"},'
      '{"startTimeMs":"2000","words":"♪"},{"startTimeMs":"3000","words":"Dos"}]},'
      '"colors":{"background":-11184811,"text":-16777216,"highlightText":-1}}',
    )!;
    expect(sp.synced, isTrue);
    expect(sp.lines.map((l) => l.text), ['Uno', 'Dos']);
    expect(sp.background, isNotNull);
    expect(parseSpotifyLyrics(''), isNull);
  });

  test('OpenUI Lang: respuesta con voz + bloque, referencias adelantadas', () {
    const reply =
        'Mañana hará sol en Manresa.\n```openui\n'
        'root = Card([title, row, more], "Tiempo")\n'
        'row = Stack([max, min], "row")\n'
        'max = Stat("Máxima", "" + 24 + "°", "sunny")\n'
        'min = Stat("Mínima", "12°", "night")\n'
        'title = TextContent("Sábado", "lg")\n'
        'more = Button("¿Y el domingo?", @ToAssistant("¿Qué tiempo hará el domingo?"))\n'
        'bad = NoExiste(1, 2)\n'
        '```';
    final (speech, ui) = splitReply(reply);
    expect(speech, 'Mañana hará sol en Manresa.');
    expect(ui!.type, 'Card');
    expect(ui.arg(1), 'Tiempo');
    final kids = ui.arg(0) as List;
    expect((kids[0] as UiNode).arg(0), 'Sábado');
    final row = kids[1] as UiNode;
    expect(((row.arg(0) as List)[0] as UiNode).arg(1), '24°');
    expect(
      ((kids[2] as UiNode).arg(1) as UiAction).message,
      '¿Qué tiempo hará el domingo?',
    );
    expect(splitReply('Solo texto').$2, isNull);
    expect(
      parseOpenUi('a = Card([a])'),
      isNotNull,
    ); // self-reference doesn't loop forever
  });
}
