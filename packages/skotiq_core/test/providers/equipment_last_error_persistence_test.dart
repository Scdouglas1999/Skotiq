// Assert that the device-state notifiers keep `lastError`
// visible across the Connecting transition, and only clear it once the
// device actually reaches Connected.
//
// This is the contract the equipment-card subtitle relies on: when the
// auto-reconnect mechanism fires after a driver error, the
// user must keep seeing the *most recent driver error* in the card
// while the retry is in flight. Clearing it the instant we entered
// Connecting would flash the descriptive subtitle back for a few
// hundred ms and then either confirm Connected or jump back to the
// same error — visually identical to "nothing went wrong" until the
// retry fails again, which is exactly the silent fallback we
// guard against.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
  });

  group('CameraStateNotifier — lastError persistence', () {
    test(
      'setError → setConnecting preserves lastError; setConnected clears it',
      () {
        final notifier = container.read(cameraStateProvider.notifier);

        // 1. Driver error arrives (the device service invokes setError with the raw
        //    driver message).
        notifier.setError(Exception('ASCOM error 0x80040403 - device offline'));
        var state = container.read(cameraStateProvider);
        expect(state.connectionState, DeviceConnectionState.error);
        expect(state.hasError, isTrue);
        expect(
          state.lastError!.message,
          contains('0x80040403'),
          reason: 'raw driver text must be preserved verbatim on the snapshot',
        );

        // 2. Auto-reconnect kicks off — state flips to Connecting. The
        //    lastError must still be visible so the card subtitle does
        //    not flash back to the descriptive text.
        notifier.setConnecting('cam-1', 'Test Camera');
        state = container.read(cameraStateProvider);
        expect(state.connectionState, DeviceConnectionState.connecting);
        expect(state.hasError, isTrue);
        expect(state.lastError!.message, contains('0x80040403'));

        // 3. Reconnect succeeds — *now* we clear the error.
        notifier.setConnected();
        state = container.read(cameraStateProvider);
        expect(state.connectionState, DeviceConnectionState.connected);
        expect(state.hasError, isFalse);
        expect(state.lastError, isNull);
      },
    );

    test('a fresh setError replaces the previous lastError', () {
      final notifier = container.read(cameraStateProvider.notifier);
      notifier.setError(Exception('first failure'));
      final first = container.read(cameraStateProvider).lastError;
      expect(first!.message, contains('first failure'));

      notifier.setError(Exception('second failure'));
      final second = container.read(cameraStateProvider).lastError;
      expect(second!.message, contains('second failure'));
      expect(second.message, isNot(contains('first failure')));
    });
  });

  group('MountStateNotifier — lastError persistence', () {
    test(
      'setError → setConnecting preserves lastError; setConnected clears it',
      () {
        final notifier = container.read(mountStateProvider.notifier);

        notifier.setError(Exception('Mount slew refused (0x80040406)'));
        expect(
          container.read(mountStateProvider).lastError!.message,
          contains('0x80040406'),
        );

        notifier.setConnecting('mount-1', 'Test Mount');
        final mid = container.read(mountStateProvider);
        expect(mid.connectionState, DeviceConnectionState.connecting);
        expect(mid.lastError!.message, contains('0x80040406'));

        notifier.setConnected();
        final after = container.read(mountStateProvider);
        expect(after.connectionState, DeviceConnectionState.connected);
        expect(after.lastError, isNull);
      },
    );
  });

  group('FocuserStateNotifier — lastError persistence', () {
    test(
      'setError → setConnecting preserves lastError; setConnected clears it',
      () {
        final notifier = container.read(focuserStateProvider.notifier);

        notifier.setError(Exception('focuser USB disconnected'));
        expect(container.read(focuserStateProvider).hasError, isTrue);

        notifier.setConnecting('focuser-1');
        expect(
          container.read(focuserStateProvider).hasError,
          isTrue,
          reason: 'lastError must survive the Connecting transition',
        );

        notifier.setConnected();
        expect(container.read(focuserStateProvider).hasError, isFalse);
      },
    );
  });
}
