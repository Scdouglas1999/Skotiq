// Native pause lets the step in flight finish, so a paused run is free to
// act on only once no exposure, download, slew or focuser move is left.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

void main() {
  final idle = ExposureProgress.idle();

  bool inFlight({
    ExposureProgress? exposure,
    bool camera = false,
    bool mount = false,
    bool focuser = false,
  }) => pausedStepInFlight(
    exposure: exposure ?? idle,
    cameraExposing: camera,
    mountSlewing: mount,
    focuserMoving: focuser,
  );

  test('each step a pause lets finish keeps the run from idle', () {
    expect(inFlight(), isFalse);
    expect(
      inFlight(
        exposure: const ExposureProgress(
          elapsed: 108,
          remaining: 12,
          percent: 90,
        ),
      ),
      isTrue,
    );
    expect(
      inFlight(
        exposure: const ExposureProgress(
          elapsed: 120,
          remaining: 0,
          percent: 100,
          isDownloading: true,
        ),
      ),
      isTrue,
    );
    expect(inFlight(camera: true), isTrue);
    expect(inFlight(mount: true), isTrue);
    expect(inFlight(focuser: true), isTrue);
  });

  test('a run that is not paused has no answer', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(pausedRunIdleProvider), isNull);
  });
}
