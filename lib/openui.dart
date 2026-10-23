import 'package:flutter/material.dart';

import 'camera.dart';
import 'ha.dart';
import 'ui.dart';

/// Minimal OpenUI Lang 1.0 runtime (https://www.openui.com/docs/openui-lang/specification):
/// `name = Expression` statements, positional component args, forward references,
/// literals/arrays/objects, member access, + - * / % comparisons && || ! and ternary,
/// and the `@ToAssistant` action. Queries, mutations and $variables aren't needed here.
/// Unknown components/functions are dropped and the rest renders, as the spec requires.

class UiNode {
  final String type;
  final List<dynamic> args;
  const UiNode(this.type, this.args);
  dynamic arg(int i) => i < args.length ? args[i] : null;
}

class UiAction {
  final String message;
  const UiAction(this.message);
}

/// Prompt section describing our component library, in OpenUI's signature style.
const openUiPrompt = '''
Componentes OpenUI disponibles (argumentos posicionales, en este orden):
Stack(children: Component[], direction?: "row" | "column")
Card(children: Component[], title?: string)
TextContent(text: string, size?: "sm" | "md" | "lg" | "xl")
Stat(label: string, value: string, icon?: Icon, caption?: string)
List(items: string[])
Table(columns: string[], rows: string[][])
Image(url_o_camara: string, caption?: string)  // url http, o el entity_id de una cámara ("camera.xxx") para mostrarla en directo
Progress(label: string, value: number)  // 0-100
Button(label: string, action: @ToAssistant)
Icon = "sunny" | "cloudy" | "rain" | "snow" | "night" | "thermostat" | "home" | "light" | "music" | "calendar" | "timer" | "info" | "check" | "warning" | "star" | "place" | "time" | "money" | "sports" | "food" | "car" | "person"
Acción: @ToAssistant("texto") envía ese texto como nueva pregunta al pulsar.''';

// ---------------------------------------------------------------- lexer

enum _T { ident, state, at, str, num, sym, eof }

class _Tok {
  final _T t;
  final String v;
  const _Tok(this.t, this.v);
  @override
  String toString() => '$t:$v';
}

List<_Tok> _lex(String src) {
  final out = <_Tok>[];
  var i = 0;
  bool isId(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);
  while (i < src.length) {
    final c = src[i];
    if (c.trim().isEmpty) {
      i++;
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '"') {
      final b = StringBuffer();
      i++;
      while (i < src.length && src[i] != '"') {
        if (src[i] == '\\' && i + 1 < src.length) {
          i++;
          b.write(switch (src[i]) {
            'n' => '\n',
            't' => '\t',
            _ => src[i],
          });
        } else {
          b.write(src[i]);
        }
        i++;
      }
      i++;
      out.add(_Tok(_T.str, b.toString()));
    } else if (RegExp(r'[0-9]').hasMatch(c)) {
      final s = i;
      while (i < src.length && RegExp(r'[0-9.]').hasMatch(src[i])) {
        i++;
      }
      out.add(_Tok(_T.num, src.substring(s, i)));
    } else if (c == r'$' || c == '@' || isId(c)) {
      final s = c == r'$' || c == '@' ? ++i : i;
      while (i < src.length && isId(src[i])) {
        i++;
      }
      out.add(
        _Tok(
          c == r'$'
              ? _T.state
              : c == '@'
              ? _T.at
              : _T.ident,
          src.substring(s, i),
        ),
      );
    } else {
      final two = i + 1 < src.length ? src.substring(i, i + 2) : '';
      if (const {'==', '!=', '>=', '<=', '&&', '||'}.contains(two)) {
        out.add(_Tok(_T.sym, two));
        i += 2;
      } else {
        out.add(_Tok(_T.sym, c));
        i++;
      }
    }
  }
  return out..add(const _Tok(_T.eof, ''));
}

// ---------------------------------------------------------------- parser (to closures)

typedef _Ev = dynamic Function(_Env);

class _Env {
  final Map<String, _Ev> stmts;
  final _resolving = <String>{};
  final _cache = <String, dynamic>{};
  _Env(this.stmts);

  dynamic ref(String name) {
    if (_cache.containsKey(name)) return _cache[name];
    final e = stmts[name];
    if (e == null || !_resolving.add(name))
      return null; // undefined (still streaming) or cycle
    final v = e(this);
    _resolving.remove(name);
    return _cache[name] = v;
  }
}

class _Parser {
  final List<_Tok> t;
  int p = 0;
  _Parser(this.t);

  _Tok get cur => t[p];
  bool sym(String s) {
    if (cur.t == _T.sym && cur.v == s) {
      p++;
      return true;
    }
    return false;
  }

  void expect(String s) {
    if (!sym(s)) throw FormatException('expected $s at $cur');
  }

  /// `name = expr` statements; a broken one is skipped up to the next `ident =`.
  Map<String, _Ev> program() {
    final out = <String, _Ev>{};
    while (cur.t != _T.eof) {
      final start = p;
      try {
        if ((cur.t == _T.ident || cur.t == _T.state) &&
            t[p + 1].t == _T.sym &&
            t[p + 1].v == '=') {
          final name = cur.v;
          p += 2;
          out[name] = expr(); // last definition wins
          continue;
        }
        throw const FormatException('not a statement');
      } catch (_) {
        p = start + 1;
        while (cur.t != _T.eof &&
            !((cur.t == _T.ident || cur.t == _T.state) &&
                t[p + 1].t == _T.sym &&
                t[p + 1].v == '=')) {
          p++;
        }
      }
    }
    return out;
  }

  _Ev expr() {
    final c = or();
    if (sym('?')) {
      final a = expr();
      expect(':');
      final b = expr();
      return (e) => _truthy(c(e)) ? a(e) : b(e);
    }
    return c;
  }

  _Ev _bin(_Ev Function() next, List<String> ops) {
    var l = next();
    while (cur.t == _T.sym && ops.contains(cur.v)) {
      final op = cur.v;
      p++;
      final a = l, b = next();
      l = (e) => _op(op, a(e), b(e));
    }
    return l;
  }

  _Ev or() => _bin(and, ['||']);
  _Ev and() => _bin(eq, ['&&']);
  _Ev eq() => _bin(cmp, ['==', '!=']);
  _Ev cmp() => _bin(add, ['>', '<', '>=', '<=']);
  _Ev add() => _bin(mul, ['+', '-']);
  _Ev mul() => _bin(unary, ['*', '/', '%']);

  _Ev unary() {
    if (sym('!')) {
      final a = unary();
      return (e) => !_truthy(a(e));
    }
    if (sym('-')) {
      final a = unary();
      return (e) => a(e) is num ? -(a(e) as num) : null;
    }
    return postfix();
  }

  _Ev postfix() {
    var v = primary();
    while (sym('.')) {
      final key = cur.v;
      p++;
      final base = v;
      v = (e) => _member(base(e), key);
    }
    return v;
  }

  List<_Ev> _args(String close) {
    final out = <_Ev>[];
    while (!sym(close)) {
      out.add(expr());
      if (!sym(',')) {
        expect(close);
        break;
      }
    }
    return out;
  }

  _Ev primary() {
    final k = cur;
    p++;
    switch (k.t) {
      case _T.str:
        return (_) => k.v;
      case _T.num:
        final n = num.tryParse(k.v);
        return (_) => n;
      case _T.state:
        return (e) => e.ref(r'$' + k.v);
      case _T.at:
        expect('(');
        final a = _args(')');
        return (e) => _call(k.v, [for (final x in a) x(e)]);
      case _T.ident:
        if (k.v == 'true') return (_) => true;
        if (k.v == 'false') return (_) => false;
        if (k.v == 'null') return (_) => null;
        if (sym('(')) {
          final a = _args(')');
          if (k.v == 'Action')
            return (e) => _flatten([for (final x in a) x(e)]);
          return (e) => UiNode(k.v, [for (final x in a) x(e)]);
        }
        return (e) => e.ref(k.v);
      case _T.sym when k.v == '[':
        final a = _args(']');
        return (e) => [for (final x in a) x(e)];
      case _T.sym when k.v == '{':
        final entries = <(String, _Ev)>[];
        while (!sym('}')) {
          final key = cur.v;
          p++;
          expect(':');
          entries.add((key, expr()));
          if (!sym(',')) {
            expect('}');
            break;
          }
        }
        return (e) => {for (final (k, v) in entries) k: v(e)};
      case _T.sym when k.v == '(':
        final v = expr();
        expect(')');
        return v;
      default:
        throw FormatException('unexpected $k');
    }
  }
}

bool _truthy(dynamic v) => v != null && v != false && v != 0 && v != '';

dynamic _op(String op, dynamic a, dynamic b) {
  switch (op) {
    case '+':
      if (a is num && b is num) return a + b;
      return '${a ?? ''}${b ?? ''}';
    case '&&':
      return _truthy(a) ? b : a;
    case '||':
      return _truthy(a) ? a : b;
    case '==':
      return a == b;
    case '!=':
      return a != b;
  }
  if (a is! num || b is! num) return null;
  return switch (op) {
    '-' => a - b,
    '*' => a * b,
    '/' => b == 0 ? null : a / b,
    '%' => b == 0 ? null : a % b,
    '>' => a > b,
    '<' => a < b,
    '>=' => a >= b,
    '<=' => a <= b,
    _ => null,
  };
}

dynamic _member(dynamic base, String key) => switch (base) {
  Map m => m[key],
  List l => [for (final x in l) _member(x, key)], // column pluck
  _ => null,
};

dynamic _flatten(List<dynamic> xs) => xs.whereType<UiAction>().firstOrNull;

dynamic _call(String name, List<dynamic> a) {
  List<num> nums() => (a.firstOrNull is List
      ? (a.first as List).whereType<num>().toList()
      : <num>[]);
  return switch (name) {
    'ToAssistant' => a.firstOrNull is String ? UiAction(a.first) : null,
    'Count' => a.firstOrNull is List ? (a.first as List).length : null,
    'Sum' => nums().fold<num>(0, (s, x) => s + x),
    'Max' => nums().isEmpty ? null : nums().reduce((x, y) => x > y ? x : y),
    'Min' => nums().isEmpty ? null : nums().reduce((x, y) => x < y ? x : y),
    'Round' =>
      a.firstOrNull is num
          ? num.parse(
              (a.first as num).toStringAsFixed(
                a.length > 1 && a[1] is int ? a[1] : 0,
              ),
            )
          : null,
    _ => null, // unknown-function: call is null, statement kept
  };
}

/// Parses an OpenUI Lang program and returns the entry component (or null).
UiNode? parseOpenUi(String src) {
  final stmts = _Parser(_lex(src)).program();
  if (stmts.isEmpty) return null;
  final env = _Env(stmts);
  final root = stmts.containsKey('root') ? env.ref('root') : null;
  if (root is UiNode) return root;
  // no-root fallback: first statement that yields a component
  for (final name in stmts.keys) {
    final v = env.ref(name);
    if (v is UiNode) return v;
  }
  return null;
}

/// Splits an assistant reply into the spoken part and an optional ```openui block.
(String speech, UiNode? ui) splitReply(String reply) {
  final m = RegExp(r'```(?:openui)?\s*\n([\s\S]*?)(?:```|$)').firstMatch(reply);
  if (m == null) return (reply.trim(), null);
  final speech = reply.replaceRange(m.start, m.end, '').trim();
  UiNode? ui;
  try {
    ui = parseOpenUi(m[1]!);
  } catch (_) {}
  return (speech, ui);
}

// ---------------------------------------------------------------- renderer

const _icons = <String, IconData>{
  'sunny': Icons.wb_sunny,
  'cloudy': Icons.cloud,
  'rain': Icons.umbrella,
  'snow': Icons.ac_unit,
  'night': Icons.nightlight_round,
  'thermostat': Icons.thermostat,
  'home': Icons.home,
  'light': Icons.lightbulb,
  'music': Icons.music_note,
  'calendar': Icons.event,
  'timer': Icons.timer,
  'info': Icons.info_outline,
  'check': Icons.check_circle,
  'warning': Icons.warning_amber,
  'star': Icons.star,
  'place': Icons.place,
  'time': Icons.schedule,
  'money': Icons.euro,
  'sports': Icons.sports_soccer,
  'food': Icons.restaurant,
  'car': Icons.directions_car,
  'person': Icons.person,
};

String _s(dynamic v) => v == null
    ? ''
    : (v is double && v == v.roundToDouble() ? v.toInt().toString() : '$v');

class OpenUiView extends StatelessWidget {
  final UiNode node;
  final ValueChanged<String> onAssistant;
  final HA ha;
  const OpenUiView({
    super.key,
    required this.node,
    required this.onAssistant,
    required this.ha,
  });

  @override
  Widget build(BuildContext context) => _build(node) ?? const SizedBox();

  List<Widget> _children(dynamic v) => [
    for (final c in (v is List ? v : [v]))
      if (c is UiNode) ?_build(c),
  ];

  Widget? _build(UiNode n) {
    switch (n.type) {
      case 'Stack' || 'Root':
        final kids = _children(n.arg(0));
        if (n.arg(1) == 'row') {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, k) in kids.indexed) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: k),
              ],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, k) in kids.indexed) ...[
              if (i > 0) const SizedBox(height: 12),
              k,
            ],
          ],
        );
      case 'Card':
        return Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (n.arg(1) is String) ...[
                Text(n.arg(1), style: gs(18, weight: FontWeight.w500)),
                const SizedBox(height: 10),
              ],
              for (final (i, k) in _children(n.arg(0)).indexed) ...[
                if (i > 0) const SizedBox(height: 10),
                k,
              ],
            ],
          ),
        );
      case 'TextContent':
        final size = switch (n.arg(1)) {
          'sm' => 14.0,
          'lg' => 22.0,
          'xl' => 30.0,
          _ => 17.0,
        };
        return Text(
          _s(n.arg(0)),
          style: gs(
            size,
            weight: size >= 22 ? FontWeight.w500 : FontWeight.w400,
            color: size < 15 ? muted : onSurface,
          ),
        );
      case 'Stat':
        return Row(
          children: [
            if (_icons[n.arg(2)] case final icon?) ...[
              CircleAvatar(
                radius: 22,
                backgroundColor: surfaceHigh,
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(n.arg(0)), style: gs(14, color: muted)),
                  Text(_s(n.arg(1)), style: gsd(30, height: 1.1)),
                  if (n.arg(3) != null)
                    Text(_s(n.arg(3)), style: gs(13, color: muted)),
                ],
              ),
            ),
          ],
        );
      case 'List':
        final items = n.arg(0) is List ? n.arg(0) as List : const [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final it in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 8, right: 10),
                      child: CircleAvatar(radius: 3, backgroundColor: accent),
                    ),
                    Expanded(child: Text(_s(it), style: gs(17))),
                  ],
                ),
              ),
          ],
        );
      case 'Table':
        final cols = n.arg(0) is List
            ? (n.arg(0) as List).map(_s).toList()
            : <String>[];
        final rows = n.arg(1) is List
            ? (n.arg(1) as List).whereType<List>().toList()
            : <List>[];
        if (cols.isEmpty) return null;
        return Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: surfaceHigh)),
              ),
              children: [
                for (final c in cols)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      c,
                      style: gs(14, color: muted, weight: FontWeight.w500),
                    ),
                  ),
              ],
            ),
            for (final r in rows)
              TableRow(
                children: [
                  for (var i = 0; i < cols.length; i++)
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(i < r.length ? _s(r[i]) : '', style: gs(16)),
                    ),
                ],
              ),
          ],
        );
      case 'Image':
        if (n.arg(0) is! String) return null;
        // A camera entity_id shows the live camera instead of a static image.
        if ((n.arg(0) as String).startsWith('camera.')) {
          final id = n.arg(0) as String;
          return SizedBox(
            height: 220,
            child: CameraCard(
              ha: ha,
              entity: id,
              name: n.arg(1) is String
                  ? n.arg(1)
                  : (ha[id]?['attributes']?['friendly_name'] as String? ?? id),
              active: true,
              icon: Icons.videocam,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image(
                image: ResizeImage(NetworkImage(n.arg(0)), width: 600),
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(),
              ),
            ),
            if (n.arg(1) != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_s(n.arg(1)), style: gs(13, color: muted)),
              ),
          ],
        );
      case 'Progress':
        final v = n.arg(1) is num
            ? ((n.arg(1) as num) / 100).clamp(0.0, 1.0).toDouble()
            : 0.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(_s(n.arg(0)), style: gs(15))),
                Text('${(v * 100).round()} %', style: gs(15, color: muted)),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: v,
              minHeight: 6,
              color: accent,
              backgroundColor: surfaceHigh,
              borderRadius: BorderRadius.circular(3),
            ),
          ],
        );
      case 'Button':
        final action = n.arg(1);
        return Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: surfaceHigh,
              foregroundColor: accent,
              shape: const StadiumBorder(),
            ),
            onPressed: action is UiAction
                ? () => onAssistant(action.message)
                : null,
            child: Text(_s(n.arg(0)), style: gs(15, color: accent)),
          ),
        );
      default:
        return null; // unknown-component: dropped
    }
  }
}
