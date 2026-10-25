part of '../flat_wizard_screen.dart';

class _ActionButtons extends ConsumerWidget {
  final FlatWizardMode mode;

  const _ActionButtons({required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);

    // The terminal error is a verdict ("no frames were saved"); on its own it
    // names no cause and no next step. Pair it with the measured diagnosis and
    // with the per-filter reason the solver already produced.
    final diagnosis =
        state.errorMessage != null ? diagnoseFlatFailure(state) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The one banner style (05 §11): both of these were bespoke tinted,
        // outlined boxes with a bare IconButton for a dismiss.
        if (state.errorMessage != null) ...[
          SkotiqBanner(
            tone: BannerTone.error,
            title: state.errorMessage!,
            message: diagnosis == null
                ? null
                : '${diagnosis.reason} ${diagnosis.nextStep}',
            onDismiss: notifier.clearError,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
        // The solver's own per-filter reason, from
        // FlatWizardState.warningMessage, so a run that partly failed explains
        // itself.
        if (state.warningMessage != null) ...[
          SkotiqBanner(
            tone: BannerTone.warning,
            title: state.warningMessage!,
            onDismiss: notifier.clearWarning,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
        // The page's ONE primary, sized to its label rather than stretched
        // across the controls column.
        Align(
          alignment: Alignment.centerLeft,
          child: state.isCapturing
              // The stop is cooperative: the run aborts the exposure in flight
              // and finishes the frame it is on, which is seconds of a screen
              // that otherwise looks exactly like a click that never landed.
              ? SkotiqButton(
                  label:
                      notifier.cancelRequested ? 'Stopping…' : 'Stop capture',
                  onPressed:
                      notifier.cancelRequested ? null : notifier.requestCancel,
                  variant: ButtonVariant.destructive,
                )
              : SkotiqButton(
                  // A tutorial key is a GlobalKey, so it may be attached to at
                  // most ONE live element. All three mode tabs mount this
                  // widget (the TabBarView keeps the outgoing tab alive across
                  // a switch), which duplicated the key and threw "specified
                  // multiple times in the widget tree" the moment the operator
                  // changed tab. The selected mode is the one the tour should
                  // spotlight, so only it claims it.
                  key: mode == state.mode
                      ? FlatWizardTutorialKeys.startBtn
                      : null,
                  label: mode == FlatWizardMode.quick
                      ? 'Start capture'
                      : 'Start batch',
                  onPressed: () => _startCapture(context, ref),
                ),
        ),
        // The run's finish: its flats become a master in the library.
        if (!state.isCapturing) ...[
          const SizedBox(height: SkotiqTokens.spaceLg),
          const FlatBuildMasterStep(),
        ],
      ],
    );
  }

  Future<void> _startCapture(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(flatWizardProvider.notifier);
    final state = ref.read(flatWizardProvider);
    if (state.isCapturing || !notifier.reserveStartPrompt()) return;
    final authority = ref.read(backendProvider);

    try {
      // Ensure a save path is set — prompt for one if missing.
      if (state.globalSettings.savePath == null ||
          state.globalSettings.savePath!.isEmpty) {
        final result = await SavePathDialog.show(
          context,
          currentPath: state.globalSettings.savePath,
          createDateSubfolder: state.globalSettings.createDateSubfolder,
          createFilterSubfolders: state.globalSettings.createFilterSubfolders,
        );

        if (result == null || !context.mounted) return;
        if (!identical(ref.read(backendProvider), authority)) {
          notifier.setWarningMessage(
            'The imaging host changed while choosing the flat-frame folder. '
            'Choose it again for the current host.',
          );
          return;
        }

        final latest = ref.read(flatWizardProvider).globalSettings;
        notifier.updateGlobalSettings(
          latest.copyWith(
            savePath: result.path,
            createDateSubfolder: result.createDateSubfolder,
            createFilterSubfolders: result.createFilterSubfolders,
          ),
        );
      }

      if (!context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
        return;
      }

      // Hand the reservation directly to runCapture. Releasing immediately
      // before the call is safe because runCapture takes its own latch
      // synchronously before its first await.
      notifier.releaseStartPrompt();
      await notifier.runCapture();
    } catch (error) {
      if (context.mounted && identical(ref.read(backendProvider), authority)) {
        notifier.setErrorMessage('Could not start flat capture: $error');
      }
    } finally {
      notifier.releaseStartPrompt();
    }
  }
}
