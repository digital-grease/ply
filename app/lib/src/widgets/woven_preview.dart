import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/editor_providers.dart';

/// The on-screen caption for every thickness-aware drawdown (this preview and the library preview):
/// yarn sizes are drawn as wider or taller threads, but that is an approximate look, not a model of
/// how the cloth actually weaves up.
const String kYarnPreviewTitle = 'Yarn preview';
const String kYarnPreviewNote = 'Approximate look, not a fabric model.';

/// The YARN PREVIEW under the editor: the draft rendered with its per-thread yarn thickness and the
/// thread texture ([wovenPreviewProvider], its own render, independent of the structural editor
/// grid), TILED to fill the free space so a short draft's empty area shows a swatch of the cloth.
///
/// Honest about what it is: an appearance approximation. The tile is the whole draft bitmap
/// repeated, not a detected structural repeat, so a seam between tiles proves nothing about how the
/// draft repeats; the caption says the look is approximate and tiled. Renders nothing when there is
/// no cloth (an empty draft, no bitmap).
class WovenPreview extends ConsumerWidget {
  const WovenPreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final img = ref.watch(wovenPreviewProvider).valueOrNull;
    if (img == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: '$kYarnPreviewTitle, tiled. $kYarnPreviewNote',
      image: true,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: cs.outlineVariant))),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: CustomPaint(painter: _TiledClothPainter(img))),
            Positioned(
              left: 8,
              top: 6,
              right: 8,
              child: Align(
                alignment: Alignment.topLeft,
                child: ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.surface.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text.rich(
                      const TextSpan(children: [
                        TextSpan(
                            text: '$kYarnPreviewTitle, tiled',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        TextSpan(text: '\n$kYarnPreviewNote'),
                      ]),
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TiledClothPainter extends CustomPainter {
  _TiledClothPainter(this.image);
  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    if (image.width == 0 || image.height == 0 || size.isEmpty) return;
    // Aim for ~90px per tile, decoupled from the editor's zoom so the swatch density stays stable
    // however the user zooms the main cloth. Uniform scale keeps the image's proportions (a fatter
    // yarn stays proportionally wider).
    final across = (size.width / 90).round().clamp(3, 12);
    final scale = (size.width / across) / image.width;
    final matrix = Matrix4.diagonal3Values(scale, scale, 1).storage;
    final paint = Paint()
      ..shader = ui.ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        matrix,
        filterQuality: FilterQuality.none, // crisp weave cells (nearest-neighbor), like the drawdown
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_TiledClothPainter old) => old.image != image;
}
