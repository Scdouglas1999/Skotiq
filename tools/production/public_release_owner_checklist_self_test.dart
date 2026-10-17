import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/public_release_owner_checklist.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Owner checklist script not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_public_release_owner_checklist_self_test_',
  );
  try {
    await _writeFixtureAudit(temp);
    final result = await Process.run(
      'dart',
      [script.path],
      workingDirectory: temp.path,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw StateError(
        '${script.path} failed with exit ${result.exitCode}\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}',
      );
    }

    final report =
        jsonDecode(
              File(
                '${temp.path}/docs/production-readiness/public-release-owner-checklist.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final markdown = File(
      '${temp.path}/docs/production-readiness/public-release-owner-checklist.md',
    ).readAsStringSync();

    _expect(report['itemCount'] == 2, 'owner checklist should contain 2 items');
    _expect(
      report['blockedOrIncompleteCount'] == 1,
      'owner checklist should preserve blocked count',
    );
    _expect(
      (report['sourceArtifacts'] as List).length == 1,
      'owner checklist should preserve completion source artifacts',
    );
    _expect(
      report['sourceArtifactBlockerCount'] == 3,
      'owner checklist should summarize source artifact blocker counts',
    );
    _expect(
      (report['goalSectionsObserved'] as List).contains(
        'P0 Before Public Release',
      ),
      'owner checklist should preserve observed goal sections',
    );
    _expect(
      markdown.contains('Required input:') &&
          markdown.contains('- fixture input'),
      'markdown should include required input',
    );
    _expect(
      markdown.contains('- Gap: None recorded.'),
      'markdown should render empty gap fields without trailing whitespace',
    );
    _expect(
      markdown.contains('- Gap: See required input.'),
      'markdown should render required-input-only gaps without trailing whitespace',
    );
    _expect(
      markdown.contains('## Source Artifacts') &&
          markdown.contains(
            'docs/production-readiness/public-release-gate.json',
          ) &&
          markdown.contains(
            '| `docs/production-readiness/public-release-gate.json` | `true` | `2026-05-05T00:00:00.000000Z` | `NOT_READY` | `1` | `3` |',
          ),
      'markdown should include source artifact table with blocker counts',
    );
    _expect(
      markdown.contains('`fixture command`'),
      'markdown should include rerun command',
    );

    stdout.writeln('Public release owner checklist self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writeFixtureAudit(Directory root) async {
  final file = File(
    '${root.path}/docs/production-readiness/public-release-completion-audit.json',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'generatedAt': '2026-05-05T00:00:00.000000Z',
      'decision': 'NOT_ACHIEVED',
      'gateDecision': 'NOT_READY',
      'ready': false,
      'completionDecision': 'NOT_ACHIEVED',
      'completionDetail': 'fixture completion detail',
      'goalSectionsObserved': ['P0 Before Public Release'],
      'sourceArtifacts': [
        {
          'path': 'docs/production-readiness/public-release-gate.json',
          'exists': true,
          'generatedAt': '2026-05-05T00:00:00.000000Z',
          'decision': 'NOT_READY',
          'passedCount': 1,
          'blockerCount': 3,
        },
      ],
      'promptToArtifactChecklist': [
        {
          'id': 'complete_fixture',
          'requirement': 'Complete fixture requirement',
          'status': 'complete',
          'evidence': ['fixture-evidence.json'],
          'verification': 'fixture verification',
          'requiredInput': '',
          'rerunCommands': ['fixture command'],
          'acceptanceCriteria': ['fixture criterion'],
          'expectedEvidence': ['fixture expected evidence'],
          'gap': '',
        },
        {
          'id': 'blocked_fixture',
          'requirement': 'Blocked fixture requirement',
          'status': 'blocked',
          'evidence': ['blocked-evidence.json'],
          'verification': 'blocked verification',
          'requiredInput': 'fixture input',
          'rerunCommands': ['fixture command'],
          'acceptanceCriteria': ['fixture criterion'],
          'expectedEvidence': ['fixture expected evidence'],
          'gap': 'Required input: fixture input',
        },
      ],
    }),
  );
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
