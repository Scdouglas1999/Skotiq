part of '../settings_widgets.dart';

enum SettingsNoticeTone { info, error }

/// Lets an input raise a short message beside itself: what was wrong with an
/// entry, or that a save failed and the previous value is back.
class SettingsNoticeController extends ChangeNotifier {
  String? _message;
  SettingsNoticeTone _tone = SettingsNoticeTone.info;

  String? get message => _message;
  SettingsNoticeTone get tone => _tone;

  void show(String message,
      {SettingsNoticeTone tone = SettingsNoticeTone.info}) {
    _message = message;
    _tone = tone;
    notifyListeners();
  }

  void clear() {
    if (_message == null) return;
    _message = null;
    notifyListeners();
  }
}

/// Thrown by a write callback that has already told the operator why the
/// value was refused (an inline message, its own snackbar). The input still
/// restores the stored value; it just does not say it a second time.
class SettingWriteHandled implements Exception {
  const SettingWriteHandled(this.cause);

  final Object cause;

  @override
  String toString() => cause.toString();
}

/// Tells the operator a save failed and the stored value is back, unless the
/// write callback already did ([SettingWriteHandled]).
void settingsReportRollback(
  BuildContext context,
  SettingsNoticeController notice,
  Object error,
) {
  if (error is SettingWriteHandled) return;
  final label = SettingRowLabel.maybeOf(context);
  final what = label == null ? 'This setting' : '"$label"';
  var reason = userFacingError(error).trim();
  if (reason.endsWith('.')) reason = reason.substring(0, reason.length - 1);
  notice.show(
    '$what was not saved: $reason. The previous value is shown.',
    tone: SettingsNoticeTone.error,
  );
}

/// Shows its controller's message in a small bubble under [child], above the
/// page, so a message never moves the row it belongs to.
class SettingsFieldNotice extends StatefulWidget {
  const SettingsFieldNotice({
    super.key,
    required this.controller,
    required this.child,
  });

  final SettingsNoticeController controller;
  final Widget child;

  /// How long a message stays up unless the operator edits again first.
  static const Duration visibleFor = Duration(seconds: 6);

  @override
  State<SettingsFieldNotice> createState() => _SettingsFieldNoticeState();
}

class _SettingsFieldNoticeState extends State<SettingsFieldNotice> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onNotice);
  }

  @override
  void didUpdateWidget(covariant SettingsFieldNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onNotice);
      widget.controller.addListener(_onNotice);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onNotice);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onNotice() {
    if (!mounted) return;
    _hideTimer?.cancel();
    final message = widget.controller.message;
    if (message == null) {
      if (_portal.isShowing) _portal.hide();
      return;
    }
    if (Overlay.maybeOf(context) == null) {
      // No overlay to float in (a bare test host): a snackbar still tells.
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    _portal.show();
    setState(() {});
    _hideTimer = Timer(SettingsFieldNotice.visibleFor, widget.controller.clear);
  }

  @override
  Widget build(BuildContext context) {
    if (Overlay.maybeOf(context) == null) return widget.child;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildBubble,
        child: widget.child,
      ),
    );
  }

  Widget _buildBubble(BuildContext context) {
    final message = widget.controller.message;
    if (message == null) return const SizedBox.shrink();
    final colors = SkotiqColors.of(context);
    final isError = widget.controller.tone == SettingsNoticeTone.error;
    final accent = isError ? colors.error : colors.warning;
    final popover = SkotiqDecorations.popover(colors);
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, SkotiqTokens.spaceXs),
        child: IgnorePointer(
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Container(
              key: const ValueKey('settings-field-notice'),
              constraints: const BoxConstraints(maxWidth: 300),
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceMd,
                vertical: SkotiqTokens.spaceSm,
              ),
              decoration: popover.copyWith(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
                border: Border.all(color: accent),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      isError ? LucideIcons.alertTriangle : LucideIcons.info,
                      size: SkotiqTokens.iconXs,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Flexible(
                    child: Text(
                      message,
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textPrimary,
                      ),
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

/// The title of the [SettingRow] an input sits in, so its messages can name
/// the setting.
class SettingRowLabel extends InheritedWidget {
  const SettingRowLabel({super.key, required this.title, required super.child});

  final String title;

  static String? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SettingRowLabel>()?.title;

  @override
  bool updateShouldNotify(SettingRowLabel oldWidget) =>
      oldWidget.title != title;
}
