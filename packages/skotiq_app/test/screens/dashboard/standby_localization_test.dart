// Choosing Spanish must not leave the LANDING SCREEN in English.
//
// Settings > General > Language > Spanish translates the nav rail, the title
// bar, the status bar and the whole Settings tree; untranslated, the Dashboard
// — the screen the app opens on — renders "TONIGHT'S BRIEFING", "No run active",
// "Image tonight", "Plan Tonight", "Tonight's targets", "Readiness", "Moon",
// "Waning Gibbous", "Moonrise", "Moonset", "Last run", "No runs yet…",
// "Set a capture directory to track free space." and "Edit Dashboard" in
// English. A picker whose own scope claim is "app chrome" while the first
// screen the user sees is untranslated reads as broken, not as partial.
//
// These tests pump the real CockpitStandby under Locale('es') and assert the
// Spanish copy renders and the English literals do not.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_standby.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/moon_card.dart';
import 'package:skotiq_app/services/observing_site.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

const _moon = MoonTimes(illumination: 74, phaseName: 'Waning Gibbous');

Future<void> _pumpStandby(WidgetTester tester, {Locale? locale}) async {
  await pumpAppScreen(
    tester,
    Builder(
      builder: (context) =>
          CockpitStandby(colors: SkotiqColors.of(context)),
    ),
    // Narrow enough that the live-astro widgets (which spin a 1 s planetarium
    // clock) stay out of the tree; the briefing's own copy is the subject.
    size: const Size(820, 1400),
    locale: locale,
    extraOverrides: [
      moonInfoProvider.overrideWithValue(_moon),
      siteMoonTimesProvider.overrideWithValue(_moon),
    ],
    settle: false,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the night briefing follows the chosen language', (tester) async {
    await _pumpStandby(tester, locale: const Locale('es'));

    expect(find.text('RESUMEN DE ESTA NOCHE'), findsOneWidget);
    expect(find.text('Ninguna sesión activa'), findsOneWidget);
    expect(find.text('Capturar esta noche'), findsOneWidget);
    expect(find.text('Objetivos de esta noche'), findsOneWidget);
    expect(find.text('Preparación'), findsOneWidget);
    expect(find.text('Conectar el equipo'), findsOneWidget);
    expect(find.text('Última sesión'), findsOneWidget);
    expect(
      find.text('Todavía no hay sesiones: tu primera noche aparecerá aquí.'),
      findsOneWidget,
    );

    // …and none of the English the audit read off the Spanish build.
    expect(find.text("TONIGHT'S BRIEFING"), findsNothing);
    expect(find.text('No run active'), findsNothing);
    expect(find.text('Image tonight'), findsNothing);
    expect(find.text("Tonight's targets"), findsNothing);
    expect(find.text('Readiness'), findsNothing);
    expect(find.text('Connect equipment'), findsNothing);
    expect(find.text('Last run'), findsNothing);
    expect(
      find.text('No runs yet — your first night will appear here.'),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the moon card translates the phase and the readout',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => MoonCard(colors: SkotiqColors.of(context)),
      ),
      locale: const Locale('es'),
      extraOverrides: [
        moonInfoProvider.overrideWithValue(_moon),
        siteMoonTimesProvider.overrideWithValue(_moon),
      ],
      settle: false,
    );
    await tester.pump();

    expect(find.text('Luna'), findsOneWidget);
    expect(find.text('Gibosa menguante'), findsOneWidget);
    expect(find.text('74 % iluminada'), findsOneWidget);
    expect(find.text('Salida de la Luna'), findsOneWidget);
    expect(find.text('Waning Gibbous'), findsNothing);
    expect(find.text('74% illuminated'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('an English build is untouched', (tester) async {
    await _pumpStandby(tester);

    expect(find.text("TONIGHT'S BRIEFING"), findsOneWidget);
    expect(find.text('No run active'), findsOneWidget);
    expect(find.text('Image tonight'), findsOneWidget);
    expect(find.text('Readiness'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
