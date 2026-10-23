import 'package:flutter/material.dart';

import 'ambient.dart';
import 'camera.dart';
import 'ha.dart';
import 'ui.dart';

const doorbellEvent = 'event.entryway_entryway_timbre';

/// Full-screen interruption when the Nest doorbell rings (Google's quartz_notification_interruption).
class DoorbellOverlay extends StatelessWidget {
  final HA ha;
  final DateTime at;
  final VoidCallback onClose;
  const DoorbellOverlay({
    super.key,
    required this.ha,
    required this.at,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 22, 28, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 26,
                  backgroundColor: accent,
                  child: Icon(Icons.doorbell, color: bg, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Están llamando a la puerta',
                        style: gs(26, weight: FontWeight.w500),
                      ),
                      Text(
                        'Timbre entrada · ${hhmm(at)}',
                        style: gs(16, color: muted),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: surfaceHigh,
                    foregroundColor: onSurface,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 18,
                    ),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: onClose,
                  child: Text('Cerrar', style: gs(17)),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: CameraCard(
                ha: ha,
                entity: 'camera.entryway_entryway',
                name: 'Timbre entrada',
                active: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
