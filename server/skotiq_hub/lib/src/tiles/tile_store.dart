import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'tile_codec.dart';

/// On-disk store for fused tile accumulators, laid out exactly like the client
/// atlas: `<root>/tiles/<order>/<tileId>.skt`. This is the bulk pixel store; the
/// DB `tile_index` is the queryable summary alongside it.
class TileStore {
  TileStore(this.root);

  /// Atlas root directory. Created on demand.
  final String root;

  String pathFor(int tileId, int order) =>
      p.join(root, 'tiles', '$order', '$tileId.skt');

  /// Path a tile's sidecar had before the rebrand's `.skt` rename.
  String _legacyPathFor(int tileId, int order) =>
      p.join(root, 'tiles', '$order', '$tileId.nst');

  /// The sidecar file on disk for a tile, current `.skt` preferred and the
  /// pre-rename `.nst` as fallback so a hub upgrading mid-life keeps serving
  /// the depth it already fused.
  File _fileFor(int tileId, int order) {
    final current = File(pathFor(tileId, order));
    if (current.existsSync()) return current;
    return File(_legacyPathFor(tileId, order));
  }

  bool exists(int tileId, int order) => _fileFor(tileId, order).existsSync();

  /// Load the fused accumulator for a tile, or null if the hub has never
  /// received a contribution for it.
  TileAccumulator? load(int tileId, int order) {
    final file = _fileFor(tileId, order);
    if (!file.existsSync()) return null;
    return TileAccumulator.deserialize(file.readAsBytesSync());
  }

  /// Read the raw `.skt` bytes for a tile (for the `finalized=false` download
  /// path), or null if absent.
  Uint8List? loadBytes(int tileId, int order) {
    final file = _fileFor(tileId, order);
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  }

  /// Atomically persist [tile]: write to a temp file in the same directory then
  /// rename, so a crash mid-write never leaves a torn sidecar.
  void save(TileAccumulator tile) {
    final dest = pathFor(tile.tileId, tile.order);
    final dir = Directory(p.dirname(dest));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('$dest.tmp');
    tmp.writeAsBytesSync(tile.serialize(), flush: true);
    tmp.renameSync(dest);
    // Migrate on write: the sidecar now lives at its `.skt` path, so a
    // pre-rename `.nst` twin would only duplicate it.
    final legacy = File(_legacyPathFor(tile.tileId, tile.order));
    if (legacy.existsSync()) legacy.deleteSync();
  }
}
