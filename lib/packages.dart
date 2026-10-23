import 'dart:async';

import 'package:flutter/material.dart';

import 'ambient.dart';
import 'ha.dart';
import 'ui.dart';

/// 17track status (as returned by seventeentrack.get_packages) -> label, icon, colour.
const _status = <String, (String, IconData, Color)>{
  'Ready to be picked up': ('Listo para recoger', Icons.store, good),
  'Alert': ('Alerta', Icons.warning_amber, danger),
  'Undelivered': ('No entregado', Icons.report_gmailerrorred, danger),
  'In Transit': ('En tránsito', Icons.local_shipping, accent),
  'Not Found': ('Sin información', Icons.help_outline, muted),
  'Delivered': ('Entregado', Icons.check_circle, good),
  'Expired': ('Caducado', Icons.history, muted),
};

/// Moving and with news in the last 30 days; "Not Found" numbers and stale
/// parcels go to "Otros" so years-old entries don't count as active.
bool _isActive(Map p) {
  if (!const {
    'Ready to be picked up',
    'Alert',
    'Undelivered',
    'In Transit',
  }.contains(p['status'])) {
    return false;
  }
  final t = DateTime.tryParse(p['timestamp'] as String? ?? '');
  return t == null || DateTime.now().difference(t).inDays <= 30;
}

/// Parcels from the 17track integration: active ones first, then the rest
/// (delivered, expired, no info; dimmed). Long press archives a parcel in 17track.
class PackagesPage extends StatefulWidget {
  final HA ha;
  final bool active;
  const PackagesPage({super.key, required this.ha, required this.active});
  @override
  State<PackagesPage> createState() => _PackagesPageState();
}

class _PackagesPageState extends State<PackagesPage> {
  List<Map<String, dynamic>>? _packages;
  String? _entry, _error;
  DateTime? _at;
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.ha.addListener(_maybeLoad);
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (widget.active) _load();
    });
    _maybeLoad();
  }

  @override
  void didUpdateWidget(PackagesPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _maybeLoad();
  }

  @override
  void dispose() {
    widget.ha.removeListener(_maybeLoad);
    _timer?.cancel();
    super.dispose();
  }

  void _maybeLoad() {
    if (!widget.ha.connected || _loading) return;
    if (_at != null &&
        DateTime.now().difference(_at!) < const Duration(minutes: 2)) {
      return;
    }
    _load();
  }

  Future<void> _load() async {
    _loading = true;
    try {
      _entry ??=
          ((await widget.ha.call({
                    'type': 'config_entries/get',
                    'domain': 'seventeentrack',
                  }))
                  as List)
              .first['entry_id'];
      final r = await widget.ha.call({
        'type': 'call_service',
        'domain': 'seventeentrack',
        'service': 'get_packages',
        'service_data': {'config_entry_id': _entry},
        'return_response': true,
      });
      final list = List<Map<String, dynamic>>.from(
        r['response']['packages'] as List,
      );
      int rank(Map p) => _status.keys.toList().indexOf(p['status']);
      DateTime when(Map p) =>
          DateTime.tryParse(p['timestamp'] as String? ?? '') ?? DateTime(0);
      list.sort((a, b) {
        final d = rank(a).compareTo(rank(b));
        return d != 0 ? d : when(b).compareTo(when(a));
      });
      setState(() {
        _packages = list;
        _error = null;
        _at = DateTime.now();
      });
    } catch (e) {
      debugPrint('Packages: $e');
      setState(() => _error = 'No se pudo leer 17track');
    } finally {
      _loading = false;
    }
  }

  Future<void> _archive(Map p) async {
    final name = _name(p);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: surface,
        title: Text('¿Archivar $name?', style: gs(20)),
        content: Text(
          'Dejará de aparecer aquí y en 17track.',
          style: gs(16, color: muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Archivar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.ha.service('seventeentrack', 'archive_package', {
      'config_entry_id': _entry,
      'package_tracking_number': p['tracking_number'],
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _packages;
    if (list == null) {
      return Center(
        child: Text(
          _error ?? 'Cargando paquetes…',
          style: gs(18, color: muted),
        ),
      );
    }
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inventory_2_outlined, color: muted, size: 48),
            const SizedBox(height: 10),
            Text('No hay paquetes en 17track', style: gs(18, color: muted)),
          ],
        ),
      );
    }
    final active = list.where(_isActive).toList();
    final old = list.where((p) => !_isActive(p)).toList();
    final counts = <String, int>{};
    for (final p in active) {
      counts.update(p['status'] as String, (n) => n + 1, ifAbsent: () => 1);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              active.isEmpty
                  ? 'Ningún paquete en camino'
                  : active.length == 1
                  ? '1 paquete activo'
                  : '${active.length} paquetes activos',
              style: gs(20, weight: FontWeight.w500),
            ),
            const Spacer(),
            for (final MapEntry(key: s, value: n) in counts.entries)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: _Chip(status: s, label: '$n ${_status[s]?.$1 ?? s}'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final p in active) _row(p),
              if (old.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 0, 8),
                  child: Text('Otros', style: gs(16, color: muted)),
                ),
                for (final p in old) Opacity(opacity: 0.6, child: _row(p)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(Map p) {
    final s = p['status'] as String? ?? '';
    final (label, icon, color) = _status[s] ?? (s, Icons.inventory_2, muted);
    final at = DateTime.tryParse(p['timestamp'] as String? ?? '')?.toLocal();
    final route = [
      p['origin_country'],
      p['destination_country'],
    ].where((c) => c != null && c != 'Unknown').join(' → ');
    final detail = [
      if ((p['info_text'] as String?)?.isNotEmpty ?? false) p['info_text'],
      if ((p['location'] as String?)?.isNotEmpty ?? false) p['location'],
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onLongPress: () => _archive(p),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: surfaceHigh,
                  ),
                  child: Icon(icon, color: color, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _name(p),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: gs(17, weight: FontWeight.w500),
                      ),
                      if (detail.isNotEmpty)
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: gs(14, color: muted),
                        ),
                      Text(
                        [
                          if (at != null) _ago(at),
                          if (route.isNotEmpty) route,
                          if ((p['friendly_name'] as String?)?.isNotEmpty ??
                              false)
                            p['tracking_number'],
                        ].join(' · '),
                        maxLines: 1,
                        style: gs(13, color: muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _Chip(status: s, label: label),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _name(Map p) {
  final n = p['friendly_name'] as String?;
  return n == null || n.isEmpty ? p['tracking_number'] as String : n;
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t).inDays;
  if (d < 7) return '${dayLabel(t)} · ${hhmm(t)}';
  final date = '${t.day} de ${monthNames[t.month - 1]}';
  return d < 300 ? date : '$date de ${t.year}';
}

/// Status pill: icon + text (never colour alone).
class _Chip extends StatelessWidget {
  final String status, label;
  const _Chip({required this.status, required this.label});
  @override
  Widget build(BuildContext context) {
    final (_, icon, color) = _status[status] ?? ('', Icons.inventory_2, muted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: surfaceHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(label, style: gs(14)),
        ],
      ),
    );
  }
}
