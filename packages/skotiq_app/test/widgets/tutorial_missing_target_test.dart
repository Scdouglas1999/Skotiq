// The Dashboard Tour must not narrate panels the default dashboard layout does
// not contain — Live Image Preview, Quick Capture, Session Progress and six more
// — each with the card floating in mid-screen, no spotlight and nothing
// highlighted, because their target keys resolve to widgets that are never
// built.
//
// The walk that decides where such a step sends the operator is pinned here.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/tutorial_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';

TutorialStep _step(String id, {String? targetKey, required int order}) =>
    TutorialStep(
      id: id,
      title: id,
      description: id,
      targetKey: targetKey,
      order: order,
      category: TutorialCategory.dashboardTour,
    );

final _tour = <TutorialStep>[
  _step('welcome', order: 0),
  _step('present', targetKey: 'dashboard_edit_button', order: 1),
  _step('absent', targetKey: 'dashboard_live_preview', order: 2),
  _step('complete', order: 3),
];

bool _onlyEditButtonIsLive(String key) => key == 'dashboard_edit_button';

void main() {
  test('a step whose panel is not on screen is passed over', () {
    expect(
      tutorialStepIndexPastMissingTarget(
        steps: _tour,
        index: 2,
        direction: TutorialDirection.forward,
        isTargetLive: _onlyEditButtonIsLive,
      ),
      3,
    );
  });

  test('going back past a missing panel keeps going back', () {
    expect(
      tutorialStepIndexPastMissingTarget(
        steps: _tour,
        index: 2,
        direction: TutorialDirection.backward,
        isTargetLive: _onlyEditButtonIsLive,
      ),
      1,
      reason: 'Back must not bounce the operator forward off a dead step',
    );
  });

  test('a step whose panel IS on screen stands', () {
    expect(
      tutorialStepIndexPastMissingTarget(
        steps: _tour,
        index: 1,
        direction: TutorialDirection.forward,
        isTargetLive: _onlyEditButtonIsLive,
      ),
      isNull,
    );
  });

  test('centred steps with no target are never skipped', () {
    for (final index in const [0, 3]) {
      expect(
        tutorialStepIndexPastMissingTarget(
          steps: _tour,
          index: index,
          direction: TutorialDirection.forward,
          isTargetLive: (_) => false,
        ),
        isNull,
        reason: 'the welcome and completion cards point at nothing by design',
      );
    }
  });

  test('a tour whose targets have none resolved stands down entirely', () {
    expect(
      tutorialStepIndexPastMissingTarget(
        steps: _tour,
        index: 2,
        direction: TutorialDirection.forward,
        isTargetLive: (_) => false,
      ),
      isNull,
      reason: 'a screen mid-build is not a screen without the panel',
    );
  });

  // A walk that hops ONE step per call and re-enters itself from the next
  // build, 450 ms apart, parked the twelve-step tour on (and announced)
  // "step 6 of 12: Weather Status" and "step 11 of 12: Active Sequence" on a
  // dashboard that carried neither panel.
  test('a run of absent panels is passed over in ONE jump', () {
    final tour = <TutorialStep>[
      _step('welcome', order: 0),
      _step('present', targetKey: 'dashboard_edit_button', order: 1),
      for (var i = 2; i < 11; i++)
        _step('absent $i', targetKey: 'dashboard_gone_$i', order: i),
      _step('complete', order: 11),
    ];

    expect(
      tutorialStepIndexPastMissingTarget(
        steps: tour,
        index: 2,
        direction: TutorialDirection.forward,
        isTargetLive: _onlyEditButtonIsLive,
      ),
      11,
      reason: 'the completion card is the next thing the screen HAS; '
          'landing on 5 or 10 announces a panel that is not on screen',
    );

    // And from the far side: Back from the last absent step lands on the one
    // panel the screen really has, not on any of the nine it does not.
    expect(
      tutorialStepIndexPastMissingTarget(
        steps: tour,
        index: 10,
        direction: TutorialDirection.backward,
        isTargetLive: _onlyEditButtonIsLive,
      ),
      1,
    );
  });

  test('every Tonight tour step stands without a spotlight target', () {
    // Tonight's tour names regions instead of spotlighting widgets, so no
    // step can point at a panel that is not built.
    final tonight =
        TutorialDefinitions.getStepsForCategory(TutorialCategory.dashboardTour);
    expect(tonight, isNotEmpty);
    for (final step in tonight) {
      expect(step.targetKey, isNull, reason: step.id);
    }
  });

  test('the walk stops at the ends rather than running off them', () {
    final trailing = [_step('absent', targetKey: 'dashboard_x', order: 0)];
    expect(
      tutorialStepIndexPastMissingTarget(
        steps: trailing,
        index: 0,
        direction: TutorialDirection.forward,
        isTargetLive: (_) => false,
      ),
      isNull,
    );
    expect(
      tutorialStepIndexPastMissingTarget(
        steps: trailing,
        index: 0,
        direction: TutorialDirection.backward,
        isTargetLive: (_) => false,
      ),
      isNull,
    );
  });
}
