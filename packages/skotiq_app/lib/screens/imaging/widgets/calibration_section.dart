import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../widgets/remote_directory_picker_dialog.dart';
import 'panel_widgets.dart';

part 'calibration_section_parts/_status_blocks.dart';
part 'calibration_section_parts/_build_controls.dart';
part 'calibration_section_parts/_correction_settings.dart';

typedef DefectMapLocalDarkPicker = Future<List<String>> Function();
typedef DefectMapHostDarkPicker = Future<String?> Function(
  BuildContext context,
);

Future<List<String>> _pickLocalDarkFrames() async {
  const typeGroup = XTypeGroup(
    label: 'Dark frames',
    extensions: ['fits', 'fit', 'fts', 'xisf'],
  );
  final files = await openFiles(acceptedTypeGroups: [typeGroup]);
  return files.map((file) => file.path).toList(growable: false);
}

Future<String?> _pickHostDarkDirectory(BuildContext context) {
  return RemoteDirectoryPickerDialog.show(
    context,
    title: 'Select the host folder containing dark frames',
  );
}

final defectMapLocalDarkPickerProvider =
    Provider<DefectMapLocalDarkPicker>((ref) => _pickLocalDarkFrames);

final defectMapHostDarkPickerProvider =
    Provider<DefectMapHostDarkPicker>((ref) => _pickHostDarkDirectory);

/// Image-calibration controls for the imaging screen.
///
/// Surfaces the per-camera defect-map pipeline:
/// - status line ("1,243 pixels, built 2 days ago at -10C")
/// - build-from-darks button
/// - apply-during-capture toggle
/// - clear-map button
///
/// All controls are disabled when the camera is not connected, with a
/// tooltip explaining why. The defect map is keyed by camera id, sensor
/// width / height and a 5C temperature bucket; those four values come
/// from [cameraStateProvider] + [cameraCapabilitiesProvider].
class CalibrationSection extends ConsumerWidget {
  final SkotiqColors colors;

  const CalibrationSection({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraState = ref.watch(cameraStateProvider);
    final isConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final cameraId = cameraState.deviceId;
    final cameraName = cameraState.deviceName ?? cameraId;
    final temperatureC = cameraState.temperature;

    final capabilitiesAsync =
        ref.watch(cameraCapabilitiesProvider(cameraId ?? ''));
    final capabilities = capabilitiesAsync.valueOrNull;

    // The defect map is keyed by the sensor's full size, not by any
    // user-selected subframe. Use the capability max which mirrors the
    // sensor dimensions reported by the driver.
    final sensorWidth = capabilities?.maxWidth ?? 0;
    final sensorHeight = capabilities?.maxHeight ?? 0;

    // Reasons the controls might be unavailable, in priority order.
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final String? disabledReason = _resolveDisabledReason(
      isConnected: isConnected,
      cameraId: cameraId,
      sensorWidth: sensorWidth,
      sensorHeight: sensorHeight,
      temperatureC: temperatureC,
    );
    final controlsEnabled = disabledReason == null;
    final noCameraConnected =
        !isConnected || cameraId == null || cameraId.isEmpty;

    return PanelSection(
      title: 'Image calibration',
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatusBlock(
            colors: colors,
            cameraId: cameraId,
            cameraName: cameraName,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            temperatureC: temperatureC,
            disabledReason: disabledReason,
          ),
          if (noCameraConnected) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: 'Go to Equipment',
                icon: SkotiqIcons.connected,
                size: ButtonSize.small,
                onPressed: () => context.go('/equipment'),
              ),
            ),
          ],
          const SizedBox(height: 16),
          DefectMapBuildButton(
            colors: colors,
            enabled: controlsEnabled,
            disabledReason: disabledReason,
            cameraId: cameraId,
            temperatureC: temperatureC,
            isRemoteMode: isRemoteMode,
          ),
          const SizedBox(height: 12),
          _ApplyToggle(
            colors: colors,
            enabled: controlsEnabled,
            disabledReason: disabledReason,
            cameraId: cameraId,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            temperatureC: temperatureC,
          ),
          const SizedBox(height: 12),
          _ClearButton(
            colors: colors,
            enabled: controlsEnabled,
            disabledReason: disabledReason,
            cameraId: cameraId,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            temperatureC: temperatureC,
          ),
          const SizedBox(height: 16),
          _CorrectionSettings(
            colors: colors,
            cameraId: cameraId,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            temperatureC: temperatureC,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'Flat wizard',
              icon: LucideIcons.sun,
              variant: ButtonVariant.outline,
              size: ButtonSize.small,
              onPressed: () => context.push('/flat-wizard'),
            ),
          ),
        ],
      ),
    );
  }

  static String? _resolveDisabledReason({
    required bool isConnected,
    required String? cameraId,
    required int sensorWidth,
    required int sensorHeight,
    required double? temperatureC,
  }) {
    // Remote mode is fully supported: the host owns the dark frames and the
    // stored defect map. BUILD picks a host directory via the remote picker;
    // APPLY and CLEAR route to the host over REST. The camera-state gates
    // below still apply (they describe the host camera, mirrored to the
    // remote client over the WS).
    if (!isConnected || cameraId == null || cameraId.isEmpty) {
      return 'Connect a camera to manage its defect map.';
    }
    if (sensorWidth <= 0 || sensorHeight <= 0) {
      return 'Waiting for sensor dimensions from the connected camera.';
    }
    if (temperatureC == null) {
      return 'Camera has not reported a sensor temperature yet; '
          'wait for the first cooler telemetry reading.';
    }
    return null;
  }
}
