import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'mirror_link.dart';

final _hostVerdict = WeatherSafetyState(
  status: WeatherSafetyStatus.unsafe,
  actions: const WeatherSafetyActions(
    shouldPause: true,
    shouldPark: true,
    reason: 'Rain sensor wet',
  ),
  currentAlertLevel: AlertLevel.values.last,
  hardwareWeatherSafe: false,
  autoParkArmed: true,
  lastEvaluation: DateTime.utc(2026, 11, 22, 3, 30),
);

void main() {
  test('a linked client fills the host verdict from the runtime state, '
      'before its own poll answers', () async {
    final client = mirrorClient(
      null,
      snapshot: () => [
        HostRuntimeUpdate(
          channel: 'weatherSafety',
          revision: 1,
          value: _hostVerdict.toJson(),
        ),
      ],
    );
    final poll = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!poll.isCompleted) poll.complete(_hostVerdict.toJson());
    });
    when(() => client.backend.isAuthTokenRejected).thenReturn(false);
    when(() => client.backend.getSafetyStatus()).thenAnswer((_) => poll.future);
    expect(
      client.container.read(weatherSafetyProvider).status,
      WeatherSafetyStatus.unsafe,
    );
    expect(
      client.container.read(weatherSafetyProvider).autoParkArmed,
      isFalse,
      reason: 'the client starts from the unevaluated verdict',
    );

    await hydrateHostRuntimeState(client.container, client.backend);

    final shown = client.container.read(weatherSafetyProvider);
    expect(shown.toJson(), _hostVerdict.toJson());
    expect(shown.hostVerdictUnavailable, isFalse);
  });

  test('a reconnect shows the host verdict again after a failed poll marked '
      'it unavailable', () async {
    final client = mirrorClient(
      null,
      snapshot: () => [
        HostRuntimeUpdate(
          channel: 'weatherSafety',
          revision: 1,
          value: _hostVerdict.toJson(),
        ),
      ],
    );
    final poll = Completer<Map<String, dynamic>>();
    when(() => client.backend.isAuthTokenRejected).thenReturn(false);
    when(() => client.backend.getSafetyStatus()).thenAnswer((_) => poll.future);
    client.container.read(weatherSafetyProvider);
    await hydrateHostRuntimeState(client.container, client.backend);

    poll.completeError(StateError('host unreachable'));
    await Future<void>.delayed(Duration.zero);
    expect(
      client.container.read(weatherSafetyProvider).hostVerdictUnavailable,
      isTrue,
    );

    await hydrateHostRuntimeState(client.container, client.backend);

    final shown = client.container.read(weatherSafetyProvider);
    expect(shown.hostVerdictUnavailable, isFalse);
    expect(shown.toJson(), _hostVerdict.toJson());
  });

  test('the host keeps its own verdict', () {
    final host = mirrorHost();
    final before = host.container.read(weatherSafetyProvider);
    host.container
        .read(weatherSafetyProvider.notifier)
        .applyHostVerdict(_hostVerdict);
    expect(host.container.read(weatherSafetyProvider), same(before));
  });
}
