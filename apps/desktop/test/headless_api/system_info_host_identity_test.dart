// /api/info says which kind of process serves it and the computer's name. It
// used to answer "Skotiq Headless" / mode headless / apiOnlyMode from the GUI
// too, so a client could not tell two imaging computers apart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/handlers/static_file_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/system_handlers.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shelf/shelf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<String, dynamic>> infoFor(SkotiqHostMode mode) async {
    final tempDir = await Directory.systemTemp.createTemp('sk_info_test_');
    final logger = LoggingService(
      applicationSupportDirectoryProvider: () async => tempDir,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await logger.ensureInitialized();
    final container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '8.2.2', buildNumber: 1),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await logger.dispose();
      await tempDir.delete(recursive: true);
    });
    final handlers = SystemHandlers(
      container: container,
      logger: logger,
      staticFileHandlers: StaticFileHandlers(logger: logger, release: '8.2.1'),
      view: SystemServerView(
        fingerprint: () => 'fp',
        instanceId: () => 'id',
        currentEventSeq: () => 0,
        eventReplayBufferSize: () => 0,
        eventReplayBufferOldestSeq: () => null,
        port: () => 8099,
        bindLocalOnly: () => false,
        authRequired: () => true,
        availableAuthScopes: () => const ['admin'],
        pairingModeWire: () => 'lan-open',
        tailscaleHost: () => null,
        relayApplianceId: () => null,
        hostMode: mode,
        hostName: 'DESKTOP-MMAJGAK',
      ),
    );
    final response = await handlers.handleInfo(
      Request('GET', Uri.parse('http://localhost/api/info')),
    );
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  test('a GUI host says so and names the computer', () async {
    final info = await infoFor(SkotiqHostMode.gui);
    expect(info['name'], 'DESKTOP-MMAJGAK');
    expect(info['hostName'], 'DESKTOP-MMAJGAK');
    expect(info['hostMode'], 'gui');
    expect(info['mode'], 'gui');
    expect(info['apiOnlyMode'], isFalse);
    expect(info['lanPairing'], isTrue);
  });

  test('the daemon still reports headless and API-only', () async {
    final info = await infoFor(SkotiqHostMode.headless);
    expect(info['hostMode'], 'headless');
    expect(info['mode'], 'headless');
    expect(info['apiOnlyMode'], isTrue);
  });

  test('the computer name drops a domain suffix', () {
    expect(hostComputerName('Mac-mini.local'), 'Mac-mini');
    expect(hostComputerName(' '), 'Skotiq');
  });
}
