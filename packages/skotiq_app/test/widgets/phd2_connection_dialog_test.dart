// The PHD2 connection dialog must surface a settings-persistence failure (not
// swallow it) and must NOT connect against unsaved values.
//
// A remote client that has not completed a successful host settings fetch
// refuses settings writes (they would clobber the host with local defaults), so
// `setPhd2Host` throws — exactly the fire-and-forget failure the dialog has to
// catch and report.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/phd2_connection_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

ProviderScope _testScope({
  required _MockNetworkBackend backend,
  required Widget child,
}) {
  final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      loggingServiceProvider.overrideWithValue(LoggingService()),
    ],
    child: child,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(const AppSettings());
  });

  testWidgets('host and port remain reachable above a landscape keyboard',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(932, 430);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());

    await tester.pumpWidget(
      _testScope(
        backend: backend,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const Phd2ConnectionDialog(
                    initialHost: 'localhost',
                    initialPort: 4400,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final host = find.widgetWithText(TextField, 'Host');
    final port = find.widgetWithText(TextField, 'Port');
    await tester.tap(host);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 230);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(host.hitTestable(), findsOneWidget);
    final editable = tester.widget<EditableText>(
      find.descendant(of: host, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.ensureVisible(port);
    await tester.pumpAndSettle();
    expect(port.hitTestable(), findsOneWidget);
  });

  testWidgets('a settings save failure surfaces and does not connect',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    // Host fetch fails -> notifier holds defaults + refuses writes, so the
    // host/port save inside the dialog throws.
    when(() => backend.getSettings()).thenThrow(StateError('host offline'));

    await tester.pumpWidget(
      _testScope(
        backend: backend,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Phd2ConnectionDialog(
              initialHost: 'localhost',
              initialPort: 4400,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.textContaining('Could not save PHD2 connection settings'),
      findsOneWidget,
    );
    // Never attempted a connection against unsaved values.
    verifyNever(
      () => backend.phd2Connect(
        host: any(named: 'host'),
        port: any(named: 'port'),
      ),
    );
  });

  testWidgets('a connection failure keeps the endpoint and retry dialog open',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getSettings()).thenAnswer(
      (_) async => const AppSettings(phd2Host: 'bad-host', phd2Port: 4400),
    );
    when(
      () => backend.updateSettingsWithCommandId(
        any(),
        commandId: any(named: 'commandId'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => backend.phd2Connect(host: 'bad-host', port: 4400),
    ).thenThrow(StateError('connection refused'));

    await tester.pumpWidget(
      _testScope(
        backend: backend,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Phd2ConnectionDialog(
              initialHost: 'bad-host',
              initialPort: 4400,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Phd2ConnectionDialog)),
    );
    await container.read(appSettingsProvider.future);
    await tester.pump();

    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(Phd2ConnectionDialog), findsOneWidget);
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .join(' | ');
    expect(
      find.textContaining('PHD2 connection failed'),
      findsOneWidget,
      reason: visibleText,
    );
    expect(find.textContaining('Bad state:'), findsNothing);
    expect(find.text('Connect'), findsOneWidget);
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.controller!.text, 'bad-host');
    expect(fields.last.controller!.text, '4400');
    verify(
      () => backend.phd2Connect(host: 'bad-host', port: 4400),
    ).called(1);
    final saved = verify(
      () => backend.updateSettingsWithCommandId(
        captureAny(),
        commandId: any(named: 'commandId'),
      ),
    ).captured.single as AppSettings;
    expect(saved.phd2Host, 'bad-host');
    expect(saved.phd2Port, 4400);
  });

  testWidgets('invalid port is rejected instead of silently using 4400',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getSettings()).thenAnswer(
      (_) async => const AppSettings(phd2Host: 'localhost', phd2Port: 4400),
    );

    await tester.pumpWidget(
      _testScope(
        backend: backend,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Phd2ConnectionDialog(
              initialHost: 'localhost',
              initialPort: 4400,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    fields.last.controller!.text = 'not-a-port';

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.byType(Phd2ConnectionDialog), findsOneWidget);
    expect(find.textContaining('port between 1 and 65535'), findsOneWidget);
    verifyNever(
      () => backend.phd2Connect(
        host: any(named: 'host'),
        port: any(named: 'port'),
      ),
    );
    verifyNever(
      () => backend.updateSettingsWithCommandId(
        any(),
        commandId: any(named: 'commandId'),
      ),
    );
  });

  testWidgets('pending connection cannot be dismissed', (tester) async {
    final backend = _MockNetworkBackend();
    final connect = Completer<void>();
    when(() => backend.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getSettings()).thenAnswer(
      (_) async => const AppSettings(phd2Host: 'localhost', phd2Port: 4400),
    );
    when(
      () => backend.updateSettingsWithCommandId(
        any(),
        commandId: any(named: 'commandId'),
      ),
    ).thenAnswer((_) async {});
    when(() => backend.phd2Connect(host: 'localhost', port: 4400))
        .thenAnswer((_) => connect.future);

    await tester.pumpWidget(
      _testScope(
        backend: backend,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Phd2ConnectionDialog(
              initialHost: 'localhost',
              initialPort: 4400,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Phd2ConnectionDialog)),
    );
    await container.read(appSettingsProvider.future);

    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();

    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(Phd2ConnectionDialog), findsOneWidget);
  });
}
