// "Warp and weft plan": the warp, weft and finishing worksheet of the open weaving draft (roadmap
// M8-03, ADR 0019). The weaver gives the finished size and allowances, chooses a swatch and the
// yarns, and the engine works out the width in the reed, the warp ends and the denting, the warp
// length, the weft and the yarn against what is on hand, every figure with where its numbers came
// from. Each assumption can be overridden on its own and set back to the swatch or Ply's estimate;
// nothing here ever writes into a swatch or a material. The plan is saved with the draft.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../models/draft_doc.dart' show MeasureUnit;
import '../models/loom_check.dart' show LoomSeverity;
import '../models/loom_profile.dart' show DentUnit, Reed;
import '../models/material_record.dart';
import '../models/project_materials.dart' show ProjectMaterials;
import '../models/weave_plan.dart';
import '../state/material_providers.dart';
import '../state/theme_providers.dart' show appSettingsProvider;
import '../state/weave_plan_providers.dart';
import '../theme/spacing.dart';
import '../widgets/planning_sheet.dart' show kYarnCountWpi;
import '../widgets/project_materials_sheet.dart' show projectMaterialsProvider;
import '../widgets/record_report_panel.dart' show EstimateTrace, SourceBadge;

/// The menu entry and screen title.
const String kWeavePlanTitle = 'Warp and weft plan';

/// The worksheet figures, grouped as the screen shows them.
const List<(String, List<String>)> _figureGroups = [
  ('Width', ['width_in_reed_target', 'warp_ends', 'width_in_reed', 'finished_width']),
  ('Warp', ['woven_length', 'warp_length', 'warp_yarn']),
  ('Weft', ['weft_picks', 'weft_per_pick', 'weft_yarn']),
];

class WeavePlanScreen extends ConsumerStatefulWidget {
  const WeavePlanScreen({this.projectId, super.key});

  /// The draft's library id (null for an unsaved draft), to show its linked records first.
  final String? projectId;

  @override
  ConsumerState<WeavePlanScreen> createState() => _WeavePlanScreenState();
}

class _WeavePlanScreenState extends ConsumerState<WeavePlanScreen> {
  /// The plan shown while the draft has none yet; stored only once the weaver changes something.
  /// Seeded from the draft's links once they and the library have loaded.
  WeavePlan? _fresh;

  /// The last worksheet worked out, shown while the next one is (latest wins, no flicker).
  PlanWorksheet? _last;

  /// Bumped when the plan is removed, so the fields start again from the fresh plan.
  int _generation = 0;

  ({BackupCraft craft, String? id}) get _project =>
      (craft: BackupCraft.weaving, id: widget.projectId);

  /// A new plan starting from the draft's links: its one weaving swatch, and the yarns linked as
  /// warp and as weft.
  static WeavePlan _seed(ProjectMaterials? links, MaterialLibraryState? lib) {
    if (links == null || lib == null || lib.readOnly) return WeavePlan();
    final swatches = [
      for (final l in links.swatches)
        if (lib.swatch(l.swatchId) case final s?)
          if (s.craft == SwatchCraft.weaving || s.craft == null) s,
    ];
    MaterialRecord? yarn(YarnRole role) {
      for (final l in links.yarns) {
        if (l.role == role) return lib.material(l.materialId);
      }
      return null;
    }

    final warp = yarn(YarnRole.warp);
    final weft = yarn(YarnRole.weft);
    final swatch = swatches.length == 1 ? swatches.single : null;
    return WeavePlan(
      swatchId: swatch?.id,
      swatchName: swatch?.displayName,
      warpMaterialId: warp?.id,
      warpMaterialName: warp?.displayName,
      weftMaterialId: weft?.id,
      weftMaterialName: weft?.displayName,
    );
  }

  void _update(WeavePlan next) => ref.read(draftWeavePlanProvider.notifier).state = next;

  LengthUnit get _short => ref.read(appSettingsProvider).unit == MeasureUnit.centimeters
      ? LengthUnit.centimeter
      : LengthUnit.inch;

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this plan?'),
        content: const Text('The finished size, the choices and your own values go. Your swatches '
            'and materials are not changed. The draft is changed when you save it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true && mounted) {
      ref.read(draftWeavePlanProvider.notifier).state = null;
      setState(() => _generation++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stored = ref.watch(draftWeavePlanProvider);
    final locked = ref.watch(draftWeavePlanLockedProvider);
    // Watched (not read once) so they stay loaded and the fresh plan is seeded from their values.
    final links = ref.watch(projectMaterialsProvider(_project));
    final library = ref.watch(materialLibraryProvider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    if (locked && stored == null) {
      return Scaffold(
        appBar: AppBar(title: const Text(kWeavePlanTitle)),
        body: const Padding(
          padding: EdgeInsets.all(PlySpacing.md),
          child: Text(
              key: ValueKey('plan-locked'),
              'This draft has a plan this version of Ply cannot read: made by a newer version, or '
              'changed outside Ply. It is kept as it is, and this version does not replace it.'),
        ),
      );
    }
    bool settled(AsyncValue<Object?> a) => a.hasValue || a.hasError;
    if (stored == null && _fresh == null && settled(links) && settled(library)) {
      _fresh = _seed(links.valueOrNull, library.valueOrNull);
    }
    final fresh = _fresh;
    if (stored == null && fresh == null) {
      return Scaffold(
        appBar: AppBar(title: const Text(kWeavePlanTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final plan = stored ?? fresh!;
    final sheet = ref.watch(weavePlanWorksheetProvider(plan));
    if (sheet case AsyncData(:final value)) _last = value;
    return Scaffold(
      appBar: AppBar(
        title: const Text(kWeavePlanTitle),
        actions: [
          if (stored != null)
            IconButton(
              tooltip: 'Remove this plan',
              onPressed: _remove,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const ValueKey('weave-plan'),
          padding: EdgeInsets.fromLTRB(PlySpacing.md, PlySpacing.sm, PlySpacing.md,
              PlySpacing.lg + MediaQuery.viewInsetsOf(context).bottom),
          children: [
            Text(
                'Plan the warp and weft from the finished size. Every figure says where its numbers '
                'came from. Ply\'s starting estimates are rules of thumb until a swatch gives '
                'measured ones; your own values never change the swatch or the yarn. The plan is '
                'saved with the draft.',
                style: muted),
            const _Header('Finished size'),
            KeyedSubtree(
                key: ValueKey('targets-$_generation'),
                child: _TargetFields(plan: plan, short: _short, onChanged: _update)),
            const _Header('Swatch and yarns'),
            KeyedSubtree(
                key: ValueKey('records-$_generation'),
                child: _RecordChoices(plan: plan, project: _project, onChanged: _update)),
            ...switch (sheet) {
              AsyncData(:final value) => _worksheet(context, plan, value),
              AsyncError(:final error) => [
                  Padding(
                    padding: const EdgeInsets.only(top: PlySpacing.md),
                    child: Text('The plan could not be worked out: $error',
                        key: const ValueKey('plan-error'),
                        style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ],
              _ when _last != null => _worksheet(context, plan, _last!),
              _ => const [
                  Padding(
                    padding: EdgeInsets.all(PlySpacing.md),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _worksheet(BuildContext context, WeavePlan plan, PlanWorksheet w) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final lib = ref.watch(materialLibraryProvider).valueOrNull;
    final swatch = plan.swatchId == null ? null : lib?.swatch(plan.swatchId!);
    final usedSwatch =
        swatch != null && (swatch.craft == SwatchCraft.weaving || swatch.craft == null)
            ? swatch
            : null;
    // Each assumption's Change and Reset are offered once, in the first place on screen that
    // concerns it: an issue first (so an override that cannot be used always has a way back), then
    // its input, then the figure or section it belongs to.
    final offered = <PlanAssumption>{};
    Widget? actionsFor(Iterable<PlanAssumption> assumptions) {
      final mine = [
        for (final a in assumptions)
          if (offered.add(a)) a,
      ];
      if (mine.isEmpty) return null;
      return Wrap(spacing: PlySpacing.xs, children: [
        for (final a in mine) ...[
          _ChangeButton(plan, a, _update, short: _short),
          if (plan.overrides.has(a))
            _ResetButton(plan, a, _update, label: resetLabel(a, plan, usedSwatch)),
        ],
      ]);
    }

    final assumptions = [
      for (final i in w.inputs)
        if (PlanAssumption.forInput(i.key).isNotEmpty) i,
    ];
    final rowKeys = {for (final i in assumptions) i.key};
    final invalid = w.issues.where((i) => i.kind == PlanIssueKind.invalid).toList();
    final needed = w.issues.where((i) => i.kind == PlanIssueKind.needed).toList();
    final otherNotes = [
      for (final n in w.inputNotes)
        if (!rowKeys.contains(n.key)) n.text,
    ];
    return [
      if (invalid.isNotEmpty || needed.isNotEmpty) ...[
        const _Header('To finish the plan'),
        for (final i in [...invalid, ...needed])
          ListTile(
            key: ValueKey('issue-${i.code}-${i.field}'),
            contentPadding: EdgeInsets.zero,
            leading: i.kind == PlanIssueKind.invalid
                ? Icon(Icons.error_outline,
                    color: theme.colorScheme.error, semanticLabel: 'Problem')
                : const Icon(Icons.edit_note_outlined, semanticLabel: 'Still to enter'),
            title: Text(i.message),
            subtitle: actionsFor(PlanAssumption.forInput(i.field)),
          ),
      ],
      const _Header('Assumptions'),
      Text(
          'Each one comes from the swatch when it measured it, else Ply\'s starting estimate for '
          'the structure, unless you give your own.',
          style: muted),
      for (final i in assumptions)
        _AssumptionRow(
          input: i,
          notes: w.notesFor(i.key),
          actions: actionsFor(PlanAssumption.forInput(i.key)),
        ),
      for (final group in _figureGroups)
        if (group.$2.any((k) => w.figure(k) != null)) ...[
          _Header(group.$1),
          for (final k in group.$2)
            if (w.figure(k) case final f?)
              _FigureTile(
                figure: f,
                worksheet: w,
                action: k == 'warp_ends' ? actionsFor(const [PlanAssumption.ends]) : null,
              ),
        ],
      if (w.denting != null || w.checks.isNotEmpty) ...[
        const _Header('Reed and loom'),
        if (w.denting case final d?)
          ExpansionTile(
            key: const ValueKey('plan-denting'),
            tilePadding: EdgeInsets.zero,
            title: Text(d.text),
            children: [
              EstimateTrace(
                  estimate: TracedEstimate<Object?>(
                      value: null, inputs: _used(w, d.uses), working: d.working)),
            ],
          ),
        for (final c in w.checks)
          ListTile(
            key: ValueKey('check-${c.code}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              switch (c.severity) {
                LoomSeverity.notFeasible => Icons.block,
                LoomSeverity.advice => Icons.info_outline,
                LoomSeverity.notChecked => Icons.help_outline,
                LoomSeverity.fits => Icons.check_circle_outline,
              },
              color: c.severity == LoomSeverity.notFeasible ? theme.colorScheme.error : null,
              semanticLabel: switch (c.severity) {
                LoomSeverity.notFeasible => 'Not feasible',
                LoomSeverity.advice => 'Advice',
                LoomSeverity.notChecked => 'Not checked',
                LoomSeverity.fits => 'Fits',
              },
            ),
            title: Text(c.message),
          ),
        if (actionsFor(const [PlanAssumption.reed]) case final reed?) reed,
      ],
      if (w.supply.isNotEmpty) ...[
        const _Header('Yarn'),
        for (final s in w.supply)
          ExpansionTile(
            key: ValueKey('supply-${s.materialId}'),
            tilePadding: EdgeInsets.zero,
            leading: Icon(s.short ? Icons.warning_amber_outlined : Icons.inventory_2_outlined,
                color: s.short ? theme.colorScheme.error : null,
                semanticLabel: s.short ? 'Not enough on hand' : null),
            title: Text(s.text),
            subtitle: s.assumed
                ? Text('Uses Ply\'s starting estimates', style: theme.textTheme.bodySmall)
                : null,
            children: [
              EstimateTrace(
                  estimate: TracedEstimate<Object?>(
                      value: null, inputs: _used(w, s.uses), working: s.working)),
            ],
          ),
      ],
      if (_missingRecords(plan).isNotEmpty || otherNotes.isNotEmpty || w.notes.isNotEmpty) ...[
        const _Header('Notes'),
        for (final n in [..._missingRecords(plan), ...otherNotes, ...w.notes])
          Padding(
            padding: const EdgeInsets.only(top: PlySpacing.xs),
            child: Text(n, style: theme.textTheme.bodySmall),
          ),
      ],
    ];
  }

  /// Sentences for records the plan names that are not in the library now.
  List<String> _missingRecords(WeavePlan plan) {
    final lib = ref.watch(materialLibraryProvider).valueOrNull;
    if (lib == null) return const [];
    String name(String? n) => (n ?? '').trim().isEmpty ? 'a record' : '"${n!.trim()}"';
    return [
      if (plan.swatchId != null && lib.swatch(plan.swatchId!) == null)
        'The swatch this plan names, ${name(plan.swatchName)}, is not in your materials, so the plan '
            'works without it.',
      if (plan.warpMaterialId != null && lib.material(plan.warpMaterialId!) == null)
        'The warp yarn this plan names, ${name(plan.warpMaterialName)}, is not in your materials.',
      if (plan.weftMaterialId != null && lib.material(plan.weftMaterialId!) == null)
        'The weft yarn this plan names, ${name(plan.weftMaterialName)}, is not in your materials.',
    ];
  }
}

/// [v] for a field to start from: at most four decimals, no trailing zeros, so a stored 0.07 shows
/// as 7 (%), not 7.000000000000001.
String prefillNumber(double v) {
  if (!v.isFinite) return '';
  var t = v.toStringAsFixed(4);
  if (t.contains('.')) t = t.replaceFirst(RegExp(r'\.?0+$'), '');
  return t == '-0' ? '0' : t;
}

/// The inputs [keys] name, in the worksheet's order.
List<TracedInput> _used(PlanWorksheet w, List<String> keys) => [
      for (final i in w.inputs)
        if (keys.contains(i.key)) i
    ];

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: PlySpacing.lg, bottom: PlySpacing.xs),
        child: Semantics(
            header: true, child: Text(text, style: Theme.of(context).textTheme.titleSmall)),
      );
}

// --- the finished size --------------------------------------------------------------------------

class _TargetFields extends StatelessWidget {
  const _TargetFields({required this.plan, required this.short, required this.onChanged});

  final WeavePlan plan;
  final LengthUnit short;
  final ValueChanged<WeavePlan> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget length(String key, String label, Length? value, String? helper,
        WeavePlan Function(Length?) apply) {
      final unit = value?.unit ?? short;
      return _NumberField(
        key: ValueKey('plan-$key'),
        label: '$label (${unit.symbol})',
        helper: helper,
        initial: value?.value,
        onChanged: (v) => onChanged(apply(v == null ? null : Length(v, unit))),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<PlanStructure>(
          key: const ValueKey('plan-structure'),
          initialValue: plan.structure,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Structure',
            helperText: 'Picks Ply\'s starting estimates: twill and satin take up and draw in a '
                'little less than plain weave.',
            helperMaxLines: 3,
          ),
          items: [
            for (final s in PlanStructure.values) DropdownMenuItem(value: s, child: Text(s.label)),
          ],
          onChanged: (s) {
            if (s != null) onChanged(plan.copyWith(structure: s));
          },
        ),
        _NumberField(
          key: const ValueKey('plan-items'),
          label: 'Items on this warp',
          integer: true,
          initial: plan.items.toDouble(),
          onChanged: (v) => onChanged(plan.copyWith(items: v?.round() ?? 1)),
        ),
        length('finished-width', 'Finished width', plan.finishedWidth,
            'One item, after wet finishing.', (l) {
          return l == null
              ? plan.copyWith(clear: {'finishedWidth'})
              : plan.copyWith(finishedWidth: l);
        }),
        length('finished-length', 'Finished length', plan.finishedLength,
            'One item, after wet finishing.', (l) {
          return l == null
              ? plan.copyWith(clear: {'finishedLength'})
              : plan.copyWith(finishedLength: l);
        }),
        length('hems', 'Hems', plan.hems,
            'Finished cloth each item folds into hems, both ends together. Optional.', (l) {
          return l == null ? plan.copyWith(clear: {'hems'}) : plan.copyWith(hems: l);
        }),
        length('fringe', 'Fringe', plan.fringe,
            'Unwoven warp each item keeps for fringe, both ends together. Optional.', (l) {
          return l == null ? plan.copyWith(clear: {'fringe'}) : plan.copyWith(fringe: l);
        }),
        length('sampling', 'Sampling', plan.sampling,
            'A length woven at the start of the warp to check the sett and beat. Optional.', (l) {
          return l == null ? plan.copyWith(clear: {'sampling'}) : plan.copyWith(sampling: l);
        }),
        _NumberField(
          key: const ValueKey('plan-end-multiple'),
          label: 'Ends in a repeat',
          helper: 'Rounds the ends to whole repeats of the threading. Optional.',
          integer: true,
          initial: plan.endMultiple?.toDouble(),
          onChanged: (v) => onChanged(v == null
              ? plan.copyWith(clear: {'endMultiple'})
              : plan.copyWith(endMultiple: v.round())),
        ),
        _NumberField(
          key: const ValueKey('plan-extra-ends'),
          label: 'Extra ends',
          helper: 'Added after rounding: floating selvedges, an end to balance a twill.',
          integer: true,
          initial: plan.extraEnds == 0 ? null : plan.extraEnds.toDouble(),
          onChanged: (v) => onChanged(v == null
              ? plan.copyWith(clear: {'extraEnds'})
              : plan.copyWith(extraEnds: v.round())),
        ),
      ],
    );
  }
}

/// A number field that keeps its own text; [onChanged] gets the number, or null when blank. Text
/// that is not a number shows an error and changes nothing.
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.initial,
    required this.onChanged,
    this.helper,
    this.integer = false,
    super.key,
  });

  final String label;
  final String? helper;
  final double? initial;
  final bool integer;
  final ValueChanged<double?> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _c = TextEditingController(
      text: widget.initial == null ? '' : exactQuantityNumber(widget.initial!));
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _changed(String text) {
    final t = text.trim();
    if (t.isEmpty) {
      setState(() => _error = null);
      widget.onChanged(null);
      return;
    }
    final v = widget.integer ? int.tryParse(t)?.toDouble() : double.tryParse(t);
    if (v == null || !v.isFinite) {
      setState(() => _error = widget.integer ? 'Enter a whole number' : 'Enter a number');
      return;
    }
    setState(() => _error = null);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: PlySpacing.sm),
        child: TextField(
          controller: _c,
          keyboardType: TextInputType.numberWithOptions(decimal: !widget.integer),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
                widget.integer ? RegExp(r'[0-9]') : RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(
            labelText: widget.label,
            helperText: widget.helper,
            helperMaxLines: 3,
            errorText: _error,
          ),
          onChanged: _changed,
        ),
      );
}

// --- the swatch and yarns -----------------------------------------------------------------------

class _RecordChoices extends ConsumerWidget {
  const _RecordChoices({required this.plan, required this.project, required this.onChanged});

  final WeavePlan plan;
  final ({BackupCraft craft, String? id}) project;
  final ValueChanged<WeavePlan> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(materialLibraryProvider).valueOrNull;
    final links = ref.watch(projectMaterialsProvider(project)).valueOrNull;
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    if (lib == null || lib.readOnly) {
      return Text(
          lib?.readOnlyReason ??
              'Your materials and swatches are not available, so the plan uses '
                  'your own values and Ply\'s starting estimates.',
          style: muted);
    }
    bool linkedSwatch(SwatchRecord s) => links?.linksSwatch(s.id) ?? false;
    bool linkedYarn(MaterialRecord m) => links?.linksMaterial(m.id) ?? false;
    final swatches = [
      for (final s in lib.swatches)
        if (s.craft == SwatchCraft.weaving || s.craft == null) s,
    ];
    final ordered = [...swatches.where(linkedSwatch), ...swatches.where((s) => !linkedSwatch(s))];
    final yarns = [
      ...lib.materials.where(linkedYarn),
      ...lib.materials.where((m) => !linkedYarn(m)),
    ];
    String? present(String? id, bool Function(String) has) => id != null && has(id) ? id : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String?>(
          key: const ValueKey('plan-swatch'),
          initialValue: present(plan.swatchId, (id) => ordered.any((s) => s.id == id)),
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Swatch',
            helperText: 'A sample woven and finished like the project. Its measurements replace '
                'Ply\'s starting estimates.',
            helperMaxLines: 3,
          ),
          items: [
            const DropdownMenuItem<String?>(
                value: null, child: Text('None: use Ply\'s starting estimates')),
            for (final s in ordered)
              DropdownMenuItem<String?>(
                value: s.id,
                child: Text(
                    '${s.displayName}${s.date == null ? '' : ' (${s.date})'}'
                    '${linkedSwatch(s) ? ', linked' : ''}',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (id) {
            final s = id == null ? null : lib.swatch(id);
            onChanged(s == null
                ? plan.copyWith(clear: {'swatchId', 'swatchName'})
                : plan.copyWith(swatchId: s.id, swatchName: s.displayName));
          },
        ),
        for (final (role, key, label) in const [
          (YarnRole.warp, 'plan-warp-yarn', 'Warp yarn'),
          (YarnRole.weft, 'plan-weft-yarn', 'Weft yarn'),
        ])
          Padding(
            padding: const EdgeInsets.only(top: PlySpacing.sm),
            child: DropdownButtonFormField<String?>(
              key: ValueKey(key),
              initialValue: present(
                  role == YarnRole.warp ? plan.warpMaterialId : plan.weftMaterialId,
                  (id) => yarns.any((m) => m.id == id)),
              isExpanded: true,
              decoration: InputDecoration(
                labelText: label,
                helperText: role == YarnRole.warp
                    ? 'Its length per mass and what you have on hand give the yarn to buy.'
                    : null,
                helperMaxLines: 2,
              ),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('None')),
                for (final m in yarns)
                  DropdownMenuItem<String?>(
                    value: m.id,
                    child: Text('${m.displayName}${linkedYarn(m) ? ', linked' : ''}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) {
                final m = id == null ? null : lib.material(id);
                onChanged(switch ((role, m)) {
                  (YarnRole.warp, null) =>
                    plan.copyWith(clear: {'warpMaterialId', 'warpMaterialName'}),
                  (YarnRole.warp, final m?) =>
                    plan.copyWith(warpMaterialId: m.id, warpMaterialName: m.displayName),
                  (_, null) => plan.copyWith(clear: {'weftMaterialId', 'weftMaterialName'}),
                  (_, final m?) =>
                    plan.copyWith(weftMaterialId: m.id, weftMaterialName: m.displayName),
                });
              },
            ),
          ),
      ],
    );
  }
}

// --- assumptions ---------------------------------------------------------------------------------

class _AssumptionRow extends StatelessWidget {
  const _AssumptionRow({required this.input, this.notes = const [], this.actions});

  final TracedInput input;

  /// The engine's notes that explain this input ("Of that, the swatch measured ...").
  final List<String> notes;

  /// Its Change and Reset, when this row is where they are offered.
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      key: ValueKey('assumption-${input.key}'),
      padding: const EdgeInsets.only(top: PlySpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: PlySpacing.xs),
                child: SourceBadge(input.source),
              ),
              Expanded(
                child: Text('${input.label}: ${input.sentence}',
                    key: ValueKey('input-${input.key}'), style: theme.textTheme.bodyMedium),
              ),
            ],
          ),
          for (final n in notes)
            Padding(
              padding: const EdgeInsets.only(top: PlySpacing.xs),
              child: Text(n, style: muted),
            ),
          if (actions != null) actions!,
        ],
      ),
    );
  }
}

/// "Change take-up": the dialog for the weaver's own value.
class _ChangeButton extends StatelessWidget {
  const _ChangeButton(this.plan, this.assumption, this.onChanged, {required this.short});

  final WeavePlan plan;
  final PlanAssumption assumption;
  final ValueChanged<WeavePlan> onChanged;
  final LengthUnit short;

  @override
  Widget build(BuildContext context) {
    final a = assumption;
    final label = switch (a) {
      PlanAssumption.wpi => 'Work the sett out from wraps',
      PlanAssumption.ends => 'Enter the warp ends',
      PlanAssumption.reed => 'Choose a reed',
      _ => 'Change ${a.noun}',
    };
    return TextButton(
      key: ValueKey('change-${a.jsonKey}'),
      onPressed: () async {
        final v = await showDialog<Object>(
          context: context,
          builder: (_) =>
              _OverrideDialog(assumption: a, current: plan.overrides.values[a], short: short),
        );
        if (v == null) return;
        var overrides = plan.overrides.set(a, v);
        // Working the sett out from wraps replaces an entered sett (which would otherwise win).
        if (a == PlanAssumption.wpi) overrides = overrides.set(PlanAssumption.sett, null);
        onChanged(plan.copyWith(overrides: overrides));
      },
      child: Text(label),
    );
  }
}

/// What taking the weaver's value for [a] out falls back to, as the reset button says it: the
/// swatch only when the chosen swatch (a weaving one, in the library) measured what the engine
/// would read for it; else Ply's estimate; a sett, wraps, ends or reed is simply cleared.
String resetLabel(PlanAssumption a, WeavePlan plan, SwatchRecord? s) {
  bool ok(Recorded<Length>? r) => r != null && r.value.value.isFinite && r.value.value > 0;
  final o = plan.overrides;
  final gives = s != null &&
      switch (a) {
        PlanAssumption.takeUp =>
          (!o.has(PlanAssumption.lengthShrinkage) && ok(s.onLoom.length) && ok(s.after.length)) ||
              (ok(s.onLoom.length) && ok(s.before.length)),
        PlanAssumption.lengthShrinkage =>
          (!o.has(PlanAssumption.takeUp) && ok(s.onLoom.length) && ok(s.after.length)) ||
              (ok(s.before.length) && ok(s.after.length)),
        PlanAssumption.drawIn =>
          (!o.has(PlanAssumption.widthShrinkage) && ok(s.widthInReed) && ok(s.after.width)) ||
              (ok(s.widthInReed) && ok(s.onLoom.width)),
        PlanAssumption.widthShrinkage =>
          (!o.has(PlanAssumption.drawIn) && ok(s.widthInReed) && ok(s.after.width)) ||
              (ok(s.before.width) && ok(s.after.width)),
        PlanAssumption.ppi => (s.onLoom.along?.value.count ?? 0) > 0,
        _ => false,
      };
  return switch (a) {
    PlanAssumption.sett ||
    PlanAssumption.wpi ||
    PlanAssumption.ends ||
    PlanAssumption.reed =>
      'Clear my ${a.noun}',
    _ when gives => 'Use the swatch',
    _ => 'Use Ply\'s estimate',
  };
}

/// The way back: takes the weaver's value out, so the swatch or Ply's estimate is used again.
class _ResetButton extends StatelessWidget {
  const _ResetButton(this.plan, this.assumption, this.onChanged, {required this.label});

  final WeavePlan plan;
  final PlanAssumption assumption;
  final ValueChanged<WeavePlan> onChanged;

  /// From [resetLabel].
  final String label;

  @override
  Widget build(BuildContext context) {
    final a = assumption;
    return TextButton(
      key: ValueKey('reset-${a.jsonKey}'),
      onPressed: () => onChanged(plan.copyWith(overrides: plan.overrides.set(a, null))),
      child: Text(label, semanticsLabel: '$label for the ${a.noun}'),
    );
  }
}

/// The weaver's own value for one assumption. Pops the value (a fraction, a [Length], a
/// [CountOver], an int or a [Reed]), or nothing on cancel.
class _OverrideDialog extends StatefulWidget {
  const _OverrideDialog({required this.assumption, required this.current, required this.short});

  final PlanAssumption assumption;
  final Object? current;
  final LengthUnit short;

  @override
  State<_OverrideDialog> createState() => _OverrideDialogState();
}

class _OverrideDialogState extends State<_OverrideDialog> {
  late final TextEditingController _c = TextEditingController(text: _initialText());
  late bool _metric = switch (widget.current) {
    final Length l => l.unit.isMetric,
    final CountOver c => c.over.unit.isMetric,
    final Reed r => r.per == DentUnit.per10cm,
    _ => widget.short.isMetric,
  };
  String? _error;

  PlanAssumption get _a => widget.assumption;

  String _initialText() => switch (widget.current) {
        final double f => prefillNumber(f * 100),
        final Length l => prefillNumber(l.value),
        final CountOver c => prefillNumber(c.per(Length(1, c.over.unit))),
        final int n => '$n',
        final Reed r => prefillNumber(r.dents),
        _ => '',
      };

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String get _fieldLabel => switch (_a) {
        _ when _a.isFraction => '${_a.label} (%)',
        PlanAssumption.loomWaste => 'Loom waste (${_metric ? 'cm' : 'in'})',
        PlanAssumption.sett => 'Ends per ${_metric ? 'cm' : 'inch'}',
        PlanAssumption.wpi => 'Wraps per ${_metric ? 'cm' : 'inch'}',
        PlanAssumption.ppi => 'Picks per ${_metric ? 'cm' : 'inch'}',
        PlanAssumption.ends => 'Warp ends',
        PlanAssumption.reed => _metric ? 'Dents per 10 cm' : 'Dents per inch',
        _ => _a.label,
      };

  /// The range the engine takes, in what the field shows.
  (double, double) get _range => switch (_a) {
        PlanAssumption.weftAllowance => (0, 200),
        _ when _a.isFraction => (-50, 90),
        PlanAssumption.ends => (1, WeavePlan.maxCount.toDouble()),
        PlanAssumption.reed => (0.01, 1000),
        PlanAssumption.loomWaste => (0, MaterialLimits.maxValue),
        _ => (0.01, _metric ? 393 : 1000),
      };

  void _done() {
    final t = _c.text.trim();
    final v = _a == PlanAssumption.ends ? int.tryParse(t)?.toDouble() : double.tryParse(t);
    final (lo, hi) = _range;
    if (v == null || !v.isFinite || v < lo || v > hi) {
      setState(() => _error = 'Enter a number from ${formatQuantityNumber(lo)} to '
          '${formatQuantityNumber(hi)}.');
      return;
    }
    final unit = _metric ? LengthUnit.centimeter : LengthUnit.inch;
    final Object value = switch (_a) {
      _ when _a.isFraction => v / 100,
      PlanAssumption.loomWaste => Length(v, unit),
      PlanAssumption.sett ||
      PlanAssumption.wpi ||
      PlanAssumption.ppi =>
        CountOver(v, Length(1, unit)),
      PlanAssumption.ends => v.round(),
      PlanAssumption.reed => Reed(v, _metric ? DentUnit.per10cm : DentUnit.perInch),
      _ => v,
    };
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final units = switch (_a) {
      PlanAssumption.loomWaste ||
      PlanAssumption.sett ||
      PlanAssumption.wpi ||
      PlanAssumption.ppi ||
      PlanAssumption.reed =>
        true,
      _ => false,
    };
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return AlertDialog(
      title: Text(_a == PlanAssumption.wpi ? 'Sett from wraps' : 'Your ${_a.noun}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_a.explanation, style: muted),
            if (_a == PlanAssumption.wpi) ...[
              const SizedBox(height: PlySpacing.xs),
              DropdownButton<int>(
                key: const ValueKey('override-yarn-size'),
                isExpanded: true,
                value: null,
                hint: const Text('Typical wraps for a yarn size (measure your own)'),
                items: [
                  for (var i = 0; i < kYarnCountWpi.length; i++)
                    DropdownMenuItem(value: i, child: Text(kYarnCountWpi[i].$1)),
                ],
                onChanged: (i) {
                  if (i == null) return;
                  setState(() {
                    _metric = false;
                    _c.text = exactQuantityNumber(kYarnCountWpi[i].$2);
                  });
                },
              ),
            ],
            const SizedBox(height: PlySpacing.sm),
            TextField(
              key: const ValueKey('override-value'),
              controller: _c,
              autofocus: true,
              keyboardType: TextInputType.numberWithOptions(
                  decimal: _a != PlanAssumption.ends, signed: _a.isFraction),
              decoration: InputDecoration(labelText: _fieldLabel, errorText: _error),
              onSubmitted: (_) => _done(),
            ),
            if (units) ...[
              const SizedBox(height: PlySpacing.sm),
              SegmentedButton<bool>(
                key: const ValueKey('override-per'),
                segments: [
                  ButtonSegment(
                      value: false,
                      label: Text(_a == PlanAssumption.loomWaste ? 'in' : 'per inch')),
                  ButtonSegment(
                      value: true,
                      label: Text(_a == PlanAssumption.loomWaste
                          ? 'cm'
                          : _a == PlanAssumption.reed
                              ? 'per 10 cm'
                              : 'per cm')),
                ],
                selected: {_metric},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _metric = s.first),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _done, child: const Text('Use this value')),
      ],
    );
  }
}

// --- results ------------------------------------------------------------------------------------

class _FigureTile extends StatelessWidget {
  const _FigureTile({required this.figure, required this.worksheet, this.action});

  final PlanFigure figure;
  final PlanWorksheet worksheet;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: ValueKey('figure-${figure.key}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('${figure.label}: ${figure.text}', style: theme.textTheme.bodyLarge),
          subtitle: figure.assumed
              ? Text('Uses Ply\'s starting estimates', style: theme.textTheme.bodySmall)
              : null,
          children: [
            EstimateTrace(
                estimate: TracedEstimate<Object?>(
                    value: null, inputs: _used(worksheet, figure.uses), working: figure.working)),
          ],
        ),
        if (action != null) action!,
      ],
    );
  }
}
