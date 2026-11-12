// The "Generate structure" sheet (M3 Phase 3): a modal that lays down a complete weave structure —
// a plain / twill / satin tie-up plus a straight or point threading, sized to the entered ends x
// picks — and COMMITS it into the editor as one undo entry. The engine builds the tie-up/threading
// (the repo wrapper `generateStructureDoc`); this widget only collects parameters and commits.
// Shadow weave (Atwater / Powell) has its own controls (system, shafts, layout, block widths, tie-up
// direction, block edges, repeats) and goes through `generateShadowWeaveDoc`; its size is whole
// repeats, shown live, never a typed ends x picks.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/shadow_weave_params.dart';
import '../rust/dto.dart' show StructureFamily, ThreadingKind;
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import 'adaptive_sheet.dart';

/// Open the structure generator. Call from a context inside the editor's ProviderScope. Adaptive: a
/// modal bottom sheet on phones, a centered dialog on tablet/wide screens.
Future<void> showStructureSheet(BuildContext context) {
  return showAdaptiveSheet<void>(context, child: const StructureSheet());
}

/// The last-used structure choices, so reopening the sheet restores them ("remember & re-tweak").
/// Persists for the app session; ends/picks are intentionally NOT remembered (they re-seed from the
/// current draft's size, which is more useful).
typedef _StructureParams = ({
  StructureFamily family,
  ThreadingKind threading,
  String over,
  String under,
  String shafts,
  String counter,
  String block,
  ShadowWeaveParams shadow,
  bool applyThreading,
  bool applyTieup,
  bool applyTreadling,
  String endStart,
  String pickStart,
});

final _lastStructureParamsProvider = StateProvider<_StructureParams?>((ref) => null);

/// Largest generated cloth per axis (ends and picks). 2000 x 2000 is the 4-million-intersection
/// preview budget (`RenderLimits::DEFAULT` in ply-weave), so a generated draft always previews;
/// larger drafts can still be imported from WIF.
const int kMaxGeneratedThreads = 2000;

class StructureSheet extends ConsumerStatefulWidget {
  const StructureSheet({super.key});

  @override
  ConsumerState<StructureSheet> createState() => _StructureSheetState();
}

class _StructureSheetState extends ConsumerState<StructureSheet> {
  final _form = GlobalKey<FormState>();

  StructureFamily _family = StructureFamily.twill;
  ThreadingKind _threading = ThreadingKind.straight;

  final _over = TextEditingController(text: '2');
  final _under = TextEditingController(text: '2');
  final _shafts = TextEditingController(text: '4');
  final _counter = TextEditingController(text: '2');
  final _ends = TextEditingController(text: '16');
  final _picks = TextEditingController(text: '16');
  // Block width (overshot).
  final _block = TextEditingController(text: '4');

  // Shadow weave: its own design knobs. There is one width field per possible block (A to H); only
  // the first `_shadowShafts` are shown and used.
  static const _defaultShadow = ShadowWeaveParams();
  ShadowSystem _shadowSystem = _defaultShadow.system;
  int _shadowShafts = _defaultShadow.shafts;
  ShadowLayout _shadowLayout = _defaultShadow.layout;
  final _blockUnits = [
    for (var b = 0; b < ShadowWeaveParams.supportedShafts.last; b++)
      TextEditingController(text: '${ShadowWeaveParams.defaultUnits}'),
  ];
  bool _reverseTwill = _defaultShadow.reverseTwill;
  bool _featheryEdges = _defaultShadow.featheryEdges;
  final _warpRepeats = TextEditingController(text: '${_defaultShadow.warpRepeats}');
  final _weftRepeats = TextEditingController(text: '${_defaultShadow.weftRepeats}');
  bool _balanced = _defaultShadow.balanced;

  // Composable application (basic families): which components a Generate (re)writes, and where the
  // generated patch is placed (so a structure can be laid into a band / one component swapped).
  bool _applyThreading = true;
  bool _applyTieup = true;
  bool _applyTreadling = true;
  final _endStart = TextEditingController(text: '0');
  final _pickStart = TextEditingController(text: '0');

  bool _generating = false;

  /// Whole-draft structures: the engine builds the whole interdependent draft (threading + tie-up +
  /// treadling + warp/weft colors), so the family/threading/shaft params don't apply, only the
  /// structure's own knobs (overshot's block width and size; shadow weave's design and repeats).
  static const _wholeDraft = {
    StructureFamily.overshot,
    StructureFamily.shadowWeave,
    StructureFamily.doubleWeave,
  };

  @override
  void initState() {
    super.initState();
    // Restore the last-used structure choices (family, params, components, offsets) if any.
    final last = ref.read(_lastStructureParamsProvider);
    if (last != null) {
      _family = last.family;
      _threading = last.threading;
      _over.text = last.over;
      _under.text = last.under;
      _shafts.text = last.shafts;
      _counter.text = last.counter;
      _block.text = last.block;
      _restoreShadow(last.shadow);
      _applyThreading = last.applyThreading;
      _applyTieup = last.applyTieup;
      _applyTreadling = last.applyTreadling;
      _endStart.text = last.endStart;
      _pickStart.text = last.pickStart;
    }
    // Seed ends/picks from the current draft when it already has a cloth (overridable, not remembered).
    final draft = ref.read(draftEditorProvider).draft;
    if (draft.ends > 0) _ends.text = '${draft.ends}';
    if (draft.picks > 0) _picks.text = '${draft.picks}';
  }

  @override
  void dispose() {
    for (final c in [
      _over,
      _under,
      _shafts,
      _counter,
      _ends,
      _picks,
      _block,
      _endStart,
      _pickStart,
      ..._blockUnits,
      _warpRepeats,
      _weftRepeats,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static const int _maxShafts = 200; // a generous loom ceiling, far below the u16 wire limit
  /// Offsets may reach anywhere in a draft, up to the per-axis document cap shared with WIF import.
  static const int _maxThreads = 100000;


  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  /// A counter is a valid SATIN move iff `1 < counter < shafts` and it shares no factor with
  /// `shafts` — otherwise the satin steps over a subset of shafts, leaving the rest never raised
  /// (full-length floats). Returns true when [shafts] is unknown (the shafts field validates that).
  static bool _validSatinCounter(int? counter, int? shafts) {
    if (counter == null) return false;
    if (shafts == null) return true;
    return counter > 1 && counter < shafts && _gcd(counter, shafts) == 1;
  }

  String? _shaftCount(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null || v < 1) return 'At least 1';
    return v > _maxShafts ? 'Too many' : null;
  }

  /// Shafts validator that depends on the family: plain needs >= 2 (one odd, one even); satin needs
  /// >= 5 (no true satin exists below 5 shafts). Plain weave lifts the odd shafts against the even
  /// ones, so neighbouring ends must alternate odd/even shafts: a POINT draw always does, but a
  /// STRAIGHT draw over an odd count puts the last shaft (odd) next to shaft 1 (odd), which then rise
  /// together and break the plain weave at every repeat.
  String? _structureShafts(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null) return 'At least 1';
    if (v > _maxShafts) return 'Too many';
    if (_family == StructureFamily.satin) return v < 5 ? 'Satin needs at least 5 shafts' : null;
    if (v < 2) return 'Plain needs at least 2 shafts';
    if (v.isOdd && _applyThreading && _threading == ThreadingKind.straight) {
      return 'Use an even number, or a point draw';
    }
    return null;
  }

  /// Satin counter validator (cross-field on the shafts value).
  String? _satinCounter(String? s) {
    final c = int.tryParse((s ?? '').trim());
    if (c == null || c < 1) return 'At least 1';
    final n = int.tryParse(_shafts.text.trim());
    if (n != null && n >= 2 && !_validSatinCounter(c, n)) {
      return 'Use a move between 2 and ${n - 1} sharing no factor with $n';
    }
    return null;
  }

  String? _threadCount(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null || v < 1) return 'At least 1';
    return v > kMaxGeneratedThreads ? 'At most $kMaxGeneratedThreads' : null;
  }

  /// Block width (overshot): needs >= 2 (a block alternates a pair of shafts), capped well below the
  /// thread ceiling.
  String? _blockCount(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null || v < 2) return 'At least 2';
    return v > 64 ? 'Too large' : null;
  }

  /// Put the shadow-weave controls back to [p] (the last generate, on reopening the sheet).
  void _restoreShadow(ShadowWeaveParams p) {
    _shadowSystem = p.system;
    _shadowShafts = p.shafts;
    _shadowLayout = p.layout;
    for (var b = 0; b < p.blockUnits.length && b < _blockUnits.length; b++) {
      _blockUnits[b].text = '${p.blockUnits[b]}';
    }
    _reverseTwill = p.reverseTwill;
    _featheryEdges = p.featheryEdges;
    _warpRepeats.text = '${p.warpRepeats}';
    _weftRepeats.text = '${p.weftRepeats}';
    _balanced = p.balanced;
  }

  /// The shadow-weave design the controls describe, or null while a width or repeat is not a whole
  /// number of at least 1 (its field says why on Generate).
  ShadowWeaveParams? _shadowParams() {
    int? whole(TextEditingController c) {
      final v = int.tryParse(c.text.trim());
      return v == null || v < 1 ? null : v;
    }

    final units = [for (var b = 0; b < _shadowShafts; b++) whole(_blockUnits[b])];
    final warp = whole(_warpRepeats);
    final weft = whole(_weftRepeats);
    if (warp == null || weft == null || units.contains(null)) return null;
    return ShadowWeaveParams(
      system: _shadowSystem,
      shafts: _shadowShafts,
      layout: _shadowLayout,
      blockUnits: [for (final u in units) u!],
      reverseTwill: _reverseTwill,
      featheryEdges: _featheryEdges,
      warpRepeats: warp,
      weftRepeats: weft,
      balanced: _balanced,
    );
  }

  /// A shadow-weave block width: a whole number of units, 1 to [ShadowWeaveParams.maxUnits].
  String? _blockUnitsCount(String? s) {
    final t = (s ?? '').trim();
    final v = int.tryParse(t);
    if (v == null) return t.isEmpty ? 'At least 1' : 'Too large';
    if (v < 1) return 'At least 1';
    return v > ShadowWeaveParams.maxUnits ? 'At most ${ShadowWeaveParams.maxUnits}' : null;
  }

  /// A shadow-weave repeat count: at least 1, and the resulting cloth must fit the per-axis cap.
  String? _repeatCount(String? s, {required bool warp}) {
    final t = (s ?? '').trim();
    final v = int.tryParse(t);
    if (v == null) return t.isEmpty ? 'At least 1' : 'Too large';
    if (v < 1) return 'At least 1';
    final p = _shadowParams();
    if (p == null) return null; // a block width is not valid yet; its own field reports it
    final n = warp ? p.ends : p.picks;
    if (n > kMaxGeneratedThreads) {
      return 'Gives $n ${warp ? 'ends' : 'picks'}; at most $kMaxGeneratedThreads';
    }
    return null;
  }

  /// Patch offset (start at end / start at pick): 0 or more.
  String? _offset(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null || v < 0) return '0 or more';
    return v > _maxThreads ? 'Too large' : null;
  }

  /// Switch families, seeding VALID defaults so a generate on the defaults always yields good cloth
  /// (the satin defaults must be coprime; the prior shafts default of 4 has no valid satin).
  void _onFamily(StructureFamily f) {
    setState(() {
      _family = f;
      if (f == StructureFamily.satin) {
        if ((int.tryParse(_shafts.text.trim()) ?? 0) < 5) _shafts.text = '5';
        if (!_validSatinCounter(int.tryParse(_counter.text.trim()), int.tryParse(_shafts.text.trim()))) {
          _counter.text = '2';
        }
      } else if (f == StructureFamily.plain) {
        if ((int.tryParse(_shafts.text.trim()) ?? 0) < 2) _shafts.text = '4';
      }
    });
  }

  Future<void> _generate() async {
    if (_generating || !_form.currentState!.validate()) return;
    // Read fields tolerantly: a field hidden for the current family (e.g. Shafts under Twill) is not
    // in the tree and so not validated, and may hold a stale/empty value — fall back rather than
    // throw a FormatException on int.parse.
    final shafts = int.tryParse(_shafts.text.trim()) ?? 4;
    final over = int.tryParse(_over.text.trim()) ?? 2;
    final under = int.tryParse(_under.text.trim()) ?? 2;
    final effShafts = _family == StructureFamily.twill ? over + under : shafts;
    if (!_wholeDraft.contains(_family) && effShafts > _maxShafts) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('That many shafts exceeds the loom (max 200).')));
      return;
    }
    // Basic families apply one or more components; with none selected a Generate would do nothing.
    if (!_wholeDraft.contains(_family) && !_applyThreading && !_applyTieup && !_applyTreadling) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Pick at least one component to apply.')));
      return;
    }
    // Shadow weave is sized and shaped by its own controls (validated above with the form).
    final shadow = _family == StructureFamily.shadowWeave ? _shadowParams() : null;
    if (_family == StructureFamily.shadowWeave && shadow == null) return;
    setState(() => _generating = true);
    final navigator = Navigator.of(context);
    try {
      final repo = ref.read(repositoryProvider);
      final notifier = ref.read(draftEditorProvider.notifier);
      final base = ref.read(draftEditorProvider).draft;
      final doc = shadow != null
          ? await repo.generateShadowWeaveDoc(base, shadow)
          : await repo.generateStructureDoc(
              base,
              family: _family,
              threading: _threading,
              shafts: shafts,
              over: over,
              under: under,
              counter: int.tryParse(_counter.text.trim()) ?? 2,
              ends: int.tryParse(_ends.text.trim()) ?? 16,
              picks: int.tryParse(_picks.text.trim()) ?? 16,
              block: int.tryParse(_block.text.trim()) ?? 4,
              applyThreading: _applyThreading,
              applyTieup: _applyTieup,
              applyTreadling: _applyTreadling,
              endStart: int.tryParse(_endStart.text.trim()) ?? 0,
              pickStart: int.tryParse(_pickStart.text.trim()) ?? 0,
            );
      if (!mounted) return;
      notifier.commitEdit(doc); // one undo entry: applies the structure into the draft
      // A whole-draft generate (re)defines the structure, so set the Book view pin to match: overshot
      // pins the Book view button, every other whole-draft structure unpins it. The editor grid is
      // one row per pick either way. A composable partial apply (basic families) leaves it untouched.
      if (_wholeDraft.contains(_family)) {
        ref.read(overshotTreadlingProvider.notifier).state =
            _family == StructureFamily.overshot;
      }
      // Remember the choices so reopening the sheet restores them.
      ref.read(_lastStructureParamsProvider.notifier).state = (
        family: _family,
        threading: _threading,
        over: _over.text,
        under: _under.text,
        shafts: _shafts.text,
        counter: _counter.text,
        block: _block.text,
        shadow: shadow ??
            _shadowParams() ??
            ref.read(_lastStructureParamsProvider)?.shadow ??
            _defaultShadow,
        applyThreading: _applyThreading,
        applyTieup: _applyTieup,
        applyTreadling: _applyTreadling,
        endStart: _endStart.text,
        pickStart: _pickStart.text,
      );
      navigator.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not generate: $e')));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final isTwill = _family == StructureFamily.twill;
    final isSatin = _family == StructureFamily.satin;
    final isWhole = _wholeDraft.contains(_family);
    final isOvershot = _family == StructureFamily.overshot;
    final isShadow = _family == StructureFamily.shadowWeave;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Generate structure', style: text.titleMedium),
              const SizedBox(height: 4),
              Text(
                  isWhole
                      ? 'Replaces the cloth with a complete generated weave (its colors included).'
                      : 'Applies the chosen parts into the draft — non-destructive, so your colors and any untouched areas stay.',
                  style: text.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 16),

              DropdownButtonFormField<StructureFamily>(
                initialValue: _family,
                decoration: const InputDecoration(labelText: 'Structure'),
                onChanged: (v) => _onFamily(v ?? StructureFamily.twill),
                items: const [
                  DropdownMenuItem(value: StructureFamily.plain, child: Text('Plain weave')),
                  DropdownMenuItem(value: StructureFamily.twill, child: Text('Twill')),
                  DropdownMenuItem(value: StructureFamily.satin, child: Text('Satin')),
                  DropdownMenuItem(value: StructureFamily.overshot, child: Text('Overshot')),
                  DropdownMenuItem(
                      value: StructureFamily.shadowWeave, child: Text('Shadow weave')),
                  DropdownMenuItem(
                      value: StructureFamily.doubleWeave, child: Text('Double weave')),
                ],
              ),

              // Tie-up family parameters (plain / twill / satin).
              if (isTwill)
                Row(
                  children: [
                    Expanded(child: _numField(_over, 'Over')),
                    const SizedBox(width: 12),
                    Expanded(child: _numField(_under, 'Under')),
                  ],
                ),
              if (!isTwill && !isWhole)
                _numField(_shafts, 'Shafts', _structureShafts),
              if (isSatin)
                _numField(_counter, 'Counter (satin move)', _satinCounter),

              // Whole-draft structure knobs.
              if (isOvershot)
                _numField(_block, 'Block width', _blockCount),
              if (isShadow) ..._shadowControls(context),

              // Threading applies only to the tie-up families; the whole-draft structures fix theirs.
              if (!isWhole) ...[
                const SizedBox(height: 4),
                DropdownButtonFormField<ThreadingKind>(
                  initialValue: _threading,
                  decoration: const InputDecoration(labelText: 'Threading'),
                  onChanged: (v) => setState(() => _threading = v ?? ThreadingKind.straight),
                  items: const [
                    DropdownMenuItem(value: ThreadingKind.straight, child: Text('Straight draw')),
                    DropdownMenuItem(value: ThreadingKind.point, child: Text('Point draw')),
                  ],
                ),
              ],

              // Shadow weave is sized in whole repeats by its own controls.
              if (!isShadow)
                Row(
                  children: [
                    Expanded(child: _numField(_ends, 'Warp ends', _threadCount)),
                    const SizedBox(width: 12),
                    Expanded(child: _numField(_picks, 'Picks', _threadCount)),
                  ],
                ),

              // Composable application (basic families): which components to (re)write, and where to
              // place the generated patch — so a structure can be mixed into a band (Start at end/pick)
              // or one part swapped (deselect the others), without disturbing the rest.
              if (!isWhole) ...[
                const SizedBox(height: 16),
                Text('Apply', style: text.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('Threading'),
                      selected: _applyThreading,
                      onSelected: (v) => setState(() => _applyThreading = v),
                    ),
                    FilterChip(
                      label: const Text('Tie-up'),
                      selected: _applyTieup,
                      onSelected: (v) => setState(() => _applyTieup = v),
                    ),
                    FilterChip(
                      label: const Text('Treadling'),
                      selected: _applyTreadling,
                      onSelected: (v) => setState(() => _applyTreadling = v),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _numField(_endStart, 'Start at end', _offset)),
                    const SizedBox(width: 12),
                    Expanded(child: _numField(_pickStart, 'Start at pick', _offset)),
                  ],
                ),
              ],

              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _generating ? null : _generate,
                  child: const Text('Generate'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The shadow-weave controls: system, shafts, layout, one width per block, tie-up direction,
  /// block edges, repeats, balance, and the resulting size (updated as the fields change).
  List<Widget> _shadowControls(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = text.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final params = _shadowParams();
    final pairs = ShadowWeaveParams.partnerPairs(_shadowSystem, _shadowShafts)
        .map((p) => '${p.$1} & ${p.$2}')
        .join(', ');
    final lastBlock = ShadowWeaveParams.blockLetter(_shadowShafts - 1);
    final tooLarge = params != null &&
        (params.ends > kMaxGeneratedThreads || params.picks > kMaxGeneratedThreads);
    void refresh(String _) => setState(() {});
    String shaftsOf(int block) {
      final (dark, light) = ShadowWeaveParams.blockShafts(_shadowSystem, _shadowShafts, block);
      return '$dark & $light';
    }

    return [
      const SizedBox(height: 16),
      Text('System', style: text.labelLarge),
      const SizedBox(height: 8),
      SegmentedButton<ShadowSystem>(
        segments: const [
          ButtonSegment(value: ShadowSystem.atwater, label: Text('Atwater')),
          ButtonSegment(value: ShadowSystem.powell, label: Text('Powell')),
        ],
        selected: {_shadowSystem},
        onSelectionChanged: (s) => setState(() => _shadowSystem = s.first),
      ),
      const SizedBox(height: 4),
      Text('Partner shafts $pairs. Both systems weave the same cloth.', style: muted),
      const SizedBox(height: 16),
      Text('Shafts', style: text.labelLarge),
      const SizedBox(height: 8),
      SegmentedButton<int>(
        segments: [
          for (final n in ShadowWeaveParams.supportedShafts)
            ButtonSegment(value: n, label: Text('$n')),
        ],
        selected: {_shadowShafts},
        onSelectionChanged: (s) => setState(() => _shadowShafts = s.first),
      ),
      const SizedBox(height: 16),
      Text('Layout', style: text.labelLarge),
      const SizedBox(height: 8),
      SegmentedButton<ShadowLayout>(
        segments: const [
          ButtonSegment(value: ShadowLayout.point, label: Text('Point')),
          ButtonSegment(value: ShadowLayout.repeat, label: Text('Straight repeat')),
        ],
        selected: {_shadowLayout},
        onSelectionChanged: (s) => setState(() => _shadowLayout = s.first),
      ),
      const SizedBox(height: 4),
      Text(
          _shadowLayout == ShadowLayout.point
              ? 'Blocks run A to $lastBlock, then back again.'
              : 'Blocks run A to $lastBlock, then start over.',
          style: muted),
      const SizedBox(height: 16),
      Text('Block widths', style: text.labelLarge),
      const SizedBox(height: 4),
      Text(
          'Units per block; a unit is one dark and one light thread. '
          'Under each block: its dark & light shafts.',
          style: muted),
      Wrap(
        spacing: 8,
        children: [
          for (var b = 0; b < _shadowShafts; b++)
            SizedBox(
              width: 76,
              child: _numberField(
                _blockUnits[b],
                ShadowWeaveParams.blockLetter(b),
                _blockUnitsCount,
                helper: shaftsOf(b),
                onChanged: refresh,
              ),
            ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Reverse the tie-up twill'),
        subtitle: const Text('Turns the block diagonal the other way'),
        value: _reverseTwill,
        onChanged: (v) => setState(() => _reverseTwill = v),
      ),
      Text('Block edges', style: text.labelLarge),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('Smooth')),
          ButtonSegment(value: true, label: Text('Feathery')),
        ],
        selected: {_featheryEdges},
        onSelectionChanged: (s) => setState(() => _featheryEdges = s.first),
      ),
      const SizedBox(height: 4),
      Text('Feathery swaps the weft colors in each pair of picks; the weave itself is the same.',
          style: muted),
      Row(
        children: [
          Expanded(
            child: _numberField(_warpRepeats, 'Warp repeats', (s) => _repeatCount(s, warp: true),
                onChanged: refresh),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _numberField(_weftRepeats, 'Weft repeats', (s) => _repeatCount(s, warp: false),
                onChanged: refresh),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Balance the edges'),
        subtitle: const Text('Repeat the first end and pick once at the end'),
        value: _balanced,
        onChanged: (v) => setState(() => _balanced = v),
      ),
      Text(
        params == null
            ? 'Resulting size: enter every block width and repeat'
            : 'Resulting size: ${params.ends} ends x ${params.picks} picks',
        key: const Key('shadow-weave-size'),
        style: text.bodyMedium?.copyWith(color: tooLarge ? theme.colorScheme.error : null),
      ),
    ];
  }

  Widget _numField(
    TextEditingController c,
    String label, [
    FormFieldValidator<String>? validator,
  ]) =>
      _numberField(c, label, validator);

  Widget _numberField(
    TextEditingController c,
    String label,
    FormFieldValidator<String>? validator, {
    String? helper,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextFormField(
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
        decoration: InputDecoration(labelText: label, helperText: helper),
        validator: validator ?? _shaftCount,
        onChanged: onChanged,
      ),
    );
  }
}
