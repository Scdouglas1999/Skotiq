// The host FFI backend answers a guider status poll with "disconnected" when
// the native library is not loaded, rather than failing the poll. The tracked
// stars come with the native status itself (`GuiderStatus.trackedStars`).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('with no native library the guider reads as disconnected', () async {
    final backend = FfiBackend();

    final status = await backend.guiderGetStatus();

    expect(status.connected, isFalse);
    expect(status.trackedStars, isEmpty);
  });
}
