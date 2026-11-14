// The nalbinding loop diagram as a list of drawing primitives, shared by the on-screen painter
// (`NalbindDiagramView`) and the printable PDF (`lib/src/print/nalbind_print.dart`), so a printed
// sketch can never drift from the one on screen. Pure geometry: no colors, stroke widths or fonts
// (each renderer maps a shape's [DiagramInk] to its own style).

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import '../rust/nalbind_dto.dart';

/// What a shape draws, so a renderer can pick its style.
enum DiagramInk {
  /// The working thread.
  thread,

  /// An engaged loop's arch.
  loop,

  /// A skipped loop's arch, and the dotted turn separators.
  faint,

  /// A connection arrow into the previous round.
  connection,

  /// A connection's text label.
  label,
}

/// One drawing primitive, in paint order, in coordinates where y grows DOWN (as on screen).
sealed class DiagramShape {
  const DiagramShape(this.ink);
  final DiagramInk ink;
}

/// A straight segment.
final class DiagramLine extends DiagramShape {
  const DiagramLine(this.from, this.to, super.ink);
  final Offset from;
  final Offset to;
}

/// An elliptical arc of the oval inscribed in [rect], from [startAngle] through [sweepAngle]
/// (radians, clockwise on screen, Flutter's `Canvas.drawArc` convention).
final class DiagramArc extends DiagramShape {
  const DiagramArc(this.rect, this.startAngle, this.sweepAngle, super.ink);
  final Rect rect;
  final double startAngle;
  final double sweepAngle;
}

/// A text label whose top-left corner is [topLeft].
final class DiagramLabel extends DiagramShape {
  const DiagramLabel(this.topLeft, this.text) : super(DiagramInk.label);
  final Offset topLeft;
  final String text;
}

/// The drawn width of [diagram] at [scale] units per loop slot (never zero).
double nalbindDiagramWidth(DiagramDto diagram, double scale) =>
    math.max(diagram.width * scale, 1.0);

/// The drawn height of [diagram] at [scale].
double nalbindDiagramHeight(DiagramDto diagram, double scale) => diagram.height * scale;

/// [diagram] (the engine's abstract unit coordinates, 1.0 = one loop slot) as primitives at [scale]:
/// each loop an arch the working thread weaves OVER (thread in front) or UNDER (thread behind);
/// skipped loops faint; turns dotted separators; connections labelled arrows into the previous
/// round. Fixed offsets (arrowheads, dashes, label nudges) are in output units, not loop slots.
List<DiagramShape> nalbindDiagramShapes(DiagramDto diagram, double scale) {
  final shapes = <DiagramShape>[];
  final width = nalbindDiagramWidth(diagram, scale);
  final baseline = diagram.baseline * scale;
  final archW = 0.66 * scale;
  final archH = 1.15 * scale;

  // 1. The working thread, full width at the baseline.
  shapes.add(DiagramLine(Offset(0, baseline), Offset(width, baseline), DiagramInk.thread));

  // 2. Each loop as an arch on the baseline (faint if skipped): the top half of an ellipse whose
  // legs dip slightly below the baseline so they visibly cross the working thread.
  for (final g in diagram.loops) {
    if (g.kind == LoopKindDto.noLoop) continue;
    final skipped = g.kind == LoopKindDto.overSkipped || g.kind == LoopKindDto.underSkipped;
    final rect = Rect.fromCenter(
      center: Offset(g.x * scale, baseline + 0.12 * scale),
      width: archW,
      height: archH * 2,
    );
    shapes.add(DiagramArc(rect, math.pi, math.pi, skipped ? DiagramInk.faint : DiagramInk.loop));
  }

  // 3. For OVER-engaged loops, redraw the thread over the arch base so it reads as in front.
  for (final g in diagram.loops) {
    if (g.kind != LoopKindDto.overEngaged) continue;
    final cx = g.x * scale;
    shapes.add(DiagramLine(
      Offset(cx - archW / 2 - 1, baseline),
      Offset(cx + archW / 2 + 1, baseline),
      DiagramInk.thread,
    ));
  }

  // 4. Turn separators (dotted vertical lines) between passes.
  const dash = 3.0, gap = 3.0;
  for (final tx in diagram.turns) {
    final x = tx * scale;
    var y = 0.2 * scale;
    while (y < baseline) {
      shapes.add(
          DiagramLine(Offset(x, y), Offset(x, math.min(y + dash, baseline)), DiagramInk.faint));
      y += dash + gap;
    }
  }

  // 5. Connection arrows into the previous round, below the baseline, labelled (F2/B1/M1...).
  for (final c in diagram.connections) {
    final cx = c.x * scale;
    final yTop = baseline + 0.15 * scale;
    final yBot = baseline + 0.85 * scale;
    shapes
      ..add(DiagramLine(Offset(cx, yTop), Offset(cx, yBot), DiagramInk.connection))
      // The arrowhead, pointing down (into the fabric).
      ..add(DiagramLine(Offset(cx, yBot), Offset(cx - 3, yBot - 4), DiagramInk.connection))
      ..add(DiagramLine(Offset(cx, yBot), Offset(cx + 3, yBot - 4), DiagramInk.connection))
      ..add(DiagramLabel(Offset(cx + 5, yTop - 2), connectionLabel(c)));
  }
  return shapes;
}

/// A connection arrow's label: its side letter and count ("F2", "B1", "M1").
String connectionLabel(ConnArrowDto c) {
  final side = switch (c.side) {
    ConnSideKind.front => 'F',
    ConnSideKind.back => 'B',
    ConnSideKind.middle => 'M',
  };
  return '$side${c.count}';
}
