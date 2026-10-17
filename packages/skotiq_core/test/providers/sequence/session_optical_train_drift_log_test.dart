// The executor's end-of-session optical-train drift line must not quote a
// number it did not measure.
//
// `OpticalTrainBaseline` keeps two penalty scores and nothing else, so
// rebuilding an `OpticalTrainDiagnostics` from one lands `tiltMeasured` /
// `collimationMeasured` on their fail-OPEN constructor defaults. The drift
// blend is `dTilt * 0.5 + dColl * 0.5`, so an axis nothing ever looked at
// contributes a placeholder 0 to half of a number the log then presents as a
// measurement of the night's mechanical stability.
//
// This drives the real session hooks against real seeded science rows — the
// same `OpticalTrainDiagnosticsService` the app uses decides what was
// measured — and asserts on what the executor actually logged.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _StubSessionStateNotifier extends SessionStateNotifier {
  _StubSessionStateNotifier(super.ref, int dbSessionId) {
    state = SessionState(
      isActive: true,
      dbSessionId: dbSessionId,
      startTime: DateTime.now(),
    );
  }
}

/// Captures every line instead of touching the filesystem / native bridge.
class _CapturingLogger extends LoggingService {
  final List<String> messages = [];

  @override
  void log(
    LogLevel level,
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) {
    messages.add(message);
  }
}

PsfFieldTileRow _tile({
  required int sessionId,
  required int row,
  required int col,
  required double hfr,
}) {
  return PsfFieldTileRow(
    id: row * 10 + col,
    sessionId: sessionId,
    tileRow: row,
    tileCol: col,
    starCount: 30,
    medianFwhm: hfr * 2.35,
    medianHfr: hfr,
    medianEccentricity: 0.1,
    roundness: 0.9,
    timestamp: DateTime.utc(2026, 5, 18, 22),
  );
}

AstrometryResidualVectorRow _residual({
  required int id,
  required int sessionId,
  required double x,
  required double y,
  required double magnitude,
}) {
  return AstrometryResidualVectorRow(
    id: id,
    sessionId: sessionId,
    x: x,
    y: y,
    dxArcsec: magnitude,
    dyArcsec: 0,
    magnitudeArcsec: magnitude,
    timestamp: DateTime.utc(2026, 5, 18, 22),
  );
}

/// The prefix the executor uses when it states a drift figure.
const _driftFigureLine = 'Optical-train drift vs. session-start baseline: ';

void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  late _CapturingLogger logger;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    logger = _CapturingLogger();
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  Future<ProviderContainer> buildContainer({
    required int dbSessionId,
    required List<PsfFieldTileRow> psfTiles,
    required List<AstrometryResidualVectorRow> residuals,
  }) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        sessionStateProvider.overrideWith(
          (ref) => _StubSessionStateNotifier(ref, dbSessionId),
        ),
        loggingServiceProvider.overrideWithValue(logger),
        sessionPsfTilesProvider(
          dbSessionId,
        ).overrideWith((_) => Stream.value(psfTiles)),
        sessionResidualVectorsProvider(
          dbSessionId,
        ).overrideWith((_) => Stream.value(residuals)),
      ],
    );
    addTearDown(container.dispose);
    // Materialize the streams so the executor's synchronous reads see them.
    await container.read(sessionPsfTilesProvider(dbSessionId).future);
    await container.read(sessionResidualVectorsProvider(dbSessionId).future);
    return container;
  }

  test('no drift figure is logged when an axis was never measured', () async {
    // A 2x2 PSF grid measures tilt. With no astrometric residuals the
    // edge-versus-centre ratio is a clamp floor, so collimation is not
    // measured and half the drift blend would be arithmetic on a
    // placeholder.
    final container = await buildContainer(
      dbSessionId: 31,
      psfTiles: [
        _tile(sessionId: 31, row: 0, col: 0, hfr: 2.1),
        _tile(sessionId: 31, row: 0, col: 1, hfr: 2.4),
        _tile(sessionId: 31, row: 1, col: 0, hfr: 2.2),
        _tile(sessionId: 31, row: 1, col: 1, hfr: 2.5),
      ],
      residuals: const [],
    );

    final executor = container.read(sequenceExecutorProvider);
    executor.captureSessionStartHooksForTest('seq-unmeasured');
    executor.captureSessionEndHooksForTest();

    expect(
      logger.messages.where((m) => m.startsWith(_driftFigureLine)),
      isEmpty,
      reason: 'collimation was never measured, so the blend is not a drift',
    );
    expect(
      logger.messages.where(
        (m) =>
            m.contains('field tilt was not measured') ||
            m.contains('collimation was not measured') ||
            m.contains('neither field tilt nor collimation was not measured'),
      ),
      isNotEmpty,
      reason: 'the log must name the axis it could not compare',
    );
  });

  test('a fully measured session still logs its drift figure', () async {
    // Guards the opposite failure: a gate that suppresses the figure
    // unconditionally would also pass the test above.
    final container = await buildContainer(
      dbSessionId: 32,
      psfTiles: [
        _tile(sessionId: 32, row: 0, col: 0, hfr: 2.1),
        _tile(sessionId: 32, row: 0, col: 1, hfr: 2.4),
        _tile(sessionId: 32, row: 1, col: 0, hfr: 2.2),
        _tile(sessionId: 32, row: 1, col: 1, hfr: 2.5),
      ],
      residuals: [
        _residual(id: 1, sessionId: 32, x: 0.05, y: 0.5, magnitude: 0.9),
        _residual(id: 2, sessionId: 32, x: 0.95, y: 0.5, magnitude: 0.8),
        _residual(id: 3, sessionId: 32, x: 0.5, y: 0.5, magnitude: 0.7),
        _residual(id: 4, sessionId: 32, x: 0.45, y: 0.55, magnitude: 0.72),
      ],
    );

    final executor = container.read(sequenceExecutorProvider);
    executor.captureSessionStartHooksForTest('seq-measured');
    executor.captureSessionEndHooksForTest();

    expect(
      logger.messages.where((m) => m.startsWith(_driftFigureLine)),
      isNotEmpty,
    );
  });
}
