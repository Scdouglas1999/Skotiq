import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/widgets/photometric_calibration_wizard.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _DelayedNetworkBackend extends Mock implements NetworkBackend {
  final matchResult = Completer<List<CatalogStarMatch>>();
  int matchCalls = 0;

  @override
  Future<List<CatalogStarMatch>> matchPhotometricCalibrationStars(
    int imageId,
  ) {
    matchCalls++;
    return matchResult.future;
  }

  @override
  void dispose() {}
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

ImagingSession _session() => ImagingSession(
      id: 1,
      name: 'Host A standards',
      startTime: DateTime.utc(2026, 7, 15),
      totalExposures: 1,
      successfulExposures: 1,
      failedExposures: 0,
      totalIntegrationSecs: 60,
      autofocusCount: 0,
      status: 'completed',
    );

DbCapturedImage _frame() => DbCapturedImage(
      id: 11,
      filePath: '/host-a/standard-v.fits',
      fileName: 'standard-v.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 60,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 15),
      createdAt: DateTime.utc(2026, 7, 15),
      isAccepted: true,
      isPlateSolved: true,
      solvedRa: 5.5,
      solvedDec: -5.4,
      filter: 'V',
      starCount: 40,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'matching is single-flight and an old host cannot complete the wizard',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final hostA = _DelayedNetworkBackend();
      final hostB = _DelayedNetworkBackend();
      late _SwappableBackendNotifier backendNotifier;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backendProvider.overrideWith((ref) {
              backendNotifier = _SwappableBackendNotifier(ref, hostA);
              return backendNotifier;
            }),
            allSessionsProvider.overrideWith(
              (ref) => Stream.value([_session()]),
            ),
            calibrationSessionImagesProvider.overrideWith(
              (ref, sessionId) async => [_frame()],
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: PhotometricCalibrationWizard()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('standard-v.fits'));
      await tester.pump();
      final nextButton = find.widgetWithText(SkotiqButton, 'Next');
      await tester.ensureVisible(nextButton);
      await tester.pump();
      await tester.tap(nextButton);
      await tester.pump();

      // Two taps before a rebuild must still admit only one host command.
      final matchButton = find.widgetWithText(SkotiqButton, 'Match Stars');
      await tester.ensureVisible(matchButton);
      await tester.pump();
      await tester.tap(matchButton);
      await tester.tap(matchButton);
      await tester.pump();
      expect(hostA.matchCalls, 1);

      backendNotifier.swap(hostB);
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Select plate-solved frames'), findsOneWidget);
      expect(find.textContaining('Star matching failed'), findsNothing);

      hostA.matchResult.complete(const []);
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Star matching failed'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
