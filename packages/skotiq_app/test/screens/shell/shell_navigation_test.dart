import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/shell/shell_navigation.dart';

void main() {
  group('ShellNavigation', () {
    test(
        'the rail runs in the order of a night: Tonight, Prepare, Observe, '
        'Review', () {
      // UI plan 3.9. Settings is deliberately absent: it lives in the top bar.
      // The Flat wizard is a tool reached from the Darkroom, Imaging and the
      // palette, not a place.
      expect(ShellNavigation.rail.map((r) => r.path), [
        '/dashboard',
        '/planner',
        '/equipment',
        '/weather',
        '/sequencer',
        '/imaging',
        '/guiding',
        '/analytics',
        '/darkroom',
      ]);
      expect(
        ShellNavigation.rail.map((d) => d.group).toList(),
        [
          ShellNavGroup.home,
          ShellNavGroup.prepare,
          ShellNavGroup.prepare,
          ShellNavGroup.prepare,
          ShellNavGroup.observe,
          ShellNavGroup.observe,
          ShellNavGroup.observe,
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

    test('Tonight has no group heading; the stages do', () {
      final l10n = SkotiqLocalizations(const Locale('en'));
      expect(ShellNavGroup.home.label(l10n), isNull);
      expect(
        [
          for (final group in ShellNavGroup.values)
            if (group != ShellNavGroup.home) group.label(l10n),
        ],
        ['Prepare', 'Observe', 'Review'],
      );
    });

    test(
        'the Flat wizard is off the rail, in the palette, hosted by the '
        'Darkroom', () {
      expect(ShellNavigation.rail, isNot(contains(AppRoute.flatWizard)));
      expect(AppRoute.flatWizard.palette, isTrue);
      expect(AppRoute.flatWizard.railHost, AppRoute.darkroom);
    });

    test('the phone bar has four routed slots', () {
      // The fifth slot is "More", which the bar renders itself.
      expect(ShellNavigation.phoneBar.map((r) => r.path),
          ['/dashboard', '/imaging', '/sequencer', '/guiding']);
    });

    test(
        'the More sheet lists every destination without a slot, then '
        'Settings', () {
      expect(
        ShellNavigation.moreSheet.map((d) => d.path).toList(),
        [
          '/planner',
          '/equipment',
          '/weather',
          '/analytics',
          '/darkroom',
          '/settings',
        ],
      );
    });

    int railIndexOf(AppRoute route) => ShellNavigation.rail.indexOf(route);

    test('railIndexFor resolves planner and ignores query', () {
      expect(
        ShellNavigation.railIndexFor('/planner?tab=targets'),
        railIndexOf(AppRoute.planner),
      );
    });

    // A prefix walk cannot answer these: /stack-result shares no prefix with
    // /darkroom, and /settings shares one with nothing yet must light nothing.
    test('route-only screens light the rail item that owns them', () {
      for (final location in [
        '/stack-result?id=9',
      ]) {
        expect(
          ShellNavigation.railIndexFor(location),
          railIndexOf(AppRoute.darkroom),
          reason: '$location is a Darkroom surface',
        );
      }
      // A mosaic is a target with panels: Plan hosts it.
      expect(ShellNavigation.railIndexFor('/mosaic/7'),
          railIndexOf(AppRoute.planner));
      expect(ShellNavigation.railIndexFor('/polar-alignment'),
          railIndexOf(AppRoute.equipment));
      expect(ShellNavigation.railIndexFor('/flat-wizard'),
          railIndexOf(AppRoute.darkroom));
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
        '/session-review?session=3',
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
