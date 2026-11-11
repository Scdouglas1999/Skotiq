import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../startup/startup_surface_queue.dart';
import '../utils/startup_ui_context.dart';
import 'your_sky_opt_in.dart';

/// Tells the user once, after Your Sky became opt-in, that it is now off on
/// this machine and how much atlas data it still holds, with Turn back on,
/// Keep off and Delete. Nothing is deleted unless the user confirms.
class YourSkyOffNoticeChecker extends ConsumerStatefulWidget {
  final Widget child;

  const YourSkyOffNoticeChecker({super.key, required this.child});

  @override
  ConsumerState<YourSkyOffNoticeChecker> createState() =>
      _YourSkyOffNoticeCheckerState();
}

class _YourSkyOffNoticeCheckerState
    extends ConsumerState<YourSkyOffNoticeChecker> {
  bool _checked = false;
  late final StartupSurfaceQueue _queue;

  @override
  void initState() {
    super.initState();
    _queue = ref.read(startupSurfaceQueueProvider)
      ..expect(StartupSurface.yourSkyOffNotice);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  @override
  void dispose() {
    _queue.pass(StartupSurface.yourSkyOffNotice);
    super.dispose();
  }

  Future<void> _check() async {
    if (_checked || !mounted) return;
    _checked = true;
    final int? bytes;
    try {
      bytes = await ref.read(skyAtlasOffNoticeProvider.future);
    } catch (e) {
      _queue.pass(StartupSurface.yourSkyOffNotice);
      ref.read(loggingServiceProvider).warning(
            'Could not check the Your Sky notice: $e',
            source: 'YourSkyOffNotice',
          );
      return;
    }
    if (bytes == null || !mounted) {
      _queue.pass(StartupSurface.yourSkyOffNotice);
      return;
    }
    await _queue.turn<void>(StartupSurface.yourSkyOffNotice, () async {
      final uiContext = resolveStartupUiContext(ref, context);
      if (uiContext == null || !uiContext.mounted) return;
      await showDialog<void>(
        context: uiContext,
        barrierDismissible: false,
        builder: (_) => YourSkyOffNoticeDialog(bytes: bytes!),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The one-time notice itself. Public for tests.
class YourSkyOffNoticeDialog extends ConsumerStatefulWidget {
  final int bytes;

  const YourSkyOffNoticeDialog({super.key, required this.bytes});

  @override
  ConsumerState<YourSkyOffNoticeDialog> createState() =>
      _YourSkyOffNoticeDialogState();
}

class _YourSkyOffNoticeDialogState
    extends ConsumerState<YourSkyOffNoticeDialog> {
  bool _busy = false;
  String? _error;

  String get _size => (widget.bytes / 1e9).toStringAsFixed(1);

  Future<void> _finish(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await markSkyAtlasOffNoticeShown(ref);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'That did not work: ${userFacingError(e)}';
        });
      }
    }
  }

  Future<void> _turnBackOn() => _finish(
        () => ref
            .read(scienceSettingsProvider.notifier)
            .setFeatureEnabled(ScienceFeature.skyAtlas, true),
      );

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (confirmContext) => AlertDialog(
        title: const Text('Delete Your sky data?'),
        content: Text(
          'This permanently deletes $_size GB of sky atlas tiles. Your '
          'frames are not touched, and region names are kept. This cannot be '
          'undone.',
        ),
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.secondary,
            onPressed: () => Navigator.of(confirmContext).pop(false),
          ),
          SkotiqButton(
            label: 'Delete',
            variant: ButtonVariant.destructive,
            onPressed: () => Navigator.of(confirmContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _finish(() async {
      await ref.read(skyAtlasServiceProvider).deleteAllData();
      ref.invalidate(skyAtlasStorageBytesProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return AlertDialog(
      title: const Text('Your sky is now off by default'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Skotiq no longer builds the Your sky atlas unless you turn it '
              'on, so it is off on this machine now. The atlas it built '
              'before holds $_size GB and has been kept.',
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              yourSkyCostText(),
              style: SkotiqTypography.labelQuiet.copyWith(
                color: colors.textSecondary,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              Text(
                _error!,
                style: SkotiqTypography.labelQuiet.copyWith(
                  color: colors.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        SkotiqButton(
          label: 'Delete…',
          variant: ButtonVariant.destructive,
          onPressed: _busy ? null : _delete,
        ),
        SkotiqButton(
          label: 'Keep off',
          variant: ButtonVariant.secondary,
          onPressed: _busy ? null : () => _finish(() async {}),
        ),
        SkotiqButton(
          label: 'Turn back on',
          onPressed: _busy ? null : _turnBackOn,
        ),
      ],
    );
  }
}
