// Rows written before the frame-type names were one spelling say "Light".
// They are light frames to every Analytics count.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/session_elapsed.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

DbCapturedImage _frame(int id, String frameType, {bool accepted = true}) =>
    DbCapturedImage(
      id: id,
      sessionId: 4,
      filePath: '/frames/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: frameType,
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 30, 2, id),
      createdAt: DateTime.utc(2026, 7, 30, 2, id),
      isAccepted: accepted,
      isPlateSolved: false,
    );

void main() {
  test('a session graded "Light" frames counts them as lights', () async {
    final container = ProviderContainer(
      overrides: [
        allDbImagesProvider.overrideWith(
          (ref) => Stream.value([
            _frame(1, 'light'),
            _frame(2, 'Light'),
            _frame(3, 'Light', accepted: false),
            _frame(4, 'dark'),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(allDbImagesProvider.future);

    final grading = container.read(gradingBySessionProvider)![4]!;
    expect(grading.accepted, 2);
    expect(grading.rejected, 1);
  });
}
