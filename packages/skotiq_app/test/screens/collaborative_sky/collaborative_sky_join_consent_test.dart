// The co-imaging JOIN flow must never promise a co-add it will not deliver.
//
// A completed sub only folds into the combined stack when an UNATTENDED
// contribution consent is on record (the same MosaicUploadConsent the mosaic
// path persists) AND its auto-upload opt-in is enabled — the co-imaging
// auto-contribute egress is inherently unattended and fails closed otherwise.
// So joining:
//   * routes a user with no unattended consent to the consent sheet, and if
//     they decline, the success snackbar honestly says sharing is OFF;
//   * when unattended consent is already granted, skips the sheet and promises
//     the co-add.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/collaborative_sky_providers.dart';
import 'package:skotiq_app/screens/collaborative_sky/collaborative_sky_screen.dart';
import 'package:skotiq_app/screens/constellation/constellation_ui_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

/// A co-imaging service whose JOIN succeeds without a hub, so the widget test
/// exercises the screen's post-join consent routing in isolation.
class _FakeCoImagingService extends CoImagingSessionService {
  _FakeCoImagingService(CoImagingSessionsDao dao)
      : super(
          credentialsResolver: () async => null,
          sessionsDao: dao,
          logger: LoggingService(),
        );

  @override
  Future<CoImagingParticipant> joinSession(
    String sessionId, {
    String? rigId,
    String role = 'contribute',
    String? targetName,
    double? targetRaDeg,
    double? targetDecDeg,
  }) async {
    return const CoImagingParticipant(
      sessionId: 's1',
      accountId: null,
      displayName: null,
      rigId: 'me',
      role: 'contribute',
      membershipToken: 'mtok',
      framingOffsetIndex: 2,
      framingOffsetRaArcsec: 60.0,
      framingOffsetDecArcsec: 0.0,
      contributedFrames: 0,
      contributedIntegrationSeconds: 0.0,
      active: true,
    );
  }
}

void main() {
  const session = CoImagingSession(
    sessionId: 's1',
    ownerAccountId: 'owner',
    ownerDisplayName: 'Ada',
    targetName: 'NGC 7000',
    centerRaDeg: 314.7,
    centerDecDeg: 44.5,
    sharedTargetId: 42,
    status: 'active',
    combinedFrames: 240,
    combinedIntegrationSeconds: 7200,
    activeTileId: 99,
    batonHolder: 'owner',
    batonHolderDisplayName: 'Ada',
    participants: [],
  );

  late SkotiqDatabase db;
  late SettingsDao settings;

  setUp(() {
    db = mockDatabase();
    settings = SettingsDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Widget host() {
    return ProviderScope(
      overrides: [
        settingsDaoProvider.overrideWithValue(settings),
        coImagingSessionServiceProvider
            .overrideWithValue(_FakeCoImagingService(CoImagingSessionsDao(db))),
        constellationConfiguredProvider.overrideWith((ref) => true),
        constellationHubInfoProvider.overrideWith((ref) async => null),
        constellationDisplayNameProvider.overrideWith((ref) async => ''),
        coImagingSessionsProvider.overrideWith((ref) async => const [session]),
        coImagingMembershipsProvider.overrideWith((ref) async => const []),
        collaborativeMosaicsProvider.overrideWith((ref) async => const []),
        sharedLibrarySummaryProvider.overrideWith(
          (ref) async =>
              const SharedLibrarySummary(publishedCount: 0, pulledCount: 0),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: CollaborativeSkyView()),
      ),
    );
  }

  testWidgets(
    'joining with no unattended consent routes to the sheet and, if declined, '
    'says sharing is OFF',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Join session'));
      // The join button keeps a spinner while the sheet is open (join is
      // suspended awaiting the consent choice), so pump the modal open by hand
      // rather than pumpAndSettle (which would time out on the spinner).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // The co-imaging consent sheet is surfaced (co-imaging wording, not the
      // mosaic-panel wording).
      expect(find.text('Share your co-imaging subs'), findsOneWidget);

      // Decline it.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // The success snackbar says what actually happens: subs will NOT co-add
      // yet.
      expect(find.textContaining('Sharing is off'), findsOneWidget);
      expect(
        find.textContaining('your subs co-add into the combined stack'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'joining with unattended consent on record skips the sheet and promises '
    'the co-add',
    (tester) async {
      // Persist an unattended contribution consent (autoUpload enabled).
      await persistMosaicUploadConsent(
        settings,
        const MosaicUploadConsent(
          license: ContributionLicense.ccBy,
          attributionConsent: true,
          autoUpload: true,
        ),
      );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Join session'));
      await tester.pumpAndSettle();

      // No consent sheet — sharing is already enabled.
      expect(find.text('Share your co-imaging subs'), findsNothing);
      expect(
        find.textContaining('your subs co-add into the combined stack'),
        findsOneWidget,
      );
    },
  );
}
