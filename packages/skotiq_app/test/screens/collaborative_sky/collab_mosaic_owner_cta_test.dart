// The mosaic you published is not something you "join".
//
// Opening a mosaic this rig owns showed a card headed "Image with this club"
// reading "Join this mosaic to mirror its panel grid into a local project" with
// a "Join mosaic" button — telling the owner to join their own project.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/collaborative_sky/collab_mosaic_detail_screen.dart';
import 'package:skotiq_app/screens/collaborative_sky/collaborative_sky_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A host-local backend: the CTA branch under test is only reachable when the
/// device can own a mosaic project (a NetworkBackend/DisconnectedBackend takes
/// the "join from the imaging host" / "connect to join" paths instead).
class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _mosaicId = 'mos-owned';

const _mosaic = CollabMosaic(
  mosaicId: _mosaicId,
  ownerAccountId: 'me',
  ownerDisplayName: 'AuditRig',
  name: 'Club Veil',
  rows: 2,
  cols: 3,
  overlapPct: 10,
  positionAngleDeg: 0,
  centerRaDeg: 311,
  centerDecDeg: 30,
  status: 'open',
  outputPresent: false,
);

MosaicProject _project(String? role) => MosaicProject(
      id: 9,
      name: 'Club Veil',
      rows: 2,
      cols: 3,
      overlapPct: 10,
      positionAngleDeg: 0,
      createdAt: DateTime(2026, 8, 1),
      updatedAt: DateTime(2026, 8, 1),
      hubMosaicId: _mosaicId,
      collabRole: role,
    );

Future<void> _pump(WidgetTester tester, MosaicProject? local) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, _MockLocalBackend()),
        ),
        collaborativeMosaicDetailProvider(_mosaicId)
            .overrideWith((ref) async => _mosaic),
        collaborativeMosaicAttributionProvider(_mosaicId).overrideWith(
          (ref) async => const ArtifactAttribution(
            artifactType: 'mosaic',
            artifactRef: _mosaicId,
          ),
        ),
        localMosaicProjectForHubProvider(_mosaicId)
            .overrideWith((ref) async => local),
      ],
      child: const MaterialApp(
        home: CollabMosaicDetailScreen(
          mosaicId: _mosaicId,
          mosaicName: 'Club Veil',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the owner is offered their own project, not a join',
      (tester) async {
    await _pump(tester, _project('owner'));

    expect(find.text('Join mosaic'), findsNothing);
    expect(find.text('Open the local project'), findsOneWidget);
    expect(find.text('Your mosaic'), findsOneWidget);
    expect(
      find.textContaining('Join this mosaic to mirror'),
      findsNothing,
      reason: 'the owner is not mirroring anything in',
    );
  });

  testWidgets('an already-joined participant is offered their project too',
      (tester) async {
    await _pump(tester, _project('participant'));

    expect(find.text('Join mosaic'), findsNothing);
    expect(find.text('Open the local project'), findsOneWidget);
    expect(find.textContaining("You've joined this mosaic"), findsOneWidget);
  });

  testWidgets("a stranger's mosaic still offers Join", (tester) async {
    await _pump(tester, null);

    expect(find.text('Join mosaic'), findsOneWidget);
    expect(find.text('Image with this club'), findsOneWidget);
  });
}
