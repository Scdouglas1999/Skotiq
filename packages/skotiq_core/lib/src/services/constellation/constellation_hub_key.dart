/// Normalize a hub base URL to the stable `scheme://host[:port]` key.
///
/// This value is a **join key** across three tables written by three different
/// services: Constellation tile receipts (`constellation_contributions`),
/// co-imaging memberships, and the `sourceHubKey` stamped on a folded shared
/// calibration record. One hub must produce one key everywhere, or rows written
/// by one service silently fail to join rows written by another — so there is
/// exactly one implementation, and every writer calls it.
///
/// Path, query, and userinfo are deliberately dropped: a hub mounted under a
/// path prefix is still the same hub, and a token rotation must not orphan the
/// rows recorded before it.
String constellationHubKey(Uri hubBaseUrl) {
  final port = hubBaseUrl.hasPort ? ':${hubBaseUrl.port}' : '';
  return '${hubBaseUrl.scheme}://${hubBaseUrl.host}$port';
}
