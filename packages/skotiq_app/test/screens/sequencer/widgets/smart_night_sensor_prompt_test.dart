import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_night_dialog.dart';
import 'package:skotiq_core/services.dart';

void main() {
  // QA N09: the camera sensor dialog came back over the wizard on every Next
  // to the preview after it had been closed once.
  test('the wizard asks for missing sensor values once', () {
    const missing = ResolvedCameraSensorSpecs.none;
    expect(smartNightAsksForSensorSpecs(missing, alreadyAsked: false), isTrue);
    expect(smartNightAsksForSensorSpecs(missing, alreadyAsked: true), isFalse);
  });
}
