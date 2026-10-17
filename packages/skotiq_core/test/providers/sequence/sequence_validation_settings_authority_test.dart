import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _DelayedSettingsNotifier extends AppSettingsNotifier {
  _DelayedSettingsNotifier(this.completer);

  final Completer<AppSettingsState> completer;

  @override
  Future<AppSettingsState> build() => completer.future;
}

final _validatorProvider = Provider<SequenceValidatorService>((ref) {
  return SequenceValidatorService(
    ref: ref,
    syncRules: const [],
    refAwareRules: const [],
    asyncRules: const [],
  );
});

void main() {
  test('full validation waits for authoritative settings', () async {
    final settings = Completer<AppSettingsState>();
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _DelayedSettingsNotifier(settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    final root = InstructionSetNode(id: 'root', name: 'Sequence');
    final sequence = Sequence.create(
      name: 'Fresh startup plan',
      nodes: {root.id: root},
      rootNodeId: root.id,
    );
    var completed = false;
    final validation = container
        .read(_validatorProvider)
        .validate(sequence)
        .whenComplete(() => completed = true);

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    settings.complete(const AppSettingsState());
    final result = await validation;

    expect(completed, isTrue);
    expect(result.issues, isEmpty);
  });
}
