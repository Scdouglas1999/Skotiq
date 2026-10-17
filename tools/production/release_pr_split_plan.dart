import 'dart:convert';
import 'dart:io';

const _inputPath = 'docs/production-readiness/release-staging-audit.json';
const _jsonOutputPath = 'docs/production-readiness/release-pr-split-plan.json';
const _markdownOutputPath =
    'docs/production-readiness/release-pr-split-plan.md';
const _pathspecDirectory = 'docs/production-readiness/release-pr-pathspecs';
const _draftDescriptionsDirectory =
    'docs/production-readiness/release-pr-drafts';
const _releaseListsDirectory = 'docs/production-readiness/release-pr-lists';
final _pathspecFilePattern = RegExp(r'^\d\d-[a-z0-9-]+\.txt$');
final _draftFilePattern = RegExp(r'^\d\d-[a-z0-9-]+\.md$');
final _releaseListFilePattern = RegExp(r'^\d\d-[a-z0-9-]+\.txt$');

const _releaseListDefinitions = [
  _ReleaseListDefinition(
    id: 'must-ship',
    title: 'Must Ship',
    fileName: '01-must-ship.txt',
    description:
        'Release-critical source, docs, and tooling paths that are not generated outputs or binary/evidence artifacts.',
  ),
  _ReleaseListDefinition(
    id: 'generated-only',
    title: 'Generated Only',
    fileName: '02-generated-only.txt',
    description:
        'Generated files that should be reviewed against their source changes and generator commands.',
  ),
  _ReleaseListDefinition(
    id: 'binary-evidence',
    title: 'Binary And Evidence',
    fileName: '03-binary-evidence.txt',
    description:
        'Binary payloads, screenshots, APKs, DLLs, and other evidence artifacts that need explicit artifact review.',
  ),
  _ReleaseListDefinition(
    id: 'defer-exclude',
    title: 'Defer Or Exclude',
    fileName: '04-defer-exclude.txt',
    description:
        'Non-release-critical paths that need owner review before they are staged into a public release branch.',
  ),
];

const _bucketDefinitions = [
  _BucketDefinition(
    id: 'generated-files',
    title: 'Generated Files',
    intent:
        'Review regenerated Dart, Drift, Freezed, bridge, and lock files apart from human-authored source.',
    recommendedAction:
        'Regenerate from source, verify generator commands, then stage only outputs that correspond to reviewed model/API changes.',
  ),
  _BucketDefinition(
    id: 'binary-and-evidence-artifacts',
    title: 'Binary And Evidence Artifacts',
    intent:
        'Review DLLs, APKs, screenshots, databases, and other binary artifacts outside normal source diffs.',
    recommendedAction:
        'Keep release payload binaries and smoke evidence in a deliberate artifact review; exclude scratch screenshots and research blobs from the release PR.',
  ),
  _BucketDefinition(
    id: 'release-infra-evidence',
    title: 'Release Infrastructure And Evidence',
    intent:
        'Keep release gates, production audit tools, public readiness docs, and operational docs together.',
    recommendedAction:
        'Stage audit tooling and evidence docs as the release-readiness PR only after confirming each artifact is current and reproducible.',
  ),
  _BucketDefinition(
    id: 'headless-remote-api',
    title: 'Headless Remote API And Dashboard',
    intent:
        'Review headless server routes, auth policy, dashboard assets, LAN behavior, and WebSocket changes as one API surface.',
    recommendedAction:
        'Pair this bucket with route contract tests, dashboard smoke logs, auth/LAN evidence, and reconnect evidence.',
  ),
  _BucketDefinition(
    id: 'mobile-remote-client',
    title: 'Mobile Remote Client',
    intent:
        'Review Android/mobile remote-client code and mobile smoke tooling separately from desktop/headless server changes.',
    recommendedAction:
        'Stage with Android build metadata and emulator smoke artifacts only after confirming the server API bucket it depends on is reviewed.',
  ),
  _BucketDefinition(
    id: 'native-driver-bridge',
    title: 'Native Driver And Bridge Source',
    intent:
        'Review Rust native code, driver integrations, Flutter Rust Bridge source, and bridge package API changes together.',
    recommendedAction:
        'Keep source changes apart from compiled DLLs; require platform build evidence and driver capability notes before release staging.',
  ),
  _BucketDefinition(
    id: 'core-data-model',
    title: 'Core Data Model And Services',
    intent:
        'Review database, model, provider, backend, migration, and shared service changes as a data/API compatibility set.',
    recommendedAction:
        'Stage with focused tests and a release-authentic older-profile migration artifact; generated DB/model files stay in the generated-files bucket.',
  ),
  _BucketDefinition(
    id: 'desktop-ui-workflows',
    title: 'Desktop UI And Workflow Packages',
    intent:
        'Review app UI, shared UI system, planetarium, plugin, updater, WebRTC, and desktop workflow changes together or split by screen if too large.',
    recommendedAction:
        'Use UI consistency audit results and focused screenshot/smoke evidence before moving these paths into a release PR.',
  ),
  _BucketDefinition(
    id: 'tests-and-support-tooling',
    title: 'Tests And Support Tooling',
    intent:
        'Review non-release test files, scripts, package config, and developer tooling separately from product behavior.',
    recommendedAction:
        'Stage only support changes needed to verify the release; defer unrelated audit scratch or developer-only helpers.',
  ),
  _BucketDefinition(
    id: 'out-of-release-scope-review',
    title: 'Out Of Release Scope Review',
    intent:
        'Quarantine scratch reports, research files, goal tracking, and broad miscellaneous edits until they are explicitly accepted or excluded.',
    recommendedAction:
        'Do not stage into the public release branch without owner review and an explicit reason.',
  ),
];

void main() async {
  final inputFile = File(_inputPath);
  if (!inputFile.existsSync()) {
    stderr.writeln('Missing release staging audit: $_inputPath');
    stderr.writeln('Run: dart run melos run audit:release-staging --no-select');
    exit(1);
  }

  final audit =
      jsonDecode(inputFile.readAsStringSync()) as Map<String, dynamic>;
  final entries = _readEntries(audit);
  final buckets = <_PlannedBucket>[
    for (final definition in _bucketDefinitions) _PlannedBucket(definition),
  ];
  final bucketById = {
    for (final bucket in buckets) bucket.definition.id: bucket,
  };

  for (final entry in entries) {
    bucketById[_bucketIdFor(entry)]!.entries.add(entry);
  }

  final nonEmptyBuckets = buckets
      .where((bucket) => bucket.entries.isNotEmpty)
      .toList();
  final releaseLists = _buildReleaseLists(entries);

  await _writePathspecFiles(nonEmptyBuckets);
  await _writeDraftDescriptionFiles(nonEmptyBuckets);
  await _writeReleaseListFiles(releaseLists);

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'sourceStagingAudit': _inputPath,
    'sourceGeneratedAt': audit['generatedAt'],
    'currentBranch': audit['currentBranch'],
    'head': audit['head'],
    'entryCount': entries.length,
    'bucketCount': nonEmptyBuckets.length,
    'draftDescriptionsDirectory': _draftDescriptionsDirectory,
    'releaseListsDirectory': _releaseListsDirectory,
    'untrackedReleaseCriticalCount':
        audit['untrackedReleaseCriticalCount'] ??
        _countUntrackedCritical(entries),
    'summary': {
      'trackedChangeCount': entries
          .where((entry) => entry.isTrackedChange)
          .length,
      'untrackedCount': entries.where((entry) => entry.isUntracked).length,
      'deletedCount': entries.where((entry) => entry.isDeleted).length,
      'generatedCount': entries.where((entry) => entry.generated).length,
      'binaryCount': entries.where((entry) => entry.binary).length,
      'releaseCriticalCount': entries
          .where((entry) => entry.releaseCritical)
          .length,
    },
    'buckets': [
      for (var i = 0; i < nonEmptyBuckets.length; i++)
        nonEmptyBuckets[i].toJson(i + 1),
    ],
    'releaseLists': [for (final list in releaseLists) list.toJson()],
  };

  await File(
    _jsonOutputPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(_markdownOutputPath).writeAsString(
    _renderMarkdown(
      audit: audit,
      buckets: nonEmptyBuckets,
      entries: entries,
      releaseLists: releaseLists,
    ),
  );

  stdout.writeln('Release PR split plan complete.');
  stdout.writeln('Entries assigned: ${entries.length}');
  stdout.writeln('Non-empty buckets: ${nonEmptyBuckets.length}');
  stdout.writeln('Pathspecs: $_pathspecDirectory');
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');
}

Future<void> _writePathspecFiles(List<_PlannedBucket> buckets) async {
  final directory = Directory(_pathspecDirectory);
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }

  final staleFiles = directory.listSync().whereType<File>().where(
    (file) => _pathspecFilePattern.hasMatch(_fileName(file.path)),
  );
  for (final file in staleFiles) {
    file.deleteSync();
  }

  for (var i = 0; i < buckets.length; i++) {
    final bucket = buckets[i];
    await File(bucket.pathspecPath(i + 1)).writeAsString(
      '${bucket.entries.map((entry) => entry.path).join('\n')}\n',
    );
  }
}

Future<void> _writeDraftDescriptionFiles(List<_PlannedBucket> buckets) async {
  final directory = Directory(_draftDescriptionsDirectory);
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }

  final staleFiles = directory.listSync().whereType<File>().where(
    (file) => _draftFilePattern.hasMatch(_fileName(file.path)),
  );
  for (final file in staleFiles) {
    file.deleteSync();
  }

  for (var i = 0; i < buckets.length; i++) {
    final order = i + 1;
    final bucket = buckets[i];
    await File(
      bucket.draftDescriptionPath(order),
    ).writeAsString(_renderDraftDescription(bucket, order));
  }
}

Future<void> _writeReleaseListFiles(List<_ReleaseList> lists) async {
  final directory = Directory(_releaseListsDirectory);
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }

  final staleFiles = directory.listSync().whereType<File>().where(
    (file) => _releaseListFilePattern.hasMatch(_fileName(file.path)),
  );
  for (final file in staleFiles) {
    file.deleteSync();
  }

  for (final list in lists) {
    await File(
      list.path,
    ).writeAsString('${list.entries.map((entry) => entry.path).join('\n')}\n');
  }
}

String _fileName(String path) => path.replaceAll('\\', '/').split('/').last;

List<_StatusEntry> _readEntries(Map<String, dynamic> audit) {
  final categories = audit['categories'] as Map<String, dynamic>? ?? const {};
  final entries = <_StatusEntry>[];
  for (final categoryEntry in categories.entries) {
    final category = categoryEntry.key;
    final value = categoryEntry.value as Map<String, dynamic>? ?? const {};
    final paths = value['paths'] as List? ?? const [];
    for (final pathEntry in paths) {
      entries.add(
        _StatusEntry.fromJson(
          pathEntry as Map<String, dynamic>,
          category: category,
        ),
      );
    }
  }
  entries.sort((a, b) => a.path.compareTo(b.path));
  return entries;
}

int _countUntrackedCritical(List<_StatusEntry> entries) {
  return entries
      .where((entry) => entry.isUntracked && entry.releaseCritical)
      .length;
}

String _bucketIdFor(_StatusEntry entry) {
  if (entry.generated) return 'generated-files';
  if (entry.binary) return 'binary-and-evidence-artifacts';

  final path = entry.path;
  final category = entry.category;

  if (path.startsWith('docs/production-readiness/') ||
      path.startsWith('.github/workflows/') ||
      path.startsWith('apps/desktop/linux/') ||
      path == 'docs/headless-secure-setup.md' ||
      path == 'docs/migration-backup-restore.md' ||
      path == 'docs/known-limitations.md' ||
      path == 'docs/release-notes-template.md' ||
      path == 'docs/supported-hardware-by-platform.md' ||
      path.startsWith('docs/troubleshooting/') ||
      path.startsWith('packaging/appliance/') ||
      path.startsWith('tools/production/') ||
      path == 'package.json' ||
      path == 'melos.yaml' ||
      path.endsWith('/tool/production_migration_probe.dart')) {
    return 'release-infra-evidence';
  }

  if (category == 'headless-remote' ||
      path.startsWith('apps/desktop/lib/headless_api') ||
      path == 'apps/desktop/lib/headless_api_server.dart' ||
      path == 'apps/desktop/lib/main_headless.dart' ||
      path.startsWith('apps/desktop/web_dashboard/')) {
    return 'headless-remote-api';
  }

  if (category == 'mobile' || path.startsWith('apps/mobile/')) {
    return 'mobile-remote-client';
  }

  if (category == 'native-rust' ||
      category == 'bridge' ||
      path.startsWith('native/skotiq_native/') ||
      path.startsWith('packages/skotiq_bridge/')) {
    return 'native-driver-bridge';
  }

  if (category == 'core' || path.startsWith('packages/skotiq_core/lib/')) {
    return 'core-data-model';
  }

  if (category == 'app-ui' ||
      category == 'ui-system' ||
      category == 'planetarium' ||
      category == 'plugins' ||
      category == 'updater' ||
      category == 'remote-protocol' ||
      path.startsWith('packages/skotiq_app/lib/') ||
      path.startsWith('packages/skotiq_ui/') ||
      path.startsWith('packages/skotiq_planetarium/') ||
      path.startsWith('packages/skotiq_plugins/') ||
      path.startsWith('packages/skotiq_updater/') ||
      path.startsWith('packages/skotiq_remote_protocol/') ||
      path.startsWith('apps/desktop/lib/')) {
    return 'desktop-ui-workflows';
  }

  if (category == 'tests' ||
      category == 'tooling' ||
      category == 'package-config' ||
      path.contains('/test/') ||
      path.endsWith('_test.dart') ||
      path.startsWith('tools/') ||
      path.startsWith('scripts/') ||
      path.endsWith('pubspec.yaml') ||
      path.endsWith('Cargo.toml')) {
    return 'tests-and-support-tooling';
  }

  return 'out-of-release-scope-review';
}

String _renderMarkdown({
  required Map<String, dynamic> audit,
  required List<_PlannedBucket> buckets,
  required List<_StatusEntry> entries,
  required List<_ReleaseList> releaseLists,
}) {
  final branch = audit['currentBranch']?.toString() ?? 'unknown';
  final head = audit['head']?.toString() ?? 'unknown';
  final untrackedCritical =
      audit['untrackedReleaseCriticalCount'] ??
      _countUntrackedCritical(entries);
  final buffer = StringBuffer()
    ..writeln('# Release PR Split Plan')
    ..writeln()
    ..writeln('- Source audit: `$_inputPath`')
    ..writeln('- Branch: `$branch`')
    ..writeln('- HEAD: `$head`')
    ..writeln(
      '- Entries assigned to proposed review buckets: `${entries.length}`',
    )
    ..writeln('- Non-empty buckets: `${buckets.length}`')
    ..writeln('- Untracked release-critical entries: `$untrackedCritical`')
    ..writeln('- Pathspec directory: `$_pathspecDirectory`')
    ..writeln('- Draft PR descriptions: `$_draftDescriptionsDirectory`')
    ..writeln('- Release decision lists: `$_releaseListsDirectory`')
    ..writeln()
    ..writeln(
      'This is a planning artifact. It does not stage files, create a branch, create a PR, or make the public release gate pass.',
    )
    ..writeln()
    ..writeln('## Bucket Summary')
    ..writeln()
    ..writeln(
      '| Suggested order | Bucket | Count | Untracked | Release-critical | Generated | Binary |',
    )
    ..writeln('| ---: | --- | ---: | ---: | ---: | ---: | ---: |');

  for (var i = 0; i < buckets.length; i++) {
    final bucket = buckets[i];
    buffer.writeln(
      '| ${i + 1} | ${bucket.definition.title} | ${bucket.entries.length} | '
      '${bucket.untrackedCount} | ${bucket.releaseCriticalCount} | '
      '${bucket.generatedCount} | ${bucket.binaryCount} |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Release Decision Lists')
    ..writeln()
    ..writeln(
      'The lists below are mutually exclusive. Generated and binary/evidence paths are separated before release-critical source/docs paths so reviewers can stage those concern areas independently.',
    )
    ..writeln()
    ..writeln('| List | Count | File | Description |')
    ..writeln('| --- | ---: | --- | --- |');

  for (final list in releaseLists) {
    buffer.writeln(
      '| ${list.definition.title} | ${list.entries.length} | '
      '`${list.path}` | ${list.definition.description} |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Proposed Review Buckets')
    ..writeln();

  for (var i = 0; i < buckets.length; i++) {
    final bucket = buckets[i];
    buffer
      ..writeln('### ${i + 1}. ${bucket.definition.title}')
      ..writeln()
      ..writeln('- Bucket ID: `${bucket.definition.id}`')
      ..writeln('- Count: `${bucket.entries.length}`')
      ..writeln('- Pathspec file: `${bucket.pathspecPath(i + 1)}`')
      ..writeln(
        '- Draft PR description: `${bucket.draftDescriptionPath(i + 1)}`',
      )
      ..writeln(
        '- Stage command: `git add --pathspec-from-file=${bucket.pathspecPath(i + 1)}`',
      )
      ..writeln('- Tracked changes: `${bucket.trackedChangeCount}`')
      ..writeln('- Untracked: `${bucket.untrackedCount}`')
      ..writeln('- Deleted: `${bucket.deletedCount}`')
      ..writeln('- Release-critical: `${bucket.releaseCriticalCount}`')
      ..writeln('- Intent: ${bucket.definition.intent}')
      ..writeln('- Recommended action: ${bucket.definition.recommendedAction}')
      ..writeln()
      ..writeln('Category mix:')
      ..writeln();

    final categories = bucket.categoryCounts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final category in categories) {
      buffer.writeln('- `${category.key}`: `${category.value}`');
    }

    _writeEntryExamples(buffer, bucket.entries);
  }

  buffer
    ..writeln('## Release Branch Implication')
    ..writeln()
    ..writeln(
      'A clean public release branch still requires each bucket to be staged, excluded, or split into smaller PRs intentionally. The current branch remains `$branch`, so this plan is evidence for scoping only, not release readiness.',
    );

  return buffer.toString();
}

String _renderDraftDescription(_PlannedBucket bucket, int order) {
  final pathspecPath = bucket.pathspecPath(order);
  final mustShipCount = bucket.entries
      .where((entry) => entry.releaseCritical)
      .length;
  final generatedCount = bucket.generatedCount;
  final binaryCount = bucket.binaryCount;
  final deferCount = bucket.entries.length - mustShipCount;
  final categories = bucket.categoryCounts.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final examples = bucket.entries.take(20).toList(growable: false);

  final buffer = StringBuffer()
    ..writeln(
      '# PR ${order.toString().padLeft(2, '0')}: '
      '${bucket.definition.title}',
    )
    ..writeln()
    ..writeln('## Summary')
    ..writeln()
    ..writeln(bucket.definition.intent)
    ..writeln()
    ..writeln(
      'Recommended staging decision: '
      '${bucket.definition.recommendedAction}',
    )
    ..writeln()
    ..writeln('## Scope')
    ..writeln()
    ..writeln('- Bucket ID: `${bucket.definition.id}`')
    ..writeln('- Path count: `${bucket.entries.length}`')
    ..writeln('- Tracked changes: `${bucket.trackedChangeCount}`')
    ..writeln('- Untracked paths: `${bucket.untrackedCount}`')
    ..writeln('- Deleted paths: `${bucket.deletedCount}`')
    ..writeln('- Must-ship/release-critical paths: `$mustShipCount`')
    ..writeln('- Generated-only paths: `$generatedCount`')
    ..writeln('- Binary/evidence paths: `$binaryCount`')
    ..writeln('- Defer/exclude review paths: `$deferCount`')
    ..writeln()
    ..writeln(
      'Decision lists are generated in `$_releaseListsDirectory` for must-ship, generated-only, binary/evidence, and defer/exclude paths.',
    )
    ..writeln()
    ..writeln('## Stage Command')
    ..writeln()
    ..writeln('```powershell')
    ..writeln('git add --pathspec-from-file=$pathspecPath')
    ..writeln('```')
    ..writeln()
    ..writeln('## Review Notes')
    ..writeln()
    ..writeln('- Confirm every untracked path is intentional before staging.')
    ..writeln('- Confirm generated files were produced from reviewed source.')
    ..writeln(
      '- Keep binary payloads and evidence artifacts only when they are '
      'required for this release PR.',
    )
    ..writeln(
      '- Move defer/exclude paths out of the staged set unless an owner '
      'explicitly accepts them.',
    )
    ..writeln()
    ..writeln('## Category Mix')
    ..writeln();

  for (final category in categories) {
    buffer.writeln('- `${category.key}`: `${category.value}`');
  }

  buffer
    ..writeln()
    ..writeln('## Representative Paths')
    ..writeln();

  for (final entry in examples) {
    buffer.writeln('- `${entry.status}` `${entry.path}` (${entry.category})');
  }
  if (bucket.entries.length > examples.length) {
    buffer.writeln(
      '- ... ${bucket.entries.length - examples.length} more paths in '
      '`$pathspecPath`.',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Verification')
    ..writeln()
    ..writeln('- [ ] Run the focused tests or audits named by this bucket.')
    ..writeln(
      '- [ ] Re-run `dart run tools/production/release_staging_audit.dart`.',
    )
    ..writeln(
      '- [ ] Re-run `dart run tools/production/release_pr_split_plan.dart`.',
    )
    ..writeln(
      '- [ ] Re-run `dart run tools/production/release_pr_staged_branch_validator.dart` on the staged branch.',
    )
    ..writeln()
    ..writeln('## Release Gate Impact')
    ..writeln()
    ..writeln(
      'This draft does not make the public release gate pass by itself. The staged branch still needs the external evidence and owner sign-off recorded by `docs/production-readiness/public-release-gate.md`.',
    );

  return buffer.toString();
}

List<_ReleaseList> _buildReleaseLists(List<_StatusEntry> entries) {
  final byId = {
    for (final definition in _releaseListDefinitions)
      definition.id: _ReleaseList(definition),
  };

  for (final entry in entries) {
    byId[_releaseListIdFor(entry)]!.entries.add(entry);
  }

  return [
    for (final definition in _releaseListDefinitions) byId[definition.id]!,
  ];
}

String _releaseListIdFor(_StatusEntry entry) {
  if (entry.generated) return 'generated-only';
  if (entry.binary) return 'binary-evidence';
  if (entry.releaseCritical) return 'must-ship';
  return 'defer-exclude';
}

void _writeEntryExamples(StringBuffer buffer, List<_StatusEntry> entries) {
  const limit = 30;
  buffer
    ..writeln()
    ..writeln('Examples:')
    ..writeln();

  for (final entry in entries.take(limit)) {
    buffer.writeln('- `${entry.status}` `${entry.path}` (${entry.category})');
  }
  if (entries.length > limit) {
    buffer.writeln('- ... ${entries.length - limit} more entries in JSON.');
  }
  buffer.writeln();
}

class _BucketDefinition {
  final String id;
  final String title;
  final String intent;
  final String recommendedAction;

  const _BucketDefinition({
    required this.id,
    required this.title,
    required this.intent,
    required this.recommendedAction,
  });
}

class _ReleaseListDefinition {
  final String id;
  final String title;
  final String fileName;
  final String description;

  const _ReleaseListDefinition({
    required this.id,
    required this.title,
    required this.fileName,
    required this.description,
  });
}

class _ReleaseList {
  final _ReleaseListDefinition definition;
  final List<_StatusEntry> entries = [];

  _ReleaseList(this.definition);

  String get path => '$_releaseListsDirectory/${definition.fileName}';

  Map<String, Object?> toJson() => {
    'id': definition.id,
    'title': definition.title,
    'description': definition.description,
    'pathspecFile': path,
    'count': entries.length,
    'trackedChangeCount': entries
        .where((entry) => entry.isTrackedChange)
        .length,
    'untrackedCount': entries.where((entry) => entry.isUntracked).length,
    'deletedCount': entries.where((entry) => entry.isDeleted).length,
    'releaseCriticalCount': entries
        .where((entry) => entry.releaseCritical)
        .length,
    'paths': entries.map((entry) => entry.toJson()).toList(),
  };
}

class _PlannedBucket {
  final _BucketDefinition definition;
  final List<_StatusEntry> entries = [];

  _PlannedBucket(this.definition);

  String pathspecFileName(int order) {
    final prefix = order.toString().padLeft(2, '0');
    return '$prefix-${definition.id}.txt';
  }

  String pathspecPath(int order) {
    return '$_pathspecDirectory/${pathspecFileName(order)}';
  }

  String draftDescriptionFileName(int order) {
    final prefix = order.toString().padLeft(2, '0');
    return '$prefix-${definition.id}.md';
  }

  String draftDescriptionPath(int order) {
    return '$_draftDescriptionsDirectory/${draftDescriptionFileName(order)}';
  }

  int get trackedChangeCount =>
      entries.where((entry) => entry.isTrackedChange).length;
  int get untrackedCount => entries.where((entry) => entry.isUntracked).length;
  int get deletedCount => entries.where((entry) => entry.isDeleted).length;
  int get generatedCount => entries.where((entry) => entry.generated).length;
  int get binaryCount => entries.where((entry) => entry.binary).length;
  int get releaseCriticalCount =>
      entries.where((entry) => entry.releaseCritical).length;

  Map<String, int> get categoryCounts {
    final counts = <String, int>{};
    for (final entry in entries) {
      counts.update(entry.category, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  Map<String, Object?> toJson(int order) => {
    'id': definition.id,
    'title': definition.title,
    'intent': definition.intent,
    'recommendedAction': definition.recommendedAction,
    'pathspecFile': pathspecPath(order),
    'draftDescriptionFile': draftDescriptionPath(order),
    'stageCommand': 'git add --pathspec-from-file=${pathspecPath(order)}',
    'count': entries.length,
    'trackedChangeCount': trackedChangeCount,
    'untrackedCount': untrackedCount,
    'deletedCount': deletedCount,
    'generatedCount': generatedCount,
    'binaryCount': binaryCount,
    'releaseCriticalCount': releaseCriticalCount,
    'categoryCounts': categoryCounts,
    'paths': entries.map((entry) => entry.toJson()).toList(),
  };
}

class _StatusEntry {
  final String status;
  final String indexStatus;
  final String worktreeStatus;
  final String path;
  final String category;
  final bool untracked;
  final bool deleted;
  final bool generated;
  final bool binary;
  final bool releaseCritical;

  const _StatusEntry({
    required this.status,
    required this.indexStatus,
    required this.worktreeStatus,
    required this.path,
    required this.category,
    required this.untracked,
    required this.deleted,
    required this.generated,
    required this.binary,
    required this.releaseCritical,
  });

  factory _StatusEntry.fromJson(
    Map<String, dynamic> json, {
    required String category,
  }) {
    return _StatusEntry(
      status: json['status']?.toString() ?? '??',
      indexStatus: json['indexStatus']?.toString() ?? '?',
      worktreeStatus: json['worktreeStatus']?.toString() ?? '?',
      path: json['path']?.toString() ?? '',
      category: json['category']?.toString() ?? category,
      untracked: json['untracked'] == true,
      deleted: json['deleted'] == true,
      generated: json['generated'] == true,
      binary: json['binary'] == true,
      releaseCritical: json['releaseCritical'] == true,
    );
  }

  bool get isUntracked => untracked;
  bool get isDeleted => deleted;
  bool get isTrackedChange => !untracked;

  Map<String, Object?> toJson() => {
    'status': status,
    'indexStatus': indexStatus,
    'worktreeStatus': worktreeStatus,
    'path': path,
    'category': category,
    'untracked': untracked,
    'deleted': deleted,
    'generated': generated,
    'binary': binary,
    'releaseCritical': releaseCritical,
  };
}
