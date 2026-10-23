import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

// Build with --dart-define-from-file=secrets.json (see secrets.example.json).
const haHost = String.fromEnvironment('HA_HOST', defaultValue: 'homeassistant.local:8123');
const haBase = 'https://$haHost';
const haToken = String.fromEnvironment('HA_TOKEN');

/// Android 8.1 lacks the newer Let's Encrypt roots; trust only our HA host.
class HaHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (cert, host, port) =>
            host == haHost.split(':').first;
}

class Room {
  final String id, name;
  final List<String> entities;
  Room(this.id, this.name, this.entities);
}

const roomDomains = {'light', 'switch', 'cover', 'climate', 'fan', 'lock'};

/// HA dashboard (storage mode) that configures the app: each view is a tab.
/// Paths inicio/casa/multimedia/reloj keep their native pages; any other
/// path is drawn generically from its entities. tools/setup_ivy_dashboard.py seeds it.
const ivyDashboard = 'ivy-app';

typedef Item = ({String id, String? name, String? icon});

class IvyView {
  final String path, title;
  final List<Item> items;
  const IvyView(this.path, this.title, [this.items = const []]);

  Iterable<Item> domain(String d) => items.where((i) => i.id.startsWith('$d.'));
}

/// Used until the dashboard loads (or if it does not exist).
const defaultViews = [
  IvyView('inicio', 'Inicio'),
  IvyView('casa', 'Casa'),
  IvyView('multimedia', 'Multimedia'),
  IvyView('reloj', 'Reloj'),
];

/// Every entity referenced anywhere in a view, in order: cards, stacks,
/// sections, `entities:` lists (strings or maps), picture cards' camera_image.
List<Item> viewItems(Object? node) {
  final out = <Item>[];
  final seen = <String>{};
  void add(Object? id, Map? m) {
    if (id is String && id.contains('.') && seen.add(id)) {
      final name = m?['name'], icon = m?['icon'];
      out.add((
        id: id,
        name: name is String ? name : null,
        icon: icon is String ? icon : null,
      ));
    }
  }

  void walk(Object? n) {
    if (n is Map) {
      add(n['entity'], n);
      add(n['camera_image'], n);
      n.values.forEach(walk);
    } else if (n is List) {
      for (final e in n) {
        e is String ? add(e, null) : walk(e);
      }
    }
  }

  walk(node);
  return out;
}

List<IvyView> parseViews(Map cfg) => [
  for (final (i, v) in (cfg['views'] as List? ?? []).indexed)
    if (v is Map)
      IvyView(
        '${v['path'] ?? i}',
        '${v['title'] ?? v['path'] ?? 'Vista ${i + 1}'}',
        viewItems(v),
      ),
];

/// Minimal Home Assistant WebSocket client with auto-reconnect.
class HA extends ChangeNotifier {
  /// Entities the UI shows; only these are streamed from HA.
  final Set<String> watch;
  HA(this.watch);

  WebSocket? _ws;
  int _id = 0;
  final _pending = <int, Completer<dynamic>>{};
  final _subs = <int, void Function(Map<String, dynamic>)>{};
  final states = <String, Map<String, dynamic>>{};
  bool connected = false;

  /// Filled from HA's area/device/entity registries on every connect.
  List<Room> rooms = [];
  List<String> mediaPlayers = [];
  List<String> cameras = [];

  /// Tabs from the [ivyDashboard] dashboard; reloaded live when it is saved.
  final views = ValueNotifier<List<IvyView>>(defaultViews);
  IvyView? view(String path) =>
      views.value.where((v) => v.path == path).firstOrNull;

  /// HA's own Spanish names for states and attribute values.
  var _tr = <String, String>{};
  final _trKeys =
      <String, (String, String)>{}; // id -> (platform, translation_key)

  /// e.g. vac_and_mop -> "Aspirar y fregar"; [attr] for attribute values
  /// such as a vacuum's fan_speed. Null if HA has no translation.
  String? stateName(String id, String value, [String? attr]) {
    final domain = id.split('.').first;
    final k = _trKeys[id];
    final dc = this[id]?['attributes']?['device_class'];
    final tail = attr == null
        ? 'state.$value'
        : 'state_attributes.$attr.state.$value';
    return (k == null
            ? null
            : _tr['component.${k.$1}.entity.$domain.${k.$2}.$tail']) ??
        (dc == null
            ? null
            : _tr['component.$domain.entity_component.$dc.$tail']) ??
        _tr['component.$domain.entity_component._.$tail'];
  }

  Future<void> _loadTranslations() async {
    try {
      final tr = <String, String>{};
      for (final cat in ['entity', 'entity_component']) {
        final r = await call({
          'type': 'frontend/get_translations',
          'language': 'es',
          'category': cat,
        });
        tr.addAll(Map<String, String>.from(r['resources']));
      }
      _tr = tr;
    } catch (e) {
      debugPrint('HA: translations: $e');
    }
  }

  Map<String, dynamic>? operator [](String entityId) => states[entityId];

  Future<void> run() async {
    while (true) {
      try {
        await _session();
      } catch (e) {
        debugPrint('HA: $e');
      }
      connected = false;
      notifyListeners();
      for (final c in _pending.values) {
        c.completeError('disconnected');
      }
      _pending.clear();
      _subs.clear();
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _session() async {
    final ws = await WebSocket.connect(
      'wss://$haHost/api/websocket',
    ).timeout(const Duration(seconds: 15));
    ws.pingInterval = const Duration(seconds: 20);
    _ws = ws;
    await ws.forEach((raw) => _onMessage(jsonDecode(raw as String)));
  }

  void _onMessage(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'auth_required':
        _ws!.add(jsonEncode({'type': 'auth', 'access_token': haToken}));
      case 'auth_ok':
        _bootstrap().catchError((e) => debugPrint('HA bootstrap: $e'));
      case 'auth_invalid':
        debugPrint('HA: auth_invalid ${m['message']}');
        _ws!.close();
      case 'result':
        final c = _pending.remove(m['id']);
        if (c == null) return;
        m['success'] == true
            ? c.complete(m['result'])
            : c.completeError(m['error'] ?? 'error');
      case 'event':
        _subs[m['id']]?.call(Map<String, dynamic>.from(m['event']));
    }
  }

  /// subscribe_entities filters server-side and sends compact diffs:
  /// a = full adds, c = changes ({'+': set, '-': removed attrs}), r = removed ids.
  Future<void> _bootstrap() async {
    await _loadRegistry();
    await _loadTranslations();
    await _loadViews();
    await subscribe(
      {'type': 'subscribe_events', 'event_type': 'lovelace_updated'},
      (ev) async {
        if (ev['data']?['url_path'] != ivyDashboard) return;
        final before = watch.length;
        await _loadViews();
        // subscribe_entities has a fixed list: reconnect to stream new entities.
        if (watch.length > before) _ws?.close();
      },
    );
    await subscribe(
      {'type': 'subscribe_entities', 'entity_ids': watch.toList()},
      (ev) {
        applyEntities(ev);
        connected = true;
        notifyListeners();
      },
    );
  }

  Future<void> _loadViews() async {
    try {
      final cfg = await call({
        'type': 'lovelace/config',
        'url_path': ivyDashboard,
      });
      final v = parseViews(cfg as Map);
      if (v.isEmpty) return;
      watch.addAll(v.expand((v) => v.items.map((i) => i.id)));
      views.value = v;
    } catch (e) {
      debugPrint('HA: dashboard $ivyDashboard: $e');
    }
  }

  Future<void> _loadRegistry() async {
    final areas = await call({'type': 'config/area_registry/list'}) as List;
    final devices = await call({'type': 'config/device_registry/list'}) as List;
    final entities =
        await call({'type': 'config/entity_registry/list'}) as List;
    final devArea = {for (final d in devices) d['id']: d['area_id']};
    final byArea = <String, List<String>>{};
    final players = <String>[], cams = <String>[];
    for (final e in entities) {
      final id = e['entity_id'] as String;
      final domain = id.split('.').first;
      if (e['translation_key'] is String) {
        _trKeys[id] = (e['platform'] as String, e['translation_key'] as String);
      }
      if (e['disabled_by'] != null ||
          e['hidden_by'] != null ||
          e['entity_category'] != null)
        continue;
      if (domain == 'media_player') players.add(id);
      if (domain == 'camera') cams.add(id);
      if (!roomDomains.contains(domain)) continue;
      final area = e['area_id'] ?? devArea[e['device_id']];
      if (area != null) byArea.putIfAbsent(area, () => []).add(id);
    }
    rooms = [
      for (final a in areas)
        if (byArea[a['area_id']] case final ids?)
          Room(a['area_id'], a['name'], ids..sort()),
    ];
    mediaPlayers = players;
    cameras = cams..sort();
    watch
      ..addAll(byArea.values.expand((e) => e))
      ..addAll(players)
      ..addAll(cams);
  }

  /// Authenticated GET against HA's REST API (used for calendars).
  Future<dynamic> rest(String path) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$haBase$path'));
      req.headers.set('Authorization', 'Bearer $haToken');
      final res = await req.close();
      return jsonDecode(await utf8.decodeStream(res));
    } finally {
      client.close();
    }
  }

  /// Authenticated JSON POST against HA's REST API (e.g. `/api/states/<id>`).
  /// Returns the decoded response body (null if empty); callers may ignore it.
  Future<dynamic> restPost(String path, Map<String, dynamic> body) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$haBase$path'));
      req.headers
        ..set('Authorization', 'Bearer $haToken')
        ..contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      client.close();
    }
  }

  /// Calls a service that returns data (e.g. weather.get_forecasts).
  Future<dynamic> serviceResponse(
    String domain,
    String service,
    String entityId,
    Map<String, dynamic> data,
  ) async {
    final r = await call({
      'type': 'call_service',
      'domain': domain,
      'service': service,
      'service_data': data,
      'target': {'entity_id': entityId},
      'return_response': true,
    });
    return r['response'][entityId];
  }

  void applyEntities(Map<String, dynamic> ev) {
    (ev['a'] as Map?)?.forEach((id, s) {
      states[id] = {
        'state': s['s'],
        'attributes': Map<String, dynamic>.from(s['a'] ?? {}),
      };
    });
    (ev['c'] as Map?)?.forEach((id, diff) {
      final cur = states[id];
      if (cur == null) return;
      final attrs = cur['attributes'] as Map<String, dynamic>;
      final plus = diff['+'];
      if (plus?['s'] != null) cur['state'] = plus['s'];
      if (plus?['a'] != null)
        attrs.addAll(Map<String, dynamic>.from(plus['a']));
      for (final k in (diff['-']?['a'] as List? ?? [])) {
        attrs.remove(k);
      }
    });
    (ev['r'] as List?)?.forEach(states.remove);
  }

  Future<dynamic> call(Map<String, dynamic> msg) {
    final ws = _ws;
    if (ws == null) return Future.error('not connected');
    final id = ++_id;
    final c = Completer<dynamic>();
    _pending[id] = c;
    ws.add(jsonEncode({...msg, 'id': id}));
    return c.future;
  }

  /// Registers the handler before sending, so early events are not lost.
  Future<int> subscribe(
    Map<String, dynamic> msg,
    void Function(Map<String, dynamic>) onEvent,
  ) async {
    final id = _id + 1;
    _subs[id] = onEvent;
    await call(msg);
    return id;
  }

  /// Raw binary frame (Assist pipeline audio: [handler id, ...pcm]).
  void sendBinary(List<int> data) => _ws?.add(data);

  void unsubscribe(int id) {
    if (_subs.remove(id) != null) {
      call({
        'type': 'unsubscribe_events',
        'subscription': id,
      }).catchError((_) {});
    }
  }

  Future<dynamic> service(
    String domain,
    String service,
    Map<String, dynamic> data,
  ) => call({
    'type': 'call_service',
    'domain': domain,
    'service': service,
    'service_data': data,
  });
}
