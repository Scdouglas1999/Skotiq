import 'dart:math' as math;

import '../imaging/imaging_models.dart' show AutofocusSettings;
import 'sequence_models.dart' show AutofocusMethod, AutofocusNode;

/// One autofocus run as the executor makes it: the sweep the Autofocus
/// settings give, or an Autofocus node's own sweep when the node does not use
/// the settings. The executor's config (`autofocusRuntimeConfig`) and the plan
/// estimate both read it, so the time a plan shows for an autofocus is the
/// time of the run the executor is sent.
class AutofocusRun {
  /// The run the executor adds by itself (after a filter change, on a timer
  /// or a trigger).
  AutofocusRun.fromSettings(AutofocusSettings settings)
    : method = null,
      stepSize = settings.stepSize,
      stepsOut = settings.initialOffsetSteps,
      exposureSecs = settings.exposureTime,
      exposuresPerPoint = settings.exposuresPerPoint,
      focuserSettleSecs = settings.focuserSettleTimeMs / 1000,
      maxDurationSecs = addedRunMaxSecs;

  /// The run [node] makes: the settings' sweep when it uses them, its own
  /// otherwise. The settle and the time limit are always the settings' and
  /// the node's.
  AutofocusRun.ofNode(AutofocusSettings settings, AutofocusNode node)
    : method = node.useSettingsDefaults ? null : node.method,
      stepSize = node.useSettingsDefaults ? settings.stepSize : node.stepSize,
      stepsOut = node.useSettingsDefaults
          ? settings.initialOffsetSteps
          : node.stepsOut,
      exposureSecs = node.useSettingsDefaults
          ? settings.exposureTime
          : node.exposureDuration,
      exposuresPerPoint = node.useSettingsDefaults
          ? settings.exposuresPerPoint
          : node.exposuresPerPoint,
      focuserSettleSecs = settings.focuserSettleTimeMs / 1000,
      maxDurationSecs = node.maxDurationSecs;

  /// The time limit of a run the executor adds by itself, in seconds.
  static const double addedRunMaxSecs = 600;

  /// The node's curve method, or null for the settings' curve fitting.
  final AutofocusMethod? method;

  final int stepSize;

  /// Focuser positions measured on each side of the starting one.
  final int stepsOut;

  final double exposureSecs;
  final int exposuresPerPoint;

  /// The wait after each focuser move before the first exposure.
  final double focuserSettleSecs;

  /// When the executor gives up on the run, in seconds.
  final double maxDurationSecs;

  /// Focuser positions the sweep measures.
  int get points => stepsOut * 2 + 1;

  /// How long one run takes: at each point the focuser settles and the camera
  /// takes its exposures, each followed by [downloadSecs] of download; never
  /// longer than the run's time limit. A failed sweep's retries are not
  /// counted: a plan cannot know them.
  Duration duration({required double downloadSecs}) {
    final sweep =
        points *
        (focuserSettleSecs + exposuresPerPoint * (exposureSecs + downloadSecs));
    return Duration(
      milliseconds: (math.min(sweep, maxDurationSecs) * 1000).round(),
    );
  }
}
