import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_mobile/services/live_activity_lifecycle_provider.dart';
import 'package:skotiq_mobile/services/mobile_platform_services.dart';
import 'package:skotiq_mobile/services/mobile_sequence_hooks.dart';
import 'package:skotiq_mobile/services/poll_rate_service.dart';
import 'package:skotiq_mobile/services/voice_control_lifecycle_provider.dart';
import 'package:skotiq_mobile/services/watch_complication_lifecycle_provider.dart';

void main() {
  test('the phone starts its platform services, voice control included', () {
    expect(mobilePlatformServices.map((s) => s.provider), [
      mobileSequenceHooksProvider,
      liveActivityLifecycleProvider,
      watchComplicationLifecycleProvider,
      pollPaceProvider,
      // Defined with its native side long before anything started it.
      voiceControlLifecycleProvider,
    ]);
    for (final service in mobilePlatformServices) {
      expect(service.roles, {AppRole.mobile}, reason: service.name);
    }
  });
}
