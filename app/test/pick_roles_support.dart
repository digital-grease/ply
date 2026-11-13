import 'package:ply/src/models/draft_doc.dart';

// Shared fixtures for the pick-role and Use tabby host tests.

const _white = DraftColor(r: 255, g: 255, b: 255);
const _dark = DraftColor(r: 45, g: 45, b: 45);

const kOvershotTieup = [
  [1, 2], // treadle 1: pattern block A
  [3, 4], // treadle 2: pattern block B
  [1, 3], // treadle 3: tabby a (lifts end 1)
  [2, 4], // treadle 4: tabby b
];

/// A Dart twin of the engine's `structure::overshot(ends, picks, block)`: blocks A {1,2} / B {3,4}
/// every [block] ends, pattern on the even (0-based) picks, tabby 3/4 alternating between them, the
/// pattern weft dark (1) and the ground white (0), with the generator's pattern/tabby roles.
DraftDoc generatedOvershot({int ends = 16, int picks = 8, int block = 4, bool roles = true}) {
  final rowsPerBlock = block ~/ 2 < 1 ? 1 : block ~/ 2;
  return DraftDoc(
    name: 'Overshot',
    shafts: 4,
    treadles: 4,
    shed: Shed.rising,
    unit: MeasureUnit.inches,
    threading: [
      for (var i = 0; i < ends; i++)
        [((i ~/ block) % 2 == 1 ? 3 : 1) + (i % 2)],
    ],
    drive: DraftTreadled(tieup: kOvershotTieup, treadling: [
      for (var p = 0; p < picks; p++)
        p.isEven
            ? [((p ~/ 2) ~/ rowsPerBlock) % 2 == 1 ? 2 : 1]
            : [(p ~/ 2).isEven ? 3 : 4],
    ]),
    palette: const [_white, _dark],
    warpColors: List<int>.filled(ends, 0),
    weftColors: [for (var p = 0; p < picks; p++) p.isEven ? 1 : 0],
    notes: '',
    pickRoles: roles
        ? [for (var p = 0; p < picks; p++) p.isEven ? PickRole.pattern : PickRole.tabby]
        : const [],
  );
}

