import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/session_stack_plan.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

CapturedImage _light(
  int id, {
  String? target = 'M34',
  String? filter = 'L',
  double? hfr,
  int bin = 1,
  FrameType type = FrameType.light,
}) =>
    CapturedImage(
      id: '$id',
      filePath: '/captures/f$id.fits',
      capturedAt: DateTime.utc(2026, 11, 11, 20, 0, id),
      settings: ExposureSettings(
        exposureTime: 5,
        gain: 100,
        offset: 50,
        binningX: bin,
        binningY: bin,
        filter: filter,
        frameType: type,
      ),
      stats: hfr == null ? null : ImageStats(hfr: hfr),
      targetName: target,
      format: ImageFileFormat.fits,
    );

class _RecordingStacker extends LiveStackingNotifier {
  _RecordingStacker(super.ref);

  final fromFrames = <(String, List<String>)>[];
  final fromFile = <String>[];

  @override
  Future<void> startFromFrames(
    String referencePath,
    List<String> framePaths, {
    LiveStackingConfig? config,
  }) async {
    fromFrames.add((referencePath, framePaths));
  }

  @override
  Future<void> startFromFile(
    String referenceImagePath, {
    LiveStackingConfig? config,
  }) async {
    fromFile.add(referenceImagePath);
  }
}

void main() {
  group('the frames a stack starts from', () {
    test('none without a light frame', () {
      expect(sessionStackPlanFor(const []), isNull);
      expect(sessionStackPlanFor([_light(1, type: FrameType.flat)]), isNull);
    });

    test('the sharpest kept frame of the newest group is the reference', () {
      final plan = sessionStackPlanFor([
        _light(1, hfr: 2.5),
        _light(2, hfr: 2.1),
        _light(3, hfr: 1.9, type: FrameType.snapshot),
        _light(4, hfr: 2.3),
      ])!;
      expect(plan.referencePath, '/captures/f2.fits');
      expect(plan.referenceHfr, 2.1);
      expect(plan.framePaths, ['/captures/f1.fits', '/captures/f4.fits']);
      expect(plan.frameCount, 3);
      expect(plan.filter, 'L');
    });

    test('other targets, filters and binnings stay out of the stack', () {
      final plan = sessionStackPlanFor([
        _light(1, target: 'M45', hfr: 1.0),
        _light(2, filter: 'Ha', hfr: 1.0),
        _light(3, bin: 2, hfr: 1.0),
        _light(4, hfr: 2.4),
        _light(5, hfr: 2.2),
      ])!;
      expect(plan.referencePath, '/captures/f5.fits');
      expect(plan.framePaths, ['/captures/f4.fits']);
    });

    test('unmeasured frames fall back to the newest as reference', () {
      final plan = sessionStackPlanFor([_light(1), _light(2)])!;
      expect(plan.referencePath, '/captures/f2.fits');
      expect(plan.referenceHfr, isNull);
    });
  });

  testWidgets(
    'Start stacks tonight\'s frames without opening a file dialog',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 1600);
      addTearDown(tester.view.reset);

      late _RecordingStacker stacker;
      var pickerCalls = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          isRemoteModeProvider.overrideWithValue(false),
          connectedCameraIdProvider.overrideWithValue(null),
          recentSessionFramesProvider.overrideWithValue([
            _light(1, hfr: 2.47),
            _light(2, hfr: 2.42),
            _light(3, hfr: 2.44),
          ]),
          stackingReferencePickerProvider.overrideWithValue(() async {
            pickerCalls++;
            return XFile('/picked.fits');
          }),
          liveStackingProvider.overrideWith((ref) {
            stacker = _RecordingStacker(ref);
            return stacker;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: StackingPanel(colors: SkotiqColors.dark),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('3 L frames from tonight'),
        findsOneWidget,
      );
      await tester.tap(find.text('Stack tonight\'s frames'));
      await tester.pump();
      await tester.pump();

      expect(pickerCalls, 0);
      expect(stacker.fromFrames, hasLength(1));
      expect(stacker.fromFrames.single.$1, '/captures/f2.fits');
      expect(
        stacker.fromFrames.single.$2,
        ['/captures/f1.fits', '/captures/f3.fits'],
      );

      // A reference from disk is still one click away.
      await tester.tap(find.text('Choose a file…'));
      await tester.pump();
      await tester.pump();
      expect(pickerCalls, 1);
      expect(stacker.fromFile, ['/picked.fits']);
      expect(tester.takeException(), isNull);
    },
  );
}
