// Pressing Connect on the guider used to REPLACE the friendly device name with
// the raw device id, because GuiderStateNotifier.connect passed the id as the
// name. Observed live on 2026-08-09 on an Android emulator paired to a headless
// appliance: the Devices tab read "Built-in Multi-Star Guider" while offline,
// and the instant it connected both that card and the guide-health card below
// it read `native:builtin_guider:multi_star` — and kept reading it, because
// nothing later restores the name.
//
// This test fails if connect() goes back to overwriting the name with the id.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const _builtinGuiderId = 'native:builtin_guider:multi_star';
const _friendlyName = 'Built-in Multi-Star Guider';

void main() {
  // The Connecting state is published synchronously, before connect() awaits
  // anything, so read it without awaiting the (backend-less, therefore
  // failing) attempt. Awaiting would drag in the device service's own
  // slot-release bookkeeping and stop the assertion pinning THIS decision.
  test('connect publishes the friendly name, not the raw device id', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    unawaited(
      container
          .read(guiderStateProvider.notifier)
          .connect(_builtinGuiderId, deviceName: _friendlyName, maxRetries: 1),
    );

    final state = container.read(guiderStateProvider);
    expect(state.connectionState, DeviceConnectionState.connecting);
    expect(state.deviceName, _friendlyName);
    expect(
      state.deviceName,
      isNot(_builtinGuiderId),
      reason:
          'the raw device id must never replace a friendly name the '
          'caller supplied',
    );
  });

  test('connect without a name still falls back to the id', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    unawaited(
      container
          .read(guiderStateProvider.notifier)
          .connect(_builtinGuiderId, maxRetries: 1),
    );

    expect(container.read(guiderStateProvider).deviceName, _builtinGuiderId);
  });
}
