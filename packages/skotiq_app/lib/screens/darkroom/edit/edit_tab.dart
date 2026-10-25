/// The Darkroom's Edit tab: every registered image on the left, the recipe
/// editor over the open one on the right.
///
/// Scoped by the route: `/darkroom?tab=edit&master=<id>` opens a registered
/// image (its newest recipe, or the offer to start one), `recipe=<id>` opens a
/// recipe by row id, and neither shows the list alone.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../darkroom_controller.dart' show DarkroomScope;
import 'channel_combine.dart';
import 'darkroom_editor.dart';
import 'darkroom_image_library.dart';

/// Width at and above which the image list sits beside an open editor.
const double kDarkroomEditListBreakpoint = 1100;

/// Width of the image list beside the editor.
const double kDarkroomEditListWidth = 280;

/// The scope the route names, or an empty scope.
DarkroomScope darkroomEditScopeFromUri(Uri uri) {
  int? id(String key) {
    final raw = uri.queryParameters[key];
    return raw == null ? null : int.tryParse(raw);
  }

  final recipe = id('recipe');
  if (recipe != null) return DarkroomScope.recipe(recipe);
  final master = id('master');
  if (master != null) return DarkroomScope.master(master);
  return const DarkroomScope.empty();
}

/// The Edit tab.
class DarkroomEditTab extends ConsumerWidget {
  /// What to open. Null reads `master` and `recipe` from the current route.
  final DarkroomScope? scope;

  const DarkroomEditTab({super.key, this.scope});

  DarkroomScope _scope(BuildContext context) {
    final given = scope;
    if (given != null) return given;
    final router = GoRouter.maybeOf(context);
    if (router == null) return const DarkroomScope.empty();
    return darkroomEditScopeFromUri(GoRouterState.of(context).uri);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(isRemoteClientProvider)) {
      return const _DarkroomEditRemoteGate();
    }
    final scope = _scope(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (scope.isEmpty) {
          return const _DarkroomImageList(selected: null, fill: true);
        }
        final listShown = constraints.maxWidth >= kDarkroomEditListBreakpoint;
        final editor = DarkroomEditor(
          key: ValueKey('darkroom_editor_$scope'),
          scope: scope,
          showSiblings: !listShown,
        );
        if (!listShown) return editor;
        final colors = SkotiqColors.of(context);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: kDarkroomEditListWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: colors.border)),
                ),
                child: _DarkroomImageList(selected: scope, fill: false),
              ),
            ),
            Expanded(child: editor),
          ],
        );
      },
    );
  }
}

/// Every registered image, grouped by target, with the way to combine a
/// target's per-filter masters.
class _DarkroomImageList extends ConsumerWidget {
  /// The open scope, whose image is highlighted; null when nothing is open.
  final DarkroomScope? selected;

  /// True when the list is the whole tab rather than a column beside the
  /// editor: it then centers a wider column and says what the tab is for.
  final bool fill;

  const _DarkroomImageList({required this.selected, required this.fill});

  bool _isSelected(DarkroomLibraryImage image) {
    final scope = selected;
    if (scope == null) return false;
    if (scope.masterId != null) return scope.masterId == image.master.id;
    final recipeId = scope.recipeId;
    return recipeId != null && image.recipes.any((r) => r.id == recipeId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final library = ref.watch(darkroomImageLibraryProvider);
    final body = library.when(
      loading: () => const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 28),
      ),
      error: (error, _) => EmptyState(
        icon: SkotiqIcons.imageOff,
        title: 'The image library could not be read',
        body: '$error',
        action: SkotiqButton(
          label: 'Try again',
          icon: SkotiqIcons.refresh,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => ref.invalidate(darkroomImageLibraryProvider),
        ),
      ),
      data: (targets) => targets.isEmpty
          ? EmptyState(
              icon: SkotiqIcons.image,
              title: 'No images to edit yet',
              body: 'Masters appear here once they are built. Build them for '
                  'a target from the Targets tab, or save a live stack as a '
                  'master from Imaging.',
              action: SkotiqButton(
                label: 'Go to Targets',
                icon: SkotiqIcons.arrowLeft,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () => context.go(darkroomTargetsLocation()),
              ),
            )
          : _list(context, colors, ref, targets),
    );
    if (!fill) return body;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: body,
      ),
    );
  }

  Widget _list(
    BuildContext context,
    SkotiqColors colors,
    WidgetRef ref,
    List<DarkroomLibraryTarget> targets,
  ) {
    final count = targets.fold<int>(0, (n, t) => n + t.images.length);
    final combinable = darkroomCombinableTargets(targets);
    final openTarget = targets
        .where((t) => t.images.any(_isSelected))
        .map((t) => t.name)
        .firstOrNull;
    return ListView(
      key: const ValueKey('darkroom_edit_image_list'),
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceLg,
      ),
      children: [
        if (fill) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
            ),
            child: Text(
              'Choose an image to edit. Every registered master and color '
              'composite opens here, with its recipes, variants and history.',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$count IMAGE${count == 1 ? '' : 'S'} · '
                '${targets.length} TARGET${targets.length == 1 ? '' : 'S'}',
                style: kDarkroomOverline.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              SkotiqButton(
                key: const ValueKey('darkroom_combine_channels'),
                label: 'Combine channels',
                icon: SkotiqIcons.layers,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                semanticsHint: combinable.isEmpty
                    ? 'No target has two or more per-filter masters yet'
                    : null,
                onPressed: combinable.isEmpty
                    ? null
                    : () => _combine(context, ref, targets, openTarget),
              ),
            ],
          ),
        ),
        for (final target in targets) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.spaceSm,
              SkotiqTokens.spaceLg,
              SkotiqTokens.spaceSm,
              SkotiqTokens.spaceXs,
            ),
            child: Text(
              target.name,
              style: SkotiqTypography.labelStrong.copyWith(
                color: colors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final image in target.images)
            _DarkroomImageRow(
              key: ValueKey('darkroom_edit_image_${image.master.id}'),
              image: image,
              selected: _isSelected(image),
            ),
        ],
      ],
    );
  }

  Future<void> _combine(
    BuildContext context,
    WidgetRef ref,
    List<DarkroomLibraryTarget> targets,
    String? openTarget,
  ) async {
    final id = await showDarkroomChannelCombineDialog(
      context,
      targets: targets,
      initialTarget: openTarget,
    );
    if (id == null || !context.mounted) return;
    ref.invalidate(darkroomImageLibraryProvider);
    context.go(darkroomRecipeLocation(id));
  }
}

/// One registered image: its preview, what it holds, and its recipes.
class _DarkroomImageRow extends StatelessWidget {
  final DarkroomLibraryImage image;
  final bool selected;

  const _DarkroomImageRow({
    super.key,
    required this.image,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final master = image.master;
    final recipes = image.recipes.length;
    final hours = describeIntegration(master.totalIntegrationSeconds);
    final meta = [
      if (master.frameCount > 0) '${master.frameCount} frames',
      if (master.totalIntegrationSeconds > 0) hours,
    ].join(' · ');
    final status = recipes == 0
        ? 'No recipe yet'
        : '$recipes recipe${recipes == 1 ? '' : 's'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        label: '${image.target} ${image.kind}'
            '${image.isColor ? ' color image' : ' master'}'
            '${meta.isEmpty ? '' : ', $meta'}, $status',
        excludeSemantics: true,
        onTap: selected
            ? null
            : () => context.go(darkroomMasterLocation(master.id)),
        child: Material(
          color: selected ? colors.surfaceHover : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            side: selected
                ? BorderSide(color: colors.primary.withValues(alpha: 0.4))
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: selected
                ? null
                : () => context.go(darkroomMasterLocation(master.id)),
            child: Padding(
              padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
              child: Row(
                children: [
                  _DarkroomImageThumb(image: image),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          image.kind,
                          style: SkotiqTypography.bodyStrong.copyWith(
                            color: colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (meta.isNotEmpty)
                          Text(
                            meta,
                            style: SkotiqTypography.monoXs.copyWith(
                              color: colors.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Text(
                          status,
                          style: SkotiqTypography.captionSm.copyWith(
                            color: recipes == 0
                                ? colors.textMuted
                                : colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The image's preview, decoded at thumbnail size, or a plain tile.
class _DarkroomImageThumb extends StatelessWidget {
  final DarkroomLibraryImage image;

  /// Side of the thumbnail.
  static const double size = 48;

  const _DarkroomImageThumb({required this.image});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final path = image.master.previewPngPath;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final placeholder = Container(
      color: colors.well,
      alignment: Alignment.center,
      child: Text(
        image.kind,
        style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
        maxLines: 1,
        overflow: TextOverflow.clip,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          ),
          child: path == null || path.isEmpty
              ? placeholder
              : Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  cacheWidth: (size * ratio * 2).round(),
                  errorBuilder: (_, __, ___) => placeholder,
                ),
        ),
      ),
    );
  }
}

/// What a remote client sees in the Edit tab: where the work lives, and the
/// same way out the editor has.
///
/// The editor renders a linear master through the native recipe engine, and
/// both the file and the engine live on the imaging host. Gated on the client
/// role, not on the connection: a desktop launched with `--remote-host` that
/// has not reached its rig yet owns none of the host's masters either.
class _DarkroomEditRemoteGate extends StatelessWidget {
  const _DarkroomEditRemoteGate();

  @override
  Widget build(BuildContext context) {
    void leave() => leaveDarkroomEdit(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): leave,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): leave,
      },
      child: Focus(
        autofocus: true,
        includeSemantics: false,
        child: EmptyState(
          icon: SkotiqIcons.device,
          title: 'Open the Darkroom on the imaging host',
          body: 'Linear masters and the recipe engine that renders them live '
              'on the imaging computer. Open Skotiq there to adjust, '
              'reorder, or export a recipe. Remote Darkroom editing is '
              'unavailable in this release.',
          action: Semantics(
            container: true,
            button: true,
            label: darkroomEditBackDestination(context),
            excludeSemantics: true,
            onTap: leave,
            child: SkotiqButton(
              key: const ValueKey('darkroom_remote_gate_back'),
              label: 'Go back',
              icon: SkotiqIcons.arrowLeft,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: leave,
            ),
          ),
        ),
      ),
    );
  }
}
