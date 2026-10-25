import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_route.dart';
import 'package:skotiq_app/utils/darkroom_navigation.dart';

DarkroomRoute parse(String location) =>
    DarkroomRoute.fromUri(Uri.parse(location));

void main() {
  test('a bare /darkroom opens Targets', () {
    expect(parse('/darkroom'), const DarkroomRoute());
    expect(parse('/darkroom').scope.isEmpty, isTrue);
  });

  test('every tab parses by name', () {
    for (final tab in DarkroomTab.values) {
      expect(parse(darkroomTabLocation(tab)).tab, tab);
    }
    expect(parse('/darkroom?tab=nonsense').tab, DarkroomTab.targets);
  });

  test('a target and its framing check round-trip, names with spaces too', () {
    final detail = parse(darkroomTargetLocation('NGC 891'));
    expect(detail.tab, DarkroomTab.targets);
    expect(detail.target, 'NGC 891');
    expect(detail.view, DarkroomTargetView.detail);

    final framing = parse(darkroomFramingLocation('NGC 891'));
    expect(framing.target, 'NGC 891');
    expect(framing.view, DarkroomTargetView.framing);
    expect(
      darkroomFramingLocation('NGC 891'),
      '/darkroom?tab=targets&target=NGC+891&view=framing',
    );
  });

  test('a framing view without a target is the plain tab', () {
    expect(
      parse('/darkroom?tab=targets&view=framing').view,
      DarkroomTargetView.detail,
    );
  });

  test('Edit opens a registered image or a recipe', () {
    final master = parse(darkroomEditLocation(masterId: 12));
    expect(master.tab, DarkroomTab.edit);
    expect(master.scope, const DarkroomScope.master(12));
    expect(parse(darkroomEditLocation(recipeId: 3)).scope,
        const DarkroomScope.recipe(3));
  });

  test('old links keep their meaning', () {
    expect(parse(darkroomMasterLocation(7)).tab, DarkroomTab.edit);
    expect(parse(darkroomMasterLocation(7)).masterId, 7);
    expect(parse(darkroomRecipeLocation(4)).recipeId, 4);
    final pass = parse(darkroomPassLocation('run 1'));
    expect(pass.tab, DarkroomTab.activity);
    expect(pass.passRunId, 'run 1');
  });

  test('a route rebuilds the location it came from', () {
    for (final location in [
      darkroomFramingLocation('M 81'),
      darkroomEditLocation(masterId: 5),
      darkroomTabLocation(DarkroomTab.activity),
    ]) {
      expect(parse(parse(location).location), parse(location));
    }
  });
}
