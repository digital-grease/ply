import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';

// Tests for the DraftDoc domain model. The two load-bearing properties are:
//   1. DEEP value equality with a hashCode consistent with it (equal docs => equal hash),
//      because the undo/redo stack dedups whole-doc snapshots and the live-preview provider
//      memoizes on the doc. Identity-based List == would silently break both.
//   2. Snapshots are FROZEN: once a DraftDoc is built, no reachable list can be mutated, so a
//      snapshot on the undo stack cannot be corrupted through a leaked reference.
// These tests pin both, plus copyWith semantics and the engine-matching blank() shape.

/// Build a [DraftColor] from RUNTIME ints so each call returns a DISTINCT instance. A const
/// literal would be canonicalized to ONE shared instance, which would silently hide a
/// regression of the palette's element value-equality into identity-equality (the
/// `identical()` short-circuit in DraftColor.== would always fire, so the r/g/b comparison
/// branch would never run through the doc-level palette path). Using this in the fixtures keeps
/// the "share NO list identity" promise true for the palette too, not just the int lists.
DraftColor mkColor(int r, int g, int b) => DraftColor(r: r, g: g, b: b);

/// A fully-populated treadled fixture built from FRESH lists each call, so two invocations
/// produce structurally-equal docs that share NO list identity (the real test of deep ==).
DraftDoc treadledFixture() => DraftDoc(
      name: 'Twill 2/2',
      shafts: 4,
      treadles: 4,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(
        tieup: [
          [1, 2],
          [2, 3],
          [3, 4],
          [4, 1],
        ],
        treadling: [
          [1],
          [2],
          [3],
          [4],
        ],
      ),
      palette: [mkColor(255, 255, 255), mkColor(0, 0, 0)],
      warpColors: [0, 0, 1, 1],
      weftColors: [1, 1, 0, 0],
      notes: 'a test cloth',
    );

/// A liftplan fixture (distinct drive variant) for getter and cross-variant checks.
DraftDoc liftplanFixture() => DraftDoc(
      name: 'lp',
      shafts: 2,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.centimeters,
      threading: [
        [1],
        [2],
      ],
      drive: DraftLiftplan(liftplan: [
        [1],
        [2],
        [1],
      ]),
      palette: [mkColor(0, 0, 0)],
      warpColors: [0, 0],
      weftColors: [0, 0, 0],
      notes: '',
    );

void main() {
  group('DraftDoc equality + hashCode (deep)', () {
    test('structurally-equal docs from independent lists compare == and hash equal', () {
      final a = treadledFixture();
      final b = treadledFixture();
      expect(identical(a, b), isFalse, reason: 'fixtures must be distinct instances');
      expect(identical(a.threading, b.threading), isFalse,
          reason: 'and must share no nested-list identity');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('palette element value-equality is exercised with DISTINCT instances', () {
      // Guards the one field whose elements are custom value objects: if palette equality
      // ever regressed to element IDENTITY, const-canonicalized fixtures would hide it but
      // production palettes (built non-const from the wire on every load) would compare
      // unequal, spuriously re-rendering the preview and growing the undo stack. mkColor
      // forces distinct instances so the r/g/b value branch (not identical()) is what runs.
      final a = treadledFixture();
      final b = treadledFixture();
      expect(identical(a.palette[0], b.palette[0]), isFalse,
          reason: 'palette elements must be distinct instances to test value-equality');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      // Swapping a palette entry for a fresh, value-equal one is a no-op to ==/hashCode.
      final swapped = a.copyWith(palette: [mkColor(255, 255, 255), mkColor(0, 0, 0)]);
      expect(identical(a.palette[0], swapped.palette[0]), isFalse);
      expect(a, equals(swapped));
      expect(a.hashCode, equals(swapped.hashCode));
    });

    test('reflexive and symmetric', () {
      final a = treadledFixture();
      final b = treadledFixture();
      expect(a, equals(a));
      expect(a == b, isTrue);
      expect(b == a, isTrue);
    });

    test('a differing inner threading cell flips == (and hash, for an ordered deep hash)', () {
      final a = treadledFixture();
      final mutated = a.threading.map((r) => List<int>.of(r)).toList();
      mutated[0] = [2]; // was [1]
      final b = a.copyWith(threading: mutated);
      expect(a == b, isFalse);
      // An order/content-blind hash would collide here; the ordered deep hash must not.
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });

    test('order-sensitive: [[1],[2]] threading != [[2],[1]] and hashes differ', () {
      final base = treadledFixture();
      final a = base.copyWith(threading: [
        [1],
        [2],
      ]);
      final b = base.copyWith(threading: [
        [2],
        [1],
      ]);
      expect(a == b, isFalse);
      expect(a.hashCode, isNot(equals(b.hashCode)),
          reason: 'guards against an unordered/sum hash');
    });

    test('a differing tieup row flips ==', () {
      final a = treadledFixture();
      final t = a.drive as DraftTreadled;
      final newTieup = t.tieup.map((r) => List<int>.of(r)).toList();
      newTieup[0] = [1]; // was [1,2]
      final b = a.copyWith(drive: t.copyWith(tieup: newTieup));
      expect(a == b, isFalse);
    });

    test('a differing treadling row flips ==', () {
      final a = treadledFixture();
      final t = a.drive as DraftTreadled;
      final newTreadling = t.treadling.map((r) => List<int>.of(r)).toList();
      newTreadling[0] = [2]; // was [1]
      final b = a.copyWith(drive: t.copyWith(treadling: newTreadling));
      expect(a == b, isFalse);
    });

    test('a differing liftplan row flips ==', () {
      final a = liftplanFixture();
      final lp = a.drive as DraftLiftplan;
      final newLift = lp.liftplan.map((r) => List<int>.of(r)).toList();
      newLift[0] = [2]; // was [1]
      final b = a.copyWith(drive: lp.copyWith(liftplan: newLift));
      expect(a == b, isFalse);
    });

    test('a single differing palette channel flips == and hash', () {
      final a = treadledFixture();
      final b = a.copyWith(palette: const [
        DraftColor(r: 254, g: 255, b: 255), // r 255 -> 254
        DraftColor(r: 0, g: 0, b: 0),
      ]);
      expect(a == b, isFalse);
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });

    test('a single differing warp/weft color index flips ==', () {
      final a = treadledFixture();
      expect(a == a.copyWith(warpColors: [0, 1, 1, 1]), isFalse);
      expect(a == a.copyWith(weftColors: [0, 1, 0, 0]), isFalse);
    });

    test('every scalar/enum field participates in ==', () {
      final a = treadledFixture();
      expect(a == a.copyWith(name: 'other'), isFalse);
      expect(a == a.copyWith(shafts: 8), isFalse);
      expect(a == a.copyWith(treadles: 8), isFalse);
      expect(a == a.copyWith(shed: Shed.sinking), isFalse);
      expect(a == a.copyWith(unit: MeasureUnit.centimeters), isFalse);
      expect(a == a.copyWith(notes: 'changed'), isFalse);
    });

    test('hash/equals contract sweep: a == b implies equal hashCode across a fixture set', () {
      final fixtures = <DraftDoc>[
        treadledFixture(),
        treadledFixture(),
        liftplanFixture(),
        liftplanFixture(),
        DraftDoc.blank(),
        DraftDoc.blank(),
        treadledFixture().copyWith(name: 'x'),
      ];
      for (final a in fixtures) {
        for (final b in fixtures) {
          if (a == b) {
            expect(a.hashCode, equals(b.hashCode),
                reason: 'equal docs MUST hash equal: $a vs $b');
          }
        }
      }
    });
  });

  group('DraftDoc cross-variant drive', () {
    test('Treadled is never == Liftplan even with coincidentally-equal rows', () {
      final treadled = DraftTreadled(tieup: [
        [1],
      ], treadling: [
        [1],
      ]);
      final liftplan = DraftLiftplan(liftplan: [
        [1],
      ]);
      expect(treadled == liftplan, isFalse);
      expect(liftplan == treadled, isFalse);
      expect(treadled.hashCode, isNot(equals(liftplan.hashCode)),
          reason: 'runtimeType folded into the hash separates the variants');
    });

    test('swapping drive Treadled->Liftplan flips == and updates picks', () {
      final a = treadledFixture(); // 4 picks
      final b = a.copyWith(
        drive: DraftLiftplan(liftplan: [
          [1],
          [2],
        ]),
      );
      expect(a == b, isFalse);
      expect(b.drive, isA<DraftLiftplan>());
      expect(b.picks, equals(2));
    });
  });

  group('DraftDoc copyWith', () {
    test('no-arg copyWith yields an equal, equal-hash, NOT-identical doc', () {
      final a = treadledFixture();
      final b = a.copyWith();
      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('copyWith(name:) changes only name; result != original', () {
      final a = treadledFixture();
      final b = a.copyWith(name: 'renamed');
      expect(b.name, equals('renamed'));
      expect(a == b, isFalse);
      // Everything else is unchanged: restoring the name makes them equal again.
      expect(b.copyWith(name: a.name), equals(a));
    });

    test('copyWith reuses unchanged sealed lists by reference (identical short-circuit)', () {
      final a = treadledFixture();
      final b = a.copyWith(name: 'renamed');
      expect(identical(a.threading, b.threading), isTrue);
      expect(identical(a.warpColors, b.warpColors), isTrue);
      expect(identical(a.weftColors, b.weftColors), isTrue);
      expect(identical(a.palette, b.palette), isTrue);
      expect(identical(a.drive, b.drive), isTrue);
    });

    test('copyWith(drive:) reuses the OTHER four lists by reference; only drive changes', () {
      // The most-trafficked editor path (Treadled<->Liftplan switch) must still preserve the
      // identical() short-circuit on the untouched lists, mirroring the name: path above.
      final a = treadledFixture();
      final b = a.copyWith(drive: DraftLiftplan(liftplan: [
        [1],
      ]));
      expect(identical(a.threading, b.threading), isTrue);
      expect(identical(a.palette, b.palette), isTrue);
      expect(identical(a.warpColors, b.warpColors), isTrue);
      expect(identical(a.weftColors, b.weftColors), isTrue);
      expect(identical(a.drive, b.drive), isFalse, reason: 'drive is the one field that changed');
    });

    test('copyWith with a FRESH value-equal list yields == and equal hash (re-seal path)', () {
      // Closes the positive direction of the re-seal branch: a brand-new list with equal
      // CONTENT but no shared identity must still compare equal (deep ==), not just the
      // by-reference no-arg case.
      final a = treadledFixture();
      final freshThreading = a.threading.map((r) => List<int>.of(r)).toList();
      final b = a.copyWith(threading: freshThreading);
      expect(identical(a.threading, b.threading), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('copyWith does not mutate the previous doc (undo-safety)', () {
      final a = treadledFixture();
      final snapshot = treadledFixture(); // a value-equal twin captured "before"
      a.copyWith(threading: [
        [9],
      ]);
      expect(a, equals(snapshot), reason: 'the source doc must be untouched by copyWith');
    });

    test('DraftTreadled.copyWith preserves the variant and reuses the untouched field', () {
      final t = DraftTreadled(tieup: [
        [1, 2],
      ], treadling: [
        [1],
      ]);
      final t2 = t.copyWith(treadling: [
        [1],
        [2],
      ]);
      expect(t2, isA<DraftTreadled>());
      expect(t2.pickCount, equals(2));
      expect(identical(t.tieup, t2.tieup), isTrue, reason: 'unchanged tieup reused by reference');
    });

    test('DraftLiftplan.copyWith preserves the variant', () {
      final lp = DraftLiftplan(liftplan: [
        [1],
      ]);
      final lp2 = lp.copyWith(liftplan: [
        [1],
        [2],
      ]);
      expect(lp2, isA<DraftLiftplan>());
      expect(lp2.pickCount, equals(2));
    });
  });

  group('DraftDoc defensive immutability', () {
    test('mutating the SOURCE lists after construction does not affect the doc', () {
      final threading = [
        [1],
        [2],
      ];
      final palette = [const DraftColor(r: 1, g: 2, b: 3)];
      final warp = [0, 0];
      final doc = DraftDoc(
        name: 'n',
        shafts: 2,
        treadles: 0,
        shed: Shed.rising,
        unit: MeasureUnit.inches,
        threading: threading,
        drive: DraftLiftplan(liftplan: [
          [1],
          [2],
        ]),
        palette: palette,
        warpColors: warp,
        weftColors: [0, 0],
        notes: '',
      );
      final twin = DraftDoc(
        name: 'n',
        shafts: 2,
        treadles: 0,
        shed: Shed.rising,
        unit: MeasureUnit.inches,
        threading: [
          [1],
          [2],
        ],
        drive: DraftLiftplan(liftplan: [
          [1],
          [2],
        ]),
        palette: [const DraftColor(r: 1, g: 2, b: 3)],
        warpColors: [0, 0],
        weftColors: [0, 0],
        notes: '',
      );
      // Corrupt the originals every way a careless caller might.
      threading[0][0] = 99; // inner cell
      threading.add([3]); // outer list
      palette.add(const DraftColor(r: 9, g: 9, b: 9));
      warp[0] = 42;
      expect(doc, equals(twin), reason: 'copy-THEN-wrap must isolate the doc from its sources');
    });

    test('the sealed lists throw on any mutation (outer AND inner)', () {
      final doc = treadledFixture();
      expect(() => doc.threading.add([5]), throwsUnsupportedError);
      expect(() => doc.threading[0].add(5), throwsUnsupportedError);
      expect(() => doc.palette.add(const DraftColor(r: 0, g: 0, b: 0)),
          throwsUnsupportedError);
      expect(() => doc.warpColors.add(0), throwsUnsupportedError);
      expect(() => doc.weftColors.add(0), throwsUnsupportedError);
      final t = doc.drive as DraftTreadled;
      expect(() => t.tieup.add([1]), throwsUnsupportedError);
      expect(() => t.tieup[0].add(1), throwsUnsupportedError);
      expect(() => t.treadling.add([1]), throwsUnsupportedError);
    });
  });

  group('DraftDoc.blank mirrors the engine Draft::blank', () {
    test('default shape: empty cloth, treadled, white-first 2-color palette', () {
      final d = DraftDoc.blank(shafts: 4, treadles: 6);
      expect(d.ends, equals(0));
      expect(d.picks, equals(0));
      expect(d.shafts, equals(4));
      expect(d.treadles, equals(6));
      expect(d.shed, equals(Shed.rising));
      expect(d.unit, equals(MeasureUnit.inches));
      expect(d.notes, equals(''));
      expect(d.palette.length, equals(2));
      expect(d.palette.first, equals(const DraftColor(r: 255, g: 255, b: 255)));
      expect(d.palette[1], equals(const DraftColor(r: 0, g: 0, b: 0)));
      expect(d.drive, isA<DraftTreadled>());
      final t = d.drive as DraftTreadled;
      expect(t.tieup.length, equals(6), reason: 'tie-up sized to the treadle count');
      expect(t.tieup.every((row) => row.isEmpty), isTrue, reason: 'tied to nothing yet');
      expect(t.treadling, isEmpty);
    });

    test('two blank() with the same args compare == with equal hashCode', () {
      final a = DraftDoc.blank(shafts: 4, treadles: 6);
      final b = DraftDoc.blank(shafts: 4, treadles: 6);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('blank is itself frozen', () {
      final d = DraftDoc.blank();
      expect(() => d.palette.add(const DraftColor(r: 1, g: 1, b: 1)),
          throwsUnsupportedError);
      final t = d.drive as DraftTreadled;
      expect(() => t.tieup.add([1]), throwsUnsupportedError);
    });
  });

  group('DraftDoc getters', () {
    test('ends == threading.length and picks == drive.pickCount', () {
      final treadled = treadledFixture();
      expect(treadled.ends, equals(treadled.threading.length));
      expect(treadled.ends, equals(4));
      expect(treadled.picks, equals(4));

      final liftplan = liftplanFixture();
      expect(liftplan.ends, equals(2));
      expect(liftplan.picks, equals(3));
    });
  });

  group('DraftDoc enforces no cross-field invariants', () {
    // The model is documented as holding NO cross-field invariants: parallel-list lengths and
    // palette-index bounds are the BRIDGE VALIDATOR's job, not the constructor's. This pins
    // that contract so a future contributor who "helpfully" adds an `assert(warpColors.length
    // == ends)` (asserts run in tests) fails loudly here instead of crashing the editor on a
    // legitimate intermediate edit state (e.g. adding a threading end before its warp color).
    test('a malformed-but-representable doc constructs without throwing', () {
      late DraftDoc d;
      expect(
        () => d = DraftDoc(
          name: 'malformed',
          shafts: 2,
          treadles: 2,
          shed: Shed.rising,
          unit: MeasureUnit.inches,
          threading: [
            [1],
            [2],
            [3],
          ], // 3 ends ...
          drive: DraftTreadled(
            tieup: [
              [1],
            ], // ... tie-up sized to 1, not the declared 2 treadles ...
            treadling: [
              [1],
              [2],
            ], // ... pick 2 presses treadle 2, which has no tie-up row ...
          ),
          palette: const <DraftColor>[], // ... empty palette ...
          warpColors: [0, 5], // ... wrong length (2 != 3 ends) AND index 5 out of range ...
          weftColors: [9], // ... out-of-range index too.
          notes: '',
        ),
        returnsNormally,
        reason: 'invariants belong to the bridge validator, never the model constructor',
      );
      // The getters still report the raw, unreconciled geometry.
      expect(d.ends, equals(3));
      expect(d.picks, equals(2));
      expect(d.palette, isEmpty);
    });
  });

  group('DraftColor value semantics', () {
    test('equal channels => == and equal hashCode', () {
      const a = DraftColor(r: 10, g: 20, b: 30);
      const b = DraftColor(r: 10, g: 20, b: 30);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('any differing channel => !=', () {
      const a = DraftColor(r: 10, g: 20, b: 30);
      expect(a == const DraftColor(r: 11, g: 20, b: 30), isFalse);
      expect(a == const DraftColor(r: 10, g: 21, b: 30), isFalse);
      expect(a == const DraftColor(r: 10, g: 20, b: 31), isFalse);
    });

    test('copyWith changes only the named channel', () {
      const a = DraftColor(r: 10, g: 20, b: 30);
      final b = a.copyWith(g: 99);
      expect(b, equals(const DraftColor(r: 10, g: 99, b: 30)));
    });
  });
}
