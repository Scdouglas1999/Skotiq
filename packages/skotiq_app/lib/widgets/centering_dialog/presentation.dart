// ignore_for_file: invalid_use_of_protected_member
part of '../centering_dialog.dart';

final _centeringPresentations = Expando<_CenteringPresentation>();

/// Shows the centering dialog for a target above navigation, so a run
/// survives the dialog being minimized. Completes with the result of the
/// next centering run in the dialog once that run ends (the dialog stays open
/// on it), or with null when the dialog closes first or a run is refused
/// before its first exposure.
Future<CenteringResult?> showCenteringDialog({
  required BuildContext context,
  double? targetRa,
  double? targetDec,
  String? targetName,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final existing = _centeringPresentations[overlay];
  if (existing != null) {
    final state = existing.key.currentState;
    state?._restore();
    // A run in flight reports its end to this caller too; a dialog resting
    // on a result has no run of this caller's to report.
    return state != null && state._isCentering
        ? existing.nextRunEnd()
        : Future<CenteringResult?>.value();
  }

  final presentation = _CenteringPresentation();
  _centeringPresentations[overlay] = presentation;
  final container = ProviderScope.containerOf(context);
  final themes = InheritedTheme.capture(from: context, to: overlay.context);
  late final OverlayEntry entry;
  void close(CenteringResult? _) {
    if (presentation.closed) return;
    presentation.closed = true;
    _centeringPresentations[overlay] = null;
    presentation.notifyRunEnded(null);
    entry.remove();
    entry.dispose();
  }

  entry = OverlayEntry(
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: themes.wrap(CenteringDialog(
        key: presentation.key,
        targetRa: targetRa,
        targetDec: targetDec,
        targetName: targetName,
        onClose: close,
        onRunEnded: presentation.notifyRunEnded,
      )),
    ),
  );
  entry.addListener(() {
    if (!entry.mounted && !presentation.closed) {
      presentation.closed = true;
      _centeringPresentations[overlay] = null;
      presentation.notifyRunEnded(null);
    }
  });
  final firstRun = presentation.nextRunEnd();
  overlay.insert(entry);
  return firstRun;
}

class _CenteringPresentation {
  final key = GlobalKey<_CenteringDialogState>();
  bool closed = false;
  Completer<CenteringResult?>? _runEnd;

  /// The end of the next run, for every caller waiting on it.
  Future<CenteringResult?> nextRunEnd() =>
      (_runEnd ??= Completer<CenteringResult?>()).future;

  void notifyRunEnded(CenteringResult? result) {
    final runEnd = _runEnd;
    _runEnd = null;
    runEnd?.complete(result);
  }
}

extension _CenteringPresentationWidgets on _CenteringDialogState {
  void _restore() => setState(() => _isMinimized = false);

  void _minimize() {
    FocusScope.of(context).unfocus();
    setState(() => _isMinimized = true);
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose(_result);
    } else {
      Navigator.of(context).pop(_result);
    }
  }

  Widget _buildMinimized(CenteringStatus status, SkotiqColors colors) {
    final outcome = _result;
    final message = _isCentering
        ? (_abortInFlight ? 'Stopping…' : status.message ?? 'Centering…')
        : outcome != null
            ? (outcome.success
                ? 'Target centered'
                : outcome.errorMessage ?? 'Centering failed')
            : _solverMissingMessage ?? 'Ready to center';
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
          child: SizedBox(
            width: 360,
            child: Material(
              elevation: 12,
              color: colors.surface,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXl),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Icon(SkotiqIcons.target, size: 20, color: colors.accent),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(
                        widget.targetName ?? 'Target centering',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600),
                      )),
                      IconButton(
                        tooltip: 'Restore centering',
                        icon: const Icon(LucideIcons.maximize2, size: 18),
                        onPressed: _restore,
                      ),
                      if (!_isCentering)
                        IconButton(
                          tooltip: 'Close centering',
                          icon: const Icon(LucideIcons.x, size: 18),
                          onPressed: _close,
                        ),
                    ]),
                    Text(message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textSecondary)),
                    if (_isCentering) ...[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                            child: Text(
                          'Iteration ${status.currentIteration}/${status.maxIterations}'
                          '${status.currentOffsetArcsec == null ? '' : ' · ${status.currentOffsetArcsec!.toStringAsFixed(1)}″ offset'}',
                          style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: SkotiqTypography.fontSize12),
                        )),
                        TextButton(
                          onPressed: _abortInFlight ? null : _abortCentering,
                          child: Text('Abort',
                              style: TextStyle(color: colors.error)),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
