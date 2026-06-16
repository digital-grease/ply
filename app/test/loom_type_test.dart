import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_type.dart';

void main() {
  group('LoomType presets', () {
    test('default shed: jack/table/dobby rising, counter* sinking', () {
      expect(LoomType.jack.defaultShed, Shed.rising);
      expect(LoomType.table.defaultShed, Shed.rising);
      expect(LoomType.dobby.defaultShed, Shed.rising);
      expect(LoomType.counterbalance.defaultShed, Shed.sinking);
      expect(LoomType.countermarch.defaultShed, Shed.sinking);
    });

    test('prefersLiftplan only for table/dobby', () {
      expect(LoomType.table.prefersLiftplan, isTrue);
      expect(LoomType.dobby.prefersLiftplan, isTrue);
      expect(LoomType.jack.prefersLiftplan, isFalse);
      expect(LoomType.counterbalance.prefersLiftplan, isFalse);
      expect(LoomType.countermarch.prefersLiftplan, isFalse);
    });

    test('serialName round-trips through loomTypeFromSerial', () {
      for (final lt in LoomType.values) {
        expect(loomTypeFromSerial(lt.serialName), lt, reason: '${lt.serialName} round-trips');
      }
    });

    test('an unknown or absent serial defaults to jack', () {
      expect(loomTypeFromSerial(null), LoomType.jack);
      expect(loomTypeFromSerial('Nonsense'), LoomType.jack);
    });
  });

  group('blankDraftForLoom', () {
    test('floor looms are treadled with the loom shed', () {
      final d = blankDraftForLoom(LoomType.counterbalance);
      expect(d.drive, isA<DraftTreadled>());
      expect(d.shed, Shed.sinking);
    });

    test('table/dobby are a liftplan, 0 treadles, rising', () {
      final d = blankDraftForLoom(LoomType.dobby);
      expect(d.drive, isA<DraftLiftplan>());
      expect(d.treadles, 0);
      expect(d.shed, Shed.rising);
    });
  });

  group('DraftMeta loomType persistence', () {
    DraftMeta meta(LoomType lt) => DraftMeta(
          name: 'x',
          loomType: lt,
          savedAt: DateTime.utc(2026, 1, 1),
          lastOpened: DateTime.utc(2026, 1, 1),
        );

    test('round-trips through JSON', () {
      final j = meta(LoomType.countermarch).toJson();
      expect(j['loomType'], 'Countermarch');
      expect(DraftMeta.fromJson(j).loomType, LoomType.countermarch);
    });

    test('an older sidecar without loomType defaults to jack', () {
      final j = meta(LoomType.table).toJson()..remove('loomType');
      expect(DraftMeta.fromJson(j).loomType, LoomType.jack);
    });
  });
}
