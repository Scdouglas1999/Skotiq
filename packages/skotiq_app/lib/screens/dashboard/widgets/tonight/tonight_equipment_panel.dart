// The equipment panel — Tonight's c4 tile beside the preview (06 §Tonight).
//
// Readouts are end-aligned: they sit at the row's right edge, and start-aligned
// they put each value over the left of its label, so "L" over FILTER and "—"
// over TOTAL RMS started at different x than the values in the rows above.
//
// One `DeviceRow` per device. A device that is connected shows its live
// readouts; one that is not shows a muted "Not connected" and NO readouts,
// because a stale number beside a dead device is the most glanceable lie this
// panel can tell.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';

class TonightEquipmentPanel extends ConsumerWidget {
  const TonightEquipmentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    final camera = ref.watch(cameraStateProvider);
    final mount = ref.watch(mountStateProvider);
    final focuser = ref.watch(focuserStateProvider);
    final wheel = ref.watch(filterWheelStateProvider);
    final guider = ref.watch(guiderStateProvider);

    bool up(DeviceConnectionState state) =>
        state == DeviceConnectionState.connected;

    final rows = <_Device>[
      _Device(
        icon: LucideIcons.camera,
        name: camera.deviceName ?? l10n.text('tnCamera'),
        connected: up(camera.connectionState),
        readouts: <Readout>[
          Readout(
            value: camera.temperature?.toStringAsFixed(1),
            unit: '°C',
            label: l10n.text('tnSensor'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
          Readout(
            value: camera.coolerPower?.toStringAsFixed(0),
            unit: '%',
            label: l10n.text('tnCooler'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
        ],
      ),
      _Device(
        icon: LucideIcons.mountain,
        name: mount.deviceName ?? l10n.text('tnMount'),
        connected: up(mount.connectionState),
        readouts: <Readout>[
          Readout(
            value: mount.ra == null ? null : _ra(mount.ra!),
            label: l10n.text('tnRa'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
          Readout(
            value: mount.dec == null ? null : _dec(mount.dec!),
            label: l10n.text('tnDec'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
          Readout(
            value: mount.altitude?.toStringAsFixed(1),
            unit: '°',
            label: l10n.text('tnAlt'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
        ],
      ),
      _Device(
        icon: LucideIcons.focus,
        name: focuser.deviceName ?? l10n.text('tnFocuser'),
        connected: up(focuser.connectionState),
        readouts: <Readout>[
          Readout(
            value: focuser.position?.toString(),
            label: l10n.text('tnPosition'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
          Readout(
            value: focuser.temperature?.toStringAsFixed(1),
            unit: '°C',
            label: l10n.text('tnTemp'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
        ],
      ),
      _Device(
        icon: LucideIcons.disc,
        name: wheel.deviceName ?? l10n.text('tnFilterWheel'),
        connected: up(wheel.connectionState),
        readouts: <Readout>[
          Readout(
            value: _filterName(wheel),
            label: l10n.text('tnFilter'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
        ],
      ),
      _Device(
        icon: LucideIcons.crosshair,
        name: guider.deviceName ?? l10n.text('tnGuider'),
        connected: up(guider.connectionState),
        readouts: <Readout>[
          Readout(
            value:
                guider.isGuiding ? guider.rmsTotal?.toStringAsFixed(2) : null,
            unit: '"',
            label: l10n.text('tnTotalRms'),
            size: ReadoutSize.sm,
            alignment: CrossAxisAlignment.end,
          ),
        ],
      ),
    ];

    final connected = rows.where((row) => row.connected).length;

    return SkotiqPanel(
      head: PanelHead(
        icon: LucideIcons.plug,
        label: l10n.text('tnEquipment'),
        trailing: <Widget>[
          SkotiqChip(
            label: connected == rows.length
                ? l10n.text('tnAllConnected')
                : l10n.text(
                    'tnSomeConnected',
                    params: {'count': '$connected', 'total': '${rows.length}'},
                  ),
            tone: connected == 0
                ? ChipTone.neutral
                : (connected == rows.length
                    ? ChipTone.success
                    : ChipTone.warning),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < rows.length; i++) ...<Widget>[
            if (i > 0) Divider(height: 1, thickness: 1, color: colors.border),
            DeviceRow(
              icon: rows[i].icon,
              name: rows[i].name,
              // A disconnected device gets no measurements — a stale number
              // beside a dead device is the most glanceable lie this panel can
              // tell — only the em dash a null [Readout] draws, labelled with
              // the reason.
              readouts: rows[i].connected
                  ? rows[i].readouts
                  : <Readout>[
                      Readout(
                        value: null,
                        label: l10n.text('tnNotConnected'),
                        size: ReadoutSize.sm,
                        alignment: CrossAxisAlignment.end,
                      ),
                    ],
            ),
          ],
        ],
      ),
    );
  }

  /// The filter currently in the beam, or null when the wheel has not said.
  static String? _filterName(FilterWheelState wheel) {
    final index = wheel.currentPosition;
    if (index == null) return null;
    if (index < 0 || index >= wheel.filterNames.length) return '$index';
    return wheel.filterNames[index];
  }

  /// `13h 29m`.
  static String _ra(double hours) {
    final h = hours.floor();
    final m = ((hours - h) * 60).round();
    return '${h}h ${m.toString().padLeft(2, '0')}m';
  }

  /// `+47° 11'`.
  ///
  /// ASCII apostrophe, not U+2032 PRIME: neither bundled font carries the prime
  /// glyphs, so the real one renders as a tofu box on the rig.
  static String _dec(double degrees) {
    final sign = degrees < 0 ? '-' : '+';
    final abs = degrees.abs();
    final d = abs.floor();
    final m = ((abs - d) * 60).round();
    return "$sign$d° ${m.toString().padLeft(2, '0')}'";
  }
}

/// One row's worth of inputs, resolved before the panel decides what to draw.
class _Device {
  const _Device({
    required this.icon,
    required this.name,
    required this.connected,
    required this.readouts,
  });

  final IconData icon;
  final String name;
  final bool connected;
  final List<Readout> readouts;
}
