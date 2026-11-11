import '../../../models/calibration/calibration_library_models.dart';
import '../../../models/collaboration/collaboration_models.dart'
    show ContributionConsent;

/// Copies one file from the imaging host to [localPath] on this device.
typedef HostFileDownload =
    Future<void> Function(
      String localPath, {
      void Function(double fraction)? onProgress,
    });

/// What became of a shared master the user asked to pull into the library.
///
/// [kind] is `merged`, `preferredLocal` or `refused`; [reason] explains a
/// refusal.
typedef SharedMasterAcceptOutcome = ({String? kind, String? reason});

/// The calibration masters (darks, biases, flats, defect maps) kept on the
/// imaging host, with their tags, notes and sharing state.
abstract interface class CalibrationLibrary {
  /// Records matching [filter], newest first.
  Future<List<CalibrationMasterRecord>> listMasters({
    CalibrationLibraryFilter filter = const CalibrationLibraryFilter(),
    bool enrichFromHeaders = true,
  });

  Future<CalibrationMasterRecord?> getRecord(
    CalibrationMasterType type,
    int id,
  );

  /// The best master of each type for lights captured under [context], with
  /// the reasons and warnings behind each pick.
  Future<CalibrationMatchSet> match(
    LightFrameContext context, {
    CalibrationMatchTolerances tolerances = CalibrationMatchTolerances.defaults,
    bool includeRemote = true,
  });

  Future<void> setTags(CalibrationMasterType type, int id, List<String> tags);

  /// Null or empty [notes] clears them.
  Future<void> setNotes(CalibrationMasterType type, int id, String? notes);

  /// Removes the master from the library and, with [deleteFile], from the
  /// host's disk. False when no such master exists.
  Future<bool> deleteMaster(
    CalibrationMasterType type,
    int id, {
    bool deleteFile = false,
  });

  /// Shares a master on the configured hub under [consent]'s license.
  Future<void> publishMaster(
    CalibrationMasterRecord record, {
    required ContributionConsent consent,
  });

  /// Stops sharing a master this host published.
  Future<void> retractPublishedMaster(CalibrationMasterRecord record);

  /// Pulls a shared master the matcher surfaced into the host's library.
  Future<SharedMasterAcceptOutcome> acceptSharedMaster(
    CalibrationMasterRecord shared,
  );

  /// How to copy [record]'s file to this device, or null when the host's
  /// files are already this device's files.
  HostFileDownload? masterFileDownload(CalibrationMasterRecord record);
}
