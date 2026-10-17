part of '../sequence_diff_service.dart';

extension _SequenceDiffNodeDescribe on SequenceDiffService {
  /// Display label for a node — the same string the dialog renders next
  /// to its kind icon. Keep concise; the body of the diff is the per-
  /// field [FieldChange] list, not this label.
  String _describeNode(SequenceNode node) {
    switch (node) {
      case ExposureNode():
        final filter = (node.filter == null || node.filter!.isEmpty)
            ? 'Unfiltered'
            : node.filter!;
        return 'Exposure ${node.durationSecs.toStringAsFixed(0)}s x${node.count} ($filter)';
      case TargetHeaderNode():
        return 'Target "${node.targetName}"';
      case LoopNode():
        if (node.conditionType == LoopConditionType.count &&
            node.repeatCount != null) {
          return 'Loop x${node.repeatCount}';
        }
        return 'Loop (${node.conditionType.name})';
      case AutofocusNode():
        return 'Autofocus (${node.method.name})';
      case DitherNode():
        return 'Dither ${node.pixels.toStringAsFixed(1)}px';
      case FilterChangeNode():
        return 'Filter change → ${node.filterName}';
      case SlewNode():
        return node.useTargetCoords
            ? 'Slew (target coords)'
            : 'Slew (RA ${node.customRa}, Dec ${node.customDec})';
      case CenterNode():
        return 'Center (${node.accuracyArcsec}″)';
      case CoolCameraNode():
        return 'Cool camera → ${node.targetTemp}C';
      case WarmCameraNode():
        return 'Warm camera → ${node.targetTemp}C';
      case RotatorNode():
        return 'Rotate to ${node.targetAngle}°';
      case WaitTimeNode():
        if (node.waitUntil != null) {
          return 'Wait until ${node.waitUntil!.toIso8601String()}';
        }
        if (node.waitForTwilight != null) {
          return 'Wait for ${node.waitForTwilight!.name} twilight';
        }
        return 'Wait';
      case DelayNode():
        return 'Delay ${node.seconds}s';
      case NotificationNode():
        return 'Notification "${node.title}"';
      case ScriptNode():
        return 'Script ${node.scriptPath}';
      case MeridianFlipNode():
        return 'Meridian flip';
      case PolarAlignmentNode():
        return 'Polar alignment';
      case TargetSchedulerNode():
        return 'Target scheduler';
      case SmartExposureNode():
        return 'Smart exposure (${node.plans.length} plans)';
      case LiveStackingNode():
        final access = node.isPublic ? 'public' : 'private';
        return 'Live stacking (port ${node.broadcastPort}, $access)';
      case SciencePhotometryNode():
        return 'Photometry (${node.targetDesignation}, ${node.filter}, '
            '${node.count}x${node.exposureSecs.toStringAsFixed(0)}s)';
      case ParallelNode():
        return 'Parallel';
      case ConditionalNode():
        return 'Conditional (${node.conditionType.name})';
      case RecoveryNode():
        return 'Recovery (${node.recoveryAction.name})';
      case StartGuidingNode():
        return 'Start guiding';
      case InstructionSetNode():
        return node.name;
      case StopGuidingNode():
        return 'Stop guiding';
      case ParkNode():
        return 'Park mount';
      case UnparkNode():
        return 'Unpark mount';
      case OpenCoverNode():
        return 'Open dust cover';
      case CloseCoverNode():
        return 'Close dust cover';
      case CalibratorOnNode():
        return 'Calibrator on';
      case CalibratorOffNode():
        return 'Calibrator off';
      case OpenDomeNode():
        return 'Open dome';
      case CloseDomeNode():
        return 'Close dome';
      case ParkDomeNode():
        return 'Park dome';
      case PluginInstructionNode():
        // Show the friendly node name AND the source plugin
        // so users distinguish identical-named nodes from different
        // plugins in the diff dialog.
        final source = node.pluginName.isEmpty
            ? node.pluginId
            : node.pluginName;
        return 'Plugin: ${node.name} ($source)';
    }
  }
}
