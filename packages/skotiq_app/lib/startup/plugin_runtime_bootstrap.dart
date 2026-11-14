// Eager bootstrap for the bundled plugin runtime.
//
// Plugins must be registered before a sequence can start, unattended runs
// included: a headless sequence containing a plugin node fails after a clean
// restart otherwise. Hardware-owning entry points call this before accepting
// sequence work.

// ignore: implementation_imports
import 'package:skotiq_plugins/src/plugin_registration.dart'
    show pluginRegistrationProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Register every bundled plugin and apply persisted enablement choices.
///
/// Call only in a hardware-owning process. A NetworkBackend client must not
/// populate its palette from local plugin state because execution belongs to
/// the remote imaging host.
Future<void> initializeBundledPluginRuntime(ProviderContainer container) {
  return container.read(pluginRegistrationProvider.future);
}
