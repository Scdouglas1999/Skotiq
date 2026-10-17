import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultExePath =
    'apps/desktop/build/windows/x64/runner/Release/skotiq_desktop.exe';
const _defaultApkPath =
    'apps/mobile/build/app/outputs/flutter-apk/app-release.apk';
const _defaultAvdName = 'skotiq_release_smoke_api35';
const _packageName = 'com.skotiq.mobile';
const _activityName = 'com.skotiq.mobile.MainActivity';
const _adminToken = 'skotiq-mobile-smoke-admin-token';
const _viewToken = 'skotiq-mobile-smoke-view-token';
const _controlToken = 'skotiq-mobile-smoke-control-token';
const _evidenceDir = 'docs/production-readiness';
const _expectedAppVersion = '2.6.0';
const _expectedApiVersion = '2.6.0';

void main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('Android remote smoke currently expects Windows headless.');
    exit(2);
  }

  final options = _SmokeOptions.parse(args);
  final exe = File(options.exePath);
  final apk = File(options.apkPath);
  if (!exe.existsSync()) {
    stderr.writeln('Release executable not found: ${options.exePath}');
    exit(2);
  }
  if (!apk.existsSync()) {
    stderr.writeln('Release APK not found: ${options.apkPath}');
    exit(2);
  }

  final adb = await _findAndroidTool('adb', 'platform-tools/adb.exe');
  if (adb == null) {
    stderr.writeln('adb not found on PATH.');
    exit(2);
  }

  Process? emulatorProcess;
  Process? headlessProcess;
  var exitCode = 0;
  final processLog = _ProcessLog();
  final client = HttpClient();
  final port = await _reservePort();
  final baseUri = Uri.parse('http://127.0.0.1:$port');

  try {
    var deviceId = await _firstAdbDevice(adb);
    if (deviceId == null) {
      emulatorProcess = await _startEmulator(options.avdName);
      deviceId = await _waitForDevice(adb);
      await _waitForBoot(adb, deviceId);
    }

    headlessProcess = await _startHeadlessProcess(exe, port, processLog);

    final exitTracker = _ExitTracker(headlessProcess);
    await _waitForServer(
      client,
      baseUri,
      exitTracker.hasExited,
      exitTracker.exitCode,
    );
    await _verifyHeadlessPreconditions(client, baseUri);

    await _runAdb(adb, [
      '-s',
      deviceId,
      'install',
      '-r',
      apk.absolute.path,
    ], timeout: const Duration(minutes: 5));
    await _runAdb(adb, ['-s', deviceId, 'logcat', '-c']);
    await _runAdb(adb, ['-s', deviceId, 'shell', 'pm', 'clear', _packageName]);
    // Android 13+ asks for notification permission on first launch. Grant it
    // in the smoke environment so the connection-screen automation is not
    // obscured by a platform dialog. Older Android versions may reject the
    // grant because the runtime permission does not exist there.
    await _runAdb(adb, [
      '-s',
      deviceId,
      'shell',
      'pm',
      'grant',
      _packageName,
      'android.permission.POST_NOTIFICATIONS',
    ], allowFailure: true);
    await _runAdb(adb, [
      '-s',
      deviceId,
      'shell',
      'am',
      'start',
      '-n',
      '$_packageName/$_activityName',
    ]);

    await Future<void>.delayed(const Duration(seconds: 8));
    await _tapByDescriptionIfPresent(adb, deviceId, 'Close dialog');
    await Future<void>.delayed(const Duration(seconds: 1));
    await _dumpUi(
      adb,
      deviceId,
      '$_evidenceDir/mobile-remote-window-initial.xml',
    );
    await _tapByDescriptionWhenAvailable(
      adb,
      deviceId,
      'Enter IP',
      dismissDescriptions: const ['Close dialog'],
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    await _dumpUi(
      adb,
      deviceId,
      '$_evidenceDir/mobile-remote-window-manual.xml',
    );
    await _tapEditText(adb, deviceId, 0);
    await _runAdb(adb, [
      '-s',
      deviceId,
      'shell',
      'input',
      'text',
      '10.0.2.2:$port',
    ]);
    await _tapEditText(adb, deviceId, 1);
    await _runAdb(adb, ['-s', deviceId, 'shell', 'input', 'text', _adminToken]);
    await _runAdb(adb, ['-s', deviceId, 'shell', 'input', 'keyevent', '4']);
    await Future<void>.delayed(const Duration(seconds: 1));
    await _tapByDescription(adb, deviceId, 'Connect');
    if (!await _waitForConnectedUi(adb, deviceId)) {
      await _tapByDescriptionIfPresent(adb, deviceId, 'Connect');
      if (!await _waitForConnectedUi(adb, deviceId)) {
        throw StateError('Mobile app did not reach the connected UI.');
      }
    }

    const connectedXmlPath = '$_evidenceDir/mobile-remote-window-connected.xml';
    await _dumpUi(adb, deviceId, connectedXmlPath);
    await _screencap(
      adb,
      deviceId,
      '$_evidenceDir/android-emulator-remote-smoke.png',
    );

    final xml = await File(connectedXmlPath).readAsString();
    if (!_isConnectedUi(xml)) {
      throw StateError('Mobile app did not reach the connected UI.');
    }

    final collaborationState = await _waitForMobileViewer(client, baseUri);
    final logcat = await _readAdbLogcat(adb, deviceId);
    await File(
      '$_evidenceDir/android-emulator-remote-smoke-log.txt',
    ).writeAsString(_renderMobileEvidence(collaborationState, logcat));
    _assertLogcatClean(logcat);

    if (options.verifyReconnect) {
      await _verifyMobileReconnect(
        adb: adb,
        deviceId: deviceId,
        exe: exe,
        port: port,
        processLog: processLog,
        client: client,
        baseUri: baseUri,
        currentProcess: headlessProcess,
      );
      headlessProcess = processLog.currentProcess;
    }

    stdout.writeln('Android emulator remote smoke passed.');
    stdout.writeln('Executable: ${exe.absolute.path}');
    stdout.writeln('APK: ${apk.absolute.path}');
    stdout.writeln('Device: $deviceId');
    stdout.writeln('Headless URL from emulator: http://10.0.2.2:$port');
    if (options.verifyReconnect) {
      stdout.writeln('Mobile reconnect verification: passed');
    }
  } catch (error, stackTrace) {
    exitCode = 1;
    stderr.writeln('Android emulator remote smoke failed: $error');
    stderr.writeln(stackTrace);
    stderr.writeln(processLog.render());
  } finally {
    client.close(force: true);
    headlessProcess?.kill();
    if (headlessProcess != null) {
      await _waitForExit(headlessProcess);
    }
    if (emulatorProcess != null) {
      await _runAdb(adb, ['emu', 'kill']).catchError((_) => _RunResult('', ''));
      emulatorProcess.kill();
      await _waitForExit(emulatorProcess);
    }
  }

  exit(exitCode);
}

Future<Process> _startHeadlessProcess(
  File exe,
  int port,
  _ProcessLog processLog,
) async {
  final process = await Process.start(exe.absolute.path, [
    '--headless',
    '--port=$port',
    '--auth-token=$_adminToken',
    '--view-token=$_viewToken',
    '--control-token=$_controlToken',
  ], workingDirectory: exe.parent.absolute.path);
  processLog.currentProcess = process;
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(processLog.addStdout);
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(processLog.addStderr);
  return process;
}

Future<void> _verifyMobileReconnect({
  required String adb,
  required String deviceId,
  required File exe,
  required int port,
  required _ProcessLog processLog,
  required HttpClient client,
  required Uri baseUri,
  required Process currentProcess,
}) async {
  await _runAdb(adb, ['-s', deviceId, 'logcat', '-c']);

  currentProcess.kill();
  await _waitForExit(currentProcess);
  await Future<void>.delayed(const Duration(seconds: 4));

  final restartedProcess = await _startHeadlessProcess(exe, port, processLog);
  final exitTracker = _ExitTracker(restartedProcess);
  await _waitForServer(
    client,
    baseUri,
    exitTracker.hasExited,
    exitTracker.exitCode,
  );

  final collaborationState = await _waitForMobileViewer(client, baseUri);
  final logcat = await _readAdbLogcat(adb, deviceId);
  await File(
    '$_evidenceDir/android-emulator-remote-reconnect-smoke-log.txt',
  ).writeAsString(_renderMobileEvidence(collaborationState, logcat));
  _assertLogcatClean(logcat);
}

Future<void> _verifyHeadlessPreconditions(
  HttpClient client,
  Uri baseUri,
) async {
  final info = await _request(client, baseUri, '/api/info');
  _expectStatus('/api/info', info, HttpStatus.ok);
  if (info.json['version'] != _expectedAppVersion) {
    throw StateError(
      'Expected app version $_expectedAppVersion, got ${info.json['version']}',
    );
  }
  if (info.json['apiVersion'] != _expectedApiVersion) {
    throw StateError(
      'Expected API version $_expectedApiVersion, got '
      '${info.json['apiVersion']}',
    );
  }

  final indi = await _request(
    client,
    baseUri,
    '/api/devices/discover-indi?host=127.0.0.1&port=7624',
    token: _adminToken,
  );
  _expectStatus('/api/devices/discover-indi', indi, HttpStatus.ok);

  final alpaca = await _request(
    client,
    baseUri,
    '/api/devices/discover-alpaca?host=127.0.0.1&port=11111',
    token: _adminToken,
  );
  _expectStatus('/api/devices/discover-alpaca', alpaca, HttpStatus.ok);
}

Future<Process> _startEmulator(String avdName) async {
  final emulator = await _findAndroidTool('emulator', 'emulator/emulator.exe');
  if (emulator == null) {
    stderr.writeln('emulator not found on PATH.');
    exit(2);
  }
  final process = await Process.start(emulator, [
    '-avd',
    avdName,
    '-no-window',
    '-no-audio',
    '-no-snapshot-save',
  ]);
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  return process;
}

Future<String?> _which(String executable) async {
  final result = await Process.run('where.exe', [executable]);
  if (result.exitCode != 0) {
    return null;
  }
  final lines = (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .where((line) => line.trim().isNotEmpty)
      .toList();
  return lines.isEmpty ? null : lines.first.trim();
}

Future<String?> _findAndroidTool(
  String executable,
  String sdkRelativePath,
) async {
  final fromPath = await _which(executable);
  if (fromPath != null) {
    return fromPath;
  }

  final sdkRoots = <String?>[
    Platform.environment['ANDROID_HOME'],
    Platform.environment['ANDROID_SDK_ROOT'],
    Platform.environment['LOCALAPPDATA'] == null
        ? null
        : '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk',
  ];

  for (final sdkRoot in sdkRoots) {
    if (sdkRoot == null || sdkRoot.isEmpty) {
      continue;
    }
    final candidate = File(
      '$sdkRoot\\${sdkRelativePath.replaceAll('/', '\\')}',
    );
    if (candidate.existsSync()) {
      return candidate.absolute.path;
    }
  }
  return null;
}

Future<String?> _firstAdbDevice(String adb) async {
  final result = await _runAdb(adb, ['devices']);
  final lines = result.stdout.split(RegExp(r'\r?\n'));
  for (final line in lines.skip(1)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1] == 'device') {
      return parts[0];
    }
  }
  return null;
}

Future<String> _waitForDevice(String adb) async {
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (DateTime.now().isBefore(deadline)) {
    final device = await _firstAdbDevice(adb);
    if (device != null) {
      return device;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw TimeoutException('Timed out waiting for Android emulator/device.');
}

Future<void> _waitForBoot(String adb, String deviceId) async {
  final deadline = DateTime.now().add(const Duration(minutes: 4));
  while (DateTime.now().isBefore(deadline)) {
    final result = await _runAdb(adb, [
      '-s',
      deviceId,
      'shell',
      'getprop',
      'sys.boot_completed',
    ], allowFailure: true);
    if (result.stdout.trim() == '1') {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw TimeoutException('Timed out waiting for Android boot completion.');
}

Future<void> _tapByDescription(
  String adb,
  String deviceId,
  String description,
) async {
  final xml = await _dumpUiToString(adb, deviceId);
  final center = _nodeCenterByDescription(xml, description);
  if (center == null) {
    throw StateError('Could not find UI node containing "$description".');
  }
  await _tap(adb, deviceId, center);
}

Future<bool> _tapByDescriptionIfPresent(
  String adb,
  String deviceId,
  String description,
) async {
  final xml = await _dumpUiToString(adb, deviceId);
  final center = _nodeCenterByDescription(xml, description);
  if (center == null) {
    return false;
  }
  await _tap(adb, deviceId, center);
  return true;
}

Future<void> _tapByDescriptionWhenAvailable(
  String adb,
  String deviceId,
  String description, {
  List<String> dismissDescriptions = const [],
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final xml = await _dumpUiToString(adb, deviceId);
    final center = _nodeCenterByDescription(xml, description);
    if (center != null) {
      await _tap(adb, deviceId, center);
      return;
    }

    for (final dismissDescription in dismissDescriptions) {
      final dismissCenter = _nodeCenterByDescription(xml, dismissDescription);
      if (dismissCenter != null) {
        await _tap(adb, deviceId, dismissCenter);
        break;
      }
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw TimeoutException('Timed out waiting for UI node "$description".');
}

Future<void> _tapEditText(String adb, String deviceId, int index) async {
  final xml = await _dumpUiToString(adb, deviceId);
  final centers = _nodeCentersByClass(xml, 'android.widget.EditText');
  if (centers.length <= index) {
    throw StateError('Could not find EditText index $index.');
  }
  await _tap(adb, deviceId, centers[index]);
}

Future<void> _tap(String adb, String deviceId, _Point point) async {
  await _runAdb(adb, [
    '-s',
    deviceId,
    'shell',
    'input',
    'tap',
    '${point.x}',
    '${point.y}',
  ]);
}

Future<bool> _waitForConnectedUi(String adb, String deviceId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  var lastXml = '';
  while (DateTime.now().isBefore(deadline)) {
    lastXml = await _dumpUiToString(adb, deviceId);
    if (_isConnectedUi(lastXml)) {
      return true;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await File(
    '$_evidenceDir/mobile-remote-window-last.xml',
  ).writeAsString(lastXml);
  return false;
}

bool _isConnectedUi(String xml) {
  return xml.contains('Catalog Setup') || xml.contains('Set up your rig');
}

Future<String> _dumpUiToString(String adb, String deviceId) async {
  await _runAdb(adb, [
    '-s',
    deviceId,
    'shell',
    'uiautomator',
    'dump',
    '/sdcard/window.xml',
  ]);
  final result = await _runAdb(adb, [
    '-s',
    deviceId,
    'exec-out',
    'cat',
    '/sdcard/window.xml',
  ]);
  return result.stdout;
}

Future<void> _dumpUi(String adb, String deviceId, String outputPath) async {
  final xml = await _dumpUiToString(adb, deviceId);
  await File(outputPath).writeAsString(xml);
}

Future<void> _screencap(String adb, String deviceId, String outputPath) async {
  final result = await Process.run(adb, [
    '-s',
    deviceId,
    'exec-out',
    'screencap',
    '-p',
  ], stdoutEncoding: null).timeout(const Duration(seconds: 30));
  if (result.exitCode != 0) {
    throw StateError('adb screencap failed: ${result.stderr}');
  }
  await File(outputPath).writeAsBytes(result.stdout as List<int>);
}

_Point? _nodeCenterByDescription(String xml, String description) {
  final pattern = RegExp(
    r'<node\b[^>]*content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
  );
  for (final match in pattern.allMatches(xml)) {
    final desc = _xmlDecode(match.group(1)!);
    if (desc.split('\n').any((line) => line.trim() == description)) {
      return _boundsCenter(match);
    }
  }
  return null;
}

List<_Point> _nodeCentersByClass(String xml, String className) {
  final pattern = RegExp(
    r'<node\b[^>]*class="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
  );
  return pattern
      .allMatches(xml)
      .where((match) => match.group(1) == className)
      .map(_boundsCenter)
      .toList();
}

_Point _boundsCenter(RegExpMatch match) {
  final x1 = int.parse(match.group(2)!);
  final y1 = int.parse(match.group(3)!);
  final x2 = int.parse(match.group(4)!);
  final y2 = int.parse(match.group(5)!);
  return _Point(((x1 + x2) / 2).round(), ((y1 + y2) / 2).round());
}

String _xmlDecode(String value) {
  return value
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&#10;', '\n');
}

void _rejectLog(String log, String message) {
  if (log.contains(message)) {
    throw StateError('Unexpected log message found: $message');
  }
}

void _assertLogcatClean(String logcat) {
  _rejectLog(logcat, 'Access denied:');
  _rejectLog(logcat, 'Token scope is not permitted');
  _rejectLog(logcat, 'Internal server error');
  _rejectLog(logcat, 'FATAL EXCEPTION');
  _rejectLog(logcat, 'E AndroidRuntime: FATAL');
  _rejectLog(logcat, 'Cannot use "ref" after the widget was disposed');
}

String _renderMobileEvidence(String collaborationState, String logcat) {
  return 'Server-observed mobile WebSocket viewer:\n'
      '$collaborationState\n\n'
      'Android logcat:\n'
      '$logcat';
}

Future<String> _readAdbLogcat(String adb, String deviceId) async {
  final result = await _runAdb(adb, [
    '-s',
    deviceId,
    'logcat',
    '-d',
  ], timeout: const Duration(seconds: 30));
  return result.stdout;
}

Future<String> _waitForMobileViewer(
  HttpClient client,
  Uri baseUri, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? lastState;
  while (DateTime.now().isBefore(deadline)) {
    final response = await _request(
      client,
      baseUri,
      '/api/collaboration/state',
      token: _adminToken,
    );
    if (response.statusCode == HttpStatus.ok) {
      lastState = response.json;
      final viewers = response.json['viewers'];
      if (viewers is List && viewers.isNotEmpty) {
        return const JsonEncoder.withIndent('  ').convert(response.json);
      }
    } else {
      lastState = 'HTTP ${response.statusCode}: ${response.text}';
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw TimeoutException(
    'Timed out waiting for the server to observe a mobile WebSocket viewer. '
    'Last collaboration state: $lastState',
  );
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
  final json = text.isEmpty || !_isJson(response)
      ? <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
  return _HttpResponseBody(
    statusCode: response.statusCode,
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

Future<_RunResult> _runAdb(
  String adb,
  List<String> args, {
  Duration timeout = const Duration(seconds: 60),
  bool allowFailure = false,
}) async {
  final result = await Process.run(adb, args).timeout(timeout);
  final stdoutText = _decodeProcessOutput(result.stdout);
  final stderrText = _decodeProcessOutput(result.stderr);
  if (!allowFailure && result.exitCode != 0) {
    throw StateError('adb ${args.join(' ')} failed: $stderrText');
  }
  return _RunResult(stdoutText, stderrText);
}

String _decodeProcessOutput(Object output) {
  if (output is String) {
    return output;
  }
  if (output is List<int>) {
    return utf8.decode(output, allowMalformed: true);
  }
  return output.toString();
}

Future<void> _waitForExit(Process process) async {
  try {
    await process.exitCode.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
}

class _SmokeOptions {
  final String exePath;
  final String apkPath;
  final String avdName;
  final bool verifyReconnect;

  const _SmokeOptions({
    required this.exePath,
    required this.apkPath,
    required this.avdName,
    required this.verifyReconnect,
  });

  factory _SmokeOptions.parse(List<String> args) {
    var exePath = _defaultExePath;
    var apkPath = _defaultApkPath;
    var avdName = _defaultAvdName;
    var verifyReconnect = false;

    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--exe':
          exePath = args[++i];
        case '--apk':
          apkPath = args[++i];
        case '--avd':
          avdName = args[++i];
        case '--verify-reconnect':
          verifyReconnect = true;
        default:
          throw ArgumentError('Unknown argument: ${args[i]}');
      }
    }

    return _SmokeOptions(
      exePath: exePath,
      apkPath: apkPath,
      avdName: avdName,
      verifyReconnect: verifyReconnect,
    );
  }
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

class _RunResult {
  final String stdout;
  final String stderr;

  const _RunResult(this.stdout, this.stderr);
}

class _Point {
  final int x;
  final int y;

  const _Point(this.x, this.y);
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
  Process? currentProcess;
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
