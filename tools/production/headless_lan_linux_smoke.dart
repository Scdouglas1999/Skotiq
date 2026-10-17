import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultExePath =
    'apps/desktop/build/linux/x64/release/bundle/skotiq';
const _adminToken = 'skotiq-smoke-admin-token';
const _viewToken = 'skotiq-smoke-view-token';
const _controlToken = 'skotiq-smoke-control-token';

void main(List<String> args) async {
  if (!Platform.isLinux) {
    stderr.writeln('Linux packaged headless smoke must run on Linux.');
    exit(2);
  }

  final options = _Options.parse(args);
  final exePath = options.exePath;
  final exe = File(exePath);
  if (!exe.existsSync()) {
    stderr.writeln('Release executable not found: $exePath');
    exit(2);
  }

  final port = await _reservePort();
  final processLog = _ProcessLog();
  final process = await Process.start(exe.absolute.path, [
    '--headless',
    '--port=$port',
    '--auth-token=$_adminToken',
    '--view-token=$_viewToken',
    '--control-token=$_controlToken',
  ], workingDirectory: exe.parent.absolute.path);

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

    final info = await _request(client, baseUri, '/api/info');
    _expectStatus('/api/info', info, HttpStatus.ok);
    _expectJsonField('/api/info', info, 'version');
    _expectJsonField('/api/info', info, 'endpoints');
    if (info.json['webUIAvailable'] != true) {
      throw StateError(
        '/api/info webUIAvailable expected true when dashboard is bundled: '
        '${info.text}',
      );
    }

    final unauthSelfTest = await _request(client, baseUri, '/api/self-test');
    _expectStatus(
      'unauthenticated /api/self-test',
      unauthSelfTest,
      HttpStatus.unauthorized,
    );

    final selfTest = await _request(
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

    final openApi = await _request(
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

    final forbiddenControl = await _request(
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

    await _expectWebSocketPong(baseUri, _viewToken);

    if (options.logPath != null) {
      await _writeSmokeLog(
        options.logPath!,
        exe: exe,
        port: port,
        info: info.json,
      );
    }

    stdout.writeln('Packaged headless Linux smoke passed.');
    stdout.writeln('Executable: ${exe.absolute.path}');
    stdout.writeln('Port: $port');
    if (options.logPath != null) {
      stdout.writeln('Log: ${File(options.logPath!).absolute.path}');
    }
  } catch (error, stackTrace) {
    stderr.writeln('Packaged headless Linux smoke failed: $error');
    stderr.writeln(stackTrace);
    stderr.writeln(processLog.render());
    exitCode = 1;
  } finally {
    client.close(force: true);
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
  }

  exit(exitCode == 1 ? 1 : 0);
}

Future<void> _writeSmokeLog(
  String path, {
  required File exe,
  required int port,
  required Map<String, dynamic> info,
}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final timestamp = DateTime.now().toUtc().toIso8601String();
  await file.writeAsString('''$timestamp Skotiq packaged Linux runtime smoke
Executable: ${exe.absolute.path}
Port: $port
Version: ${info['version']}
Platform: ${info['platform']}
PASS headless_process_started
PASS api_info_ok
PASS auth_fail_closed_and_scoped
PASS self_test_ok
PASS openapi_ok
PASS dashboard_asset_ok (HTML, CSS, api.js, app.js)
PASS websocket_ping_pong
PASS packaged_linux_runtime_smoke
''');
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
      final response = await _request(client, baseUri, '/api/info');
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

Future<_HttpResponseBody> _request(
  HttpClient client,
  Uri baseUri,
  String path, {
  String method = 'GET',
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
  return _HttpResponseBody(
    statusCode: response.statusCode,
    contentType: response.headers.value(HttpHeaders.contentTypeHeader) ?? '',
    text: text,
    json: json,
  );
}

void _expectStatus(String label, _HttpResponseBody response, int statusCode) {
  if (response.statusCode != statusCode) {
    throw StateError(
      '$label returned ${response.statusCode}, expected $statusCode: '
      '${response.text}',
    );
  }
}

void _expectJsonField(String label, _HttpResponseBody response, String field) {
  if (!response.json.containsKey(field)) {
    throw StateError('$label missing JSON field "$field": ${response.text}');
  }
}

void _expectRuntimeMetadata(
  _HttpResponseBody info,
  _HttpResponseBody selfTest,
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

Future<void> _expectWebSocketPong(Uri baseUri, String token) async {
  final uri = Uri(
    scheme: 'ws',
    host: baseUri.host,
    port: baseUri.port,
    path: '/events',
    queryParameters: {'token': token},
  );
  final socket = await WebSocket.connect(uri.toString());
  try {
    socket.add(jsonEncode({'type': 'ping'}));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    await for (final message in socket) {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      if (data['type'] == 'pong') {
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for WebSocket pong');
      }
    }
  } finally {
    await socket.close();
  }
}

class _Options {
  final String exePath;
  final String? logPath;

  const _Options({required this.exePath, required this.logPath});

  factory _Options.parse(List<String> args) {
    var exePath = _defaultExePath;
    String? logPath;
    var executableProvided = false;

    for (final arg in args) {
      if (arg.startsWith('--log=')) {
        logPath = arg.substring('--log='.length).trim();
        if (logPath.isEmpty) {
          throw ArgumentError('--log requires a non-empty path');
        }
      } else if (!arg.startsWith('-') && !executableProvided) {
        exePath = arg;
        executableProvided = true;
      } else {
        throw ArgumentError('Unknown argument: $arg');
      }
    }

    return _Options(exePath: exePath, logPath: logPath);
  }
}

class _HttpResponseBody {
  final int statusCode;
  final String contentType;
  final String text;
  final Map<String, dynamic> json;

  const _HttpResponseBody({
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
