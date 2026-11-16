import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

final now = DateTime(2026, 11, 16, 5);
const reuse = CalibrationReuse(
  darkValidFor: Duration(days: 120),
  toleranceC: 2,
);

CalibrationMasterRecord master({
  CalibrationMasterType type = CalibrationMasterType.bias,
  double? exposure = 0.001,
  int gain = 139,
  int offset = 21,
  int bin = 1,
  double? setPoint = -10,
  double? temperature = -9.8,
  String? readMode,
  String? offSetPoint,
  required DateTime createdAt,
}) => CalibrationMasterRecord(
  type: type,
  id: 1,
  filePath: '/lib/Masters/master.fits',
  isMaster: true,
  exposureSeconds: exposure,
  temperature: temperature,
  gain: gain,
  offset: offset,
  binX: bin,
  binY: bin,
  readoutMode: readMode,
  offSetPoint: offSetPoint,
  setPointC: setPoint,
  createdAt: createdAt,
);

CalibrationFrameSetting bias({int gain = 139, double? setPoint = -10}) =>
    CalibrationFrameSetting(
      type: FrameType.bias,
      exposureSecs: 0,
      gain: gain,
      offset: 21,
      binX: 1,
      binY: 1,
      readMode: null,
      setPointC: setPoint,
    );

CalibrationFrameSetting dark({double exposure = 30, double setPoint = -10}) =>
    CalibrationFrameSetting(
      type: FrameType.dark,
      exposureSecs: exposure,
      gain: 139,
      offset: 21,
      binX: 1,
      binY: 1,
      readMode: null,
      setPointC: setPoint,
    );

db.DbCapturedImage frame(int id, DateTime at) => db.DbCapturedImage(
  id: id,
  filePath: '/n/Bias/Bias_$id.fits',
  fileName: 'Bias_$id.fits',
  fileFormat: 'fits',
  frameType: 'bias',
  exposureDuration: 0.001,
  gain: 139,
  offset: 21,
  binX: 1,
  binY: 1,
  sensorTemp: -10,
  isPlateSolved: false,
  capturedAt: at,
  createdAt: at,
  isAccepted: true,
);

CalibrationFrameGroup biasFrames(int count, DateTime at) =>
    CalibrationFrameGroup(
      setting: bias(),
      frames: [for (var i = 0; i < count; i++) frame(i, at)],
      offSetPoint: const [],
    );

LibraryCover cover(
  CalibrationFrameSetting need, {
  List<CalibrationMasterRecord> masters = const [],
  List<CalibrationFrameGroup> frames = const [],
  int frameCount = 200,
}) => libraryCover(
  need,
  masters: masters,
  frameGroups: frames,
  frameCount: frameCount,
  reuse: reuse,
  now: now,
);

void main() {
  test('a bias master of the setting covers the bias, however old', () {
    final old = master(createdAt: DateTime(2024, 3, 1));
    expect(
      cover(bias(), masters: [old]),
      isA<CoveredByMaster>().having((c) => c.master, 'master', same(old)),
    );
  });

  test('a bias master at another gain does not cover', () {
    expect(
      cover(
        bias(gain: 76),
        masters: [master(createdAt: DateTime(2026, 11, 15))],
      ),
      isA<NotCovered>().having((c) => c.why, 'why', isNull),
    );
  });

  test('a set-point counts within the dark library tolerance only', () {
    final m = master(createdAt: DateTime(2026, 11, 15));
    expect(cover(bias(setPoint: -8.5), masters: [m]), isA<CoveredByMaster>());
    expect(cover(bias(setPoint: 0), masters: [m]), isA<NotCovered>());
  });

  test('a master without a set-point stands at its measured temperature', () {
    final m = master(
      setPoint: null,
      temperature: -9.8,
      createdAt: DateTime(2026, 10, 24),
    );
    expect(cover(bias(), masters: [m]), isA<CoveredByMaster>());
    expect(cover(bias(setPoint: 1), masters: [m]), isA<NotCovered>());
  });

  test('a master built off its set-point does not cover', () {
    expect(
      cover(
        bias(),
        masters: [
          master(
            createdAt: DateTime(2026, 11, 15),
            offSetPoint: 'Built from frames that read -2 °C',
          ),
        ],
      ),
      isA<NotCovered>(),
    );
  });

  test('read modes are compared when both state one', () {
    final m = master(readMode: 'High speed', createdAt: DateTime(2026, 11, 15));
    const normal = CalibrationFrameSetting(
      type: FrameType.bias,
      exposureSecs: 0,
      gain: 139,
      offset: 21,
      binX: 1,
      binY: 1,
      readMode: 'Normal',
      setPointC: -10,
    );
    expect(cover(normal, masters: [m]), isA<NotCovered>());
    expect(cover(bias(), masters: [m]), isA<CoveredByMaster>());
  });

  test('a dark master covers within the days darks stay valid', () {
    final recent = master(
      type: CalibrationMasterType.dark,
      exposure: 30,
      createdAt: now.subtract(const Duration(days: 119)),
    );
    expect(cover(dark(), masters: [recent]), isA<CoveredByMaster>());
    expect(cover(dark(exposure: 60), masters: [recent]), isA<NotCovered>());
  });

  test('a dark master older than the setting does not cover, and says so', () {
    final old = master(
      type: CalibrationMasterType.dark,
      exposure: 30,
      createdAt: now.subtract(const Duration(days: 121)),
    );
    expect(
      cover(dark(), masters: [old]),
      isA<NotCovered>().having(
        (c) => c.why,
        'why',
        'the newest library master, from Jul 18, is older than the 120 days '
            'a dark stays valid',
      ),
    );
  });

  test('frames without a master cover when there are as many as planned', () {
    final group = biasFrames(200, DateTime(2026, 10, 30, 2));
    expect(
      cover(bias(), frames: [group]),
      isA<CoveredByFrames>().having((c) => c.group, 'group', same(group)),
    );
  });

  test('fewer frames than planned do not cover', () {
    expect(
      cover(bias(), frames: [biasFrames(50, DateTime(2026, 10, 22, 5))]),
      isA<NotCovered>().having(
        (c) => c.why,
        'why',
        'the library holds 50 such frames without a master, fewer than the '
            '200 planned',
      ),
    );
  });

  test('a master wins over frames of the same setting', () {
    final m = master(createdAt: DateTime(2026, 10, 24));
    expect(
      cover(
        bias(),
        masters: [m],
        frames: [biasFrames(200, DateTime(2026, 10, 30, 2))],
      ),
      isA<CoveredByMaster>(),
    );
  });

  test('a dark flat is covered by a dark master of its exposure', () {
    final m = master(
      type: CalibrationMasterType.dark,
      exposure: 2.5,
      createdAt: DateTime(2026, 11, 10),
    );
    const darkFlat = CalibrationFrameSetting(
      type: FrameType.darkFlat,
      exposureSecs: 2.5,
      gain: 139,
      offset: 21,
      binX: 1,
      binY: 1,
      readMode: null,
      setPointC: -10,
    );
    expect(cover(darkFlat, masters: [m]), isA<CoveredByMaster>());
  });
}
