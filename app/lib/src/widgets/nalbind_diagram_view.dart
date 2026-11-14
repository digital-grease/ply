import 'package:flutter/material.dart';

import '../models/nalbind_diagram_shapes.dart';
import '../rust/nalbind_dto.dart';

/// Draws a [DiagramDto] (the engine's vector loop diagram) as a structural sketch: each loop is an
/// arch the working thread weaves OVER (thread in front) or UNDER (thread behind); skipped loops are
/// faint; turns are dotted separators; connections are labelled arrows into the previous round.
///
/// The engine emits abstract unit coordinates (1.0 = one loop slot); this widget scales them to the
/// given height and is horizontally scrollable for long, multi-pass stitches.
///
/// Every diagram carries the [caption] saying it is a schematic, wherever it is drawn. An
/// [approximate] diagram (drawn from a notation that was not read exactly) is dimmed under a label
/// that says so, so a best-effort reading is never presented as what the text says.
class NalbindDiagramView extends StatelessWidget {
  const NalbindDiagramView({
    required this.diagram,
    this.height = 96,
    this.approximate = false,
    super.key,
  });

  final DiagramDto diagram;

  /// The height of the drawing itself (the labels add to it).
  final double height;

  /// True when the diagram comes from a best-effort reading of the notation.
  final bool approximate;

  /// Under every diagram: it is a schematic, not a picture of the cloth.
  static const caption = "Sketch of one stitch's needle path, not a picture of finished fabric.";

  /// Above an [approximate] diagram.
  static const approximateLabel =
      'Approximate: the notation was not read exactly, so this sketch may be wrong.';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    Widget drawing = _drawing(cs);
    if (approximate) drawing = Opacity(opacity: 0.45, child: drawing);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (approximate)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: cs.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(approximateLabel, style: small?.copyWith(color: cs.error)),
                ),
              ],
            ),
          ),
        drawing,
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(caption, style: small?.copyWith(color: cs.onSurfaceVariant)),
        ),
      ],
    );
  }

  Widget _drawing(ColorScheme cs) {
    final scale = height / diagram.height;
    final width = nalbindDiagramWidth(diagram, scale);
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: CustomPaint(
          size: Size(width, height),
          painter: _NalbindDiagramPainter(
            diagram: diagram,
            scale: scale,
            thread: cs.onSurface,
            loop: cs.primary,
            faint: cs.outlineVariant,
            connection: cs.tertiary,
            labelStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 11, height: 1),
          ),
        ),
      ),
    );
  }
}

class _NalbindDiagramPainter extends CustomPainter {
  _NalbindDiagramPainter({
    required this.diagram,
    required this.scale,
    required this.thread,
    required this.loop,
    required this.faint,
    required this.connection,
    required this.labelStyle,
  });

  final DiagramDto diagram;
  final double scale;
  final Color thread;
  final Color loop;
  final Color faint;
  final Color connection;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final threadPaint = Paint()
      ..color = thread
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final loopPaint = Paint()
      ..color = loop
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final faintPaint = Paint()
      ..color = faint
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final connPaint = Paint()
      ..color = connection
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    Paint paintFor(DiagramInk ink) => switch (ink) {
          DiagramInk.thread => threadPaint,
          DiagramInk.loop => loopPaint,
          DiagramInk.faint => faintPaint,
          DiagramInk.connection || DiagramInk.label => connPaint,
        };

    // The shared geometry (the printed PDF draws the same shapes), in paint order.
    for (final shape in nalbindDiagramShapes(diagram, scale)) {
      switch (shape) {
        case DiagramLine(:final from, :final to, :final ink):
          canvas.drawLine(from, to, paintFor(ink));
        case DiagramArc(:final rect, :final startAngle, :final sweepAngle, :final ink):
          canvas.drawArc(rect, startAngle, sweepAngle, false, paintFor(ink));
        case DiagramLabel(:final topLeft, :final text):
          _label(canvas, text, topLeft);
      }
    }
  }

  void _label(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_NalbindDiagramPainter old) =>
      old.diagram != diagram || old.scale != scale || old.thread != thread;
}
