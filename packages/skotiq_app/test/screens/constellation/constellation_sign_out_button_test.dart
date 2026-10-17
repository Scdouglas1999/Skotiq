import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/constellation/constellation_ui_providers.dart';
import 'package:skotiq_app/screens/constellation/widgets/hub_status_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

void main() {
  testWidgets('hub sign-out is single-flight, atomic, and retryable',
      (tester) async {
    final settings = _MockSettingsDao();
    final firstWrite = Completer<void>();
    final writes = <Map<String, String>>[];
    var signedOut = 0;

    when(() => settings.setSettings(any())).thenAnswer((invocation) {
      writes.add(
        Map<String, String>.from(
          invocation.positionalArguments.single as Map,
        ),
      );
      if (writes.length == 1) return firstWrite.future;
      return Future<void>.value();
    });

    await pumpAppScreen(
      tester,
      ConstellationSignOutButton(onSignedOut: () => signedOut++),
      extraOverrides: [settingsDaoProvider.overrideWithValue(settings)],
    );

    final buttonFinder = find.widgetWithText(SkotiqButton, 'Sign out');
    await tester.tap(buttonFinder);
    await tester.tap(buttonFinder);
    await tester.pump();

    expect(writes, hasLength(1));
    expect(
      tester.widget<SkotiqButton>(buttonFinder).isLoading,
      isTrue,
    );
    expect(
      writes.single,
      {
        constellationHubUrlSettingKey: '',
        constellationHubTokenSettingKey: '',
        constellationAccountIdSettingKey: '',
        constellationPublicKeySettingKey: '',
      },
    );

    firstWrite.completeError(StateError('database is read-only'));
    await tester.pumpAndSettle();

    expect(signedOut, 0);
    expect(find.textContaining('database is read-only'), findsOneWidget);
    expect(
      tester.widget<SkotiqButton>(buttonFinder).isLoading,
      isFalse,
    );

    await tester.tap(buttonFinder);
    await tester.pumpAndSettle();

    expect(writes, hasLength(2));
    expect(signedOut, 1);
  });
}
