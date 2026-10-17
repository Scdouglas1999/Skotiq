import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/diagnostic_dump_service.dart';
import 'package:skotiq_core/src/services/logging_service.dart';

LoggingService _testLogging({required Directory tempDir}) {
  // LoggingService talks to a native bridge in production. Tests inject
  // no-op native callbacks so the on-disk surface stays inside the
  // managed temp dir and we don't depend on the Rust runtime.
  return LoggingService(
    applicationSupportDirectoryProvider: () async => tempDir,
    nativeInitWithLogging: ({logDirectory}) {},
    nativeInit: () {},
    currentLogFileProvider: () => 'skotiq.log',
  );
}

void main() {
  test('createDump produces a zip with logs/, profile.json, sequence.json, '
      'system_info.json, devices.json, and manifest.json', () async {
    final tempDir = await Directory.systemTemp.createTemp('diag_dump_ok_');
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final logging = _testLogging(tempDir: tempDir);
    await logging.ensureInitialized();
    logging.info('boot ok', source: 'TestDriver');

    final sequence = Sequence.create(
      name: 'Andromeda',
      description: 'M31 stack',
      rootNodeId: null,
    );

    final service = DiagnosticDumpService(
      logging: logging,
      gatherProfile: () async => {
        'id': 7,
        'name': 'My Rig',
        'camera_id': 'native:zwo:0',
      },
      gatherSequence: () => sequence,
      gatherDevices: () => const [
        DumpDeviceEntry(
          role: 'camera',
          connectionState: 'connected',
          deviceId: 'native:zwo:0',
          deviceName: 'ASI2600MC',
        ),
        DumpDeviceEntry(role: 'mount', connectionState: 'disconnected'),
      ],
      gatherSystemInfo: () async => {
        'app_version': '2.5.0',
        'platform': {'operating_system': 'windows'},
      },
      tempDirProvider: () async => tempDir,
    );

    final outPath =
        '${tempDir.path}${Platform.pathSeparator}diagnostic_test.zip';
    final file = await service.createDump(outputPath: outPath);

    expect(
      await file.exists(),
      isTrue,
      reason: 'The dump file should be written to disk.',
    );

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toSet();

    // The dump layout is part of the bug-report contract; assert every
    // path is present so a future refactor can't silently drop one.
    expect(names, contains('manifest.json'));
    expect(names, contains('system_info.json'));
    expect(names, contains('profile.json'));
    expect(names, contains('sequence.json'));
    expect(names, contains('devices.json'));
    expect(
      names.any((n) => n.startsWith('logs/')),
      isTrue,
      reason: 'logs/ entry should be present',
    );

    Map<String, dynamic> readJson(String path) {
      final entry = archive.files.firstWhere((f) => f.name == path);
      final raw = utf8.decode(entry.content as List<int>);
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    final manifest = readJson('manifest.json');
    expect(manifest['bundle_version'], DiagnosticDumpService.bundleVersion);
    final entries = manifest['entries'] as List<dynamic>;
    expect(entries.length, greaterThanOrEqualTo(5));
    for (final e in entries) {
      expect(
        (e as Map<String, dynamic>)['status'],
        'ok',
        reason:
            'No gather step should have failed in the happy path. '
            'Entry: $e',
      );
    }

    final profile = readJson('profile.json');
    expect(profile['name'], 'My Rig');
    expect(profile['camera_id'], 'native:zwo:0');

    final seq = readJson('sequence.json');
    expect(seq['name'], 'Andromeda');
    expect(seq['description'], 'M31 stack');
    expect(seq['node_count'], 0);

    final devices = readJson('devices.json');
    final deviceList = devices['devices'] as List<dynamic>;
    expect(deviceList.length, 2);
    expect((deviceList.first as Map)['role'], 'camera');
    expect((deviceList.first as Map)['connection_state'], 'connected');
  });

  test('createDump still emits files when individual gather steps fail; '
      'manifest records the failure', () async {
    final tempDir = await Directory.systemTemp.createTemp('diag_dump_fail_');
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final logging = _testLogging(tempDir: tempDir);
    await logging.ensureInitialized();

    final service = DiagnosticDumpService(
      logging: logging,
      // Why throw here: a profile-fetch failure (e.g. DB locked) must NOT
      // collapse the whole dump. The test pins that contract.
      gatherProfile: () async => throw StateError('db locked'),
      // null sequence is the normal "no sequence loaded" path, also covered.
      gatherSequence: () => null,
      gatherDevices: () => throw StateError('equipment provider unbuilt'),
      gatherSystemInfo: () async => {'app_version': '0.0.0-test'},
      tempDirProvider: () async => tempDir,
    );

    final outPath =
        '${tempDir.path}${Platform.pathSeparator}diagnostic_fail.zip';
    final file = await service.createDump(outputPath: outPath);
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());

    final names = archive.files.map((f) => f.name).toSet();
    expect(names, contains('manifest.json'));
    expect(names, contains('profile.json'));
    expect(names, contains('sequence.json'));
    expect(names, contains('devices.json'));

    final manifestRaw =
        archive.files.firstWhere((f) => f.name == 'manifest.json').content
            as List<int>;
    final manifest =
        jsonDecode(utf8.decode(manifestRaw)) as Map<String, dynamic>;
    final entries = (manifest['entries'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final byName = {for (final e in entries) e['name']: e};

    expect(byName['profile']!['status'], 'failed');
    expect(byName['profile']!['error'], contains('db locked'));
    expect(byName['devices']!['status'], 'failed');
    expect(byName['devices']!['error'], contains('equipment provider unbuilt'));

    // Sequence didn't throw; null is a "no sequence loaded" signal, so it
    // succeeds with a `current_sequence: null` body. The dump consumer
    // can tell "missing data" from "load failure" by the manifest status.
    expect(byName['sequence']!['status'], 'ok');
    final seqRaw =
        archive.files.firstWhere((f) => f.name == 'sequence.json').content
            as List<int>;
    final seq = jsonDecode(utf8.decode(seqRaw)) as Map<String, dynamic>;
    expect(seq['current_sequence'], isNull);
  });
}
