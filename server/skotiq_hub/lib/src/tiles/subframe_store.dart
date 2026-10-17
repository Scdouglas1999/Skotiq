import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// On-disk store for raw FITS subframes (the opt-in `acceptsRawSubs` path).
///
/// Unlike [TileStore], which fuses additive sums into one accumulator per tile,
/// every raw subframe is kept as its own immutable file so a single-frame
/// retraction is an exact file-delete (raw subs cannot be cleanly subtracted
/// the way additive sums can). Layout mirrors the contract:
///
///   `<root>/subframes/<accountId>/<order>/<tileId>/<contributionId>.fits`
///
/// The DB `raw_subframe_contributions` table is the queryable ledger alongside
/// this bulk store.
class SubframeStore {
  SubframeStore(this.root);

  /// Atlas root directory. Created on demand.
  final String root;

  String dirFor(String accountId, int tileId, int order) =>
      p.join(root, 'subframes', accountId, '$order', '$tileId');

  String pathFor(
    String accountId,
    int tileId,
    int order,
    String contributionId,
  ) => p.join(dirFor(accountId, tileId, order), '$contributionId.fits');

  /// Persist [bytes] as the raw subframe for [contributionId]. Writes to a temp
  /// file in the same directory then renames, so a crash mid-write never leaves
  /// a torn FITS. Returns the absolute path written.
  String save({
    required String accountId,
    required int tileId,
    required int order,
    required String contributionId,
    required Uint8List bytes,
  }) {
    final dest = pathFor(accountId, tileId, order, contributionId);
    final dir = Directory(p.dirname(dest));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('$dest.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(dest);
    return dest;
  }

  /// Read a stored subframe's bytes, or null if the file is gone.
  Uint8List? load(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  }

  /// Delete a stored subframe file (idempotent). Returns true if a file was
  /// removed. The empty `<tileId>` directory is pruned best-effort so a churned
  /// account does not leave a litter of empty dirs.
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
