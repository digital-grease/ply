import 'package:flutter/material.dart';

import '../rust/dto.dart' show SeverityKind;
import '../rust/nalbind_dto.dart';

/// The findings of one Hansen-notation reading, shown under its text field (the notation playground
/// and a project's notation field share it).
///
/// Problems come first: errors, then warnings, each in source order, each with its severity, the
/// quoted text it is about, and the engine's message. The stitch's validation [issues] join them
/// at their own severity. Formatting notes (`Info`: whitespace, letter case, and the like, which
/// change nothing about the stitch) are collapsed into one quiet line that expands on tap.
class NotationFeedback extends StatefulWidget {
  const NotationFeedback({required this.parsed, this.issues = const [], super.key});

  final ParsedNotationDto parsed;
  final List<NalbindIssueDto> issues;

  /// Longest quote shown before it is shortened (a pasted paragraph would otherwise fill the row).
  static const maxQuote = 40;

  @override
  State<NotationFeedback> createState() => _NotationFeedbackState();
}

enum _Level { error, warning, note }

class _NotationFeedbackState extends State<NotationFeedback> {
  bool _showNotes = false;

  @override
  Widget build(BuildContext context) {
    final diagnostics = widget.parsed.diagnostics;
    Iterable<NotationDiagnosticDto> at(NotationSeverityKind s) =>
        diagnostics.where((d) => d.severity == s);
    Iterable<NalbindIssueDto> issuesAt(SeverityKind s) =>
        widget.issues.where((i) => i.severity == s);
    final notes = at(NotationSeverityKind.info).toList();

    final rows = <Widget>[
      for (final d in at(NotationSeverityKind.error))
        _row(context, _Level.error, d.message, d.text),
      for (final i in issuesAt(SeverityKind.error)) _row(context, _Level.error, i.message, ''),
      for (final d in at(NotationSeverityKind.warning))
        _row(context, _Level.warning, d.message, d.text),
      for (final i in issuesAt(SeverityKind.warning)) _row(context, _Level.warning, i.message, ''),
      if (notes.isNotEmpty) _notesToggle(context, notes.length),
      if (notes.isNotEmpty && _showNotes)
        for (final d in notes) _row(context, _Level.note, d.message, d.text),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  /// One finding: icon, then "Error at "XYZ": message". Text that is only whitespace (or empty) is
  /// not quoted; the message describes it.
  Widget _row(BuildContext context, _Level level, String message, String quote) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (level) {
      _Level.error => (Icons.error_outline, cs.error, 'Error'),
      _Level.warning => (Icons.warning_amber_rounded, cs.tertiary, 'Warning'),
      _Level.note => (Icons.info_outline, cs.onSurfaceVariant, 'Note'),
    };
    final shown = _shorten(quote);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: Theme.of(context).textTheme.bodySmall,
                children: [
                  TextSpan(
                    text: label,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                  if (shown.isNotEmpty) ...[
                    const TextSpan(text: ' at '),
                    TextSpan(
                      text: '"$shown"',
                      style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                    ),
                  ],
                  TextSpan(text: ': $message'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _shorten(String quote) {
    if (quote.trim().isEmpty) return '';
    final chars = quote.characters;
    if (chars.length <= NotationFeedback.maxQuote) return quote;
    return '${chars.take(NotationFeedback.maxQuote - 1)}…';
  }

  /// The collapsed formatting notes. When the notation was accepted, the line also says what it
  /// reads as, since that is all the notes amount to.
  Widget _notesToggle(BuildContext context, int count) {
    final cs = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final p = widget.parsed;
    final noun = count == 1 ? '1 formatting note' : '$count formatting notes';
    final summary =
        p.accepted && p.normalized != p.source ? 'Reads as ${p.normalized} ($noun)' : noun;
    return Semantics(
      button: true,
      expanded: _showNotes,
      child: InkWell(
        onTap: () => setState(() => _showNotes = !_showNotes),
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(child: Text(summary, style: muted)),
              Icon(_showNotes ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
