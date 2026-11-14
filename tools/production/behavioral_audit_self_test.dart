import 'dart:io';

import 'src/site_register.dart';

/// Self-test for tools/production/behavioral_audit.dart.
///
/// Builds a small workspace in a temp dir and proves the properties the gate
/// exists for: a reviewed verdict stays attached when code moves or lines
/// shift, new and open findings fail, deleted code leaves prunable rows that
/// one command drops, and a package outside the scan scope fails the gate.
Future<void> main() async {
  _testEnclosingScope();

  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/behavioral_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Behavioral audit not found: ${script.path}');
  }
  final scopePath =
      '${repoRoot.path}/docs/production-readiness/audit-scope.yaml';

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_behavioral_audit_self_test_',
  );
  Future<ProcessResult> run([List<String> extra = const []]) => Process.run(
    'dart',
    [
      script.path,
      '--scope',
      scopePath,
      '--register',
      'register.md',
      '--report',
      'hits.txt',
      '--fail-on-unregistered',
      '--fail-on-open',
      ...extra,
    ],
    workingDirectory: temp.path,
    runInShell: Platform.isWindows,
  );
  String sites() => File('${temp.path}/register.sites.tsv').readAsStringSync();

  try {
    const dartPath = 'packages/fixture/lib/src/loader.dart';
    const rustPath = 'native/skotiq_native/bridge/src/wheel.rs';
    await _write(temp, dartPath, _dartFixture);
    await _write(temp, rustPath, _rustFixture);
    await _write(temp, 'register.md', _registerFixture);

    // --- Unregistered findings fail and are named with their scope. ---
    var result = await run();
    _expect(result.exitCode == 1, 'unregistered findings should fail');
    final stderrText = result.stderr.toString();
    for (final expected in [
      '$dartPath:3:literal_null_coalesce [read]',
      '$dartPath:9:empty_catch [close]',
      '$rustPath:3:unwrap_or_default [names]',
    ]) {
      _expect(
        stderrText.contains(expected),
        'expected "$expected" in:\n$stderrText',
      );
    }

    // --- Registering them under a closed verdict passes. ---
    result = await run(['--accept-new', 'V1']);
    _expect(
      result.exitCode == 0,
      'accepted findings should pass: ${_out(result)}',
    );
    final accepted = sites();

    // --- Lines inserted above the hits: green, no register edit. ---
    await _write(
      temp,
      dartPath,
      '// A new header comment.\n\nint unrelated() => 1;\n\n$_dartFixture',
    );
    await _write(temp, rustPath, '// header\n\nfn other() {}\n\n$_rustFixture');
    result = await run();
    _expect(result.exitCode == 0, 'shifted lines should pass: ${_out(result)}');
    _expect(sites() == accepted, 'a plain gate run must not edit the sites');

    // --- Files moved (one across packages): green, no register edit. ---
    const movedDart = 'apps/desktop/lib/io/loader.dart';
    const movedRust = 'native/skotiq_native/sequencer/src/devices/wheel.rs';
    await _move(temp, dartPath, movedDart);
    await _move(temp, rustPath, movedRust);
    result = await run();
    _expect(result.exitCode == 0, 'moved files should pass: ${_out(result)}');
    _expect(
      result.stdout.toString().contains(
        'Registered: 3 (3 matched away from their recorded path)',
      ),
      'moved findings should be reported as moved: ${result.stdout}',
    );
    _expect(sites() == accepted, 'a move must not need a sites edit');

    // --- --sync refreshes the path hints. ---
    result = await run(['--sync']);
    _expect(result.exitCode == 0, 'sync after a move should pass');
    _expect(
      sites().contains(movedDart) && !sites().contains(dartPath),
      'sync should re-point the path hints',
    );

    // --- A new hit fails, and only the new hit is reported. ---
    await _write(temp, 'apps/desktop/lib/io/fresh.dart', '''
int fresh(Map<String, Object?> json) {
  return json['n'] as int? ?? 0;
}
''');
    result = await run();
    _expect(result.exitCode == 1, 'a new finding should fail');
    _expect(
      result.stderr.toString().contains(
            'Unregistered behavioral findings (1)',
          ) &&
          result.stderr.toString().contains('fresh.dart:2'),
      'only the new finding should be reported: ${result.stderr}',
    );

    // --- A second copy of a reviewed line in the same function fails. ---
    await File('${temp.path}/apps/desktop/lib/io/fresh.dart').delete();
    final moved = File('${temp.path}/$movedDart');
    final original = moved.readAsStringSync();
    moved.writeAsStringSync(
      original.replaceFirst(
        "    return json['n'] as int? ?? 0;",
        "    if (json.isEmpty) {\n      return json['n'] as int? ?? 0;\n    }\n"
            "    return json['n'] as int? ?? 0;",
      ),
    );
    result = await run();
    _expect(
      result.exitCode == 1 &&
          result.stderr.toString().contains(
            'Unregistered behavioral findings (1)',
          ),
      'a duplicated reviewed line should fail: ${_out(result)}',
    );
    moved.writeAsStringSync(original);

    // --- An open verdict fails until it is closed. ---
    await _write(temp, 'apps/desktop/lib/io/fresh.dart', '''
int fresh(Map<String, Object?> json) {
  return json['n'] as int? ?? 0;
}
''');
    result = await run([
      '--accept-new',
      'V2',
      '--only',
      'apps/desktop/lib/io/f',
    ]);
    _expect(
      result.exitCode == 1 &&
          result.stderr.toString().contains('Open behavioral findings (1)'),
      'an open verdict should fail: ${_out(result)}',
    );
    final register = File('${temp.path}/register.md');
    register.writeAsStringSync(
      register.readAsStringSync().replaceFirst(
        '| V2 | open |',
        '| V2 | done |',
      ),
    );
    result = await run();
    _expect(result.exitCode == 0, 'a closed verdict should pass');

    // --- A verdict id missing from the register is not a pass. ---
    result = await run(['--accept-new', 'V9']);
    _expect(result.exitCode == 2, 'an unknown verdict id should be refused');

    // --- Deleted file: green, rows reported prunable, one command drops
    // them and the verdict nothing uses any more. ---
    await File('${temp.path}/apps/desktop/lib/io/fresh.dart').delete();
    result = await run();
    _expect(
      result.exitCode == 0 &&
          result.stdout.toString().contains('Prunable: 1 site rows'),
      'a deleted file should pass and report prunable rows: ${_out(result)}',
    );
    result = await run(['--sync', '--prune-verdicts']);
    _expect(result.exitCode == 0, 'sync after a delete should pass');
    _expect(
      !sites().contains('fresh'),
      'sync should drop rows for deleted code',
    );
    _expect(
      !register.readAsStringSync().contains('| V2 |') &&
          register.readAsStringSync().contains('| V1 |'),
      'only the unused verdict should be pruned',
    );

    // --- A renamed function is unregistered until --sync carries the
    // verdict to the same line under its new name. ---
    moved.writeAsStringSync(original.replaceFirst('int read(', 'int parse('));
    result = await run();
    _expect(result.exitCode == 1, 'a renamed scope should need a sync');
    result = await run(['--sync']);
    _expect(
      result.exitCode == 0 && sites().contains('\tparse\t'),
      'sync should carry the verdict to the renamed scope: ${_out(result)}',
    );

    // --- An edited line is carried only on request. ---
    moved.writeAsStringSync(
      moved.readAsStringSync().replaceFirst("json['n']", "json['count']"),
    );
    result = await run(['--sync']);
    _expect(result.exitCode == 1, 'an edited line is not carried by default');
    result = await run(['--sync', '--carry-edited']);
    _expect(
      result.exitCode == 0 && sites().contains("json['count']"),
      '--carry-edited should follow an in-place edit: ${_out(result)}',
    );

    // --- Scope floor: a package the include globs miss fails the gate. ---
    await _write(
      temp,
      'server/new_service/pubspec.yaml',
      'name: new_service\n',
    );
    await _write(temp, 'server/new_service/lib/main.dart', 'void main() {}\n');
    result = await run();
    _expect(
      result.exitCode == 1 &&
          result.stderr.toString().contains('server/new_service'),
      'an uncovered package should fail: ${_out(result)}',
    );
    await Directory('${temp.path}/server').delete(recursive: true);

    result = await run(['--min-files', '999']);
    _expect(result.exitCode == 1, 'an unmet --min-files floor should fail');

    stdout.writeln('Behavioral audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

void _testEnclosingScope() {
  void check(String ext, String source, String marker, String expected) {
    final lines = source.split('\n');
    final index = lines.indexWhere((line) => line.contains(marker));
    final actual = enclosingScope(lines, index, ext);
    _expect(
      actual == expected,
      'scope of "$marker" should be $expected, got $actual',
    );
  }

  const dart = '''
class Session extends Base {
  Session(this.id) : start = clock() ?? 0;

  final label = name ?? '';

  Future<void> load({
    required String path,
  }) async {
    if (path.isEmpty) {
      items.forEach((item) {
        use(item ?? 1);
      });
    }
  }

  int get total => count ?? 2;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(title ?? 'three'),
      ],
    );
  }
}

int topLevel(int? v) => v ?? 4;
''';
  check('.dart', dart, '?? 0', 'Session');
  check('.dart', dart, "?? ''", 'Session');
  check('.dart', dart, '?? 1', 'load');
  check('.dart', dart, '?? 2', 'total');
  check('.dart', dart, "'three'", 'build');
  check('.dart', dart, '?? 4', 'topLevel');

  const rust = '''
impl<T: Read> Parser<T> {
    pub async fn parse(
        &mut self,
        input: &str,
    ) -> Result<Value, Error> {
        match input {
            "a" => {
                let _ = self.advance();
            }
            _ => {}
        }
    }
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.release().ok();
    }
}

const LIMIT: u32 = parse_env().unwrap_or(7);

mod tests {
    #[test]
    fn round_trips() {
        let v = read().unwrap_or_default();
    }
}
''';
  check('.rs', rust, 'let _ =', 'parse');
  check('.rs', rust, '.ok();', 'drop');
  check('.rs', rust, 'unwrap_or(7)', noScope);
  check('.rs', rust, 'unwrap_or_default', 'round_trips');
}

const _dartFixture = '''
class Loader {
  int read(Map<String, Object?> json) {
    return json['n'] as int? ?? 0;
  }

  void close() {
    try {
      release();
    } catch (_) {}
  }
}
''';

const _rustFixture = '''
impl Wheel {
    pub async fn names(&self) -> Vec<String> {
        self.read_names().await.unwrap_or_default()
    }
}
''';

const _registerFixture = '''
# Fixture register

| verdict | status | owner | notes |
| --- | --- | --- | --- |
| V1 | accepted_modeled_approximation | fixture | reviewed |
| V2 | open | fixture | still being looked at |
''';

String _out(ProcessResult result) =>
    'exit ${result.exitCode}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}';

Future<void> _write(Directory root, String relativePath, String content) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

Future<void> _move(Directory root, String from, String to) async {
  final source = File('${root.path}/$from');
  await _write(root, to, source.readAsStringSync());
  await source.delete();
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
