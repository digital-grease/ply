import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';

// The active-brush plumbing: the pure remap helper (kept in lockstep with the engine's color-remove
// renumbering), the clamp-on-read chokepoint, and the load-reset.

void main() {
  test('remapAfterRemove matches the engine renumbering (e==removed->0, e>removed->e-1)', () {
    expect(remapAfterRemove(2, 2), 0); // the removed color itself
    expect(remapAfterRemove(3, 2), 2); // a survivor above it shifts down
    expect(remapAfterRemove(1, 2), 1); // below it is unchanged
    expect(remapAfterRemove(0, 0), 0); // removing index 0
    expect(remapAfterRemove(1, 0), 0); // and the next falls to the new 0
  });

  test('clampBrush clamps a dangling brush into the palette (shared chokepoint)', () {
    expect(clampBrush(5, 2), 1, reason: 'dangles past a 2-color palette -> last index');
    expect(clampBrush(1, 3), 1, reason: 'in range -> unchanged');
    expect(clampBrush(0, 0), 0, reason: 'empty palette -> 0');
  });

  test('load() resets the brush to 0 (no cross-draft bleed)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(activePaletteColorProvider.notifier).state = 1;
    c.read(draftEditorProvider.notifier).load(DraftDoc.blank());
    expect(c.read(activePaletteColorProvider), 0);
  });
}
