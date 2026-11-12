import 'dart:convert';
import 'dart:io';

/// Self-test for tools/production/architecture_rules_audit.dart.
///
/// Builds a small workspace in a temp dir (layered pubspecs, a node table,
/// Rust crates, a baseline) that passes, then breaks one rule per case and
/// asserts the audit fails with the rule's id and its "where it goes instead"
/// text, and that the allowed places and the baseline still pass.
Future<void> main() async {
  final script = File(
    '${Directory.current.path}/tools/production/architecture_rules_audit.dart',
  );
  final scope = File(
    '${Directory.current.path}/docs/production-readiness/audit-scope.yaml',
  );
  if (!script.existsSync() || !scope.existsSync()) {
    throw StateError('Run from the repository root.');
  }

  var failures = 0;
  Future<void> check(
    String name,
    Future<void> Function(Directory root) mutate, {
    required int exitCode,
    List<String> stderrHas = const [],
    List<String> args = const [],
    Future<void> Function(Directory root)? after,
  }) async {
    final root = await Directory.systemTemp.createTemp('skotiq_arch_rules_');
    try {
      await _cleanWorkspace(root, scope);
      await mutate(root);
      final result = await Process.run('dart', [
        'run',
        script.path,
        ...args,
      ], workingDirectory: root.path);
      final err = '${result.stderr}';
      final problems = [
        if (result.exitCode != exitCode)
          'exit ${result.exitCode}, expected $exitCode',
        for (final text in stderrHas)
          if (!err.contains(text)) 'stderr lacks "$text"',
      ];
      if (problems.isEmpty && after != null) {
        try {
          await after(root);
        } on StateError catch (e) {
          problems.add(e.message);
        }
      }
      if (problems.isEmpty) {
        stdout.writeln('ok    $name');
      } else {
        failures++;
        stdout.writeln('FAIL  $name: ${problems.join('; ')}');
        stdout.writeln(result.stdout);
        stdout.writeln(err);
      }
    } finally {
      await root.delete(recursive: true);
    }
  }

  await check('clean workspace passes', (_) async {}, exitCode: 0);

  await check(
    'skotiq_ui importing skotiq_core fails',
    (root) => _write(
      root,
      'packages/skotiq_ui/lib/src/badge.dart',
      "import 'package:skotiq_core/skotiq_core.dart';\n",
    ),
    exitCode: 1,
    stderrHas: [
      '[package-direction]',
      'skotiq_ui uses skotiq_core',
      'Where it goes instead: skotiq_ui is the design system',
    ],
  );

  await check(
    'skotiq_core declaring skotiq_app in its pubspec fails',
    (root) => _write(
      root,
      'packages/skotiq_core/pubspec.yaml',
      _pubspec('skotiq_core', ['skotiq_astro', 'skotiq_app']),
    ),
    exitCode: 1,
    stderrHas: [
      'packages/skotiq_core/pubspec.yaml:',
      'skotiq_core uses skotiq_app',
    ],
  );

  await check(
    'skotiq_astro importing Flutter fails',
    (root) => _write(
      root,
      'packages/skotiq_astro/lib/src/sky.dart',
      "import 'package:flutter/foundation.dart';\n",
    ),
    exitCode: 1,
    stderrHas: ['skotiq_astro is pure Dart and may not import Flutter'],
  );

  await check(
    'a package with no layering row fails',
    (root) => _write(
      root,
      'packages/skotiq_extra/pubspec.yaml',
      _pubspec('skotiq_extra', []),
    ),
    exitCode: 1,
    stderrHas: ['package skotiq_extra has no row in the layering table'],
  );

  await check(
    'a driver crate depending on the sequencer fails',
    (root) => _write(
      root,
      'native/skotiq_native/device/Cargo.toml',
      _cargo('skotiq_device', ['skotiq_sequencer']),
    ),
    exitCode: 1,
    stderrHas: [
      'skotiq_device depends on skotiq_sequencer',
      'Driver crates speak the skotiq_device vocabulary',
    ],
  );

  await check(
    'a backend class test in app code fails',
    (root) => _write(
      root,
      'packages/skotiq_app/lib/screens/darkroom.dart',
      'bool linked(Object backend) => backend is NetworkBackend;\n',
    ),
    exitCode: 1,
    stderrHas: [
      '[backend-class]',
      'packages/skotiq_app/lib/screens/darkroom.dart:1: `is NetworkBackend`',
      'backend.remoteHost?.<role>',
    ],
  );

  await check(
    'a backend class cast fails',
    (root) => _write(
      root,
      'packages/skotiq_core/lib/src/services/files.dart',
      'void f(Object b) { final n = b as FfiBackend; }\n',
    ),
    exitCode: 1,
    stderrHas: ['`as FfiBackend`'],
  );

  await check(
    'a backend class matched as a pattern or by runtimeType fails',
    (root) => _write(
      root,
      'packages/skotiq_app/lib/screens/linked.dart',
      'bool a(Object b) => switch (b) { NetworkBackend() => true, _ => false };\n'
          'bool c(Object b) { if (b case FfiBackend _) return true; return false; }\n'
          'bool d(Object b) => b.runtimeType == DisconnectedBackend;\n',
    ),
    exitCode: 1,
    stderrHas: [
      'linked.dart:1: `NetworkBackend() =>`',
      'linked.dart:2: `case FfiBackend`',
      'linked.dart:3: `runtimeType == DisconnectedBackend`',
    ],
  );

  await check('backend class names in comments, strings, tests and the '
      'backend files pass', (root) async {
    await _write(
      root,
      'packages/skotiq_app/lib/screens/notes.dart',
      '// Not `backend is NetworkBackend`; ask remoteHost.\n'
          "const hint = 'backend is NetworkBackend';\n",
    );
    await _write(
      root,
      'packages/skotiq_app/test/fake_test.dart',
      'bool f(Object b) => b is DisconnectedBackend;\n',
    );
    await _write(
      root,
      'packages/skotiq_core/lib/src/backend/remote_host.dart',
      'bool f(Object b) => b is! NetworkBackend;\n',
    );
  }, exitCode: 0);

  await check(
    'importing another package\'s src/ fails',
    (root) => _write(
      root,
      'packages/skotiq_app/lib/screens/plan.dart',
      "import 'package:skotiq_core/src/providers/plan.dart';\n",
    ),
    exitCode: 1,
    stderrHas: [
      '[src-import]',
      'imports package:skotiq_core/src/providers/plan.dart',
      'Import the package\'s public library',
    ],
  );

  await check(
    'a baselined src/ import passes, a second one of the same file fails',
    (root) async {
      await _baseline(
        root,
        srcImport: {
          'skotiq_app -> package:skotiq_core/src/providers/plan.dart': 1,
        },
      );
      await _write(
        root,
        'packages/skotiq_app/lib/screens/plan.dart',
        "import 'package:skotiq_core/src/providers/plan.dart';\n",
      );
      await _write(
        root,
        'packages/skotiq_app/lib/screens/plan_two.dart',
        "import 'package:skotiq_core/src/providers/plan.dart';\n",
      );
    },
    exitCode: 1,
    stderrHas: ['baseline allows 1 under', 'found 2'],
  );

  await check('a baselined src/ import passes', (root) async {
    await _baseline(
      root,
      srcImport: {
        'skotiq_app -> package:skotiq_core/src/providers/plan.dart': 1,
      },
    );
    await _write(
      root,
      'packages/skotiq_app/lib/moved/deeper/plan.dart',
      "import 'package:skotiq_core/src/providers/plan.dart';\n",
    );
  }, exitCode: 0);

  await check(
    'a new switch over node types fails',
    (root) => _write(
      root,
      'packages/skotiq_app/lib/screens/sequencer/row_color.dart',
      _dartSwitch('rowColor', 8),
    ),
    exitCode: 1,
    stderrHas: [
      '[node-dispatch]',
      'row_color.dart:2: switch over 8 node types',
      'a field of NodeKind',
    ],
  );

  await check('a switch over fewer node types, and the node table, pass', (
    root,
  ) async {
    await _write(
      root,
      'packages/skotiq_app/lib/screens/sequencer/row_color.dart',
      _dartSwitch('rowColor', 7),
    );
    await _write(
      root,
      'packages/skotiq_core/lib/src/models/sequence/sequence_models/node_kind.dart',
      _dartSwitch('describeAll', 10),
    );
  }, exitCode: 0);

  await check(
    'a new `is` chain over node types fails',
    (root) => _write(
      root,
      'packages/skotiq_core/lib/src/services/overhead.dart',
      [
        'class Overhead {',
        '  int secondsFor(Object node) {',
        for (var i = 0; i < 8; i++) '    if (node is N${i}Node) return $i;',
        '    return 0;',
        '  }',
        '}',
      ].join('\n'),
    ),
    exitCode: 1,
    stderrHas: ['overhead.dart:3: `is` chain over 8 node types'],
  );

  await check(
    'a baselined dispatch passes under its declaration name after a move',
    (root) async {
      await _baseline(root, nodeDispatch: {'row_color.dart::rowColor': 1});
      await _write(
        root,
        'packages/skotiq_app/lib/elsewhere/row_color.dart',
        '\n\n\n${_dartSwitch('rowColor', 9)}',
      );
    },
    exitCode: 0,
  );

  await check(
    'a new Rust match over NodeType fails',
    (root) => _write(
      root,
      'native/skotiq_native/sequencer/src/executor/budget.rs',
      [
        'impl Budget {',
        '    fn frames(node: &NodeType) -> u32 {',
        '        match node {',
        for (var i = 0; i < 8; i++) '            NodeType::Kind$i(_) => $i,',
        '            _ => 0,',
        '        }',
        '    }',
        '}',
      ].join('\n'),
    ),
    exitCode: 1,
    stderrHas: ['budget.rs:3: match over 8 NodeType variants'],
  );

  await check(
    '--sync-baseline lowers and drops entries and never adds one',
    (root) async {
      await _baseline(
        root,
        srcImport: {
          'skotiq_app -> package:skotiq_core/src/gone.dart': 2,
          'skotiq_app -> package:skotiq_core/src/kept.dart': 3,
        },
      );
      await _write(
        root,
        'packages/skotiq_app/lib/kept.dart',
        "import 'package:skotiq_core/src/kept.dart';\n",
      );
    },
    exitCode: 0,
    args: ['--sync-baseline'],
    after: (root) async {
      final doc =
          jsonDecode(
                await File(
                  '${root.path}/tools/production/architecture_rules_baseline.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final allowed =
          (doc['srcImport'] as Map<String, dynamic>)['allowed']
              as Map<String, dynamic>;
      if (allowed.length != 1 ||
          allowed['skotiq_app -> package:skotiq_core/src/kept.dart'] != 1) {
        throw StateError('synced baseline is $allowed');
      }
    },
  );

  if (failures > 0) {
    stderr.writeln('$failures architecture rules self-test case(s) failed.');
    exit(1);
  }
  stdout.writeln('Architecture rules audit self-test passed.');
}

const _layers = {
  'packages/skotiq_astro': ('skotiq_astro', <String>[]),
  'packages/skotiq_ui': ('skotiq_ui', ['skotiq_astro']),
  'packages/skotiq_core': ('skotiq_core', ['skotiq_astro']),
  'packages/skotiq_app': (
    'skotiq_app',
    ['skotiq_astro', 'skotiq_core', 'skotiq_ui'],
  ),
  'apps/desktop': ('skotiq_desktop', ['skotiq_app', 'skotiq_core']),
};

Future<void> _cleanWorkspace(Directory root, File scope) async {
  await _write(
    root,
    'docs/production-readiness/audit-scope.yaml',
    await scope.readAsString(),
  );
  for (final MapEntry(key: dir, value: (name, deps)) in _layers.entries) {
    await _write(root, '$dir/pubspec.yaml', _pubspec(name, deps));
    await _write(root, '$dir/lib/$name.dart', 'library;\n');
  }
  await _write(
    root,
    'packages/skotiq_app/lib/screens/home.dart',
    "import 'package:skotiq_core/skotiq_core.dart';\n"
        "import 'package:skotiq_ui/skotiq_ui.dart';\n"
        'bool linked(Object b) => b.remoteHost != null;\n',
  );
  await _write(
    root,
    'packages/skotiq_core/lib/src/models/sequence/sequence_models/node_kinds.dart',
    [
      for (var i = 0; i < 10; i++) 'final n$i = NodeKind<N${i}Node>();',
    ].join('\n'),
  );
  await _write(
    root,
    'packages/skotiq_core/lib/src/backend/network_backend.dart',
    'class NetworkBackend {}\n',
  );
  await _write(
    root,
    'native/skotiq_native/device/Cargo.toml',
    _cargo('skotiq_device', []),
  );
  await _write(root, 'native/skotiq_native/device/src/lib.rs', '');
  await _write(
    root,
    'native/skotiq_native/sequencer/Cargo.toml',
    _cargo('skotiq_sequencer', ['skotiq_device']),
  );
  await _write(
    root,
    'native/skotiq_native/sequencer/src/lib.rs',
    [
      'impl NodeType {',
      '    pub fn wire_name(&self) -> &str {',
      '        match self {',
      for (var i = 0; i < 10; i++) '            NodeType::Kind$i(_) => "k$i",',
      '        }',
      '    }',
      '}',
    ].join('\n'),
  );
  await _baseline(root);
}

Future<void> _baseline(
  Directory root, {
  Map<String, int> srcImport = const {},
  Map<String, int> nodeDispatch = const {},
}) => _write(
  root,
  'tools/production/architecture_rules_baseline.json',
  jsonEncode({
    'backendClass': {'allowed': <String, Object>{}},
    'srcImport': {'allowed': srcImport},
    'nodeDispatch': {
      'allowed': {
        for (final e in nodeDispatch.entries)
          e.key: {'count': e.value, 'reason': 'self-test'},
      },
    },
  }),
);

String _dartSwitch(String name, int types) => [
  'String $name(Object node) {',
  '  return switch (node) {',
  for (var i = 0; i < types; i++) "    N${i}Node() => 'n$i',",
  "    _ => 'other',",
  '  };',
  '}',
].join('\n');

String _pubspec(String name, List<String> deps) => [
  'name: $name',
  'environment:',
  "  sdk: '>=3.8.0 <4.0.0'",
  'dependencies:',
  for (final dep in deps) '  $dep:\n    path: ../$dep',
  'dev_dependencies:',
  '  test: any',
  '',
].join('\n');

String _cargo(String name, List<String> deps) => [
  '[package]',
  'name = "$name"',
  '',
  '[dependencies]',
  'serde = "1"',
  for (final dep in deps) '$dep = { path = "../$dep" }',
  '',
].join('\n');

Future<void> _write(Directory root, String relative, String content) async {
  final file = File('${root.path}/$relative');
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}
