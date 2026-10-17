/// Who owns the sequence currently loaded into the editor / executor.
///
/// The editor's [currentSequenceProvider] is a single slot that many callers
/// load into: the human operator (drag-drop authoring, library open), and a
/// handful of automated planners (autopilot scheduler, Smart Night, mosaic).
/// Before this concept existed every automated planner called
/// `loadSequence(..., discardUnsaved: true)`, silently destroying whatever the
/// operator had open. The owner makes the hand-off explicit: when an automated
/// planner takes over it stashes the manual sequence and flips the owner; when
/// it stops, manual ownership (and the stashed sequence) is restored.
enum ActivePlanOwner {
  /// The human operator is authoring/running the loaded sequence. This is the
  /// default and the only owner that respects the unsaved-changes guard.
  manual,

  /// The autopilot scheduler dispatched the loaded sequence as part of its own
  /// run loop ([SchedulerSequenceSink.dispatchSequence]).
  autopilot,

  /// A Smart Night plan was accepted and launched.
  smartNight,

  /// A mosaic project controller launched the generated panel sequence.
  mosaic;

  /// Whether this owner is an automated planner (i.e. NOT the human operator).
  /// Automated owners stash/restore the manual sequence on take-over/release.
  bool get isAutomated => this != ActivePlanOwner.manual;

  /// Wire token for the master/slave editor mirror. Kept stable and explicit so
  /// it survives enum reordering; parsed back via [ActivePlanOwnerWire.fromWire].
  String get wireValue {
    switch (this) {
      case ActivePlanOwner.manual:
        return 'manual';
      case ActivePlanOwner.autopilot:
        return 'autopilot';
      case ActivePlanOwner.smartNight:
        return 'smartNight';
      case ActivePlanOwner.mosaic:
        return 'mosaic';
    }
  }
}

/// Parsing helpers for the remote-sync wire value. Backward-compatible: an
/// absent/unknown token resolves to [ActivePlanOwner.manual] so an older host
/// (which never sends the field) is treated as manual ownership.
extension ActivePlanOwnerWire on ActivePlanOwner {
  static ActivePlanOwner fromWire(Object? value) {
    if (value is! String) return ActivePlanOwner.manual;
    switch (value) {
      case 'autopilot':
        return ActivePlanOwner.autopilot;
      case 'smartNight':
        return ActivePlanOwner.smartNight;
      case 'mosaic':
        return ActivePlanOwner.mosaic;
      case 'manual':
      default:
        return ActivePlanOwner.manual;
    }
  }
}
