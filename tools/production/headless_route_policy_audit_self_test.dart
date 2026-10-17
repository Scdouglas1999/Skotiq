import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/headless_route_policy_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Headless route policy audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_headless_route_policy_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    final passing = _readJson(
      temp,
      'docs/production-readiness/headless-route-policy-audit.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(
      passing['issueCount'] == 0,
      'passing fixture should have no issues',
    );
    final bodyLimits = passing['bodyLimits'] as Map<String, dynamic>;
    _expect(
      bodyLimits.length == 6 &&
          bodyLimits['/api/imaging/stats'] == 64 * 1024 * 1024 &&
          bodyLimits['/api/imaging/debayer'] == 64 * 1024 * 1024 &&
          bodyLimits['/api/imaging/save-fits'] == 64 * 1024 * 1024,
      'passing fixture should audit all explicit image body limits',
    );
    _expect(
      passing['serverMiddlewareTestCount'] == 4,
      'passing fixture should count server middleware tests',
    );
    _expect(
      (passing['bodyLimitedApiWriteRouteCount'] as int) >= 3,
      'passing fixture should count registered body-limited API write routes',
    );
    final middlewareTests =
        passing['serverMiddlewareTests'] as Map<String, dynamic>;
    _expect(
      middlewareTests['oversized_control_request_before_auth'] == true,
      'passing fixture should include oversized request coverage',
    );
    _expect(
      middlewareTests['chunked_oversized_control_request_auth_ordering'] ==
          true,
      'passing fixture should include chunked oversized request coverage',
    );
    _expect(
      middlewareTests['high_risk_control_rate_limit'] == true,
      'passing fixture should include high-risk rate-limit coverage',
    );
    _expect(
      middlewareTests['websocket_api_version_before_auth'] == true,
      'passing fixture should include WebSocket API-version coverage',
    );
    final passingMarkdown = File(
      '${temp.path}/docs/production-readiness/headless-route-policy-audit.md',
    ).readAsStringSync();
    _expect(
      passingMarkdown.contains('## Server Middleware Tests'),
      'passing markdown should include server middleware test table',
    );
    _expect(
      passingMarkdown.contains('## Body-Limited API Write Routes'),
      'passing markdown should include body-limited route table',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(script, temp, allowFailure: true);
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/headless-route-policy-audit.json',
    );
    _expect(failing['passed'] == false, 'failing report should not pass');
    final issues = (failing['issues'] as List? ?? const []).join('\n');
    _expect(
      issues.contains('Headless server middleware test coverage is missing'),
      'failing report should include missing middleware test coverage',
    );

    stdout.writeln('Headless route policy audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _writeServerFixture(root);
  await _writeFile(
    root,
    'apps/desktop/test/headless_api/auth_middleware_test.dart',
    '''
void main() {
  // rejects oversized control requests before auth
  // HttpStatus.requestEntityTooLarge
  // Request body too large
  // rejects chunked oversized control requests for authenticated callers
  // response.body['requestId']
  // response.headers['x-request-id']
  // HttpStatus.requestEntityTooLarge
  // rate limits repeated high-risk control requests
  // HttpStatus.tooManyRequests
  // Rate limit exceeded
  // blocked.body['requestId']
  // blocked.headers['x-request-id']
  // rejects incompatible WebSocket API versions before auth
  // GET /events?apiVersion=1.9.9 HTTP/1.1
  // HttpStatus.upgradeRequired
  // server_too_old
}
''',
  );
  await _writeFile(
    root,
    'apps/desktop/test/headless_api_server/http_request_size_limit_test.dart',
    '''
void main() {
  // unauthenticated chunked upload is rejected with 401 before the body
  // HttpStatus.unauthorized
  // Transfer-Encoding: chunked
}
''',
  );
}

Future<void> _writeFailingFixture(Directory root) async {
  await _writeServerFixture(root);
  await _writeFile(
    root,
    'apps/desktop/test/headless_api/auth_middleware_test.dart',
    '''
void main() {
  // API compatibility tests only.
}
''',
  );
}

Future<void> _writeServerFixture(Directory root) async {
  await _writeFile(root, 'apps/desktop/lib/headless_api_server.dart', '''
void start() {
  router.post('/api/mount/slew', handleSlew);
  router.post('/api/imaging/stretch', handleStretch);
  router.patch('/api/settings/location', handleLocation);
}
''');
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path],
    workingDirectory: root.path,
    runInShell: Platform.isWindows,
  );
  if (!allowFailure && result.exitCode != 0) {
    throw StateError(
      '${script.path} failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return result;
}

Future<void> _writeFile(
  Directory root,
  String relativePath,
  String content,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

Map<String, dynamic> _readJson(Directory root, String relativePath) {
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('Expected report was not written: ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
