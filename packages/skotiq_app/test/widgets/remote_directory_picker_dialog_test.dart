// Concurrency / error-handling net for RemoteDirectoryPickerDialog.
//
// The picker browses a *remote* host over the network, so every browse and
// validate is an async round-trip that can outlive the dialog, arrive out of
// order, or land after the backend has been swapped (reconnect/disconnect).
// These tests pin the trust/reliability contract:
//
//   * close-during-load           -> no setState-after-dispose crash
//   * out-of-order navigation     -> a stale earlier browse never clobbers the
//                                    latest folder
//   * old-backend swap            -> stale host data never appears; the user
//                                    gets an actionable error
//   * browse failure + Retry      -> the list is replaced by a Retry affordance
//   * validation failure          -> the list is preserved and the error shows
//                                    as a banner (selection semantics kept)
//   * validation single-flight    -> repeated taps validate/pop exactly once
//
// The backend is a mocktail double implementing NetworkBackend (the dialog
// gates on `backend is NetworkBackend`), wired through a swappable
// BackendNotifier so a test can replace the live backend mid-flight.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/remote_directory_picker_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// BackendNotifier that pins a test backend and lets a test swap it at runtime
/// (simulating a reconnect/disconnect while a browse or validate is pending).
class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

RemoteDirectoryListing _listing({
  String? currentPath,
  String? parentPath,
  List<RemoteDirectoryEntry> directories = const [],
}) {
  return RemoteDirectoryListing(
    currentPath: currentPath,
    parentPath: parentPath,
    directories: directories,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A pending-forever validation return needs no fallback, but any() on the
  // named bool args does not require registration either — all args are
  // primitives, so mocktail resolves them without a fallback value.

  /// Pump a host screen with an "open" button that shows the picker and
  /// records its pop result. Returns the swappable notifier so tests can swap
  /// the backend mid-flight.
  Future<_SwappableBackendNotifier> pumpHost(
    WidgetTester tester,
    NetworkBackend backend, {
    String? initialPath,
    required List<String?> resultSink,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier =
        container.read(backendProvider.notifier) as _SwappableBackendNotifier;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final result = await RemoteDirectoryPickerDialog.show(
                      context,
                      title: 'Select host folder',
                      initialPath: initialPath,
                    );
                    resultSink.add(result);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return notifier;
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    // Two frames: one to start the dialog route, one to advance its transition.
    // (No pumpAndSettle — the loading spinner animates forever.)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('close during load does not setState after dispose',
      (tester) async {
    final backend = _MockNetworkBackend();
    final browse = Completer<RemoteDirectoryListing>();
    when(() => backend.browseRemoteDirectories(path: any(named: 'path')))
        .thenAnswer((_) => browse.future);

    final results = <String?>[];
    await pumpHost(tester, backend, initialPath: '/data', resultSink: results);
    await openDialog(tester);

    // Dialog is mid-load (spinner). Close it via Cancel.
    expect(find.byType(SkotiqMark), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Late browse response arrives after the dialog is gone.
    browse.complete(_listing(currentPath: '/data'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(results, [null]);
  });

  testWidgets('out-of-order navigation: stale browse never clobbers the latest',
      (tester) async {
    final backend = _MockNetworkBackend();
    final initial = Completer<RemoteDirectoryListing>();
    final alpha = Completer<RemoteDirectoryListing>();
    final beta = Completer<RemoteDirectoryListing>();
    when(() => backend.browseRemoteDirectories(path: '/data'))
        .thenAnswer((_) => initial.future);
    when(() => backend.browseRemoteDirectories(path: '/data/alpha'))
        .thenAnswer((_) => alpha.future);
    when(() => backend.browseRemoteDirectories(path: '/data/beta'))
        .thenAnswer((_) => beta.future);

    final results = <String?>[];
    await pumpHost(tester, backend, initialPath: '/data', resultSink: results);
    await openDialog(tester);

    initial.complete(_listing(
      currentPath: '/data',
      directories: const [
        RemoteDirectoryEntry(name: 'alpha', path: '/data/alpha'),
        RemoteDirectoryEntry(name: 'beta', path: '/data/beta'),
      ],
    ));
    await tester.pump();
    await tester.pump();

    // Navigate into alpha then beta WITHOUT pumping between taps, so both
    // browses are in flight against the still-visible list.
    final chevrons = find.byIcon(LucideIcons.chevronRight);
    expect(chevrons, findsNWidgets(2));
    await tester.tap(chevrons.first); // alpha (generation N)
    await tester.tap(chevrons.at(1)); // beta   (generation N+1)
    await tester.pump();

    // Resolve beta (latest) first, then alpha (stale) late.
    beta.complete(_listing(currentPath: '/data/beta'));
    await tester.pump();
    await tester.pump();
    alpha.complete(_listing(currentPath: '/data/alpha'));
    await tester.pump();
    await tester.pump();

    // The current-path chip must show beta, and the stale alpha listing must
    // not have overwritten it.
    expect(find.text('/data/beta'), findsOneWidget);
    expect(find.text('/data/alpha'), findsNothing);
  });

  testWidgets('backend swap mid-load surfaces an error, not stale host data',
      (tester) async {
    final backend1 = _MockNetworkBackend();
    final backend2 = _MockNetworkBackend();
    final initial = Completer<RemoteDirectoryListing>();
    final alpha = Completer<RemoteDirectoryListing>();
    when(() => backend1.browseRemoteDirectories(path: '/data'))
        .thenAnswer((_) => initial.future);
    when(() => backend1.browseRemoteDirectories(path: '/data/alpha'))
        .thenAnswer((_) => alpha.future);

    final results = <String?>[];
    final notifier = await pumpHost(
      tester,
      backend1,
      initialPath: '/data',
      resultSink: results,
    );
    await openDialog(tester);

    initial.complete(_listing(
      currentPath: '/data',
      directories: const [
        RemoteDirectoryEntry(name: 'alpha', path: '/data/alpha'),
      ],
    ));
    await tester.pump();
    await tester.pump();

    // Navigate into alpha (browse in flight against backend1)...
    await tester.tap(find.byIcon(LucideIcons.chevronRight).first);
    await tester.pump();

    // ...then the connection swaps to a different host.
    notifier.swap(backend2);
    alpha.complete(_listing(
      currentPath: '/data/alpha',
      directories: const [
        RemoteDirectoryEntry(name: 'ghost', path: '/data/alpha/ghost'),
      ],
    ));
    await tester.pump();
    await tester.pump();

    expect(
        find.textContaining('connection to the host changed'), findsOneWidget);
    expect(find.text('/data/alpha'), findsNothing);
    expect(find.text('ghost'), findsNothing);
  });

  testWidgets('browse failure shows an actionable Retry that reloads',
      (tester) async {
    final backend = _MockNetworkBackend();
    var calls = 0;
    when(() => backend.browseRemoteDirectories(path: any(named: 'path')))
        .thenAnswer((_) async {
      calls++;
      if (calls == 1) {
        throw Exception('network down');
      }
      return _listing(
        currentPath: '/data',
        directories: const [
          RemoteDirectoryEntry(name: 'alpha', path: '/data/alpha'),
        ],
      );
    });

    final results = <String?>[];
    await pumpHost(tester, backend, initialPath: '/data', resultSink: results);
    await openDialog(tester);

    expect(find.textContaining('Could not browse host directories'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Retry'), findsNothing);
    expect(find.text('alpha'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('validation failure keeps the list and shows a banner',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.browseRemoteDirectories(path: any(named: 'path')))
        .thenAnswer(
      (_) async => _listing(
        currentPath: '/data',
        directories: const [
          RemoteDirectoryEntry(name: 'alpha', path: '/data/alpha'),
        ],
      ),
    );
    when(() => backend.validateRemoteDirectory(
          any(),
          mustExist: any(named: 'mustExist'),
          mustBeWritable: any(named: 'mustBeWritable'),
        )).thenAnswer(
      (_) async => {'valid': false, 'error': 'Host folder is read-only'},
    );

    final results = <String?>[];
    await pumpHost(tester, backend, initialPath: '/data', resultSink: results);
    await openDialog(tester);

    await tester.tap(find.text('Use this folder'));
    await tester.pump();
    await tester.pump();

    // Banner shows the host's reason; the folder list is still there; the
    // dialog stayed open (no pop).
    expect(find.text('Host folder is read-only'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('validation is single-flight: repeated taps validate/pop once',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.browseRemoteDirectories(path: any(named: 'path')))
        .thenAnswer(
      (_) async => _listing(
        currentPath: '/data',
        directories: const [
          RemoteDirectoryEntry(name: 'alpha', path: '/data/alpha'),
        ],
      ),
    );
    final validate = Completer<Map<String, dynamic>>();
    when(() => backend.validateRemoteDirectory(
          any(),
          mustExist: any(named: 'mustExist'),
          mustBeWritable: any(named: 'mustBeWritable'),
        )).thenAnswer((_) => validate.future);

    final results = <String?>[];
    await pumpHost(tester, backend, initialPath: '/data', resultSink: results);
    await openDialog(tester);

    // Two rapid taps while the validation round-trip is pending.
    await tester.tap(find.text('Use this folder'));
    await tester.tap(find.text('Use this folder'));
    await tester.pump();

    verify(() => backend.validateRemoteDirectory(
          any(),
          mustExist: any(named: 'mustExist'),
          mustBeWritable: any(named: 'mustBeWritable'),
        )).called(1);

    // Cancel, the modal barrier, and system back must not turn a validation
    // that is still committing into an apparent cancellation.
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.tapAt(const Offset(4, 4));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(results, isEmpty);

    validate.complete({'valid': true, 'normalizedPath': '/data/normalized'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(results, ['/data/normalized']);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
