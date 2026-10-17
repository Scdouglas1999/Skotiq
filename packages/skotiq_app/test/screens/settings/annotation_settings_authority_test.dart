import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/annotation_panel.dart';
import 'package:skotiq_app/screens/settings/widgets/annotation_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

int _settingsAttempts = 0;
int _styleAttempts = 0;
int _presetAttempts = 0;

class _FailingAnnotationSettings extends AnnotationSettingsNotifier {
  @override
  Future<AnnotationSettings> build() async {
    _settingsAttempts++;
    throw StateError('annotation settings unavailable');
  }
}

class _FailingMarkerStyle extends AnnotationMarkerStyleNotifier {
  @override
  Future<AnnotationMarkerStyle> build() async {
    _styleAttempts++;
    throw StateError('marker style unavailable');
  }
}

class _FailingAnnotationPresets extends AnnotationPresetsNotifier {
  @override
  Future<List<AnnotationPreset>> build() async {
    _presetAttempts++;
    throw StateError('preset library unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('display settings outage hides placeholder controls and retries',
      (tester) async {
    _settingsAttempts = 0;
    await pumpAppScreen(
      tester,
      const AnnotationSettingsPage(),
      extraOverrides: [
        annotationSettingsProvider.overrideWith(
          _FailingAnnotationSettings.new,
        ),
      ],
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Could not load annotation display settings'), findsOne);
    expect(
      find.textContaining('Bad state: annotation settings unavailable'),
      findsOne,
    );
    expect(find.text('Enable annotations'), findsNothing);
    expect(_settingsAttempts, 1);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Retry annotation settings'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_settingsAttempts, 2);
    expect(find.text('Enable annotations'), findsNothing);
  });

  testWidgets('marker style outage does not show writable style defaults',
      (tester) async {
    _styleAttempts = 0;
    await pumpAppScreen(
      tester,
      const AnnotationSettingsPage(),
      extraOverrides: [
        annotationMarkerStyleProvider.overrideWith(_FailingMarkerStyle.new),
      ],
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Could not load annotation marker styles'), findsOne);
    expect(
      find.textContaining('Bad state: marker style unavailable'),
      findsOne,
    );
    expect(find.text('Stroke width'), findsNothing);
    expect(find.text('Enable annotations'), findsNothing);
    expect(_styleAttempts, 1);
  });

  testWidgets('in-image panel hides default filters and retries settings',
      (tester) async {
    _settingsAttempts = 0;
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SizedBox(
          width: 400,
          height: 600,
          child: AnnotationTabPanel(colors: SkotiqColors.of(context)),
        ),
      ),
      extraOverrides: [
        annotationSettingsProvider.overrideWith(
          _FailingAnnotationSettings.new,
        ),
      ],
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Could not load annotation settings'), findsOneWidget);
    expect(find.text('Filters'), findsNothing);
    expect(_settingsAttempts, 1);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Retry annotation settings'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_settingsAttempts, 2);
    expect(find.text('Filters'), findsNothing);
  });

  testWidgets('preset outage is visible and save-as-preset is disabled',
      (tester) async {
    _presetAttempts = 0;
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SizedBox(
          width: 400,
          height: 600,
          child: AnnotationTabPanel(colors: SkotiqColors.of(context)),
        ),
      ),
      extraOverrides: [
        annotationPresetsProvider.overrideWith(
          _FailingAnnotationPresets.new,
        ),
      ],
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('Annotation presets'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Saved presets unavailable:'), findsOneWidget);
    expect(find.text('Deep Field'), findsOneWidget);
    final saveItem = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('Save as Preset'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(saveItem.enabled, isFalse);
    expect(_presetAttempts, 1);

    await tester.tap(find.text('Retry saved presets'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_presetAttempts, 2);
  });
}
