import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

// Phd2GuidingState (and its displayName extension) are owned by skotiq_core.
// This UI-only extension layers on the icon mapping that's specific to widgets.
extension Phd2GuidingStateIcon on Phd2GuidingState {
  IconData get icon {
    switch (this) {
      case Phd2GuidingState.disconnected:
        return LucideIcons.cloudOff;
      case Phd2GuidingState.stopped:
        return LucideIcons.square;
      case Phd2GuidingState.looping:
        return LucideIcons.refreshCw;
      case Phd2GuidingState.calibrating:
        return LucideIcons.settings;
      case Phd2GuidingState.guiding:
        return LucideIcons.crosshair;
      case Phd2GuidingState.paused:
        return LucideIcons.pause;
      case Phd2GuidingState.settling:
        return LucideIcons.timer;
      case Phd2GuidingState.lostLock:
        return LucideIcons.alertTriangle;
      case Phd2GuidingState.unknown:
        return LucideIcons.helpCircle;
    }
  }
}

/// Panel containing main guiding controls
class GuideControlsPanel extends StatefulWidget {
  /// Key of the inline "why that control is unavailable" banner, raised when
  /// the operator presses a control that cannot act.
  static const Key noticeBannerKey = ValueKey('guideControlsNotice');

  /// Current guiding state
  final Phd2GuidingState state;

  /// Whether PHD2 is connected
  final bool isConnected;

  /// Callbacks for main controls.
  ///
  /// These are async on purpose: each issues a real hardware command. The panel
  /// awaits them with its own busy/error handling (see
  /// [_runReportingAction]) so a tap
  /// stays busy until the command is accepted or fails, a second tap cannot
  /// duplicate the native call, and a thrown error is surfaced instead of
  /// escaping as an unhandled Future.
  final Future<void> Function()? onStartGuiding;
  final Future<void> Function()? onStopGuiding;
  final Future<void> Function()? onPauseGuiding;
  final Future<void> Function()? onResumeGuiding;
  final Future<void> Function()? onLoop;

  /// Auto Select. Unlike the others this one RETURNS what happened, and the
  /// panel puts it in its own notice banner.
  ///
  /// A snackbar is not enough: it renders on the app shell's messenger, sits
  /// for four seconds and is gone, so an operator who reads the screen a moment
  /// later finds nothing and takes the control for dead. The banner stays until
  /// it is dismissed, in the panel the operator just clicked.
  final Future<String?> Function()? onFindStar;
  final Future<void> Function()? onDeselectStar;

  /// Why Pause cannot be used with the active guider, when it cannot.
  ///
  /// A control that is unavailable for a reason the app knows must say the
  /// reason: the built-in guider has no pause, and a Pause button that simply
  /// did nothing left the operator unable to tell whether corrections were
  /// suspended — the one thing pause exists to tell them.
  final String? pauseUnavailableReason;

  /// Dither controls
  final double ditherAmount;
  final bool ditherRaOnly;
  final void Function(double)? onDitherAmountChanged;
  final void Function(bool)? onDitherRaOnlyChanged;
  final Future<void> Function()? onDither;

  /// Settle parameters
  final double settlePixels;
  final double settleTime;
  final double settleTimeout;
  final void Function(double)? onSettlePixelsChanged;
  final void Function(double)? onSettleTimeChanged;
  final void Function(double)? onSettleTimeoutChanged;

  const GuideControlsPanel({
    super.key,
    required this.state,
    required this.isConnected,
    this.onStartGuiding,
    this.onStopGuiding,
    this.onPauseGuiding,
    this.onResumeGuiding,
    this.onLoop,
    this.onFindStar,
    this.onDeselectStar,
    this.pauseUnavailableReason,
    this.ditherAmount = 5.0,
    this.ditherRaOnly = false,
    this.onDitherAmountChanged,
    this.onDitherRaOnlyChanged,
    this.onDither,
    this.settlePixels = 1.5,
    this.settleTime = 10.0,
    this.settleTimeout = 60.0,
    this.onSettlePixelsChanged,
    this.onSettleTimeChanged,
    this.onSettleTimeoutChanged,
  });

  @override
  State<GuideControlsPanel> createState() => _GuideControlsPanelState();
}

class _GuideControlsPanelState extends State<GuideControlsPanel> {
  bool _settleExpanded = false;

  /// Two busy lanes mirroring the controller's command gate so a Stop can
  /// always pre-empt a settling Start (the safe abort direction) while a
  /// duplicate of either is swallowed. [_positiveInFlight] holds the id of the
  /// running start/pause/resume/loop/dither/star action; [_stopInFlight] tracks
  /// the Stop lane independently. The active button shows a spinner; a command
  /// stays busy until it is accepted or fails, so a double-tap cannot fire a
  /// second native call.
  String? _positiveInFlight;
  bool _stopInFlight = false;

  /// Last command error, surfaced inline (dismissible) instead of escaping as
  /// an unhandled Future or silently reverting the button to an idle look.
  String? _errorText;

  /// Why the control the operator just pressed is unavailable.
  ///
  /// A disabled button explains itself on HOVER, which is no explanation at
  /// all to the operator who clicked it: Pause under the built-in guider ate
  /// the click, nothing moved, and the log said nothing — the exact silence
  /// pause exists to break. Pressing an unavailable control now states the
  /// reason where the operator is already looking.
  String? _noticeText;

  bool get _positiveBusy => _positiveInFlight != null || _stopInFlight;

  /// Await [action] with local busy + error handling. Stop rides its own lane
  /// (can run even while a positive command is in flight); everything else is
  /// serialised behind the positive lane. No-ops when the action is
  /// unavailable or the relevant lane is already occupied.
  /// An action that returns a message reports it in the notice banner — the
  /// panel's own persistent surface. Actions with nothing to say return null.
  Future<void> _runReportingAction(
    String id,
    Future<String?> Function()? action,
  ) async {
    if (action == null) return;
    final isStop = id == 'stop';
    if (isStop) {
      if (_stopInFlight) return;
    } else if (_positiveBusy) {
      return;
    }
    setState(() {
      if (isStop) {
        _stopInFlight = true;
      } else {
        _positiveInFlight = id;
      }
      _errorText = null;
    });
    try {
      final outcome = await action();
      if (outcome != null && mounted) {
        setState(() => _noticeText = outcome);
      }
    } catch (e) {
      if (mounted) setState(() => _errorText = _messageFor(e));
    } finally {
      if (mounted) {
        setState(() {
          if (isStop) {
            _stopInFlight = false;
          } else {
            _positiveInFlight = null;
          }
        });
      }
    }
  }

  String _messageFor(Object error) {
    if (error is StateError) return error.message;
    return error.toString().replaceFirst('Exception: ', '');
  }

  /// The panel sizes to its content and never scrolls on its own.
  ///
  /// It used to be a bordered card with its own scroll view inside the side
  /// panel's: a column of full-width 44px buttons whose Dither and Settle
  /// sections sat below the fold of the inner scroll, announced only by a
  /// fade. The buttons are a compact grid now, and the host scrolls the whole
  /// column if a short window needs it.
  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // No state header here: the page header carries the guider state
        // chip (06 §Guiding), and one screen states a fact once.
        if (_errorText != null) ...[
          _buildErrorBanner(colors, _errorText!),
          const SizedBox(height: _sectionGap),
        ],
        if (_noticeText != null) ...[
          _buildNoticeBanner(colors, _noticeText!),
          const SizedBox(height: _sectionGap),
        ],
        _buildMainControls(colors),
        const SizedBox(height: _sectionGap),
        _buildStarSelection(colors),
        const SizedBox(height: _sectionGap),
        _buildDitherControls(colors),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _buildSettleSettings(colors),
      ],
    );
  }

  /// Gap between the panel's sections.
  static const double _sectionGap = SkotiqTokens.spaceLg;

  /// Gap between a section's header and its buttons, and between buttons.
  static const double _gridGap = SkotiqTokens.spaceSm;

  Widget _buildMainControls(SkotiqColors colors) {
    // All enable/label decisions flow from the shared capability layer so the
    // desktop and mobile controls (which share this widget) can never disagree
    // about what is legal. In particular: paused / calibrating / settling /
    // lost-lock / unknown are all "busy" phases whose primary action is Stop —
    // an enabled Start is NEVER offered there.
    final state = widget.state;
    final connected = widget.isConnected;
    final canStart = connected && state.canStart;
    final canStop = connected && state.canStop;

    // Primary button: Stop whenever the session is live/uncertain, Start only
    // from a genuinely idle-but-connected state, disabled otherwise.
    final primaryIsStop = canStop;
    final String primaryId = primaryIsStop ? 'stop' : 'start';
    final Future<void> Function()? primaryAction = primaryIsStop
        ? (canStop ? widget.onStopGuiding : null)
        : (canStart ? widget.onStartGuiding : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader('Guiding controls', LucideIcons.target, colors),
        const SizedBox(height: _gridGap),
        _buttonGrid([
          _buildControlButton(
            id: primaryId,
            icon: primaryIsStop ? LucideIcons.square : LucideIcons.play,
            label: primaryIsStop ? 'Stop' : 'Start',
            color: primaryIsStop ? colors.error : colors.success,
            colors: colors,
            onPressed: primaryAction,
          ),
          _buildControlButton(
            id: state.canResume ? 'resume' : 'pause',
            icon: state.canResume ? LucideIcons.play : LucideIcons.pause,
            label: state.canResume ? 'Resume' : 'Pause',
            color: colors.warning,
            colors: colors,
            isOutline: true,
            onPressed: connected
                ? (state.canResume
                    ? widget.onResumeGuiding
                    : (state.canPause ? widget.onPauseGuiding : null))
                : null,
            unavailableReason: widget.pauseUnavailableReason,
          ),
          // Outline, not a fill: 05 §5 gives a view ONE primary, and Start
          // owns it here. Loop exposures, Auto select and Deselect were all
          // painted as fills, so the panel read as three primaries stacked.
          // "Loop" fits a third of the panel; the tooltip and the semantics
          // label keep the full name.
          _buildControlButton(
            id: 'loop',
            icon: LucideIcons.refreshCw,
            label: 'Loop',
            semanticLabel: 'Loop exposures',
            tooltip: 'Loop exposures without guiding',
            color: colors.info,
            colors: colors,
            isOutline: true,
            onPressed: connected && state.canLoop ? widget.onLoop : null,
          ),
        ]),
      ],
    );
  }

  Widget _buildErrorBanner(SkotiqColors colors, String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.12),
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, size: 16, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: SkotiqTypography.caption.copyWith(color: colors.error),
            ),
          ),
          const SizedBox(width: 4),
          // The tap lived on a bare gesture wrapper, which publishes an action
          // and no role, so assistive tech read a live control as an inert
          // disabled panel. The flags are only published when given.
          Semantics(
              button: true,
              enabled: true,
              label: 'Dismiss error',
              child: GestureDetector(
                onTap: () => setState(() => _errorText = null),
                behavior: HitTestBehavior.opaque,
                child: Icon(LucideIcons.x, size: 16, color: colors.error),
              )),
        ],
      ),
    );
  }

  /// Neutral (not error) inline banner: nothing has gone wrong, a control
  /// simply does not exist for the connected guider.
  Widget _buildNoticeBanner(SkotiqColors colors, String message) {
    return Container(
      key: GuideControlsPanel.noticeBannerKey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.info.withValues(alpha: 0.12),
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.info.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: 16, color: colors.info),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: SkotiqTypography.caption.copyWith(color: colors.info),
            ),
          ),
          const SizedBox(width: 4),
          Semantics(
            button: true,
            enabled: true,
            label: 'Dismiss notice',
            child: GestureDetector(
              onTap: () => setState(() => _noticeText = null),
              behavior: HitTestBehavior.opaque,
              child: Icon(LucideIcons.x, size: 16, color: colors.info),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStarSelection(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader('Star selection', LucideIcons.star, colors),
        const SizedBox(height: _gridGap),
        _buttonGrid([
          _buildControlButton(
            id: 'findStar',
            icon: LucideIcons.search,
            label: 'Auto select',
            color: colors.primary,
            colors: colors,
            isOutline: true,
            onPressedReporting: widget.isConnected ? widget.onFindStar : null,
          ),
          _buildControlButton(
            id: 'deselectStar',
            icon: LucideIcons.x,
            label: 'Deselect',
            color: colors.textSecondary,
            colors: colors,
            isOutline: true,
            onPressed: widget.isConnected ? widget.onDeselectStar : null,
          ),
        ]),
      ],
    );
  }

  /// Narrowest a grid cell may get before its label stops fitting.
  ///
  /// Measured against the longest label in a cell ("Auto select", and
  /// "Resume" in a third of the row): below it a label truncates, and a
  /// truncated control name is not a name, so the row breaks into fewer
  /// columns and keeps the words whole.
  static const double _gridCellMinWidth = 80.0;

  /// Control buttons in one row of equal cells, as many columns as there are
  /// buttons when they fit, wrapping onto further rows when they do not.
  Widget _buttonGrid(List<Widget> buttons) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var columns = buttons.length;
        while (columns > 1 &&
            (constraints.maxWidth - _gridGap * (columns - 1)) / columns <
                _gridCellMinWidth) {
          columns--;
        }
        final rows = <Widget>[];
        for (var start = 0; start < buttons.length; start += columns) {
          final cells = buttons.sublist(
            start,
            math.min(start + columns, buttons.length),
          );
          if (rows.isNotEmpty) rows.add(const SizedBox(height: _gridGap));
          rows.add(Row(
            children: [
              for (var i = 0; i < columns; i++) ...[
                if (i > 0) const SizedBox(width: _gridGap),
                Expanded(
                  child: i < cells.length ? cells[i] : const SizedBox.shrink(),
                ),
              ],
            ],
          ));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        );
      },
    );
  }

  Widget _buildDitherControls(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader('Dither', LucideIcons.shuffle, colors),
        const SizedBox(height: _gridGap),
        Row(
          children: [
            Text(
              'Amount:',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  activeTrackColor: colors.primary,
                  inactiveTrackColor: colors.well,
                  thumbColor: colors.primary,
                  overlayColor: colors.primary.withValues(alpha: 0.2),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: widget.ditherAmount,
                  min: 1,
                  max: 20,
                  divisions: 19,
                  onChanged: widget.onDitherAmountChanged,
                ),
              ),
            ),
            Container(
              width: 32,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colors.well,
                borderRadius: SkotiqTokens.borderRadiusXs,
              ),
              child: Text(
                widget.ditherAmount.toStringAsFixed(0),
                style: SkotiqTypography.labelSm
                    .copyWith(color: colors.textPrimary),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            // Wrap checkbox with GestureDetector for larger touch target (44px minimum)
            GestureDetector(
              onTap: () =>
                  widget.onDitherRaOnlyChanged?.call(!widget.ditherRaOnly),
              behavior: HitTestBehavior.opaque,
              // The Checkbox inside already publishes the checked state; a
              // second tap node beside it reads as an unnamed disabled panel.
              excludeFromSemantics: true,
              child: Container(
                // 44px minimum touch target, but visually compact
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: Checkbox(
                        value: widget.ditherRaOnly,
                        semanticLabel: 'RA only',
                        onChanged: (value) =>
                            widget.onDitherRaOnlyChanged?.call(value ?? false),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: BorderSide(color: colors.border),
                        activeColor: colors.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius: SkotiqTokens.borderRadiusXs),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'RA only',
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: _buildControlButton(
                id: 'dither',
                icon: LucideIcons.shuffle,
                label: 'Dither now',
                color: colors.accent,
                colors: colors,
                small: true,
                onPressed: widget.state.canDither ? widget.onDither : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettleSettings(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The tap lived on a bare gesture wrapper, which publishes an action
        // and no role, so assistive tech read a live control as an inert
        // disabled panel. The flags are only published when given.
        Semantics(
            button: true,
            enabled: true,
            expanded: _settleExpanded,
            child: InkWell(
              onTap: () => setState(() => _settleExpanded = !_settleExpanded),
              borderRadius: SkotiqTokens.borderRadiusLg,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: colors.well,
                  borderRadius: SkotiqTokens.borderRadiusLg,
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.settings2,
                      size: 14,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Settle settings',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.labelSm
                            .copyWith(color: colors.textSecondary),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedRotation(
                      turns: _settleExpanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        LucideIcons.chevronDown,
                        size: 16,
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            )),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.well.withValues(alpha: 0.5),
              borderRadius: SkotiqTokens.borderRadiusLg,
              border: Border.all(color: colors.border.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                _buildSettingRow('Pixels', widget.settlePixels, 0.5, 5.0,
                    widget.onSettlePixelsChanged, colors),
                const SizedBox(height: 8),
                _buildSettingRow('Time (s)', widget.settleTime, 5, 60,
                    widget.onSettleTimeChanged, colors),
                const SizedBox(height: 8),
                _buildSettingRow('Timeout (s)', widget.settleTimeout, 30, 180,
                    widget.onSettleTimeoutChanged, colors),
              ],
            ),
          ),
          crossFadeState: _settleExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }

  Widget _buildSettingRow(String label, double value, double min, double max,
      void Function(double)? onChanged, SkotiqColors colors) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: colors.primary.withValues(alpha: 0.7),
              inactiveTrackColor: colors.surfaceHover,
              thumbColor: colors.primary,
              overlayColor: colors.primary.withValues(alpha: 0.1),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            value.toStringAsFixed(1),
            style:
                SkotiqTypography.labelQuiet.copyWith(color: colors.textPrimary),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, SkotiqColors colors) {
    return Row(
      children: [
        Icon(icon, size: 14, color: colors.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style:
                SkotiqTypography.eyebrow.copyWith(color: colors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.visible,
          ),
        ),
      ],
    );
  }

  Widget _buildControlButton({
    required String id,
    required IconData icon,
    required String label,
    required Color color,
    required SkotiqColors colors,
    Future<void> Function()? onPressed,

    /// An action that reports its outcome (see [_runReportingAction]). Exactly
    /// one of this and [onPressed] is given.
    Future<String?> Function()? onPressedReporting,
    bool isOutline = false,
    bool small = false,
    String? unavailableReason,

    /// The control's full name for assistive tech, when [label] is the short
    /// form that fits the grid.
    String? semanticLabel,

    /// Hover help for a live control.
    String? tooltip,
  }) {
    final action = onPressedReporting ??
        (onPressed == null
            ? null
            : () async {
                await onPressed();
                return null;
              });
    // Stop rides its own lane so it stays tappable to abort a settling Start;
    // every other action is locked while any command is in flight so no second
    // native call can be issued until the current one settles.
    final isStop = id == 'stop';
    final isThisBusy = isStop ? _stopInFlight : _positiveInFlight == id;
    final laneBusy = isStop ? _stopInFlight : _positiveBusy;
    final isDisabled = action == null || laneBusy;
    // A reason only applies while the control is genuinely unavailable — never
    // over a control that is merely busy with its own command.
    final reason = action == null ? unavailableReason : null;

    // These are the controls that start and stop guiding, so they must publish
    // a button role and their enabled state. Without this wrapper the bare
    // Material > InkWell reached assistive tech as an unnamed generic node
    // ("panel: Start") that never carried DISABLED, so a screen-reader user was
    // never told Start was unavailable while PHD2 was disconnected. The tap
    // action is republished here because excludeSemantics drops the InkWell's
    // own gesture semantics along with the duplicate label node.
    final button = Semantics(
      container: true,
      button: true,
      enabled: !isDisabled,
      label: reason == null
          ? (semanticLabel ?? label)
          : '${semanticLabel ?? label} — $reason',
      onTap: isDisabled ? null : () => _runReportingAction(id, action),
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isDisabled ? null : () => _runReportingAction(id, action),
          borderRadius: SkotiqTokens.borderRadiusLg,
          child: ConstrainedBox(
            // The standard control height on desktop; the platform minimum
            // touch target on a touch device. These were 44px everywhere,
            // which on a desktop side panel made five buttons the height of
            // a column of cards.
            constraints: BoxConstraints(
              minHeight: SkotiqTouchTarget.minExtent(
                context,
                desktopExtent: SkotiqTokens.buttonHeight,
              ),
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceSm,
              ),
              decoration: BoxDecoration(
                color: isOutline
                    ? Colors.transparent
                    : (isDisabled
                        ? colors.well
                        : color.withValues(alpha: 0.15)),
                borderRadius: SkotiqTokens.borderRadiusLg,
                border: Border.all(
                  color: isDisabled
                      ? colors.border
                      : (isOutline
                          ? colors.border
                          : color.withValues(alpha: 0.3)),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: small ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  if (isThisBusy)
                    SizedBox(
                      width: small ? 14 : 16,
                      height: small ? 14 : 16,
                      child: SkotiqSpinner(size: small ? 14 : 16, color: color),
                    )
                  else
                    Icon(
                      icon,
                      size: small ? 14 : 16,
                      color: isDisabled ? colors.textMuted : color,
                    ),
                  SizedBox(width: small ? 6 : 8),
                  Flexible(
                    child: Text(
                      label,
                      style: (small
                              ? SkotiqTypography.labelQuiet
                              : SkotiqTypography.labelSm)
                          .copyWith(
                              color: isDisabled ? colors.textMuted : color),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (reason == null) {
      return tooltip == null
          ? button
          : Tooltip(
              message: tooltip, excludeFromSemantics: true, child: button);
    }

    // The button stays disabled — it is genuinely not a live control, and the
    // semantics node above says so. What changes is that pressing it is no
    // longer silent: a hover tooltip is invisible to the operator who clicks,
    // and invisible to touch entirely. `excludeFromSemantics` keeps the
    // tooltip from publishing a second, state-less node over the button's own
    // (the reason is already carried in its label).
    return Tooltip(
      message: reason,
      excludeFromSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: () => setState(() => _noticeText = reason),
        child: button,
      ),
    );
  }
}
