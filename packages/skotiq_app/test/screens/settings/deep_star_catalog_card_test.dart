import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/gated_action.dart';
import 'package:skotiq_app/screens/settings/widgets/deep_star_catalog_card.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _manifest = DeepStarManifest(
  name: 'Test tier',
  source: 'widget test',
  magnitudeFloor: 11.5,
  magnitudeLimit: 13,
  tiles: [
    DeepStarManifestTile(
      raBand: 1,
      decBand: 2,
      file: 'tile.skdt',
      sizeBytes: 100,
      sha256: 'abc',
      starCount: 7,
    ),
  ],
);

class _FakeManager extends DeepStarCatalogManager {
  _FakeManager({this.currentStatus = const DeepStarStatus()})
      : super(directory: '/unused/deep-star-widget-test');

  String baseUrl = 'https://catalog.example/deep-stars';
  DeepStarStatus currentStatus;
  Object? statusError;
  Object? verifyError;
  Object? deleteError;
  int deleteCalls = 0;

  @override
  Future<String> getBaseUrl() async => baseUrl;

  @override
  Future<DeepStarStatus> status() async {
    if (statusError case final error?) throw error;
    return currentStatus;
  }

  @override
  Future<DeepStarVerifyResult> verify() async {
    if (verifyError case final error?) throw error;
    return const DeepStarVerifyResult(
      tilesChecked: 1,
      missing: [],
      corrupt: [],
    );
  }

  @override
  Future<void> delete() async {
    deleteCalls++;
    if (deleteError case final error?) throw error;
    currentStatus = const DeepStarStatus();
  }
}

Future<HarnessHandle> _pumpCard(
  WidgetTester tester,
  _FakeManager manager,
) async {
  final handle = await pumpAppScreen(
    tester,
    const DeepStarCatalogCard(),
    size: const Size(1000, 800),
    settle: false,
    extraOverrides: [
      deepStarCatalogManagerProvider.overrideWithValue(manager),
    ],
  );
  await tester.pump();
  await tester.pump();
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('status failure is recoverable instead of spinning forever',
      (tester) async {
    final manager = _FakeManager()..statusError = StateError('disk offline');
    await _pumpCard(tester, manager);

    expect(find.text('Deep-star catalog unavailable'), findsOneWidget);
    expect(find.textContaining('disk offline'), findsOneWidget);
    expect(find.byType(SkotiqMark), findsNothing);

    manager.statusError = null;
    await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Deep-star catalog unavailable'), findsNothing);
    expect(find.widgetWithText(SkotiqButton, 'Download'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // With an empty tileset URL, "Download" must not look like every other
  // enabled button and then do nothing at all when pressed — no snackbar, no
  // validation, no log line.
  testWidgets('Download is unavailable, with a reason, while the URL is empty',
      (tester) async {
    final manager = _FakeManager()..baseUrl = '';
    await _pumpCard(tester, manager);

    final download = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Download'),
    );
    expect(download.onPressed, isNull);
    expect(find.textContaining('point this at a tileset you host'),
        findsOneWidget);
  });

  // The widget-level assertion above is not enough: the same control reads out
  // of the running app's accessibility tree as a plain `button: Download` with
  // no `[DISABLED]` and a click that does nothing. The SEMANTICS level is where
  // that shows, because that is what a tree dump reads, so pin the announced
  // name and the enabled flags.
  testWidgets('the blocked Download announces the reason to AT',
      (tester) async {
    final handle = tester.ensureSemantics();
    final manager = _FakeManager()..baseUrl = '';
    await _pumpCard(tester, manager);

    final node = tester.getSemantics(find.byType(GatedAction));
    expect(node.label, contains('Download'));
    expect(node.label, contains('unavailable: no tileset URL is set'));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(
      node.hasFlag(SemanticsFlag.hasEnabledState),
      isTrue,
      reason: 'AT-SPI derives insensitive from the enabled flags; without '
          'hasEnabledState the control announces as live',
    );
    expect(node.hasFlag(SemanticsFlag.isEnabled), isFalse);
    handle.dispose();
  });

  testWidgets('a usable Download announces nothing extra', (tester) async {
    final handle = tester.ensureSemantics();
    final manager = _FakeManager()..baseUrl = 'https://host/tiles';
    await _pumpCard(tester, manager);

    expect(find.byType(GatedAction), findsOneWidget);
    final node = tester.getSemantics(
      find.widgetWithText(SkotiqButton, 'Download'),
    );
    expect(node.label, isNot(contains('unavailable')));
    expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
    handle.dispose();
  });

  testWidgets('verification failure is visible and unlocks the action',
      (tester) async {
    final manager = _FakeManager(
      currentStatus: const DeepStarStatus(
        manifest: _manifest,
        tilesPresent: 1,
        bytesPresent: 100,
      ),
    )..verifyError = StateError('read failed');
    await _pumpCard(tester, manager);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Verify'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Verification failed'), findsOneWidget);
    expect(find.textContaining('read failed'), findsOneWidget);
    final verify = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Verify'),
    );
    expect(verify.onPressed, isNotNull);
    expect(verify.isLoading, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('partial download remains resumable and deletable',
      (tester) async {
    final manager = _FakeManager(
      currentStatus: const DeepStarStatus(hasLocalFiles: true),
    );
    await _pumpCard(tester, manager);

    expect(find.text('Partial'), findsOneWidget);
    expect(find.textContaining('partial or unreadable'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Re-download / Resume'),
      findsOneWidget,
    );
    expect(find.widgetWithText(SkotiqButton, 'Verify'), findsNothing);
    expect(find.widgetWithText(SkotiqButton, 'Delete'), findsOneWidget);
  });

  testWidgets('incomplete deletion does not claim success or hide the layer',
      (tester) async {
    final manager = _FakeManager(
      currentStatus: const DeepStarStatus(
        manifest: _manifest,
        tilesPresent: 1,
        bytesPresent: 100,
      ),
    )..deleteError = StateError('tile is locked');
    final handle = await _pumpCard(tester, manager);
    handle.container.read(showDeepStarsProvider.notifier).state = true;
    final refreshBefore =
        handle.container.read(deepStarManifestRefreshProvider);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete').last);
    await tester.pump();
    await tester.pump();

    expect(manager.deleteCalls, 1);
    expect(find.textContaining('Deletion incomplete'), findsOneWidget);
    expect(find.textContaining('tile is locked'), findsOneWidget);
    expect(find.text('Deep-star tiles deleted'), findsNothing);
    expect(handle.container.read(showDeepStarsProvider), isTrue);
    expect(
      handle.container.read(deepStarManifestRefreshProvider),
      refreshBefore + 1,
    );
    final delete = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Delete'),
    );
    expect(delete.onPressed, isNotNull);
    expect(delete.isLoading, isFalse);
    expect(tester.takeException(), isNull);
  });
}
