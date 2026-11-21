import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('getImprovementCurveJson returns the stored curve, or null', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = IntegratedMastersDao(db);

    final id = await dao.insertMaster(
      name: 'M31_L',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
    );

    expect(await dao.getImprovementCurveJson(id), isNull);

    const curveJson =
        '{"points":[{"count":1,"snr":12.5}],"population":["a.fits"]}';
    await dao.updateSmartFields(id, improvementCurveJson: curveJson);
    expect(await dao.getImprovementCurveJson(id), curveJson);
    expect(await dao.getImprovementCurveJson(id + 999), isNull);
  });
}
