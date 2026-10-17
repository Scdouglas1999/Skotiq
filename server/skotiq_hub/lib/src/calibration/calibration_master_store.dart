import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// On-disk store for the shared calibration library's master FITS files.
///
/// Mirrors [SubframeStore]: every published master is kept as its own immutable
/// file so a publish/retract is an exact file write/delete, with the queryable
/// metadata living alongside in the `shared_calibration_masters` DB table.
/// Layout:
///
///   `<root>/calibration-masters/<accountId>/<masterId>.fits`
///
/// Files are written via a temp-then-rename so a crash mid-write never leaves a
/// torn master that a later download could hand a puller.
class CalibrationMasterStore {
  CalibrationMasterStore(this.root);

  /// Atlas root directory. Created on demand.
  final String root;

  String dirFor(String accountId) =>
      p.join(root, 'calibration-masters', accountId);

  String pathFor(String accountId, String masterId) =>
      p.join(dirFor(accountId), '$masterId.fits');

  /// Persist [bytes] as the master file for [masterId] owned by [accountId].
  /// Writes to a temp file in the same directory then renames. Returns the
  /// absolute path written.
  String save({
    required String accountId,
    required String masterId,
    required Uint8List bytes,
  }) {
    final dest = pathFor(accountId, masterId);
    final dir = Directory(p.dirname(dest));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('$dest.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(dest);
    return dest;
  }

  /// Read a stored master's bytes, or null when the file is gone.
  Uint8List? load(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  }

  /// Delete a stored master file (idempotent). Returns whether a file was
  /// removed. Prunes the now-empty account directory best-effort.
  bool delete(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    file.deleteSync();
    final dir = file.parent;
    try {
      if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
    } on FileSystemException {
      // A concurrent writer re-populated the dir; harmless.
    }
    return true;
  }
}
