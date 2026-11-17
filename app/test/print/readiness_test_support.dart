import 'package:ply/src/data/readiness_repository.dart';
import 'package:ply/src/models/loom_check.dart' show Sett;
import 'package:ply/src/models/loom_profile.dart';
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/models/readiness.dart';
import 'package:ply/src/rust/dto.dart' show DraftDto;
import 'package:ply/src/rust/knit_dto.dart' show KnitPatternDto;
import 'package:ply/src/rust/weave_plan_dto.dart' show WeavePlanRequestDto;

// Shared helpers for the readiness tests (ADR 0021): a readiness repository with canned reports
// (host tests have no native library) and short builders for findings.

/// A finding of [level] from [check].
ReadinessItem finding(
  ReadinessLevel level,
  String message, {
  ReadinessCheck check = ReadinessCheck.chart,
  String? place,
  String code = 'test',
}) =>
    ReadinessItem(check: check, code: code, level: level, message: message, place: place);

/// A report of [items] that ran [checked].
ReadinessReport report(List<ReadinessItem> items,
        {List<ReadinessCheck> checked = const [ReadinessCheck.chart]}) =>
    ReadinessReport(checked: checked, items: items);

/// A readiness repository that answers every craft with [answer], and records what it was asked.
class FakeReadiness extends ReadinessRepository {
  FakeReadiness([this.answer = const ReadinessReport()]);

  ReadinessReport answer;
  final calls = <String>[];
  LoomProfile? lastLoom;
  WeavePlanRequestDto? lastPlan;
  String? lastNotation;

  @override
  Future<ReadinessReport> weave(DraftDto draft,
      {LoomProfile? loom, Sett? sett, WeavePlanRequestDto? plan}) async {
    calls.add('weave');
    lastLoom = loom;
    lastPlan = plan;
    return answer;
  }

  @override
  Future<ReadinessReport> knit(KnitPatternDto pattern) async {
    calls.add('knit');
    return answer;
  }

  @override
  Future<ReadinessReport> nalbind(String notation, NalbindRecipe? recipe) async {
    calls.add('nalbind');
    lastNotation = notation;
    return answer;
  }
}
