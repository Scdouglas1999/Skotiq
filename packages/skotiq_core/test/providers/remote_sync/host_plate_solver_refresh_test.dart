// reverify RV-01: a linked client kept the host's plate-solver state from when
// it connected; after the host set up ASTAP the client's pre-flight still said
// "No plate solver" until someone pressed Re-scan. Hydration (on reconnect and
// every 30 s) now reads it again.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('the host plate solver is read again on refresh', () async {
    var detections = 0;
    final container = ProviderContainer(
      overrides: [
        plateSolverDetectionProvider.overrideWith((ref) async {
          detections++;
          return const PlateSolverDetection();
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(plateSolverDetectionProvider, (_, __) {});
    await container.read(plateSolverDetectionProvider.future);
    expect(detections, 1);

    refreshHostPlateSolverState(container);
    await container.read(plateSolverDetectionProvider.future);
    expect(detections, 2);
  });
}
