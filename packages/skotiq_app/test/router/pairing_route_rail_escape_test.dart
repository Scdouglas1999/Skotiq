// Pairing is a part of Settings > Remote access, not a page of its own. The
// old `/pairing` address forwards there in the router, so a rail click from it
// is an ordinary move between two routed pages and nothing can sit above the
// shell's match list.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/router/settings_sections.dart';

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  late GoRouter router;
  setUp(() {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    router = container.read(appRouterProvider);
    addTearDown(router.dispose);
  });

  testWidgets('/pairing opens Settings on Remote access', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    final match = await router.configuration.redirect(
      context,
      router.configuration.findMatch(Uri.parse(AppRoute.pairing.path)),
      redirectHistory: [],
    );
    expect(match.isError, isFalse);
    expect(match.uri.path, AppRoute.settings.path);
    expect(SettingsSectionId.resolve(match.uri.queryParameters['section']),
        SettingsSectionId.remoteAccess);
  });

  test('/pairing only forwards: it draws no page of its own', () {
    expect(AppRoute.pairing.onlyRedirects, isTrue);
    expect(AppRoute.pairing.label, isNull,
        reason: 'the palette finds pairing through Remote access');
    final shell = router.configuration.routes.whereType<ShellRoute>().single;
    final pairing = shell.routes
        .whereType<GoRoute>()
        .singleWhere((route) => route.path == AppRoute.pairing.path);
    expect(pairing.builder, isNull);
    expect(pairing.pageBuilder, isNull);
  });
}
