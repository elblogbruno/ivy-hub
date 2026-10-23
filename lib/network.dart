import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'ui.dart';

/// Wi-Fi and network info: pick/type a network with the on-screen keyboard,
/// see the IP and whether ADB over Wi-Fi is on. Native side: wifi* in MainActivity.kt.
class NetworkPage extends StatefulWidget {
  /// Keeps the Shell's idle timer from closing the page while typing
  /// (IME key presses aren't Flutter pointer events).
  final VoidCallback onTouch;
  const NetworkPage({super.key, required this.onTouch});
  @override
  State<NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<NetworkPage> {
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  Map? _info;
  List<Map> _nets = [];
  String? _ips, _adb, _msg;
  bool _busy = false, _hide = true, _adbOn = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh(scan: true);
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool scan = false}) async {
    final info = await native.invokeMethod<Map>('wifiInfo');
    final nets = await native.invokeListMethod<Map>('wifiScan', scan) ?? [];
    final adbOn = await native.invokeMethod<bool>('adbWifi') ?? true;
    final ips = [
      for (final i in await NetworkInterface.list())
        for (final a in i.addresses) '${i.name}  ${a.address}',
    ].join('\n');
    String? adb;
    for (final p in ['service.adb.tcp.port', 'persist.adb.tcp.port']) {
      final v = (await Process.run('getprop', [p])).stdout.toString().trim();
      if (v.isNotEmpty && v != '-1' && v != '0') adb = v;
    }
    if (mounted) {
      setState(() {
        _info = info;
        _nets = nets;
        _ips = ips;
        _adb = adb;
        _adbOn = adbOn;
      });
    }
  }

  Future<void> _connect() async {
    final ssid = _ssid.text.trim();
    if (ssid.isEmpty) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    final err = await native.invokeMethod<String>('wifiConnect', {
      'ssid': ssid,
      'password': _pass.text,
    });
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = false;
      _msg = err ?? 'Conectando a $ssid…';
    });
  }

  Widget _row(String k, String? v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 130, child: Text(k, style: gs(16, color: muted))),
        Expanded(child: Text(v ?? '—', style: gs(16))),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final i = _info;
    final field = InputDecoration(
      filled: true,
      fillColor: surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    );
    return Listener(
      onPointerDown: (_) => widget.onTouch(),
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          title: Text('Red', style: gs(22)),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _refresh(scan: true),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
          children: [
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('Wi-Fi', i?['ssid'] as String?),
                  _row('Señal', i == null ? null : '${i['rssi']} dBm'),
                  _row('IP', i?['ip'] as String?),
                  _row('Puerta enlace', i?['gateway'] as String?),
                  _row('DNS', i?['dns'] as String?),
                  _row('MAC', i?['mac'] as String?),
                  _row('Interfaces', _ips),
                  Row(
                    children: [
                      Expanded(
                        child: _row(
                          'ADB Wi-Fi',
                          _adb == null
                              ? 'adbd sin puerto TCP'
                              : _adbOn
                              ? 'Activo · adb connect ${i?['ip'] ?? '<ip>'}:$_adb'
                              : 'Bloqueado (USB sigue activo)',
                        ),
                      ),
                      Switch(
                        value: _adbOn,
                        onChanged: _adb == null || _busy
                            ? null
                            : (v) async {
                                setState(() => _busy = true);
                                final on = await native.invokeMethod<bool>('adbWifi', v);
                                if (mounted) {
                                  setState(() {
                                    _busy = false;
                                    _adbOn = on ?? _adbOn;
                                  });
                                }
                              },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Conectar a una red', style: gs(18, weight: FontWeight.w500)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ssid,
                    onChanged: (_) => widget.onTouch(),
                    style: gs(18),
                    decoration: field.copyWith(labelText: 'Nombre (SSID)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: _hide,
                    onChanged: (_) => widget.onTouch(),
                    onSubmitted: (_) => _connect(),
                    style: gs(18),
                    decoration: field.copyWith(
                      labelText: 'Contraseña (vacía = red abierta)',
                      suffixIcon: IconButton(
                        icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Conectar', style: gs(18, color: bg)),
                    ),
                  ),
                  if (_msg != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(_msg!, style: gs(16, color: muted)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            for (final n in _nets)
              ListTile(
                leading: Icon(
                  n['secure'] == true ? Icons.wifi_lock : Icons.wifi,
                  color: accent,
                ),
                title: Text(n['ssid'] as String, style: gs(17)),
                trailing: Text('${n['level']} dBm', style: gs(15, color: muted)),
                onTap: () => setState(() {
                  _ssid.text = n['ssid'] as String;
                  _pass.clear();
                }),
              ),
          ],
        ),
      ),
    );
  }
}
