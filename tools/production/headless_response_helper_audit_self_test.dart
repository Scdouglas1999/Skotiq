import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/headless_response_helper_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError(
      'Headless response helper audit not found: ${script.path}',
    );
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_headless_response_helper_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    final passing = _readJson(
      temp,
      'docs/production-readiness/headless-response-helper-audit.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(
      passing['issueCount'] == 0,
      'passing fixture should have no issues',
    );
    final usage = passing['usage'] as Map<String, dynamic>;
    _expect(
      usage['rawResponseCallCount'] == 2,
      'passing fixture should count raw Response calls',
    );
    _expect(
      usage['intentionalRawResponseCallCount'] == 2,
      'passing fixture should classify intentional raw Response calls',
    );
    _expect(
      usage['unclassifiedRawResponseCallCount'] == 0,
      'passing fixture should have no unclassified raw Response calls',
    );
    _expect(
      usage['helperImportCount'] == 1,
      'passing fixture should count helper imports',
    );
    final passingMarkdown = File(
      '${temp.path}/docs/production-readiness/headless-response-helper-audit.md',
    ).readAsStringSync();
    _expect(
      passingMarkdown.contains('## Classified Raw Responses'),
      'passing markdown should include classified raw response table',
    );
    _expect(
      passingMarkdown.contains('dashboard static asset byte response'),
      'passing markdown should include intentional raw response reasons',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(script, temp, allowFailure: true);
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/headless-response-helper-audit.json',
    );
    _expect(failing['passed'] == false, 'failing report should not pass');
    final issues = (failing['issues'] as List? ?? const []).join('\n');
    _expect(
      issues.contains('response_helpers.dart is missing required text'),
      'failing report should include helper missing text',
    );
    _expect(
      issues.contains('response_helpers_test.dart is missing required text'),
      'failing report should include test missing text',
    );

    await _writeRawHandlerFixture(temp);
    final rawHandlerResult = await _runAudit(script, temp, allowFailure: true);
    _expect(rawHandlerResult.exitCode == 1, 'raw handler fixture should fail');
    final rawHandler = _readJson(
      temp,
      'docs/production-readiness/headless-response-helper-audit.json',
    );
    final rawHandlerIssues = (rawHandler['issues'] as List? ?? const []).join(
      '\n',
    );
    _expect(
      rawHandlerIssues.contains('Headless handler raw Response calls'),
      'raw handler fixture should fail on handler-level raw Response usage',
    );

    stdout.writeln('Headless response helper audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/response_helpers.dart',
    '''
import 'dart:convert';
import 'package:shelf/shelf.dart';
const jsonContentType = 'application/json';
const jsonResponseHeaders = {'content-type': jsonContentType};
Response jsonResponse(Object? body) => Response(200, body: jsonEncode(body));
Response jsonOk(Object? body) => jsonResponse(body);
Response jsonCreated(Object? body) => jsonResponse(body);
Response jsonBadRequest(Object? body) => jsonResponse(body);
Response jsonUnauthorized(Object? body) => jsonResponse(body);
Response jsonForbidden(Object? body) => jsonResponse(body);
Response jsonNotFound(Object? body) => jsonResponse(body);
Response jsonConflict(Object? body) => jsonResponse(body);
Response jsonTooLarge(Object? body) => jsonResponse(body);
Response jsonUpgradeRequired(Object? body) => jsonResponse(body);
Response jsonRateLimited(Object? body) => jsonResponse(body);
Response jsonInternalServerError(Object? body) => jsonResponse(body);
Response jsonNotImplemented(Object? body) => jsonResponse(body);
Response contentResponse(Object? body) => Response.ok(body);
Response noContentResponse() => Response(204);
Response attachmentResponse(Object? body) => Response.ok(body);
''',
  );
  await _writeFile(
    root,
    'apps/desktop/test/headless_api/response_helpers_test.dart',
    '''
void main() {
  // jsonOk encodes JSON
  // jsonRateLimited
  // jsonNotImplemented encodes 501 JSON
  // contentResponse applies content type and length
  // noContentResponse returns 204 without a body
  // attachmentResponse applies safe disposition and length
  // attachmentDisposition
}
''',
  );
  await _writeFile(root, 'apps/desktop/lib/headless_api_server.dart', '''
import 'headless_api/response_helpers.dart';
void routes() {
  Response.ok(file.openRead(), headers: {'content-type': _getMimeType(filePath)});
  Response.ok('', headers: corsHeaders);
  jsonOk({'ok': true});
}
''');
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/handlers/status_handlers.dart',
    '''
void handler() {
  jsonBadRequest({'error': 'bad'});
}
''',
  );
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/handlers/session_handlers.dart',
    '''
void download() {
  contentResponse([1, 2, 3]);
}
''',
  );
}

Future<void> _writeFailingFixture(Directory root) async {
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/response_helpers.dart',
    '''
String attachmentDisposition(String fileName) => fileName;
''',
  );
  await _writeFile(
    root,
    'apps/desktop/test/headless_api/response_helpers_test.dart',
    '''
void main() {}
''',
  );
}

Future<void> _writeRawHandlerFixture(Directory root) async {
  await _writePassingFixture(root);
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/handlers/status_handlers.dart',
    '''
void handler() {
  Response.ok('{}', headers: {'content-type': 'application/json'});
}
''',
  );
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path, '--root', root.path],
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
