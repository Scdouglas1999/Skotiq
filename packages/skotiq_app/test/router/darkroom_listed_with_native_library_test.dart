// Darkroom renders through the native library, so a device without it (the
// phone app) does not list it in its menus.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_core/utils.dart';

void main() {
  tearDown(() => DeviceTraits.debugOverride = null);

  test('a device without the native library does not list Darkroom', () {
    DeviceTraits.debugOverride =
        const DeviceTraits(touchOs: true, nativeLibrary: false);
    expect(AppRoute.darkroom.listedOnThisDevice, isFalse);
    expect(AppRoute.values.where((r) => r.needsNativeLibrary),
        [AppRoute.darkroom]);
  });

  test('a device with the native library lists Darkroom', () {
    DeviceTraits.debugOverride =
        const DeviceTraits(touchOs: false, nativeLibrary: true);
    expect(AppRoute.darkroom.listedOnThisDevice, isTrue);
  });
}
