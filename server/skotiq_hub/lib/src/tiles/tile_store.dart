import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'tile_codec.dart';

/// On-disk store for fused tile accumulators, laid out exactly like the client
/// atlas: `<root>/tiles/<order>/<tileId>.nst`. This is the bulk pixel store; the
/// DB `tile_index` is the queryable summary alongside it.
class TileStore {
  TileStore(this.root);

  /// Atlas root directory. Created on demand.
  final String root;

  String pathFor(int tileId, int order) =>
      p.join(root, 'tiles', '$order', '$tileId.nst');

  bool exists(int tileId, int order) =>
      File(pathFor(tileId, order)).existsSync();

  /// Load the fused accumulator for a tile, or null if the hub has never
  /// received a contribution for it.
  TileAccumulator? load(int tileId, int order) {
    final file = File(pathFor(tileId, order));
    if (!file.existsSync()) return null;
    return TileAccumulator.deserialize(file.readAsBytesSync());
  }

  /// Read the raw `.nst` bytes for a tile (for the `finalized=false` download
  /// path), or null if absent.
  Uint8List? loadBytes(int tileId, int order) {
    final file = File(pathFor(tileId, order));
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
  }
}
