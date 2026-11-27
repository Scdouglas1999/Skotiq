// A failed switch channel, PHD2 being started and an exposure whose
// completion never came are told through the notification router, on rows of
// their own: shown in the app as before by default, and silent when the
// operator turns their row off.
import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/errors/error_text.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/imaging_service_providers.dart';
import 'package:skotiq_core/src/providers/notification_router_provider.dart';
import 'package:skotiq_core/src/providers/ui_notification_provider.dart';
import 'package:skotiq_core/src/services/notification/notification_router.dart';
import 'package:skotiq_core/src/services/notification/transports/in_app_transport.dart';
import 'package:skotiq_core/src/services/notification/ui_notices.dart';
import 'package:skotiq_core/src/services/phd2_launcher.dart';
import 'package:skotiq_core/src/services/switch_channel_service.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

class _Shown {
  _Shown(this.kind, this.title, this.message, this.duration);
  final String kind;
  final String? title;
  final String message;
  final Duration? duration;

  @override
  String toString() => '$kind $title / $message ($duration)';
}

class _Notices implements UiNotices {
  final List<_Shown> shown = [];

  void _add(String kind, String message, String? title, Duration? duration) =>
      shown.add(_Shown(kind, title, message, duration));

  @override
  void showInfo(
    String message, {
    String? title,
    Duration? duration,
    String? deepLink,
  }) => _add('info', message, title, duration);

  @override
  void showSuccess(
    String message, {
    String? title,
    Duration? duration,
    String? deepLink,
  }) => _add('success', message, title, duration);

  @override
  void showWarning(
    String message, {
    String? title,
    Duration? duration,
    String? deepLink,
  }) => _add('warning', message, title, duration);

  @override
  void showError(
    String message, {
    String? title,
    Duration? duration,
    String? deepLink,
  }) => _add('error', message, title, duration);
}

NotificationRouter _router(UiNotices notices, {NotificationCategory? rowOff}) {
  final defaults = NotificationRoutingMatrix.defaults();
  return NotificationRouter(
    transports: [InAppTransport(notices)],
    matrix: rowOff == null
        ? defaults
        : defaults.copyWith(
            rules: {
              ...defaults.rules,
              rowOff: defaults.ruleFor(rowOff).copyWith(enabled: false),
            },
          ),
  );
}

/// The app's router, over the app's own notices.
Override _routerOver(NotificationCategory? rowOff) =>
    notificationRouterProvider.overrideWith(
      (ref) =>
          _router(ref.read(uiNotificationProvider.notifier), rowOff: rowOff),
    );

List<String> _shownIn(ProviderContainer container) => [
  for (final n in container.read(uiNotificationProvider))
    '${n.level.name} ${n.title} / ${n.message} (${n.duration})',
];

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackend extends BackendNotifier {
  _FixedBackend(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

Future<void> _settle() => pumpEventQueue();

void main() {
  setUpAll(() => registerFallbackValue(FrameType.light));

  group('a failed switch channel read', () {
    Future<List<String>> refreshFailing({NotificationCategory? rowOff}) async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.getSwitchStatus(deviceId: 'remote:switch:1'),
      ).thenThrow(Exception('relay box did not answer'));
      final service = Provider<SwitchChannelService>(
        (ref) => SwitchChannelService(
          ref: ref,
          backend: backend,
          hostDevices: backend,
          notices: () => ref.read(notificationRouterProvider),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
          _routerOver(rowOff),
        ],
      );
      addTearDown(container.dispose);
      container.read(switchStateProvider.notifier)
        ..setConnecting('remote:switch:1', 'Power Box')
        ..setConnected();

      await expectLater(
        container.read(service).refreshChannels(),
        throwsA(isA<Exception>()),
      );
      await _settle();
      return _shownIn(container);
    }

    test('is shown in the app as a switch warning', () async {
      final shown = await refreshFailing();
      final text = describeError(
        'Failed to refresh switch channels: '
        'Exception: relay box did not answer',
        domain: ErrorDomain.device,
      );
      expect(shown, [
        'warning Switch Warning / ${text.message} (0:00:06.000000)',
      ]);
    });

    test('is silent with its row off', () async {
      final shown = await refreshFailing(
        rowOff: NotificationCategory.switchChannelFailed,
      );
      expect(shown, isEmpty);
    });
  });

  group('starting PHD2', () {
    Future<_Notices> launch({NotificationCategory? rowOff}) async {
      final notices = _Notices();
      final router = _router(notices, rowOff: rowOff);
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final launcher = Phd2Launcher(
        notices: () => router,
        launchTimeout: const Duration(milliseconds: 300),
        pollInterval: const Duration(milliseconds: 50),
      );

      await expectLater(
        launcher.ensureRunning(
          executablePath: '/bin/true',
          host: '127.0.0.1',
          port: port,
        ),
        throwsA(isA<TimeoutException>()),
      );
      await _settle();
      return notices;
    }

    test(
      'is shown in the app for five seconds',
      () async {
        final notices = await launch();
        expect(notices.shown.map((n) => '$n'), [
          'info PHD2 / PHD2 not running: launching /bin/true... '
              '(0:00:05.000000)',
        ]);
      },
      skip: !File('/bin/true').existsSync(),
    );

    test('is silent with its row off', () async {
      final notices = await launch(rowOff: NotificationCategory.guiderStarting);
      expect(notices.shown, isEmpty);
    }, skip: !File('/bin/true').existsSync());
  });

  group('an exposure whose completion never came', () {
    List<String> timeOut({NotificationCategory? rowOff}) {
      var shown = <String>[];
      final backend = MockBackend();
      final events = StreamController<SkotiqEvent>.broadcast();
      final started = Completer<void>();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.getCameraCapabilities(any()),
      ).thenAnswer((_) async => null);
      when(
        () => backend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async => started.complete());
      when(() => backend.cameraAbortExposure(any())).thenAnswer((_) async {});
      when(
        () => backend.cameraGetLastImage(any()),
      ).thenThrow(Exception('no image'));

      fakeAsync((clock) {
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
            _routerOver(rowOff),
            cameraStateProvider.overrideWith((ref) {
              final notifier = CameraStateNotifier(ref);
              notifier.setConnecting('test-camera-1', 'Test Camera');
              notifier.setConnected();
              return notifier;
            }),
          ],
        );
        unawaited(
          container
              .read(imagingServiceProvider)
              .captureImage(
                settings: const ExposureSettings(
                  exposureTime: 1,
                  gain: 100,
                  offset: 10,
                ),
              )
              .then((_) {}, onError: (Object _) {}),
        );
        for (var i = 0; i < 50 && !started.isCompleted; i++) {
          clock.elapse(const Duration(milliseconds: 10));
        }
        expect(started.isCompleted, isTrue, reason: 'the exposure started');
        clock.elapse(const Duration(seconds: 32));
        clock.flushMicrotasks();
        shown = _shownIn(container);
        container.dispose();
        unawaited(events.close());
      });
      return shown;
    }

    test('is shown in the app as a warning', () {
      expect(timeOut(), [
        'warning Exposure Timeout / Exposure event not received in time - '
            'checking for image. Camera may be unresponsive. (0:00:06.000000)',
      ]);
    });

    test('is silent with its row off', () {
      expect(timeOut(rowOff: NotificationCategory.exposureTimedOut), isEmpty);
    });
  });
}
