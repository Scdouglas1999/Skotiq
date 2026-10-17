// Editor-layer helper for applying user edits to a [MeridianFlipNode].
//
// Why this exists (and why it lives in the editor layer, not in
// `sequence_models.dart`):
//
// The Sequencer Settings panel exposes a global "Meridian Flip" section that
// governs flip behavior for any node carrying `useGlobalDefaults: true`.
// When an operator opens the properties panel for a meridian-flip node and
// edits one of its 11 config fields, the *user intent* is "I want a sticky
// per-node override that beats the global settings." Expressing that intent
// means flipping `useGlobalDefaults` to `false` as a side-effect of the edit.
//
// That rule does not belong in `MeridianFlipNode.copyWith`: the data model
// would carry hidden UX behavior, and every caller of `copyWith` — JSON
// round-trippers, sequence importers, diffing tools, and programmatic mutators
// that legitimately want to preserve `useGlobalDefaults` — would get the
// side-effect silently. It would also make the class incompatible with a
// `freezed`-generated `copyWith`, which is a vanilla field-replace.
//
// So this helper owns the UX rule. Editor widgets must funnel their per-field
// edits through [applyMeridianFlipEdit] instead of calling
// `node.copyWith(field: value)` directly. Programmatic call sites keep calling
// `copyWith` — a plain field-replace — and decide for themselves whether to
// touch `useGlobalDefaults`.

import 'package:skotiq_core/skotiq_core.dart';

/// Applies a user edit from the meridian-flip properties panel to [current].
///
/// Rules:
///
/// * If any of the 11 flip-config fields is supplied with a non-null value
///   (`triggerMethod`, `minutesPastMeridian`, `minutesBeforeLimit`,
///   `hourAngleThreshold`, `pauseGuiding`, `autoCenter`, `refocusAfter`,
///   `settleTime`, `resumeGuiding`, `maxRetries`, `failureAction`), the
///   returned node has `useGlobalDefaults: false` — the edit becomes a
///   sticky per-node override.
/// * Touching only structural fields (id/name/parent/etc.) leaves
///   `useGlobalDefaults` alone.
/// * An explicit [useGlobalDefaults] argument always wins; this is the
///   "Use global defaults" toggle path in the properties panel.
MeridianFlipNode applyMeridianFlipEdit(
  MeridianFlipNode current, {
  String? id,
  String? name,
  bool? isEnabled,
  List<String>? childIds,
  String? parentId,
  int? orderIndex,
  String? comment,
  MeridianTriggerMethod? triggerMethod,
  double? minutesPastMeridian,
  double? minutesBeforeLimit,
  double? hourAngleThreshold,
  bool? pauseGuiding,
  bool? autoCenter,
  bool? refocusAfter,
  double? settleTime,
  bool? resumeGuiding,
  int? maxRetries,
  FlipFailureAction? failureAction,
  bool? useGlobalDefaults,
}) {
  final touchedConfig = triggerMethod != null ||
      minutesPastMeridian != null ||
      minutesBeforeLimit != null ||
      hourAngleThreshold != null ||
      pauseGuiding != null ||
      autoCenter != null ||
      refocusAfter != null ||
      settleTime != null ||
      resumeGuiding != null ||
      maxRetries != null ||
      failureAction != null;
  final resolvedUseGlobalDefaults =
      useGlobalDefaults ?? (touchedConfig ? false : current.useGlobalDefaults);

  return current.copyWith(
    id: id,
    name: name,
    isEnabled: isEnabled,
    childIds: childIds,
    parentId: parentId,
    orderIndex: orderIndex,
    comment: comment,
    triggerMethod: triggerMethod,
    minutesPastMeridian: minutesPastMeridian,
    minutesBeforeLimit: minutesBeforeLimit,
    hourAngleThreshold: hourAngleThreshold,
    pauseGuiding: pauseGuiding,
    autoCenter: autoCenter,
    refocusAfter: refocusAfter,
    settleTime: settleTime,
    resumeGuiding: resumeGuiding,
    maxRetries: maxRetries,
    failureAction: failureAction,
    useGlobalDefaults: resolvedUseGlobalDefaults,
  );
}
