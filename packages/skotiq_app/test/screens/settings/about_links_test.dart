// The About page's link strip is the one place in the app that hands the user
// off to a public address on the project's behalf. A wrong URL there — a 404
// GitHub org, a hostname under an undelegated TLD that DNS can never answer, a
// Discord invite belonging to an unrelated server — is invisible at runtime:
// url_launcher reports success for all of them, because a 404 page still opens.
//
// These tests tap the real buttons and assert the URI actually handed to the
// launcher, on both the phone (Wrap) and desktop (Row) layouts, because two
// hand-typed copies of the list can drift apart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/about_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpAbout(
  WidgetTester tester, {
  required bool isMobile,
  required List<Uri> launched,
  bool launcherSucceeds = true,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize =
      isMobile ? const Size(420, 1600) : const Size(1400, 1600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.1.0', buildNumber: 1),
        ),
        aboutLinkLauncherProvider.overrideWithValue((uri) async {
          launched.add(uri);
          return launcherSucceeds;
        }),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: AboutSettings(isMobile: isMobile)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('every About link points at a destination this project owns', () {
    expect(kAboutLinks, isNotEmpty);
    for (final link in kAboutLinks) {
      expect(
        link.url,
        startsWith('https://github.com/Scdouglas1999/Skotiq'),
        reason: '${link.label} points outside the project repository',
      );
    }
    // The Discord invite in the shipped build resolved to a stranger's server.
    // There is no project chat, so no button may claim one.
    expect(
      kAboutLinks.any((link) => link.url.contains('discord')),
      isFalse,
    );
  });

  testWidgets('desktop About buttons launch the real project URLs',
      (tester) async {
    final launched = <Uri>[];
    await _pumpAbout(tester, isMobile: false, launched: launched);

    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(launched.last, Uri.parse('https://github.com/Scdouglas1999/Skotiq'));

    await tester.tap(find.text('Documentation'));
    await tester.pumpAndSettle();
    expect(
      launched.last,
      Uri.parse(
          'https://github.com/Scdouglas1999/Skotiq/blob/main/docs/index.md'),
    );

    await tester.tap(find.text('Report an Issue'));
    await tester.pumpAndSettle();
    expect(launched.last,
        Uri.parse('https://github.com/Scdouglas1999/Skotiq/issues'));

    expect(launched, hasLength(3));
  });

  testWidgets('phone About buttons launch the same URLs as desktop',
      (tester) async {
    final launched = <Uri>[];
    await _pumpAbout(tester, isMobile: true, launched: launched);

    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Issues'));
    await tester.pumpAndSettle();

    // Asserted against literals, not against kAboutLinks: comparing the phone
    // layout to the same list it renders from would pass whatever the list
    // contained, which is exactly how six wrong URLs shipped.
    expect(launched.map((uri) => uri.toString()).toList(), [
      'https://github.com/Scdouglas1999/Skotiq',
      'https://github.com/Scdouglas1999/Skotiq/blob/main/docs/index.md',
      'https://github.com/Scdouglas1999/Skotiq/issues',
    ]);
  });

  testWidgets('a launcher that refuses the URL surfaces it to the user',
      (tester) async {
    final launched = <Uri>[];
    await _pumpAbout(
      tester,
      isMobile: false,
      launched: launched,
      launcherSucceeds: false,
    );

    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('https://github.com/Scdouglas1999/Skotiq'),
      findsOneWidget,
    );
  });
}
