import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';

void main() {
  test('a linked client with the host plan open does not recover', () {
    expect(
      hostOpenPlanDefersCheckpoint(
        linkedClient: true,
        hostHasOpenPlan: true,
      ),
      isTrue,
    );
    expect(
      hostOpenPlanDefersCheckpoint(
        linkedClient: true,
        hostHasOpenPlan: false,
      ),
      isFalse,
    );
    expect(
      hostOpenPlanDefersCheckpoint(
        linkedClient: false,
        hostHasOpenPlan: true,
      ),
      isFalse,
    );
  });
}
