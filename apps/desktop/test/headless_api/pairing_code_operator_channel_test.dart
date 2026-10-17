// Regression coverage: a headless operator must be able to READ the pairing
// code, and a remote client must NOT be able to.
//
// Observed live (2026-07-25): `POST /api/pairing/start` returned 200, but the
// generated code appeared in NO host log — not
// `~/.local/share/com.skotiq.desktop/logs/skotiq.log.<date>`
// (line count unchanged across the request) and not stdout. On a headless
// appliance with no GUI that made code pairing unusable.
//
// Why logging is not the channel: `LoggingService` does not write the on-disk
// log at all — that file carries only the native Rust tracing output. Its
// entries go to an in-memory ring buffer that is SERVED OVER HTTP by
// `/api/logs/recent` and `/api/logs/tail`. Logging the code therefore keeps it
// off the operator's disk while making it harvestable by any already
// authenticated client — the exact inverse of the documented intent.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_attempt_tracker.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api/handlers/pairing_handlers.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shelf/shelf.dart';

void main() {
  group('pairing code operator channel', () {
    late Directory tempDir;
    late LoggingService logger;
    late PairingService pairingService;
    late PairingHandlers handlers;
    // Records the client keys whose bearer-token failure bucket was cleared.
    final clearedAuthFailures = <String>[];

    setUp(() async {
      clearedAuthFailures.clear();
      tempDir = await Directory.systemTemp.createTemp('sk_pair_code_test_');
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
        clearAuthFailures: clearedAuthFailures.add,
        pairingAttempts: PairingAttemptTracker(),
        ensurePairingService: () => pairingService,
        recordPairedSession: (_, __) {},
        rateLimitClientKey: (_) => 'test-client',
        pairingPrintCodes: false,
        pairingMode: () => PairingMode.codeRequired,
        logger: logger,
      );
    });

    tearDown(() async {
      await pairingService.close();
      await logger.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<Response> start() => handlers.handlePairingStart(
      Request('POST', Uri.parse('http://localhost/api/pairing/start')),
    );

    /// Everything a remotely-authenticated client could read back out of
    /// `/api/logs/recent` or `/api/logs/tail`.
    String remotelyReadableLogText() =>
        logger.getRecentLogs().map((e) => e.toString()).join('\n');

    test('start writes the code where the operator can read it', () async {
      final response = await start();
      expect(response.statusCode, HttpStatus.ok);

      final path = handlers.pairingCodeFilePath;
      expect(path, isNotNull);
      // It lands in the app-support root, NOT in the logs directory (which
      // is enumerable/downloadable through /api/logs/files/...).
      expect(path, equals('${tempDir.path}/$kPairingCodeFileName'));

      final file = File(path!);
      expect(await file.exists(), isTrue);
      final contents = await file.readAsString();
      expect(contents, contains('code='));
      expect(contents, contains('expires='));

      // The code in the file is the real, verifiable one.
      final code = RegExp(r'code=(.+)').firstMatch(contents)!.group(1)!.trim();
      expect(code, isNotEmpty);
      final verify = await pairingService.verifyPairing(
        code: code,
        deviceId: 'device-1',
        deviceName: 'Operator Phone',
        deviceType: 'mobile',
        authGrantSpec: 'control',
      );
      expect(verify.outcome, PairingVerifyOutcome.success);
    });

    test('the code file is owner-only', () async {
      if (Platform.isWindows) return;
      await start();
      final stat = await File(handlers.pairingCodeFilePath!).stat();
      // 0600 — anyone who can read this file can pair with the rig.
      expect(stat.modeString(), 'rw-------');
    });

    test(
      'the code NEVER reaches the remotely-readable log or the response body',
      () async {
        final response = await start();
        final body = await response.readAsString();

        final contents = await File(
          handlers.pairingCodeFilePath!,
        ).readAsString();
        final code = RegExp(
          r'code=(.+)',
        ).firstMatch(contents)!.group(1)!.trim();

        // The HTTP response envelope carries only expiry.
        expect(jsonDecode(body) as Map, isNot(contains('code')));
        expect(body, isNot(contains(code)));

        // …and nothing an authenticated client can pull from /api/logs/*
        // contains it either, or the code would be harvestable over HTTP by
        // anyone already holding a token.
        expect(remotelyReadableLogText(), isNot(contains(code)));

        // The log still records that pairing happened, and points the
        // operator at the file.
        expect(remotelyReadableLogText(), contains('Pairing started'));
        expect(remotelyReadableLogText(), contains(kPairingCodeFileName));
      },
    );

    test('a spent code is removed from disk on successful verify', () async {
      await start();
      final path = handlers.pairingCodeFilePath!;
      final contents = await File(path).readAsString();
      final code = RegExp(r'code=(.+)').firstMatch(contents)!.group(1)!.trim();

      final verify = await handlers.handlePairingVerify(
        Request(
          'POST',
          Uri.parse('http://localhost/api/pairing/verify'),
          body: jsonEncode({
            'code': code,
            'deviceId': 'device-1',
            'deviceName': 'Operator Phone',
            'deviceType': 'mobile',
          }),
        ),
      );

      expect(verify.statusCode, HttpStatus.ok);
      expect(await File(path).exists(), isFalse);
    });

    /// A successful pairing must lift the BEARER-TOKEN failure lockout, not
    /// just the pairing lockout.
    ///
    /// The auth middleware checks that bucket BEFORE resolving the token — it
    /// has to, since the resolve is an O(N*L) constant-time scan and letting
    /// unauthenticated callers drive it is a CPU-burn vector — so its own
    /// "clear on success" line is unreachable while the client is limited.
    /// Without clearing here, an operator whose tablet tripped the limiter on
    /// a stale token (exactly what an appliance restart produces) stayed
    /// locked out while holding a brand-new, valid token. Observed live: a
    /// token issued seconds earlier still answers 429 "Too many
    /// authentication failures".
    test(
      'a successful pairing lifts the bearer-token failure lockout',
      () async {
        await start();
        final contents = await File(
          handlers.pairingCodeFilePath!,
        ).readAsString();
        final code = RegExp(
          r'code=(.+)',
        ).firstMatch(contents)!.group(1)!.trim();

        expect(clearedAuthFailures, isEmpty, reason: 'nothing cleared yet');

        final verify = await handlers.handlePairingVerify(
          Request(
            'POST',
            Uri.parse('http://localhost/api/pairing/verify'),
            body: jsonEncode({
              'code': code,
              'deviceId': 'device-1',
              'deviceName': 'Operator Phone',
              'deviceType': 'mobile',
            }),
          ),
        );

        expect(verify.statusCode, HttpStatus.ok);
        expect(
          clearedAuthFailures,
          contains('test-client'),
          reason: 'the freshly-paired client must not stay rate-limited',
        );
      },
    );

    /// The converse: a FAILED pairing must never clear the lockout, or the
    /// limiter could be reset by exactly the traffic it exists to throttle.
    test('a failed pairing does not lift the lockout', () async {
      await start();

      final verify = await handlers.handlePairingVerify(
        Request(
          'POST',
          Uri.parse('http://localhost/api/pairing/verify'),
          body: jsonEncode({
            'code': '000000',
            'deviceId': 'device-1',
            'deviceName': 'Attacker',
            'deviceType': 'mobile',
          }),
        ),
      );

      expect(verify.statusCode, isNot(HttpStatus.ok));
      expect(clearedAuthFailures, isEmpty);
    });

    test('an injected directory overrides the log-derived default', () async {
      final custom = await Directory.systemTemp.createTemp('sk_pair_custom_');
      addTearDown(() async {
        if (await custom.exists()) await custom.delete(recursive: true);
      });

      final scoped = PairingHandlers(
        clearAuthFailures: clearedAuthFailures.add,
        pairingAttempts: PairingAttemptTracker(),
        ensurePairingService: () => pairingService,
        recordPairedSession: (_, __) {},
        rateLimitClientKey: (_) => 'test-client-2',
        pairingPrintCodes: false,
        pairingMode: () => PairingMode.codeRequired,
        logger: logger,
        operatorCodeDirectory: custom.path,
      );

      await scoped.handlePairingStart(
        Request('POST', Uri.parse('http://localhost/api/pairing/start')),
      );

      expect(
        await File('${custom.path}/$kPairingCodeFileName').exists(),
        isTrue,
      );
    });

    // The client asking for a code has to be able to name a next step that
    // works on THIS rig. Measured against a headless bundle: the run-watch
    // pairing wall sent the operator to the desktop app's Remote Access screen
    // — a screen an appliance does not have — while the code sat in the
    // owner-only file below, named nowhere. So the answer says WHERE the code
    // went. It still never says WHAT the code is, and never says which absolute
    // path it lives at: this endpoint is unauthenticated.
    test('start reports the channels the code was delivered on', () async {
      final body = jsonDecode(await (await start()).readAsString()) as Map;
      final delivery = body['codeDelivery'] as Map;

      expect(delivery['operatorFile'], isTrue);
      expect(delivery['operatorFileName'], kPairingCodeFileName);
      expect(delivery['console'], isFalse, reason: 'printing was not opted in');

      // No secret, and no host layout, for an unauthenticated caller.
      final code = RegExp(r'code=(.+)')
          .firstMatch(await File(handlers.pairingCodeFilePath!).readAsString())!
          .group(1)!
          .trim();
      final raw = jsonEncode(body);
      expect(raw, isNot(contains(code)));
      expect(raw, isNot(contains(tempDir.path)));
    });

    test('a host started with --pairing-print-codes says so', () async {
      final printing = PairingHandlers(
        clearAuthFailures: clearedAuthFailures.add,
        pairingAttempts: PairingAttemptTracker(),
        ensurePairingService: () => pairingService,
        recordPairedSession: (_, __) {},
        rateLimitClientKey: (_) => 'test-client-printing',
        pairingPrintCodes: true,
        pairingMode: () => PairingMode.codeRequired,
        logger: logger,
      );

      final response = await printing.handlePairingStart(
        Request('POST', Uri.parse('http://localhost/api/pairing/start')),
      );
      final delivery =
          (jsonDecode(await response.readAsString()) as Map)['codeDelivery']
              as Map;
      expect(delivery['console'], isTrue);
    });

    /// A rig that could not write the file must not be reported as one that
    /// did. The client turns `operatorFile: true` into "read it from
    /// pairing-code.txt", and naming a file nothing wrote is the same defect
    /// this block exists to close, moved one step along.
    test('a rig that could not write the file does not claim it did', () async {
      final blocker = File(
        '${tempDir.path}${Platform.pathSeparator}not-a-directory',
      );
      await blocker.writeAsString('a file where a directory would have to be');

      final blocked = PairingHandlers(
        clearAuthFailures: clearedAuthFailures.add,
        pairingAttempts: PairingAttemptTracker(),
        ensurePairingService: () => pairingService,
        recordPairedSession: (_, __) {},
        rateLimitClientKey: (_) => 'test-client-blocked',
        pairingPrintCodes: false,
        pairingMode: () => PairingMode.codeRequired,
        logger: logger,
        operatorCodeDirectory: '${blocker.path}${Platform.pathSeparator}nested',
      );

      final response = await blocked.handlePairingStart(
        Request('POST', Uri.parse('http://localhost/api/pairing/start')),
      );
      expect(response.statusCode, HttpStatus.ok);
      final delivery =
          (jsonDecode(await response.readAsString()) as Map)['codeDelivery']
              as Map;
      expect(delivery['operatorFile'], isFalse);
      expect(delivery['console'], isFalse);
    });
  });
}
