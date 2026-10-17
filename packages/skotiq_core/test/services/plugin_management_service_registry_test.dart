import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late Directory directory;
  late LoggingService logger;
  late PluginManagementService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin_registry_test_');
    logger = LoggingService(
      applicationSupportDirectoryProvider: () async => directory,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    service = PluginManagementService(
      logger: logger,
      directoryOverride: () async => directory,
    );
  });

  tearDown(() async {
    await logger.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  File registry({String suffix = ''}) => File(
    '${directory.path}/${PluginManagementService.registryFileName}$suffix',
  );

  Map<String, dynamic> envelope(Map<String, dynamic> plugins) => {
    'version': 1,
    'plugins': plugins,
  };

  Map<String, dynamic> manifest(String id) => {
    'id': id,
    'name': 'Legacy plugin',
    'version': '1.0.0',
    'enabled': false,
    'signed': false,
    'signatureValid': false,
  };

  test(
    'corrupt registry is surfaced instead of impersonating no plugins',
    () async {
      await registry().writeAsString('{broken', flush: true);

      await expectLater(
        service.listPlugins(),
        throwsA(isA<PluginRegistryException>()),
      );
      expect(await registry().readAsString(), '{broken');
    },
  );

  test(
    'one malformed row prevents a mutation from erasing other rows',
    () async {
      final original = jsonEncode(
        envelope({
          'good': manifest('good'),
          'broken': {'name': 'Missing ID'},
        }),
      );
      await registry().writeAsString(original, flush: true);

      await expectLater(
        service.setEnabled('good', true),
        throwsA(isA<PluginRegistryException>()),
      );
      expect(await registry().readAsString(), original);
    },
  );

  test(
    'install refuses a corrupt registry without leaving an archive',
    () async {
      await registry().writeAsString('[]', flush: true);
      final upload = utf8.encode(
        jsonEncode({'id': 'new', 'name': 'New', 'version': '1.0.0'}),
      );

      await expectLater(
        service.installFromBytes(upload, filename: 'new.nsplugin'),
        throwsA(isA<PluginRegistryException>()),
      );
      expect(directory.listSync().map((entry) => entry.path.split('/').last), [
        PluginManagementService.registryFileName,
      ]);
    },
  );

  test(
    'a valid backup is recovered after an interrupted atomic save',
    () async {
      await registry(suffix: '.bak').writeAsString(
        jsonEncode(envelope({'legacy': manifest('legacy')})),
        flush: true,
      );

      final plugins = await service.listPlugins();
      expect(plugins.map((plugin) => plugin.id), ['legacy']);
      expect(await registry().exists(), isTrue);
    },
  );

  test('concurrent installs retain both registry entries', () async {
    List<int> upload(String id) =>
        utf8.encode(jsonEncode({'id': id, 'name': id, 'version': '1.0.0'}));

    await Future.wait([
      service.installFromBytes(upload('one'), filename: 'one.nsplugin'),
      service.installFromBytes(upload('two'), filename: 'two.nsplugin'),
    ]);

    expect((await service.listPlugins()).map((plugin) => plugin.id).toSet(), {
      'one',
      'two',
    });
  });
}
