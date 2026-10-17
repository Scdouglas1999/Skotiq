import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// On-disk store for collaborative-mosaic panel masters and the finished
/// stitched output.
///
/// Mirrors [SubframeStore] / [CalibrationMasterStore]: every blob is kept as
/// its own immutable file written via temp-then-rename, so a crash mid-write
/// never leaves a torn FITS a later download could hand a puller. The queryable
/// metadata (claim/upload state, provenance) lives alongside in the
/// `collaborative_mosaic_panels` / `collaborative_mosaics` DB tables.
///
/// Panel masters are SPATIALLY-DISJOINT sky regions, not additive same-tile
/// sums, so they are NOT routed through [TileStore]/[FusionService] (whose
/// `mergeSigned` co-add is wrong for disjoint panels) — each is just a stored
/// blob. Layout:
///
///   `<root>/mosaics/<mosaicId>/panels/<panelIndex>/<masterId>.fits`
///   `<root>/mosaics/<mosaicId>/output/<masterId>.fits`
class MosaicMasterStore {
  MosaicMasterStore(this.root);

  /// Atlas root directory. Created on demand.
  final String root;

  String panelDir(String mosaicId, int panelIndex) =>
      p.join(root, 'mosaics', mosaicId, 'panels', '$panelIndex');

  String panelPath(String mosaicId, int panelIndex, String masterId) =>
      p.join(panelDir(mosaicId, panelIndex), '$masterId.fits');

  String outputDir(String mosaicId) =>
      p.join(root, 'mosaics', mosaicId, 'output');

  String outputPath(String mosaicId, String masterId) =>
      p.join(outputDir(mosaicId), '$masterId.fits');

  /// Persist [bytes] as a panel master for `(mosaicId, panelIndex)` under
  /// [masterId]. Writes to a temp file in the same directory then renames.
  /// Returns the absolute path written.
  String savePanelMaster({
    required String mosaicId,
    required int panelIndex,
    required String masterId,
    required Uint8List bytes,
  }) => _saveAt(panelPath(mosaicId, panelIndex, masterId), bytes);

  /// Persist [bytes] as the finished stitched mosaic output under [masterId].
  /// Returns the absolute path written.
  String saveOutput({
    required String mosaicId,
    required String masterId,
    required Uint8List bytes,
  }) => _saveAt(outputPath(mosaicId, masterId), bytes);

  String _saveAt(String dest, Uint8List bytes) {
    final dir = Directory(p.dirname(dest));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('$dest.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(dest);
    return dest;
  }

  /// Read a stored blob's bytes, or null when the file is gone.
  Uint8List? load(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  }

  /// Delete a stored blob file (idempotent). Returns whether a file was removed.
  /// Prunes the now-empty parent directory best-effort.
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
