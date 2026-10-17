/// Builds a URI for a Skotiq host without relying on string
/// interpolation. In particular, [Uri] adds the brackets required around an
/// IPv6 literal when it appears in an authority.
Uri buildSkotiqServerUri({
  required String scheme,
  required String host,
  required int port,
  required String pathAndQuery,
}) {
  final relative = Uri.parse(pathAndQuery);
  if (relative.hasScheme || relative.hasAuthority || relative.hasFragment) {
    throw ArgumentError.value(
      pathAndQuery,
      'pathAndQuery',
      'must be a path with an optional query',
    );
  }

  final normalizedHost = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  final path = relative.path.isEmpty
      ? ''
      : (relative.path.startsWith('/') ? relative.path : '/${relative.path}');
  return Uri(
    scheme: scheme,
    host: normalizedHost,
    port: port,
    path: path,
    query: relative.hasQuery ? relative.query : null,
  );
}
