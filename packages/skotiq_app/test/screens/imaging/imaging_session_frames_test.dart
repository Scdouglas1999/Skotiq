import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_session_frames.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/widgets/saved_frame/saved_frame_viewer.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

DbCapturedImage _light(
  int id, {
  int? targetId = 1,
  String? filter = 'L',
  double hfr = 2.4,
  bool accepted = true,
}) =>
    DbCapturedImage(
      id: id,
      filePath: '/captures/f$id.fits',
      fileName: 'f$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 5,
      binX: 1,
      binY: 1,
      targetId: targetId,
      filter: filter,
      hfr: hfr,
      starCount: 45,
      capturedAt: DateTime(2026, 11, 11, 21, 0, id),
      createdAt: DateTime(2026, 11, 11, 21, 0, id),
      isAccepted: accepted,
      isPlateSolved: false,
    );

DbTarget _target(int id, String name) => DbTarget(
      id: id,
      name: name,
      ra: 2.7,
      dec: 42.8,
      minAltitude: 30,
      priority: 0,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0,
      goalIntegrationSecs: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      isFavorite: false,
    );

class _NoThumbnails extends Fake implements ImagingBackend {
  @override
  Future<Uint8List> getImageThumbnail(int imageId) async => Uint8List(0);
}

void main() {
  test('frames group by target and filter, newest group and frame first', () {
    final groups = sessionFrameGroups([
      _light(1, filter: 'Ha'),
      _light(2),
      _light(3, accepted: false),
      _light(4, targetId: 2),
    ]);
    expect(
      [for (final g in groups) (g.targetId, g.filter)],
      [(2, 'L'), (1, 'L'), (1, 'Ha')],
    );
    final m34 = groups[1];
    expect([for (final f in m34.frames) f.number], [3, 2]);
    expect(m34.keptCount, 1);
    expect(m34.keptSeconds, 5);
  });

  testWidgets('tonight\'s frames show as tiles under their target and filter',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          isRemoteModeProvider.overrideWithValue(false),
          imagingBackendProvider.overrideWithValue(_NoThumbnails()),
          nightSessionLightRowsProvider.overrideWithValue([
            _light(1, hfr: 2.47),
            _light(2, hfr: 2.42),
            _light(3, hfr: 3.9, accepted: false),
          ]),
          allDbTargetsProvider.overrideWith(
            (ref) => Stream.value([_target(1, 'M34')]),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ImagingSessionFrames()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('M34 · L'), findsOneWidget);
    expect(find.text('3 frames · 2 kept · 10s'), findsOneWidget);
    expect(find.text('#3'), findsOneWidget);
    expect(find.text('HFR 3.90 · 45 ★'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Frame 3, Rejected, HFR 3\.90')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tapping a tile shows that frame at full resolution, decoded from its '
    'own file',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      addTearDown(tester.view.reset);
      final decoded = <String>[];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            isRemoteModeProvider.overrideWithValue(false),
            imagingBackendProvider.overrideWithValue(_NoThumbnails()),
            nightSessionLightRowsProvider.overrideWithValue([
              _light(1),
              _light(2),
            ]),
            allDbTargetsProvider.overrideWith(
              (ref) => Stream.value([_target(1, 'M34')]),
            ),
            frameFileDecoderProvider.overrideWithValue((path) async {
              decoded.add(path);
              return _decoded(64, 48);
            }),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: ImagingSessionFrames()),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('#1'));
      await _settle(tester);

      expect(decoded, ['/captures/f1.fits']);
      expect(find.byType(SavedFrameViewer), findsOneWidget);
      expect(
        find.textContaining('64 × 48', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('2 of 2', findRichText: true), findsOneWidget);

      // The newest frame is first in the grid; the one before it is a key away.
      await tester.tap(find.text('Previous'));
      await _settle(tester);
      expect(decoded, ['/captures/f1.fits', '/captures/f2.fits']);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byType(SavedFrameViewer), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

bridge.FitsReadResult _decoded(int width, int height) => bridge.FitsReadResult(
      width: width,
      height: height,
      bitpix: 16,
      displayData: Uint8List(width * height * 4),
      histogram: Uint32List(256),
      stats: const bridge.ImageStatsResult(
        min: 0,
        max: 1000,
        mean: 500,
        median: 480,
        stdDev: 20,
        starCount: 0,
      ),
    );

/// Lets the viewer route open or close and its load land. The frame's texture
/// decode spins a loading mark, so pumpAndSettle would never settle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
