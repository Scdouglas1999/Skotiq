// The headless server must actually INJECT its CommandCorrelator into the
// handlers that register commands.
//
// `HeadlessApiServer` can build its correlator, expose it, sweep it on a timer,
// and have `_stampEventForBroadcast` ready to stamp outgoing events, and still
// correlate nothing if `_initializeHandlers()` constructs
// `DeviceHandlers(container, ...)` and `SequencerHandlers(container)` without
// passing it. `commandCorrelator` is an optional named parameter and every call
// site guards with `commandCorrelator?.beginCommand(...)`, so the omission
// fails silently and in the pass-making direction: action POSTs return no
// `commandId`, every emitted event carries `correlatingCommandId: null`,
// nothing throws, and the correlation feature advertised by /api/docs is
// dead.
//
// Crucially, the existing unit tests over `commandCompletionEventTypes`
// (command_correlator_test.dart) could NOT catch this: that table was always
// correct, it was simply never consulted with a registered command. So this test
// asserts the WIRING rather than the table — it observes the injected
// correlator's own `pendingCount`, which only moves if a handler really called
// `beginCommand`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/command_correlator.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import 'handler_test_helpers.dart';

void main() {
  // The server touches path_provider (a MethodChannel) while handling requests
  // and while stopping, so the test binding must exist or teardown throws
  // "Binding has not yet been initialized" after the assertions have passed.
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test installs a mock HttpClient that answers every request with 400
  // without any socket being opened, so requests would never reach the server
  // under test and `pendingCount` would stay 0 for the wrong reason. These tests
  // deliberately talk to a real loopback socket.
  setUpAll(() => HttpOverrides.global = null);

  late ProviderContainer container;
  late CommandCorrelator correlator;
  late HeadlessApiServer server;
  late HttpClient client;
  late Uri baseUri;

  setUp(() async {
    // The shared helper wires an in-memory database. Without it the real drift
    // database opens via path_provider, whose MethodChannel has no
    // implementation in a unit test, and the resulting MissingPluginException
    // surfaces as an unrelated async failure after the assertions have passed.
    container = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.0.0', buildNumber: 1),
        ),
      ],
    );
    correlator = CommandCorrelator();
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      commandCorrelator: correlator,
    );
    await server.start();
    client = HttpClient();
    baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    container.dispose();
  });

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final request = await client.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer admin-token');
    request.write(jsonEncode(payload));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (body.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  /// The sequence start will FAIL in this test (there is no backend or loaded
  /// sequence), and that is fine — `beginCommand` is called before any work, so
  /// a correctly-wired server registers the command regardless of the outcome.
  /// Asserting registration rather than success keeps the test about the wiring.
  test(
    'POST /api/sequencer/start registers a command with the correlator',
    () async {
      expect(correlator.pendingCount, 0, reason: 'nothing registered yet');

      await post('/api/sequencer/start');

      expect(
        correlator.pendingCount,
        1,
        reason:
            'SequencerHandlers was constructed without the correlator, so '
            'beginCommand was a no-op and no command was ever registered',
      );
    },
  );

  test(
    'a registered sequencer command is matched by its bare lifecycle event',
    () async {
      await post('/api/sequencer/start');
      expect(correlator.pendingCount, 1);

      // `Completed` is the BARE spelling the sequencer actually emits on the wire.
      final operation = operationForCompletionEvent('Completed');
      expect(
        operation,
        'sequencer.start',
        reason:
            'the completion table must recognise the spelling the sequencer '
            'really emits, not only the prefixed alias',
      );

      final stamped = correlator.stampEvent(operation: operation!);
      expect(
        stamped,
        isNotNull,
        reason:
            'the end-to-end path is register-then-stamp; a null here means '
            'the client would receive correlatingCommandId: null',
      );
      expect(
        correlator.pendingCount,
        0,
        reason: 'the match consumes the command',
      );
    },
  );

  test('POST /api/mount/slew registers a command on the device handlers', () async {
    // DeviceHandlers needs the same injection, so cover it too rather than
    // pinning one handler and assuming the other.
    //
    // `mount.slew` is the route used here (not `camera.expose`) because it calls
    // `beginCommand` immediately after payload validation. `camera.expose`
    // deliberately validates against the CAMERA'S CAPABILITIES first, so with no
    // camera connected it never reaches `beginCommand` — a correct ordering
    // (see the rejection test below), but useless for proving injection.
    await post('/api/mount/slew', const {
      'deviceId': 'sim_mount_1',
      'ra': 5.5,
      'dec': 30.0,
    });

    expect(
      correlator.pendingCount,
      1,
      reason:
          'DeviceHandlers was constructed without the correlator, so '
          'beginCommand was a no-op',
    );
  });

  /// The ordering above is worth pinning on its own: a rejected request must not
  /// register anything, or the next matching event would be stamped with the id
  /// of a command that never ran.
  test('a request rejected by validation registers no command', () async {
    await post('/api/mount/slew'); // no deviceId -> 400

    expect(
      correlator.pendingCount,
      0,
      reason:
          'a 400 must not leave a pending command for a later event to '
          'match; a mis-stamped id is worse than an unstamped one',
    );
  });
}
