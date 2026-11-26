// One-tap LAN pairing mints the scope the client asks for. A phone at a
// headless rig is the only screen that can choose the capture folder, the
// solver or the backups, and a control-only token left it unable to: the
// first-run setup told the operator to "set it on the imaging computer".
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_attempt_tracker.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api/handlers/pairing_handlers.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

class _LanPeer implements HttpConnectionInfo {
  @override
  InternetAddress get remoteAddress => InternetAddress('192.168.1.50');
  @override
  int get remotePort => 50000;
  @override
  int get localPort => 8080;
}

void main() {
  late Directory tempDir;
  late LoggingService logger;
  late PairingService pairingService;
  late PairingHandlers handlers;
  final recorded = <String>[];

  setUp(() async {
    recorded.clear();
    tempDir = await Directory.systemTemp.createTemp('sk_lan_claim_scope_');
    logger = LoggingService(
      applicationSupportDirectoryProvider: () async => tempDir,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () =>
          '${tempDir.path}${Platform.pathSeparator}logs'
          '${Platform.pathSeparator}skotiq.log',
    );
    await logger.ensureInitialized();
    pairingService = PairingService(
      database: PairingDatabase.forTesting(NativeDatabase.memory()),
    );
    handlers = PairingHandlers(
      clearAuthFailures: (_) {},
      pairingAttempts: PairingAttemptTracker(),
      ensurePairingService: () => pairingService,
      recordPairedSession: (_, grant) => recorded.add(grant.toSpec()),
      rateLimitClientKey: (_) => 'lan-client',
      pairingPrintCodes: false,
      pairingMode: () => PairingMode.lanOpen,
      logger: logger,
      operatorCodeDirectory: tempDir.path,
    );
  });

  tearDown(() async {
    await pairingService.close();
    await logger.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<Response> claim(Map<String, Object?> body) => handlers.handleLanClaim(
    Request(
      'POST',
      Uri.parse('http://192.168.1.20:8080/api/pairing/lan-claim'),
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
      context: {'shelf.io.connection_info': _LanPeer()},
    ),
  );

  test('a claim that names no scope pairs with control', () async {
    final response = await claim({'deviceId': 'phone-1'});
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['tokenScope'], 'control');
    expect(recorded, ['control']);
  });

  test('a phone that asks for full control gets it', () async {
    final response = await claim({
      'deviceId': 'phone-2',
      'requestedScope': 'admin',
    });
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['tokenScope'], 'admin');
    expect(recorded, ['admin']);
  });

  test('a scope the host does not know is refused, not widened', () async {
    final response = await claim({
      'deviceId': 'phone-3',
      'requestedScope': 'everything',
    });
    expect(response.statusCode, HttpStatus.badRequest);
    expect(recorded, isEmpty);
  });
}
