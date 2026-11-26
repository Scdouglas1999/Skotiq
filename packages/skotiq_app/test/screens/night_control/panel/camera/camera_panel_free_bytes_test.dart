import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/before_you_start_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_stats_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_panel_vm.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../../../harness/mock_backend.dart';
import '../../../../harness/mock_database.dart';
import '../../../../harness/pump_app_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<int?> freeBytes({int? live, required int projected}) async {
    final database = mockDatabase();
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend()),
        ),
        databaseProvider.overrideWithValue(database),
        nightRunPhaseProvider.overrideWithValue(NightRunPhase.notSetUp),
        nightCaptureFreeBytesProvider.overrideWithValue(live),
        captureFolderMissingProvider.overrideWithValue(false),
        nightDiskProjectionProvider.overrideWithValue(
          DiskSpaceProjection(
            freeBytes: projected,
            totalBytes: projected * 2,
            projectedBytes: 100,
            severity: DiskSpaceSeverity.info,
            headline: 'ok',
            detail: 'ok',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(database.close);
    return container.read(nightCameraPanelProvider).diskFreeBytes;
  }

  test('the camera panel prefers a live free-space sample', () async {
    expect(await freeBytes(live: 500, projected: 1000), 500);
  });

  test('a missing live sample falls through to the projection', () async {
    expect(await freeBytes(live: null, projected: 1000), 1000);
  });
}
