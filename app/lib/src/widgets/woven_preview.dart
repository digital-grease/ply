import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/editor_providers.dart';

/// A "woven preview": the engine drawdown bitmap (one repeat of the cloth) TILED to fill the space,
/// so a from-scratch draft's otherwise-empty area shows how the fabric actually looks as yardage,
/// not just the single structural unit. Reuses [previewProvider] — the SAME render as the editor
/// cloth and the library thumbnails — so it updates live on every edit and costs no extra FFI.
/// Renders nothing when there is no cloth (an empty draft, no bitmap).
class WovenPreview extends ConsumerWidget {
  const WovenPreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final img = ref.watch(previewProvider).valueOrNull;
    if (img == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Woven fabric preview',
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
              child: ExcludeSemantics(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.surface.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Woven preview',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
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
    // Aim for ~90px per repeat, decoupled from the editor's zoom so the swatch density stays stable
    // however the user zooms the main cloth. Uniform scale keeps the cells square.
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
