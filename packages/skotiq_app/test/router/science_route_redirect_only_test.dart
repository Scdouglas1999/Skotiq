import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Every GoRoute in the tree, depth-first.
Iterable<GoRoute> _allRoutes(List<RouteBase> routes) sync* {
  for (final route in routes) {
    if (route is GoRoute) yield route;
    yield* _allRoutes(route.routes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('/science is redirect-only, so it declares no unreachable builder', () {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);
    final science = _allRoutes(router.configuration.routes)
        .firstWhere((r) => r.path == '/science');

    // go_router short-circuits a route whose redirect returns non-null, and
    // this redirect is unconditional. A builder here would be code that ships,
    // reads like a live screen, and can never appear — the trap this test
    // exists to keep out.
    expect(science.redirect, isNotNull);
    expect(
      science.builder,
      isNull,
      reason: '/science always redirects; a builder could never run',
    );
    expect(
      science.pageBuilder,
      isNull,
      reason: '/science always redirects; a pageBuilder could never run',
    );
  });
}
