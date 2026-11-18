// The engines' side of progress tracking (ADR 0023): what to do at each unit of a pattern and where a
// saved place resumes. The only place in the app that calls the generated work symbols. Host tests
// override [workRepositoryProvider] with canned results (they have no native library).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as api;
import '../rust/dto.dart' show DraftDto;
import '../rust/knit_dto.dart' show KnitPatternDto;
import '../rust/progress_dto.dart';

class WorkRepository {
  const WorkRepository();

  /// Picks [first] to [last] (from 1) of the [time]-th time through [draft] (from 1), at most 500,
  /// [first] always included. Throws the engine's reason.
  Future<WeaveWorkDto> weaveWindow(DraftDto draft, int first, int last, int time) =>
      api.weaveWorkWindow(draft: draft, first: first, last: last, time: time);

  /// Where a saved weaving [place] resumes in [draft] as it is now.
  Future<WorkResumeDto> weaveResume(DraftDto draft, WeavePlaceDto place) =>
      api.weaveResume(draft: draft, place: place);

  /// Every unit of knitting work in [pattern].
  Future<KnitWorkDto> knitWork(KnitPatternDto pattern) => api.knitWork(pattern: pattern);

  /// Where a saved knitting [place] resumes in [pattern] as it is now.
  Future<WorkResumeDto> knitResume(KnitPatternDto pattern, KnitPlaceDto place) =>
      api.knitResume(pattern: pattern, place: place);
}

final workRepositoryProvider = Provider<WorkRepository>((_) => const WorkRepository());
