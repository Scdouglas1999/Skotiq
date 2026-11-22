/// Map http(s) onto ws(s) and strip trailing slashes so endpoint paths
/// can be appended uniformly. Throws [ArgumentError] on anything else.
Uri normalizeRelayUrl(Uri url) {
  final scheme = switch (url.scheme) {
    'ws' || 'http' => 'ws',
    'wss' || 'https' => 'wss',
    _ => throw ArgumentError.value(
      url,
      'relayUrl',
      'scheme must be ws, wss, http, or https',
    ),
  };
  final path = url.path.replaceAll(RegExp(r'/+$'), '');
  return url.replace(scheme: scheme, path: path);
}
