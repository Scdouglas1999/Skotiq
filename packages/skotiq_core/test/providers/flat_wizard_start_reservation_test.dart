import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('flat wizard reserves startup while the save dialog is open', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(flatWizardProvider.notifier);

    expect(notifier.reserveStartPrompt(), isTrue);
    expect(notifier.isBusy, isTrue);
    expect(notifier.reserveStartPrompt(), isFalse);

    notifier.releaseStartPrompt();
    expect(notifier.isBusy, isFalse);
    expect(notifier.reserveStartPrompt(), isTrue);
  });
}
