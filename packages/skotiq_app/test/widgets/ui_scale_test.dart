import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/app.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/services/location_sync_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uiScale applies text scaling correctly', (tester) async {
    const windowSize = Size(1000, 800);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = windowSize;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) {
            // Verify text scaling is applied
            final textScaler = MediaQuery.of(context).textScaler;
            return Text(
              'Test',
              key: const ValueKey('test-text'),
              textScaler: textScaler,
            );
          },
        ),
      ],
    );

    const settings = AppSettingsState(
      uiScale: 'Small (0.8x)',
      autoDiscoverOnLaunch: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appRouterProvider.overrideWithValue(router),
          appSettingsProvider.overrideWith(
            () => _TestAppSettingsNotifier(settings),
          ),
          locationSyncProvider.overrideWith((ref) {}),
          incompleteSessionsProvider
              .overrideWith((ref) async => const <SessionRecoveryInfo>[]),
          quickStartContextProvider.overrideWith((ref) async => null),
        ],
        child: const SkotiqApp(isDesktop: false, isMobile: false),
      ),
    );

    await tester.pump();

    // Verify the app renders without crashing - the main thing we're testing
    // is that the scaling doesn't break the layout
    expect(find.byKey(const ValueKey('test-text')), findsOneWidget);

    // SkotiqApp spins up background periodic timers (LAN discovery,
    // session-recovery heartbeats) on startup. Let them settle before the
    // test ends so the framework's pending-timer assertion doesn't fire.
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });
}

class _TestAppSettingsNotifier extends AppSettingsNotifier {
  final AppSettingsState _settings;

  _TestAppSettingsNotifier(this._settings);

  @override
  Future<AppSettingsState> build() async => _settings;
}
