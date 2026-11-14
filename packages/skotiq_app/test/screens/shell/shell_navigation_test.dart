import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/shell_navigation.dart';

void main() {
  group('ShellNavigation', () {
    test('the rail is ten destinations grouped Observe/Prepare/Review', () {
      // 04-shell §3.2. Order and grouping are the spec; the route paths do not
      // change. Settings is deliberately absent — it lives in the top bar.
      expect(ShellNavigation.rail.map((r) => r.path), [
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
        ShellNavigation.rail.map((d) => d.group).toList(),
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
      for (final dest in ShellNavigation.rail) {
        if (seen.isEmpty || seen.last != dest.group) {
          expect(
            seen,
            isNot(contains(dest.group)),
            reason: '${dest.group} must appear as one contiguous run',
          );
          seen.add(dest.group!);
        }
      }
    });

    test('the phone bar has four routed slots', () {
      // The fifth slot is "More", which the bar renders itself.
      expect(ShellNavigation.phoneBar.map((r) => r.path),
          ['/dashboard', '/imaging', '/sequencer', '/guiding']);
    });

    test(
        'the More sheet lists every destination without a slot, then '
        'Session replay and Settings', () {
      expect(
        ShellNavigation.moreSheet.map((d) => d.path).toList(),
        [
          '/planner',
          '/equipment',
          '/flat-wizard',
          '/weather',
          '/darkroom',
          '/analytics',
          '/session-replay',
          '/settings',
        ],
      );
    });

    int railIndexOf(AppRoute route) => ShellNavigation.rail.indexOf(route);

    test('railIndexFor resolves planner and ignores query', () {
      expect(
        ShellNavigation.railIndexFor('/planner?tab=scheduler'),
        railIndexOf(AppRoute.planner),
      );
    });

    // A prefix walk cannot answer these: /session-review shares no prefix with
    // /darkroom, and /settings shares one with nothing yet must light nothing.
    test('route-only screens light the rail item that owns them', () {
      for (final location in [
        '/session-review?session=3',
        '/stack-result?id=9',
        '/mosaic',
        '/mosaic/7',
      ]) {
        expect(
          ShellNavigation.railIndexFor(location),
          railIndexOf(AppRoute.darkroom),
          reason: '$location is a Darkroom surface',
        );
      }
      expect(ShellNavigation.railIndexFor('/polar-alignment'),
          railIndexOf(AppRoute.equipment));
      expect(ShellNavigation.railIndexFor('/flat-wizard'),
          railIndexOf(AppRoute.flatWizard));
      expect(ShellNavigation.railIndexFor('/tonight'),
          railIndexOf(AppRoute.tonight));
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
        '/session-replay',
        '/session-replay/4',
        '/diagnostics',
        '/diagnostics/dump',
        '/tutorial/first-night',
        '/',
      ]) {
        expect(
          ShellNavigation.railIndexFor(location),
          -1,
          reason: '$location must not highlight a rail destination',
        );
      }
    });

    test('a sub-route resolves to the destination that hosts it', () {
      // The image-ready notification deep link renders the Imaging screen.
      expect(ShellNavigation.railIndexFor('/imaging/preview/42'),
          railIndexOf(AppRoute.imaging));
      expect(ShellNavigation.railIndexFor('/imaging/preview/42?x=1'),
          railIndexOf(AppRoute.imaging));
    });

    test('contains matches on segment boundaries only', () {
      expect(AppRoute.planner.contains('/planner'), isTrue);
      expect(AppRoute.planner.contains('/planner?tab=discover'), isTrue);
      expect(AppRoute.planner.contains('/planner/queue'), isTrue);
      // A sibling route that merely shares a prefix is NOT nested.
      expect(AppRoute.planner.contains('/planner-archive'), isFalse);
      expect(AppRoute.tonight.contains('/imaging'), isFalse);
    });

    test('every rail route resolves to its own index', () {
      for (var i = 0; i < ShellNavigation.rail.length; i++) {
        expect(ShellNavigation.railIndexFor(ShellNavigation.rail[i].path), i);
      }
    });
  });
}
