/// The Darkroom screen: the landing state, a pass, and the Edit tab.
///
/// `/darkroom?tab=edit` (or a `master` / `recipe` parameter) opens the Edit
/// tab, whose body is [DarkroomEditTab]. A bare `/darkroom` lists what there is
/// to open, and `/darkroom?pass=<runId>` shows a pass.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../utils/darkroom_navigation.dart';
import 'build_masters/build_job_banner.dart';
import 'build_masters_dialog.dart';
import 'darkroom_controller.dart';
import 'pass_view/darkroom_pass_page.dart';
import 'edit/edit_tab.dart';

part 'darkroom_screen_parts/_landing.dart';

/// The Darkroom screen.
class DarkroomScreen extends ConsumerStatefulWidget {
  /// What the route asked to open.
  final DarkroomScope scope;

  /// True when the route asked for the Edit tab by name.
  final bool editTab;

  const DarkroomScreen({super.key, required this.scope, this.editTab = false});

  @override
  ConsumerState<DarkroomScreen> createState() => _DarkroomScreenState();
}

class _DarkroomScreenState extends ConsumerState<DarkroomScreen> {
  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final scope = widget.scope;
    if (widget.editTab || scope.recipeId != null || scope.masterId != null) {
      return Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PageHeader(title: 'Darkroom', icon: SkotiqIcons.aperture),
              Expanded(
                child: DarkroomEditTab(
                  scope: scope.passRunId == null ? scope : null,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (ref.watch(isRemoteClientProvider)) {
      return _shell(
        colors: colors,
        context: 'Host-only processing',
        body: const EmptyState(
          icon: SkotiqIcons.device,
          title: 'Open the Darkroom on the imaging host',
          body: 'Linear masters and the recipe engine that renders them live '
              'on the imaging computer. Open Skotiq there to adjust, '
              'reorder, or export a recipe. Remote Darkroom editing is '
              'unavailable in this release.',
        ),
      );
    }

    // A bare `/darkroom` is a rail destination, so it lists what there is to
    // open instead of refusing.
    if (scope.isEmpty) {
      return Scaffold(
        backgroundColor: colors.background,
        body: const SafeArea(bottom: false, child: _DarkroomLandingView()),
      );
    }

    // A pass has no recipe and no controller: it is the record of a night
    // being calibrated, registered and integrated, live while it runs.
    return _shell(
      colors: colors,
      context: 'Pass',
      body: DarkroomPassPage(runId: scope.passRunId!),
    );
  }

  Widget _shell({
    required SkotiqColors colors,
    required String? context,
    required Widget body,
  }) {
    return Scaffold(
      backgroundColor: colors.background,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _leave,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _leave,
        },
        child: Focus(
          autofocus: true,
          includeSemantics: false,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                PageHeader(
                  title: 'Darkroom',
                  icon: SkotiqIcons.aperture,
                  context: context,
                  actions: [
                    SkotiqButton(
                      label: 'Back',
                      icon: SkotiqIcons.arrowLeft,
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      onPressed: _leave,
                    ),
                  ],
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _leave() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return;
    }
    context.go('/darkroom');
  }
}
