import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/discover/mosaic/mosaic_project_controller.dart';
import 'package:skotiq_app/screens/discover/mosaic/mosaic_project_screen.dart';
import 'package:skotiq_app/screens/planner/targets/plan_targets_tab.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {
  _MockNetworkBackend() {
    // The tab's saved group is kept per linked host.
    when(() => scheme).thenReturn('https');
    when(() => serverHost).thenReturn('host.local');
    when(() => serverPort).thenReturn(8080);
    when(() => pinnedFingerprint).thenReturn(null);
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Override> remoteOverrides() => [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, _MockNetworkBackend()),
        ),
        // The tab around the mosaics reads nothing from the mocked host.
        planTargetsProvider.overrideWith((ref) => const AsyncValue.data([])),
        projectListProvider.overrideWith((ref) => Stream.value(const [])),
        unusedTargetsCountProvider.overrideWith((ref) async => 0),
        schedulerRemoteSnapshotProvider.overrideWith(
          (ref) => Completer<SchedulerRemoteSnapshot>().future,
        ),
        weekForecastProvider.overrideWith(
          (ref) => Completer<WeekForecast>().future,
        ),
        mosaicProjectsListProvider.overrideWith(
          (ref) => throw StateError(
            'The client-local mosaic project list must not load remotely',
          ),
        ),
        mosaicProjectsDaoProvider.overrideWith(
          (ref) => throw StateError(
            'The client-local mosaic project DAO must not load remotely',
          ),
        ),
      ];

  testWidgets('remote project list is guarded before the local list provider',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [inMemoryDatabaseOverride(), ...remoteOverrides()],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlanTargetsTab(initialGroup: 'mosaics')),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('Mosaics are on the imaging host'),
      findsOneWidget,
    );
    expect(find.text('Could not load the mosaics'), findsNothing);
  });

  testWidgets('remote project is guarded before its local DAO controller',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [inMemoryDatabaseOverride(), ...remoteOverrides()],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const MosaicProjectScreen(
            projectId: 42,
            artifactsBaseDir: '/client/mosaic',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('Open this mosaic project on the imaging host'),
      findsOneWidget,
    );
    expect(find.text('Mosaic project not found'), findsNothing);
  });
}
