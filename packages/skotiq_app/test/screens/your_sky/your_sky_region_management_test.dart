import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/your_sky/your_sky_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Widget _surface(SkotiqBackend backend) {
  return ProviderScope(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      skyAtlasRegionsProvider.overrideWith(
        (ref) => Stream.value(const <SkyAtlasRegionRow>[]),
      ),
      skyAtlasCoverageProvider.overrideWith(
        (ref) => Stream.value(const <AtlasTileCoverage>[]),
      ),
    ],
    child: const MaterialApp(home: YourSkyScreen()),
  );
}

void main() {
  testWidgets('empty remote atlas offers the Name a region workflow', (
    tester,
  ) async {
    await tester.pumpWidget(_surface(_MockNetworkBackend()));
    await tester.pumpAndSettle();

    expect(find.text('Your sky is dark — for now'), findsOneWidget);
    expect(find.text('Name a region'), findsOneWidget);
  });

  testWidgets('disconnected client does not write a throwaway local region', (
    tester,
  ) async {
    await tester.pumpWidget(_surface(DisconnectedBackend()));
    await tester.pumpAndSettle();

    expect(find.text('Your sky is dark — for now'), findsOneWidget);
    expect(find.text('Name a region'), findsNothing);
  });
}
