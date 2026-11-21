import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Decodes a pre-rendered RGBA8 buffer (such as a Live Darkroom render) into a
/// drawable [ui.Image] and hands it to [builder].
class RgbaImageSource extends StatefulWidget {
  const RgbaImageSource({
    super.key,
    required this.rgba,
    required this.width,
    required this.height,
    required this.builder,
    this.placeholder,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final Widget Function(BuildContext context, ui.Image image) builder;
  final Widget? placeholder;

  @override
  State<RgbaImageSource> createState() => _RgbaImageSourceState();
}

class _RgbaImageSourceState extends State<RgbaImageSource> {
  ui.Image? _image;
  int _generation = 0;
  bool _decoding = false;
  bool _pendingDecode = false;

  @override
  void initState() {
    super.initState();
    _scheduleDecode();
  }

  @override
  void didUpdateWidget(covariant RgbaImageSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.rgba, oldWidget.rgba) ||
        widget.width != oldWidget.width ||
        widget.height != oldWidget.height) {
      _scheduleDecode();
    }
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  void _scheduleDecode() {
    _generation++;
    if (_decoding) {
      _pendingDecode = true;
      return;
    }
    unawaited(_decode());
  }

  Future<void> _decode() async {
    _decoding = true;
    _pendingDecode = false;
    final w = widget.width;
    final h = widget.height;
    final expected = w * h * 4;
    if (w <= 0 || h <= 0 || widget.rgba.length < expected) {
      _decoding = false;
      return;
    }

    final gen = _generation;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(widget.rgba);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();

      if (!mounted || gen != _generation) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = frame.image;
      });
    } catch (error) {
      developer.log(
        '[RgbaImageSource] Failed to decode RGBA preview: $error',
        name: 'RgbaImageSource',
        error: error,
      );
    } finally {
      _decoding = false;
      if (mounted && _pendingDecode) {
        _pendingDecode = false;
        unawaited(_decode());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return widget.placeholder ?? const SizedBox.shrink();
    }
    return widget.builder(context, image);
  }
}
