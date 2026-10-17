/// Delivery to any local or already-mounted path — the NAS/SMB/NFS case the
/// operating system has already solved.
///
/// Config (`delivery_targets.config_json`):
///
/// ```json
/// {"path": "/mnt/nas/skotiq", "minFreeBytes": 1073741824,
///  "rigId": "shed-rig"}
/// ```
///
/// `minFreeBytes` is the headroom left after the night's copy; it defaults to
/// [kDefaultWatchedFolderHeadroomBytes]. `rigId` is the rig-identity component
/// every delivered name carries so two rigs writing into one share do not
/// collide — see [DeliveryNaming].
///
/// The destination directory is never created. A path that is missing is
/// reported as unreachable and retried, because the overwhelmingly likely
/// cause is a network share that is not mounted yet — and creating it would
/// turn an unmounted NAS mountpoint into a local directory that quietly fills
/// the boot drive with gigabytes of masters.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/darkroom/delivery.dart';
import '../disk_space_service.dart';
import 'artifact_transport.dart';
import 'atomic_file_write.dart';
import 'delivery_artifact.dart';
import 'delivery_failure.dart';
import 'delivery_naming.dart';

/// Free space left on the destination after a night's delivery, when the
/// destination row does not name its own figure.
const int kDefaultWatchedFolderHeadroomBytes = 1024 * 1024 * 1024;

/// How free space on a destination filesystem is measured.
///
/// [DiskSpaceService] shells out to `df` / `Get-PSDrive`, which a unit test
/// cannot make report a full disk. The transport therefore takes this seam and
/// the production wiring passes [SystemFreeSpaceProbe].
abstract class FreeSpaceProbe {
  /// Bytes currently free on the filesystem holding [path].
  Future<int> freeBytes(String path);
}

/// [FreeSpaceProbe] backed by the existing [DiskSpaceService].
class SystemFreeSpaceProbe implements FreeSpaceProbe {
  final DiskSpaceService _service;

  SystemFreeSpaceProbe([DiskSpaceService? service])
    : _service = service ?? DiskSpaceService();

  @override
  Future<int> freeBytes(String path) async {
    final info = await _service.query(path);
    return info.freeBytes;
  }
}

/// Copies artifacts into a watched folder, one atomic file at a time.
class WatchedFolderTransport implements ArtifactTransport {
  /// The destination row this transport serves.
  final ArtifactDestination destination;

  /// The job whose artifacts are being delivered; names the staged files.
  final int jobId;

  final FreeSpaceProbe _freeSpace;

  Directory? _root;
  DeliveryNaming? _naming;

  WatchedFolderTransport({
    required this.destination,
    required this.jobId,
    FreeSpaceProbe? freeSpace,
  }) : _freeSpace = freeSpace ?? SystemFreeSpaceProbe();

  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.watchedFolder;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {
    final config = _decodeConfig();
    final naming = DeliveryNaming.of(config);
    final path = config['path'];
    if (path is! String || path.trim().isEmpty) {
      throw const DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'This watched-folder destination names no path to write to',
      );
    }

    final root = Directory(path.trim());
    // What is at that path, not merely whether a DIRECTORY is. `exists()` is
    // false for a path holding a file, so a destination pointed at a file —
    // the share's mountpoint replaced by a stub, a path typed one component
    // short — reported "not on the filesystem right now" about something that
    // plainly is, and retried it every sweep until the budget ran out. A file
    // does not become a directory by being waited for, so it is stated as what
    // it is and is terminal.
    //
    // `type` follows links, so a link to a live share reads as the directory
    // it points at and a dangling one reads as absent — both the answers the
    // operator means.
    final onDisk = await FileSystemEntity.type(root.path);
    if (onDisk == FileSystemEntityType.notFound) {
      throw DeliveryFailure(
        DeliveryFailureKind.destinationUnreachable,
        '${root.path} is not on the filesystem right now',
      );
    }
    if (onDisk != FileSystemEntityType.directory) {
      throw DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        '${root.path} is on the filesystem but it is a '
        '${_entityWord(onDisk)}, not a folder, so nothing can be delivered '
        'into it. Point this destination at a directory in '
        'Settings > Delivery',
      );
    }

    final headroom = _headroomBytes(config);
    final needed = artifacts.fold<int>(0, (sum, a) => sum + a.bytes) + headroom;
    final int free;
    try {
      free = await _freeSpace.freeBytes(root.path);
    } on DiskSpaceException catch (error) {
      throw DeliveryFailure(
        DeliveryFailureKind.destinationUnreachable,
        'Free space on ${root.path} could not be read: ${error.message}',
        cause: error,
      );
    }
    if (free < needed) {
      throw DeliveryFailure(
        DeliveryFailureKind.insufficientSpace,
        '${root.path} has ${_mb(free)} free; this delivery needs '
        '${_mb(needed)} including ${_mb(headroom)} of headroom',
      );
    }

    _root = root;
    _naming = naming;
  }

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    final root = _root;
    final naming = _naming;
    if (root == null || naming == null) {
      throw const DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'This watched-folder destination was asked to deliver before it was '
        'opened',
      );
    }

    final deliveredName = naming.nameFor(artifact.fileName);
    final existing = File(p.join(root.path, deliveredName));
    if (await existing.exists()) {
      final String onDisk;
      try {
        onDisk = await sha256OfFile(existing);
      } on DeliveryFailure catch (failure) {
        // The file being hashed is the destination's, not the rig's. A share
        // that unmounts between the exists() and the read must not be recorded
        // as the master having vanished — and a file that goes while the share
        // stays must not be recorded as the share having gone.
        throw await destinationReadFailure(
          sourcePath: artifact.sourcePath,
          destinationFile: existing,
          failure: failure,
        );
      }
      if (onDisk == artifact.checksum) {
        // The same bytes are already there — a previous attempt that was
        // interrupted after the rename, or a re-run of the same job. Claiming
        // this as delivered is the truth; rewriting it is not.
        return TransportDeliveryOutcome(
          disposition: DeliveryDisposition.delivered,
          checksum: onDisk,
          destinationDescription: existing.path,
        );
      }
      throw DeliveryFailure(
        DeliveryFailureKind.destinationConflict,
        '${existing.path} already exists with different content '
        '(there: $onDisk, here: ${artifact.checksum}); delivery copies and '
        'never overwrites',
      );
    }

    final staged = await AtomicFileWrite.stage(
      artifact: artifact,
      deliveredName: deliveredName,
      directory: root,
      jobId: jobId,
    );
    await staged.commit();
    return TransportDeliveryOutcome(
      disposition: DeliveryDisposition.delivered,
      checksum: staged.stagedChecksum,
      destinationDescription: staged.finalPath,
    );
  }

  @override
  Future<void> close() async {
    _root = null;
    _naming = null;
  }

  Map<String, Object?> _decodeConfig() =>
      decodeDeliveryConfig(destination, what: 'watched-folder destination');

  int _headroomBytes(Map<String, Object?> config) {
    final configured = config['minFreeBytes'];
    if (configured == null) return kDefaultWatchedFolderHeadroomBytes;
    if (configured is int && configured >= 0) return configured;
    throw DeliveryFailure(
      DeliveryFailureKind.configurationInvalid,
      'minFreeBytes on this destination is $configured, which is not a '
      'non-negative whole number of bytes',
    );
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  /// What sits at a path, in the operator's words.
  ///
  /// Only the non-directory answers are named here — a directory is the case
  /// that never reaches this — and the `notFound` arm exists because
  /// [FileSystemEntityType] carries it, not because the caller can arrive with
  /// it.
  static String _entityWord(FileSystemEntityType type) {
    if (type == FileSystemEntityType.file) return 'file';
    if (type == FileSystemEntityType.link) return 'link';
    if (type == FileSystemEntityType.notFound) return 'absent path';
    return 'device node';
  }
}
