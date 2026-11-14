// Retained WIF sections through edits that change a draft's size: only per-thread data on an axis
// whose count changes is dropped (the engine's `Draft::resized` rule); the file's credit (the kept
// [TEXT] lines and Ply's record of the first program), vendor sections and per-thread data on the
// unchanged axis are kept.

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';

void main() {
  final credit = RetainedSection(kWifTextSection, const [RetainedEntry('Author', 'A. Weaver')]);
  final origin =
      RetainedSection(kWifSourceSection, const [RetainedEntry('Source Program', 'Loomcraft')]);
  final vendor = RetainedSection('LOOMCRAFT EXTRAS', const [RetainedEntry('Bobbins', '3')]);
  final warpSpacing = RetainedSection('WARP SPACING', const [RetainedEntry('1', '0.1')]);
  final weftSpacing = RetainedSection('WEFT SPACING', const [RetainedEntry('1', '0.1')]);
  final doc = DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
    threading: List.generate(8, (e) => [e % 4 + 1]),
    drive: DraftTreadled(tieup: const [
      [1],
      [2],
      [3],
      [4]
    ], treadling: List.generate(6, (p) => [p % 4 + 1])),
    retained: [credit, warpSpacing, weftSpacing, vendor, origin],
  );

  test('the same size leaves the kept sections untouched', () {
    expect(retainedForSize(doc, ends: doc.ends, picks: doc.picks), isNull);
    expect(retainedForPickCount(doc, doc.picks), isNull);
  });

  test('more or fewer ends drops only the per-end sections', () {
    expect(retainedForSize(doc, ends: 10, picks: doc.picks), [credit, weftSpacing, vendor, origin]);
  });

  test('more or fewer picks drops only the per-pick sections', () {
    expect(retainedForSize(doc, ends: doc.ends, picks: 3), [credit, warpSpacing, vendor, origin]);
    expect(retainedForPickCount(doc, 3), [credit, warpSpacing, vendor, origin]);
  });

  test('both axes changing keeps the credit and the vendor section', () {
    expect(retainedForSize(doc, ends: 12, picks: 12), [credit, vendor, origin]);
  });
}
