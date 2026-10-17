import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/screens/sequencer/widgets/replay_debug_screen.dart';

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Every GoRoute in the tree, depth-first.
Iterable<GoRoute> _allRoutes(List<RouteBase> routes) sync* {
  for (final route in routes) {
    if (route is GoRoute) yield route;
    yield* _allRoutes(route.routes);
  }
}

/// A screen pushed with `Navigator.push` onto the shell's navigator sits ABOVE
/// the page go_router owns. Clicking a nav-rail destination then changes the
/// location under it — the rail repaints Analytics as selected, accent bar and
/// all, while the header still reads `Replay — New Sequence` — and the
/// top-right ✕ leaves it up.
///
/// Replay is therefore a route like every other page, so a `go()` from the rail
/// replaces it. This pins the two halves that make that true: the route exists
/// inside the shell, and the launcher targets it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('replay is a real route inside the shell, not an imperative push', () {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);
    final replay = _allRoutes(
      router.configuration.routes,
    ).firstWhere((r) => r.path == '/replay/:runId');

    expect(replay.pageBuilder, isNotNull);
    expect(replay.name, 'replay');

    // Inside the ShellRoute: a route pushed above the shell would keep the
    // rail's highlight and the page out of sync all over again.
    final shell = router.configuration.routes.whereType<ShellRoute>().single;
    expect(
      _allRoutes(shell.routes).any((r) => r.path == '/replay/:runId'),
      isTrue,
      reason: 'replay must share the shell navigator with every other page',
    );
  });

  test('the launcher location carries the run, label and scrub window', () {
    final location = ReplayDebugScreen.locationFor(
      sequenceRunId: 7,
      sequenceName: 'New Sequence',
      startedAt: DateTime.utc(2026, 8, 13, 20, 53, 44),
      endedAt: DateTime.utc(2026, 8, 13, 20, 54, 1),
    );

    final uri = Uri.parse(location);
    expect(uri.path, '/replay/7');
    expect(uri.queryParameters['name'], 'New Sequence');
    expect(
      DateTime.parse(uri.queryParameters['started']!).toUtc(),
      DateTime.utc(2026, 8, 13, 20, 53, 44),
    );
    expect(
      DateTime.parse(uri.queryParameters['ended']!).toUtc(),
      DateTime.utc(2026, 8, 13, 20, 54, 1),
    );
  });
}
