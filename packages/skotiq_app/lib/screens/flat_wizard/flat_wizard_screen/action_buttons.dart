part of '../flat_wizard_screen.dart';

class _ActionButtons extends ConsumerWidget {
  final FlatWizardMode mode;

  const _ActionButtons({required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final saveFolder = ref.watch(flatWizardSaveFolderProvider);

    // The terminal error is a verdict ("no frames were saved"); on its own it
    // names no cause and no next step. Pair it with the measured diagnosis and
    // with the per-filter reason the solver already produced.
    final diagnosis =
        state.errorMessage != null ? diagnoseFlatFailure(state) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Icon(LucideIcons.folder, size: 16),
          const SizedBox(width: SkotiqTokens.spaceSm),
          if (saveFolder == null)
            const Expanded(
              child: Text(
                'Choose where to save flats',
                style: SkotiqTypography.bodySm,
              ),
            )
          else ...[
            const Text('Saves to ', style: SkotiqTypography.bodySm),
            Expanded(
              child: Tooltip(
                message: saveFolder,
                child: LayoutBuilder(
                  builder: (context, constraints) => Text(
                    pathTail(
                      saveFolder,
                      maxWidth: constraints.maxWidth,
                      style: SkotiqTypography.bodySm,
                      textScaler: MediaQuery.textScalerOf(context),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.bodySm,
                  ),
                ),
              ),
            ),
          ],
          SkotiqButton(
              label: saveFolder == null ? 'Choose…' : 'Change…',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed:
                  state.isCapturing ? null : () => _chooseFolder(context, ref)),
        ]),
        const SizedBox(height: SkotiqTokens.spaceSm),
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
                      ? TourTarget.flatStartButton.key
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

  Future<void> _chooseFolder(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(flatWizardProvider.notifier);
    if (!notifier.reserveStartPrompt()) return;
    final hostScope = ref.backendScope();
    final settings = ref.read(flatWizardProvider).globalSettings;
    try {
      final result = await SavePathDialog.show(context,
          currentPath: ref.read(flatWizardSaveFolderProvider),
          createDateSubfolder: settings.createDateSubfolder,
          createFilterSubfolders: settings.createFilterSubfolders);
      if (result == null || !context.mounted) return;
      if (hostScope.isStale) {
        notifier.setWarningMessage(
            'The imaging host changed. Choose the folder again.');
        return;
      }
      notifier.updateGlobalSettings(ref
          .read(flatWizardProvider)
          .globalSettings
          .copyWith(
              savePath: result.path,
              createDateSubfolder: result.createDateSubfolder,
              createFilterSubfolders: result.createFilterSubfolders));
    } finally {
      notifier.releaseStartPrompt();
    }
  }

  Future<void> _startCapture(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(flatWizardProvider.notifier);
    final state = ref.read(flatWizardProvider);
    if (state.isCapturing || !notifier.reserveStartPrompt()) return;
    final hostScope = ref.backendScope();

    try {
      // Flats default to the capture folder; only a computer with neither
      // has to be asked.
      if (ref.read(flatWizardSaveFolderProvider) == null) {
        final result = await SavePathDialog.show(
          context,
          currentPath: null,
          createDateSubfolder: state.globalSettings.createDateSubfolder,
          createFilterSubfolders: state.globalSettings.createFilterSubfolders,
        );

        if (result == null || !context.mounted) return;
        if (hostScope.isStale) {
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

      if (!context.mounted || hostScope.isStale) {
        return;
      }

      // Hand the reservation directly to runCapture. Releasing immediately
      // before the call is safe because runCapture takes its own latch
      // synchronously before its first await.
      notifier.releaseStartPrompt();
      await notifier.runCapture();
    } catch (error) {
      if (context.mounted && hostScope.isCurrent) {
        notifier.setErrorMessage(
            'Could not start flat capture: ${userFacingError(error)}');
      }
    } finally {
      notifier.releaseStartPrompt();
    }
  }
}
