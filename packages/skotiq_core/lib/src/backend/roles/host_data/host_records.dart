import '../../../database/database.dart'
    show EquipmentProfile, ImagingSession, Sequence, SequenceRun, Target;

/// The equipment profiles saved in the imaging host's database.
abstract interface class EquipmentProfileLibrary {
  Stream<List<EquipmentProfile>> watchAllProfiles();

  /// The profile marked active, or null when none is.
  Stream<EquipmentProfile?> watchActiveProfile();
}

/// The targets saved in the imaging host's database.
abstract interface class TargetLibrary {
  Stream<List<Target>> watchAllTargets();

  Stream<List<Target>> watchFavoriteTargets();
}

/// The sequences saved in the imaging host's database.
abstract interface class SequenceLibrary {
  /// Every saved sequence that is not a template.
  Stream<List<Sequence>> watchAllSequences();
}

/// The imaging sessions recorded in the imaging host's database.
abstract interface class SessionHistory {
  /// Every session, newest first.
  Stream<List<ImagingSession>> watchAllSessions();
}

/// The sequence runs recorded in the imaging host's database.
///
/// A linked host does not serve the snapshot of the sequence a run executed,
/// so `sequenceSnapshotJson` is null on rows read from one.
abstract interface class RunHistory {
  /// Every run, newest first.
  Stream<List<SequenceRun>> watchAllRuns();

  Stream<List<SequenceRun>> watchRunsForSequence(int sequenceId);
}
