import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/catalog_setup_dialog.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

class _MockCatalogManager extends Mock implements CatalogManager {}

void main() {
  setUpAll(() {
    registerFallbackValue(CatalogPackage.standard);
  });

  testWidgets('disposed catalog setup does not launch the next download',
      (tester) async {
    final manager = _MockCatalogManager();
    final starDownload = Completer<bool>();
    when(
      () => manager.downloadStarCatalog(
        package: any(named: 'package'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((_) => starDownload.future);

    await pumpAppScreen(
      tester,
      const CatalogSetupDialog(),
      size: const Size(390, 650),
      extraOverrides: [
        catalogSetupManagerProvider.overrideWithValue(manager),
      ],
    );

    final downloadButton =
        find.widgetWithText(SkotiqButton, 'Download Now');
    await tester.ensureVisible(downloadButton);
    await tester.tap(downloadButton);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    starDownload.complete(true);
    await tester.pump();

    verifyNever(
      () => manager.downloadDsoCatalog(
        package: any(named: 'package'),
        onProgress: any(named: 'onProgress'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed catalog download remains visible and retryable',
      (tester) async {
    final manager = _MockCatalogManager();
    var dsoAttempts = 0;
    var completed = 0;
    when(
      () => manager.downloadStarCatalog(
        package: any(named: 'package'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((_) async => true);
    when(
      () => manager.downloadDsoCatalog(
        package: any(named: 'package'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((_) async => ++dsoAttempts > 1);

    await pumpAppScreen(
      tester,
      CatalogSetupDialog(onComplete: () => completed++),
      extraOverrides: [
        catalogSetupManagerProvider.overrideWithValue(manager),
      ],
    );

    var downloadButton = find.widgetWithText(SkotiqButton, 'Download Now');
    await tester.ensureVisible(downloadButton);
    await tester.tap(downloadButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('DSO catalog download failed'), findsOneWidget);
    expect(completed, 0);

    downloadButton = find.widgetWithText(SkotiqButton, 'Download Now');
    await tester.ensureVisible(downloadButton);
    await tester.tap(downloadButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(dsoAttempts, 2);
    expect(completed, 1);
    // The one dataset an install delivers. There is no tier to pick — see
    // [CatalogPackage] — so every download is the same, full package.
    verify(
      () => manager.downloadStarCatalog(
        package: CatalogPackage.complete,
        onProgress: any(named: 'onProgress'),
      ),
    ).called(1);
  });

  testWidgets(
      'the dialog advertises the one dataset it installs, with no tier to pick',
      (tester) async {
    // The dialog used to offer Essential (~9,000 stars, mag ≤ 6.5), Standard
    // (~40,000, mag ≤ 8.0) and Complete (~120,000) above the download button.
    // Live, on the release bundle, Essential and Standard fetched byte-identical
    // files (same SHA-256, 119,614 HYG rows) — there is one HYG asset and one
    // OpenNGC asset behind the download whichever name is clicked. The tiers
    // are gone; what the dialog says must be what arrives.
    await pumpAppScreen(
      tester,
      const CatalogSetupDialog(),
      size: const Size(900, 1200),
      extraOverrides: [
        catalogSetupManagerProvider.overrideWithValue(_MockCatalogManager()),
      ],
    );

    // The figures of the installed dataset, stated once, with HYG's real
    // completeness rather than an invented per-tier depth.
    expect(
      find.text(
        '~${formatCatalogCount(kInstalledStarApproxCount)} stars, '
        'complete to mag ${kHygFaintFloorMag.toStringAsFixed(1)}',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
          '~${formatCatalogCount(kInstalledDsoApproxCount)} DSOs (NGC/IC)'),
      findsOneWidget,
    );
    expect(
      find.text('About $kInstalledCatalogApproxSizeMB MB on disk.'),
      findsOneWidget,
    );

    // No selector, no fictitious tiers, no figures the bytes do not back.
    expect(find.text('Select package size:'), findsNothing);
    for (final package in CatalogPackage.values) {
      expect(find.text(package.displayName), findsNothing,
          reason: '${package.displayName} must not be offered as a choice');
    }
    expect(find.text('~40,000 stars'), findsNothing);
    expect(find.text('~9,000 stars'), findsNothing);
    expect(find.textContaining('mag ≤ 6.5'), findsNothing);
    expect(find.textContaining('mag ≤ 8.0'), findsNothing);
  });
}
