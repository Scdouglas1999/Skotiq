import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultExePath =
    'apps/desktop/build/windows/x64/runner/Release/skotiq.exe';
const _adminToken = 'skotiq-smoke-admin-token';
const _viewToken = 'skotiq-smoke-view-token';
const _controlToken = 'skotiq-smoke-control-token';

void main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('Windows packaged headless smoke must run on Windows.');
    exit(2);
  }

  final exePath = args.isEmpty ? _defaultExePath : args.first;
  final exe = File(exePath);
  if (!exe.existsSync()) {
    stderr.writeln('Release executable not found: $exePath');
    exit(2);
  }

  final port = await _reservePort();
  final scratch = await Directory.systemTemp.createTemp(
    'skotiq-windows-smoke-',
  );
  final data = await Directory('${scratch.path}/data').create();
  final captures = await Directory('${scratch.path}/captures').create();
  final processLog = _ProcessLog();
  final process = await Process.start(
    exe.absolute.path,
    [
      '--headless',
      '--port=$port',
      '--auth-token=$_adminToken',
      '--view-token=$_viewToken',
      '--control-token=$_controlToken',
    ],
    workingDirectory: exe.parent.absolute.path,
    environment: {
      'SKOTIQ_DATABASE_DIR': data.path,
      'SKOTIQ_DATA_DIR': data.path,
      'SKOTIQ_BROWSE_ROOTS': 'Smoke=${captures.path}',
    },
  );

  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(processLog.addStdout);
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(processLog.addStderr);

  var exited = false;
  int? exitCode;
  unawaited(
    process.exitCode.then((code) {
      exited = true;
      exitCode = code;
    }),
  );

  final client = HttpClient();
  final baseUri = Uri.parse('http://127.0.0.1:$port');

  try {
    await _waitForServer(client, baseUri, () => exited, () => exitCode);

    final info = await requestSmokeJson(client, baseUri, '/api/info');
    _expectStatus('/api/info', info, HttpStatus.ok);
    _expectJsonField('/api/info', info, 'version');
    _expectJsonField('/api/info', info, 'endpoints');

    final unauthSelfTest = await requestSmokeJson(
      client,
      baseUri,
      '/api/self-test',
    );
    _expectStatus(
      'unauthenticated /api/self-test',
      unauthSelfTest,
      HttpStatus.unauthorized,
    );

    final selfTest = await requestSmokeJson(
      client,
      baseUri,
      '/api/self-test',
      token: _adminToken,
    );
    _expectStatus('/api/self-test', selfTest, HttpStatus.ok);
    _expectJsonField('/api/self-test', selfTest, 'platform');
    _expectJsonField('/api/self-test', selfTest, 'server');
    _expectJsonField('/api/self-test', selfTest, 'api');
    _expectRuntimeMetadata(info, selfTest);

    final openApi = await requestSmokeJson(
      client,
      baseUri,
      '/api/openapi.json',
      token: _viewToken,
    );
    _expectStatus('/api/openapi.json view token', openApi, HttpStatus.ok);
    if (openApi.json['openapi'] != '3.0.3') {
      throw StateError(
        'Unexpected OpenAPI version: ${openApi.json['openapi']}',
      );
    }

    final forbiddenControl = await requestSmokeJson(
      client,
      baseUri,
      '/api/camera/expose',
      method: 'POST',
      token: _viewToken,
      body: const {'deviceId': 'camera-1'},
    );
    _expectStatus(
      'view token control rejection',
      forbiddenControl,
      HttpStatus.forbidden,
    );

    await _expectTextAsset(client, baseUri, '/dashboard', 'text/html');
    await _expectTextAsset(
      client,
      baseUri,
      '/dashboard/css/dashboard.css',
      'text/css',
    );
    await _expectTextAsset(
      client,
      baseUri,
      '/dashboard/js/api.js',
      'application/javascript',
    );
    await _expectTextAsset(
      client,
      baseUri,
      '/dashboard/js/app.js',
      'application/javascript',
    );

    await expectSmokeWebSocketPong(baseUri, _viewToken);
    await _expectSimulatorCapture(client, baseUri, captures);

    stdout.writeln('Packaged headless Windows smoke passed.');
    stdout.writeln('Executable: ${exe.absolute.path}');
    stdout.writeln('Port: $port');
    stdout.writeln('Scratch evidence: ${scratch.path}');
  } catch (error, stackTrace) {
    stderr.writeln('Packaged headless Windows smoke failed: $error');
    stderr.writeln(stackTrace);
    stderr.writeln(processLog.render());
    stderr.writeln('Scratch evidence: ${scratch.path}');
    exitCode = 1;
  } finally {
    client.close(force: true);
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5));
    }
  }

  exit(exitCode == 1 ? 1 : 0);
}

Future<int> _reservePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitForServer(
  HttpClient client,
  Uri baseUri,
  bool Function() hasExited,
  int? Function() exitCode,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    if (hasExited()) {
      throw StateError('Headless process exited early with code ${exitCode()}');
    }
    try {
      final response = await requestSmokeJson(client, baseUri, '/api/info');
      if (response.statusCode == HttpStatus.ok) {
        return;
      }
      lastError = 'HTTP ${response.statusCode}';
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException('Timed out waiting for /api/info: $lastError');
}

Future<SmokeHttpResponse> requestSmokeJson(
  HttpClient client,
  Uri baseUri,
  String path, {
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
  Duration timeout = const Duration(seconds: 30),
}) => _requestJson(
  client,
  baseUri,
  path,
  method: method,
  token: token,
  body: body,
).timeout(timeout);

Future<SmokeHttpResponse> _requestJson(
  HttpClient client,
  Uri baseUri,
  String path, {
  required String method,
  String? token,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, baseUri.resolve(path));
  request.headers.contentType = ContentType.json;
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final json = text.isEmpty
      ? const <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
  return SmokeHttpResponse(
    statusCode: response.statusCode,
    contentType: response.headers.value(HttpHeaders.contentTypeHeader) ?? '',
    text: text,
    json: json,
  );
}

void _expectStatus(String label, SmokeHttpResponse response, int statusCode) {
  if (response.statusCode != statusCode) {
    throw StateError(
      '$label returned ${response.statusCode}, expected $statusCode: '
      '${response.text}',
    );
  }
}

void _expectJsonField(String label, SmokeHttpResponse response, String field) {
  if (!response.json.containsKey(field)) {
    throw StateError('$label missing JSON field "$field": ${response.text}');
  }
}

void _expectRuntimeMetadata(
  SmokeHttpResponse info,
  SmokeHttpResponse selfTest,
) {
  final server = selfTest.json['server'] as Map<String, dynamic>;
  if (server['authMode'] != 'token') {
    throw StateError('Expected token auth mode, got ${server['authMode']}');
  }
  if (server['authRequired'] != true) {
    throw StateError(
      'Expected authRequired=true, got ${server['authRequired']}',
    );
  }

  final scopes = (server['authScopes'] as List).cast<String>();
  for (final scope in const ['admin', 'control', 'view']) {
    if (!scopes.contains(scope)) {
      throw StateError('Missing auth scope "$scope": $scopes');
    }
  }

  final api = selfTest.json['api'] as Map<String, dynamic>;
  final endpointCount = api['endpointCount'];
  final advertisedEndpoints = (info.json['endpoints'] as List).length;
  if (endpointCount != advertisedEndpoints) {
    throw StateError(
      'Self-test endpointCount $endpointCount did not match '
      '/api/info endpoint count $advertisedEndpoints',
    );
  }
}

Future<void> _expectTextAsset(
  HttpClient client,
  Uri baseUri,
  String path,
  String contentTypePrefix,
) async {
  await _readTextAsset(
    client,
    baseUri,
    path,
    contentTypePrefix,
  ).timeout(const Duration(seconds: 10));
}

Future<void> _readTextAsset(
  HttpClient client,
  Uri baseUri,
  String path,
  String contentTypePrefix,
) async {
  final request = await client.getUrl(baseUri.resolve(path));
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  final contentType =
      response.headers.value(HttpHeaders.contentTypeHeader) ?? '';

  if (response.statusCode != HttpStatus.ok) {
    throw StateError('$path returned ${response.statusCode}: $body');
  }
  if (!contentType.startsWith(contentTypePrefix)) {
    throw StateError(
      '$path content-type "$contentType" did not start with '
      '"$contentTypePrefix"',
    );
  }
  if (body.isEmpty) {
    throw StateError('$path returned an empty body');
  }
}

Future<void> expectSmokeWebSocketPong(
  Uri baseUri,
  String token, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final uri = Uri(
    scheme: 'ws',
    host: baseUri.host,
    port: baseUri.port,
    path: '/events',
    queryParameters: {'token': token},
  );
  final socket = await WebSocket.connect(uri.toString()).timeout(timeout);
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

Future<void> _expectSimulatorCapture(
  HttpClient client,
  Uri baseUri,
  Directory captures,
) async {
  // The id is explicit: discovery is never needed to connect a simulator.
  const camera = {'deviceId': 'sim_camera_1', 'deviceType': 'camera'};
  final connected = await requestSmokeJson(
    client,
    baseUri,
    '/api/devices/connect',
    method: 'POST',
    token: _adminToken,
    body: camera,
  );
  _expectStatus('simulator connect', connected, HttpStatus.ok);
  if (connected.json['status'] != 'connected') {
    throw StateError('Simulator did not connect: ${connected.text}');
  }
  try {
    final capturedAt = DateTime.now().toUtc();
    final exposure = await requestSmokeJson(
      client,
      baseUri,
      '/api/camera/expose',
      method: 'POST',
      token: _adminToken,
      body: {
        'deviceId': camera['deviceId'],
        'exposureTime': 0.01,
        'frameType': 'light',
        'binX': 1,
        'binY': 1,
        'x': 0,
        'y': 0,
        'width': 128,
        'height': 96,
      },
    );
    _expectStatus('simulator exposure', exposure, HttpStatus.ok);
    if (exposure.json['status'] != 'complete') {
      throw StateError('Simulator exposure did not finish: ${exposure.text}');
    }
    final fits = File('${captures.path}/simulator.fits');
    final saved = await requestSmokeJson(
      client,
      baseUri,
      '/api/imaging/save-fits-from-capture',
      method: 'POST',
      token: _adminToken,
      body: {
        'deviceId': camera['deviceId'],
        'filePath': fits.absolute.path,
        'keepCameraFile': false,
        'headerData': {
          'objectName': 'Windows smoke simulator',
          'exposureTime': 0.01,
          'captureTimestamp': capturedAt.toIso8601String(),
          'frameType': 'Light',
          'binX': 1,
          'binY': 1,
        },
      },
    );
    _expectStatus('simulator FITS save', saved, HttpStatus.ok);
    if (saved.json['status'] != 'saved' || !await fits.exists()) {
      throw StateError('Simulator FITS was not saved: ${saved.text}');
    }
    final header = validateSmokeFits(await fits.readAsBytes());
    stdout.writeln('Simulator capture verified: ${jsonEncode(header)}');
    stdout.writeln(
      'FITS evidence: ${fits.path} (${await fits.length()} bytes)',
    );
  } finally {
    final disconnected = await requestSmokeJson(
      client,
      baseUri,
      '/api/devices/disconnect',
      method: 'POST',
      token: _adminToken,
      body: camera,
    );
    _expectStatus('simulator disconnect', disconnected, HttpStatus.ok);
  }
}

/// Checks the small monochrome fixture's actual file, not API success alone.
Map<String, String> validateSmokeFits(List<int> bytes) {
  final header = <String, String>{};
  int? dataOffset;
  for (var offset = 0; offset + 80 <= bytes.length; offset += 80) {
    final card = ascii.decode(bytes.sublist(offset, offset + 80));
    final key = card.substring(0, 8).trim();
    if (key == 'END') {
      dataOffset = ((offset + 80 + 2879) ~/ 2880) * 2880;
      break;
    }
    if (card[8] == '=') {
      var value = card.substring(10).split('/').first.trim();
      if (value.startsWith("'") && value.endsWith("'")) {
        value = value.substring(1, value.length - 1).trimRight();
      }
      header[key] = value;
    }
  }
  const expected = {
    'SIMPLE': 'T',
    'BITPIX': '16',
    'NAXIS': '2',
    'NAXIS1': '128',
    'NAXIS2': '96',
    'OBJECT': 'Windows smoke simulator',
  };
  for (final entry in expected.entries) {
    if (header[entry.key] != entry.value) {
      throw StateError(
        'FITS ${entry.key}: ${header[entry.key]}, '
        'expected ${entry.value}',
      );
    }
  }
  if (double.tryParse(header['EXPTIME'] ?? '') != 0.01 ||
      DateTime.tryParse(header['DATE-OBS'] ?? '') == null) {
    throw StateError('FITS capture metadata is missing or incorrect: $header');
  }
  if (dataOffset == null || bytes.length < dataOffset + 128 * 96 * 2) {
    throw StateError('FITS pixel payload is missing or truncated');
  }
  return header;
}

class SmokeHttpResponse {
  final int statusCode;
  final String contentType;
  final String text;
  final Map<String, dynamic> json;

  const SmokeHttpResponse({
    required this.statusCode,
    required this.contentType,
    required this.text,
    required this.json,
  });
}

class _ProcessLog {
  final _stdout = <String>[];
  final _stderr = <String>[];

  void addStdout(String line) => _addBounded(_stdout, line);
  void addStderr(String line) => _addBounded(_stderr, line);

  String render() {
    return [
      '--- process stdout ---',
      ..._stdout,
      '--- process stderr ---',
      ..._stderr,
    ].join('\n');
  }

  void _addBounded(List<String> lines, String line) {
    lines.add(line);
    if (lines.length > 200) {
      lines.removeAt(0);
    }
  }
}
