// Go to: a typed object name is looked up by the button pressed, so typing
// "NGC 7331" and pressing Slew goes there without a separate Enter, and RA
// and Dec typed by hand are used as typed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/panel/mount/mount_go_to.dart';
import 'package:skotiq_app/screens/night_control/panel/mount/night_mount_tab.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/mount_command_service.dart';

import '../../../../harness/harness.dart';
import '../scope_panel_test_support.dart';

const _name = ValueKey<String>('nightMount.goToName');
const _ra = ValueKey<String>('nightMount.goToRa');
const _dec = ValueKey<String>('nightMount.goToDec');
const _slew = ValueKey<String>('nightMount.slew');
const _slewCenter = ValueKey<String>('nightMount.slewCenter');

class _SlewRecorder extends RecordingMountCommands {
  _SlewRecorder(super.ref);

  final List<(double, double)> slews = [];

  @override
  Future<CommandActionResult> slewTo(double ra, double dec,
      {bool showFeedback = true}) {
    slews.add((ra, dec));
    return super.slewTo(ra, dec, showFeedback: showFeedback);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(HarnessHandle, List<String>)> pump(WidgetTester tester) async {
    final lookups = <String>[];
    final handle = await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: [
        ...panelOverrides(),
        mountCommandServiceProvider.overrideWith(_SlewRecorder.new),
        nightGoToResolverProvider.overrideWithValue((query) async {
          lookups.add(query);
          return query == 'NGC 7331'
              ? const NightGoToTarget(
                  name: 'NGC7331', raHours: 22.618, decDegrees: 34.416)
              : null;
        }),
      ],
    );
    await tester.ensureVisible(find.byKey(_slew));
    await tester.pump();
    return (handle, lookups);
  }

  _SlewRecorder commands(HarnessHandle handle) =>
      handle.container.read(mountCommandServiceProvider) as _SlewRecorder;

  testWidgets('a typed name is looked up when Slew is pressed', (tester) async {
    final (handle, lookups) = await pump(tester);
    expect(isEnabled(tester, _slew), isFalse,
        reason: 'nothing typed, nothing to go to');

    await tester.enterText(find.byKey(_name), 'NGC 7331');
    await tester.pump();
    expect(isEnabled(tester, _slew), isTrue);
    expect(isEnabled(tester, _slewCenter), isTrue);

    await tester.tap(find.byKey(_slew));
    await tester.pumpAndSettle();

    expect(lookups, ['NGC 7331']);
    expect(commands(handle).slews, [(22.618, 34.416)]);
    expect(find.text('NGC7331'), findsOneWidget,
        reason: 'the field shows the object the lookup found');
  });

  testWidgets('a name that finds nothing says so and moves nothing',
      (tester) async {
    final (handle, lookups) = await pump(tester);
    await tester.enterText(find.byKey(_name), 'Nowhere');
    await tester.pump();
    await tester.tap(find.byKey(_slew));
    await tester.pumpAndSettle();

    expect(lookups, ['Nowhere']);
    expect(commands(handle).slews, isEmpty);
    expect(find.textContaining('Nowhere'), findsWidgets);
  });

  testWidgets('RA and Dec typed after a name are used as typed',
      (tester) async {
    final (handle, lookups) = await pump(tester);
    await tester.enterText(find.byKey(_name), 'my field');
    await tester.enterText(find.byKey(_ra), '10h00m00s');
    await tester.enterText(find.byKey(_dec), '+20 00 00');
    await tester.pump();
    await tester.tap(find.byKey(_slew));
    await tester.pumpAndSettle();

    expect(lookups, isEmpty);
    expect(commands(handle).slews, [(10.0, 20.0)]);
  });
}
