import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Renders a decoded drawdown image, scaled to fit with crisp nearest-neighbor
/// cells. Pure presentation: it consumes an already-decoded [ui.Image] and never
/// touches the FFI bridge. Decoding (RGBA buffer -> ui.Image) lives in
/// `DraftRepository.renderDrawdown`, so this widget is reusable for both live
/// previews and saved-PNG-less re-renders without pulling in generated symbols.
class DrawdownView extends StatelessWidget {
  const DrawdownView(this.image, {super.key, this.framed = true});

  final ui.Image image;

  /// When true, draw a thin outline around the cloth so its (often white) edges
  /// read against the background. Thumbnail tiles pass `framed: false`.
  final bool framed;

  @override
  Widget build(BuildContext context) {
    Widget content = CustomPaint(painter: DrawdownPainter(image));
    if (framed) {
      // Frame the cloth so its edges read against the background and it isn't bled
      // to the container edges. Foreground position so the border sits over the paint.
      content = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: content,
      );
    }
    return RepaintBoundary(
      child: AspectRatio(
        aspectRatio: image.width / image.height,
        child: content,
      ),
    );
  }
}

/// Blits the drawdown image, scaled to fit with nearest-neighbor sampling so weave
/// cells stay crisp squares. No vertical flip — the engine already put pick 0 at the
/// bottom (see the orientation contract in DraftRepository.renderDrawdown).
class DrawdownPainter extends CustomPainter {
  DrawdownPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final src = Offset.zero & imageSize;
    final fitted = applyBoxFit(BoxFit.contain, imageSize, size);
    final dst = Alignment.center.inscribe(fitted.destination, Offset.zero & size);
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(covariant DrawdownPainter oldDelegate) => oldDelegate.image != image;
}
