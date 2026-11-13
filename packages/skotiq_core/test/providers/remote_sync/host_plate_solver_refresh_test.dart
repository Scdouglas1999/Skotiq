// A plate solver set up on the host while a client is linked shows on the
// client with the next re-read of the host (on reconnect and every 30 s).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

void main() {
  test('the host plate solver is read again with the host re-read', () async {
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

    rereadStoredHostData(container);
    await container.read(plateSolverDetectionProvider.future);
    expect(detections, 2);
  });
}
