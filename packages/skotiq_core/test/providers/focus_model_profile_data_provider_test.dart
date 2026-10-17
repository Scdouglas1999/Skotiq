import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('combines remote focus history and fitted model responses', () {
    final profile = parseRemoteFocusProfileData(
      {
        'profileId': '42',
        'count': 1,
        'referenceFilter': 'L',
        'dataPoints': [
          {
            'timestamp': '2026-07-13T01:02:03.000Z',
            'temperature': 7.5,
            'position': 12040,
            'hfr': 2.15,
            'filter': 'L',
          },
        ],
      },
      {
        'profileId': '42',
        'hasModel': true,
        'model': {
          'slope': -34.5,
          'intercept': 12300.0,
          'rSquared': 0.92,
          'dataPointCount': 8,
          'lastUpdated': '2026-07-13T01:02:03.000Z',
        },
      },
    );

    expect(profile.profileId, '42');
    expect(profile.referenceFilter, 'L');
    expect(profile.dataPoints, hasLength(1));
    expect(profile.dataPoints.single.focusPosition, 12040);
    expect(profile.temperatureModel?.slope, -34.5);
    expect(profile.temperatureModel?.isReliable, isTrue);
  });

  test('preserves history when the host has not fitted a model yet', () {
    final profile = parseRemoteFocusProfileData(
      {
        'profileId': '7',
        'dataPoints': [
          {
            'timestamp': '2026-07-13T01:02:03.000Z',
            'temperature': 7.5,
            'position': 12040,
            'hfr': 2.15,
            'filter': null,
          },
        ],
      },
      {'profileId': '7', 'hasModel': false, 'dataPointCount': 1},
    );

    expect(profile.dataPoints, hasLength(1));
    expect(profile.temperatureModel, isNull);
  });

  test(
    'local profile data waits for disk hydration before publishing',
    () async {
      final service = _DelayedFocusModelService();
      final container = ProviderContainer(
        overrides: [
          focusModelServiceProvider.overrideWithValue(service),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, DisconnectedBackend()),
          ),
        ],
      );
      addTearDown(container.dispose);

      var completed = false;
      final result = container.read(focusProfileDataProvider('7').future);
      unawaited(result.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);

      expect(service.initializeCalls, 1);
      expect(completed, isFalse);

      service.finishHydration();
      final profile = await result;

      expect(profile?.profileId, '7');
      expect(profile?.dataPoints.single.focusPosition, 12345);
    },
  );
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _DelayedFocusModelService extends FocusModelService {
  final Completer<void> _hydrated = Completer<void>();
  int initializeCalls = 0;
  bool _ready = false;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    await _hydrated.future;
    _ready = true;
  }

  void finishHydration() => _hydrated.complete();

  @override
  ProfileFocusData? getProfileData(String profileId) {
    if (!_ready) return null;
    return ProfileFocusData(
      profileId: profileId,
      dataPoints: [
        FocusHistoryPoint(
          timestamp: DateTime.utc(2026, 7, 15),
          temperatureCelsius: 5,
          focusPosition: 12345,
          hfr: 1.8,
        ),
      ],
    );
  }
}
