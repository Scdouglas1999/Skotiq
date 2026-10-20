// pumpAppScreen: ergonomic widget-test bootstrap for skotiq_app screens.
//
// Mirrors the production override surface from apps/desktop/lib/main.dart so
// a test pumping (say) NightControlScreen sees the same provider graph the
// shipped desktop GUI initialises. The harness wires:
//
//   - backendProvider       -> MockBackend via TestBackendNotifier
//   - databaseProvider      -> in-memory SkotiqDatabase
//   - appVersionProvider    -> fixed AppVersionInfo (production throws)
//
// Tests append additional overrides via [extraOverrides]; those win because
// Riverpod resolves the override list left-to-right and later entries
// shadow earlier ones.
//
// Why a plain function instead of a TestHarness class: widget tests already
// have heavy ceremony (binding init, `tester.pumpWidget`, etc.). A free
// function with named parameters keeps the call sites short and lets the
// test see (and override) every dependency at the call site. The trade-off
// is no "shared state" between calls — each test builds its own database
// and mock backend. That's intentional: shared state across pumps is the
// #1 source of flaky widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'mock_backend.dart';
import 'mock_database.dart';

/// Test-only subclass of [BackendNotifier] that bypasses the real
/// [BackendNotifier.useLocalBackend]/`.connect` logic and pins the state to
/// a pre-built [SkotiqBackend] (typically a [MockBackend]).
///
/// Why this exists: `backendProvider` is a `StateNotifierProvider` whose
/// initial state is a `DisconnectedBackend` and which switches state via
/// methods that touch `databaseProvider` and try to build an `FfiBackend`.
/// Overriding the *value* isn't possible directly — Riverpod only lets you
/// override the notifier factory. So we substitute the factory with a
/// subclass that skips the real wiring and just emits the test backend.
class TestBackendNotifier extends BackendNotifier {
  TestBackendNotifier(super.ref, SkotiqBackend backend) {
    // Why ignored: BackendNotifier.state is a protected field on
    // StateNotifier; the recommended way to seed state for tests is to set
    // it from a subclass constructor.
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

/// Resolved set of harness inputs returned to tests so they can inspect /
/// drive the mocked dependencies after pumping. Tests rarely need this
/// (most just call `pumpAppScreen(...)` and then assert with `find.*`), but
/// long-form tests want to:
///
/// - register additional `when(...)` stubs on the [backend] after pump,
/// - seed the [database] with rows, or
/// - close everything in `tearDown`.
class HarnessHandle {
  /// Backend wired into [backendProvider]. Already has `eventStream` and
  /// `polarAlignmentEvents` stubbed by [mockBackend]; add more stubs as
  /// needed.
  final MockBackend backend;

  /// In-memory database wired into [databaseProvider]. Test code can call
  /// DAO methods directly to seed rows before pumping additional frames.
  final SkotiqDatabase database;

  /// Provider container shared by the widget tree. Useful for reading
  /// arbitrary providers in test bodies (`handle.container.read(...)`).
  final ProviderContainer container;

  HarnessHandle({
    required this.backend,
    required this.database,
    required this.container,
  });
}

/// Pump [screen] inside a ProviderScope + MaterialApp with the standard
/// skotiq_app harness wiring.
///
/// Returns a [HarnessHandle] for tests that need post-pump access to the
/// mock backend and in-memory database.
///
/// Close `handle.database` from an `addTearDown`. Screen-specific fakes go in
/// `extraOverrides`.
///
/// [size] sets the surface dimensions so layout-sensitive widgets pick the
/// right responsive branch. Defaults to a desktop-ish 1280x800; pass
/// `const Size(360, 740)` for mobile-portrait. The harness clears the
/// override automatically when the test ends.
///
/// [settle] controls whether to call `tester.pumpAndSettle()` after the
/// initial pump. Defaults to `true`. Set to `false` for screens that have
/// long-running animations or polling timers — those will trip
/// `pumpAndSettle`'s 10-second timeout otherwise.
Future<HarnessHandle> pumpAppScreen(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(1280, 800),
  List<Override> extraOverrides = const [],
  MockBackend? backend,
  SkotiqDatabase? database,
  AppVersionInfo? appVersion,
  bool settle = true,
  ThemeData? theme,
  bool registerTearDown = true,
  Locale? locale,
}) async {
  // Why force devicePixelRatio = 1.0: physicalSize is in physical pixels.
  // Leaving the host system's ratio (Retina = 2.0+) makes the surface half
  // the expected logical size and surprises responsive screens that branch
  // on width thresholds.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final resolvedBackend = backend ?? mockBackend();
  final resolvedDatabase = database ?? mockDatabase();
  // Why close the DB ourselves only if we built it: tests that pass in
  // their own [database] own its lifecycle and may need to keep reading it
  // after the widget tree tears down (e.g. to assert mutations).
  if (database == null && registerTearDown) {
    addTearDown(resolvedDatabase.close);
  }

  final resolvedAppVersion =
      appVersion ?? const AppVersionInfo(version: '0.0.0-test', buildNumber: 0);

  // Why a separately-created ProviderContainer: handing the same container
  // to UncontrolledProviderScope lets the test reach into the graph after
  // pump (handle.container.read(...)) without rebuilding the tree.
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => TestBackendNotifier(ref, resolvedBackend),
      ),
      databaseProvider.overrideWithValue(resolvedDatabase),
      appVersionProvider.overrideWithValue(resolvedAppVersion),
      ...extraOverrides,
    ],
  );
  if (registerTearDown) {
    addTearDown(container.dispose);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        // Default to SkotiqTheme.dark to match production GUI. Tests
        // doing golden-image diffs against the light theme can override.
        theme: theme ?? SkotiqTheme.dark,
        // Only wired when a test asks for a locale: installing the delegates
        // unconditionally would change what every existing test's tree
        // resolves for Material/Cupertino strings. With [locale] null,
        // `SkotiqLocalizations.of` falls back to `en`, which is what the
        // whole suite has always asserted against.
        locale: locale,
        localizationsDelegates:
            locale == null ? null : SkotiqLocalizations.localizationsDelegates,
        supportedLocales: locale == null
            ? const [Locale('en', 'US')]
            : SkotiqLocalizations.supportedLocales,
        home: Scaffold(body: screen),
      ),
    ),
  );

  if (settle) {
    // Why a guarded pumpAndSettle: some screens schedule one-shot timers
    // (e.g. shimmer/loading) and we want them to drain. A bare `pump()` is
    // not enough; a `pumpAndSettle()` without timeout is dangerous if a
    // periodic animation slips in. 5 seconds matches Flutter's own widget
    // testing convention.
    await tester.pumpAndSettle(const Duration(seconds: 5));
  } else {
    await tester.pump();
  }

  return HarnessHandle(
    backend: resolvedBackend,
    database: resolvedDatabase,
    container: container,
  );
}

/// Convenience finder by `Key(ValueKey(name))` for tests that adopt the
/// data-key convention. Why a helper: typing
/// `find.byKey(const ValueKey('cam-status'))` is noisy and easy to typo.
/// Production widgets tagged with `key: const ValueKey('cam-status')` can
/// be located with `findByDataKey('cam-status')`.
Finder findByDataKey(String key) => find.byKey(ValueKey<String>(key));
