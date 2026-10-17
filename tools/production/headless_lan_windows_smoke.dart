import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultExePath =
    'apps/desktop/build/windows/x64/runner/Release/skotiq.exe';
const _adminToken = 'skotiq-lan-smoke-admin-token';
const _viewToken = 'skotiq-lan-smoke-view-token';
const _controlToken = 'skotiq-lan-smoke-control-token';

void main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('Windows packaged LAN smoke must run on Windows.');
    exit(2);
  }

  final exePath = args.isEmpty ? _defaultExePath : args.first;
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

  final exitTracker = _ExitTracker(process);
  final client = HttpClient();
  final loopbackUri = Uri.parse('http://127.0.0.1:$port');
  var exitCode = 0;

  try {
    await _waitForServer(
      client,
      loopbackUri,
      exitTracker.hasExited,
      exitTracker.exitCode,
    );

    final lanBaseUri = await _findReachableLanUri(client, port);
    final info = await _request(client, lanBaseUri, '/api/info');
    _expectStatus('/api/info over LAN address', info, HttpStatus.ok);
    if (info.json['authRequired'] != true) {
      throw StateError('/api/info did not report authRequired=true');
    }

    final unauthSelfTest = await _request(client, lanBaseUri, '/api/self-test');
    _expectStatus(
      'unauthenticated /api/self-test over LAN address',
      unauthSelfTest,
      HttpStatus.unauthorized,
    );

    final selfTest = await _request(
      client,
      lanBaseUri,
      '/api/self-test',
      token: _adminToken,
    );
    _expectStatus('/api/self-test over LAN address', selfTest, HttpStatus.ok);
    final server = selfTest.json['server'] as Map<String, dynamic>;
    if (server['bindMode'] != 'lan') {
      throw StateError('Expected self-test bindMode=lan, got $server');
    }
    if (server['authMode'] != 'token') {
      throw StateError('Expected token auth mode, got ${server['authMode']}');
    }

    final forbiddenControl = await _request(
      client,
      lanBaseUri,
      '/api/camera/expose',
      method: 'POST',
      token: _viewToken,
      body: const {'deviceId': 'camera-1'},
    );
    _expectStatus(
      'view token control rejection over LAN address',
      forbiddenControl,
      HttpStatus.forbidden,
    );

    await _expectTextAsset(client, lanBaseUri, '/dashboard', 'text/html');
    await _expectTextAsset(
      client,
      lanBaseUri,
      '/dashboard/css/dashboard.css',
      'text/css',
    );
    await _expectTextAsset(
      client,
      lanBaseUri,
      '/dashboard/js/api.js',
      'application/javascript',
    );
    await _expectTextAsset(
      client,
      lanBaseUri,
      '/dashboard/js/app.js',
      'application/javascript',
    );

    await _expectWebSocketPong(lanBaseUri, _viewToken);

    stdout.writeln('Packaged headless Windows LAN smoke passed.');
    stdout.writeln('Executable: ${exe.absolute.path}');
    stdout.writeln('LAN URL: $lanBaseUri');
  } catch (error, stackTrace) {
    exitCode = 1;
    stderr.writeln('Packaged headless Windows LAN smoke failed: $error');
    stderr.writeln(stackTrace);
    stderr.writeln(processLog.render());
  } finally {
    client.close(force: true);
    process.kill();
    await _waitForExit(process);
  }

  exit(exitCode);
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

Future<Uri> _findReachableLanUri(HttpClient client, int port) async {
  final addresses = await _nonLoopbackIpv4Addresses();
  if (addresses.isEmpty) {
    throw StateError('No non-loopback IPv4 addresses found for LAN smoke.');
  }

  Object? lastError;
  for (final address in addresses) {
    final uri = Uri.parse('http://$address:$port');
    try {
      final response = await _request(client, uri, '/api/info');
      if (response.statusCode == HttpStatus.ok) {
        return uri;
      }
      lastError = '$uri returned HTTP ${response.statusCode}';
    } catch (error) {
      lastError = '$uri failed: $error';
    }
  }
  throw StateError(
    'No non-loopback IPv4 address could reach the headless server. '
    'Tried $addresses. Last error: $lastError',
  );
}

Future<List<String>> _nonLoopbackIpv4Addresses() async {
  final addresses = <String>[];
  final interfaces = await NetworkInterface.list();
  for (final interface in interfaces) {
    final name = interface.name.toLowerCase();
    if (name.contains('loopback') || name == 'lo') {
      continue;
    }
    for (final address in interface.addresses) {
      if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
        continue;
      }
      if (address.address.startsWith('169.254.')) {
        continue;
      }
      addresses.add(address.address);
    }
  }
  return addresses;
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
  final json = text.isEmpty || !_isJson(response)
      ? <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
  return _HttpResponseBody(
    statusCode: response.statusCode,
    contentType: response.headers.value(HttpHeaders.contentTypeHeader) ?? '',
    text: text,
    json: json,
  );
}

bool _isJson(HttpClientResponse response) {
  final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
  return contentType?.contains('application/json') ?? false;
}

void _expectStatus(String label, _HttpResponseBody response, int statusCode) {
  if (response.statusCode != statusCode) {
    throw StateError(
      '$label returned ${response.statusCode}, expected $statusCode: '
      '${response.text}',
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

Future<void> _waitForExit(Process process) async {
  try {
    await process.exitCode.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
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

class _ExitTracker {
  var _exited = false;
  int? _exitCode;

  _ExitTracker(Process process) {
    unawaited(
      process.exitCode.then((code) {
        _exited = true;
        _exitCode = code;
      }),
    );
  }

  bool hasExited() => _exited;
  int? exitCode() => _exitCode;
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
