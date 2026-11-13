// Tests for the framing "effective aim" state: setAim normalisation, the
// aim-vs-view-centre lifecycle, and aim-centred mosaic panel placement.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import '../harness/in_memory_database.dart';

const _equipment = FramingEquipment(
  cameraName: 'Test Camera',
  sensorWidthMm: 23.5,
  sensorHeightMm: 15.7,
  pixelSizeMicrons: 3.76,
  pixelsX: 6248,
  pixelsY: 4176,
  telescopeName: 'Test Scope',
  focalLengthMm: 900,
  apertureMm: 150,
);

FramingTarget _target({
  double ra = 5.0,
  double dec = 20.0,
  String name = 'M45',
}) => FramingTarget(
  name: name,
  raHours: ra,
  decDegrees: dec,
  type: TargetType.cluster,
  magnitude: 1.6,
  constellation: 'Tau',
);

/// 1°/px-equivalent scale: 4° of sky across 100 image px gives 25 px/deg so a
/// 50-px canvas drag moves the view centre by exactly 2°.
const _plateScale = FramingPlateScale(
  surveyFovWidthDeg: 4.0,
  surveyFovHeightDeg: 4.0,
  imagePixelWidth: 100,
  imagePixelHeight: 100,
);

/// A notifier seeded with an arbitrary initial state whose IO surfaces
/// (HiPS fetch, last-framed persistence) are stubbed so the pure state
/// transitions can be exercised directly.
class _SeededFraming extends FramingNotifier {
  _SeededFraming(super.ref, FramingState seed) {
    state = seed;
  }

  @override
  Future<void> loadSurveyImage({double? canvasWidthLogicalPx}) async {}

  @override
  Future<void> persistLastFramedTarget(FramingTarget target) async {}
}

ProviderContainer _container({FramingState? seed}) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      framingProvider.overrideWith(
        (ref) => _SeededFraming(ref, seed ?? const FramingState()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('setAim', () {
    test('normalizes RA into [0, 24) and clamps Dec into [-90, 90]', () {
      final container = _container(seed: FramingState(target: _target()));
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(25.5, 95.0);
      expect(container.read(framingProvider).aimRaHours, closeTo(1.5, 1e-9));
      expect(container.read(framingProvider).aimDecDegrees, 90.0);

      notifier.setAim(-2.0, -95.0);
      expect(container.read(framingProvider).aimRaHours, closeTo(22.0, 1e-9));
      expect(container.read(framingProvider).aimDecDegrees, -90.0);
    });

    test('rejects non-finite aim', () {
      final container = _container(seed: FramingState(target: _target()));
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(double.nan, 10.0);
      notifier.setAim(5.0, double.infinity);
      expect(container.read(framingProvider).aimRaHours, isNull);
      expect(container.read(framingProvider).aimDecDegrees, isNull);
    });

    test('stores an aim distinct from the view-center target', () {
      final container = _container(seed: FramingState(target: _target()));
      container.read(framingProvider.notifier).setAim(5.5, 19.0);
      final state = container.read(framingProvider);

      expect(state.target!.raHours, 5.0);
      expect(state.effectiveAimRaHours, 5.5);
      expect(state.effectiveAimDecDegrees, 19.0);
    });
  });

  group('effective aim accessors', () {
    test('fall back to the view-center target when no aim is set', () {
      final container = _container(seed: FramingState(target: _target()));
      final state = container.read(framingProvider);

      expect(state.effectiveAimRaHours, 5.0);
      expect(state.effectiveAimDecDegrees, 20.0);
      expect(identical(state.effectiveAimTarget, state.target), isTrue);
    });

    test('are null when no target is selected', () {
      final container = _container();
      final state = container.read(framingProvider);

      expect(state.effectiveAimRaHours, isNull);
      expect(state.effectiveAimDecDegrees, isNull);
      expect(state.effectiveAimTarget, isNull);
    });

    test('effectiveAimTarget carries the picked object metadata on the aim '
        'coordinates', () {
      final container = _container(seed: FramingState(target: _target()));
      container.read(framingProvider.notifier).setAim(6.25, 18.5);
      final aim = container.read(framingProvider).effectiveAimTarget!;

      expect(aim.raHours, 6.25);
      expect(aim.decDegrees, 18.5);
      // Metadata still comes from the object the user picked.
      expect(aim.name, 'M45');
      expect(aim.type, TargetType.cluster);
      expect(aim.magnitude, 1.6);
      expect(aim.constellation, 'Tau');
    });
  });

  group('aim lifecycle', () {
    test('a fresh setTarget clears the aim', () {
      final container = _container(seed: FramingState(target: _target()));
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(7.0, 30.0);
      notifier.setTarget(_target(ra: 10.0, dec: 40.0, name: 'M31'));

      final state = container.read(framingProvider);
      expect(state.aimRaHours, isNull);
      expect(state.aimDecDegrees, isNull);
      expect(state.effectiveAimRaHours, 10.0);
    });

    test('a fresh setTargetCoordinates clears the aim', () {
      final container = _container(seed: FramingState(target: _target()));
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(7.0, 30.0);
      notifier.setTargetCoordinates(12.0, -10.0, name: 'Manual point');

      final state = container.read(framingProvider);
      expect(state.aimRaHours, isNull);
      expect(state.effectiveAimRaHours, 12.0);
      expect(state.effectiveAimTarget!.name, 'Manual point');
    });

    test('a fresh setTargetSuggestion clears the aim', () {
      final container = _container(seed: FramingState(target: _target()));
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(7.0, 30.0);
      notifier.setTargetSuggestion(
        const TargetSuggestion(
          targetId: 42,
          targetName: 'NGC 7000',
          catalogId: 'NGC 7000',
          raHours: 20.97,
          decDegrees: 44.5,
          totalScore: 91.0,
          visibility: TargetVisibilityInfo(
            currentAltitude: 50.0,
            currentAzimuth: 200.0,
            airmass: 1.3,
            moonDistance: 80.0,
            peakAltitude: 62.0,
            hoursAboveMinAlt: 5.0,
          ),
        ),
      );

      final state = container.read(framingProvider);
      expect(state.aimRaHours, isNull);
      expect(state.effectiveAimRaHours, closeTo(20.97, 1e-9));
      expect(state.effectiveAimTarget!.name, 'NGC 7000');
    });

    test('_recenterFromPan preserves the aim (it is absolute sky, not view '
        'state)', () {
      final container = _container(
        seed: FramingState(
          target: _target(),
          plateScale: _plateScale,
          useCustomEquipment: true,
          customEquipment: _equipment,
        ),
      );
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(6.0, 18.0);
      // 50 px at 25 px/deg = 2° moved — past the 1.4° refetch threshold.
      notifier.pan(50, 0, canvasSize: const Size(100, 100));

      final state = container.read(framingProvider);
      // The view centre moved with the sky …
      expect(state.target!.raHours, isNot(closeTo(5.0, 1e-6)));
      // … but the aim still points at the same patch of sky.
      expect(state.aimRaHours, 6.0);
      expect(state.aimDecDegrees, 18.0);
    });

    test('resetView clears the aim back to centered-on-target', () {
      final container = _container(seed: FramingState(target: _target()));
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(6.0, 18.0);
      notifier.resetView();

      final state = container.read(framingProvider);
      expect(state.aimRaHours, isNull);
      expect(state.aimDecDegrees, isNull);
      expect(state.effectiveAimRaHours, 5.0);
    });

    test('clearTarget clears the aim', () {
      final container = _container(seed: FramingState(target: _target()));
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(6.0, 18.0);
      notifier.clearTarget();

      expect(container.read(framingProvider).aimRaHours, isNull);
      expect(container.read(framingProvider).aimDecDegrees, isNull);
    });

    test('pan within the refetch threshold does not touch the aim', () {
      final container = _container(
        seed: FramingState(
          target: _target(),
          plateScale: _plateScale,
          useCustomEquipment: true,
          customEquipment: _equipment,
        ),
      );
      final notifier = container.read(framingProvider.notifier);

      notifier.setAim(6.0, 18.0);
      notifier.pan(10, 5, canvasSize: const Size(100, 100));

      final state = container.read(framingProvider);
      expect(state.aimRaHours, 6.0);
      expect(state.target!.raHours, 5.0);
      expect(state.panX, 10.0);
    });
  });

  group('aim-centered mosaic', () {
    test('the left column is east: columns run left to right on a sky '
        'shown north up, east left', () async {
      final container = _container(
        seed: FramingState(
          target: _target(),
          useCustomEquipment: true,
          customEquipment: _equipment,
        ),
      );
      final notifier = container.read(framingProvider.notifier);

      notifier.setMosaicConfig(const FramingMosaicConfig(columns: 2, rows: 1));
      notifier.setMosaicEnabled(true);
      await pumpEventQueue();

      final panels = container.read(framingProvider).mosaicPanels;
      final left = panels.firstWhere((p) => p.col == 0);
      final right = panels.firstWhere((p) => p.col == 1);
      expect(left.raHours, greaterThan(right.raHours));
    });

    test('Framing numbers a mosaic as the wizard and the sequence do',
        () async {
      final container = _container(
        seed: FramingState(
          target: _target(),
          useCustomEquipment: true,
          customEquipment: _equipment,
          rotation: 12,
        ),
      );
      final notifier = container.read(framingProvider.notifier);
      notifier.setMosaicConfig(const FramingMosaicConfig(
        columns: 3,
        rows: 2,
        overlapPercent: 20,
        startCorner: MosaicStartCorner.bottomRight,
      ));
      notifier.setMosaicEnabled(true);
      await pumpEventQueue();

      final framing = container.read(framingProvider).mosaicPanels;
      // The wizard's preview and every mosaic sequence come from here.
      final service = const MosaicService().generatePanels(MosaicConfig(
        centerRa: 5.0,
        centerDec: 20.0,
        panelWidthArcmin: _equipment.fovWidthDeg * 60,
        panelHeightArcmin: _equipment.fovHeightDeg * 60,
        overlapPercent: 20,
        rotation: 12,
        panelsHorizontal: 3,
        panelsVertical: 2,
        startCorner: MosaicStartCorner.bottomRight,
      ));
      String describe(MosaicPanel p) => '${p.number} ${p.name} '
          '${p.row},${p.col} ${p.raHours.toStringAsFixed(9)} '
          '${p.decDegrees.toStringAsFixed(9)}';
      expect(framing.map(describe), service.map(describe));
      expect((framing.first.row, framing.first.col), (1, 2));
    });

    test('single-panel grid sits on the aim, not the view center', () async {
      final container = _container(
        seed: FramingState(
          target: _target(),
          useCustomEquipment: true,
          customEquipment: _equipment,
        ),
      );
      final notifier = container.read(framingProvider.notifier);

      notifier.setMosaicConfig(const FramingMosaicConfig(columns: 1, rows: 1));
      notifier.setMosaicEnabled(true);
      await pumpEventQueue();

      var state = container.read(framingProvider);
      expect(state.mosaicPanels, hasLength(1));
      expect(state.mosaicPanels.single.raHours, closeTo(5.0, 1e-9));
      expect(state.mosaicPanels.single.decDegrees, closeTo(20.0, 1e-9));

      notifier.setAim(5.5, 21.0);
      await pumpEventQueue();

      state = container.read(framingProvider);
      expect(state.mosaicPanels, hasLength(1));
      expect(state.mosaicPanels.single.raHours, closeTo(5.5, 1e-9));
      expect(state.mosaicPanels.single.decDegrees, closeTo(21.0, 1e-9));
    });
  });
}
