import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _adminToken = 'skotiq-hardware-probe-admin-token';
const _jsonOutputPath =
    'docs/production-readiness/hardware-availability-probe.json';
const _markdownOutputPath =
    'docs/production-readiness/hardware-availability-probe.md';

const _requiredDeviceTypes = <String, String>{
  'camera': 'Camera',
  'mount': 'Mount',
  'focuser': 'Focuser',
  'filterWheel': 'Filter wheel',
  'rotator': 'Rotator',
  'guider': 'Guider',
  'dome': 'Dome',
  'weather': 'Weather',
  'safetyMonitor': 'Safety monitor',
};

void main(List<String> args) async {
  final requireFull = args.contains('--require-full');
  final exePath =
      args.where((arg) => !arg.startsWith('--')).cast<String?>().firstOrNull ??
      _defaultExePath();
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
  int? processExitCode;
  unawaited(
    process.exitCode.then((code) {
      exited = true;
      processExitCode = code;
    }),
  );

  final client = HttpClient();
  final baseUri = Uri.parse('http://127.0.0.1:$port');
  var exitCode = 0;

  try {
    await _waitForServer(client, baseUri, () => exited, () => processExitCode);

    final results = <String, _DeviceAvailability>{};
    for (final entry in _requiredDeviceTypes.entries) {
      final response = await _request(
        client,
        baseUri,
        '/api/devices?deviceType=${entry.key}',
        token: _adminToken,
      );
      _expectStatus('/api/devices?deviceType=${entry.key}', response, 200);
      final rawDevices = (response.json['devices'] as List? ?? const []);
      final devices = rawDevices
          .whereType<Map>()
          .map((raw) => _DiscoveredDevice.fromJson(raw.cast<String, dynamic>()))
          .toList();
      results[entry.key] = _DeviceAvailability(
        label: entry.value,
        devices: devices,
      );
    }

    final missingAny = results.entries
        .where((entry) => !entry.value.hasAnyDevice)
        .map((entry) => entry.key)
        .toList();
    final missingNonSimulator = results.entries
        .where((entry) => !entry.value.hasNonSimulatorDevice)
        .map((entry) => entry.key)
        .toList();
    final fullRealOrSimulatorCoverage = missingAny.isEmpty;
    final fullNonSimulatorCoverage = missingNonSimulator.isEmpty;
    final generatedAt = DateTime.now().toUtc().toIso8601String();

    final report = {
      'generatedAt': generatedAt,
      'hostPlatform': Platform.operatingSystem,
      'executable': exe.absolute.path,
      'requiredDeviceTypes': _requiredDeviceTypes,
      'fullCoverage': fullNonSimulatorCoverage,
      'fullNonSimulatorCoverage': fullNonSimulatorCoverage,
      'fullRealOrSimulatorCoverage': fullRealOrSimulatorCoverage,
      'missingDeviceTypes': missingAny,
      'missingRealOrSimulatorDeviceTypes': missingAny,
      'missingNonSimulatorDeviceTypes': missingNonSimulator,
      'note':
          'This is a discovery/availability probe only. It does not connect to devices or prove command/control smoke.',
      'deviceTypes': {
        for (final entry in results.entries) entry.key: entry.value.toJson(),
      },
    };

    await File(
      _jsonOutputPath,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    await File(_markdownOutputPath).writeAsString(
      _renderMarkdown(
        generatedAt: generatedAt,
        exe: exe,
        results: results,
        missingAny: missingAny,
        missingNonSimulator: missingNonSimulator,
        fullRealOrSimulatorCoverage: fullRealOrSimulatorCoverage,
        fullNonSimulatorCoverage: fullNonSimulatorCoverage,
      ),
    );

    stdout.writeln('Hardware availability probe complete.');
    stdout.writeln('JSON: $_jsonOutputPath');
    stdout.writeln('Markdown: $_markdownOutputPath');
    stdout.writeln(
      'Full required real-or-simulator coverage: $fullRealOrSimulatorCoverage',
    );
    stdout.writeln(
      'Full required non-simulator coverage: $fullNonSimulatorCoverage',
    );
    if (missingAny.isNotEmpty) {
      stdout.writeln(
        'Missing real-or-simulator device types: ${missingAny.join(', ')}',
      );
    }
    if (missingNonSimulator.isNotEmpty) {
      stdout.writeln(
        'Missing non-simulator device types: ${missingNonSimulator.join(', ')}',
      );
    }

    if (requireFull && !fullRealOrSimulatorCoverage) {
      exitCode = 1;
    }
  } catch (error, stackTrace) {
    stderr.writeln('Hardware availability probe failed: $error');
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

  exit(exitCode);
}

String _defaultExePath() {
  if (Platform.isWindows) {
    return 'apps/desktop/build/windows/x64/runner/Release/skotiq.exe';
  }
  if (Platform.isLinux) {
    return 'apps/desktop/build/linux/x64/release/bundle/skotiq';
  }
  if (Platform.isMacOS) {
    return 'apps/desktop/build/macos/Build/Products/Release/Skotiq.app/Contents/MacOS/Skotiq';
  }
  stderr.writeln(
    'Unsupported host platform for hardware availability probe: '
    '${Platform.operatingSystem}. Pass an executable path explicitly if this '
    'platform can launch a packaged Skotiq desktop binary.',
  );
  exit(2);
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
  String? token,
}) async {
  final request = await client.getUrl(baseUri.resolve(path));
  request.headers.contentType = ContentType.json;
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final json = text.isEmpty
      ? const <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
  return _HttpResponseBody(
    statusCode: response.statusCode,
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

String _renderMarkdown({
  required String generatedAt,
  required File exe,
  required Map<String, _DeviceAvailability> results,
  required List<String> missingAny,
  required List<String> missingNonSimulator,
  required bool fullRealOrSimulatorCoverage,
  required bool fullNonSimulatorCoverage,
}) {
  final buffer = StringBuffer()
    ..writeln('# Hardware Availability Probe')
    ..writeln()
    ..writeln('- Generated: `$generatedAt`')
    ..writeln('- Executable: `${exe.absolute.path}`')
    ..writeln(
      '- Full required real-or-simulator coverage: `$fullRealOrSimulatorCoverage`',
    )
    ..writeln(
      '- Full required non-simulator coverage: `$fullNonSimulatorCoverage`',
    )
    ..writeln(
      '- Scope: discovery only; this does not connect to devices or verify control actions.',
    )
    ..writeln();

  if (missingAny.isEmpty) {
    buffer.writeln('No required device classes were missing.');
  } else {
    buffer.writeln(
      'Missing required real-or-simulator device classes: `${missingAny.join('`, `')}`.',
    );
  }
  if (missingNonSimulator.isNotEmpty) {
    buffer.writeln(
      'Missing required non-simulator device classes: `${missingNonSimulator.join('`, `')}`.',
    );
  }

  buffer
    ..writeln()
    ..writeln('| Device Type | Non-Simulator | Simulator | Devices |')
    ..writeln('| --- | ---: | ---: | --- |');

  for (final entry in _requiredDeviceTypes.entries) {
    final availability = results[entry.key]!;
    final devices = availability.devices.isEmpty
        ? 'None'
        : availability.devices.map(_deviceSummary).join('<br>');
    buffer.writeln(
      '| ${entry.value} | ${availability.nonSimulatorCount} | '
      '${availability.simulatorCount} | $devices |',
    );
  }

  return buffer.toString();
}

String _deviceSummary(_DiscoveredDevice device) {
  if (device.id.startsWith('${device.driverType}:')) {
    return device.id;
  }
  return '${device.driverType}:${device.id}';
}

class _HttpResponseBody {
  final int statusCode;
  final String text;
  final Map<String, dynamic> json;

  const _HttpResponseBody({
    required this.statusCode,
    required this.text,
    required this.json,
  });
}

class _DiscoveredDevice {
  final String id;
  final String name;
  final String deviceType;
  final String driverType;
  final String? description;

  const _DiscoveredDevice({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.driverType,
    this.description,
  });

  factory _DiscoveredDevice.fromJson(Map<String, dynamic> json) {
    return _DiscoveredDevice(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      deviceType: json['deviceType']?.toString() ?? '',
      driverType: json['driverType']?.toString() ?? '',
      description: json['description']?.toString(),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'deviceType': deviceType,
    'driverType': driverType,
    'description': description,
  };
}

class _DeviceAvailability {
  final String label;
  final List<_DiscoveredDevice> devices;

  const _DeviceAvailability({required this.label, required this.devices});

  int get simulatorCount =>
      devices.where((device) => device.driverType == 'simulator').length;

  int get nonSimulatorCount => devices.length - simulatorCount;

  bool get hasAnyDevice => devices.isNotEmpty;

  bool get hasNonSimulatorDevice => nonSimulatorCount > 0;

  Map<String, Object?> toJson() => {
    'label': label,
    'deviceCount': devices.length,
    'nonSimulatorCount': nonSimulatorCount,
    'simulatorCount': simulatorCount,
    'devices': devices.map((device) => device.toJson()).toList(),
  };
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
