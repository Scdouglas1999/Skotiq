import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

/// The updater and the plugins cannot import core's `Log`; what they log must
/// still reach the app log (the file, the Log Viewer, the remote tail), once.
void main() {
  late Directory dataRoot;
  late LoggingService service;

  setUp(() async {
    dataRoot = Directory.systemTemp.createTempSync('sk-leaf-log');
    service = LoggingService(
      applicationSupportDirectoryProvider: () async => dataRoot,
      environment: {skotiqDataDirEnv: dataRoot.path},
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await service.initialize();
    Log.attach(service);
  });

  tearDown(() async {
    Log.detach(service);
    await service.dispose();
    dataRoot.deleteSync(recursive: true);
  });

  List<LogEntry> from(String source) =>
      service.getRecentLogs().where((e) => e.source == source).toList();

  String fileText() => Directory('${dataRoot.path}/logs')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains(dartLogFileBaseName))
      .map((f) => f.readAsStringSync())
      .join();

  test('an updater warning reaches the log file once', () async {
    Directory('${dataRoot.path}/updates').createSync();
    File(
      '${dataRoot.path}/updates/prompt_state.json',
    ).writeAsStringSync('{not json');

    await UpdatePromptStore(() async => dataRoot).read();

    final entries = from('UpdatePromptStore');
    expect(entries, hasLength(1));
    expect(entries.single.level, LogLevel.warning);
    expect(entries.single.message, contains('Failed to read update prompt'));
    final lines = fileText()
        .split('\n')
        .where((l) => l.contains('Failed to read update prompt'));
    expect(lines, hasLength(1));
    expect(lines.single, contains('WARNING'));
    expect(lines.single, contains('[UpdatePromptStore]'));
  });

  test('a plugin error reaches the log once under the plugin id', () {
    final context = PluginContextFactory(
      storageFactory: (_) => InMemoryPluginStorage(),
    ).createContext('demo.weather');

    context.logger.error('Station offline', StateError('timeout'));

    final entries = from('Plugin.demo.weather');
    expect(entries, hasLength(1));
    expect(entries.single.level, LogLevel.error);
    expect(entries.single.message, 'Station offline: Bad state: timeout');
  });
}
