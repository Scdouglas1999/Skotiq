import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The 28 px strip under the narrow page header (06 §Imaging, "Narrow").
///
/// Below the shell breakpoint there is no instrument bar (04 §5), so this is
/// the one place the rig's state is on screen while imaging. It is built from
/// the same [InstrumentPill] the instrument bar uses — one status surface, one
/// component — and it scrolls rather than truncating a device's name.
class ImagingStatusStrip extends ConsumerWidget {
  const ImagingStatusStrip({super.key});

  /// Widest a device value may be before it ellipsizes.
  static const double _valueMaxWidth = 96;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final cameraState = ref.watch(cameraStateProvider);
    final mountState = ref.watch(mountStateProvider);
    final guiderState = ref.watch(guiderStateProvider);
    final focuserState = ref.watch(focuserStateProvider);

    final cameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final focuserConnected =
        focuserState.connectionState == DeviceConnectionState.connected;
    final guiderConnected =
        guiderState.connectionState == DeviceConnectionState.connected;

    return Container(
      height: ShellChromeMetrics.narrowStatusStripHeight,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            InstrumentPill(
              icon: SkotiqIcons.camera,
              dotTone: _tone(cameraState.connectionState),
              value: cameraConnected && cameraState.temperature != null
                  ? '${cameraState.temperature!.toStringAsFixed(1)} °C'
                  : (cameraConnected ? 'Ready' : 'Not connected'),
              mono: cameraConnected && cameraState.temperature != null,
              semanticLabel:
                  cameraConnected ? 'Camera connected' : 'Camera not connected',
              maxValueWidth: _valueMaxWidth,
            ),
            const InstrumentSeparator(),
            InstrumentPill(
              icon: SkotiqIcons.mount,
              dotTone: _tone(mountState.connectionState),
              value: _mountValue(mountState),
              // Sentence case for the reader: "Mount not connected", not "Mount Not
              // connected".
              semanticLabel: 'Mount ${_lowerFirst(_mountValue(mountState))}',
              maxValueWidth: _valueMaxWidth,
            ),
            const InstrumentSeparator(),
            InstrumentPill(
              icon: SkotiqIcons.guider,
              dotTone: _tone(guiderState.connectionState),
              value: guiderConnected
                  ? (guiderState.isGuiding ? 'Guiding' : 'Ready')
                  : 'Not connected',
              semanticLabel: guiderConnected
                  ? 'Guider ${guiderState.isGuiding ? 'guiding' : 'ready'}'
                  : 'Guider not connected',
              maxValueWidth: _valueMaxWidth,
            ),
            const InstrumentSeparator(),
            InstrumentPill(
              icon: SkotiqIcons.focuser,
              dotTone: _tone(focuserState.connectionState),
              // The POSITION, not the word "Ready": a focuser's position is the
              // one thing about it worth a permanent slot in the chrome.
              value: focuserConnected
                  ? (focuserState.position?.toString() ?? 'Ready')
                  : 'Not connected',
              mono: focuserConnected && focuserState.position != null,
              semanticLabel: focuserConnected
                  ? 'Focuser at ${focuserState.position ?? 'unknown'}'
                  : 'Focuser not connected',
              maxValueWidth: _valueMaxWidth,
            ),
          ],
        ),
      ),
    );
  }

  static String _mountValue(MountState state) {
    if (state.connectionState != DeviceConnectionState.connected) {
      return 'Not connected';
    }
    if (state.isSlewing) return 'Slewing';
    if (state.isParked) return 'Parked';
    if (state.isTracking) return 'Tracking';
    return 'Ready';
  }

  static InstrumentTone _tone(DeviceConnectionState state) {
    return switch (state) {
      DeviceConnectionState.connected => InstrumentTone.success,
      DeviceConnectionState.connecting => InstrumentTone.warning,
      DeviceConnectionState.error => InstrumentTone.error,
      _ => InstrumentTone.idle,
    };
  }
}

String _lowerFirst(String s) =>
    s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
