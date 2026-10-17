/// Returns a URL projection suitable for status screens and remote APIs.
///
/// Operational endpoints may contain user-info, signed query parameters, or
/// fragments. Those components are never needed to identify the destination
/// to an operator and can contain credentials, so only origin and path are
/// retained. Invalid or non-network URLs produce an empty string.
String sanitizeEndpointForDisplay(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}
