import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultExePath =
    'apps/desktop/build/windows/x64/runner/Release/skotiq.exe';
const _viewToken = 'skotiq-browser-smoke-view-token';
const _controlToken = 'skotiq-browser-smoke-control-token';
const _adminToken = 'skotiq-browser-smoke-admin-token';

void main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('Dashboard browser smoke must run on Windows.');
    exit(2);
  }

  final verifyReconnect = args.contains('--verify-reconnect');
  final exePath = _exePathFromArgs(args);
  final exe = File(exePath);
  if (!exe.existsSync()) {
    stderr.writeln('Release executable not found: $exePath');
    exit(2);
  }

  final chromePath = _findChromePath();
  if (chromePath == null) {
    stderr.writeln('Chrome or Edge executable not found.');
    exit(2);
  }

  final serverPort = await _reservePort();
  final chromePort = await _reservePort();
  final serverLog = _ProcessLog('headless app');
  final chromeLog = _ProcessLog('browser');
  final tempDir = await Directory.systemTemp.createTemp('skotiq_browser_');
  Process? serverProcess;
  Process? chromeProcess;
  var exitCode = 0;

  try {
    serverProcess = await _startHeadlessServer(exe, serverPort, serverLog);

    final serverExited = _ExitTracker(serverProcess);
    final httpClient = HttpClient();
    final baseUri = Uri.parse('http://127.0.0.1:$serverPort');
    await _waitForServer(
      httpClient,
      baseUri,
      serverExited.hasExited,
      serverExited.exitCode,
    );

    chromeProcess = await Process.start(chromePath, [
      '--headless=new',
      '--disable-gpu',
      '--disable-background-networking',
      '--disable-default-apps',
      '--no-first-run',
      '--no-default-browser-check',
      '--remote-debugging-port=$chromePort',
      '--user-data-dir=${tempDir.path}',
      'about:blank',
    ]);
    _captureProcess(chromeProcess, chromeLog);

    final browserExited = _ExitTracker(chromeProcess);
    final target = await _waitForBrowserTarget(
      httpClient,
      chromePort,
      browserExited.hasExited,
      browserExited.exitCode,
    );

    final cdp = await _CdpClient.connect(target.webSocketDebuggerUrl);
    final pageEvents = _PageEvents(cdp);
    final runtimeErrors = _RuntimeErrors(cdp);

    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Log.enable');
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
      'source': _startupScript(baseUri.toString(), _viewToken),
    });
    await cdp.send('Page.navigate', {
      'url': baseUri.resolve('/dashboard').toString(),
    });
    await pageEvents.waitForLoad();

    final snapshot = await _waitForDashboardConnected(cdp, runtimeErrors);
    if (verifyReconnect) {
      serverProcess = await _verifyDashboardReconnect(
        cdp: cdp,
        runtimeErrors: runtimeErrors,
        exe: exe,
        port: serverPort,
        serverProcess: serverProcess,
        serverLog: serverLog,
        httpClient: httpClient,
        baseUri: baseUri,
      );
    }
    final errors = runtimeErrors.errors;
    await cdp.close();
    httpClient.close(force: true);

    if (errors.isNotEmpty) {
      throw StateError(
        'Browser reported JavaScript/runtime errors:\n${errors.join('\n')}',
      );
    }

    stdout.writeln(
      verifyReconnect
          ? 'Dashboard browser reconnect smoke passed.'
          : 'Dashboard browser smoke passed.',
    );
    stdout.writeln('Executable: ${exe.absolute.path}');
    stdout.writeln('Browser: $chromePath');
    stdout.writeln('Dashboard: ${baseUri.resolve('/dashboard')}');
    stdout.writeln('Panels rendered: ${snapshot.panelCount}');
  } catch (error, stackTrace) {
    exitCode = 1;
    stderr.writeln('Dashboard browser smoke failed: $error');
    stderr.writeln(stackTrace);
    stderr.writeln(serverLog.render());
    stderr.writeln(chromeLog.render());
  } finally {
    serverProcess?.kill();
    chromeProcess?.kill();
    await _waitForExit(serverProcess);
    await _waitForExit(chromeProcess);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  exit(exitCode);
}

String _exePathFromArgs(List<String> args) {
  for (final arg in args) {
    if (!arg.startsWith('--')) {
      return arg;
    }
  }
  return _defaultExePath;
}

Future<Process> _startHeadlessServer(
  File exe,
  int port,
  _ProcessLog serverLog,
) async {
  final process = await Process.start(exe.absolute.path, [
    '--headless',
    '--port=$port',
    '--auth-token=$_adminToken',
    '--view-token=$_viewToken',
    '--control-token=$_controlToken',
  ], workingDirectory: exe.parent.absolute.path);
  _captureProcess(process, serverLog);
  return process;
}

String? _findChromePath() {
  final candidates = <String>[
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

String _startupScript(String baseUrl, String token) {
  return '''
localStorage.setItem('skotiq_url', ${jsonEncode(baseUrl)});
localStorage.setItem('skotiq_device_id', 'browser-dashboard-smoke');
localStorage.setItem('skotiq_device_name', 'Browser smoke');
localStorage.setItem('skotiq_remember_token', 'false');
localStorage.removeItem('skotiq_token');
sessionStorage.setItem('skotiq_token', ${jsonEncode(token)});
''';
}

void _captureProcess(Process process, _ProcessLog log) {
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(log.addStdout);
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(log.addStderr);
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
      final request = await client.getUrl(baseUri.resolve('/api/info'));
      final response = await request.close();
      await response.drain<void>();
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

Future<_BrowserTarget> _waitForBrowserTarget(
  HttpClient client,
  int chromePort,
  bool Function() hasExited,
  int? Function() exitCode,
) async {
  final uri = Uri.parse('http://127.0.0.1:$chromePort/json/list');
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    if (hasExited()) {
      throw StateError('Browser exited early with code ${exitCode()}');
    }
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == HttpStatus.ok) {
        final targets = jsonDecode(body) as List<dynamic>;
        for (final targetJson in targets.cast<Map<String, dynamic>>()) {
          if (targetJson['type'] == 'page' &&
              targetJson['webSocketDebuggerUrl'] is String) {
            return _BrowserTarget(targetJson['webSocketDebuggerUrl'] as String);
          }
        }
      }
      lastError = body;
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('Timed out waiting for browser target: $lastError');
}

Future<_DashboardSnapshot> _waitForDashboardConnected(
  _CdpClient cdp,
  _RuntimeErrors runtimeErrors,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  _DashboardSnapshot? lastSnapshot;
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await _readDashboardSnapshot(cdp);
    lastSnapshot = snapshot;
    if (snapshot.readyState == 'complete' &&
        snapshot.statusText == 'Connected' &&
        snapshot.apiConnected == true &&
        snapshot.apiWsConnected == true &&
        snapshot.panelCount >= 6 &&
        snapshot.disabledActionCount == 0 &&
        snapshot.serverUrl.startsWith('http://127.0.0.1:')) {
      return snapshot;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException(
    'Timed out waiting for rendered dashboard connection. '
    'Last snapshot: ${lastSnapshot?.toJson()}. '
    'Runtime errors: ${runtimeErrors.errors}',
  );
}

Future<Process> _verifyDashboardReconnect({
  required _CdpClient cdp,
  required _RuntimeErrors runtimeErrors,
  required File exe,
  required int port,
  required Process serverProcess,
  required _ProcessLog serverLog,
  required HttpClient httpClient,
  required Uri baseUri,
}) async {
  serverProcess.kill();
  await _waitForExit(serverProcess);

  final disconnected = await _waitForDashboardWebSocketState(
    cdp: cdp,
    runtimeErrors: runtimeErrors,
    expectedConnected: false,
    requireLogText: 'WebSocket disconnected',
    timeout: const Duration(seconds: 15),
  );
  if (disconnected.statusText != 'Connected') {
    throw StateError(
      'REST connection status changed unexpectedly during WebSocket outage: '
      '${disconnected.toJson()}',
    );
  }

  final restartedProcess = await _startHeadlessServer(exe, port, serverLog);
  final restartedExit = _ExitTracker(restartedProcess);
  await _waitForServer(
    httpClient,
    baseUri,
    restartedExit.hasExited,
    restartedExit.exitCode,
  );

  final reconnected = await _waitForDashboardWebSocketState(
    cdp: cdp,
    runtimeErrors: runtimeErrors,
    expectedConnected: true,
    requireLogText: 'WebSocket connected',
    timeout: const Duration(seconds: 30),
  );
  final connectedCount = RegExp(
    'WebSocket connected',
  ).allMatches(reconnected.logText).length;
  if (connectedCount < 2) {
    throw StateError(
      'Dashboard did not log an initial and recovered WebSocket connection: '
      '${reconnected.toJson()}',
    );
  }

  return restartedProcess;
}

Future<_DashboardSnapshot> _waitForDashboardWebSocketState({
  required _CdpClient cdp,
  required _RuntimeErrors runtimeErrors,
  required bool expectedConnected,
  required String requireLogText,
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  _DashboardSnapshot? lastSnapshot;
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await _readDashboardSnapshot(cdp);
    lastSnapshot = snapshot;
    if (snapshot.readyState == 'complete' &&
        snapshot.apiConnected == true &&
        snapshot.apiWsConnected == expectedConnected &&
        snapshot.logText.contains(requireLogText)) {
      return snapshot;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException(
    'Timed out waiting for dashboard WebSocket '
    '${expectedConnected ? 'reconnect' : 'disconnect'}. '
    'Last snapshot: ${lastSnapshot?.toJson()}. '
    'Runtime errors: ${runtimeErrors.errors}',
  );
}

Future<_DashboardSnapshot> _readDashboardSnapshot(_CdpClient cdp) async {
  final result = await cdp.send('Runtime.evaluate', {
    'expression': r'''
(() => ({
  readyState: document.readyState,
  statusText: document.getElementById('status-text')?.textContent || '',
  authBarHidden: document.getElementById('auth-bar')?.classList.contains('hidden') || false,
  panelCount: document.querySelectorAll('.panel').length,
  disabledActionCount: Array.from(document.querySelectorAll('.panel button:not(#btn-clear-log)')).filter((button) => button.disabled).length,
  toastText: document.getElementById('toast-container')?.innerText || '',
  logText: document.getElementById('log-container')?.innerText || '',
  serverUrl: document.getElementById('server-url')?.value || '',
  scriptCount: document.scripts.length,
  scriptSources: Array.from(document.scripts).map((script) => script.src || '[inline]'),
  hasApiClass: typeof SkotiqApi !== 'undefined',
  apiConnected: typeof api !== 'undefined' ? api.isConnected : null,
  apiWsConnected: typeof api !== 'undefined' ? api.isWsConnected : null,
}))()
''',
    'returnByValue': true,
  });
  final value =
      ((result['result'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>)['value']
          as Map<String, dynamic>;
  return _DashboardSnapshot.fromJson(value);
}

Future<void> _waitForExit(Process? process) async {
  if (process == null) {
    return;
  }
  try {
    await process.exitCode.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
}

class _BrowserTarget {
  final String webSocketDebuggerUrl;

  const _BrowserTarget(this.webSocketDebuggerUrl);
}

class _DashboardSnapshot {
  final String readyState;
  final String statusText;
  final bool authBarHidden;
  final int panelCount;
  final int disabledActionCount;
  final String toastText;
  final String logText;
  final String serverUrl;
  final int scriptCount;
  final List<String> scriptSources;
  final bool hasApiClass;
  final bool? apiConnected;
  final bool? apiWsConnected;

  const _DashboardSnapshot({
    required this.readyState,
    required this.statusText,
    required this.authBarHidden,
    required this.panelCount,
    required this.disabledActionCount,
    required this.toastText,
    required this.logText,
    required this.serverUrl,
    required this.scriptCount,
    required this.scriptSources,
    required this.hasApiClass,
    required this.apiConnected,
    required this.apiWsConnected,
  });

  factory _DashboardSnapshot.fromJson(Map<String, dynamic> json) {
    return _DashboardSnapshot(
      readyState: json['readyState'] as String? ?? '',
      statusText: json['statusText'] as String? ?? '',
      authBarHidden: json['authBarHidden'] as bool? ?? false,
      panelCount: json['panelCount'] as int? ?? 0,
      disabledActionCount: json['disabledActionCount'] as int? ?? 0,
      toastText: json['toastText'] as String? ?? '',
      logText: json['logText'] as String? ?? '',
      serverUrl: json['serverUrl'] as String? ?? '',
      scriptCount: json['scriptCount'] as int? ?? 0,
      scriptSources: (json['scriptSources'] as List<dynamic>? ?? const [])
          .cast<String>(),
      hasApiClass: json['hasApiClass'] as bool? ?? false,
      apiConnected: json['apiConnected'] as bool?,
      apiWsConnected: json['apiWsConnected'] as bool?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'readyState': readyState,
      'statusText': statusText,
      'authBarHidden': authBarHidden,
      'panelCount': panelCount,
      'disabledActionCount': disabledActionCount,
      'toastText': toastText,
      'logText': logText,
      'serverUrl': serverUrl,
      'scriptCount': scriptCount,
      'scriptSources': scriptSources,
      'hasApiClass': hasApiClass,
      'apiConnected': apiConnected,
      'apiWsConnected': apiWsConnected,
    };
  }
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

class _PageEvents {
  final _loadCompleters = <Completer<void>>[];

  _PageEvents(_CdpClient cdp) {
    cdp.events.listen((event) {
      if (event['method'] == 'Page.loadEventFired') {
        for (final completer in List<Completer<void>>.from(_loadCompleters)) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
        _loadCompleters.clear();
      }
    });
  }

  Future<void> waitForLoad() {
    final completer = Completer<void>();
    _loadCompleters.add(completer);
    return completer.future.timeout(const Duration(seconds: 30));
  }
}

class _RuntimeErrors {
  final errors = <String>[];

  _RuntimeErrors(_CdpClient cdp) {
    cdp.events.listen((event) {
      final method = event['method'];
      final params = event['params'];
      if (params is! Map<String, dynamic>) {
        return;
      }
      if (method == 'Runtime.exceptionThrown') {
        final details = params['exceptionDetails'] as Map<String, dynamic>?;
        errors.add(details?['text'] as String? ?? 'Runtime exception');
      } else if (method == 'Runtime.consoleAPICalled' &&
          params['type'] == 'error') {
        final args = params['args'] as List<dynamic>? ?? const [];
        final text = args
            .cast<Map<String, dynamic>>()
            .map((arg) => arg['value'] ?? arg['description'] ?? '')
            .where((value) => value.toString().isNotEmpty)
            .join(' ');
        errors.add(text.isEmpty ? 'console.error called' : text);
      }
    });
  }
}

class _CdpClient {
  final WebSocket _socket;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  var _nextId = 1;

  _CdpClient._(this._socket) {
    _socket.listen(
      (message) {
        final data = jsonDecode(message as String) as Map<String, dynamic>;
        final id = data['id'];
        if (id is int) {
          final completer = _pending.remove(id);
          if (completer == null) {
            return;
          }
          if (data.containsKey('error')) {
            completer.completeError(StateError(jsonEncode(data['error'])));
          } else {
            completer.complete(data);
          }
        } else {
          _events.add(data);
        }
      },
      onError: _events.addError,
      onDone: () {
        for (final completer in _pending.values) {
          if (!completer.isCompleted) {
            completer.completeError(StateError('CDP socket closed'));
          }
        }
        _pending.clear();
        _events.close();
      },
    );
  }

  static Future<_CdpClient> connect(String webSocketDebuggerUrl) async {
    final socket = await WebSocket.connect(webSocketDebuggerUrl);
    return _CdpClient._(socket);
  }

  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(
      jsonEncode({
        'id': id,
        'method': method,
        if (params.isNotEmpty) 'params': params,
      }),
    );
    return completer.future.timeout(const Duration(seconds: 30));
  }

  Future<void> close() async {
    await _socket.close();
  }
}

class _ProcessLog {
  final String label;
  final _stdout = <String>[];
  final _stderr = <String>[];

  _ProcessLog(this.label);

  void addStdout(String line) => _addBounded(_stdout, line);
  void addStderr(String line) => _addBounded(_stderr, line);

  String render() {
    return [
      '--- $label stdout ---',
      ..._stdout,
      '--- $label stderr ---',
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
