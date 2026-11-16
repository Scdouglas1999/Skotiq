import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  final capture = RetainedCapture(
    deviceId: 'gphoto2:canon',
    cameraName: 'Canon EOS',
    location: '/store_00020001/DCIM/100CANON/IMG_0002.CR3',
    inCameraMemory: false,
    reason: 'The download failed',
    retainedAt: DateTime.utc(2026, 11, 15, 3, 12),
  );

  test('a linked client reads the capture the host lists', () {
    final read = RetainedCapture.fromJson(capture.toJson());
    expect(read.toJson(), capture.toJson());
    expect(read.retainedAt, capture.retainedAt);
  });

  test('a capture the host described in part is refused', () {
    for (final field in capture.toJson().keys) {
      final partial = capture.toJson()..remove(field);
      expect(
        () => RetainedCapture.fromJson(partial),
        throwsA(isA<TypeError>()),
        reason: 'without $field',
      );
    }
  });
}
