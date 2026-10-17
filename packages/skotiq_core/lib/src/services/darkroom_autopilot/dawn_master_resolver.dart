/// Resolves the linear masters a night produced, from the database alone.
///
/// **Why from the database and not from the caller.** `darkroom_jobs` records a
/// session id and nothing else, so a job re-queued by the open-time crash
/// recovery arrives with no in-memory hand-off from the integration that
/// produced its inputs. Deriving the inputs from the session makes the resumed
/// path and the fresh path the same code, which is the only way the resumed
/// path can be trusted: a second resolver would be exercised only after a
/// crash.
///
/// The join is on identity, never on order — `integrated_master_frames` records
/// which `captured_images` row went into which master, and that is what the
/// resolution follows.
library;

import '../../database/daos/images_dao.dart';
import '../../database/daos/integrated_masters_dao.dart';
import '../../models/imaging/integrated_master.dart';

/// One linear master this job can draft over.
class DawnMaster {
  /// The `integrated_masters.id` row.
  final int masterId;

  /// The target the master was integrated for, or null when the night carried
  /// no target row.
  final int? targetId;

  /// Operator-facing master name, as the library row carries it.
  final String name;

  /// The filter this master covers, or null for an unfiltered master.
  final String? filter;

  /// Absolute path of the linear master FITS.
  final String masterFitsPath;

  /// Channel count. Three is the colour case the colour calibration needs; one
  /// is a per-filter mono master.
  final int channels;

  /// Master width in pixels.
  final int width;

  /// Master height in pixels.
  final int height;

  /// Frames folded into the master across every night it accumulated.
  final int frameCount;

  /// Total integration time in seconds across every night.
  final double totalIntegrationSeconds;

  const DawnMaster({
    required this.masterId,
    required this.targetId,
    required this.name,
    required this.filter,
    required this.masterFitsPath,
    required this.channels,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.totalIntegrationSeconds,
  });

  /// True when the base has the three channels the colour calibration fits.
  bool get isColor => channels == 3;

  @override
  String toString() =>
      'DawnMaster($name, ${filter ?? 'no filter'}, ${channels}ch, '
      '$masterFitsPath)';
}

/// A master the night touched that has no linear FITS on disk yet.
///
/// An accumulating master only writes its FITS at finalize, so a night that
/// folded subs into one has grown the data without producing a file to draft
/// over. That is a statement the morning report makes, not a master silently
/// missing from the list.
class DawnMasterWithoutFile {
  /// The `integrated_masters.id` row.
  final int masterId;

  /// Operator-facing master name.
  final String name;

  /// Why there is no file, in the words the report prints.
  final String reason;

  const DawnMasterWithoutFile({
    required this.masterId,
    required this.name,
    required this.reason,
  });
}

/// What one session's integration left behind.
class DawnMasterSet {
  /// The session these masters came from.
  final int sessionId;

  /// Masters with a linear FITS on disk, newest first.
  final List<DawnMaster> masters;

  /// Masters the night grew that have no FITS to draft over yet.
  final List<DawnMasterWithoutFile> withoutFile;

  const DawnMasterSet({
    required this.sessionId,
    required this.masters,
    required this.withoutFile,
  });

  /// True when the session produced nothing to draft over.
  bool get isEmpty => masters.isEmpty;
}

/// Reads the masters a session produced.
class DawnMasterResolver {
  final ImagesDao _images;
  final IntegratedMastersDao _masters;

  const DawnMasterResolver({
    required ImagesDao images,
    required IntegratedMastersDao masters,
  }) : _images = images,
       _masters = masters;

  /// Every master any of [sessionId]'s frames was folded into.
  ///
  /// Frames of every type are considered, because the fold record is what
  /// establishes the link and a light is the only frame type that reaches it.
  /// A master row whose `master_fits_path` is null lands in
  /// [DawnMasterSet.withoutFile] with the reason, so the count of masters the
  /// night touched always matches the count the report explains.
  Future<DawnMasterSet> resolve(int sessionId) async {
    final images = await _images.getImagesForSession(sessionId);
    final imageIds = images.map((i) => i.id).toList(growable: false);
    final masterIds = await _masters.masterIdsForImages(imageIds);

    final drafted = <DawnMaster>[];
    final missing = <DawnMasterWithoutFile>[];
    for (final id in masterIds) {
      final master = await _masters.getById(id);
      if (master == null) {
        missing.add(
          DawnMasterWithoutFile(
            masterId: id,
            name: 'master $id',
            reason:
                'the frame record points at master $id and that row is gone, '
                'so its pixels cannot be located',
          ),
        );
        continue;
      }
      final path = master.masterFitsPath;
      if (path == null || path.trim().isEmpty) {
        missing.add(
          DawnMasterWithoutFile(
            masterId: id,
            name: master.name,
            reason: _noFileReason(master),
          ),
        );
        continue;
      }
      drafted.add(
        DawnMaster(
          masterId: id,
          targetId: master.targetId,
          name: master.name,
          filter: master.filter,
          masterFitsPath: path,
          channels: master.channels,
          width: master.width,
          height: master.height,
          frameCount: master.frameCount,
          totalIntegrationSeconds: master.totalIntegrationSeconds,
        ),
      );
    }

    return DawnMasterSet(
      sessionId: sessionId,
      masters: List.unmodifiable(drafted),
      withoutFile: List.unmodifiable(missing),
    );
  }

  /// Why a master row carries no linear FITS, stated from its own status.
  static String _noFileReason(IntegratedMaster master) {
    if (master.status == IntegratedMasterStatus.accumulating) {
      return 'this master is still accumulating; its linear FITS is written '
          'when the accumulation is finalized, so tonight grew the data '
          'without producing a file to draft over';
    }
    return 'this master row records no linear FITS path, so there are no '
        'pixels to render a draft from';
  }
}
