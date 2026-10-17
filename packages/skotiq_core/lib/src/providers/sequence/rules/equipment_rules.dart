import '../../../models/backend/device_types.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../utils/device_id.dart';
import '../../equipment_provider.dart';
import '../sequence_validation.dart';

/// Cross-checks the device types required by enabled nodes against the
/// currently-connected equipment.
///
/// Strict map between [DeviceType] and connection state:
///   * camera — error if missing
///   * mount — error if missing (only when there are slewing/tracking nodes)
///   * focuser — error if missing (only when there are autofocus nodes)
///   * filter wheel — warning if missing (some users image without one)
///   * guider — warning if missing (per-node warnings on the actual guider
///     nodes, plus a high-level message if any node requires it)
///   * rotator — info if missing
///   * dome — info if missing
class EquipmentConnectionRule implements RefAwareSequenceValidator {
  @override
  String get name => 'EquipmentConnection';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final required = <DeviceType>{};
    for (final node in sequence.nodes.values) {
      if (!node.isEnabled) continue;
      required.addAll(node.requiredDevices);
    }
    if (required.isEmpty) return const [];

    final issues = <ValidationIssue>[];
    final ref = ctx.ref;

    bool isConnected(DeviceConnectionState s) =>
        s == DeviceConnectionState.connected;

    if (required.contains(DeviceType.camera)) {
      final cs = ref.read(cameraStateProvider);
      if (!isConnected(cs.connectionState)) {
        issues.add(
          const ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.equipment,
            title: 'No Camera Connected',
            description: 'This sequence requires a camera to capture images.',
            resolutionHint: 'Connect a camera in the Equipment panel.',
          ),
        );
      }
    }

    if (required.contains(DeviceType.mount)) {
      final ms = ref.read(mountStateProvider);
      if (!isConnected(ms.connectionState)) {
        issues.add(
          const ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.equipment,
            title: 'No Mount Connected',
            description:
                'This sequence includes slewing or tracking operations that require a mount.',
            resolutionHint: 'Connect a mount in the Equipment panel.',
          ),
        );
      }
    }

    if (required.contains(DeviceType.focuser)) {
      final fs = ref.read(focuserStateProvider);
      if (!isConnected(fs.connectionState)) {
        issues.add(
          const ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.equipment,
            title: 'No Focuser Connected',
            description:
                'This sequence includes autofocus operations that require a focuser.',
            resolutionHint: 'Connect a focuser in the Equipment panel.',
          ),
        );
      }
    }

    if (required.contains(DeviceType.filterWheel)) {
      final fws = ref.read(filterWheelStateProvider);
      if (!isConnected(fws.connectionState)) {
        issues.add(
          const ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.equipment,
            title: 'No Filter Wheel Connected',
            description:
                'This sequence includes filter changes that require a filter wheel.',
            resolutionHint: 'Connect a filter wheel in the Equipment panel.',
          ),
        );
      }
    }

    if (required.contains(DeviceType.guider)) {
      final gs = ref.read(guiderStateProvider);
      if (!isConnected(gs.connectionState)) {
        // Per-node warnings carry an affectedNodeId, so the tree borders
        // highlight the nodes that need the guider AND the pre-flight list
        // names them. A top-level summary on top of those was the SAME
        // missing guider counted twice — identical hint and all — which
        // inflated the "N warnings" badge. It is emitted only as a fallback,
        // when no enabled node could be attributed.
        //
        // The remediation follows the guider actually in hand — see
        // [_guiderResolutionHint]. Naming PHD2 unconditionally sent an
        // operator running the built-in guider to a panel that has no
        // Connect button for it.
        final hint = _guiderResolutionHint(gs);
        final perNode = <ValidationIssue>[];
        for (final node in sequence.nodes.values) {
          if (!node.isEnabled) continue;
          if (!node.requiredDevices.contains(DeviceType.guider)) continue;
          perNode.add(
            ValidationIssue(
              severity: ValidationSeverity.warning,
              category: ValidationCategory.equipment,
              title: 'Guider Not Connected',
              description:
                  '${node.name} requires a guider but none is connected.',
              affectedNodeId: node.id,
              resolutionHint: hint,
            ),
          );
        }
        if (perNode.isEmpty) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.warning,
              category: ValidationCategory.equipment,
              title: 'No Guider Connected',
              description:
                  'This sequence includes guiding or dithering operations '
                  'that require a guider.',
              resolutionHint: hint,
            ),
          );
        } else {
          issues.addAll(perNode);
        }
      }
    }

    if (required.contains(DeviceType.rotator)) {
      final rs = ref.read(rotatorStateProvider);
      if (!isConnected(rs.connectionState)) {
        issues.add(
          const ValidationIssue(
            severity: ValidationSeverity.info,
            category: ValidationCategory.equipment,
            title: 'No Rotator Connected',
            description: 'This sequence includes rotator operations.',
            resolutionHint: 'Connect a rotator in the Equipment panel.',
          ),
        );
      }
    }

    if (required.contains(DeviceType.dome)) {
      // Dome state is not yet a first-class provider; surface an info note
      // rather than silently skipping the check.
      issues.add(
        const ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.equipment,
          title: 'Dome Operations Present',
          description:
              'This sequence includes dome operations. Cannot verify dome connection at edit time.',
          resolutionHint:
              'Verify the dome is connected before starting the sequence.',
        ),
      );
    }

    return issues;
  }
}

/// Remediation text for a missing guider, routed to the panel that can
/// actually connect the guider [gs] refers to.
///
/// Only PHD2 has a Connect button on the Guiding panel (it has to launch and
/// socket into an external process). Every other backend — including the
/// built-in multi-star guider this build ships — is connected from Equipment,
/// where the Guiding panel's own button sends you.
String _guiderResolutionHint(GuiderState gs) {
  final id = gs.deviceId;
  if (id == null) {
    return 'Connect a guider in the Equipment panel — the built-in '
        'multi-star guider, or PHD2.';
  }
  if (isPhd2DeviceId(id)) return 'Connect to PHD2 in the Guiding panel.';
  final name = gs.deviceName;
  return name == null
      ? 'Connect the selected guider in the Equipment panel.'
      : 'Connect $name in the Equipment panel.';
}

/// Warns when a target specifies a rotation angle but no rotator is
/// connected. The rotator command will fail at runtime.
class RotatorRotationConflictRule implements RefAwareSequenceValidator {
  @override
  String get name => 'RotatorRotationConflict';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final issues = <ValidationIssue>[];
    final rotatorState = ctx.ref.read(rotatorStateProvider);
    final connected =
        rotatorState.connectionState == DeviceConnectionState.connected;
    if (connected) return const [];

    for (final target in sequence.targetHeaders) {
      final rotation = target.rotation;
      // A null or 0° rotation requests no rotation at all — it never needs a
      // rotator (0° = leave the camera at its current angle). Auto-built (Plan
      // Tonight) targets request no rotation, but carry a spurious 0.0 from
      // persistence/serialization defaults; warning on that is noise. Only a
      // genuinely non-zero target angle requires a connected rotator.
      if (rotation == null || rotation.abs() < 0.01) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.equipment,
          title: 'Rotator Not Connected',
          description:
              'Target "${target.targetName}" specifies rotation (${rotation.toStringAsFixed(1)}°) '
              'but no rotator is connected.',
          affectedNodeId: target.id,
          resolutionHint: 'Connect a rotator or remove the rotation setting.',
        ),
      );
    }
    return issues;
  }
}
