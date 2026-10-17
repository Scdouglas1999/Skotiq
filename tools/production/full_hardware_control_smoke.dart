import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultExePath =
    'apps/desktop/build/linux/x64/release/bundle/skotiq';
const _adminToken = 'skotiq-full-hardware-smoke-admin-token';
const _smokeLogPath =
    'docs/production-readiness/full-hardware-control-smoke.log';
const _smokeEvidencePath =
    'docs/production-readiness/full-hardware-control-smoke-evidence.json';
const _auditLogPath = 'docs/production-readiness/real-control-audit.log';
const _remoteEvidencePath =
    'docs/production-readiness/real-remote-control-actions-evidence.json';

const _requiredTypes = <String>[
  'camera',
  'mount',
  'focuser',
  'filterWheel',
  'rotator',
  'guider',
  'dome',
  'weather',
  'safetyMonitor',
];

Future<void> main(List<String> args) async {
  final exePath =
      args.where((arg) => !arg.startsWith('--')).firstOrNull ?? _defaultExePath;
  final exe = File(exePath);
  if (!exe.existsSync()) {
    stderr.writeln('Release executable not found: $exePath');
    exit(2);
  }

  final transcript = _Transcript();
  final port = await _reservePort();
  final process = await Process.start(exe.absolute.path, [
    '--headless',
    '--port=$port',
    '--auth-token=$_adminToken',
  ], workingDirectory: exe.parent.absolute.path);
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) => transcript.server('stdout', line));
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) => transcript.server('stderr', line));

  var exited = false;
  int? processExitCode;
  unawaited(
    process.exitCode.then((code) {
      exited = true;
      processExitCode = code;
    }),
  );

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final baseUri = Uri.parse('http://127.0.0.1:$port');
  final api = _Api(client, baseUri, transcript);
  final connectionResults = <Map<String, Object?>>[];
  final commandResults = <Map<String, Object?>>[];
  final remoteCommandResults = <Map<String, Object?>>[];
  final connected = <_Device>[];

  try {
    transcript.note('Skotiq packaged full hardware/control smoke');
    transcript.note('Executable: ${exe.absolute.path}');
    transcript.note('Server: $baseUri');
    await _waitForServer(api, () => exited, () => processExitCode);

    final devices = <String, _Device>{};
    for (final type in _requiredTypes) {
      final response = await api.get('/api/devices?deviceType=$type');
      response.expectOk('discover $type');
      final raw = (response.json['devices'] as List? ?? const <Object?>[])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      if (raw.isEmpty) {
        throw StateError('No real-or-simulator-backed $type was discovered');
      }
      final selected = raw.firstWhere(
        (item) => item['driverType'] == 'simulator',
        orElse: () => raw.first,
      );
      devices[type] = _Device.fromJson(selected);
    }

    for (final type in _requiredTypes) {
      final device = devices[type]!;
      final response = await api.post('/api/devices/connect', {
        'deviceId': device.id,
        'deviceType': device.type,
      }, requestId: _requestId('connect', type));
      response.expectOk('connect $type');
      connected.add(device);
    }

    final statuses = <String, Map<String, dynamic>>{};
    for (final type in _requiredTypes) {
      final device = devices[type]!;
      final status = await _readStatus(api, device);
      _validateConnectedStatus(device, status);
      statuses[type] = status;
      connectionResults.add({
        'deviceType': type,
        'deviceId': device.id,
        'backingType': device.backingType,
        'connectPassed': true,
        'disconnectPassed': false,
        'statusReadback': jsonEncode(status),
      });
    }

    commandResults.add(
      await _cameraCommand(api, devices['camera']!, statuses['camera']!),
    );
    final mountResult = await _mountCommand(api, devices['mount']!);
    commandResults.add(mountResult.result);
    remoteCommandResults.add(mountResult.remoteResult);
    commandResults.add(
      await _focuserCommand(api, devices['focuser']!, statuses['focuser']!),
    );
    commandResults.add(
      await _filterWheelCommand(
        api,
        devices['filterWheel']!,
        statuses['filterWheel']!,
      ),
    );
    commandResults.add(
      await _rotatorCommand(api, devices['rotator']!, statuses['rotator']!),
    );
    commandResults.add(
      await _guiderCommand(api, devices['guider']!, statuses['guider']!),
    );
    commandResults.add(
      await _domeCommand(api, devices['dome']!, statuses['dome']!),
    );
    commandResults.add(await _weatherCommand(api, devices['weather']!));
    commandResults.add(await _safetyCommand(api, devices['safetyMonitor']!));

    transcript.note(
      'Waiting 61 seconds before disconnects to respect the packaged '
      'high-risk control rate limit (12 requests/minute).',
    );
    stdout.writeln(
      'Control/readback phase passed; respecting rate-limit window before disconnects...',
    );
    await Future<void>.delayed(const Duration(seconds: 61));

    for (final device in connected.reversed) {
      final response = await api.post('/api/devices/disconnect', {
        'deviceId': device.id,
        'deviceType': device.type,
      }, requestId: _requestId('disconnect', device.type));
      response.expectOk('disconnect ${device.type}');
      final row = connectionResults.firstWhere(
        (item) => item['deviceType'] == device.type,
      );
      row['disconnectPassed'] = true;
    }
    connected.clear();

    final connectedAfter = await api.get('/api/devices/connected');
    connectedAfter.expectOk('final connected-device readback');
    final stillConnected =
        connectedAfter.json['devices'] as List? ?? const <Object?>[];
    if (stillConnected.isNotEmpty) {
      throw StateError(
        'Devices remained connected after cleanup: $stillConnected',
      );
    }

    final recentLogs = await api.get('/api/logs/recent?limit=1000');
    recentLogs.expectOk('retrieve remote audit log');
    final entries = (recentLogs.json['entries'] as List? ?? const <Object?>[])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final remoteIds = remoteCommandResults
        .map((item) => item['requestId'] as String)
        .toSet();
    final auditEntries = entries.where((entry) {
      final encoded = jsonEncode(entry);
      return remoteIds.any(encoded.contains);
    }).toList();
    for (final requestId in remoteIds) {
      if (!auditEntries.any((entry) => jsonEncode(entry).contains(requestId))) {
        throw StateError(
          'Remote command $requestId was absent from the server audit log',
        );
      }
    }

    final generatedAt = DateTime.now().toUtc().toIso8601String();
    final smokeEvidence = <String, Object?>{
      'generatedAt': generatedAt,
      'coveredDeviceTypes': _requiredTypes,
      'connectDisconnectPassed': true,
      'safeStatusReadsPassed': true,
      'safeControlActionsPassed': true,
      'smokeLogPath': _smokeLogPath,
      'connectionResults': connectionResults,
      'commandResults': commandResults,
      'skippedUnsafeActions': const [
        {
          'command': 'unparked mount slew',
          'reason':
              'Park-state command proved remote mount control without an unnecessary slew.',
        },
        {
          'command': 'start guider loop',
          'reason':
              'Built-in guider configuration round-trip is safe without starting unattended guiding.',
        },
        {
          'command': 'open or move dome shutter',
          'reason':
              'Dome slaving round-trip exercises control without unnecessary shutter motion.',
        },
      ],
      'notes':
          'Generated by tools/production/full_hardware_control_smoke.dart against the packaged headless server. The native built-in guider is recorded as real because it is a non-simulator software driver; all other rows use internal simulators.',
    };
    final remoteEvidence = <String, Object?>{
      'generatedAt': generatedAt,
      'usedRealOrSimulatorBackedDevices': true,
      'remoteClientType': 'headless-api',
      'coveredDeviceTypes': remoteCommandResults
          .map((item) => item['deviceType'])
          .toList(),
      'stateReadbackPassed': true,
      'auditLogPath': _auditLogPath,
      'commandResults': remoteCommandResults,
      'skippedUnsafeActions': const [],
      'notes':
          'Generated from an authenticated packaged headless-API mount park command, post-command driver state readback, and the server in-memory audit trail.',
    };

    transcript.note(
      'PASS: all nine connect/status/command/readback/disconnect cycles passed.',
    );
    await File(_smokeLogPath).writeAsString(transcript.render());
    await File(_auditLogPath).writeAsString(
      '${auditEntries.map((entry) => jsonEncode(entry)).join('\n')}\n',
    );
    await _writeJson(_smokeEvidencePath, smokeEvidence);
    await _writeJson(_remoteEvidencePath, remoteEvidence);

    stdout.writeln('Packaged full hardware/control smoke passed.');
    stdout.writeln('Evidence: $_smokeEvidencePath');
    stdout.writeln('Remote evidence: $_remoteEvidencePath');
  } catch (error, stackTrace) {
    transcript.note('FAIL: $error');
    stderr.writeln('Packaged full hardware/control smoke failed: $error');
    stderr.writeln(stackTrace);
    stderr.writeln(transcript.render());
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
}

Future<Map<String, Object?>> _cameraCommand(
  _Api api,
  _Device device,
  Map<String, dynamic> initial,
) async {
  final original = (initial['gain'] as num).toInt();
  final target = original == 65535 ? original - 1 : original + 1;
  (await api.post(
    '/api/camera/gain',
    {'deviceId': device.id, 'gain': target},
    requestId: _requestId('camera-gain', device.type),
  )).expectOk('camera set gain');
  final changed = await _pollStatus(
    api,
    device,
    (status) => status['gain'] == target,
    'camera gain=$target',
  );
  (await api.post('/api/camera/gain', {
    'deviceId': device.id,
    'gain': original,
  })).expectOk('camera restore gain');
  final restored = await _pollStatus(
    api,
    device,
    (status) => status['gain'] == original,
    'camera gain restore=$original',
  );
  return _commandRow(device, 'set gain $target then restore $original', {
    'changed': changed,
    'restored': restored,
  });
}

Future<({Map<String, Object?> result, Map<String, Object?> remoteResult})>
_mountCommand(_Api api, _Device device) async {
  final requestId = _requestId('remote-mount-park', device.type);
  (await api.post('/api/mount/park', {
    'deviceId': device.id,
  }, requestId: requestId)).expectOk('mount park');
  final status = await _pollStatus(
    api,
    device,
    (value) => value['parked'] == true && value['slewing'] == false,
    'mount parked=true',
  );
  final readback = jsonEncode(status);
  return (
    result: _commandRow(device, 'park mount', status),
    remoteResult: {
      'deviceType': device.type,
      'deviceId': device.id,
      'requestId': requestId,
      'command': 'POST /api/mount/park',
      'stateReadback': readback,
      'passed': true,
    },
  );
}

Future<Map<String, Object?>> _focuserCommand(
  _Api api,
  _Device device,
  Map<String, dynamic> initial,
) async {
  final original = (initial['position'] as num).toInt();
  final max = (initial['maxPosition'] as num).toInt();
  final target = original + 50 <= max ? original + 50 : original - 50;
  (await api.post('/api/focuser/move-to', {
    'deviceId': device.id,
    'position': target,
  })).expectOk('focuser move');
  final changed = await _pollStatus(
    api,
    device,
    (status) => status['position'] == target && status['moving'] == false,
    'focuser position=$target',
  );
  (await api.post('/api/focuser/move-to', {
    'deviceId': device.id,
    'position': original,
  })).expectOk('focuser restore');
  final restored = await _pollStatus(
    api,
    device,
    (status) => status['position'] == original && status['moving'] == false,
    'focuser restore=$original',
  );
  return _commandRow(device, 'move to $target then restore $original', {
    'changed': changed,
    'restored': restored,
  });
}

Future<Map<String, Object?>> _filterWheelCommand(
  _Api api,
  _Device device,
  Map<String, dynamic> initial,
) async {
  final original = (initial['position'] as num).toInt();
  final count = (initial['filterCount'] as num).toInt();
  if (count < 2) throw StateError('Filter wheel reported fewer than two slots');
  final target = (original + 1) % count;
  (await api.post('/api/filter-wheel/position', {
    'deviceId': device.id,
    'position': target,
  })).expectOk('filter wheel move');
  final changed = await _pollStatus(
    api,
    device,
    (status) => status['position'] == target && status['moving'] == false,
    'filter wheel position=$target',
  );
  (await api.post('/api/filter-wheel/position', {
    'deviceId': device.id,
    'position': original,
  })).expectOk('filter wheel restore');
  final restored = await _pollStatus(
    api,
    device,
    (status) => status['position'] == original && status['moving'] == false,
    'filter wheel restore=$original',
  );
  return _commandRow(device, 'set slot $target then restore $original', {
    'changed': changed,
    'restored': restored,
  });
}

Future<Map<String, Object?>> _rotatorCommand(
  _Api api,
  _Device device,
  Map<String, dynamic> initial,
) async {
  final original = (initial['position'] as num).toDouble();
  final target = (original + 1.0) % 360.0;
  (await api.post('/api/rotator/move-to', {
    'deviceId': device.id,
    'angle': target,
  })).expectOk('rotator move');
  final changed = await _pollStatus(
    api,
    device,
    (status) => _near(status['position'], target) && status['moving'] == false,
    'rotator position=$target',
    timeout: const Duration(seconds: 15),
  );
  (await api.post('/api/rotator/move-to', {
    'deviceId': device.id,
    'angle': original,
  })).expectOk('rotator restore');
  final restored = await _pollStatus(
    api,
    device,
    (status) =>
        _near(status['position'], original) && status['moving'] == false,
    'rotator restore=$original',
    timeout: const Duration(seconds: 15),
  );
  return _commandRow(device, 'move to $target degrees then restore $original', {
    'changed': changed,
    'restored': restored,
  });
}

Future<Map<String, Object?>> _guiderCommand(
  _Api api,
  _Device device,
  Map<String, dynamic> initial,
) async {
  (await api.post(
    '/api/builtin-guider/config',
    initial,
  )).expectOk('reapply built-in guider config');
  final readback = await api.get('/api/builtin-guider/config');
  readback.expectOk('read built-in guider config');
  if (jsonEncode(readback.json) != jsonEncode(initial)) {
    throw StateError(
      'Built-in guider config readback mismatch: ${readback.text}',
    );
  }
  return _commandRow(
    device,
    'reapply built-in guider configuration',
    readback.json,
  );
}

Future<Map<String, Object?>> _domeCommand(
  _Api api,
  _Device device,
  Map<String, dynamic> initial,
) async {
  final original = initial['syncEnabled'] == true;
  final target = !original;
  (await api.post('/api/dome/sync', {
    'deviceId': device.id,
    'enable': target,
  })).expectOk('dome set slaving');
  final changed = await _pollStatus(
    api,
    device,
    (status) => status['syncEnabled'] == target,
    'dome syncEnabled=$target',
  );
  (await api.post('/api/dome/sync', {
    'deviceId': device.id,
    'enable': original,
  })).expectOk('dome restore slaving');
  final restored = await _pollStatus(
    api,
    device,
    (status) => status['syncEnabled'] == original,
    'dome sync restore=$original',
  );
  return _commandRow(device, 'set slaving $target then restore $original', {
    'changed': changed,
    'restored': restored,
  });
}

Future<Map<String, Object?>> _weatherCommand(_Api api, _Device device) async {
  (await api.post(
    '/api/weather/clear-cache',
    const {},
  )).expectOk('weather clear cache');
  final status = await _readStatus(api, device);
  if (status['hardwareConnected'] != true || status['temperature'] == null) {
    throw StateError('Weather hardware telemetry readback failed: $status');
  }
  return _commandRow(
    device,
    'clear forecast cache and read hardware telemetry',
    status,
  );
}

Future<Map<String, Object?>> _safetyCommand(_Api api, _Device device) async {
  final status = await _readStatus(api, device);
  if (status['connected'] != true || status['isSafe'] is! bool) {
    throw StateError('Safety verdict readback failed: $status');
  }
  return _commandRow(device, 'read fail-closed safety verdict', status);
}

Map<String, Object?> _commandRow(
  _Device device,
  String command,
  Object readback,
) => {
  'deviceType': device.type,
  'deviceId': device.id,
  'backingType': device.backingType,
  'command': command,
  'stateReadback': readback is String ? readback : jsonEncode(readback),
  'passed': true,
};

Future<Map<String, dynamic>> _pollStatus(
  _Api api,
  _Device device,
  bool Function(Map<String, dynamic>) predicate,
  String expected, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  Map<String, dynamic> last = const {};
  do {
    last = await _readStatus(api, device);
    if (predicate(last)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } while (DateTime.now().isBefore(deadline));
  throw StateError('Timed out waiting for $expected; last status: $last');
}

Future<Map<String, dynamic>> _readStatus(_Api api, _Device device) async {
  final id = Uri.encodeQueryComponent(device.id);
  final path = switch (device.type) {
    'camera' => '/api/equipment/camera/status?deviceId=$id',
    'mount' => '/api/equipment/mount/status?deviceId=$id',
    'focuser' => '/api/equipment/focuser/status?deviceId=$id',
    'filterWheel' => '/api/equipment/filter-wheel/status?deviceId=$id',
    'rotator' => '/api/equipment/rotator/status?deviceId=$id',
    'guider' => '/api/builtin-guider/config',
    'dome' => '/api/dome/status?deviceId=$id',
    'weather' => '/api/weather/current',
    'safetyMonitor' => '/api/safety/status?deviceId=$id',
    _ => throw StateError('Unsupported device type ${device.type}'),
  };
  final response = await api.get(path);
  response.expectOk('${device.type} status');
  return response.json;
}

void _validateConnectedStatus(_Device device, Map<String, dynamic> status) {
  final valid = switch (device.type) {
    'guider' => status.containsKey('exposureSecs'),
    'weather' =>
      status['hardwareConnected'] == true && status['temperature'] != null,
    _ => status['connected'] == true,
  };
  if (!valid) {
    throw StateError(
      '${device.type} status did not prove a live connection: $status',
    );
  }
}

bool _near(Object? value, double expected) =>
    value is num && (value.toDouble() - expected).abs() < 0.01;

String _requestId(String operation, String type) =>
    'ns-smoke-$operation-$type-${DateTime.now().microsecondsSinceEpoch}';

Future<int> _reservePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitForServer(
  _Api api,
  bool Function() exited,
  int? Function() exitCode,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    if (exited()) {
      throw StateError('Packaged server exited early with code ${exitCode()}');
    }
    try {
      final response = await api.get('/api/info', authenticated: false);
      if (response.statusCode == HttpStatus.ok) return;
      lastError = 'HTTP ${response.statusCode}';
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException('Timed out waiting for packaged server: $lastError');
}

Future<void> _writeJson(String path, Object value) => File(
  path,
).writeAsString('${const JsonEncoder.withIndent('  ').convert(value)}\n');

class _Api {
  final HttpClient client;
  final Uri baseUri;
  final _Transcript transcript;

  _Api(this.client, this.baseUri, this.transcript);

  Future<_Response> get(String path, {bool authenticated = true}) =>
      _request('GET', path, null, authenticated: authenticated);

  Future<_Response> post(
    String path,
    Map<String, Object?> body, {
    String? requestId,
  }) => _request('POST', path, body, requestId: requestId);

  Future<_Response> _request(
    String method,
    String path,
    Map<String, Object?>? body, {
    String? requestId,
    bool authenticated = true,
  }) async {
    final request = await client.openUrl(method, baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    if (authenticated) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $_adminToken',
      );
    }
    if (requestId != null) request.headers.set('x-request-id', requestId);
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Map<String, dynamic> json = const {};
    if (text.isNotEmpty) {
      final decoded = jsonDecode(text);
      if (decoded is Map) json = decoded.cast<String, dynamic>();
    }
    transcript.http(method, path, requestId, body, response.statusCode, text);
    return _Response(response.statusCode, text, json);
  }
}

class _Response {
  final int statusCode;
  final String text;
  final Map<String, dynamic> json;

  const _Response(this.statusCode, this.text, this.json);

  void expectOk(String label) {
    if (statusCode < 200 || statusCode >= 300) {
      throw StateError('$label returned HTTP $statusCode: $text');
    }
  }
}

class _Device {
  final String id;
  final String type;
  final String driverType;

  const _Device(this.id, this.type, this.driverType);

  factory _Device.fromJson(Map<String, dynamic> json) => _Device(
    json['id'] as String,
    json['deviceType'] as String,
    json['driverType'] as String,
  );

  String get backingType => driverType == 'simulator' ? 'simulator' : 'real';
}

class _Transcript {
  final _lines = <String>[];
  final _serverLines = <String>[];

  void note(String message) =>
      _lines.add('${DateTime.now().toUtc().toIso8601String()} $message');

  void server(String stream, String line) {
    _serverLines.add(
      '${DateTime.now().toUtc().toIso8601String()} [$stream] $line',
    );
    if (_serverLines.length > 500) _serverLines.removeAt(0);
  }

  void http(
    String method,
    String path,
    String? requestId,
    Map<String, Object?>? body,
    int status,
    String response,
  ) {
    note(
      '$method $path${requestId == null ? '' : ' requestId=$requestId'} '
      'body=${body == null ? '-' : jsonEncode(body)} -> $status $response',
    );
  }

  String render() =>
      '${_lines.join('\n')}\n\n== Packaged server output (last 500 lines) ==\n${_serverLines.join('\n')}\n';
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
