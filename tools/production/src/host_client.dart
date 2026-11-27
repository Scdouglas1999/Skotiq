import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'version_file.dart';

/// The release this tree builds, from `version.yaml` in the working directory
/// (the repository root, where the smoke tools run). A host refuses an API
/// request or an event socket that does not name it.
final String skotiqRelease = () {
  final version = VersionFile.parse(
    File('version.yaml').readAsStringSync(),
  ).version;
  if (version == null) {
    throw const FormatException('Missing release in version.yaml');
  }
  return version;
}();

/// Names this release on [request], marks the body as JSON and, with a
/// [token], presents it as the bearer.
void setHostHeaders(HttpClientRequest request, {String? token}) {
  request.headers.set('x-skotiq-version', skotiqRelease);
  request.headers.contentType = ContentType.json;
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
}

/// The host's event socket for [token], on the host at [baseUri].
Uri hostEventsUri(Uri baseUri, String token) => Uri(
  scheme: 'ws',
  host: baseUri.host,
  port: baseUri.port,
  path: '/events',
  queryParameters: {'token': token, 'version': skotiqRelease},
);

/// Opens the event socket, sends a ping and waits for the pong. Fails when
/// the socket closes first, and times out after [timeout] at each step.
Future<void> expectEventsPong(
  Uri baseUri,
  String token, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final socket = await WebSocket.connect(
    hostEventsUri(baseUri, token).toString(),
  ).timeout(timeout);
  try {
    socket.add(jsonEncode({'type': 'ping'}));
    await socket
        .firstWhere((message) {
          final data = jsonDecode(message as String) as Map<String, dynamic>;
          return data['type'] == 'pong';
        })
        .timeout(timeout);
  } finally {
    await socket.close().timeout(timeout);
  }
}
