// The engines' side of progress tracking (ADR 0023): what to do at each unit of a pattern and where a
// saved place resumes. The only place in the app that calls the generated work symbols. Host tests
// override [workRepositoryProvider] with canned results (they have no native library).

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/nalbind_recipe.dart' show NalbindRecipe;
import '../models/nalbind_recipe_view.dart' show recipeToDto;
import '../rust/api.dart' as api;
import '../rust/dto.dart' show DraftDto;
import '../rust/knit_dto.dart' show KnitPatternDto;
import '../rust/progress_dto.dart';
import '../rust/tablet_dto.dart' show TabletDocumentDto;

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

  /// Picks [first] to [last] (from 1) of the [time]-th time through the tablet weaving [band] (from
  /// 1): what to do at each and every card before and at each, at most 500 picks and 50,000 cells,
  /// [first] always included. [from] is a work state an earlier window of this time through gave
  /// (its `startState` or `endState`), resumed from when it belongs. Throws a `TabletRunFailure` (a
  /// band with errors, a pick it does not have).
  Future<TabletWorkDto> tabletWindow(TabletDocumentDto band, int first, int last, int time,
          {Uint8List? from}) =>
      api.tabletWorkWindow(doc: band, first: first, last: last, time: time, from: from);

  /// Where a saved tablet weaving [place] resumes in [band] as it is now. Throws a
  /// `TabletRunFailure` for a band with errors.
  Future<WorkResumeDto> tabletResume(TabletDocumentDto band, TabletPlaceDto place) =>
      api.tabletResume(doc: band, place: place);

  /// Every step of a nalbinding [recipe] with its id and fingerprint; [projectNotation] and
  /// [projectStitchName] are the project's stitch.
  Future<NalbindWorkDto> nalbindWork(NalbindRecipe recipe,
          {required String projectNotation, required String projectStitchName}) =>
      api.nalbindWork(
          recipe: recipeToDto(recipe),
          projectNotation: projectNotation,
          projectStitchName: projectStitchName);

  /// Where a saved nalbinding [place] resumes in [recipe] as it is now.
  Future<WorkResumeDto> nalbindResume(NalbindRecipe recipe, NalbindPlaceDto place,
          {required String projectNotation, required String projectStitchName}) =>
      api.nalbindResume(
          recipe: recipeToDto(recipe),
          projectNotation: projectNotation,
          projectStitchName: projectStitchName,
          place: place);
}

final workRepositoryProvider = Provider<WorkRepository>((_) => const WorkRepository());
