import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

void main() {
  // The payload `FailedStep::err` writes in
  // `native/skotiq_native/processing/src/darkroom/args.rs`.
  const payload =
      '{"kind":"step_failed","index":1,"opId":"stretch","opVersion":1,'
      '"reason":"the white point is below the black point",'
      '"message":"step 2 failed: stretch@1: the white point is below the '
      'black point"}';

  test('a failed step is read from its fields', () {
    final failed = DarkroomFailedStep.tryDecode(payload);

    expect(failed, isNotNull);
    expect(failed!.index, 1);
    expect(failed.opId, 'stretch');
    expect(failed.opVersion, 1);
    expect(failed.reason, 'the white point is below the black point');
    expect(
      failed.message,
      'step 2 failed: stretch@1: the white point is below the black point',
    );
  });

  test('the bridge may wrap the payload in its own exception text', () {
    expect(DarkroomFailedStep.tryDecode('AnyhowException($payload)')?.index, 1);
  });

  test(
    'a sentence, a cancellation and a half payload are not failed steps',
    () {
      expect(
        DarkroomFailedStep.tryDecode('step 2 failed: stretch@1: bad'),
        isNull,
      );
      expect(
        DarkroomFailedStep.tryDecode(
          '{"kind":"cancelled","renderId":"r","phase":"render"}',
        ),
        isNull,
      );
      expect(
        DarkroomFailedStep.tryDecode('{"kind":"step_failed","index":1}'),
        isNull,
      );
    },
  );
}
