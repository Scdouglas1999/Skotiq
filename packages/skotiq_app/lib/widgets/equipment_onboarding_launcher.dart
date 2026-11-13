import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../router/app_router.dart';
import '../router/app_routes.dart';
import '../startup/startup_surface_queue.dart';
import '../utils/startup_ui_context.dart';

/// Wraps the app shell and routes a brand-new user (no profiles, no
/// onboarding completion record) into `/onboarding` on first launch.
///
/// Why a launcher widget rather than a router redirect: GoRouter
/// redirects fire on every navigation, and we only want to forcibly
/// route on the first frame after app launch. The move to `/onboarding`
/// takes its turn in the [StartupSurfaceQueue], after the recovery and
/// Quick Start prompts have been answered.
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
  late final StartupSurfaceQueue _queue;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _checkGeneration = 0;

  @override
  void initState() {
    super.initState();
    _queue = ref.read(startupSurfaceQueueProvider)
      ..expect(StartupSurface.equipmentOnboarding);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        // Onboarding is host-specific because the equipment profiles live on
        // the active rig. Retire a pending result and evaluate the new host.
        _checkGeneration++;
        _hasChecked = false;
        ref.invalidate(shouldRunEquipmentOnboardingProvider);
        unawaited(_maybeLaunch());
      },
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_maybeLaunch()),
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    _checkGeneration++;
    _queue.pass(StartupSurface.equipmentOnboarding);
    super.dispose();
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
      if (!shouldRun) {
        _queue.pass(StartupSurface.equipmentOnboarding);
        return;
      }

      // Only auto-launch if the user is still parked on the default
      // dashboard route — otherwise they navigated somewhere themselves
      // and we shouldn't yank them away.
      //
      // Why ref.read(appRouterProvider) instead of GoRouter.of(context):
      // this widget sits above MaterialApp.router in the widget tree, so
      // there is no GoRouter ancestor and GoRouter.of returns null. The
      // provider exposes the same singleton instance directly.
      await _queue.turn<void>(StartupSurface.equipmentOnboarding, () async {
        final router = ref.read(appRouterProvider);
        final currentLocation =
            router.routerDelegate.currentConfiguration.uri.toString();
        if (_isCurrentCheck(authority, generation) &&
            (currentLocation == '/' ||
                currentLocation == AppRoute.tonight.path)) {
          router.go(AppRoute.onboarding.path);
        }
      });
    } catch (error, stackTrace) {
      _queue.pass(StartupSurface.equipmentOnboarding);
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
              unawaited(_maybeLaunch());
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
