// qa-surfaces S29: after a restart the histogram overlay stayed on, but
// Crosshair, Star detection and "Save loop frames" came back off; the last
// one silently stopped saving the next night's loop frames.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_capture_bar.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_view_prefs.dart';
import 'package:skotiq_core/providers.dart';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Save loop frames survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    first.read(loopSavesFramesProvider);
    await first.read(loopSavesFramesProvider.notifier).set(true);
    first.dispose();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    second.read(loopSavesFramesProvider);
    await _settle();
    expect(second.read(loopSavesFramesProvider), isTrue);
  });

  test('crosshair and star detection survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    first.read(imagingViewPrefsBinderProvider);
    await _settle();
    first.read(imagingViewerStateProvider.notifier).toggleCrosshair();
    first.read(imagingViewerStateProvider.notifier).toggleStarOverlay();
    await _settle();
    first.dispose();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    second.read(imagingViewPrefsBinderProvider);
    await _settle();
    final state = second.read(imagingViewerStateProvider);
    expect(state.showCrosshair, isTrue);
    expect(state.showStarOverlay, isTrue);
  });
}
