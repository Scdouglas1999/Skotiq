import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/collaborative_sky/collab_mosaic_detail_screen.dart';
import 'package:skotiq_app/screens/collaborative_sky/collaborative_sky_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('remote client never joins into a client-local mosaic project',
      (tester) async {
    const mosaic = CollabMosaic(
      mosaicId: 'mos-remote',
      ownerAccountId: 'owner',
      ownerDisplayName: 'Ada',
      name: 'Remote Veil',
      rows: 1,
      cols: 2,
      overlapPct: 10,
      positionAngleDeg: 0,
      centerRaDeg: 311,
      centerDecDeg: 30,
      status: 'open',
      outputPresent: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, _MockNetworkBackend()),
          ),
          collaborativeMosaicDetailProvider('mos-remote').overrideWith(
            (ref) async => mosaic,
          ),
          collaborativeMosaicAttributionProvider('mos-remote').overrideWith(
            (ref) async => const ArtifactAttribution(
              artifactType: 'mosaic',
              artifactRef: 'mos-remote',
            ),
          ),
          collaborativeMosaicServiceProvider.overrideWith(
            (ref) => throw StateError(
              'The client-local collaborative mosaic service must not join',
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const CollabMosaicDetailScreen(
            mosaicId: 'mos-remote',
            mosaicName: 'Remote Veil',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Join from imaging host'), findsOneWidget);
    expect(find.text('Join mosaic'), findsNothing);
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Join from imaging host'),
          )
          .onPressed,
      isNull,
    );
  });
}
