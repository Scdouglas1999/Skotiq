// The API resolves an alert's own state, not just the overrides map.
//
// `transientAlertStatesProvider` holds ONLY the queue/dismiss actions taken
// through the alert surfaces; an alert can also carry its state on itself (a
// First Light detection's reviewed/dismissed row reaches the UI that way, via
// `transientAlertFromDetection`). Every in-app surface now resolves through
// `resolveTransientAlertState`; /api/transients read the map bare, so any alert
// whose state lives on the alert would have been served as active and reported
// `isDismissed: false` — the phone contradicting the desktop about one row.
// These tests hold the endpoint to the shared resolver.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/transient_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Serves a fixed alert list instead of reaching for the upstream sources.
class _FixedAlertService extends TransientAlertService {
  _FixedAlertService(this.alerts)
    : super(
        httpClient: http.Client(),
        logger: LoggingService(
          nativeInit: () {},
          nativeInitWithLogging: ({String? logDirectory}) {},
          currentLogFileProvider: () => null,
        ),
      );

  final List<TransientAlert> alerts;

  @override
  Future<List<TransientAlert>> getAllAlerts(
    TransientAlertSettings settings, {
    int? tnsBotId,
    String? tnsBotName,
    bool tnsUseSandbox = false,
  }) async => alerts;
}

/// A First Light detection mapped through the production mapper, so the alert
/// carries whatever state the row does.
TransientAlert _detectionAlert({
  required bool reviewed,
  required bool dismissed,
}) => transientAlertFromDetection(
  TransientDetectionRow(
    id: 7,
    sessionId: null,
    capturedImageId: null,
    tileId: 261982,
    detectedAt: DateTime.utc(2026, 8, 1, 3, 30),
    raDeg: 202.47,
    decDeg: 47.19,
    residualFlux: 1200.0,
    deltaMag: null,
    snr: 14.2,
    fwhm: 2.8,
    eccentricity: 0.12,
    positionAngleDeg: 0.0,
    kind: 'newSource',
    catalogMatch: null,
    confidence: 0.91,
    reviewed: reviewed,
    dismissed: dismissed,
  ),
);

Future<Map<String, dynamic>> _getActive(TransientHandlers handlers) async {
  final response = await translateHandlerErrors(
    handlers.handleGetActiveTransients(
      Request('GET', Uri.parse('http://localhost/api/transients')),
    ),
  );
  expect(response.statusCode, HttpStatus.ok);
  return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a detection dismissed in the app is not served as an active alert',
    () async {
      final alert = _detectionAlert(reviewed: true, dismissed: true);
      expect(alert.state, TransientAlertState.dismissed);

      final container = createHeadlessTestContainer(
        overrides: [
          transientAlertServiceProvider.overrideWithValue(
            _FixedAlertService([alert]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final body = await _getActive(TransientHandlers(container));

      expect(
        body['alerts'],
        isEmpty,
        reason: 'the row says dismissed; the API must not re-offer it',
      );
      expect(body['dismissedCount'], 1);
    },
  );

  test(
    'an undismissed detection is still served, and says it is not dismissed',
    () async {
      final alert = _detectionAlert(reviewed: false, dismissed: false);

      final container = createHeadlessTestContainer(
        overrides: [
          transientAlertServiceProvider.overrideWithValue(
            _FixedAlertService([alert]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final body = await _getActive(TransientHandlers(container));

      final served = (body['alerts'] as List).single as Map<String, dynamic>;
      expect(served['id'], alert.id);
      expect(served['isDismissed'], isFalse);
      expect(body['dismissedCount'], 0);
    },
  );
}
