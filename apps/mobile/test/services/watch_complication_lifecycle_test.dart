// Tests for the Apple Watch complication lifecycle throttle.
//
// The watch complication's `WidgetCenter.reloadAllTimelines()` is a system
// call we deliberately do NOT want to fire on every sequence-progress
// event. The lifecycle controller is supposed to throttle publishes to
// at most one per 30 s; if that throttle regresses we'll burn through
// WidgetKit's reload budget and the OS may start dropping reloads.
//
// We exercise the throttle directly via
// `WatchComplicationLifecycleController.submitSnapshotForTest` — the
// production listeners pipe their state changes into the same throttle
// path. Going through `submitSnapshotForTest` lets us assert the
// invariant ("N submits in a 30 s window produce at most 1 publish")
// without spinning up the four upstream providers, which depend on
// Drift / FFI / scheduler fixtures.
//
// The fake clock is injected via the `now:` parameter on the controller
// constructor so the test does not actually wait 30 s.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/watch_complication_lifecycle_provider.dart'
    show WatchComplicationLifecycleController;
import 'package:skotiq_mobile/services/watch_complication_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WatchComplicationSnapshot', () {
    test('equality compares every field', () {
      final a = WatchComplicationSnapshot(
        targetName: 'NGC 7000',
        framesCompleted: 12,
        framesTotal: 120,
        currentFilter: 'Ha',
        jobState: 'exposing',
        weatherSafe: true,
        weatherLabel: 'Clear',
      );
      final b = WatchComplicationSnapshot(
        targetName: 'NGC 7000',
        framesCompleted: 12,
        framesTotal: 120,
        currentFilter: 'Ha',
        jobState: 'exposing',
        weatherSafe: true,
        weatherLabel: 'Clear',
      );
      final c = WatchComplicationSnapshot(
        targetName: 'NGC 7000',
        framesCompleted: 13, // changed
        framesTotal: 120,
        currentFilter: 'Ha',
        jobState: 'exposing',
        weatherSafe: true,
        weatherLabel: 'Clear',
      );
      expect(a, equals(b));
      expect(a == c, isFalse);
    });

    test('encode produces JSON the Swift decoder will accept', () {
      final snap = WatchComplicationSnapshot(
        targetName: 'NGC 7000',
        framesCompleted: 12,
        framesTotal: 120,
        currentFilter: 'Ha',
        jobState: 'exposing',
        weatherSafe: false,
        weatherLabel: 'Warning',
      );
      final json = snap.encode();
      // Round-trip via the same key names the Swift `SnapshotPayload`
      // expects. If anyone ever renames a field on either side, this
      // test fails loud.
      expect(json, contains('"targetName":"NGC 7000"'));
      expect(json, contains('"framesCompleted":12'));
      expect(json, contains('"framesTotal":120'));
      expect(json, contains('"currentFilter":"Ha"'));
      expect(json, contains('"jobState":"exposing"'));
      expect(json, contains('"weatherSafe":false'));
      expect(json, contains('"weatherLabel":"Warning"'));
    });
  });

  group('WatchComplicationLifecycleController throttle', () {
    test('many submit events produce at most one publish per 30 s', () async {
      // Stub the platform channel — we never want to actually call
      // into the iOS host from a test. Every successful publish gets
      // recorded so we can count.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel(WatchComplicationService.channelName);
      final publishCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        publishCalls.add(call);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
      });

      // Fake clock. Starts at epoch and advances when the test bumps
      // `fakeNow`. The controller's throttle is purely a function of
      // `now()` so this is enough.
      var fakeNow = DateTime.fromMillisecondsSinceEpoch(0);
      DateTime clock() => fakeNow;

      // Need a Ref to construct the controller — capture one from a
      // throwaway provider read against an empty container. The
      // controller never reads from this Ref in the test path because
      // we drive it via `submitSnapshotForTest`.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      late Ref capturedRef;
      final refCapture = Provider<int>((ref) {
        capturedRef = ref;
        return 0;
      });
      container.read(refCapture);

      final service = WatchComplicationService(
        channel: channel,
        platformIsIos: true,
      );
      final controller = WatchComplicationLifecycleController(
        capturedRef,
        service: service,
        now: clock,
        platformIsIos: true,
      );
      // Don't call start() — we want only the test-driven submits to
      // exercise the throttle, not any fireImmediately listener.

      // First submit is allowed (no prior publish wall-clock).
      controller.submitSnapshotForTest(
        WatchComplicationSnapshot(
          targetName: 'M31',
          framesCompleted: 1,
          framesTotal: 100,
          currentFilter: 'L',
          jobState: 'exposing',
          weatherSafe: true,
          weatherLabel: 'Clear',
        ),
      );
      // Allow microtasks to flush — the controller's _flush() awaits
      // the service.publish() future.
      await Future<void>.value();
      await Future<void>.value();
      expect(
        publishCalls.length,
        equals(1),
        reason: 'First submit should publish immediately',
      );

      // Now hammer the controller with 50 different snapshots within
      // the throttle window. The first one schedules a deferred
      // publish, all subsequent ones overwrite the pending snapshot
      // but do NOT add more publishes (verified by counting at the
      // end). The deferred publish is on a real Timer that won't
      // fire during the synchronous portion of the test.
      for (var i = 2; i <= 51; i++) {
        controller.submitSnapshotForTest(
          WatchComplicationSnapshot(
            targetName: 'M31',
            framesCompleted: i,
            framesTotal: 100,
            currentFilter: 'L',
            jobState: 'exposing',
            weatherSafe: true,
            weatherLabel: 'Clear',
          ),
        );
        await Future<void>.value();
      }
      expect(
        publishCalls.length,
        equals(1),
        reason:
            'No additional publishes within the 30s throttle window (got ${publishCalls.length})',
      );

      // Advance the fake clock past the throttle floor and submit
      // again. The controller's `_maybeFlush()` sees
      // `elapsed >= _minPublishInterval` and publishes synchronously.
      fakeNow = fakeNow.add(const Duration(seconds: 31));
      controller.submitSnapshotForTest(
        WatchComplicationSnapshot(
          targetName: 'M31',
          framesCompleted: 52,
          framesTotal: 100,
          currentFilter: 'L',
          jobState: 'exposing',
          weatherSafe: true,
          weatherLabel: 'Clear',
        ),
      );
      await Future<void>.value();
      await Future<void>.value();
      expect(
        publishCalls.length,
        equals(2),
        reason:
            'After 30s elapsed the next submit should produce exactly one more publish',
      );

      // Verify the latest payload reflects the most recent state
      // (frame 52, not any of the intermediates).
      final lastJson =
          (publishCalls.last.arguments as Map)['snapshotJson'] as String;
      expect(lastJson, contains('"framesCompleted":52'));

      // Identical snapshots resubmitted after the window should NOT
      // produce another publish thanks to the equality short-circuit.
      fakeNow = fakeNow.add(const Duration(seconds: 31));
      controller.submitSnapshotForTest(
        WatchComplicationSnapshot(
          targetName: 'M31',
          framesCompleted: 52,
          framesTotal: 100,
          currentFilter: 'L',
          jobState: 'exposing',
          weatherSafe: true,
          weatherLabel: 'Clear',
        ),
      );
      await Future<void>.value();
      expect(
        publishCalls.length,
        equals(2),
        reason:
            'Re-submitting the same snapshot must not trigger another publish',
      );

      await controller.dispose();
    });
  });
}
