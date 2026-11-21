import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/services/lan_push_frame_reader.dart';

void main() {
  testWidgets('authentication length and payload share one deadline', (
    tester,
  ) async {
    final chunks = StreamController<Uint8List>();
    final reader = LanPushFrameReader(
      chunks.stream,
      idleTimeout: const Duration(minutes: 1),
    );
    Object? failure;
    unawaited(
      reader
          .readAuthFrame(const Duration(seconds: 10))
          .then<void>(
            (_) {},
            onError: (Object error) {
              failure = error;
            },
          ),
    );
    await tester.pump(const Duration(seconds: 6));
    chunks.add(Uint8List.fromList([0, 0, 0, 1]));
    await tester.pump();
    expect(failure, isNull);
    await tester.pump(const Duration(seconds: 4));
    expect(failure, isA<TimeoutException>());
    unawaited(chunks.close());
  });
}
