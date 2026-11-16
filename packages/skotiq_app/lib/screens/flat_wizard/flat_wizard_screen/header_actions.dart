part of '../flat_wizard_screen.dart';

/// Where the flats are saved, as a ghost button that changes it.
class _SaveFolderButton extends ConsumerWidget {
  const _SaveFolderButton({required this.compact});

  /// Icon only, where the header has no room for the folder's name.
  final bool compact;

  /// The widest the folder's tail runs in the header.
  static const double _labelWidth = 220;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCapturing =
        ref.watch(flatWizardProvider.select((s) => s.isCapturing));
    final saveFolder = ref.watch(flatWizardSaveFolderProvider);
    final onPressed = isCapturing ? null : () => _chooseFolder(context, ref);
    final tooltip = saveFolder == null
        ? 'Choose where flats are saved'
        : 'Flats are saved to $saveFolder';

    if (compact) {
      return SkotiqIconButton(
        icon: LucideIcons.folder,
        tooltip: tooltip,
        onPressed: onPressed,
      );
    }
    return Tooltip(
      message: tooltip,
      child: SkotiqButton(
        label: saveFolder == null
            ? 'Choose folder'
            : pathTail(
                saveFolder,
                maxWidth: _labelWidth,
                style: SkotiqTypography.button,
                textScaler: MediaQuery.textScalerOf(context),
              ),
        icon: LucideIcons.folder,
        variant: ButtonVariant.ghost,
        onPressed: onPressed,
      ),
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
}

/// The page's one primary: start the run, or stop the one that is on.
class _RunButton extends ConsumerWidget {
  const _RunButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);

    if (state.isCapturing) {
      // A stop aborts the exposure in flight and settles the camera, which
      // takes seconds; the label says the press was taken.
      return SkotiqButton(
        label: notifier.cancelRequested ? 'Stopping…' : 'Stop capture',
        onPressed: notifier.cancelRequested ? null : notifier.requestCancel,
        variant: ButtonVariant.destructive,
      );
    }
    return SkotiqButton(
      key: TourTarget.flatStartButton.key,
      label:
          state.mode == FlatWizardMode.quick ? 'Start capture' : 'Start batch',
      onPressed: () => _startCapture(context, ref),
    );
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

/// What stopped or marred the last run, at the top of the settings it blocks.
class _RunBanners extends ConsumerWidget {
  const _RunBanners();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    // The terminal error is a verdict; the measured diagnosis names the cause
    // and the next step.
    final diagnosis =
        state.errorMessage != null ? diagnoseFlatFailure(state) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.errorMessage != null)
          SkotiqBanner(
            tone: BannerTone.error,
            title: state.errorMessage!,
            message: diagnosis == null
                ? null
                : '${diagnosis.reason} ${diagnosis.nextStep}',
            onDismiss: notifier.clearError,
          ),
        if (state.errorMessage != null && state.warningMessage != null)
          const SizedBox(height: SkotiqTokens.spaceSm),
        // The solver's own per-filter reason, so a run that partly failed
        // explains itself.
        if (state.warningMessage != null)
          SkotiqBanner(
            tone: BannerTone.warning,
            title: state.warningMessage!,
            onDismiss: notifier.clearWarning,
          ),
      ],
    );
  }
}
