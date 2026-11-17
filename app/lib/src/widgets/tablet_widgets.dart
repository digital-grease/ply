// Small pieces the tablet weaving editor shares (M10-02, ADR 0018): the review note every computed
// result carries, the card diagram (a side view from the weaver's right, ADR 0018 section 1), colour
// swatches, and diagnostics in words.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/tablet_band.dart';
import '../print/tablet_print.dart' show tabletPlaceText;
import '../rust/tablet_dto.dart';
import '../theme/ply_colors.dart';

/// Stops a text field at [maxBytes] bytes of UTF-8 (the document's limits are in bytes, so a name or
/// note over them would make every later save fail). An edit that would pass the limit is not taken.
class Utf8ByteLimit extends TextInputFormatter {
  Utf8ByteLimit(this.maxBytes);
  final int maxBytes;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      utf8.encode(newValue.text).length <= maxBytes ? newValue : oldValue;
}

/// A validator for `promptForName` that refuses a text over [maxBytes] bytes of UTF-8.
String? Function(String) tabletTextLimit(int maxBytes) =>
    (text) => utf8.encode(text).length > maxBytes
        ? 'Too long: at most ${maxBytes ~/ 1000},000 bytes (a letter can take several).'
        : null;

/// A palette colour as a Flutter colour.
Color tabletColor(TabletColorDto c) => Color.fromARGB(255, c.r, c.g, c.b);

/// "#b3262e".
String tabletHex(TabletColorDto c) =>
    '#${[c.r, c.g, c.b].map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';

/// "colour 3 (#b3262e)" for palette index [i] of [doc], or "empty".
String colorWords(TabletDocumentDto doc, int? i) {
  if (i == null) return 'empty';
  if (i < 0 || i >= doc.palette.length) return 'colour ${i + 1} (not in the palette)';
  return 'colour ${i + 1} (${tabletHex(doc.palette[i])})';
}

/// Dark or light ink that reads on [c].
Color inkOn(Color c) => c.computeLuminance() > 0.35 ? Colors.black87 : Colors.white;

/// The note every computed face, chart and twist carries while the rules await a tablet weaver's
/// review. Shows nothing when [pending] is false.
class TabletReviewNote extends StatelessWidget {
  const TabletReviewNote({this.pending = true, this.dense = false, super.key});

  final bool pending;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (!pending) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: kTabletReviewNote,
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('tablet-review-note'),
          width: double.infinity,
          color: theme.colorScheme.secondaryContainer,
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 4 : 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.science_outlined, size: 18, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  kTabletReviewNote,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One card seen from the weaver's right (ADR 0018 section 1): the band and the weaver at the left,
/// the far end at the right; the hole letter at each corner (NT, FT, FB, NB); a clockwise arrow is a
/// forward turn. [colors] gives each hole's thread colour (A to D), drawn as a dot at its corner.
class TabletCardDiagram extends StatelessWidget {
  const TabletCardDiagram({
    required this.arrangement,
    this.colors = const {},
    this.size = 64,
    this.showForward = false,
    super.key,
  });

  final TabletArrangementDto? arrangement;
  final Map<TabletHoleKind, Color?> colors;
  final double size;
  final bool showForward;

  @override
  Widget build(BuildContext context) {
    final a = arrangement;
    final label = a == null
        ? 'Card position unknown'
        : 'Card seen from the weaver\'s right: ${arrangementWords(a)}';
    return Semantics(
      label: label,
      child: CustomPaint(
        size: Size(size * 1.5, size),
        painter: _CardPainter(
          arrangement: a,
          colors: colors,
          ink: Theme.of(context).colorScheme.onSurface,
          faint: Theme.of(context).colorScheme.outline,
          showForward: showForward,
        ),
      ),
    );
  }
}

class _CardPainter extends CustomPainter {
  _CardPainter({
    required this.arrangement,
    required this.colors,
    required this.ink,
    required this.faint,
    required this.showForward,
  });

  final TabletArrangementDto? arrangement;
  final Map<TabletHoleKind, Color?> colors;
  final Color ink;
  final Color faint;
  final bool showForward;

  @override
  void paint(Canvas canvas, Size size) {
    final pad = size.height * 0.22;
    final rect = Rect.fromLTRB(pad, pad, size.width - pad, size.height - pad);
    canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = faint
          ..strokeWidth = 1.2);
    final a = arrangement;
    final corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft];
    final fontSize = size.height * 0.2;
    for (var i = 0; i < 4; i++) {
      final hole = a == null ? null : cornersOf(a)[i];
      final c = hole == null ? null : colors[hole];
      final center = corners[i];
      canvas.drawCircle(
          center,
          size.height * 0.07,
          Paint()
            ..color = c ?? Colors.transparent
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          center,
          size.height * 0.07,
          Paint()
            ..color = ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      final tp = TextPainter(
        text: TextSpan(
          text: hole == null ? '?' : holeLetter(hole),
          style: TextStyle(color: ink, fontSize: fontSize, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // Letters sit outside the corner they name.
      final dx = i == 0 || i == 3 ? -tp.width - 2 : 2.0;
      final dy = i < 2 ? -tp.height : 0.0;
      tp.paint(canvas, center + Offset(dx, dy));
    }
    if (showForward) {
      // A clockwise arc inside the card: forward, the top edge moving away from the weaver.
      final r = rect.deflate(rect.shortestSide * 0.25);
      final p = Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      canvas.drawArc(r, -2.6, 2.2, false, p);
      final end = Offset(r.center.dx + r.width / 2 * 0.91, r.center.dy - r.height / 2 * 0.4);
      canvas.drawLine(end, end + const Offset(-5, -3), p);
      canvas.drawLine(end, end + const Offset(1, -6), p);
    }
  }

  @override
  bool shouldRepaint(covariant _CardPainter old) =>
      old.arrangement != arrangement ||
      old.colors != colors ||
      old.ink != ink ||
      old.showForward != showForward;
}

/// A small colour swatch (a hatched box for an empty hole).
class TabletSwatch extends StatelessWidget {
  const TabletSwatch({required this.color, this.size = 16, super.key});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color ?? Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: color == null
            ? CustomPaint(painter: _HatchPainter(Theme.of(context).colorScheme.outline))
            : null,
      );
}

class _HatchPainter extends CustomPainter {
  _HatchPainter(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = ink
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 4) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(covariant _HatchPainter old) => old.ink != ink;
}

// --- diagnostics in words ---------------------------------------------------------------------------

/// The severity in words (never colour alone).
String severityWord(TabletSeverityKind s) => switch (s) {
      TabletSeverityKind.error => 'Error',
      TabletSeverityKind.warning => 'Warning',
      TabletSeverityKind.unsupported => 'Not modelled',
      TabletSeverityKind.info => 'Note',
    };

IconData severityIcon(TabletSeverityKind s) => switch (s) {
      TabletSeverityKind.error => Icons.error_outline,
      TabletSeverityKind.warning => Icons.warning_amber_rounded,
      TabletSeverityKind.unsupported => Icons.help_outline,
      TabletSeverityKind.info => Icons.info_outline,
    };

Color severityColor(BuildContext context, TabletSeverityKind s) {
  final scheme = Theme.of(context).colorScheme;
  return switch (s) {
    TabletSeverityKind.error => scheme.error,
    TabletSeverityKind.warning =>
      Theme.of(context).extension<PlyColors>()?.warning ?? const Color(0xFFB26A00),
    TabletSeverityKind.unsupported => scheme.tertiary,
    TabletSeverityKind.info => scheme.outline,
  };
}

/// Where a diagnostic is, in words: "Card 3", "Card 1, hole B", "Pick 5, cards 1 to 8", "Segment 2,
/// pick 1", "Card 1, hole B, top face, picks 1 to 4"; null for the whole band. The same words the
/// printed checks use.
String? tabletLocationText(TabletLocationDto l) => tabletPlaceText(l);
