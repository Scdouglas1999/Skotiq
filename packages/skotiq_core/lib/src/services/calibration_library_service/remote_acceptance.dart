part of '../calibration_library_service.dart';

/// What happened when a REMOTE master was accepted into the local library.
enum RemoteMasterAcceptanceKind {
  /// The master was downloaded and merged in as a new local artifact.
  merged,

  /// An exact-tuple LOCAL master already existed, so the local copy was kept and
  /// nothing was downloaded (conflict resolution: prefer local).
  preferredLocal,

  /// The master was refused by the quality/consent gate (e.g. non-shareable
  /// license, or a flat without an optical-train tag).
  refused,
}

/// The outcome of [CalibrationLibraryService.acceptRemoteMaster].
class RemoteMasterAcceptance {
  const RemoteMasterAcceptance._(
    this.kind, {
    this.mergedId,
    this.filePath,
    this.existing,
    this.reason,
  });

  factory RemoteMasterAcceptance.merged(int id, String filePath) =>
      RemoteMasterAcceptance._(
        RemoteMasterAcceptanceKind.merged,
        mergedId: id,
        filePath: filePath,
      );

  factory RemoteMasterAcceptance.preferredLocal(
    CalibrationMasterRecord existing,
  ) => RemoteMasterAcceptance._(
    RemoteMasterAcceptanceKind.preferredLocal,
    existing: existing,
  );

  factory RemoteMasterAcceptance.refused(String reason) =>
      RemoteMasterAcceptance._(
        RemoteMasterAcceptanceKind.refused,
        reason: reason,
      );

  final RemoteMasterAcceptanceKind kind;

  /// The new local artifact id (set only when [kind] is `merged`).
  final int? mergedId;

  /// The downloaded file path (set only when [kind] is `merged`).
  final String? filePath;

  /// The kept local master (set only when [kind] is `preferredLocal`).
  final CalibrationMasterRecord? existing;

  /// Why the master was refused (set only when [kind] is `refused`).
  final String? reason;

  bool get accepted => kind == RemoteMasterAcceptanceKind.merged;
}
