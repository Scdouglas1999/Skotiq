// What the Analytics session dialog says about a night whose frames were all
// culled.
//
// A night whose six subs were every one of them rejected for low star count
// once read "Successful 6 · Failed 0" above its own six cards each stamped
// REJECTED. The accepted and rejected split is counted from the frames, which
// also covers rows written before the session row kept that split (the
// fixture below is such a row: successful 6 of 6).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _PinnedBackend extends BackendNotifier {
  _PinnedBackend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'NoopTutorialProgressDao.${invocation.memberName} called in test',
      );
}

DbCapturedImage _light({required int id, required bool accepted}) =>
    DbCapturedImage(
      id: id,
      filePath: '/frames/light_$id.fits',
      fileName: 'light_$id.fits',
      fileFormat: 'fits',
      sessionId: 5,
      frameType: 'light',
      exposureDuration: 2.0,
      binX: 1,
      binY: 1,
      isPlateSolved: false,
      capturedAt: DateTime(2026, 7, 30, 22, id),
      createdAt: DateTime(2026, 7, 30, 22, id),
      isAccepted: accepted,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pump the History tab for a night the camera returned six frames of, with
  /// [images] as the frames the culling then judged.
  Future<void> pumpHistory(
    WidgetTester tester,
    List<DbCapturedImage> images,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final session = ImagingSession(
      id: 5,
      name: 'Night A - M31',
      startTime: DateTime(2026, 7, 30),
      totalExposures: 6,
      successfulExposures: 6,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: 'completed',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _PinnedBackend(ref, DisconnectedBackend()),
          ),
          allSessionsProvider.overrideWith(
            (ref) => Stream<List<ImagingSession>>.value([session]),
          ),
          standaloneImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
          allDbImagesProvider.overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(images),
          ),
          dbSessionImagesProvider(5).overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(images),
          ),
          tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: AnalyticsScreen(initialTab: AnalyticsTab.history),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// The same night, with its History dialog open.
  Future<void> openDialog(
    WidgetTester tester,
    List<DbCapturedImage> images,
  ) async {
    await pumpHistory(tester, images);
    await tester.tap(find.text('Night A - M31'));
    // pump, not pumpAndSettle: the thumbnail futures never go idle locally.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'the History row for an all-rejected night does not read like a good one',
    (tester) async {
      await pumpHistory(tester, [
        for (var id = 1; id <= 6; id++) _light(id: id, accepted: false),
      ]);

      // The row read `COMPLETED · 6 frames · 0 integration` — the good night's
      // row with an odd integration figure, rather than a night that kept
      // nothing.
      // Both figures are Readouts now, so the label and the value are one
      // widget and the test no longer has to guess which Column pairs them.
      expect(_readout(tester, 'Frames').value, '6');
      expect(_readout(tester, 'Rejected').value, '6');
    },
  );

  testWidgets(
    'a History row that kept everything carries no rejected chip',
    (tester) async {
      await pumpHistory(tester, [
        for (var id = 1; id <= 6; id++) _light(id: id, accepted: true),
      ]);

      expect(_readout(tester, 'Frames').value, '6');
      expect(_readouts(tester, 'Rejected'), isEmpty);
    },
  );

  testWidgets(
    'a night whose every frame was rejected never calls the camera tally a '
    'success',
    (tester) async {
      await openDialog(tester, [
        for (var id = 1; id <= 6; id++) _light(id: id, accepted: false),
      ]);

      expect(_readouts(tester, 'Successful', within: _dialog), isEmpty);

      // Accepted 0, Rejected 6 of 6 captures.
      expect(_readout(tester, 'Total exposures', within: _dialog).value, '6');
      expect(_readout(tester, 'Accepted', within: _dialog).value, '0');
      expect(_readout(tester, 'Rejected', within: _dialog).value, '6');
    },
  );

  testWidgets('a night the culling kept states both halves', (tester) async {
    await openDialog(tester, [
      for (var id = 1; id <= 5; id++) _light(id: id, accepted: true),
      _light(id: 6, accepted: false),
    ]);

    expect(_readout(tester, 'Total exposures', within: _dialog).value, '6');
    expect(_readout(tester, 'Accepted', within: _dialog).value, '5');
    expect(_readout(tester, 'Rejected', within: _dialog).value, '1');
  });
}

/// Every [Readout] whose label is [label], case-insensitively: a readout
/// renders its label uppercase but keeps the written form.
///
/// [within] scopes the search, which the dialog assertions need: the History
/// row behind the open dialog carries a 'Rejected' readout of its own.
List<Readout> _readouts(WidgetTester tester, String label, {Finder? within}) {
  final wanted = label.toLowerCase();
  final finder = within == null
      ? find.byType(Readout)
      : find.descendant(of: within, matching: find.byType(Readout));
  return tester
      .widgetList<Readout>(finder)
      .where((r) => r.label?.toLowerCase() == wanted)
      .toList(growable: false);
}

/// The single [Readout] carrying [label], optionally scoped to [within].
Readout _readout(WidgetTester tester, String label, {Finder? within}) {
  final matches = _readouts(tester, label, within: within);
  expect(matches, hasLength(1), reason: 'expected one "$label" readout');
  return matches.single;
}

/// The open session-detail dialog, so a dialog assertion cannot read the
/// History row painted behind it.
Finder get _dialog => find.byType(Dialog);
