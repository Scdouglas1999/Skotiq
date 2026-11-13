// The Darkroom's place in the shell: a real route inside the ShellRoute, a
// screen the notification filter can name, and a rail slot under Review.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/screens/shell/shell_navigation.dart';
import 'package:skotiq_core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('/darkroom is a route inside the shell', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final router = container.read(appRouterProvider);
    final shell = router.configuration.routes.whereType<ShellRoute>().single;
    expect(
      shell.routes.whereType<GoRoute>().map((r) => r.path),
      contains(AppRoute.darkroom.path),
    );
  });

  test('the rail lights the Darkroom while the Darkroom is up', () {
    // The Darkroom became a rail destination in the Observatory shell (04
    // §3.2), under Review. It was route-only before, when a rail slot would
    // have led to a screen with nothing to open.
    final darkroom = ShellNavigation.rail.indexOf(AppRoute.darkroom);
    expect(darkroom, isNonNegative);
    expect(ShellNavigation.railIndexFor('/darkroom'), darkroom);
    expect(ShellNavigation.railIndexFor('/darkroom?recipe=12'), darkroom);
    // On phone it reaches the operator through the More sheet, not a slot.
    expect(ShellNavigation.phoneBar, isNot(contains(AppRoute.darkroom)));
  });

  test('the screen tracker names the Darkroom', () {
    // Without the arm this reads as `unknown`, and the smart notification
    // filter would pop "your draft is ready" over the screen showing it.
    expect(AppRoute.of('/darkroom')?.screen, AppScreen.darkroom);
    expect(AppRoute.of('/darkroom?master=3')?.screen, AppScreen.darkroom);
  });
}
