// A goal carries the reference light's SET-TEMP and READOUTM when it states
// them, so the host holds lights and masters to them. A goal stored or sent
// before they were read carries neither, and its JSON is unchanged.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

const _legacy = {
  'instrument': 'ASI2600MM',
  'filter': 'Ha',
  'exposureSecs': 300.0,
  'gain': 100,
  'offset': 50,
  'binX': 1,
  'binY': 1,
  'ccdTempC': -10.0,
};

void main() {
  test('a goal without the cards reads and writes as before', () {
    final settings = AcquisitionSettings.fromJson(_legacy);
    expect(settings.setPointC, isNull);
    expect(settings.readMode, isNull);
    expect(settings.toJson(), _legacy);
  });

  test('the set-point and read mode travel with the goal', () {
    final json = {..._legacy, 'setPointC': -10.0, 'readMode': 'High Gain'};
    final settings = AcquisitionSettings.fromJson(json);
    expect(settings.setPointC, -10.0);
    expect(settings.readMode, 'High Gain');
    expect(settings.toJson(), json);
  });
}
