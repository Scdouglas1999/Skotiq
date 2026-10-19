// Shared setup for the night-control session data tests: a container over a
// seeded in-memory database and a mock backend, plus fixed device states.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;
import 'package:skotiq_core/src/database/database.dart' as drift_db;

import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';

import '../../../../harness/mock_backend.dart';
import '../../../../harness/mock_database.dart';
import '../../../../harness/pump_app_screen.dart' show TestBackendNotifier;

/// The session every seeded frame belongs to.
const int kSessionId = 7;

/// 23:00 local on the night the tests image.
final DateTime kNight = DateTime(2026, 10, 19, 23);

class SessionHarness {
  SessionHarness._(this.container, this.db, this.backend);

  final ProviderContainer container;
  final SkotiqDatabase db;
  final MockBackend backend;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  /// Add a light frame [minutes] after [kNight].
  Future<int> addFrame({
    required int minutes,
    double? hfr,
    int? starCount,
    double? noise,
    bool accepted = true,
    String filter = 'Ha',
    String frameType = 'light',
    double? sensorTemp,
    double? focuserTemp,
    int? focuserPosition,
    String? path,
    double? solvedRa,
    double? solvedDec,
  }) async {
    final file = path ?? '/data/m74/frame_$minutes.fits';
    final id = await db.imagesDao.createImage(
      drift_db.CapturedImagesCompanion.insert(
        filePath: file,
        fileName: file.split('/').last,
        exposureDuration: 180,
        capturedAt: kNight.add(Duration(minutes: minutes)),
        sessionId: const Value(kSessionId),
        frameType: Value(frameType),
        filter: Value(filter),
        hfr: Value(hfr),
        starCount: Value(starCount),
        noise: Value(noise),
        isAccepted: Value(accepted),
        rejectionReason: Value(accepted ? null : 'HFR high'),
        sensorTemp: Value(sensorTemp),
        focuserTemp: Value(focuserTemp),
        focuserPosition: Value(focuserPosition),
        isPlateSolved: Value(solvedRa != null),
        solvedRa: Value(solvedRa),
        solvedDec: Value(solvedDec),
      ),
    );
    return id;
  }

  /// Let the Drift watch stream deliver, then return the provider's value.
  Future<T> settle<T>(ProviderListenable<T> provider) async {
    final sub = container.listen<T>(provider, (_, __) {});
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final value = container.read(provider);
    sub.close();
    return value;
  }
}

/// A container over a fresh in-memory database holding session [kSessionId].
Future<SessionHarness> sessionHarness({
  List<Override> overrides = const <Override>[],
  bool seedSession = true,
}) async {
  final db = mockDatabase();
  addTearDown(db.close);
  if (seedSession) {
    await db.into(db.imagingSessions).insert(
          drift_db.ImagingSessionsCompanion.insert(
            id: const Value(kSessionId),
            startTime: kNight,
          ),
        );
  }
  final backend = mockBackend();
  final container = ProviderContainer(
    overrides: <Override>[
      backendProvider.overrideWith((ref) => TestBackendNotifier(ref, backend)),
      databaseProvider.overrideWithValue(db),
      // The typed event stream would open the native bridge.
      skotiqEventsProvider
          .overrideWith((ref) => const Stream<sk_events.SkotiqEvent>.empty()),
      if (seedSession) nightSessionIdProvider.overrideWithValue(kSessionId),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return SessionHarness._(container, db, backend);
}

class FixedCamera extends CameraStateNotifier {
  FixedCamera(super.ref, CameraStateSnapshot value) {
    state = value;
  }
}

class FixedMount extends MountStateNotifier {
  FixedMount(super.ref, MountState value) {
    state = value;
  }
}

class FixedGuider extends GuiderStateNotifier {
  FixedGuider(super.ref, GuiderState value) {
    state = value;
  }
}

class FixedWeather extends WeatherStateNotifier {
  FixedWeather(super.ref, WeatherState value) {
    state = value;
  }
}

class FixedSettings extends AppSettingsNotifier {
  FixedSettings(this.value);

  final AppSettingsState value;

  @override
  Future<AppSettingsState> build() async => value;
}
