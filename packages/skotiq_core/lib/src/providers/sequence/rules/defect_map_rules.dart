import '../../../models/defect_map.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../providers/capability_provider.dart';
import '../../../providers/defect_map_provider.dart';
import '../../../providers/equipment_provider.dart';
import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';

/// Defect-map validation rules.
///
/// The Rust capture path silently skips defect-map application when no map
/// exists for the connected camera at the current temperature bucket
/// (a warn-level log is emitted, but the sequence does not fail). Without
/// this rule the user can have `defectMap.autoApply = true` and still ship
/// uncorrected frames for an entire night — exactly the "silent fallback
/// hides bugs" failure mode we prohibit.
///
/// The pre-flight rule queries the current camera capabilities + the
/// stored defect map status to surface a warning when:
///   * Auto-apply is on, AND
///   * The camera is connected, AND
///   * No defect map exists for the current sensor size + temperature
///     bucket.
///
/// The user can either:
///   * Build a defect map for the bucket (via the calibration section), or
///   * Disable auto-apply.
class DefectMapAppliedButCalibrationOffRule
    implements RefAwareSequenceValidator {
  @override
  String get name => 'DefectMapAppliedButCalibrationOff';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final settings = ctx.ref.read(defectMapSettingsProvider);
    if (!settings.autoApply) {
      // Opt-in is off — nothing to warn about. The rule still runs (we
      // return an empty list) so the user can flip auto-apply and the
      // next live-validation tick will catch the new state.
      return const <ValidationIssue>[];
    }

    final cameraState = ctx.ref.read(cameraStateProvider);
    final cameraId = cameraState.deviceId;
    if (cameraId == null ||
        cameraId.isEmpty ||
        cameraState.connectionState != DeviceConnectionState.connected) {
      // Without a camera we cannot resolve the map status. Emit an
      // info-level note rather than swallowing the check: this is the
      // documented "could not run" branch from the SequenceValidator
      // contract.
      return <ValidationIssue>[
        const ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.exposures,
          title: 'Defect-map auto-apply check skipped (no camera)',
          description:
              'Auto-apply defect map is enabled but no camera is connected. '
              'Connect a camera so the pre-flight check can verify a map '
              'exists for it.',
          resolutionHint:
              'Connect a camera in the Equipment screen, or disable '
              '"Auto-apply" in the calibration settings.',
        ),
      ];
    }

    final temperatureC = cameraState.temperature;
    if (temperatureC == null) {
      return <ValidationIssue>[
        const ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.exposures,
          title: 'Defect-map auto-apply check skipped (cooler not reporting)',
          description:
              'Auto-apply defect map is enabled but the camera has not '
              'reported a sensor temperature yet. The check will re-run '
              'once the first cooler telemetry arrives.',
          resolutionHint:
              'Wait for the cooler to report a temperature, or disable '
              '"Auto-apply" in the calibration settings.',
        ),
      ];
    }

    final capsAsync = ctx.ref.read(cameraCapabilitiesProvider(cameraId));
    // .value normalises the AsyncValue's nullable payload back to the
    // inner Option, matching the AsyncValue.value semantics used by the
    // calibration UI elsewhere in the codebase.
    final caps = capsAsync.value;
    if (caps == null) {
      return const <ValidationIssue>[];
    }
    final width = caps.maxWidth;
    final height = caps.maxHeight;
    if (width <= 0 || height <= 0) {
      return const <ValidationIssue>[];
    }

    final statusAsync = ctx.ref.read(
      defectMapStatusProvider(
        DefectMapQuery(
          cameraId: cameraId,
          width: width,
          height: height,
          sensorTemperatureCelsius: temperatureC,
        ),
      ),
    );
    // Why .value rather than .valueOrNull: the FutureProvider's data
    // wrapper double-Options the payload (Option<Option<DefectMapStatus>>);
    // the AsyncValue helpers normalise the outer Option, so .value here
    // returns the inner DefectMapStatus? directly.
    final status = statusAsync.value;
    if (status == null) {
      final bucket = DefectMapTemperatureBucket.fromCelsius(temperatureC);
      return <ValidationIssue>[
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.exposures,
          title: 'Defect map auto-apply on but no map exists',
          description:
              'Auto-apply defect map is enabled for ${cameraState.deviceName ?? cameraId}, '
              'but no defect map is stored for ${width}x$height at '
              '${bucket.label}. Captured frames will be saved uncorrected '
              'until a map is built.',
          resolutionHint:
              'Open the Calibration section and click "Build defect map" '
              'using at least 5 dark frames captured at this temperature, '
              'or disable "Auto-apply" in the calibration settings.',
        ),
      ];
    }
    return const <ValidationIssue>[];
  }
}
