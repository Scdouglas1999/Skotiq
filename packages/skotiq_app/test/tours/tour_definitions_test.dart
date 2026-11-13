// Tours are data. These checks are what keeps that data pointing at things
// that exist: a step whose target no widget carries, or whose screen is not a
// page, is a card over nothing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/router/analytics_route.dart';
import 'package:skotiq_app/router/equipment_route.dart';
import 'package:skotiq_app/router/planner_route.dart';
import 'package:skotiq_app/router/sequencer_route.dart';
import 'package:skotiq_app/router/settings_sections.dart';
import 'package:skotiq_app/tours/tour.dart';

/// Every Dart file under lib/, joined, without the tour data itself.
String _appSource() {
  final lib = Directory('lib');
  final buffer = StringBuffer();
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.contains('${Platform.pathSeparator}tours'
        '${Platform.pathSeparator}')) {
      continue;
    }
    buffer.writeln(entity.readAsStringSync());
  }
  return buffer.toString();
}

void main() {
  final usedTargets = {
    for (final tour in Tour.values)
      for (final step in tour.steps)
        if (step.target != null) step.target!,
  };

  group('every tour', () {
    test('has steps, and no two steps anywhere share an id', () {
      final seen = <String, Tour>{};
      for (final tour in Tour.values) {
        expect(tour.steps, isNotEmpty, reason: '${tour.name} has no steps');
        for (final step in tour.steps) {
          expect(
            seen.containsKey(step.id),
            isFalse,
            reason: '${step.id} is in ${tour.name} and ${seen[step.id]?.name}',
          );
          seen[step.id] = tour;
        }
      }
    });

    test('keeps the id its saved progress is stored under', () {
      // A changed id orphans the progress users already have.
      expect({
        for (final tour in Tour.values) tour.name: tour.id
      }, {
        'firstNight': 'firstNight',
        'firstLaunch': 'firstLaunchTour',
        'equipmentSetup': 'equipmentSetup',
        'targetPlanning': 'targetPlanning',
        'automatedImaging': 'automatedImaging',
        'calibrationFrames': 'calibrationFrames',
        'advancedFeatures': 'advancedFeatures',
        'tonight': 'dashboardTour',
        'equipment': 'equipmentTour',
        'imaging': 'imagingTour',
        'guiding': 'guidingTour',
        'sequencer': 'sequencerTour',
        'planetarium': 'planetariumTour',
        'framing': 'framingTour',
        'analytics': 'analyticsTour',
        'flatWizard': 'flatWizardTour',
        'weather': 'weatherTour',
        'settings': 'settingsTour',
        'polarAlignment': 'polarAlignmentTour',
      });
    });

    test('can be reached: from Settings > Help or from its screen', () {
      for (final tour in Tour.values) {
        final listed = Tour.workflows.contains(tour) ||
            tour == Tour.firstNight ||
            tour == Tour.firstLaunch;
        expect(
          listed || tour.screen != null,
          isTrue,
          reason: '${tour.name} has no way in',
        );
        if (Tour.workflows.contains(tour)) {
          expect(tour.icon, isNotNull, reason: '${tour.name} row icon');
        }
      }
    });

    test('about a screen names a page the help menu can be opened on', () {
      for (final tour in Tour.values) {
        final screen = tour.screen;
        if (screen == null) continue;
        expect(screen.onlyRedirects, isFalse, reason: tour.name);
        expect(Tour.forScreen(screen), contains(tour));
      }
    });
  });

  group('every step', () {
    test('is shown on a real page, on a tab that exists', () {
      for (final tour in Tour.values) {
        for (var i = 0; i < tour.steps.length; i++) {
          final location = tour.locationOfStep(i);
          final step = tour.steps[i];
          if (location == null) {
            // Only the shell's own controls, or a card with nothing to point
            // at in a tour that has no screen, may stay wherever the user is.
            expect(
              step.target?.location,
              isNull,
              reason: '${tour.name}/${step.id}',
            );
            continue;
          }
          final uri = Uri.parse(location);
          final route = AppRoute.of(location);
          expect(route, isNotNull, reason: '${step.id}: $location');
          expect(route!.path, uri.path, reason: '${step.id}: $location');
          expect(route.onlyRedirects, isFalse, reason: '${step.id}: $location');
          expect(route.redirect(uri), isNull, reason: '${step.id}: $location');

          final tab = uri.queryParameters['tab'];
          if (tab != null) {
            final known = switch (route) {
              AppRoute.planner => PlannerTab.fromQuery(tab),
              AppRoute.equipment => EquipmentTab.fromQuery(tab),
              AppRoute.sequencer => SequencerTab.fromQuery(tab),
              AppRoute.analytics => AnalyticsTab.fromQuery(tab),
              _ => null,
            };
            expect(known, isNotNull, reason: '${step.id}: $location');
          }
          final section = uri.queryParameters['section'];
          if (section != null) {
            expect(
              SettingsSectionId.resolve(section),
              isNotNull,
              reason: '${step.id}: $location',
            );
          }
        }
      }
    });

    test('of a walkthrough has an icon and a named screen to open', () {
      for (final tour in Tour.values) {
        if (tour.style != TourStyle.walkthrough) continue;
        for (final step in tour.steps) {
          expect(step.icon, isNotNull, reason: step.id);
          expect(step.target, isNull, reason: step.id);
          final showMe = step.showMe;
          if (showMe != null) {
            expect(showMe.label, isNotNull, reason: step.id);
          }
        }
        expect(
          tour.steps.where((step) => step.showMe != null),
          isNotEmpty,
          reason: tour.name,
        );
      }
    });
  });

  group('every target', () {
    final source = _appSource();

    test('is carried by a widget', () {
      for (final target in TourTarget.values) {
        if (target.isRailDestination) continue;
        expect(
          source.contains('TourTarget.${target.name}.key'),
          isTrue,
          reason: 'no widget is built with TourTarget.${target.name}.key',
        );
      }
    });

    test('for a rail destination is the one the rail attaches', () {
      expect(
        source.contains('TourTarget.forDestination('),
        isTrue,
        reason: 'the rail and the phone bar attach destination targets',
      );
      for (final route in AppRoute.values) {
        final target = TourTarget.forDestination(route);
        expect(
          target != null,
          route.group != null,
          reason: '${route.name}: a rail destination has a target and '
              'nothing else does',
        );
        if (target != null) expect(target.isRailDestination, isTrue);
      }
      expect(
        TourTarget.values.where((target) => target.isRailDestination).length,
        AppRoute.values.where((route) => route.group != null).length,
      );
    });

    test('is used by a step, or is part of the shell', () {
      for (final target in TourTarget.values) {
        if (target.isRailDestination || target == TourTarget.navMore) continue;
        expect(
          usedTargets,
          contains(target),
          reason: '${target.name} is a target no tour points at',
        );
      }
    });
  });
}
