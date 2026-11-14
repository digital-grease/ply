import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/draft_repository.dart' show previewErrorMessage;
import '../models/double_weave_construction.dart';
import '../models/double_weave_layers.dart';
import '../models/draft_doc.dart';
import '../models/weft_work.dart' show directionNotes, passArrow, passStarts, passWords, shuttlesInUse;
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import '../widgets/drawdown_view.dart';

/// An inspector for a double weave's two layers (M8-09): the construction (declared, and whether the
/// derived edges match it), what happens at each edge, the working order with pass directions, and
/// TWO drawdowns, the top layer's cloth above the bottom layer's. A shaft picker lets the weaver
/// assign which shafts belong to the top layer (the rest are the bottom); the picks that weave each
/// layer are derived from the structure (see [doubleWeaveLayerDraft]) and rendered through the SAME
/// renderer. The top view is labeled the cloth's "Top face" only when that is provable (see
/// [topFaceUnavailable]); otherwise each view is one layer's own interlacement.
///
/// The only edit it makes is the construction label: "Use as ..." when the derived edges match a
/// construction exactly (after the weaver confirms), and "Remove the label".
class LayerInspectorScreen extends ConsumerStatefulWidget {
  const LayerInspectorScreen({required this.draft, super.key});

  /// A snapshot of the draft to inspect (taken when the inspector opens).
  final DraftDoc draft;

  @override
  ConsumerState<LayerInspectorScreen> createState() => _LayerInspectorScreenState();
}

class _LayerInspectorScreenState extends ConsumerState<LayerInspectorScreen> {
  /// The inspected draft: the snapshot, updated when the construction label changes here.
  late DraftDoc _draft = widget.draft;

  /// Shafts assigned to the TOP layer (the rest are bottom). Seeded to the odd shafts.
  late Set<int> _topShafts;

  ui.Image? _topImage;
  ui.Image? _bottomImage;
  /// Why a layer has nothing to draw (null = it rendered).
  String? _topEmpty;
  String? _bottomEmpty;
  bool _loading = true;
  String? _error;

  /// Monotonic guard so a slow render for a previous shaft assignment can't paint over a newer one.
  int _seq = 0;

  /// How many picks the working order lists before "and N more".
  static const int _shownPicks = 16;

  @override
  void initState() {
    super.initState();
    _topShafts = defaultTopShafts(_draft);
    _render();
  }

  @override
  void dispose() {
    _topImage?.dispose();
    _bottomImage?.dispose();
    super.dispose();
  }

  Future<void> _render() async {
    final repo = ref.read(repositoryProvider);
    final topDraft = doubleWeaveLayerDraft(_draft, topShafts: _topShafts, top: true);
    final botDraft = doubleWeaveLayerDraft(_draft, topShafts: _topShafts, top: false);
    // A 0x0 layer can't be rendered (its image would NaN the AspectRatio), so say why instead.
    final topEmpty = _emptyReason(topDraft);
    final botEmpty = _emptyReason(botDraft);
    final mySeq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Kick off BOTH layer renders concurrently (don't serialize on the first decode), then await.
      final topFut = topEmpty != null ? null : repo.renderDto(topDraft, cellPx: 18, gridlines: true);
      final botFut = botEmpty != null ? null : repo.renderDto(botDraft, cellPx: 18, gridlines: true);
      final topImg = topFut == null ? null : await topFut;
      final botImg = botFut == null ? null : await botFut;
      if (!mounted || mySeq != _seq) {
        topImg?.dispose();
        botImg?.dispose();
        return;
      }
      setState(() {
        _topImage?.dispose();
        _bottomImage?.dispose();
        _topImage = topImg;
        _bottomImage = botImg;
        _topEmpty = topEmpty;
        _bottomEmpty = botEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _error = 'Could not render the layers: ${previewErrorMessage(e)}';
        _loading = false;
      });
    }
  }

  static String? _emptyReason(DraftDoc layer) {
    if (layer.ends == 0) return 'No warp ends are on this layer\'s shafts.';
    if (layer.picks == 0) return 'No picks weave this layer with this shaft assignment.';
    return null;
  }

  /// One line per reason a pick weaves neither layer, listing the (1-based) picks.
  static List<String> _unclassifiedLines(PickLayers layers) {
    const why = {
      UnclassifiedPick.noSplit: 'every shaft is in one layer',
      UnclassifiedPick.overEverything: 'nothing raised, the weft floats over both layers',
      UnclassifiedPick.underEverything: 'every shaft raised, the weft passes under both layers',
      UnclassifiedPick.betweenLayers: 'top layer raised, the weft lies between the layers',
      UnclassifiedPick.crossesLayers: 'joins or crosses the layers (or not double weave here)',
    };
    final byReason = <UnclassifiedPick, List<int>>{};
    layers.unclassified.forEach((pick, reason) => byReason.putIfAbsent(reason, () => []).add(pick + 1));
    return [
      for (final reason in UnclassifiedPick.values)
        if (byReason[reason] case final picks?)
          '${picks.length == 1 ? 'Pick' : 'Picks'} ${_pickList(picks)}: ${why[reason]}',
    ];
  }

  static String _pickList(List<int> picks) {
    const shown = 8;
    final head = picks.take(shown).join(', ');
    return picks.length > shown ? '$head and ${picks.length - shown} more' : head;
  }

  void _toggleShaft(int shaft) {
    setState(() {
      if (!_topShafts.remove(shaft)) _topShafts.add(shaft);
    });
    _render();
  }

  /// What the edges are, for the confirmation of [c].
  static String _edgeSummary(LayerConstruction c) => switch (c) {
        LayerConstruction.twoLayers => 'every weft turns back into its own layer at both edges',
        LayerConstruction.tube => 'every weft passes from one layer to the other at both edges',
        LayerConstruction.doubleWidthFoldLeft =>
          'the layers join on the left and are open on the right',
        LayerConstruction.doubleWidthFoldRight =>
          'the layers join on the right and are open on the left',
        LayerConstruction.none => '',
      };

  /// Confirm, then declare [c] on the live draft (one undo entry) and here.
  Future<void> _useAs(LayerConstruction c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm the construction'),
        content: Text('The edges of this draft match ${constructionPhrase(c)}: ${_edgeSummary(c)}. '
            'Ply will keep this label with the draft and warn you if a later edit no longer '
            'matches it.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(useAsLabel(c))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _applyConstruction(c);
  }

  void _applyConstruction(LayerConstruction c) {
    // The inspector opened on a snapshot; only label the live draft when it is still that draft.
    if (ref.read(draftEditorProvider).draft != _draft) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The draft changed since this view opened. Close it and open it again.')));
      return;
    }
    ref.read(draftEditorProvider.notifier).setConstruction(c);
    setState(() => _draft = _draft.copyWith(construction: c));
  }

  static String _edgeText(EdgeBehavior? b) => switch (b) {
        null => 'Unknown',
        EdgeBehavior.open => 'Open: each layer turns back at its own selvedge',
        EdgeBehavior.joined =>
          'Joined: the weft passes from one layer to the other (a fold or a closed edge)',
        EdgeBehavior.mixed => 'Mixed: the layers join at some turns and not at others',
        EdgeBehavior.noTurns => 'No shuttle turns here yet',
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final shaftCount = maxLayerShaft(_draft);
    final layers = classifyPicks(_draft, _topShafts);
    final unclassified = _unclassifiedLines(layers);
    final faceReason = topFaceUnavailable(_draft, layers);
    final panelHeight = (MediaQuery.sizeOf(context).height * 0.4).clamp(180.0, 420.0);
    return Scaffold(
      appBar: AppBar(title: const Text('Double-weave layers')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Top-layer shafts', style: text.titleSmall),
                  const SizedBox(height: 2),
                  Text('Tap a shaft to move it between the top and bottom layer.', style: muted),
                  const SizedBox(height: 2),
                  if (faceReason == null)
                    Text(
                        'The top view is the top face: what you see from above as you weave. '
                        'Only the top layer shows there. The bottom view is the bottom layer\'s '
                        'own interlacement.',
                        style: muted)
                  else ...[
                    Text(
                        "Each view shows one layer's own interlacement, not the face of the finished "
                        'cloth.',
                        style: muted),
                    Text(faceReason, key: const Key('top-face-reason'), style: muted),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (var s = 1; s <= shaftCount; s++)
                        FilterChip(
                          label: Text('$s'),
                          selected: _topShafts.contains(s),
                          onSelected: (_) => _toggleShaft(s),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (unclassified.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${layers.unclassified.length} of ${_draft.picks} picks weave neither '
                      'layer, so neither view shows them:',
                      style: text.bodySmall?.copyWith(color: cs.onSurface),
                    ),
                    for (final line in unclassified) Text(line, style: muted),
                  ],
                ),
              ),
            _constructionSection(context),
            const Divider(height: 12),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              )
            else ...[
              SizedBox(
                height: panelHeight,
                child: _layerPanel(
                    context, faceReason == null ? 'Top face' : 'Top layer', _topImage, _topEmpty),
              ),
              const Divider(height: 1),
              SizedBox(
                height: panelHeight,
                child: _layerPanel(context, 'Bottom layer', _bottomImage, _bottomEmpty),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The construction, the edge legend, and the working order.
  Widget _constructionSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final declared = _draft.construction;
    final derived = deriveEdges(_draft);
    final known = derived is EdgesKnown ? derived : null;
    final offer = declared == LayerConstruction.none && known != null
        ? known.construction
        : LayerConstruction.none;
    final issues = constructionIssues(_draft);

    final String status;
    if (declared != LayerConstruction.none) {
      status = issues.isEmpty ? 'The edges match this construction.' : issues.join('\n');
    } else if (derived case EdgesUnknown(:final reason)) {
      status = 'Ply cannot tell the construction because $reason.';
    } else if (offer != LayerConstruction.none) {
      status = 'The edges match ${constructionPhrase(offer)}. Ply labels a draft only when you '
          'confirm it.';
    } else {
      status = 'The edges do not match one construction exactly, so Ply does not offer a label.';
    }

    final shuttles = shuttlesInUse(_draft);
    final picks = _draft.picks;
    final starts = passStarts(_draft);
    String layerLetter(int p) => switch (_draft.roleAt(p)) {
          PickRole.topLayer => 'T',
          PickRole.bottomLayer => 'B',
          _ => '?',
        };
    String layerWords(int p) => switch (_draft.roleAt(p)) {
          PickRole.topLayer => 'top layer',
          PickRole.bottomLayer => 'bottom layer',
          _ => 'no layer role',
        };
    final crossNote = (known?.left == EdgeBehavior.open || known?.right == EdgeBehavior.open) &&
        shuttles.length > 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Construction', style: text.titleSmall),
          const SizedBox(height: 2),
          Text(constructionLabel(declared),
              key: const Key('construction-declared'), style: text.bodyMedium),
          const SizedBox(height: 2),
          Text(status, key: const Key('construction-status'), style: muted),
          if (offer != LayerConstruction.none)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: OutlinedButton(
                onPressed: () => _useAs(offer),
                child: Text(useAsLabel(offer)),
              ),
            ),
          if (declared != LayerConstruction.none)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _applyConstruction(LayerConstruction.none),
                child: const Text('Remove the label'),
              ),
            ),
          const SizedBox(height: 10),
          Text('Edges, as you sit at the front of the loom', style: text.titleSmall),
          const SizedBox(height: 2),
          Text('Left edge: ${_edgeText(known?.left)}',
              key: const Key('edge-left'), style: text.bodySmall),
          Text('Right edge (warp end 1): ${_edgeText(known?.right)}',
              key: const Key('edge-right'), style: text.bodySmall),
          if (crossNote)
            Text(
                'An open edge stays open unless you cross the wefts of two shuttles there, which '
                'Ply does not record.',
                style: muted),
          if (picks > 0) ...[
            const SizedBox(height: 10),
            Text('Working order', style: text.titleSmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (var p = 0; p < picks && p < _shownPicks; p++)
                  Semantics(
                    label: 'Pick ${p + 1}, ${layerWords(p)}'
                        '${_draft.shuttleAt(p) == null ? ', no shuttle' : ', shuttle ${_draft.shuttleAt(p)}'}'
                        '${starts[p] == null ? ', direction unknown' : ', ${passWords(starts[p]!)}'}',
                    excludeSemantics: true,
                    child: Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${p + 1} ${layerLetter(p)} '
                          '${starts[p] == null ? '?' : passArrow(starts[p]!)}'
                          '${shuttles.length > 1 && _draft.shuttleAt(p) != null ? ' s${_draft.shuttleAt(p)}' : ''}'),
                    ),
                  ),
              ],
            ),
            if (picks > _shownPicks)
              Text('and ${picks - _shownPicks} more picks', style: muted),
            Text(
                'T top layer, B bottom layer, ← right to left, → left to right'
                '${shuttles.length > 1 ? ', s1 shuttle 1' : ''}.',
                style: muted),
            for (final note in directionNotes(_draft)) Text(note, style: muted),
          ],
        ],
      ),
    );
  }

  Widget _layerPanel(BuildContext context, String label, ui.Image? image, String? empty) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(label, style: text.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : empty != null
                      ? Text(empty,
                          textAlign: TextAlign.center,
                          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant))
                      : image != null
                          ? DrawdownView(image)
                          : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}
