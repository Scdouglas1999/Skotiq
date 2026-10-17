import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/static_file_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/system_handlers.dart';
import 'package:shelf/shelf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pair page establishes a cookie session and offers code fallback',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ns_pair_page_test_',
      );
      final logger = LoggingService(
        applicationSupportDirectoryProvider: () async => tempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      await logger.ensureInitialized();
      final container = ProviderContainer();
      addTearDown(() async {
        container.dispose();
        await logger.dispose();
        await tempDir.delete(recursive: true);
      });

      final handlers = SystemHandlers(
        container: container,
        logger: logger,
        staticFileHandlers: StaticFileHandlers(logger: logger),
        view: SystemServerView(
          fingerprint: () => 'test',
          instanceId: () => 'test',
          currentEventSeq: () => 0,
          eventReplayBufferSize: () => 0,
          eventReplayBufferOldestSeq: () => null,
          port: () => 8080,
          bindLocalOnly: () => false,
          authRequired: () => true,
          availableAuthScopes: () => const ['control'],
          pairingModeWire: () => 'lan-open',
          tailscaleHost: () => null,
          relayApplianceId: () => null,
        ),
      );

      final response = await handlers.handlePairPage(
        Request('GET', Uri.parse('http://localhost/pair')),
      );
      final html = await response.readAsString();

      expect(response.statusCode, HttpStatus.ok);
      expect(html, contains("fetch('/api/auth/cookie'"));
      expect(html, contains("res.body.error === 'not_local_network'"));
      expect(html, contains('Open dashboard'));
      expect(html, contains('placeholder="STAR-LYRA-1234"'));
      expect(html, contains('maxlength="32"'));
      expect(html, contains('bearer credential is intentionally hidden'));
      expect(html, isNot(contains("escapeHtml(token) + '</code>'")));
    },
  );
}
