import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/shell_navigation.dart';

void main() {
  group('ShellNavigation', () {
    test('the rail is ten destinations grouped Observe/Prepare/Review', () {
      // 04-shell §3.2. Order and grouping are the spec; the route paths do not
      // change. Settings is deliberately absent — it lives in the top bar.
      expect(ShellNavigation.primaryDestinations, hasLength(10));
      expect(ShellNavigation.primaryRoutes, [
        '/dashboard',
        '/imaging',
        '/sequencer',
        '/guiding',
        '/planner',
        '/equipment',
        '/flat-wizard',
        '/weather',
        '/darkroom',
        '/analytics',
      ]);
      expect(
        ShellNavigation.primaryDestinations.map((d) => d.group).toList(),
        [
          ShellNavGroup.observe,
          ShellNavGroup.observe,
          ShellNavGroup.observe,
          ShellNavGroup.observe,
          ShellNavGroup.prepare,
          ShellNavGroup.prepare,
          ShellNavGroup.prepare,
          ShellNavGroup.prepare,
          ShellNavGroup.review,
          ShellNavGroup.review,
        ],
      );
      // Groups are contiguous: a rail that interleaved them would render an
      // eyebrow twice for the same group.
      final seen = <ShellNavGroup>[];
      for (final dest in ShellNavigation.primaryDestinations) {
        if (seen.isEmpty || seen.last != dest.group) {
          expect(
            seen,
            isNot(contains(dest.group)),
            reason: '${dest.group} must appear as one contiguous run',
          );
          seen.add(dest.group);
        }
      }
    });

    test('bottomNavigationDestinations has four routed slots', () {
      // The fifth slot is "More", which the bar renders itself.
      expect(ShellNavigation.bottomNavigationDestinations, hasLength(4));
      final routes = ShellNavigation.bottomNavigationDestinations
          .map((d) => d.route)
          .toList();
      expect(routes, ['/dashboard', '/imaging', '/sequencer', '/guiding']);
      expect(routes, isNot(contains('/settings')));
    });

    test(
        'the More sheet lists every destination without a slot, plus '
        'Settings', () {
      expect(
        ShellNavigation.overflowDestinations.map((d) => d.route).toList(),
        [
          '/planner',
          '/equipment',
          '/flat-wizard',
          '/weather',
          '/darkroom',
          '/analytics',
          '/settings',
        ],
      );
    });

    test('primaryIndexForLocation resolves planner and ignores query', () {
      final planner = ShellNavigation.primaryRoutes.indexOf('/planner');
      expect(
        ShellNavigation.primaryIndexForLocation('/planner?tab=scheduler'),
        planner,
      );
      expect(ShellNavigation.primaryRouteForIndex(planner), '/planner');
    });

    // The alias table (04 §3.2) is consulted before the prefix walk, because a
    // prefix walk cannot answer these: /session-review shares no prefix with
    // /darkroom, and /settings shares one with nothing yet must light nothing.
    test('route-only screens light the rail item that owns them', () {
      final darkroom = ShellNavigation.primaryRoutes.indexOf('/darkroom');
      final equipment = ShellNavigation.primaryRoutes.indexOf('/equipment');
      final tonight = ShellNavigation.primaryRoutes.indexOf('/dashboard');
      for (final location in [
        '/session-review?session=3',
        '/stack-result?id=9',
        '/mosaic',
        '/mosaic/7',
      ]) {
        expect(
          ShellNavigation.primaryIndexForLocation(location),
          darkroom,
          reason: '$location is a Darkroom surface',
        );
      }
      expect(
        ShellNavigation.primaryIndexForLocation('/polar-alignment'),
        equipment,
      );
      expect(ShellNavigation.primaryIndexForLocation('/flat-wizard'),
          ShellNavigation.primaryRoutes.indexOf('/flat-wizard'));
      expect(ShellNavigation.primaryIndexForLocation('/tonight'), tonight);
    });

    // A lit rail item is the shell's strongest claim about where the operator
    // is. Defaulting an unmatched location to 0 lights Tonight for every route
    // no rail destination hosts, while showing something else entirely.
    test('non-rail routes select nothing rather than falling back', () {
      for (final location in [
        '/settings',
        '/settings/plate-solving',
        '/onboarding',
        '/pairing',
        '/replay/17',
        '/diagnostics',
        '/diagnostics/dump',
        '/tutorial/first-night',
      ]) {
        expect(
          ShellNavigation.primaryIndexForLocation(location),
          -1,
          reason: '$location must not highlight a rail destination',
        );
      }
    });

    test('a sub-route resolves to the destination that hosts it', () {
      // The image-ready notification deep link renders the Imaging screen.
      expect(
        ShellNavigation.primaryIndexForLocation('/imaging/preview/42'),
        ShellNavigation.primaryRoutes.indexOf('/imaging'),
      );
      expect(
        ShellNavigation.primaryIndexForLocation('/imaging/preview/42?x=1'),
        ShellNavigation.primaryRoutes.indexOf('/imaging'),
      );
    });

    test('locationIsUnder matches on segment boundaries only', () {
      expect(ShellNavigation.locationIsUnder('/planner', '/planner'), isTrue);
      expect(
        ShellNavigation.locationIsUnder('/planner?tab=discover', '/planner'),
        isTrue,
      );
      expect(
        ShellNavigation.locationIsUnder('/planner/queue', '/planner'),
        isTrue,
      );
      // A sibling route that merely shares a prefix is NOT nested.
      expect(
        ShellNavigation.locationIsUnder('/planner-archive', '/planner'),
        isFalse,
      );
      expect(
          ShellNavigation.locationIsUnder('/imaging', '/dashboard'), isFalse);
    });

    test('every primary route still resolves to its own index', () {
      for (var i = 0; i < ShellNavigation.primaryRoutes.length; i++) {
        expect(
          ShellNavigation.primaryIndexForLocation(
            ShellNavigation.primaryRoutes[i],
          ),
          i,
        );
      }
    });

    test('isBottomNavRoute covers the four fixed slots only', () {
      expect(ShellNavigation.isBottomNavRoute('/guiding'), isTrue);
      expect(ShellNavigation.isBottomNavRoute('/dashboard'), isTrue);
      // Everything else reaches the phone through the More sheet.
      expect(ShellNavigation.isBottomNavRoute('/weather'), isFalse);
      expect(ShellNavigation.isBottomNavRoute('/settings'), isFalse);
      expect(ShellNavigation.isBottomNavRoute('/science'), isFalse);
      expect(ShellNavigation.isBottomNavRoute('/polar-alignment'), isFalse);
    });
  });
}
