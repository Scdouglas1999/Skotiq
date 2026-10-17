part of '../constellation_service.dart';

/// Default age a cached swarm `.nst`/`.fits` blob may reach before
/// [sweepSwarmBlobs] reclaims it. A blob older than this that is not the live
/// overlay for a currently-pulled tile is stale working set, safe to delete
/// (a later pull re-fetches it).
const Duration _defaultSwarmBlobMaxAge = Duration(days: 14);

ConstellationClient _defaultClientFactory(ConstellationCredentials c) =>
    ConstellationClient(hubBaseUrl: c.hubBaseUrl, bearerToken: c.bearerToken);

/// Default browse: `GET /v1/targets` returning a `targets` array. Tolerates a
/// bare array body too, so a minimal hub need only return the list.
Future<List<SharedTarget>> _defaultBrowser(ConstellationClient client) async {
  final raw = await client.browseRaw();
  final list = raw is List
      ? raw
      : (raw is Map<String, dynamic>
            ? (raw['targets'] as List? ?? const [])
            : const []);
  return list
      .whereType<Map<String, dynamic>>()
      .map(SharedTarget.fromJson)
      .toList(growable: false);
}

/// Map a hub target id to the NEGATIVE `tileId` its join-rehydration row uses,
/// keeping join rows in a key space disjoint from real (non-negative HEALPix)
/// tile receipts. The `-1` offset keeps target id 0 strictly negative.
int _joinRowKey(int targetId) => -targetId - 1;
