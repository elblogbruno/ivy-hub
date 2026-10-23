import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'main.dart' show cameraToken;
import 'ui.dart';

enum CallState { idle, calling, ringing, active }

/// Screen-to-screen call. Audio is a native LAN link (CallAudio.kt); video is the
/// peer's MJPEG, polled as JPEG snapshots on :2971. Signalling piggybacks on the
/// :2971 "call" command: each side POSTs ring/accept/end to the other.
class Call extends ChangeNotifier {
  final VoidCallback onStart, onStop; // pause/resume the voice assistant
  Call({required this.onStart, required this.onStop});

  CallState state = CallState.idle;
  String? peerIp, peerName;
  bool muted = false;
  String myName = 'Ivy';

  Future<void> init() async {
    myName =
        (await native.invokeMethod<String>('deviceName'))?.trim().isNotEmpty ==
            true
        ? (await native.invokeMethod<String>('deviceName'))!.trim()
        : 'Ivy';
  }

  String get peerSnapshot =>
      'http://$peerIp:2971/api/camera.jpg?token=$cameraToken';

  static Future<String?> localIp() async {
    try {
      for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final a in ni.addresses) {
          if (a.address.startsWith('192.168.')) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _post(String ip, Map body) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://$ip:2971/api/command'),
      );
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
      await req.close().timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('Call post: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// Start an outgoing call to [ip] (that screen's name is [name]).
  Future<void> invite(String ip, String name) async {
    if (state != CallState.idle) return;
    peerIp = ip;
    peerName = name;
    muted = false;
    state = CallState.calling;
    notifyListeners();
    final me = await localIp();
    await _post(ip, {
      'call': {'action': 'ring', 'from_ip': me, 'from_name': myName},
    });
  }

  void onRing(String fromIp, String fromName) {
    if (state != CallState.idle) {
      _post(fromIp, {
        'call': {'action': 'end'},
      }); // busy
      return;
    }
    peerIp = fromIp;
    peerName = fromName;
    state = CallState.ringing;
    notifyListeners();
  }

  Future<void> accept() async {
    if (state != CallState.ringing || peerIp == null) return;
    muted = false;
    state = CallState.active;
    notifyListeners();
    onStart();
    native.invokeMethod('callStart', peerIp);
    final me = await localIp();
    await _post(peerIp!, {
      'call': {'action': 'accept', 'from_ip': me},
    });
  }

  void onAccept() {
    if (state != CallState.calling || peerIp == null) return;
    state = CallState.active;
    notifyListeners();
    onStart();
    native.invokeMethod('callStart', peerIp);
  }

  /// Hang up (or reject a ring) and tell the peer.
  Future<void> end() async {
    if (peerIp != null) {
      await _post(peerIp!, {
        'call': {'action': 'end'},
      });
    }
    _hangup();
  }

  void onEnd() => _hangup();

  void _hangup() {
    if (state == CallState.active) {
      native.invokeMethod('callStop');
      onStop();
    }
    state = CallState.idle;
    peerIp = peerName = null;
    muted = false;
    notifyListeners();
  }

  void toggleMute() {
    muted = !muted;
    native.invokeMethod('callMute', muted);
    notifyListeners();
  }
}

// ------------------------------------------------------------------ overlay

class CallOverlay extends StatelessWidget {
  final Call call;
  const CallOverlay({super.key, required this.call});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: call,
      builder: (context, _) {
        final s = call.state;
        return Positioned.fill(
          child: IgnorePointer(
            ignoring: s == CallState.idle,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: s == CallState.idle
                  ? const SizedBox.shrink()
                  : SizedBox.expand(
                      key: ValueKey(s),
                      child: s == CallState.active
                          ? _ActiveCall(call: call)
                          : _RingCall(call: call),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// Ringing (incoming) or calling (outgoing): name + accept/reject.
class _RingCall extends StatelessWidget {
  final Call call;
  const _RingCall({required this.call});

  @override
  Widget build(BuildContext context) {
    final incoming = call.state == CallState.ringing;
    return ColoredBox(
      color: const Color(0xF2101114),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam, color: Colors.white, size: 54),
            const SizedBox(height: 16),
            Text(
              call.peerName ?? 'Ivy',
              style: gs(30, color: Colors.white, weight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            Text(
              incoming ? 'Te está llamando' : 'Llamando…',
              style: gs(18, color: muted),
            ),
            const SizedBox(height: 34),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (incoming)
                  _CallBtn(
                    icon: Icons.call,
                    color: const Color(0xFF2E7D32),
                    label: 'Aceptar',
                    onTap: call.accept,
                  ),
                if (incoming) const SizedBox(width: 28),
                _CallBtn(
                  icon: Icons.call_end,
                  color: const Color(0xFFC62828),
                  label: incoming ? 'Rechazar' : 'Cancelar',
                  onTap: call.end,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Active call: the peer's camera (polled JPEG) full screen, with mute + hang up.
class _ActiveCall extends StatefulWidget {
  final Call call;
  const _ActiveCall({required this.call});
  @override
  State<_ActiveCall> createState() => _ActiveCallState();
}

class _ActiveCallState extends State<_ActiveCall> {
  Timer? _t;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (mounted) setState(() => _tick++);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.call;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            '${c.peerSnapshot}&_=$_tick',
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => Center(
              child: Text(
                'Conectando con ${c.peerName ?? ''}…',
                style: gs(18, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            top: 18,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0x99000000),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                c.peerName ?? 'Ivy',
                style: gs(16, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallBtn(
                  icon: c.muted ? Icons.mic_off : Icons.mic,
                  color: c.muted ? const Color(0xFF616161) : const Color(0xFF37474F),
                  label: c.muted ? 'Silenciado' : 'Micro',
                  onTap: c.toggleMute,
                ),
                const SizedBox(width: 28),
                _CallBtn(
                  icon: Icons.call_end,
                  color: const Color(0xFFC62828),
                  label: 'Colgar',
                  onTap: c.end,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CallBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  const _CallBtn({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: gs(14, color: Colors.white)),
      ],
    );
  }
}
