import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File('${repoRoot.path}/tools/production/docs_link_audit.dart');
  if (!script.existsSync()) {
    throw StateError('Docs link audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_docs_link_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    final passing = _readJson(
      temp,
      'docs/production-readiness/docs-link-audit.json',
    );
    _expect(passing['markdownFileCount'] == 4, 'should scan Markdown files');
    _expect(
      passing['checkedLocalLinkCount'] == 3,
      'should count local links and skip anchors/external links',
    );
    _expect(
      passing['brokenLocalLinkCount'] == 0,
      'passing fixture should have no broken local links',
    );
    final passingMarkdown = File(
      '${temp.path}/docs/production-readiness/docs-link-audit.md',
    ).readAsStringSync();
    _expect(
      passingMarkdown.contains('No broken local docs links found.'),
      'passing markdown should report no broken links',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(script, temp, allowFailure: true);
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/docs-link-audit.json',
    );
    _expect(
      failing['brokenLocalLinkCount'] == 1,
      'failing fixture should report one broken local link',
    );
    final brokenLinks = failing['brokenLocalLinks'] as List? ?? const [];
    _expect(
      brokenLinks.single['target'] == 'missing.md',
      'failing fixture should preserve the broken target',
    );

    stdout.writeln('Docs link audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _writeFile(root, 'docs/index.md', '''
# Index

[Guide](guide.md)
[Nested](nested/topic.md)
[Path with spaces](nested/path%20with%20spaces.md)
[External](https://example.invalid)
[Anchor only](#details)
''');
  await _writeFile(root, 'docs/guide.md', '# Guide\n');
  await _writeFile(root, 'docs/nested/topic.md', '# Topic\n');
  await _writeFile(root, 'docs/nested/path with spaces.md', '# Spaces\n');
}

Future<void> _writeFailingFixture(Directory root) async {
  await _deleteDocs(root);
  await _writeFile(root, 'docs/index.md', '''
# Index

[Missing](missing.md)
[External](https://example.invalid)
''');
}

Future<void> _deleteDocs(Directory root) async {
  final docs = Directory('${root.path}/docs');
  if (docs.existsSync()) {
    await docs.delete(recursive: true);
  }
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
