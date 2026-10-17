// `FfiBackend.setLocation` honours its `Future<void>` contract.
//
// Invoking `apiSetLocation(...)` WITHOUT awaiting it completes the returned
// `Future<void>` before the native write resolves: a failed observer-location
// write then surfaces only as a dropped, unhandled async error — never to the
// caller — and an await-then-read pair can observe stale state.
//
// These tests drive the REAL `FfiBackend` (NOT a mock backend), so the seam is
// exercised end to end. In the no-native test runtime the bridge's
// `apiSetLocation` rejects (the native library is required and absent). The
// awaited `setLocation` therefore propagates that rejection out of
// `await backend.setLocation(...)`; a dropped Future would let the call
// complete normally with the rejection lost.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FfiBackend.setLocation await/error-propagation contract', () {
    test(
      'a native write failure propagates out of await setLocation',
      () async {
        final backend = FfiBackend();

        const location = ObserverLocation(
          latitude: 45.5,
          longitude: -122.6,
          elevation: 100.0,
        );

        // The real native write rejects in the no-native runtime. Because
        // `setLocation` now awaits it, the rejection must surface to the caller
        // rather than being swallowed as an unhandled async error.
        await expectLater(
          backend.setLocation(location),
          throwsA(isA<Object>()),
        );
      },
    );

    test('clearing the location (null) also awaits the native write', () async {
      final backend = FfiBackend();

      await expectLater(backend.setLocation(null), throwsA(isA<Object>()));
    });
  });
}
