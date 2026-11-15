import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The 28 px strip under the narrow page header (06 §Imaging, "Narrow").
///
/// Below the shell breakpoint there is no instrument bar (04 §5), so this is
/// the one place the rig's state is on screen while imaging. It is built from
/// the same [InstrumentPill] the instrument bar uses — one status surface, one
/// component — and it scrolls rather than truncating a device's name, with
/// the edge that has more pills faded so the strip reads as one that scrolls.
class ImagingStatusStrip extends ConsumerWidget {
  const ImagingStatusStrip({super.key});

  /// Widest a device value may be before it ellipsizes.
  static const double _valueMaxWidth = 96;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final cameraState = ref.watch(cameraStateProvider);
    final mountState = ref.watch(mountStateProvider);
    final guiderState = ref.watch(guiderStateProvider);
    final focuserState = ref.watch(focuserStateProvider);

    final cameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final focuserConnected =
        focuserState.connectionState == DeviceConnectionState.connected;
    final guiderConnected =
        guiderState.connectionState == DeviceConnectionState.connected;

    return Container(
      height: ShellChromeMetrics.narrowStatusStripHeight,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
      ),
      child: _FadingHorizontalScroll(
        child: Row(
          children: <Widget>[
            InstrumentPill(
              icon: SkotiqIcons.camera,
              dotTone: _tone(cameraState.connectionState),
              value: cameraConnected && cameraState.temperature != null
                  ? formatCelsius(cameraState.temperature!)
                  : (cameraConnected ? 'Ready' : 'Not connected'),
              mono: cameraConnected && cameraState.temperature != null,
              semanticLabel:
                  cameraConnected ? 'Camera connected' : 'Camera not connected',
              maxValueWidth: _valueMaxWidth,
            ),
            const InstrumentSeparator(),
            InstrumentPill(
              icon: SkotiqIcons.mount,
              dotTone: _tone(mountState.connectionState),
              value: _mountValue(mountState),
              // Sentence case for the reader: "Mount not connected", not "Mount Not
              // connected".
              semanticLabel: 'Mount ${_lowerFirst(_mountValue(mountState))}',
              maxValueWidth: _valueMaxWidth,
            ),
            const InstrumentSeparator(),
            InstrumentPill(
              icon: SkotiqIcons.guider,
              dotTone: _tone(guiderState.connectionState),
              value: guiderConnected
                  ? (guiderState.isGuiding ? 'Guiding' : 'Ready')
                  : 'Not connected',
              semanticLabel: guiderConnected
                  ? 'Guider ${guiderState.isGuiding ? 'guiding' : 'ready'}'
                  : 'Guider not connected',
              maxValueWidth: _valueMaxWidth,
            ),
            const InstrumentSeparator(),
            InstrumentPill(
              icon: SkotiqIcons.focuser,
              dotTone: _tone(focuserState.connectionState),
              // The POSITION, not the word "Ready": a focuser's position is the
              // one thing about it worth a permanent slot in the chrome.
              value: focuserConnected
                  ? (focuserState.position?.toString() ?? 'Ready')
                  : 'Not connected',
              mono: focuserConnected && focuserState.position != null,
              semanticLabel: focuserConnected
                  ? 'Focuser at ${focuserState.position ?? 'unknown'}'
                  : 'Focuser not connected',
              maxValueWidth: _valueMaxWidth,
            ),
          ],
        ),
      ),
    );
  }

  static String _mountValue(MountState state) {
    if (state.connectionState != DeviceConnectionState.connected) {
      return 'Not connected';
    }
    if (state.isSlewing) return 'Slewing';
    if (state.isParked) return 'Parked';
    if (state.isTracking) return 'Tracking';
    return 'Ready';
  }

  static InstrumentTone _tone(DeviceConnectionState state) {
    return switch (state) {
      DeviceConnectionState.connected => InstrumentTone.success,
      DeviceConnectionState.connecting => InstrumentTone.warning,
      DeviceConnectionState.error => InstrumentTone.error,
      _ => InstrumentTone.idle,
    };
  }
}

/// A horizontal scroll whose edges fade where more content lies past them.
class _FadingHorizontalScroll extends StatefulWidget {
  const _FadingHorizontalScroll({required this.child});

  final Widget child;

  @override
  State<_FadingHorizontalScroll> createState() =>
      _FadingHorizontalScrollState();
}

class _FadingHorizontalScrollState extends State<_FadingHorizontalScroll> {
  static const double _fadeWidth = SkotiqTokens.space2xl;

  final ScrollController _controller = ScrollController();
  bool _moreBefore = false;
  bool _moreAfter = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_sync);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _sync() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    final before = position.pixels > position.minScrollExtent;
    final after = position.pixels < position.maxScrollExtent;
    if (before != _moreBefore || after != _moreAfter) {
      setState(() {
        _moreBefore = before;
        _moreAfter = after;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // The extent is known only after layout, and changes with the pills.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    final opaque = context.skotiqColors.background;
    final clear = opaque.withValues(alpha: 0);
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final fade = (_fadeWidth / bounds.width).clamp(0.0, 0.5);
        return LinearGradient(
          colors: [
            _moreBefore ? clear : opaque,
            opaque,
            opaque,
            _moreAfter ? clear : opaque,
          ],
          stops: [0, fade, 1 - fade, 1],
        ).createShader(bounds);
      },
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: widget.child,
      ),
    );
  }
}

String _lowerFirst(String s) =>
    s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
