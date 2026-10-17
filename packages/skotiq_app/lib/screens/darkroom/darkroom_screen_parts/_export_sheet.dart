part of '../darkroom_screen.dart';

/// Where an export writes, as a seam a test can script.
///
/// Mirrors `stackResultSavePickerProvider`: the production picker is a platform
/// dialog on desktop and a sandbox path plus the share sheet on touch, and
/// neither can run inside a widget test.
typedef DarkroomSavePicker = Future<String?> Function({
  required String suggestedName,
  required List<String> allowedExtensions,
  required String confirmButtonText,
});

Future<String?> _defaultDarkroomSavePicker({
  required String suggestedName,
  required List<String> allowedExtensions,
  required String confirmButtonText,
  required String? initialDirectory,
}) async {
  final target = await chooseExportTarget(
    suggestedName: suggestedName,
    initialDirectory: initialDirectory,
    acceptedTypeGroups: [
      XTypeGroup(
        label: allowedExtensions.map((e) => e.toUpperCase()).join(' / '),
        extensions: allowedExtensions,
      ),
    ],
    confirmButtonText: confirmButtonText,
  );
  return target?.path;
}

/// Where the save chooser opens: the profile's own darkroom output folder.
///
/// The chooser used to open wherever the process was launched from — for a
/// release build, the bundle directory — while the profile's capture path and
/// its `darkroom/` subfolder were configured, known, and already where every
/// draft render and night report of this night had been written.
///
/// The directory is only OFFERED, never created and never written to: a chooser
/// that opens at a path the operator then navigates away from must not have
/// left a folder behind. `getSaveLocation` ignores an initial directory that
/// does not exist, which is the same as not naming one, so a night that has not
/// written a darkroom folder yet falls back to the capture root and then to the
/// platform default.
Future<String?> _darkroomOutputDirectory(SettingsDao settings) async {
  final String configured;
  try {
    configured = (await settings.getImageOutputDirectory()).trim();
  } catch (error, stack) {
    // The chooser opening at the platform default is the documented behaviour
    // of naming no directory, so a settings read that fails must not stop an
    // export the operator asked for — but it is still a database read that did
    // not work, and the log is where that is answerable.
    developer.log(
      'Darkroom: the capture output path could not be read, so the save '
      'chooser opens at the platform default: $error',
      name: 'Darkroom',
      level: 900,
      stackTrace: stack,
    );
    return null;
  }
  if (configured.isEmpty) return null;
  final darkroom = p.join(configured, 'darkroom');
  if (await Directory(darkroom).exists()) return darkroom;
  if (await Directory(configured).exists()) return configured;
  return null;
}

/// Override point for the Darkroom export destination (tests script this).
final darkroomSavePickerProvider = Provider<DarkroomSavePicker>((ref) {
  final settings = ref.watch(settingsDaoProvider);
  return ({
    required String suggestedName,
    required List<String> allowedExtensions,
    required String confirmButtonText,
  }) async {
    return _defaultDarkroomSavePicker(
      suggestedName: suggestedName,
      allowedExtensions: allowedExtensions,
      confirmButtonText: confirmButtonText,
      initialDirectory: await _darkroomOutputDirectory(settings),
    );
  };
});

/// How a written export is handed to the OS, as a seam a test can script.
///
/// The production hand-off is a share sheet on touch and a path snackbar on
/// desktop; neither can be made to FAIL inside a widget test, and the failing
/// case is the one that has to be proven — a share sheet that throws on a
/// written file must not be reported as a failed export.
typedef DarkroomFileRevealer = Future<void>
    Function(BuildContext context, String filePath, {String subject});

/// Override point for the reveal/share hand-off (tests script this).
final darkroomFileRevealerProvider = Provider<DarkroomFileRevealer>(
  (ref) => revealExportedFile,
);

/// Which stage of the stack an export materialises.
enum _DarkroomExportStageKind {
  /// The master's own pixels. The recipe still travels with the file as
  /// provenance, recorded as not applied.
  linear,

  /// The stack replayed through one step — a post-gradient or starless master,
  /// rendered on demand rather than stored.
  afterStep,

  /// The whole stack.
  finalStack;

  /// The wire token the export entry point reads.
  String get wire {
    switch (this) {
      case _DarkroomExportStageKind.linear:
        return 'linear';
      case _DarkroomExportStageKind.afterStep:
        return 'afterStep';
      case _DarkroomExportStageKind.finalStack:
        return 'final';
    }
  }
}

/// A file format an export can write.
enum _DarkroomExportFormat {
  fits,
  png,
  jpeg,
  tiff;

  String get wire => name;

  String get label {
    switch (this) {
      case _DarkroomExportFormat.fits:
        return 'FITS';
      case _DarkroomExportFormat.png:
        return 'PNG';
      case _DarkroomExportFormat.jpeg:
        return 'JPEG';
      case _DarkroomExportFormat.tiff:
        return 'TIFF';
    }
  }

  /// The extensions the save picker offers for this format.
  List<String> get extensions {
    switch (this) {
      case _DarkroomExportFormat.fits:
        return const ['fits', 'fit'];
      case _DarkroomExportFormat.png:
        return const ['png'];
      case _DarkroomExportFormat.jpeg:
        return const ['jpg', 'jpeg'];
      case _DarkroomExportFormat.tiff:
        return const ['tif', 'tiff'];
    }
  }

  /// True when the format quantises the engine's `F32` samples into 8/16-bit
  /// integers, which is what needs a display mapping to be meaningful.
  bool get isRaster => this != _DarkroomExportFormat.fits;
}

/// Whether the pixels a chosen stage produces have left the linear domain.
enum _DarkroomStageDomain {
  /// Still linear ADU: no display mapping, so a raster of it is refused unless
  /// the operator asks for the engine's own screen transfer.
  linear,

  /// A stretched operation has run, so the samples already carry a display
  /// mapping and a raster is a faithful quantisation of them.
  stretched,

  /// This build cannot say which — the operation catalogue is missing, or the
  /// stack carries an operation whose stage this build does not model. Treated
  /// as linear, because inventing a mapping is the failure this whole path
  /// exists to prevent.
  undetermined,
}

/// The export sheet: which stage, which format, and the rules stated where the
/// operator can read them.
///
/// **The refusal is a choice, never a silent stretch.** The engine refuses a
/// PNG/JPEG/TIFF of a still-linear stage, because linear ADU has no display
/// mapping. This sheet shows those formats disabled with that sentence, and one
/// switch turns the engine's own auto stretch on and enables them. Nothing here
/// stretches anything by itself, and the reply names the transfer that was
/// applied.
///
/// **That switch is a standing control, not a one-way door.** It stays on the
/// sheet for as long as the chosen stage has no display mapping of its own, in
/// both positions, and the sentence beside it changes to say which way it is
/// set. Hiding it once it was on left the sheet indistinguishable from a stage
/// that was genuinely stretched, with no way back except re-tapping the stage.
///
/// **A stack the engine refuses is refused here BEFORE the press**, in the same
/// shape: the stages that would replay it are disabled and carry the engine's
/// own sentence, and the sheet opens on the linear stage, which replays nothing
/// and writes the master's own pixels. Every chip stayed live over a stack the
/// recipe panel was already calling invalid, so the operator committed to the
/// press, named a file in a save chooser, and only then read "Export failed".
class _DarkroomExportSheet extends ConsumerStatefulWidget {
  final int recipeId;
  final String recipeName;
  final String baseMasterPath;
  final RecipeAuthor author;
  final List<DarkroomStep> steps;
  final DarkroomCatalog? catalog;
  final List<DarkroomStepReport> reports;

  /// The catalogue stars the editor lends `color_calibrate` on every render.
  /// The export lends the same ones, or the colour step would record itself
  /// skipped for want of a catalogue the editor plainly had.
  final List<Map<String, dynamic>> catalogStars;

  /// Why the base master could not be read, in the sentence the viewport is
  /// showing, or null when the last render read it.
  ///
  /// Every export replays the stack over that one file. With the file gone, no
  /// stage, format or destination on this sheet can produce anything — so the
  /// sheet states the failure and disables Export rather than walking the
  /// operator through a save chooser for a render that will refuse.
  final String? baseMasterFailure;

  /// The engine's verdict on the recipe as a whole, or null when it validates.
  ///
  /// The same sentence the recipe panel puts on screen and the Add step button
  /// carries in its accessible name — from the same `validate` call over the
  /// same steps this sheet would send. A stage that REPLAYS the stack comes
  /// back refused by it, so those stages say so before the press rather than
  /// after a save chooser has been answered. The linear stage replays nothing
  /// and stays available.
  final String? recipeRefusal;

  const _DarkroomExportSheet({
    required this.recipeId,
    required this.recipeName,
    required this.baseMasterPath,
    required this.author,
    required this.steps,
    required this.catalog,
    required this.reports,
    required this.catalogStars,
    required this.baseMasterFailure,
    required this.recipeRefusal,
  });

  /// Show the sheet over [context].
  ///
  /// [showAdaptiveModal], not `showDialog`: on a phone this is a bottom sheet
  /// rather than a 640-wide card floating in the middle of a 430-wide screen.
  ///
  /// `isDismissible: false` is fixed when the route is pushed, and an export can
  /// start at any moment after that — so the barrier is closed for the whole
  /// life of the sheet rather than opened and hoped about. Escape is handled
  /// inside [_DarkroomExportSheetState.build] instead, where the live phase can
  /// answer it: it pops when nothing is running, and otherwise says which of
  /// the two — the save chooser or the engine — it is waiting on.
  static Future<void> show(
    BuildContext context, {
    required int recipeId,
    required String recipeName,
    required String baseMasterPath,
    required RecipeAuthor author,
    required List<DarkroomStep> steps,
    required DarkroomCatalog? catalog,
    required List<DarkroomStepReport> reports,
    required List<Map<String, dynamic>> catalogStars,
    required String? baseMasterFailure,
    required String? recipeRefusal,
  }) {
    return showAdaptiveModal<void>(
      context: context,
      designWidth: 640,
      phoneMode: PhoneModalMode.bottomSheet,
      isDismissible: false,
      builder: (_) => _DarkroomExportSheet(
        recipeId: recipeId,
        recipeName: recipeName,
        baseMasterPath: baseMasterPath,
        author: author,
        steps: steps,
        catalog: catalog,
        reports: reports,
        catalogStars: catalogStars,
        baseMasterFailure: baseMasterFailure,
        recipeRefusal: recipeRefusal,
      ),
    );
  }

  @override
  ConsumerState<_DarkroomExportSheet> createState() =>
      _DarkroomExportSheetState();
}

/// What an export in progress is waiting on.
///
/// Two different things, and the sheet says which: the operator answering the
/// save chooser, and the engine replaying the stack. Only the second one is a
/// render, and only the second one can be stopped.
enum _DarkroomExportPhase {
  /// The save chooser is up. Nothing has been sent to the engine.
  choosingFile,

  /// The export is inside the engine, cancellable under [_renderId].
  rendering,
}

class _DarkroomExportSheetState extends ConsumerState<_DarkroomExportSheet> {
  _DarkroomExportStageKind _stageKind = _DarkroomExportStageKind.finalStack;

  /// The step an `afterStep` export stops at. Null until one is chosen.
  int? _afterStep;

  _DarkroomExportFormat _format = _DarkroomExportFormat.fits;

  /// Whether the 8/16-bit files are rendered through the engine's own auto
  /// stretch. Off by default: turning it on is the operator saying they want a
  /// display rendering rather than the data.
  bool _screenTransfer = false;

  /// What the sheet is waiting on, or null when nothing is running.
  _DarkroomExportPhase? _phase;

  /// True while an export is under way, in either phase — the state that
  /// disables the pickers and the Export button.
  bool get _exporting => _phase != null;

  /// The id the running export is cancellable under. Written when the request
  /// goes to the engine, so it is null for exactly as long as there is nothing
  /// to cancel.
  String? _renderId;

  /// True once a stop has been asked for and before the export answers.
  bool _cancelRequested = false;

  /// What the last export wrote, in the words the reply gave.
  String? _result;

  /// Why the last export produced no file, when it was stopped rather than
  /// failed.
  String? _stopped;

  /// Why an Escape was refused, when one arrived mid-export.
  String? _dismissRefused;

  /// The base-master failure an export in this sheet ran into, with the remedy
  /// the viewport's own error path composes.
  ///
  /// Latched: the file the next export would read is the same one this export
  /// could not, so the sheet stops offering a chooser until the operator has
  /// been somewhere that can put the file back.
  String? _exportMasterFailure;

  /// Why no export can succeed, or null when one can be attempted.
  ///
  /// The screen hands over what the last render found, and an export that
  /// refuses on the same file adds its own. Both are about the base master, and
  /// neither is answered by another stage, format or destination.
  String? get _masterFailure =>
      _exportMasterFailure ?? widget.baseMasterFailure;

  @override
  void initState() {
    super.initState();
    // The sheet opens on a stage that is genuinely available. "Final" is the
    // default because it is what an export usually means, but a stack the
    // engine refuses refuses every stage that replays it — and opening on a
    // disabled chip, with Export off, is the same cry-wolf shape one screen
    // further on. The linear stage writes the master's own pixels and replays
    // nothing, so it is the one stage a refused stack leaves standing.
    if (widget.recipeRefusal != null) {
      _stageKind = _DarkroomExportStageKind.linear;
    }
  }

  /// Escape closes the sheet, unless an export is inside the engine.
  ///
  /// The modal barrier cannot decide this — `isDismissible` is fixed when the
  /// route is pushed and an export starts later — so the key is answered here,
  /// where `_exporting` is the live flag. A refusal is stated on the sheet
  /// rather than swallowed: a key that does nothing and says nothing reads as a
  /// broken window.
  void _handleEscape() {
    switch (_phase) {
      case null:
        Navigator.of(context).pop();
      case _DarkroomExportPhase.choosingFile:
        setState(
          () => _dismissRefused =
              'The save chooser is open and nothing has been sent to the '
                  'engine yet. Answer it, or cancel it — cancelling the chooser '
                  'cancels the export and leaves this sheet exactly as it is.',
        );
      case _DarkroomExportPhase.rendering:
        setState(
          () => _dismissRefused = _cancelRequested
              ? 'The export has been asked to stop and has not answered yet. '
                  'This sheet stays up until it does — it is the only thing '
                  'left to report the outcome to.'
              : 'An export is inside the engine. Stop it first, or wait for it '
                  'to finish: closing now would leave the render running with '
                  'nothing left to report its outcome to.',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final domain = _domain();
    final rasterAllowed =
        domain == _DarkroomStageDomain.stretched || _screenTransfer;

    // Surface, not SkotiqDialog: `showAdaptiveModal` already supplies the
    // frame — a Dialog on tablet/desktop, a bottom sheet on a phone — and
    // nesting a second Dialog inside it stretches that frame into a full-height
    // slab.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
      },
      child: Focus(
        autofocus: true,
        // The focus is only here to give the Escape binding somewhere to live.
        // Publishing it annotates the sheet's own frame as focusable, and a
        // focusable node with no enabled state is what the AT-SPI bridge
        // reports as `Export "Draft" [DISABLED]` — measured, on this build.
        includeSemantics: false,
        child: _surface(colors, domain, rasterAllowed),
      ),
    );
  }

  Widget _surface(
    SkotiqColors colors,
    _DarkroomStageDomain domain,
    bool rasterAllowed,
  ) {
    return SkotiqDialogSurface(
      title: 'Export "${widget.recipeName}"',
      icon: SkotiqIcons.download,
      closeEnabled: !_exporting,
      actions: [
        // A Stop only while there is a render to stop. Offering it while the
        // save chooser is up published a live control for a render id nothing
        // was running under.
        if (_phase == _DarkroomExportPhase.rendering)
          SkotiqButton(
            label: _cancelRequested ? 'Stopping…' : 'Stop',
            icon: SkotiqIcons.stop,
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
            onPressed: _cancelRequested ? null : _stop,
          )
        else
          SkotiqButton(
            label: 'Close',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            // The chooser is a modal window of its own: a Close that reads live
            // underneath it cannot be pressed, so it says it cannot.
            onPressed: _exporting ? null : () => Navigator.of(context).pop(),
          ),
        _exportButton(rasterAllowed),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _stagePicker(colors),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _formatPicker(colors, domain, rasterAllowed),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _provenanceNote(colors),
          if (_masterFailure case final failure?) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(
              tone: BannerTone.error,
              title: 'This master cannot be read',
              message: failure,
            ),
          ],
          if (_dismissRefused != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(
              tone: BannerTone.warning,
              title: _phase == _DarkroomExportPhase.choosingFile
                  ? 'The save chooser is still open'
                  : 'This sheet stays up while the export runs',
              message: _dismissRefused!,
            ),
          ],
          if (_stopped != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(
              title: 'The export was stopped',
              tone: BannerTone.info,
              message: _stopped!,
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(
              tone: BannerTone.success,
              title: 'Written',
              message: _result!,
            ),
          ],
          if (_phase case final phase?) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqProgressBar(
              // The engine reports no fraction for an export, so the bar is
              // indeterminate rather than inventing progress.
              value: 0.0,
              indeterminate: true,
              style: SkotiqProgressStyle.standard,
              state: SkotiqProgressState.normal,
              // The phase the sheet is actually in. This line read "Rendering
              // the final stack at full resolution…" while the save chooser was
              // still up and the engine had been asked for nothing at all.
              label: switch (phase) {
                _DarkroomExportPhase.choosingFile =>
                  'Waiting for the save chooser — nothing has been sent to the '
                      'engine yet.',
                _DarkroomExportPhase.rendering => _cancelRequested
                    ? 'Stopping at the next step boundary…'
                    : 'Rendering the ${_stageLabel()} at full resolution…',
              },
            ),
          ],
        ],
      ),
    );
  }

  /// The Export button, carrying its refusal in its accessible name.
  ///
  /// The same shape the refused format chips use, and for the same measured
  /// reason: the Linux AT-SPI bridge publishes a node's name and description
  /// and drops `Semantics(hint:)`, so a disabled control whose only explanation
  /// is a hint announces as a bare, dead "Export".
  Widget _exportButton(bool rasterAllowed) {
    final blocked = _exportRefusal(rasterAllowed);
    final enabled = !_exporting && blocked == null;
    final button = SkotiqButton(
      label: 'Export',
      icon: SkotiqIcons.download,
      size: ButtonSize.small,
      isLoading: _exporting,
      onPressed: enabled ? _export : null,
    );
    if (blocked == null) return button;
    return Semantics(
      container: true,
      button: true,
      enabled: false,
      label: 'Export — $blocked',
      child: ExcludeSemantics(child: button),
    );
  }

  // -----------------------------------------------------------------------
  // Pickers
  // -----------------------------------------------------------------------

  /// One segment of the Stage / Format pickers, with [reason] readable by both
  /// a pointer and a screen reader.
  ///
  /// A [Tooltip] alone puts the reason behind a hover, which is nothing at all
  /// on a touch screen — a refused format announced as the bare word "PNG"
  /// states no reason for its refusal.
  ///
  /// `Semantics(hint:)` is not the rescue it looks like. The hint does reach
  /// Flutter's own semantics tree, but the Linux AT-SPI bridge publishes only a
  /// node's NAME and description, and the hint reaches neither: every chip on
  /// this sheet comes back over AT-SPI as `'PNG' | button | desc: ''` —
  /// measured on this build. So an option carries its reason inside its
  /// accessible name, the shape the disabled Compare button already uses, and
  /// [ExcludeSemantics] drops the chip's own node so exactly one node comes out
  /// rather than a bare "PNG" nested under the sentence.
  ///
  /// **Enabled options take the same shape as refused ones.** They used to take
  /// the hint, so the only statement of what FITS writes, or of what "After a
  /// step" produces, was a hover tooltip: nothing at all from a keyboard, from
  /// a screen reader, or on a touch screen. An available choice needs its
  /// reason as much as an unavailable one — that is what makes it a choice.
  ///
  /// The name is the reason's only assistive-tech channel, never its only
  /// channel outright: each picker states a live refusal on screen as well, and
  /// [_chosenFormatNote] puts the selected format's own sentence on the sheet.
  ///
  /// The tooltip is width-CONSTRAINED. Unbounded, `_formatNote`'s sentence laid
  /// out as one ~900-pixel line that escaped the modal barrier and painted
  /// across the nav rail and the alert's own title row.
  ///
  /// [onTap] is dropped when [enabled] is false — an unavailable option must not
  /// publish a live tap action beside its disabled flag.
  Widget _optionChip({
    required String label,
    required String reason,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final chip = SkotiqChip(
      label: label,
      selected: selected,
      enabled: enabled,
      onTap: enabled ? onTap : null,
    );
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: selected,
      label: '$label — $reason',
      onTap: enabled ? onTap : null,
      child: ExcludeSemantics(
        child: _boundedTooltip(message: reason, child: chip),
      ),
    );
  }

  /// A tooltip that wraps instead of running off the screen.
  ///
  /// `Tooltip` has no width of its own, so a long message lays out as a single
  /// line as wide as it needs. `richMessage` is the one hook that takes a
  /// widget, and a [ConstrainedBox] inside it is what gives the text something
  /// to wrap against.
  Widget _boundedTooltip({required String message, required Widget child}) {
    return Builder(
      builder: (context) {
        final colors = SkotiqColors.of(context);
        return Tooltip(
          richMessage: WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                message,
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
          child: child,
        );
      },
    );
  }

  /// What the CHOSEN format writes, on screen.
  ///
  /// The per-chip reasons are an accessible name and a hover; this is the one
  /// the operator reads without pointing at anything, about the option they
  /// have actually taken.
  Widget _chosenFormatNote(SkotiqColors colors) {
    return Text(
      '${_format.label}: ${_formatNote(_format)}',
      style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
    );
  }

  Widget _stagePicker(SkotiqColors colors) {
    final replayRefusal = _replayRefusal();
    final afterStepRefusal = _afterStepRefusal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Stage',
          style: SkotiqTypography.labelSm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Wrap(
          spacing: SkotiqTokens.spaceXs,
          runSpacing: SkotiqTokens.spaceXs,
          children: [
            _optionChip(
              label: 'Linear master',
              reason: 'Write the master\'s own pixels, with the recipe '
                  'travelling along as provenance.',
              selected: _stageKind == _DarkroomExportStageKind.linear,
              onTap: () => _setStage(_DarkroomExportStageKind.linear),
            ),
            _optionChip(
              label: 'After a step',
              reason: afterStepRefusal ??
                  'Replay the stack through one step and write what it '
                      'produced.',
              selected: _stageKind == _DarkroomExportStageKind.afterStep,
              enabled: afterStepRefusal == null,
              onTap: () => _setStage(_DarkroomExportStageKind.afterStep),
            ),
            _optionChip(
              label: 'Final',
              reason: replayRefusal ??
                  'Write every enabled step, at the master\'s full resolution.',
              selected: _stageKind == _DarkroomExportStageKind.finalStack,
              enabled: replayRefusal == null,
              onTap: () => _setStage(_DarkroomExportStageKind.finalStack),
            ),
          ],
        ),
        // On screen, not only in the chip's name: a hover states nothing on a
        // touch screen, and the format picker's own refusal has read this way
        // since it shipped. The stage picker is the one that had no
        // equivalent.
        if (replayRefusal != null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqBanner(
            tone: BannerTone.warning,
            title: 'This stack does not validate, so only the linear master '
                'can be written',
            message: replayRefusal,
          ),
        ] else if (afterStepRefusal != null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqBanner(
            tone: BannerTone.info,
            title: '"After a step" is unavailable for this recipe',
            message: afterStepRefusal,
          ),
        ],
        if (_stageKind == _DarkroomExportStageKind.afterStep) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqDropdown(
            value: _afterStep == null ? null : _stepOptionFor(_afterStep!),
            hint: 'Choose the step to stop after',
            isExpanded: true,
            items: [
              for (var i = 0; i < widget.steps.length; i++) _stepOptionFor(i),
            ],
            onChanged: _exporting
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _afterStep = _stepIndexOf(value);
                      _result = null;
                      _stopped = null;
                      // A different cut is a different stage; see [_setStage].
                      _screenTransfer = false;
                    });
                  },
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          _stageExplanation(),
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _formatPicker(
    SkotiqColors colors,
    _DarkroomStageDomain domain,
    bool rasterAllowed,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Format',
          style: SkotiqTypography.labelSm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Wrap(
          spacing: SkotiqTokens.spaceXs,
          runSpacing: SkotiqTokens.spaceXs,
          children: [
            for (final format in _DarkroomExportFormat.values)
              _optionChip(
                label: format.label,
                reason: format.isRaster && !rasterAllowed
                    ? _rasterRefusal(domain)
                    : _formatNote(format),
                selected: _format == format,
                enabled: !format.isRaster || rasterAllowed,
                onTap: () => setState(() {
                  _format = format;
                  _result = null;
                  _stopped = null;
                }),
              ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        _chosenFormatNote(colors),
        // Gated on the STAGE's own domain, never on `rasterAllowed`. Whether
        // these pixels need the engine's transfer is a fact about the stage;
        // `_screenTransfer` is the operator's answer to it. Gating this block
        // on the answer made the switch delete itself the moment it was turned
        // on — taking the only control that could turn it back off, and every
        // sentence saying a transfer would be applied, off the sheet with it.
        if (domain != _DarkroomStageDomain.stretched) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          // The state is on screen, not only in a tooltip: a chip whose reason
          // lives behind a hover says nothing on a touch screen. Both answers
          // get a sentence — refused, and rendered through the auto stretch.
          SkotiqBanner(
            tone: BannerTone.info,
            title: _screenTransfer
                ? 'PNG, JPEG and TIFF are rendered through the auto stretch'
                : 'PNG, JPEG and TIFF are unavailable for this stage',
            message: _screenTransfer
                ? _rasterTransferNote(domain)
                : _rasterRefusalMessage(domain),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqSwitchRow(
            label: 'Render the 8/16-bit files through the auto stretch',
            // "these pixels", not "these linear pixels": this row is offered on
            // an undetermined stage too, where the build has not established
            // that the pixels are linear.
            subtitle:
                'Uses the engine\'s own auto stretch to give these pixels a '
                'display mapping. The recipe is not changed and the reply '
                'names the transfer that was applied — a FITS export of the '
                'same stage still carries whatever the pixels are.',
            value: _screenTransfer,
            onChanged: _exporting
                ? null
                : (value) => setState(() {
                      _screenTransfer = value;
                      _result = null;
                      _stopped = null;
                    }),
          ),
        ],
      ],
    );
  }

  Widget _provenanceNote(SkotiqColors colors) {
    return Text(
      'Every export carries this recipe: a FITS gets HISTORY cards naming each '
      'step and its outcome plus the recipe\'s own canonical JSON, and a '
      '.skrecipe sidecar is written beside whichever file is chosen so the '
      'recipe survives outside the database.',
      style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
    );
  }

  // -----------------------------------------------------------------------
  // The stage / domain rules
  // -----------------------------------------------------------------------

  void _setStage(_DarkroomExportStageKind kind) {
    setState(() {
      _stageKind = kind;
      _result = null;
      _stopped = null;
      // The rule is per stage: whether these pixels need a display mapping is a
      // fact about the stage that was chosen, so the choice is re-made rather
      // than carried across from a different one.
      _screenTransfer = false;
      if (kind == _DarkroomExportStageKind.afterStep && _afterStep == null) {
        _afterStep = widget.steps.isEmpty ? null : widget.steps.length - 1;
      }
    });
  }

  String _stepOptionFor(int index) =>
      '${index + 1}. ${darkroomOpTitle(widget.steps[index].opId)}';

  int? _stepIndexOf(String option) {
    for (var i = 0; i < widget.steps.length; i++) {
      if (_stepOptionFor(i) == option) return i;
    }
    return null;
  }

  String _stageLabel() {
    switch (_stageKind) {
      case _DarkroomExportStageKind.linear:
        return 'linear master';
      case _DarkroomExportStageKind.afterStep:
        final index = _afterStep;
        return index == null
            ? 'chosen step'
            : 'stack through step ${index + 1}';
      case _DarkroomExportStageKind.finalStack:
        return 'final stack';
    }
  }

  /// Why a stage that REPLAYS the stack cannot be chosen, or null when the
  /// engine accepts the recipe.
  ///
  /// The engine validates the whole recipe before it touches a pixel, so a
  /// stage that replays it is refused by the same fault the recipe panel is
  /// already naming. The sentence is the engine's own, quoted rather than
  /// paraphrased, so this sheet and that panel cannot drift.
  ///
  /// The linear stage is deliberately not covered: it replays nothing, and the
  /// recipe rides along with it as provenance.
  String? _replayRefusal() {
    final error = widget.recipeRefusal;
    if (error == null) return null;
    return 'The engine refuses this stack as it stands, so replaying it would '
        'be refused with it: $error';
  }

  /// Why the `afterStep` stage cannot be chosen, or null when it can.
  ///
  /// One sentence, read by the chip's accessible name AND by the alert under
  /// the picker, so the two can never drift into stating different reasons.
  String? _afterStepRefusal() {
    final replay = _replayRefusal();
    if (replay != null) return replay;
    if (widget.steps.isNotEmpty) return null;
    return 'This recipe carries no steps, so there is no step to stop after. '
        'Add one, or export the linear master.';
  }

  /// What each stage writes, counted off THIS recipe rather than asserted.
  ///
  /// A zero-step recipe is a real state — "Start from linear" produces one —
  /// and the final stage over it applies nothing at all. Describing "every
  /// enabled step" there names steps the operator can see are not in the stack,
  /// beside a History panel that says the recipe carries no operations.
  String _stageExplanation() {
    final total = widget.steps.length;
    final enabled = widget.steps.where((step) => step.enabled).length;
    switch (_stageKind) {
      case _DarkroomExportStageKind.linear:
        return 'The master\'s own pixels, untouched. The recipe rides along as '
            'provenance and is recorded as not applied.';
      case _DarkroomExportStageKind.afterStep:
        final refusal = _afterStepRefusal();
        if (refusal != null) return refusal;
        return 'The stack replayed from the start through the chosen step. '
            'Steps below it are not applied.';
      case _DarkroomExportStageKind.finalStack:
        final refusal = _replayRefusal();
        if (refusal != null) return refusal;
        if (total == 0) {
          return 'This recipe carries no steps, so the final stage applies '
              'nothing: it writes the master\'s own pixels at full resolution.';
        }
        if (enabled == 0) {
          return 'All $total steps in this recipe are switched off, so the '
              'final stage applies nothing: it writes the master\'s own pixels '
              'at full resolution.';
        }
        return 'The $enabled enabled step${enabled == 1 ? '' : 's'} of '
            '$total, at the master\'s full resolution — not the pyramid level '
            'the viewport renders from.';
    }
  }

  /// The last index a chosen stage renders through, or null when the stage
  /// applies no step at all.
  int? _cutIndex() {
    switch (_stageKind) {
      case _DarkroomExportStageKind.linear:
        return null;
      case _DarkroomExportStageKind.afterStep:
        return _afterStep;
      case _DarkroomExportStageKind.finalStack:
        return widget.steps.isEmpty ? null : widget.steps.length - 1;
    }
  }

  /// Whether the chosen stage's pixels have left the linear domain.
  ///
  /// The engine decides this from its own render report — an APPLIED step whose
  /// operation emits stretched pixels. This mirrors that rule from the recipe
  /// and the catalogue so the sheet can state it BEFORE the export runs. When
  /// the catalogue is missing, or the stack carries an operation this build does
  /// not register, the answer is [_DarkroomStageDomain.undetermined] rather than
  /// a guess.
  _DarkroomStageDomain _domain() {
    final cut = _cutIndex();
    if (cut == null) return _DarkroomStageDomain.linear;
    final catalog = widget.catalog;
    if (catalog == null) return _DarkroomStageDomain.undetermined;

    var undetermined = false;
    for (var i = 0; i <= cut && i < widget.steps.length; i++) {
      final step = widget.steps[i];
      if (!step.enabled) continue;
      final spec = catalog.specFor(step);
      if (spec == null || spec.stage == DarkroomOpStage.unmodelled) {
        undetermined = true;
        continue;
      }
      if (spec.stage != DarkroomOpStage.stretched) continue;
      // A step the last render skipped changed nothing, so it left the pixels
      // where they were. An unreported step is not evidence either way, so it
      // counts as having run — the direction that keeps a linear file from
      // being quantised as if it had a display mapping.
      final report = _reportFor(i);
      if (report?.outcome == DarkroomStepOutcome.skipped) continue;
      return _DarkroomStageDomain.stretched;
    }
    return undetermined
        ? _DarkroomStageDomain.undetermined
        : _DarkroomStageDomain.linear;
  }

  DarkroomStepReport? _reportFor(int index) {
    for (final report in widget.reports) {
      if (report.index == index) return report;
    }
    return null;
  }

  String _rasterRefusal(_DarkroomStageDomain domain) {
    switch (domain) {
      case _DarkroomStageDomain.stretched:
        return 'These pixels already carry a display mapping.';
      case _DarkroomStageDomain.linear:
        return 'The ${_stageLabel()} is still linear ADU and has no display '
            'mapping, so quantising it into 8 or 16 bits would show almost '
            'nothing. Export FITS to keep the linear pixels, or switch on the '
            'auto stretch below to render the 8/16-bit files through the '
            'engine\'s own transfer.';
      case _DarkroomStageDomain.undetermined:
        return widget.catalog == null
            ? 'The operation catalogue could not be read, so this build cannot '
                'tell whether the ${_stageLabel()} has a display mapping. '
                'FITS keeps whatever the pixels are; switch on the auto '
                'stretch to render the 8/16-bit files through the engine\'s '
                'own transfer.'
            : 'This stack carries an operation whose stage this build does not '
                'model, so whether the ${_stageLabel()} has a display '
                'mapping is unstated. FITS keeps whatever the pixels are; '
                'switch on the auto stretch to render the 8/16-bit files '
                'through the engine\'s own transfer.';
    }
  }

  /// The refusal, plus what it means for the format that is actually chosen.
  ///
  /// The auto stretch can now be switched back off with a raster still
  /// selected, and a disabled chip renders identically whether or not it is the
  /// chosen one — so the sheet says outright that Export is waiting on that
  /// choice, rather than leaving a greyed button with no sentence beside it.
  String _rasterRefusalMessage(_DarkroomStageDomain domain) {
    final refusal = _rasterRefusal(domain);
    if (!_format.isRaster) return refusal;
    return '$refusal\n\n${_format.label} is still the chosen format, so Export '
        'stays off until you pick FITS or switch the auto stretch back on.';
  }

  /// What the sheet states once the operator has switched the auto stretch on.
  ///
  /// The counterpart to [_rasterRefusal]: the rasters are available now, and
  /// the sheet has to keep saying WHY they are available and what will be done
  /// to them, or an opted-in export reads exactly like a stage whose pixels
  /// already carried a display mapping.
  String _rasterTransferNote(_DarkroomStageDomain domain) {
    final because = domain == _DarkroomStageDomain.undetermined
        ? 'this build cannot tell whether the ${_stageLabel()} carries a '
            'display mapping of its own'
        : 'the ${_stageLabel()} is still linear ADU and carries no display '
            'mapping of its own';
    return 'The 8/16-bit files are rendered through the engine\'s own auto '
        'stretch, because $because. The recipe is not changed, a FITS export '
        'of the same stage still carries whatever the pixels are, and the '
        'reply names the transfer that was applied. Switch it back off to '
        'return these formats to unavailable.';
  }

  String _formatNote(_DarkroomExportFormat format) {
    switch (format) {
      case _DarkroomExportFormat.fits:
        return 'The engine\'s own F32 samples, with the master\'s astrometry '
            'and the recipe in HISTORY cards. Always available, at every '
            'stage.';
      case _DarkroomExportFormat.png:
        return '16-bit PNG, quantised from the render\'s samples.';
      case _DarkroomExportFormat.jpeg:
        return '8-bit JPEG at the engine\'s documented default quality; the '
            'reply names the value used.';
      case _DarkroomExportFormat.tiff:
        return '16-bit TIFF, quantised from the render\'s samples.';
    }
  }

  /// Why Export is unavailable, or null when it can run.
  ///
  /// The predicates the run path gates on, in the same order, folded into one
  /// sentence the greyed Export button carries as its accessible name — the
  /// shape the Compare button and the format chips already use, so a disabled
  /// control is never a bare, reasonless "Export" over a bridge that publishes
  /// only a node's name. The master failure leads, then the chosen stage, then
  /// the two selections a stage leaves open: a step not yet picked, and a
  /// raster format still selected for a stage that cannot write one. The last
  /// two used to disable the button with no reason at all — `_stageBlocked` is
  /// null for both, so the button fell through to its plain, unlabelled form.
  String? _exportRefusal(bool rasterAllowed) {
    final master = _masterFailure;
    if (master != null) return master;
    final stage = _stageBlocked();
    if (stage != null) return stage;
    if (_stageKind == _DarkroomExportStageKind.afterStep &&
        _afterStep == null) {
      return 'Choose the step to stop after.';
    }
    if (_format.isRaster && !rasterAllowed) {
      return '${_format.label} is unavailable for this stage. Render it '
          'through the auto stretch, or choose FITS.';
    }
    return null;
  }

  /// Why the CHOSEN stage cannot be exported, or null when it can.
  ///
  /// The chips for a refused stack are disabled, so this only answers for a
  /// selection that was made before the refusal was known. It is what the
  /// Export button carries in its accessible name, so a greyed button is never
  /// a bare "Export".
  String? _stageBlocked() {
    switch (_stageKind) {
      case _DarkroomExportStageKind.linear:
        return null;
      case _DarkroomExportStageKind.afterStep:
        return _afterStepRefusal();
      case _DarkroomExportStageKind.finalStack:
        return _replayRefusal();
    }
  }

  // -----------------------------------------------------------------------
  // Running the export
  // -----------------------------------------------------------------------

  /// The file-name fragment for an `afterStep` export.
  ///
  /// Reads the chosen step itself, so the name says which operation the file
  /// stopped after. The Export button stays disabled until a step is chosen, so
  /// the unchosen case never reaches a file name; if it somehow did, the
  /// fragment says "afterStep" rather than naming a step nobody picked.
  String _afterStepSlug() {
    final index = _afterStep;
    if (index == null || index >= widget.steps.length) return 'afterStep';
    return 'step${index + 1}-${widget.steps[index].opId}';
  }

  /// [name] folded to the characters a file name carries anywhere.
  ///
  /// The proposed name goes into a Save dialog, onto this disk, into a
  /// `.skrecipe` sidecar beside it, and from there onto a watched folder or an
  /// SFTP target — four filesystems and a wire, none of them this app's. The
  /// autopilot names its recipes `Master · <filter> draft`, and U+00B7 was
  /// carried straight through: the chooser opened on `Master_·_B_draft-final`
  /// and that is the name that left the rig, while every name the autopilot
  /// itself writes in the same directory is ASCII.
  ///
  /// Only the FILE NAME is folded. The recipe keeps the name the operator and
  /// the autopilot gave it — that name is the label in the app, and rewriting
  /// it to suit a filesystem would be the tail wagging the dog.
  ///
  /// A run of non-portable characters becomes ONE underscore rather than one
  /// each, so `Master · B` reads as `Master_B` instead of `Master___B`, and
  /// leading and trailing runs are dropped. A name with nothing portable left
  /// in it — a recipe titled in a non-Latin script — returns empty, and the
  /// caller falls back to the recipe's id rather than proposing a file called
  /// `_`.
  static String _asciiFileNameSlug(String name) {
    final folded = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return folded.replaceAll(RegExp(r'^_+|_+$'), '');
  }

  String _suggestedFileName() {
    final stage = switch (_stageKind) {
      _DarkroomExportStageKind.linear => 'linear',
      _DarkroomExportStageKind.afterStep => _afterStepSlug(),
      _DarkroomExportStageKind.finalStack => 'final',
    };
    final base = _asciiFileNameSlug(widget.recipeName);
    return '${base.isEmpty ? 'recipe-${widget.recipeId}' : base}'
        '-$stage.${_format.extensions.first}';
  }

  Future<void> _export() async {
    // The button is disabled in both of these states; the guard keeps a
    // keyboard activation that raced the rebuild from opening a chooser.
    if (_exporting || _masterFailure != null) return;
    final picker = ref.read(darkroomSavePickerProvider);
    final darkroom = ref.read(darkroomSeamProvider);

    // The save chooser answers first and the engine is asked nothing until it
    // does, so the sheet enters the CHOOSING phase here. Entering the rendering
    // phase at this point is what had the sheet announce a full-resolution
    // render, publish a Stop for a render id that named nothing, and refuse an
    // Escape by naming an engine that was idle — all while the only thing
    // happening was a file dialog waiting for a name.
    setState(() {
      _phase = _DarkroomExportPhase.choosingFile;
      _cancelRequested = false;
      _result = null;
      _stopped = null;
      _dismissRefused = null;
    });

    try {
      final outputPath = await picker(
        suggestedName: _suggestedFileName(),
        allowedExtensions: _format.extensions,
        confirmButtonText: 'Export ${_format.label}',
      );
      if (outputPath == null || !mounted) return;

      final renderId = 'darkroom-export-${widget.recipeId}-'
          '${DateTime.now().microsecondsSinceEpoch}';
      setState(() {
        _phase = _DarkroomExportPhase.rendering;
        _renderId = renderId;
      });

      final reply = await darkroom.renderExport(
        recipeJson: encodeDarkroomRecipe(
          recipeId: widget.recipeId,
          baseMasterRef: widget.baseMasterPath,
          author: widget.author,
          steps: widget.steps,
        ),
        args: {
          'masterPath': widget.baseMasterPath,
          'renderId': renderId,
          'stage': {
            'kind': _stageKind.wire,
            if (_stageKind == _DarkroomExportStageKind.afterStep)
              'index': _afterStep,
          },
          'outputs': [
            {'format': _format.wire, 'path': outputPath},
          ],
          // Named rather than derived: the engine only derives a sidecar path
          // from a FITS output, and a raster export with no sidecar would leave
          // the recipe behind in the database alone.
          'sidecarPath': '$outputPath.skrecipe',
          'writeSidecar': true,
          'screenTransfer': _screenTransfer,
          if (widget.catalogStars.isNotEmpty)
            'catalogStars': widget.catalogStars,
        },
      );
      if (!mounted) return;
      _settle(() => _result = _describeReply(reply, outputPath));
      if (!context.mounted) return;
      SkotiqToastHelper.show(
        context: context,
        message: 'Exported ${p.basename(outputPath)}',
        severity: SkotiqAlertSeverity.success,
      );
      // The reveal/share is a hand-off to the OS AFTER the file is written and
      // the success above is already recorded. It gets its OWN try: on a
      // platform whose share sheet throws — some desktop and headless targets
      // do — a written export must not be reported as "Export failed" and must
      // not latch `_exportMasterFailure`. The export succeeded; only the reveal
      // did not, and that is the smaller, non-fatal news it carries.
      try {
        await ref.read(darkroomFileRevealerProvider)(
          context,
          outputPath,
          subject: 'Skotiq Darkroom export',
        );
      } catch (revealError, revealStack) {
        // The path is on the sheet's own outcome block either way, so the
        // operator can still find the file; only the hand-off is lost, and the
        // reason for it belongs in the log rather than in a toast.
        developer.log(
          'Darkroom: the export was written to $outputPath but could not be '
          'revealed or shared: $revealError',
          name: 'Darkroom',
          level: 900,
          stackTrace: revealStack,
        );
        if (mounted) {
          SkotiqToastHelper.show(
            context: context,
            message: 'Exported ${p.basename(outputPath)}, but it could not be '
                'revealed or shared on this device.',
            severity: SkotiqAlertSeverity.warning,
          );
        }
      }
    } on DarkroomCancelledOutcome catch (cancelled) {
      if (!mounted) return;
      // The engine honours a stop before it writes, so a stopped export leaves
      // no half-written file behind.
      _settle(
        () => _stopped =
            'The export was stopped during ${cancelled.phase}. No file was '
                'written.',
      );
    } on DarkroomSeamException catch (error) {
      if (!mounted) return;
      await _reportFailure(error.message);
    } catch (error) {
      if (!mounted) return;
      await _reportFailure('$error');
    } finally {
      // Every outcome above has already settled the sheet; this catches the
      // paths that produced none — a save chooser the operator cancelled, and
      // a sheet that was disposed mid-export.
      _renderId = null;
      if (mounted && _phase != null) _settle(() {});
    }
  }

  /// Publish an outcome and retire the running state in ONE frame.
  ///
  /// The sheet must never paint an outcome over its own progress bar. Clearing
  /// the phase in a `finally` looked equivalent and was not: the failure path
  /// AWAITS its error dialog, so "Export failed" was read over a live
  /// "Rendering the linear master at full resolution…", a filled progress bar
  /// and a working Stop button — two contradictory claims about one operation
  /// in one frame, for as long as the operator took to press Close.
  void _settle(VoidCallback outcome) {
    _renderId = null;
    setState(() {
      outcome();
      _phase = null;
      _cancelRequested = false;
      // The refusal named a render that is no longer running; leaving it on
      // screen would state something untrue about the sheet.
      _dismissRefused = null;
    });
  }

  Future<void> _reportFailure(String raw) async {
    // The same humaniser the stack-and-share flow uses: the bridge's stringified
    // union is not a sentence, and the operator reads the payload inside it.
    final failure = describeStackShareFailure(raw);

    // A failure about the base master is not a failure about this export, and
    // nothing on this sheet answers it. The viewport behind the dialog is
    // already naming the two acts that recover the file; the dialog named the
    // path and offered a single Close, which left the operator holding an OS
    // error and no next step. It now composes the same sentence, from the same
    // helper, so the two surfaces cannot drift.
    final masterNextStep = darkroomMasterFailureNextStep(
      failure.message,
      widget.baseMasterPath,
    );
    // Settled BEFORE the dialog, never after it: the dialog is awaited, and a
    // sheet still claiming to be rendering underneath it contradicts the
    // failure the operator is reading.
    if (mounted) {
      _settle(() {
        if (masterNextStep != null) {
          _exportMasterFailure = '${failure.message}. $masterNextStep';
        }
      });
    }

    final nextStep = masterNextStep ?? failure.nextStep;
    if (!context.mounted) return;
    await ErrorDialog.show(
      context,
      title: 'Export failed',
      message: nextStep == null
          ? failure.message
          : '${failure.message}\n\n$nextStep',
      technicalDetails: failure.technical,
    );
  }

  /// Ask the running export to stop.
  ///
  /// Cooperative, like the preview render: the engine honours it at the next
  /// step boundary or pixel-budget poll, so the button says "Stopping…" until
  /// the export answers.
  Future<void> _stop() async {
    final renderId = _renderId;
    if (renderId == null || _cancelRequested) return;
    setState(() => _cancelRequested = true);
    try {
      await ref.read(darkroomSeamProvider).cancel({
        'op': 'cancel',
        'renderId': renderId,
      });
    } on DarkroomSeamException catch (error) {
      if (!mounted) return;
      setState(() {
        _cancelRequested = false;
        _stopped = 'The stop request did not reach the export: '
            '${error.message}';
      });
    }
  }

  /// What the reply says was written, in its own numbers.
  String _describeReply(Map<String, dynamic> reply, String outputPath) {
    final lines = <String>[];
    final outputs = reply['outputs'];
    if (outputs is List && outputs.isNotEmpty) {
      for (final entry in outputs) {
        if (entry is! Map<String, dynamic>) continue;
        final format = entry['format'];
        final path = entry['path'];
        final bytes = entry['bytes'];
        final width = entry['width'];
        final height = entry['height'];
        final clamped = entry['clampedSamples'];
        final quality = entry['quality'];
        lines.add(
          '${format ?? 'file'}: ${path ?? outputPath}'
          '${width != null && height != null ? ' — $width×$height' : ''}'
          '${bytes is int ? ', ${_bytes(bytes)}' : ''}'
          '${quality != null ? ', quality $quality' : ''}'
          '${clamped is int && clamped > 0 ? ', $clamped samples clamped' : ''}',
        );
      }
    } else {
      lines.add(
        'The engine reported no output entry, so what landed at $outputPath '
        'is unstated.',
      );
    }

    final sidecar = reply['sidecarPath'];
    final skipped = reply['sidecarSkippedReason'];
    if (sidecar is String && sidecar.isNotEmpty) {
      lines.add('Recipe sidecar: $sidecar');
    } else if (skipped is String && skipped.isNotEmpty) {
      lines.add('No recipe sidecar: $skipped');
    }

    final domain = reply['sourceDomain'];
    if (domain is String && domain.isNotEmpty) {
      lines.add('Source pixels: $domain');
    }
    final transfer = reply['screenTransfer'];
    lines.add(
      transfer == null
          ? 'No screen transfer was applied.'
          : 'The engine\'s auto stretch was applied to the 8/16-bit files '
              'only; the recipe was not changed.',
    );
    final fingerprint = reply['recipeFingerprint'];
    if (fingerprint is String && fingerprint.isNotEmpty) {
      lines.add('Recipe fingerprint: $fingerprint');
    }
    return lines.join('\n');
  }

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
