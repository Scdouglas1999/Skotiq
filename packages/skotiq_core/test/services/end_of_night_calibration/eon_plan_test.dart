import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

db.CapturedImage light(
  int id, {
  double exposure = 90,
  int? gain = 76,
  int? offset = 15,
  int bin = 1,
  double? sensorTemp = -10.1,
  String frameType = 'light',
}) {
  final at = DateTime(2026, 10, 22, 3).add(Duration(minutes: id));
  return db.CapturedImage(
    id: id,
    filePath: '/n/NGC0891_L_$id.fits',
    fileName: 'NGC0891_L_$id.fits',
    fileFormat: 'fits',
    frameType: frameType,
    exposureDuration: exposure,
    gain: gain,
    offset: offset,
    binX: bin,
    binY: bin,
    sensorTemp: sensorTemp,
    isPlateSolved: false,
    capturedAt: at,
    createdAt: at,
    isAccepted: true,
  );
}

void main() {
  group('planFrameNeeds', () {
    test('missing gain or offset cannot become a zero-setting dark group', () {
      for (final frame in [light(1, gain: null), light(2, offset: null)]) {
        expect(() => planFrameNeeds([frame]), throwsFormatException);
      }
      final needs = planFrameNeeds([light(3, gain: 0, offset: 0)]);
      expect(needs.darks.single.gain, 0);
      expect(needs.darks.single.offset, 0);
    });
    test('one dark set per light setting and one bias set per gain', () {
      final needs = planFrameNeeds([
        for (var i = 0; i < 30; i++) light(i),
        for (var i = 30; i < 75; i++) light(i, exposure: 120),
        light(99, frameType: 'dark'),
      ], cameraSetPointC: -10);

      expect(needs.darks, [
        const EonDarkGroup(
          exposureSecs: 90,
          gain: 76,
          offset: 15,
          binX: 1,
          binY: 1,
          setPointC: -10,
          lightCount: 30,
        ),
        const EonDarkGroup(
          exposureSecs: 120,
          gain: 76,
          offset: 15,
          binX: 1,
          binY: 1,
          setPointC: -10,
          lightCount: 45,
        ),
      ]);
      expect(needs.bias, [
        const EonBiasGroup(
          gain: 76,
          offset: 15,
          binX: 1,
          binY: 1,
          setPointC: -10,
        ),
      ]);
    });

    test('lights far from the set-point keep their own temperature', () {
      final needs = planFrameNeeds([
        light(1, sensorTemp: -10.2),
        light(2, sensorTemp: -4.6),
      ], cameraSetPointC: -10);
      expect(needs.darks.map((d) => d.setPointC).toSet(), {-10.0, -5.0});
    });

    test('an uncooled camera groups by rounded sensor temperature', () {
      final needs = planFrameNeeds([
        light(1, sensorTemp: 12.3),
        light(2, sensorTemp: 11.8),
        light(3, sensorTemp: null),
      ]);
      expect(needs.darks.map((d) => d.setPointC).toSet(), {12.0, null});
    });

    test('no lights need nothing', () {
      expect(planFrameNeeds(const []).isEmpty, isTrue);
    });
  });

  group('findDarkSlot', () {
    test('finds the DARK slot on the owner wheel', () {
      final slot = findDarkSlot(const [
        'L',
        'R',
        'G',
        'B',
        'Ha',
        'SII',
        'OIII',
        'DARK',
      ]);
      expect(slot?.name, 'DARK');
      expect(slot?.index, 7);
    });

    test('accepts the usual names for a blank slot', () {
      for (final name in ['Blank', 'opaque', 'Closed', ' dark ']) {
        expect(findDarkSlot(['L', name])?.index, 1, reason: name);
      }
    });

    test('does not mistake a filter for a blank', () {
      expect(findDarkSlot(const ['L', 'Dark Sky', 'Ha']), isNull);
      expect(findDarkSlot(null), isNull);
    });
  });

  group('buildCalibrationSequence', () {
    final needs = planFrameNeeds([
      light(1),
      light(2, exposure: 120),
    ], cameraSetPointC: -10);

    test('cools, then takes darks and bias through the dark slot', () {
      final sequence = buildCalibrationSequence(
        needs: needs,
        darkCount: 20,
        biasCount: 50,
        biasExposureSecs: 0.001,
        cameraCanCool: true,
        darkSlot: const EonDarkSlot(name: 'DARK', index: 7),
      );
      final root = sequence.nodes[sequence.rootNodeId]!;
      final children = [for (final id in root.childIds) sequence.nodes[id]!];
      expect(children.first, isA<CoolCameraNode>());
      expect((children.first as CoolCameraNode).targetTemp, -10);
      final exposures = children.whereType<ExposureNode>().toList();
      expect(
        exposures.map((e) => (e.frameType, e.durationSecs, e.count)).toList(),
        [
          (FrameType.dark, 90.0, 20),
          (FrameType.dark, 120.0, 20),
          (FrameType.bias, 0.001, 50),
        ],
      );
      for (final e in exposures) {
        expect(e.filter, 'DARK');
        expect(e.filterIndex, 7);
        expect(e.gain, 76);
        expect(e.offset, 15);
        expect(e.ditherEvery, 0);
        expect(e.adaptiveExposure?.enabled, isFalse);
        expect(e.parentId, sequence.rootNodeId);
      }
      expect(isCalibrationOnlySequence(sequence), isTrue);
    });

    test('a camera that cannot cool gets no Cool Camera step', () {
      final sequence = buildCalibrationSequence(
        needs: needs,
        darkCount: 5,
        biasCount: 5,
        biasExposureSecs: 0.001,
        cameraCanCool: false,
      );
      expect(sequence.nodes.values.whereType<CoolCameraNode>(), isEmpty);
      expect(
        sequence.nodes.values.whereType<ExposureNode>().map((e) => e.filter),
        everyElement(isNull),
      );
    });
  });

  group('isCalibrationOnlySequence', () {
    test('a light frame or a slew makes it an imaging run', () {
      Sequence of(List<SequenceNode> children) {
        final root = InstructionSetNode(
          id: 'root',
          childIds: [for (final c in children) c.id],
        );
        return Sequence.create(
          name: 't',
          nodes: {root.id: root, for (final c in children) c.id: c},
          rootNodeId: root.id,
        );
      }

      final dark = ExposureNode(id: 'd', frameType: FrameType.dark);
      expect(isCalibrationOnlySequence(of([dark])), isTrue);
      expect(
        isCalibrationOnlySequence(of([dark, ExposureNode(id: 'l')])),
        isFalse,
      );
      expect(isCalibrationOnlySequence(of([dark, SlewNode(id: 's')])), isFalse);
      expect(
        isCalibrationOnlySequence(
          of([dark, ExposureNode(id: 'l', isEnabled: false)]),
        ),
        isTrue,
      );
      expect(isCalibrationOnlySequence(of([CoolCameraNode(id: 'c')])), isFalse);
    });
  });

  group('the plan\'s closing warm-up', () {
    Sequence plan(List<SequenceNode> steps) {
      const root = 'root';
      return Sequence.create(
        name: 'Night',
        rootNodeId: root,
        nodes: {
          root: InstructionSetNode(
            id: root,
            name: 'Night',
            childIds: [for (final n in steps) n.id],
          ),
          for (final n in steps) n.id: n,
        },
      );
    }

    test('only the warm-up among the closing steps is handed over', () {
      final sequence = plan([
        WarmCameraNode(id: 'early-warm', name: 'Warm', parentId: 'root'),
        ExposureNode(id: 'lights', name: 'Lights', parentId: 'root'),
        StopGuidingNode(id: 'stop', name: 'Stop', parentId: 'root'),
        HomeMountNode(id: 'home', name: 'Home', parentId: 'root'),
        WarmCameraNode(id: 'warm', name: 'Warm', parentId: 'root'),
      ]);
      expect(shutdownWarmUpIds(sequence), {'warm'});
    });

    test('a plan that ends on its lights hands nothing over', () {
      final sequence = plan([
        ExposureNode(id: 'lights', name: 'Lights', parentId: 'root'),
      ]);
      expect(shutdownWarmUpIds(sequence), isEmpty);
    });
  });

  test('end-of-night calibration is on unless switched off', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = SettingsDao(db);
    expect((await EonSettings.load(dao)).enabled, isTrue);
    await dao.setSetting(EonSettings.enabledKey, 'false');
    expect((await EonSettings.load(dao)).enabled, isFalse);
  });
}
