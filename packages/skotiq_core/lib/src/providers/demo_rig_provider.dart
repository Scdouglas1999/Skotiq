import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/logging_service.dart';
import 'backend_provider.dart';
import 'settings_provider.dart';

/// Hands the demo rig setting to [BackendNotifier], which puts the phone on
/// the demo rig while it is not linked to an imaging host, and back on no
/// backend when the setting is turned off. A linked phone always uses its
/// host.
///
/// Only the phone app watches this: a computer has the real simulators of
/// its own rig. The settings load again after every backend change, and a
/// reload is not a change of the setting, so only a loaded value is acted
/// on.
final demoRigSelectionProvider = Provider<void>((ref) {
  final notifier = ref.read(backendProvider.notifier);
  ref.listen<({bool wanted, double latitude, double longitude})?>(
    appSettingsProvider.select((async) {
      final settings = async.valueOrNull;
      if (settings == null) return null;
      return (
        wanted: settings.demoRig,
        latitude: settings.latitude,
        longitude: settings.longitude,
      );
    }),
    (previous, next) {
      if (next == null || next.wanted == previous?.wanted) return;
      notifier
          .setDemoRigWanted(
            next.wanted,
            latitudeDeg: next.latitude,
            longitudeDeg: next.longitude,
          )
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              // A connect or disconnect asked for meanwhile owns the backend.
              if (error is BackendTransitionSupersededException) return;
              Log.error(
                'Could not ${next.wanted ? 'start' : 'stop'} the demo rig: '
                '$error',
                source: 'DemoRig',
                error: error,
                stackTrace: stackTrace,
              );
            },
          );
    },
    fireImmediately: true,
  );
});
