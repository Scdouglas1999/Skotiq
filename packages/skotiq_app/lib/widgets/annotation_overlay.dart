import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../screens/imaging/imaging_science_state.dart';
import '../utils/plan_tonight_sequencer_helper.dart';
import '../utils/preview_transform.dart';

part 'annotation_overlay/marker_pulse_overlay.dart';
part 'annotation_overlay/enhanced_annotation_painter.dart';
part 'annotation_overlay/object_info_tooltip.dart';

const _annotationOverlayTextColor = Color(0xFFFFFFFF);
const _annotationOverlayShadowColor = Color(0xFF000000);

/// Enhanced annotation overlay with fade effects, click-to-identify, hover tooltips, and customizable styles
class AnnotationOverlay extends ConsumerStatefulWidget {
  final ImageAnnotation? annotation;
  final double zoomLevel;
  final Offset imageOffset;
  final Size imageSize;
  final void Function(CelestialObjectAnnotation object)? onObjectTapped;
  final void Function(double x, double y)? onIdentifyAt;

  /// Called when the mouse hovers over a celestial object
  final void Function(CelestialObjectAnnotation object, Offset screenPosition)?
      onObjectHovered;

  /// Called when the mouse moves away from all objects
  final VoidCallback? onObjectUnhovered;

  const AnnotationOverlay({
    super.key,
    required this.annotation,
    this.zoomLevel = 1.0,
    this.imageOffset = Offset.zero,
    required this.imageSize,
    this.onObjectTapped,
    this.onIdentifyAt,
    this.onObjectHovered,
    this.onObjectUnhovered,
  });

  @override
  ConsumerState<AnnotationOverlay> createState() => _AnnotationOverlayState();
}

class _AnnotationOverlayState extends ConsumerState<AnnotationOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  bool _isHovering = false;

  /// On touch platforms (iOS/Android), annotations are toggled on/off by
  /// tapping anywhere on the image instead of using mouse hover fade.
  bool _touchAnnotationsVisible = true;

  // Hover detection state
  CelestialObjectAnnotation? _currentHoveredObject;
  Timer? _hoverDebounceTimer;
  static const _hoverDebounceMs = 75; // Delay before showing tooltip

  static bool get _isTouchPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Animation<double> _createFadeAnimation(AnnotationSettings settings) {
    return Tween<double>(
      begin: settings.idleOpacity,
      end: settings.hoverOpacity,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void initState() {
    super.initState();
    final settings = ref.read(annotationSettingsProvider).valueOrNull ??
        const AnnotationSettings();
    _fadeController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: settings.fadeAnimationMs),
    );
    _fadeAnimation = _createFadeAnimation(settings);
  }

  @override
  void dispose() {
    _hoverDebounceTimer?.cancel();
    _fadeController.dispose();
    super.dispose();
  }

  void _clearHoverState() {
    _hoverDebounceTimer?.cancel();
    if (_currentHoveredObject != null) {
      _currentHoveredObject = null;
      widget.onObjectUnhovered?.call();
    }
  }

  void _onHoverMove(PointerEvent event) {
    final settings = ref.read(annotationSettingsProvider).valueOrNull;
    if (settings == null) return;
    if (!settings.enabled || widget.annotation == null) return;

    final localPosition = event.localPosition;

    // Convert screen position to image coordinates
    final imagePoint = viewportToImage(
      viewportPoint: localPosition,
      imageOffset: widget.imageOffset,
      zoomLevel: widget.zoomLevel,
    );

    // Find the object under the cursor (if any)
    CelestialObjectAnnotation? foundObject;
    for (final object in widget.annotation!.objects) {
      // Skip objects that wouldn't be visible based on settings
      if (!object.visible) continue;
      if (object.magnitude != null) {
        if (object.magnitude! > settings.magnitudeCutoff) continue;
        if (object.magnitude! < settings.minMagnitude) continue;
      }
      if (!_isTypeVisibleForHover(object.type, settings.visibleTypes)) continue;

      final dx = object.x - imagePoint.dx;
      final dy = object.y - imagePoint.dy;
      final distance = (dx * dx + dy * dy);
      final hitRadius = (object.size ?? 30) * 1.5;

      if (distance < hitRadius * hitRadius) {
        foundObject = object;
        break;
      }
    }

    // Only update if the hovered object changed
    if (foundObject?.name != _currentHoveredObject?.name) {
      _hoverDebounceTimer?.cancel();

      if (foundObject != null) {
        // Debounce showing the tooltip to avoid flickering
        final objectToShow = foundObject;
        _hoverDebounceTimer =
            Timer(const Duration(milliseconds: _hoverDebounceMs), () {
          if (!mounted) return;
          _currentHoveredObject = objectToShow;

          // Calculate screen position for the tooltip
          final screenPosition = imageToViewport(
            imagePoint: Offset(objectToShow.x, objectToShow.y),
            imageOffset: widget.imageOffset,
            zoomLevel: widget.zoomLevel,
          );

          widget.onObjectHovered?.call(objectToShow, screenPosition);
        });
      } else {
        // Immediately clear when moving away from objects (no debounce needed)
        _currentHoveredObject = null;
        widget.onObjectUnhovered?.call();
      }
    }
  }

  bool _isTypeVisibleForHover(
      ObjectType type, Set<AnnotationObjectFilter> filters) {
    switch (type) {
      case ObjectType.galaxy:
        return filters.contains(AnnotationObjectFilter.galaxies);
      case ObjectType.nebula:
        return filters.contains(AnnotationObjectFilter.nebulae);
      case ObjectType.planetaryNebula:
        return filters.contains(AnnotationObjectFilter.planetaryNebulae);
      case ObjectType.starCluster:
        return filters.contains(AnnotationObjectFilter.starClusters);
      case ObjectType.star:
      case ObjectType.doubleStar:
        return filters.contains(AnnotationObjectFilter.stars);
      default:
        return filters.contains(AnnotationObjectFilter.other);
    }
  }

  bool _isObjectVisibleForInteraction(
    CelestialObjectAnnotation object,
    AnnotationSettings settings,
  ) {
    if (!object.visible) return false;
    if (object.magnitude != null) {
      if (object.magnitude! > settings.magnitudeCutoff) return false;
      if (object.magnitude! < settings.minMagnitude) return false;
    }
    return _isTypeVisibleForHover(object.type, settings.visibleTypes);
  }

  void _onHoverChanged(bool hovering) {
    if (_isHovering == hovering) return;
    _isHovering = hovering;
    ref.read(annotationHoverStateProvider.notifier).state = hovering;

    final settings = ref.read(annotationSettingsProvider).valueOrNull;
    if (settings == null) {
      _clearHoverState();
      return;
    }
    if (!settings.fadeWhenNotHovering) return;

    if (hovering) {
      _fadeController.forward();
    } else {
      _fadeController.reverse();
      // When mouse leaves the overlay entirely, clear hover state
      _clearHoverState();
    }
  }

  CelestialObjectAnnotation? _objectAt(
    Offset imagePoint,
    AnnotationSettings settings,
  ) {
    if (widget.annotation == null) return null;
    for (final object in widget.annotation!.objects) {
      if (!_isObjectVisibleForInteraction(object, settings)) continue;

      final dx = object.x - imagePoint.dx;
      final dy = object.y - imagePoint.dy;
      final distance = (dx * dx + dy * dy);
      final hitRadius = (object.size ?? 30) * 1.5;

      if (distance < hitRadius * hitRadius) return object;
    }
    return null;
  }

  void _onTapUp(TapUpDetails details) {
    final settings = ref.read(annotationSettingsProvider).valueOrNull;
    if (settings == null) return;

    final imagePoint = viewportToImage(
      viewportPoint: details.localPosition,
      imageOffset: widget.imageOffset,
      zoomLevel: widget.zoomLevel,
    );

    final object = _objectAt(imagePoint, settings);
    if (object != null) {
      widget.onObjectTapped?.call(object);
      return;
    }

    // On touch platforms, tapping empty space toggles annotation visibility
    if (_isTouchPlatform) {
      setState(() {
        _touchAnnotationsVisible = !_touchAnnotationsVisible;
      });
      return;
    }

    // On desktop, no object hit triggers identify at position
    if (!settings.clickToIdentify) return;
    widget.onIdentifyAt?.call(imagePoint.dx, imagePoint.dy);
  }

  /// Touch-platform identify gesture. Tap is reserved for visibility toggling,
  /// so long-press (and secondary-tap where a pointer provides it) runs the
  /// same object-tap / click-to-identify path desktop gets from a plain click.
  void _onIdentifyGesture(Offset localPosition) {
    final settings = ref.read(annotationSettingsProvider).valueOrNull;
    if (settings == null) return;

    final imagePoint = viewportToImage(
      viewportPoint: localPosition,
      imageOffset: widget.imageOffset,
      zoomLevel: widget.zoomLevel,
    );

    final object = _objectAt(imagePoint, settings);
    if (object != null) {
      widget.onObjectTapped?.call(object);
      return;
    }

    if (!settings.clickToIdentify) return;
    widget.onIdentifyAt?.call(imagePoint.dx, imagePoint.dy);
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(annotationSettingsProvider);
    final markerStyleAsync = ref.watch(annotationMarkerStyleProvider);

    final settings = settingsAsync.valueOrNull;
    final markerStyle = markerStyleAsync.valueOrNull;

    if (settings == null || markerStyle == null) {
      return const SizedBox.shrink();
    }

    _fadeController.duration = Duration(milliseconds: settings.fadeAnimationMs);
    _fadeAnimation = _createFadeAnimation(settings);

    if (!settings.enabled || widget.annotation == null) {
      return const SizedBox.shrink();
    }

    final annotationPaint = CustomPaint(
      painter: EnhancedAnnotationPainter(
        annotation: widget.annotation!,
        settings: settings,
        markerStyle: markerStyle,
        zoomLevel: widget.zoomLevel,
        imageOffset: widget.imageOffset,
      ),
      size: Size.infinite,
    );

    // On touch platforms: no fade, use tap-to-toggle visibility instead
    if (_isTouchPlatform) {
      return Stack(
        children: [
          GestureDetector(
            onTapUp: _onTapUp,
            onLongPressStart: (d) => _onIdentifyGesture(d.localPosition),
            onSecondaryTapUp: (d) => _onIdentifyGesture(d.localPosition),
            behavior: HitTestBehavior.translucent,
            child: Opacity(
              opacity: _touchAnnotationsVisible ? settings.hoverOpacity : 0.0,
              child: annotationPaint,
            ),
          ),
          _MarkerPulseOverlay(
            annotation: widget.annotation!,
            zoomLevel: widget.zoomLevel,
            imageOffset: widget.imageOffset,
            markerStyle: markerStyle,
          ),
        ],
      );
    }

    // On desktop: use mouse hover fade behavior
    return Stack(
      children: [
        MouseRegion(
          onEnter: (_) => _onHoverChanged(true),
          onExit: (_) => _onHoverChanged(false),
          onHover: _onHoverMove,
          child: GestureDetector(
            onTapUp: _onTapUp,
            behavior: HitTestBehavior.translucent,
            child: AnimatedBuilder(
              animation: _fadeAnimation,
              builder: (context, child) {
                final opacity = settings.fadeWhenNotHovering
                    ? _fadeAnimation.value
                    : settings.hoverOpacity;

                return Opacity(
                  opacity: opacity,
                  child: annotationPaint,
                );
              },
            ),
          ),
        ),
        _MarkerPulseOverlay(
          annotation: widget.annotation!,
          zoomLevel: widget.zoomLevel,
          imageOffset: widget.imageOffset,
          markerStyle: markerStyle,
        ),
      ],
    );
  }
}
