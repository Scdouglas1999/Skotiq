import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/connection_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Connection settings render release-scoped platform capabilities',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: ConnectionSettings(),
          ),
        ),
      ),
    );

    await tester.pump();

    final platform =
        PlatformCapabilityMatrix.normalizePlatform(Platform.operatingSystem);
    expect(find.text('Platform capabilities'.toUpperCase()), findsOneWidget);
    expect(find.text('Current platform: ${_platformLabel(platform)}'),
        findsOneWidget);
    expect(find.text('ASCOM COM'), findsOneWidget);
    expect(
      find.textContaining('Windows-only ASCOM driver installations'),
      findsOneWidget,
    );
    expect(find.text('ASCOM Alpaca'), findsOneWidget);
    expect(find.text('Native SDK'), findsOneWidget);
    expect(find.text('Capability-gated'), findsNWidgets(2));
    expect(find.textContaining('packaged libraries'), findsOneWidget);
    expect(find.text('INDI'), findsOneWidget);
    expect(find.textContaining('reachable INDI server'), findsOneWidget);
    expect(find.text('Simulator'), findsOneWidget);
    expect(find.textContaining('Workflow simulators'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

String _platformLabel(String platform) {
  switch (platform) {
    case PlatformCapabilityMatrix.windows:
      return 'Windows';
    case PlatformCapabilityMatrix.linux:
      return 'Linux';
    case PlatformCapabilityMatrix.macos:
      return 'macOS';
    default:
      return platform;
  }
}
