import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'nullable copyWith fields preserve omissions and allow explicit clear',
    () {
      const state = DarkLibraryUiState(
        activeMutation: DarkLibraryMutation.cleanOrphans,
        statusMessage: 'working',
        errorMessage: 'old error',
        selectedGroupIndex: 4,
      );

      final preserved = state.copyWith(isCreatingMaster: true);
      expect(preserved.activeMutation, DarkLibraryMutation.cleanOrphans);
      expect(preserved.statusMessage, 'working');
      expect(preserved.errorMessage, 'old error');
      expect(preserved.selectedGroupIndex, 4);

      final cleared = preserved.copyWith(
        activeMutation: null,
        statusMessage: null,
        errorMessage: null,
        selectedGroupIndex: null,
      );
      expect(cleared.activeMutation, isNull);
      expect(cleared.statusMessage, isNull);
      expect(cleared.errorMessage, isNull);
      expect(cleared.selectedGroupIndex, isNull);
    },
  );

  test(
    'maintenance mutations are single-flight and unlock after completion',
    () async {
      final backend = _MockNetworkBackend();
      final gate = Completer<int>();
      when(
        () => backend.cleanDarkLibraryOrphans(),
      ).thenAnswer((_) => gate.future);
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(darkLibraryNotifierProvider.notifier);

      final first = notifier.cleanOrphans();
      expect(
        container.read(darkLibraryNotifierProvider).activeMutation,
        DarkLibraryMutation.cleanOrphans,
      );

      await notifier.cleanOrphans();
      await expectLater(
        notifier.deleteGroup(
          const DarkGroupKey(
            exposureTime: 30,
            gain: 100,
            offset: 10,
            binX: 1,
            binY: 1,
            frameType: 'dark',
          ),
        ),
        throwsStateError,
      );
      verify(() => backend.cleanDarkLibraryOrphans()).called(1);
      verifyNever(
        () => backend.deleteDarkLibraryGroup(
          exposureTime: 30,
          gain: 100,
          offset: 10,
          binX: 1,
          binY: 1,
          frameType: 'dark',
          deleteFiles: false,
        ),
      );

      gate.complete(2);
      await first;
      final completed = container.read(darkLibraryNotifierProvider);
      expect(completed.isBusy, isFalse);
      expect(completed.activeMutation, isNull);
      expect(completed.statusMessage, 'Removed 2 orphaned entries.');
      expect(completed.errorMessage, isNull);

      await notifier.cleanOrphans();
      verify(() => backend.cleanDarkLibraryOrphans()).called(1);
    },
  );
}
