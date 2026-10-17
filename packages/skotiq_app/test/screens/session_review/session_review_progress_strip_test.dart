// The live-progress strip under the Session Review header must not outlive the
// action that raised it.
//
// The reproduced defect: the A/B panel's "Run both" calls
// `reIntegratePreview`, the native preview integrate ends with a terminal 1.0
// event on the shared progress stream, and nothing ever cleared it — so a
// "Preview… 100%" strip stayed pinned under the header indefinitely (it
// survived a Narrative/Workbench round-trip and was still there 13 minutes
// later), claiming a job was still running. `integrate()` cleared it; every
// other seam-driven action did not.
//
// These drive the real screen against a real controller and a seam that emits
// the same terminal event the native side does, and assert on what is rendered.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/session_review_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/post_session_seam.dart' as seam;

import '../../harness/mock_database.dart';

/// A seam that reports progress exactly the way the native preview integrate
/// does: a terminal `(phase: 'preview', fraction: 1.0)` on the shared stream
/// immediately before the call returns.
class _PreviewSeam implements PostSessionSeam {
  final progress =
      StreamController<({String phase, double fraction})>.broadcast();

  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      progress.stream;

  @override
  Future<seam.IntegrateSessionResult> integrateSession(
      Map<String, dynamic> args) async {
    final lights = (args['lightPaths'] as List).cast<String>();
    final output = args['output'] as Map<String, dynamic>;
    progress.add((phase: 'preview', fraction: 1.0));
    // Let the controller's stream listener run before the call returns, so the
    // terminal event is on state by the time the action completes — the exact
    // ordering that orphaned the strip.
    await Future<void>.delayed(Duration.zero);
    return seam.IntegrateSessionResult(
      masterFitsPath: output['masterFitsPath'] as String,
      previewPath: null,
      rejectionMapPath: null,
      framesIntegrated: lights.length,
      framesRejected: 0,
      totalIntegrationSec: 60.0 * lights.length,
      rmsResidual: 0.2,
      width: 100,
      height: 80,
      channels: 1,
      perFrameStats: [
        for (final path in lights)
          seam.PerFrameRecord(
            path: path,
            weight: 1.0,
            rmsResidualPx: 0.2,
            accepted: true,
            reason: null,
          ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;
  late _PreviewSeam seamFake;
  late int sessionId;

  setUp(() async {
    db = mockDatabase();
    seamFake = _PreviewSeam();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(seamFake),
    ]);

    final sessions = container.read(sessionsDaoProvider);
    final images = container.read(imagesDaoProvider);

    sessionId = await sessions.createSession(
      ImagingSessionsCompanion.insert(startTime: DateTime.now()),
    );
    for (var i = 0; i < 3; i++) {
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/subs/s$i.fits',
          fileName: 's$i.fits',
          sessionId: Value(sessionId),
          exposureDuration: 60,
          frameType: const Value('light'),
          filter: const Value('L'),
          hfr: Value(2.0 + i * 0.1),
          isAccepted: const Value(true),
          capturedAt: DateTime.now().add(Duration(minutes: i)),
        ),
      );
    }
  });

  tearDown(() async {
    await seamFake.progress.close();
    container.dispose();
    await db.close();
  });

  SessionReviewController controller() => container.read(
        sessionReviewControllerProvider(SessionReviewScope.session(sessionId))
            .notifier,
      );

  SessionReviewState state() => container.read(
        sessionReviewControllerProvider(SessionReviewScope.session(sessionId)),
      );

  testWidgets(
      'the preview progress strip is torn down when reIntegratePreview returns',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SessionReviewScreen(
            scope: SessionReviewScope.session(1),
          ),
        ),
      ),
    );
    for (var i = 0; i < 40 && state().loading; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Control: a live event does render the strip, so the finder below is not
    // vacuously passing.
    seamFake.progress.add((phase: 'preview', fraction: 0.5));
    await tester.pump();
    await tester.pump();
    expect(find.text('Preview…'), findsOneWidget);

    // Now run the action that raises the terminal event. When it returns, the
    // strip it raised must be gone.
    //
    // runAsync because previewIntegrate does real filesystem work
    // (`Directory.systemTemp.createTemp`), which never completes inside the
    // widget tester's fake-async zone.
    await tester.runAsync(
      () => controller().reIntegratePreview(state().settings),
    );
    await tester.pump();

    expect(state().progress, isNull);
    expect(find.text('Preview…'), findsNothing);
  });
}
