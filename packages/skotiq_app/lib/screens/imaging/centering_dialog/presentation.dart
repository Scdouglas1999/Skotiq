// ignore_for_file: invalid_use_of_protected_member
part of '../centering_dialog.dart';

final _centeringPresentations = Expando<_CenteringPresentation>();

/// Keeps the operation mounted above navigation while its window is minimized.
Future<CenteringResult?> showCenteringDialog({
  required BuildContext context,
  double? targetRa,
  double? targetDec,
  String? targetName,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final existing = _centeringPresentations[overlay];
  if (existing != null) {
    existing.key.currentState?._restore();
    return existing.result.future;
  }

  final presentation = _CenteringPresentation();
  _centeringPresentations[overlay] = presentation;
  final container = ProviderScope.containerOf(context);
  final themes = InheritedTheme.capture(from: context, to: overlay.context);
  late final OverlayEntry entry;
  void close(CenteringResult? result) {
    if (presentation.result.isCompleted) return;
    _centeringPresentations[overlay] = null;
    presentation.result.complete(result);
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
      )),
    ),
  );
  entry.addListener(() {
    if (!entry.mounted && !presentation.result.isCompleted) {
      _centeringPresentations[overlay] = null;
      presentation.result.complete(null);
    }
  });
  overlay.insert(entry);
  return presentation.result.future;
}

class _CenteringPresentation {
  final key = GlobalKey<_CenteringDialogState>();
  final result = Completer<CenteringResult?>();
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
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Icon(SkotiqIcons.target,
                          size: 20, color: colors.accent),
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
                              color: colors.textSecondary, fontSize: 12),
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
