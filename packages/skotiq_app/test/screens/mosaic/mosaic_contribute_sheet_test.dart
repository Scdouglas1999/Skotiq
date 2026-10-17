import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/constellation/constellation_ui_providers.dart'
    as ui;
import 'package:skotiq_app/screens/mosaic/mosaic_contribute_sheet.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('upload stays disabled until hub license capabilities resolve',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final info = Completer<HubInfo>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ui.constellationHubInfoProvider.overrideWith((ref) => info.future),
          mosaicUploadConsentProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showMosaicContributeSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('I understand this uploads'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Checking the hub'), findsOneWidget);
    expect(find.byType(SkotiqDropdown), findsNothing);
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Upload'),
          )
          .onPressed,
      isNull,
    );

    info.complete(const HubInfo(
      name: 'Hub',
      fingerprint: 'fp',
      version: '6',
      healpixOrder: 9,
      tilePixels: 512,
      selfHosted: true,
      supportedLicenses: ['cc-by'],
    ));
    await tester.pumpAndSettle();

    expect(find.byType(SkotiqDropdown), findsOneWidget);
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Upload'),
          )
          .onPressed,
      isNotNull,
    );
  });
}
