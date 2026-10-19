// The guider's pixel scale (arcsec/px) reaches GuiderState from PHD2's own
// answer, so the guide chart can label arcseconds, and is null whenever the
// guider has no scale to give.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

SkotiqEvent _guidingEvent(String eventType) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.guiding,
  eventType: eventType,
  data: const {},
);

Phd2Status _status({required bool connected, double? pixelScale}) => Phd2Status(
  state: connected ? 'Guiding' : 'Disconnected',
  connected: connected,
  pixelScale: pixelScale,
);

void main() {
  late StreamController<SkotiqEvent> events;
  late _MockBackend backend;
  late ProviderContainer container;

  setUp(() {
    events = StreamController<SkotiqEvent>.broadcast();
    backend = _MockBackend();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        loggingServiceProvider.overrideWithValue(LoggingService()),
      ],
    );
    container.read(phd2ControllerProvider);
  });

  tearDown(() async {
    container.dispose();
    await events.close();
  });

  Future<void> deliver(String eventType) async {
    events.add(_guidingEvent(eventType));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  double? scale() =>
      container.read(guiderStateProvider).pixelScaleArcsecPerPixel;

  test('the scale PHD2 reports is read when the link comes up', () async {
    when(
      () => backend.phd2GetStatus(),
    ).thenAnswer((_) async => _status(connected: true, pixelScale: 1.25));

    await deliver('Connected');

    expect(scale(), 1.25);
  });

  test('a calibration or guiding start re-reads it', () async {
    when(
      () => backend.phd2GetStatus(),
    ).thenAnswer((_) async => _status(connected: true, pixelScale: 1.25));
    await deliver('Connected');

    // The operator changed the guide scope in PHD2's profile.
    when(
      () => backend.phd2GetStatus(),
    ).thenAnswer((_) async => _status(connected: true, pixelScale: 3.1));
    await deliver('CalibrationComplete');
    expect(scale(), 3.1);

    when(
      () => backend.phd2GetStatus(),
    ).thenAnswer((_) async => _status(connected: true));
    await deliver('GuidingStarted');
    expect(scale(), isNull, reason: 'no scale in the profile is unknown');
  });

  test('a failed read leaves the scale unknown, never 0', () async {
    when(() => backend.phd2GetStatus()).thenThrow(StateError('rpc failed'));

    await deliver('Connected');

    expect(scale(), isNull);
  });

  test('a disconnect forgets the scale', () async {
    when(
      () => backend.phd2GetStatus(),
    ).thenAnswer((_) async => _status(connected: true, pixelScale: 1.25));
    await deliver('Connected');
    expect(scale(), 1.25);

    container.read(guiderStateProvider.notifier).setDisconnected();

    expect(scale(), isNull);
  });

  test('setPixelScale treats zero and non-finite values as unknown', () {
    final notifier = container.read(guiderStateProvider.notifier);
    notifier.setPixelScale(2.0);
    expect(scale(), 2.0);
    notifier.setPixelScale(0);
    expect(scale(), isNull);
    notifier.setPixelScale(2.0);
    notifier.setPixelScale(double.nan);
    expect(scale(), isNull);
  });

  test('Phd2Status carries the scale over the network as null or positive', () {
    expect(
      Phd2Status.fromJson({
        'state': 'Guiding',
        'connected': true,
        'pixelScale': 1.5,
      }).pixelScale,
      1.5,
    );
    for (final value in [null, 0, -1]) {
      expect(
        Phd2Status.fromJson({
          'state': 'Guiding',
          'connected': true,
          'pixelScale': value,
        }).pixelScale,
        isNull,
      );
    }
    final roundTrip = Phd2Status.fromJson(
      _status(connected: true, pixelScale: 2.2).toJson(),
    );
    expect(roundTrip.pixelScale, 2.2);
  });
}
