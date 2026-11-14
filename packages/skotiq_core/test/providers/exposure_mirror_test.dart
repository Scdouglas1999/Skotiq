import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import '../harness/in_memory_database.dart';

/// The host follows its camera's imaging events only for an exposure it did
/// not start ([applyHostLocalSyncEvent]); a linked client shows the host's
/// exposure from the exposure channel (exposure_channel_test.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SkotiqEvent imagingEvent(String type, Map<String, dynamic> data) =>
      SkotiqEvent(
        timestamp: 0,
        severity: EventSeverity.info,
        category: EventCategory.imaging,
        eventType: type,
        data: data,
      );

  test(
    'exposure events are IGNORED on the host path (no network backend)',
    () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      applyHostLocalSyncEvent(
        container,
        imagingEvent('ExposureProgress', {
          'progress': 0.5,
          'remainingSecs': 30.0,
        }),
      );

      expect(container.read(cameraStateProvider).isExposing, isFalse);
    },
  );
}
