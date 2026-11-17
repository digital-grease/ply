// A loom check of a draft (roadmap M8-02, ADR 0014): the domain twin of the bridge's
// `LoomReportDto`, and the per-draft loom choice kept in the draft's sidecar. Pure data.
//
// A loom check is SEPARATE from structural validation (`DraftIssue`): a draft can be structurally
// sound and not feasible on a loom, and feasibility never gates saving.

import 'package:collection/collection.dart';

import 'draft_doc.dart' show MeasureUnit;
import 'loom_profile.dart';

/// How serious a loom finding is (mirrors `ply_weave::feasibility::LoomSeverity`).
enum LoomSeverity {
  /// The draft cannot be woven on this loom as drafted.
  notFeasible,

  /// It can be, with a different tie-up, approach, or care.
  advice,

  /// An input is unknown, so this was not checked.
  notChecked,

  /// Checked, and it fits.
  fits,
}

/// What a location's numbers count.
enum LoomLocationKind { shafts, treadles, picks }

/// Where a finding applies: 1-based numbers (at most 24 listed) out of [total].
class LoomLocation {
  const LoomLocation({required this.kind, required this.numbers, required this.total});

  final LoomLocationKind kind;
  final List<int> numbers;
  final int total;

  @override
  bool operator ==(Object other) =>
      other is LoomLocation &&
      other.kind == kind &&
      other.total == total &&
      const ListEquality<int>().equals(other.numbers, numbers);

  @override
  int get hashCode => Object.hash(kind, total, const ListEquality<int>().hash(numbers));
}

/// One loom finding. [code] is the engine's stable id (`loom.shafts_exceeded`); tests and the UI key
/// on it, never on [message].
class LoomDiagnostic {
  const LoomDiagnostic({
    required this.code,
    required this.severity,
    required this.summary,
    required this.message,
    this.location,
    this.remediation,
  });

  final String code;
  final LoomSeverity severity;

  /// A few words for the group header: "needs 8 shafts, has 4".
  final String summary;

  /// The full sentence with the exact requirement.
  final String message;
  final LoomLocation? location;

  /// What the weaver can do, when Ply can suggest something.
  final String? remediation;

  @override
  bool operator ==(Object other) =>
      other is LoomDiagnostic &&
      other.code == code &&
      other.severity == severity &&
      other.summary == summary &&
      other.message == message &&
      other.location == location &&
      other.remediation == remediation;

  @override
  int get hashCode => Object.hash(code, severity, summary, message, location, remediation);

  @override
  String toString() => 'LoomDiagnostic($code: $message)';
}

/// A sett: [ends] per inch or per cm.
class Sett {
  const Sett(this.ends, this.per);

  final double ends;
  final MeasureUnit per;

  /// Ends per inch.
  double get perInch => per == MeasureUnit.inches ? ends : ends * 2.54;

  /// Whether the check can use it (finite, within the engine's range).
  bool get isValid =>
      ends.isFinite && perInch >= LoomLimits.minSettPerInch && perInch <= LoomLimits.maxSettPerInch;

  /// "24 ends per inch", "10 ends per cm".
  String get label =>
      '${formatLoomNumber(ends)} ends per ${per == MeasureUnit.inches ? 'inch' : 'cm'}';

  Map<String, Object?> toJson() => {'ends': ends, 'per': per == MeasureUnit.inches ? 'inch' : 'cm'};

  /// Null when [json] is not a sett this build can read.
  static Sett? fromJson(Object? json) {
    if (json is! Map) return null;
    final ends = json['ends'];
    final per = switch (json['per']) {
      'inch' => MeasureUnit.inches,
      'cm' => MeasureUnit.centimeters,
      _ => null,
    };
    if (ends is! num || per == null) return null;
    final sett = Sett(ends.toDouble(), per);
    return sett.isValid ? sett : null;
  }

  @override
  bool operator ==(Object other) => other is Sett && other.ends == ends && other.per == per;

  @override
  int get hashCode => Object.hash(ends, per);

  @override
  String toString() => 'Sett($label)';
}

/// Where the sett a check used came from.
enum SettSource { entered, file }

/// A whole loom check.
class LoomReport {
  const LoomReport({
    required this.loomName,
    required this.diagnostics,
    this.sett,
    this.settSource,
    this.fileSett,
    this.reedWidth,
  });

  /// The loom's name as the messages use it.
  final String loomName;
  final List<LoomDiagnostic> diagnostics;

  /// The sett the width and reed checks used, and where it came from.
  final Sett? sett;
  final SettSource? settSource;

  /// The file's own sett, when it gives one.
  final Sett? fileSett;

  /// The warp's width in the reed, when known.
  final LoomLength? reedWidth;

  bool get feasible => diagnostics.every((d) => d.severity != LoomSeverity.notFeasible);

  Iterable<LoomDiagnostic> withSeverity(LoomSeverity s) =>
      diagnostics.where((d) => d.severity == s);

  /// The group header: "On Floor loom: not feasible, needs 8 shafts, has 4", "On Floor loom: fits",
  /// "On Floor loom: fits, 1 note", "On Floor loom: fits so far, 1 note, 2 not checked".
  String get headline {
    final blocked = withSeverity(LoomSeverity.notFeasible).toList();
    if (blocked.isNotEmpty) {
      final more = blocked.length - 1;
      return 'On $loomName: not feasible, ${blocked.first.summary}'
          '${more > 0 ? ' (and $more more)' : ''}';
    }
    final notes = withSeverity(LoomSeverity.advice).length;
    final unchecked = withSeverity(LoomSeverity.notChecked).length;
    final parts = [
      if (notes > 0) '$notes ${notes == 1 ? 'note' : 'notes'}',
      if (unchecked > 0) '$unchecked not checked',
    ];
    final fits = unchecked > 0 ? 'fits so far' : 'fits';
    return 'On $loomName: $fits${parts.isEmpty ? '' : ', ${parts.join(', ')}'}';
  }

  /// The findings worst first (not feasible, advice, not checked, fits), engine order within each.
  List<LoomDiagnostic> get sorted =>
      [...diagnostics]..sort((a, b) => a.severity.index.compareTo(b.severity.index));

  @override
  bool operator ==(Object other) =>
      other is LoomReport &&
      other.loomName == loomName &&
      const ListEquality<LoomDiagnostic>().equals(other.diagnostics, diagnostics) &&
      other.sett == sett &&
      other.settSource == settSource &&
      other.fileSett == fileSett &&
      other.reedWidth == reedWidth;

  @override
  int get hashCode => Object.hash(loomName, const ListEquality<LoomDiagnostic>().hash(diagnostics),
      sett, settSource, fileSett, reedWidth);
}

/// The loom a draft is planned for, kept in the draft's sidecar under the `loomPlan` key (ADR 0014):
/// the loom's id and its name when it was chosen (so a draft whose loom was deleted, or restored on
/// another device, still says what it was planned for), and the weaver's sett for the check. Never
/// the profile itself, and never in the WIF.
class LoomPlan {
  LoomPlan({
    required this.loomId,
    required this.loomName,
    this.sett,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  final String loomId;
  final String loomName;
  final Sett? sett;

  /// Keys of the stored object this build does not read, written back as they were (so a later
  /// build can add to the plan), plus a `sett` this build could not read.
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = {'loomId', 'loomName', 'sett'};

  LoomPlan copyWith({String? loomId, String? loomName, Sett? sett, bool clearSett = false}) =>
      LoomPlan(
        loomId: loomId ?? this.loomId,
        loomName: loomName ?? this.loomName,
        sett: clearSett ? null : (sett ?? this.sett),
        extra: {
          for (final e in extra.entries)
            if (!(e.key == 'sett' && (sett != null || clearSett))) e.key: e.value,
        },
      );

  Map<String, Object?> toJson() => {
        'loomId': loomId,
        'loomName': loomName,
        if (sett != null) 'sett': sett!.toJson(),
        ...extra,
      };

  /// Null when [json] is not a plan this build can read (no string `loomId`); the caller keeps the
  /// raw value so a rewrite does not lose it.
  static LoomPlan? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['loomId'];
    if (id is! String || id.isEmpty) return null;
    final name = json['loomName'];
    final rawSett = json['sett'];
    final sett = rawSett == null ? null : Sett.fromJson(rawSett);
    return LoomPlan(
      loomId: id,
      loomName: name is String ? name : '',
      sett: sett,
      extra: {
        for (final e in json.entries)
          if (!knownKeys.contains(e.key) || (e.key == 'sett' && sett == null && rawSett != null))
            '${e.key}': e.value,
      },
    );
  }

  /// The loom's name to show: the stored name, or "Unnamed loom" when it had none.
  String get displayName => loomName.trim().isEmpty ? 'Unnamed loom' : loomName.trim();

  @override
  bool operator ==(Object other) =>
      other is LoomPlan &&
      other.loomId == loomId &&
      other.loomName == loomName &&
      other.sett == sett &&
      const DeepCollectionEquality().equals(other.extra, extra);

  @override
  int get hashCode =>
      Object.hash(loomId, loomName, sett, const DeepCollectionEquality().hash(extra));

  @override
  String toString() => 'LoomPlan($loomId, $loomName, $sett)';
}
