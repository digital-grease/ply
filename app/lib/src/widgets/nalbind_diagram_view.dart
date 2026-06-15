import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../rust/nalbind_dto.dart';

/// Draws a [DiagramDto] (the engine's vector loop diagram) as a structural sketch: each loop is an
/// arch the working thread weaves OVER (thread in front) or UNDER (thread behind); skipped loops are
/// faint; turns are dotted separators; connections are labelled arrows into the previous round.
///
/// The engine emits abstract unit coordinates (1.0 = one loop slot); this widget scales them to the
/// given height and is horizontally scrollable for long, multi-pass stitches.
class NalbindDiagramView extends StatelessWidget {
  const NalbindDiagramView({required this.diagram, this.height = 96, super.key});

  final DiagramDto diagram;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scale = height / diagram.height;
    final width = math.max(diagram.width * scale, 1.0);
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
    final baseline = diagram.baseline * scale;
    final archW = 0.66 * scale;
    final archH = 1.15 * scale;

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

    // 1. The working thread, full width at the baseline.
    canvas.drawLine(Offset(0, baseline), Offset(size.width, baseline), threadPaint);

    // 2. Each loop as an arch on the baseline (faint if skipped).
    for (final g in diagram.loops) {
      if (g.kind == LoopKindDto.noLoop) continue;
      final skipped = g.kind == LoopKindDto.overSkipped || g.kind == LoopKindDto.underSkipped;
      _arch(canvas, g.x * scale, baseline, archW, archH, skipped ? faintPaint : loopPaint);
    }

    // 3. For OVER-engaged loops, redraw the thread over the arch base so it reads as in-front.
    for (final g in diagram.loops) {
      if (g.kind != LoopKindDto.overEngaged) continue;
      final cx = g.x * scale;
      canvas.drawLine(
        Offset(cx - archW / 2 - 1, baseline),
        Offset(cx + archW / 2 + 1, baseline),
        threadPaint,
      );
    }

    // 4. Turn separators (dotted vertical lines) between passes.
    for (final tx in diagram.turns) {
      _dottedV(canvas, tx * scale, 0.2 * scale, baseline, faintPaint);
    }

    // 5. Connection arrows into the previous round, below the baseline, labelled (F2/B1/M…).
    final connPaint = Paint()
      ..color = connection
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final c in diagram.connections) {
      final cx = c.x * scale;
      final yTop = baseline + 0.15 * scale;
      final yBot = baseline + 0.85 * scale;
      canvas.drawLine(Offset(cx, yTop), Offset(cx, yBot), connPaint);
      // arrowhead pointing down (into the fabric)
      canvas.drawLine(Offset(cx, yBot), Offset(cx - 3, yBot - 4), connPaint);
      canvas.drawLine(Offset(cx, yBot), Offset(cx + 3, yBot - 4), connPaint);
      _label(canvas, _connLabel(c), Offset(cx + 5, yTop - 2));
    }
  }

  void _arch(Canvas canvas, double cx, double baseline, double w, double h, Paint paint) {
    // The top half of an ellipse sitting on the baseline (a ∩ bight). Legs dip slightly below the
    // baseline so they visibly cross the working thread.
    final rect = Rect.fromCenter(center: Offset(cx, baseline + 0.12 * scale), width: w, height: h * 2);
    canvas.drawArc(rect, math.pi, math.pi, false, paint);
  }

  void _dottedV(Canvas canvas, double x, double yTop, double yBot, Paint paint) {
    const dash = 3.0, gap = 3.0;
    var y = yTop;
    while (y < yBot) {
      canvas.drawLine(Offset(x, y), Offset(x, math.min(y + dash, yBot)), paint);
      y += dash + gap;
    }
  }

  void _label(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  String _connLabel(ConnArrowDto c) {
    final side = switch (c.side) {
      ConnSideKind.front => 'F',
      ConnSideKind.back => 'B',
      ConnSideKind.middle => 'M',
    };
    return '$side${c.count}';
  }

  @override
  bool shouldRepaint(_NalbindDiagramPainter old) =>
      old.diagram != diagram || old.scale != scale || old.thread != thread;
}
