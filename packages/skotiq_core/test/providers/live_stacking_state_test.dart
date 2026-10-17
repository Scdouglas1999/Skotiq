import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/live_stacking_provider.dart';

void main() {
  test('copyWith preserves nullable fields when no clear is requested', () {
    final original = LiveStackingState(
      status: LiveStackingStatus.error,
      previewData: Uint16List.fromList([1, 2]),
      previewWidth: 2,
      previewHeight: 1,
      errorMessage: 'old failure',
    );

    final updated = original.copyWith(previewWidth: 3);

    expect(updated.previewData, same(original.previewData));
    expect(updated.errorMessage, 'old failure');
  });

  test('copyWith can explicitly clear stale preview and error fields', () {
    final original = LiveStackingState(
      status: LiveStackingStatus.error,
      previewData: Uint16List.fromList([1, 2]),
      previewWidth: 2,
      previewHeight: 1,
      errorMessage: 'old failure',
    );

    final cleared = original.copyWith(
      status: LiveStackingStatus.running,
      clearPreviewData: true,
      clearErrorMessage: true,
    );

    expect(cleared.previewData, isNull);
    expect(cleared.errorMessage, isNull);
  });
}
