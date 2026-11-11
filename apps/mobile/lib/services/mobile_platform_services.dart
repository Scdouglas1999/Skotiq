import 'package:skotiq_app/startup/always_on_services.dart';

import 'live_activity_lifecycle_provider.dart';
import 'mobile_sequence_hooks.dart';
import 'voice_control_lifecycle_provider.dart';
import 'watch_complication_lifecycle_provider.dart';

const _mobile = {AppRole.mobile};

/// The phone app's own always-on services: the ones that talk to iOS and
/// Android. They are started with the shared table in
/// `skotiq_app/startup/always_on_services.dart`, which cannot name them
/// because they live in this app.
final List<AlwaysOnService> mobilePlatformServices = [
  AlwaysOnService(
    'background sequence hooks',
    mobileSequenceHooksProvider,
    _mobile,
    'the run kept in view while the app is in the background',
  ),
  AlwaysOnService(
    'Live Activity',
    liveActivityLifecycleProvider,
    _mobile,
    'the iOS Live Activity for the running sequence',
  ),
  AlwaysOnService(
    'Apple Watch complication',
    watchComplicationLifecycleProvider,
    _mobile,
    'the watch complication following the run and the weather',
  ),
  AlwaysOnService(
    'voice control',
    voiceControlLifecycleProvider,
    _mobile,
    'Siri and Google Assistant answering "how is my sequence" and pausing '
        'or resuming it',
  ),
];
