part of '../constellation_service.dart';

extension _ConstellationServiceInternals on ConstellationService {
  /// Open a client for the configured hub, or null when no hub is configured.
  /// Callers that require a hub use [_requireClient].
  Future<ConstellationClient?> _client() async {
    final creds = await _credentialsResolver();
    if (creds == null) return null;
    return _clientFactory(creds);
  }

  Future<ConstellationClient> _requireClient() async {
    final client = await _client();
    if (client == null) {
      throw const ConstellationException(
        'No Constellation hub is configured. Sign in to a hub first.',
        kind: ConstellationErrorKind.auth,
      );
    }
    return client;
  }

  /// Persist (or clear) the join-rehydration row for [target] on the configured
  /// hub. Best-effort: a missing DAO / no-hub / write failure is swallowed (the
  /// in-memory join already took effect; only restart-survival is lost).
  Future<void> _persistJoin(SharedTarget target, {required bool joined}) async {
    final dao = _contributions;
    if (dao == null) return;
    try {
      final creds = await _credentialsResolver();
      if (creds == null) return;
      await dao.upsertJoined(
        constellationHubKey(creds.hubBaseUrl),
        _joinRowKey(target.targetId),
        joined: joined,
        targetName: target.name,
        targetRaDeg: target.raDeg,
        targetDecDeg: target.decDeg,
      );
    } catch (e, st) {
      _logger.debug(
        'persistJoin(#${target.targetId}, joined:$joined) failed '
        '(non-fatal): $e\n$st',
        source: ConstellationService._logSource,
      );
    }
  }

  /// The hub tile a target's raw subframes should be attributed to: the deepest
  /// local tile in the cone, else the joined target's advertised active tile.
  Future<int?> _representativeTileId({
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    required SharedTarget? joined,
  }) async {
    final tiles = await _localTilesInCone(
      centerRaDeg: centerRaDeg,
      centerDecDeg: centerDecDeg,
      radiusDeg: radiusDeg,
    );
    if (tiles.isNotEmpty) {
      tiles.sort(
        (a, b) => b.integrationSeconds.compareTo(a.integrationSeconds),
      );
      return tiles.first.tileId;
    }
    return joined?.activeTileId;
  }

  // Internals

  /// Resolve a target's sky centre from the joined hub row, falling back to the
  /// local target table when the hub did not advertise coordinates.
  Future<({double raDeg, double decDeg})> _targetCenter(
    int targetId,
    SharedTarget? joined,
  ) async {
    if (joined != null && (joined.raDeg != 0.0 || joined.decDeg != 0.0)) {
      return (raDeg: joined.raDeg, decDeg: joined.decDeg);
    }
    final locals = await _localTargetsResolver();
    for (final t in locals) {
      if (t.targetId == targetId) {
        return (raDeg: t.raDeg, decDeg: t.decDeg);
      }
    }
    throw ConstellationException(
      'Cannot resolve sky coordinates for target #$targetId — '
      'join it or add it to the local catalog first.',
      kind: ConstellationErrorKind.notFound,
    );
  }

  /// Local atlas tiles whose centre falls within [radiusDeg] of the cone centre.
  ///
  /// Delegates to [SkyAtlasService.tilesInCone], which prefilters on the indexed
  /// Dec band (`idx_sky_tiles_dec`) before the exact great-circle test, so a
  /// Contribute/Pull cone read costs scale with the cone — not the whole atlas
  /// — instead of materializing every tile ever imaged and filtering in Dart.
  Future<List<AtlasTileCoverage>> _localTilesInCone({
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
  }) {
    return _atlas.tilesInCone(
      centerRaDeg: centerRaDeg,
      centerDecDeg: centerDecDeg,
      radiusDeg: radiusDeg,
    );
  }

  Future<List<int>> _localTileIdsInCone({
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
  }) async {
    final tiles = await _localTilesInCone(
      centerRaDeg: centerRaDeg,
      centerDecDeg: centerDecDeg,
      radiusDeg: radiusDeg,
    );
    return tiles.map((t) => t.tileId).toList(growable: false);
  }

  Future<String> _swarmDir() async {
    final root = await _atlas.atlasRoot();
    return '$root/swarm/$_order';
  }

  /// Delete one swarm blob, swallowing a race where it vanished mid-sweep so one
  /// unlucky file cannot sink the whole pass. Returns whether it was removed.
  Future<bool> _deleteSwarmBlob(File file) async {
    try {
      await file.delete();
      return true;
    } on FileSystemException catch (e) {
      _logger.warning(
        'sweepSwarmBlobs: could not delete ${file.path}: ${e.message}',
        source: ConstellationService._logSource,
      );
      return false;
    }
  }
}
