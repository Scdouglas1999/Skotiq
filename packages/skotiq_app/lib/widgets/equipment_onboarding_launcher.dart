import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../router/app_router.dart';
import '../utils/startup_ui_context.dart';

/// Wraps the app shell and routes a brand-new user (no profiles, no
/// onboarding completion record) into `/onboarding` on first launch.
///
/// Why a launcher widget rather than a router redirect: GoRouter
/// redirects fire on every navigation, and we only want to forcibly
/// route on the first frame after app launch. Inside the launcher we
/// also defer the check so any higher-priority startup dialogs
/// (database recovery, session recovery) get to render first.
class EquipmentOnboardingLauncher extends ConsumerStatefulWidget {
  final Widget child;

  const EquipmentOnboardingLauncher({super.key, required this.child});

  @override
  ConsumerState<EquipmentOnboardingLauncher> createState() =>
      _EquipmentOnboardingLauncherState();
}

class _EquipmentOnboardingLauncherState
    extends ConsumerState<EquipmentOnboardingLauncher> {
  bool _hasChecked = false;
  Timer? _deferTimer;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _checkGeneration = 0;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        // Onboarding is host-specific because the equipment profiles live on
        // the active rig. Retire a pending result and evaluate the new host.
        _checkGeneration++;
        _hasChecked = false;
        ref.invalidate(shouldRunEquipmentOnboardingProvider);
        _scheduleCheck(delay: const Duration(milliseconds: 100));
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleCheck());
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    _checkGeneration++;
    _deferTimer?.cancel();
    super.dispose();
  }

  void _scheduleCheck({
    Duration delay = const Duration(milliseconds: 800),
  }) {
    if (_hasChecked || !mounted) return;
    // Defer by 800 ms so that DatabaseRecoveryLauncher and any session
    // recovery flow get to claim the navigator first. Once those flows
    // have rendered, the navigator is stable enough to push /onboarding.
    _deferTimer?.cancel();
    _deferTimer = Timer(delay, () => unawaited(_maybeLaunch()));
  }

  Future<void> _maybeLaunch() async {
    if (_hasChecked || !mounted) return;
    _hasChecked = true;
    final authority = ref.read(backendProvider);
    final generation = ++_checkGeneration;

    try {
      final shouldRun =
          await ref.read(shouldRunEquipmentOnboardingProvider.future);
      if (!_isCurrentCheck(authority, generation)) return;
      if (!shouldRun) return;

      // Only auto-launch if the user is still parked on the default
      // dashboard route — otherwise they navigated somewhere themselves
      // and we shouldn't yank them away.
      //
      // Why ref.read(appRouterProvider) instead of GoRouter.of(context):
      // this widget sits above MaterialApp.router in the widget tree, so
      // there is no GoRouter ancestor and GoRouter.of returns null. The
      // provider exposes the same singleton instance directly.
      final router = ref.read(appRouterProvider);
      final currentLocation =
          router.routerDelegate.currentConfiguration.uri.toString();
      if (_isCurrentCheck(authority, generation) &&
          (currentLocation == '/' || currentLocation == '/dashboard')) {
        router.go('/onboarding');
      }
    } catch (error, stackTrace) {
      if (!_isCurrentCheck(authority, generation)) return;
      ref.read(loggingServiceProvider).warning(
        '[EquipmentOnboarding] Could not evaluate startup gate: $error',
        source: 'EquipmentOnboardingLauncher',
        fields: {'stackTrace': stackTrace.toString()},
      );
      if (!mounted) return;
      final uiContext = resolveStartupUiContext(ref, context);
      if (uiContext == null || !uiContext.mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(uiContext);
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          content: const Text(
            'Skotiq could not check whether equipment setup is needed.',
          ),
          duration: const Duration(days: 1),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              if (!mounted) return;
              _hasChecked = false;
              ref.invalidate(shouldRunEquipmentOnboardingProvider);
              _scheduleCheck(delay: Duration.zero);
            },
          ),
        ),
      );
    }
  }

  bool _isCurrentCheck(SkotiqBackend authority, int generation) {
    return mounted &&
        generation == _checkGeneration &&
        identical(ref.read(backendProvider), authority);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
