import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'ha.dart';
import 'ui.dart';

/// Live camera. Cameras with the STREAM feature (Nest) play HA's HLS stream;
/// MJPEG cameras without it (Moonraker printer, camera.ivy) can't be
/// transcoded to HLS without going black, so they poll the snapshot endpoint
/// ~2 fps the way the HA frontend renders them. Runs only while [active], muted.
class CameraCard extends StatefulWidget {
  final HA ha;
  final String entity, name;
  final bool active;
  final BoxFit fit;
  final IconData icon;
  const CameraCard({
    super.key,
    required this.ha,
    required this.entity,
    required this.name,
    required this.active,
    this.fit = BoxFit.cover,
    this.icon = Icons.doorbell,
  });
  @override
  State<CameraCard> createState() => _CameraCardState();
}

class _CameraCardState extends State<CameraCard> {
  VideoPlayerController? _vc;
  bool _starting = false;
  String? _error;
  Timer? _poll;
  int _tick = 0;
  bool _loaded = false;

  /// MJPEG (snapshot-polled) when the camera lacks HA's STREAM feature (bit 2).
  bool get _mjpeg =>
      (((widget.ha[widget.entity]?['attributes']?['supported_features'] as int?) ??
                  0) &
              2) ==
      0;

  bool get _live => _mjpeg ? _loaded : (_vc?.value.isPlaying ?? false);

  String? _snapshotUrl() {
    final tok = widget.ha[widget.entity]?['attributes']?['access_token'];
    if (tok == null) return null;
    return '$haBase/api/camera_proxy/${widget.entity}?token=$tok&_=$_tick';
  }

  @override
  void initState() {
    super.initState();
    widget.ha.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(CameraCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    final want = widget.active && widget.ha.connected;
    if (_mjpeg) {
      if (want && _poll == null) {
        _poll = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => mounted ? setState(() => _tick++) : null,
        );
      } else if (!want && _poll != null) {
        _poll!.cancel();
        _poll = null;
        setState(() => _loaded = false);
      }
      return;
    }
    if (want && _vc == null && !_starting) _start();
    if (!want && _vc != null) _stop();
  }

  Future<void> _start() async {
    _starting = true;
    setState(() => _error = null);
    VideoPlayerController? vc;
    try {
      final r = await widget.ha.call({
        'type': 'camera/stream',
        'entity_id': widget.entity,
      });
      vc = VideoPlayerController.networkUrl(
        Uri.parse('$haBase${r['url']}'),
        formatHint: VideoFormat.hls,
      );
      await vc.initialize();
      await vc.setVolume(0);
      if (!mounted || !widget.active) {
        await vc.dispose();
        return;
      }
      vc.addListener(() {
        if (vc!.value.hasError && identical(vc, _vc)) _restart();
        if (mounted) setState(() {});
      });
      await vc.play();
      setState(() => _vc = vc);
    } catch (e) {
      debugPrint('Camera: $e');
      await vc?.dispose();
      if (mounted) setState(() => _error = 'Sin señal');
    } finally {
      _starting = false;
    }
  }

  Future<void> _restart() async {
    await _stop();
    await Future.delayed(const Duration(seconds: 2));
    _sync();
  }

  Future<void> _stop() async {
    final vc = _vc;
    _vc = null;
    await vc?.dispose();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.ha.removeListener(_sync);
    _poll?.cancel();
    _vc?.dispose();
    super.dispose();
  }

  Widget _buildSnapshot() {
    final url = _snapshotUrl();
    if (url == null) return const SizedBox.expand();
    return Image.network(
      url,
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, _) {
        if (frame != null && !_loaded) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _loaded = true);
          });
        }
        return child;
      },
      errorBuilder: (_, _, _) => const SizedBox.expand(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: surface),
          AnimatedOpacity(
            opacity: _live ? 1 : 0,
            duration: const Duration(milliseconds: 400),
            child: _mjpeg
                ? _buildSnapshot()
                : _vc == null
                ? const SizedBox.expand()
                : FittedBox(
                    fit: widget.fit,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: _vc!.value.size.width,
                      height: _vc!.value.size.height,
                      child: VideoPlayer(_vc!),
                    ),
                  ),
          ),
          if (!_live)
            Center(
              child: _error != null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_off, color: muted, size: 40),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: const TextStyle(
                            fontFamily: 'GoogleSans',
                            color: muted,
                          ),
                        ),
                        TextButton(
                          onPressed: _restart,
                          child: const Text('Reintentar'),
                        ),
                      ],
                    )
                  : const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: accent,
                      ),
                    ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(18, 28, 18, 14),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xAA000000), Color(0x00000000)],
                ),
              ),
              child: Row(
                children: [
                  Icon(widget.icon, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    widget.name,
                    style: const TextStyle(
                      fontFamily: 'GoogleSans',
                      fontWeight: FontWeight.w500,
                      fontSize: 17,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  if (_live)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEA4335),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'EN DIRECTO',
                        style: TextStyle(
                          fontFamily: 'GoogleSans',
                          fontWeight: FontWeight.w500,
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
