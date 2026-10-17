// The Darkroom's place in the shell: a real route inside the ShellRoute, a
// screen the notification filter can name, and deliberately no rail slot.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/screens/shell/shell_navigation.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('/darkroom is a named route', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final router = container.read(appRouterProvider);
    expect(
      router.namedLocation(
        'darkroom',
        queryParameters: const {'recipe': '12'},
      ),
      '/darkroom?recipe=12',
    );
  });

  test('the rail lights the Darkroom while the Darkroom is up', () {
    // The Darkroom became a rail destination in the Observatory shell (04
    // §3.2), under Review. It was route-only before, when a rail slot would
    // have led to a screen with nothing to open.
    final darkroom = ShellNavigation.primaryRoutes.indexOf('/darkroom');
    expect(darkroom, isNonNegative);
    expect(ShellNavigation.primaryIndexForLocation('/darkroom'), darkroom);
    expect(
      ShellNavigation.primaryIndexForLocation('/darkroom?recipe=12'),
      darkroom,
    );
    // On phone it reaches the operator through the More sheet, not a slot.
    expect(ShellNavigation.isBottomNavRoute('/darkroom'), isFalse);
  });

  test('the screen tracker names the Darkroom', () {
    // Without the arm this reads as `unknown`, and the smart notification
    // filter would pop "your draft is ready" over the screen showing it.
    expect(locationToAppScreen('/darkroom'), AppScreen.darkroom);
    expect(locationToAppScreen('/darkroom?master=3'), AppScreen.darkroom);
  });
}
