// Settings search declares the keywords 'license' and 'credits' for the About
// section (settings_catalog.dart), and typing either one collapses the section
// list to exactly one destination: About. About carried neither — a logo, a
// version, a tagline, three links and a System Information card, and nothing
// else. A search that routes a term to a single page which does not have it is
// the search asserting something the app cannot back up.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/about_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpAbout(
  WidgetTester tester, {
  required List<Uri> launched,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 2000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.1.0', buildNumber: 42),
        ),
        aboutLinkLauncherProvider.overrideWithValue((uri) async {
          launched.add(uri);
          return true;
        }),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: AboutSettings()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('About names the license the build ships under', (tester) async {
    await _pumpAbout(tester, launched: []);

    expect(find.text('License'), findsOneWidget);
    expect(
      find.textContaining(kSkotiqLicenseName),
      findsOneWidget,
      reason: 'searching "license" must land on a page that states one',
    );
    expect(find.textContaining(kSkotiqCopyright), findsOneWidget);
  });

  testWidgets('the license button opens this project\'s LICENSE file',
      (tester) async {
    final launched = <Uri>[];
    await _pumpAbout(tester, launched: launched);

    final button = find.widgetWithText(SkotiqButton, 'Read the license');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(launched.single.toString(), kSkotiqLicenseUrl);
    expect(kSkotiqLicenseUrl,
        startsWith('https://github.com/Scdouglas1999/Skotiq'));
  });

  testWidgets('About reaches the open-source credits', (tester) async {
    await _pumpAbout(tester, launched: []);

    final button =
        find.widgetWithText(SkotiqButton, 'Open-source licenses');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
    // The page is fed the build's real identity, not a placeholder.
    final page = tester.widget<LicensePage>(find.byType(LicensePage));
    expect(page.applicationName, 'Skotiq');
    expect(page.applicationVersion, 'Version 6.1.0 (build 42)');
  });

  testWidgets('the shipped build number is on the page', (tester) async {
    await _pumpAbout(tester, launched: []);

    expect(find.text('Version 6.1.0 (build 42)'), findsOneWidget);
  });
}
