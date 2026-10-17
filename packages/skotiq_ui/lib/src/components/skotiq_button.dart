import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/text_measure.dart';
import '../utils/touch_target.dart';
import 'skotiq_chip.dart';

/// The five button faces.
///
/// One [primary] per page and one per dialog; everything else in a side panel,
/// a list or a row is [secondary] or [ghost].
enum ButtonVariant {
  /// Solid `primary` fill. The single most important action in view.
  primary,

  /// Transparent with a 1px `borderHighlight` outline. The default for
  /// everything that is not the one primary action.
  secondary,

  /// No fill and no outline until hover. Toolbars, rows, dismissals.
  ghost,

  /// Hollow with an `error` outline and `error` ink.
  ///
  /// Hollow in EVERY theme, not just red night. Under red night `primary`
  /// #EF3B3B and `error` #EF5252 are two shades of one hue — the palette is
  /// monochrome by construction — so a filled destructive beside a filled
  /// primary produced two adjacent, equally weighted red slabs with nothing
  /// left to tell them apart. FILL WEIGHT is the channel that stays free, so
  /// exactly one of the pair is filled and it is never this one.
  destructive,

  /// The Start-sequence face: a solid `startFill` (green) with `onStart` ink.
  ///
  /// Its own colour because starting a night is not the same act as the
  /// primary action of a settings page, and the operator finds it by colour
  /// from across a dark room.
  start,

  /// Old name for [secondary].
  @Deprecated('Use ButtonVariant.secondary. Removed in wave 4.')
  outline,
}

/// The three button heights: 28 / 32 / 40.
enum ButtonSize { small, medium, large }

/// Button heights in logical pixels (03 §3.3).
const double _buttonHeightSm = SkotiqTokens.buttonHeightSm;
const double _buttonHeightMd = SkotiqTokens.buttonHeight;
const double _buttonHeightLg = SkotiqTokens.buttonHeightLg;

/// Horizontal padding per size, in logical pixels (05 §6: 10 / 12 / 18).
const double _buttonPadSm = SkotiqTokens.buttonPaddingSm;
const double _buttonPadMd = SkotiqTokens.buttonPaddingMd;
const double _buttonPadLg = SkotiqTokens.buttonPaddingLg;

/// Icon size inside a button, in logical pixels (05 §6: 15, 16 in large).
const double _buttonIconSize = SkotiqTokens.iconGlyphButton;

/// Gap between a button's icon and its label.
const double _buttonIconGap = 7;

/// The 1px stroke `Border.all` draws on each vertical edge.
const double _buttonBorderWidth = 1;

/// The three per-size metrics, as functions rather than `State` getters: the
/// static measurement below needs them before any button exists, and one
/// implementation each is what keeps the measurement and the paint in step.
TextStyle _textStyleFor(ButtonSize size) => switch (size) {
  ButtonSize.small => SkotiqTypography.buttonSm,
  ButtonSize.medium => SkotiqTypography.button,
  ButtonSize.large => SkotiqTypography.buttonLg,
};

double _horizontalPaddingFor(ButtonSize size) => switch (size) {
  ButtonSize.small => _buttonPadSm,
  ButtonSize.medium => _buttonPadMd,
  ButtonSize.large => _buttonPadLg,
};

double _iconSizeFor(ButtonSize size) => switch (size) {
  ButtonSize.small => _buttonIconSize,
  ButtonSize.medium => _buttonIconSize,
  ButtonSize.large => SkotiqTokens.iconSm,
};

/// How far outside the button's own box the keyboard focus ring is drawn, and
/// how thick that stroke is, in logical pixels. Kept outside the box so the
/// ring never overlaps the label and never changes the control's metrics.
const double _focusRingOffset = 2.0;
const double _focusRingWidth = 2.0;

/// Solid, outlined and ghost buttons on the Observatory scale.
class SkotiqButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final ButtonVariant variant;
  final ButtonSize size;
  final bool isLoading;

  /// A sentence read after [label], qualifying what the button is in this
  /// state — most often WHY it is disabled.
  ///
  /// A disabled control publishes `enabled: false` and nothing else, so
  /// assistive tech says "dimmed" and the reason stays wherever the screen put
  /// it. The hint is the slot that carries the reason with the control, which
  /// is the difference between a button that refuses and a button that looks
  /// broken.
  final String? semanticsHint;

  /// A count carried on the button's trailing edge — Sequencer's "Preflight 2".
  ///
  /// A count is part of what the button SAYS, not a second control beside it,
  /// which is why it is a slot here rather than a `Row` at the call site:
  /// hand-rolled, it lands outside the button's hit box and outside its
  /// semantics node, so the number is neither pressable nor announced.
  final String? badge;

  /// What the [badge] means, in words, for assistive tech — "2 issues".
  ///
  /// Required in spirit whenever [badge] is set: a screen reader that hears
  /// "Preflight, 2" learns nothing. Falls back to the bare number.
  final String? badgeSemanticsLabel;

  /// The badge's tone. Defaults to the button's own ink, which is right for a
  /// neutral count; a warning or error count says so in colour.
  final ChipTone? badgeTone;

  const SkotiqButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.variant = ButtonVariant.primary,
    this.size = ButtonSize.medium,
    this.isLoading = false,
    this.semanticsHint,
    this.badge,
    this.badgeSemanticsLabel,
    this.badgeTone,
  });

  /// The button's height in logical pixels.
  double get height => switch (size) {
    ButtonSize.small => _buttonHeightSm,
    ButtonSize.medium => _buttonHeightMd,
    ButtonSize.large => _buttonHeightLg,
  };

  /// The width a button needs to render [label] in full, in logical pixels.
  ///
  /// The label is a `Flexible` `Text` with `TextOverflow.ellipsis`, so a
  /// button handed less room than its words need neither overflows nor grows:
  /// it renders "St…" and nothing in the app reports a problem. A layout that
  /// chooses between side-by-side and stacked has to ask this first, and ask
  /// it of the button's own metrics — the same text style, horizontal padding,
  /// icon slot and border `build` paints with — so the two cannot drift apart.
  ///
  /// [badge] is not counted; a call site that carries one measures it itself.
  static double measureWidth(
    BuildContext context, {
    required String label,
    bool hasIcon = false,
    ButtonSize size = ButtonSize.medium,
  }) {
    final labelWidth = measureTextWidth(
      context,
      text: label,
      style: _textStyleFor(size),
    );
    final iconSlot = hasIcon ? _iconSizeFor(size) + _buttonIconGap : 0.0;
    return labelWidth +
        iconSlot +
        2 * _horizontalPaddingFor(size) +
        2 * _buttonBorderWidth;
  }

  @override
  State<SkotiqButton> createState() => _SkotiqButtonState();
}

/// The resolved face of a button in one interaction state.
typedef _ButtonFace = ({Color fill, Color ink, Color border});

class _SkotiqButtonState extends State<SkotiqButton>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isPressed = false;
  bool _isFocused = false;

  late AnimationController _pressController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      duration: SkotiqTokens.durationFast,
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
      CurvedAnimation(
        parent: _pressController,
        curve: SkotiqTokens.curveStandard,
      ),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  void _setHovered(bool value) {
    if (!mounted || _isHovered == value) return;
    setState(() => _isHovered = value);
  }

  void _handleTapDown(TapDownDetails details) {
    if (!mounted || widget.onPressed == null || widget.isLoading) return;
    setState(() => _isPressed = true);
    _pressController.forward();
  }

  void _handleTapUp(TapUpDetails details) => _releasePress();
  void _handleTapCancel() => _releasePress();

  void _releasePress() {
    if (!mounted || !_isPressed) return;
    setState(() => _isPressed = false);
    _pressController.reverse();
  }

  /// Smallest interactive box this button may occupy, in logical pixels.
  ///
  /// The visual sizes are deliberately compact for dense desktop panels — 28px
  /// tall for `small`, 32px for the DEFAULT `medium` — but both are under the
  /// platform touch minimums (Android 48, iOS 44), which `flutter_test`'s
  /// tap-target guidelines flag. On a tablet, which is a primary way this app
  /// is driven, that is a genuinely hard-to-hit control.
  ///
  /// Applied only on touch platforms: growing desktop buttons to 48px would
  /// re-flow every dense panel for no accessibility gain, since a mouse has
  /// none of the imprecision the guideline exists to absorb.
  double get _minInteractiveExtent => SkotiqTouchTarget.minExtent(context);

  double get _horizontalPadding => _horizontalPaddingFor(widget.size);

  TextStyle get _textStyle => _textStyleFor(widget.size);

  double get _iconSize => _iconSizeFor(widget.size);

  /// Hover lightening for the [ButtonVariant.start] fill, which has no second
  /// named colour the way `primary` has `accent`.
  Color _lighten(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }

  /// The button's fill, ink and border for the current interaction state.
  ///
  /// Disabled is NOT resolved here: it is 40% opacity over the resting face
  /// (05 §6, "no colour change"), applied once in [build] so every variant
  /// dims the same way and a disabled destructive still reads as destructive.
  _ButtonFace _face(SkotiqColors colors) {
    final hovered = _isHovered || _isPressed;
    // `outline` is the deprecated spelling of `secondary`; fold it before the
    // switch so there is exactly one implementation of that face.
    final variant = widget.variant == ButtonVariant.outline
        // ignore: deprecated_member_use_from_same_package
        ? ButtonVariant.secondary
        : widget.variant;

    return switch (variant) {
      ButtonVariant.primary => (
        fill: hovered ? colors.accent : colors.primary,
        ink: colors.onPrimary,
        border: Colors.transparent,
      ),
      ButtonVariant.start => (
        fill: hovered
            ? _lighten(colors.startFill, SkotiqTokens.buttonHoverLighten)
            : colors.startFill,
        ink: colors.onStart,
        border: Colors.transparent,
      ),
      ButtonVariant.secondary || ButtonVariant.outline => (
        fill: hovered ? colors.surfaceHover : Colors.transparent,
        ink: colors.textPrimary,
        border: colors.borderHighlight,
      ),
      ButtonVariant.ghost => (
        fill: hovered ? colors.surfaceHover : Colors.transparent,
        ink: hovered ? colors.textPrimary : colors.textSecondary,
        border: Colors.transparent,
      ),
      ButtonVariant.destructive => (
        fill: hovered
            ? colors.error.withValues(alpha: SkotiqTokens.opacityStatusFill)
            : Colors.transparent,
        ink: colors.error,
        border: colors.error,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final isDisabled = widget.onPressed == null || widget.isLoading;
    final face = _face(colors);

    return Semantics(
      button: true,
      enabled: !isDisabled,
      label: widget.badge == null
          ? widget.label
          : '${widget.label}, ${widget.badgeSemanticsLabel ?? widget.badge}',
      hint: widget.semanticsHint,
      child: MouseRegion(
        onEnter: (_) => _setHovered(true),
        onExit: (_) {
          _setHovered(false);
          _releasePress();
        },
        cursor: isDisabled
            ? SystemMouseCursors.forbidden
            : SystemMouseCursors.click,
        // A bare GestureDetector has no focus node, so every SkotiqButton
        // in the app was invisible to Tab traversal and could not be activated
        // from the keyboard at all. Live proof: in the 13-step setup wizard the
        // ONLY control Tab could reach was the header's "Skip onboarding"
        // TextButton — three consecutive Tab presses produced a pixel-identical
        // frame, and Return abandoned setup. The wizard was impossible to
        // complete without a mouse.
        child: FocusableActionDetector(
          enabled: !isDisabled,
          onShowFocusHighlight: (value) {
            if (!mounted || _isFocused == value) return;
            setState(() => _isFocused = value);
          },
          actions: <Type, Action<Intent>>{
            // Enter and Space both arrive as ActivateIntent from the app-level
            // default shortcuts; ButtonActivateIntent is the web variant.
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
            ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          // Every tap callback is dropped when disabled, not just `onTap`.
          // `GestureDetector` registers a `TapGestureRecognizer` — and with it
          // a `SemanticsAction.tap` on this node — if ANY of onTapDown/onTapUp/
          // onTapCancel/onTap is non-null. A disabled button that leaves one
          // wired publishes an actionable node: correct
          // `hasEnabledState`/`isEnabled` flags with a live tap action beside
          // them, which the Linux AT-SPI bridge reports as an enabled
          // `button: Start Alignment` carrying no disabled marker.
          child: GestureDetector(
            onTapDown: isDisabled ? null : _handleTapDown,
            onTapUp: isDisabled ? null : _handleTapUp,
            onTapCancel: isDisabled ? null : _handleTapCancel,
            onTap: isDisabled ? null : widget.onPressed,
            child: AnimatedBuilder(
              animation: _scaleAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _scaleAnimation.value,
                  child: child,
                );
              },
              // Disabled is one opacity over the resting face, so a disabled
              // destructive is still recognisably the destructive one and a
              // disabled primary is still the primary.
              child: Opacity(
                opacity: isDisabled ? SkotiqTokens.opacityDisabled : 1,
                child: _box(colors, face),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _box(SkotiqColors colors, _ButtonFace face) {
    // The focus ring is a STROKE painted in an overflowing Positioned rather
    // than a spread `BoxShadow` on the button itself. A spread shadow is a
    // *filled* round-rect painted behind the box, so on the `ghost` and
    // `secondary` variants — whose fill is transparent until hover — it showed
    // straight through the middle and turned the whole control into a solid
    // primary slab with unreadable label text. Stroking it keeps the interior
    // untouched for every variant.
    //
    // The Stack is unconditional (so the AnimatedContainer keeps its element
    // slot, and with it the in-flight colour animation) and sizes itself to its
    // only non-positioned child, so mounting the ring costs no layout:
    // `Clip.none` lets it draw the 2px outside.
    return Stack(
      clipBehavior: Clip.none,
      // passthrough, NOT the default loose fit: a loose Stack strips the
      // incoming minimum, so a button handed tight constraints —
      // `Expanded(child: SkotiqButton(...))`, a stretched column — would
      // silently shrink to its content. passthrough hands the container exactly
      // the constraints it saw before this Stack existed.
      fit: StackFit.passthrough,
      children: <Widget>[
        AnimatedContainer(
          duration: SkotiqTokens.durationNormal,
          curve: SkotiqTokens.curveStandard,
          height: widget.height,
          // No `alignment`: a Container that aligns its child takes the whole
          // slot it is offered, so every button in a `crossAxisAlignment:
          // start` Column — which hands its children LOOSE, not tight,
          // constraints — stretched to the full page width and read as a
          // banner instead of a button (02 rule 4). Without it the container
          // shrink-wraps the label row when the slot is loose and still fills
          // a tight one, where the row's own `mainAxisAlignment: center`
          // centres the label.
          // Floor the tappable box on touch platforms. `constraints` rather
          // than extra padding so the fill and border grow with it and the
          // whole visible control is the target, not a small shape inside a
          // larger invisible one.
          constraints: BoxConstraints(
            minWidth: _minInteractiveExtent,
            minHeight: _minInteractiveExtent,
          ),
          padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
          decoration: BoxDecoration(
            color: face.fill,
            borderRadius: SkotiqTokens.borderRadiusSm,
            border: Border.all(color: face.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (widget.isLoading) ...<Widget>[
                SizedBox(
                  width: _iconSize,
                  height: _iconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(face.ink),
                  ),
                ),
                const SizedBox(width: _buttonIconGap),
              ] else if (widget.icon != null) ...<Widget>[
                Icon(widget.icon, size: _iconSize, color: face.ink),
                const SizedBox(width: _buttonIconGap),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  style: _textStyle.copyWith(color: face.ink),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              if (widget.badge != null) ...<Widget>[
                const SizedBox(width: _buttonIconGap),
                _Badge(
                  value: widget.badge!,
                  ink: face.ink,
                  tone: widget.badgeTone,
                ),
              ],
            ],
          ),
        ),
        if (_isFocused && widget.onPressed != null)
          Positioned(
            left: -_focusRingOffset,
            top: -_focusRingOffset,
            right: -_focusRingOffset,
            bottom: -_focusRingOffset,
            // The ring sits over the button's own hit box, so it must not eat
            // the pointer events the button exists to receive.
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    SkotiqTokens.radiusSm + _focusRingOffset,
                  ),
                  border: Border.all(
                    color: colors.primary,
                    width: _focusRingWidth,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The count on a button's trailing edge.
///
/// A chip's face at a chip's radius, sized from the button's own ink so it
/// belongs to the control rather than sitting on it. It carries no semantics:
/// the button's node already says what the number means.
class _Badge extends StatelessWidget {
  const _Badge({required this.value, required this.ink, this.tone});

  final String value;
  final Color ink;
  final ChipTone? tone;

  /// The badge's height in logical pixels — the chip scale, minus the air a
  /// chip needs when it stands alone.
  static const double height = 18;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final toneColor = tone?.resolve(colors) ?? ink;
    return ExcludeSemantics(
      child: Container(
        height: height,
        constraints: const BoxConstraints(minWidth: height),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceXs + 1,
        ),
        decoration: BoxDecoration(
          color: toneColor.withValues(alpha: SkotiqTokens.opacityStatusFill),
          borderRadius: SkotiqTokens.borderRadiusXs,
        ),
        child: Text(
          value,
          style: SkotiqTypography.monoCaption.copyWith(
            color: toneColor,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
        ),
      ),
    );
  }
}
