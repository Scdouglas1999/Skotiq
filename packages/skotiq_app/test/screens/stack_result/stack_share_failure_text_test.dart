import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/stack_result/stack_and_share_dialog.dart';

void main() {
  test('unwraps the flutter_rust_bridge union around a native failure', () {
    const raw = 'SkotiqError.imageError(field0: Alignment residual too '
        'high: 10.34px (max 10.00px))';
    final failure = describeStackShareFailure(raw);

    // The trailing parenthetical belongs to the sentence and must survive.
    expect(
      failure.message,
      'Alignment residual too high: 10.34px (max 10.00px)',
    );
    expect(failure.technical, raw);
    expect(failure.nextStep, contains('Cull'));
  });

  test('strips a Dart exception type prefix', () {
    final failure = describeStackShareFailure(
      'StackAndShareAllFramesRejectedException: Every one of the 7 follower '
      'frames was rejected, so only the reference remained of 8 selected. '
      'Most common reason: too few stars.',
    );

    expect(failure.message, startsWith('Every one of the 7 follower frames'));
    expect(failure.nextStep, isNotNull);
  });

  test('leaves an already-plain sentence alone and offers no technical text',
      () {
    final failure = describeStackShareFailure(
      'Stacking engine returned 4 channels; only 1 (mono) or 3 (interleaved '
      'RGB16) are supported.',
    );

    expect(
      failure.message,
      'Stacking engine returned 4 channels; only 1 (mono) or 3 (interleaved '
      'RGB16) are supported.',
    );
    expect(
      failure.technical,
      isNull,
      reason: 'a technical section identical to the message is noise',
    );
    // No invented next step for a cause we cannot name one for.
    expect(failure.nextStep, isNull);
  });

  test('peels a bridge union nested inside an app exception', () {
    final failure = describeStackShareFailure(
      'Exception: SkotiqError.imageError(field0: Reference frame has only '
      '0 stars, need at least 5 for alignment)',
    );

    expect(
      failure.message,
      'Reference frame has only 0 stars, need at least 5 for alignment',
    );
  });
}
