import 'dart:async';

import 'package:flutter/material.dart';

import 'camera.dart';
import 'ha.dart';
import 'rooms.dart';
import 'ui.dart';

/// Security-camera wall: every HA camera (or only those listed in the view),
/// as snapshots refreshed every 5 s; cameras with no snapshot but a stream
/// (the Nest) play live instead. Tap opens one full screen, live.
class CamerasPage extends StatefulWidget {
  final HA ha;
  final IvyView view;
  final bool active;
  const CamerasPage({
    super.key,
    required this.ha,
    required this.view,
    required this.active,
  });
  @override
  State<CamerasPage> createState() => _CamerasPageState();
}

class _CamerasPageState extends State<CamerasPage> {
  bool _full = false;

  Future<void> _open(String id, String name) async {
    setState(() => _full = true);
    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: _FullCamera(ha: widget.ha, entity: id, name: name),
        ),
      ),
    );
    if (mounted) setState(() => _full = false);
  }

  @override
  Widget build(BuildContext context) {
    final ha = widget.ha;
    return ListenableBuilder(
      listenable: ha,
      builder: (context, _) {
        final listed = widget.view.domain('camera').toList();
        final all = listed.isNotEmpty
            ? listed
            : [for (final id in ha.cameras) (id: id, name: null, icon: null)];
        final cams = all
            .where((c) => ha[c.id]?['state'] != 'unavailable')
            .toList();
        final offline = all.length - cams.length;
        if (cams.isEmpty) {
          return Center(
            child: Text(
              ha.connected ? 'No hay cámaras disponibles' : 'Conectando…',
              style: gs(18, color: muted),
            ),
          );
        }
        final cols = cams.length == 1 ? 1 : (cams.length <= 4 ? 2 : 3);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Fit every camera on screen: tile shape follows the free area.
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final rows = (cams.length / cols).ceil();
                  final w = (box.maxWidth - 12 * (cols - 1)) / cols;
                  final h = (box.maxHeight - 12 * (rows - 1)) / rows;
                  return GridView.count(
                    padding: EdgeInsets.zero,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: cols,
                    childAspectRatio: w / h,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    children: [
                      for (final c in cams)
                        _CamTile(
                          ha: ha,
                          entity: c.id,
                          name: c.name ?? friendly(ha, c.id),
                          active: widget.active && !_full,
                          onTap: () =>
                              _open(c.id, c.name ?? friendly(ha, c.id)),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (offline > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  offline == 1
                      ? '1 cámara sin conexión'
                      : '$offline cámaras sin conexión',
                  style: gs(14, color: muted),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CamTile extends StatefulWidget {
  final HA ha;
  final String entity, name;
  final bool active;
  final VoidCallback onTap;
  const _CamTile({
    required this.ha,
    required this.entity,
    required this.name,
    required this.active,
    required this.onTap,
  });
  @override
  State<_CamTile> createState() => _CamTileState();
}

class _CamTileState extends State<_CamTile> {
  Timer? _tick;
  int _n = 0;
  bool _noSnapshot = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (widget.active && !_noSnapshot) setState(() => _n++);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  bool get _streams =>
      ((widget.ha[widget.entity]?['attributes']?['supported_features']
                      as num?) ??
                  0)
              .toInt() &
          2 !=
      0;

  @override
  Widget build(BuildContext context) {
    final pic =
        widget.ha[widget.entity]?['attributes']?['entity_picture'] as String?;
    final Widget body;
    if (_noSnapshot && _streams) {
      body = CameraCard(
        ha: widget.ha,
        entity: widget.entity,
        name: widget.name,
        active: widget.active,
        icon: Icons.videocam,
      );
    } else {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: surface),
            if (pic != null && !_noSnapshot)
              Image.network(
                '$haBase$pic&t=$_n',
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _noSnapshot = true);
                  });
                  return const SizedBox();
                },
              ),
            if (_noSnapshot)
              const Center(
                child: Icon(Icons.videocam_off, color: muted, size: 40),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xAA000000), Color(0x00000000)],
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.videocam, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: gs(
                          16,
                          color: Colors.white,
                          weight: FontWeight.w500,
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
    return GestureDetector(onTap: widget.onTap, child: body);
  }
}

/// One camera full screen, live (HLS), letterboxed so nothing is cropped.
class _FullCamera extends StatelessWidget {
  final HA ha;
  final String entity, name;
  const _FullCamera({
    required this.ha,
    required this.entity,
    required this.name,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraCard(
            ha: ha,
            entity: entity,
            name: name,
            active: true,
            fit: BoxFit.contain,
            icon: Icons.videocam,
          ),
          Positioned(
            top: 16,
            left: 16,
            child: IconButton.filled(
              iconSize: 28,
              style: IconButton.styleFrom(
                backgroundColor: const Color(0x99000000),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    ),
  );
}
