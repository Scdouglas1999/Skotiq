// `flutter test` has no loadable `libskotiq_bridge`, so this exercises the
// library-absent branch, which is the branch that must refuse.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

void main() {
  setUpAll(() async {
    await NativeBridge.init();
  });

  test('init without the library leaves the bridge unavailable', () {
    expect(NativeBridge.isNativeAvailable, isFalse);
  });

  test('run refuses under the operation name without calling the body', () {
    var called = false;
    expect(
      NativeBridge.run('mountPark', () {
        called = true;
      }),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith('Operation "mountPark" requires the native bridge.'),
            contains('fails closed'),
          ),
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('requireNative throws the same refusal synchronously', () {
    expect(
      () => NativeBridge.requireNative('plateSolveBlind'),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          startsWith('Operation "plateSolveBlind" requires the native bridge.'),
        ),
      ),
    );
  });
}
