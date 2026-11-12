// A protocol the user does not run is not an error.
//
// Walk-2 F2: on every device step a ZWO-native user saw red "Alpaca (0)" and
// "INDI (0)" chips and two red "nothing answered" lines, five times over,
// because the Drivers step ticks Alpaca and INDI by default and nothing listens
// on localhost. A refused connection now reads as a muted note with a way to
// point the scan at the server the user does run; a server that is configured
// but does not answer still warns.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/mount_step.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _refusedIndi =
    'INDI server connection failed: SkotiqError.connectionFailed('
    'deviceId: localhost:7624, reason: error trying to connect: tcp connect '
    'error: Connection refused (os error 111))';

const _timedOutAlpaca =
    'Alpaca server connection failed: operation timed out (10.0.0.4:11111)';

class _Discovery extends UnifiedDiscoveryNotifier {
  _Discovery(super.ref) {
    state = const UnifiedDiscoveryState(
      backendStates: {
        DriverType.indi: BackendDiscoveryState(
          backend: DriverType.indi,
          status: DiscoveryStatus.error,
          error: _refusedIndi,
        ),
        DriverType.alpaca: BackendDiscoveryState(
          backend: DriverType.alpaca,
          status: DiscoveryStatus.error,
          error: _timedOutAlpaca,
        ),
      },
    );
  }

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {}
}

class _Draft extends OnboardingNotifier {
  _Draft(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const OnboardingDraft(
      currentStep: OnboardingStep.mount,
      selectedDrivers: {DriverType.indi, DriverType.alpaca},
    );
  }
}

void main() {
  testWidgets('no INDI server reads as a note, not an error', (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          onboardingDraftProvider.overrideWith(_Draft.new),
          unifiedDiscoveryProvider.overrideWith(_Discovery.new),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: OnboardingMountStep()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final colors = SkotiqColors.of(tester.element(find.byType(Scaffold)));
    final note = find.text('No INDI server at localhost:7624.');
    expect(note, findsOneWidget);
    expect(tester.widget<Text>(note).style?.color, colors.textMuted);
    expect(find.textContaining('nothing answered — nothing is listening'),
        findsNothing);

    final indiChip = tester.widget<SkotiqChip>(
      find.widgetWithText(SkotiqChip, 'INDI: no server'),
    );
    expect(indiChip.tone, ChipTone.neutral);

    // A configured server that does not answer is still a problem to report.
    final alpacaChip = tester.widget<SkotiqChip>(
      find.widgetWithText(SkotiqChip, 'Alpaca (0)'),
    );
    expect(alpacaChip.tone, ChipTone.warning);
    expect(find.textContaining('did not answer in time'), findsOneWidget);

    // Both server protocols can be pointed somewhere else from here.
    expect(find.widgetWithText(SkotiqButton, 'Change address'), findsNWidgets(2));
  });
}
