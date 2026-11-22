// The Sequencer telemetry strip prints the guider's RMS the way Tonight does:
// arcseconds when the guider reports its pixel scale, pixels otherwise (the
// RMS is in guide-camera pixels). Each item reads as one label
// ("Filter: L").

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/equipment_telemetry_strip.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _Guider extends GuiderStateNotifier {
  _Guider(super.ref, this._scale) {
    setConnecting('phd2', 'PHD2');
    setConnected();
    setGuiding(true);
    updateRms(0.31, 0.32, 0.45);
    setPixelScale(_scale);
  }

  final double? _scale;
}

class _Wheel extends FilterWheelStateNotifier {
  _Wheel(super.ref) {
    setConnecting('efw', 'ZWO EFW');
    setConnected(filterNames: const ['L', 'R', 'G', 'B']);
    updatePosition(0);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  double? scale,
  Axis direction = Axis.horizontal,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        guiderStateProvider.overrideWith((ref) => _Guider(ref, scale)),
        filterWheelStateProvider.overrideWith(_Wheel.new),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => EquipmentTelemetryStrip(
                colors: context.skotiqColors,
                direction: direction,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the strip shows guide RMS in pixels when no scale is known',
      (tester) async {
    await _pump(tester);
    expect(find.text('0.45 px'), findsOneWidget);
    expect(find.textContaining('0.45"'), findsNothing);
    expect(find.textContaining('0.45″'), findsNothing);
  });

  testWidgets('the strip converts guide RMS to arcseconds with the scale',
      (tester) async {
    await _pump(tester, scale: 1.41439);
    // 0.45 px × 1.41439″/px
    expect(find.text('0.64″'), findsOneWidget);
    expect(find.textContaining('px'), findsNothing);
  });

  testWidgets('the vertical card uses the same units', (tester) async {
    await _pump(tester, direction: Axis.vertical);
    expect(find.text('0.45 px'), findsOneWidget);
    expect(find.text('0.31 px'), findsOneWidget);
    expect(find.text('0.32 px'), findsOneWidget);
    expect(find.textContaining('"'), findsNothing);
  });

  testWidgets('each strip item reads as one label with its value',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    expect(find.bySemanticsLabel('Filter: L'), findsOneWidget);
    expect(find.bySemanticsLabel('RMS: 0.45 px'), findsOneWidget);
    handle.dispose();
  });
}
