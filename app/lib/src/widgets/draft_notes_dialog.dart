// The notes of a saved weaving draft, to read and change after its first save (ADR 0007, amendment
// of 2026-11-18, item 7). The save dialog takes them on a draft's first save; this is how they are
// seen and changed afterwards, from a draft's menu in the weaving library or the editor's overflow
// menu. They live in the draft's sidecar, so changing them never touches the pattern file, never
// marks the draft edited and runs no check. They are Ply's own: not printed, and not the WIF file's
// [NOTES] (which a PDF prints).
//
// Notes within the limit open in an editable field. Notes over it, saved by an earlier build (up to
// megabytes), open in a read-only view laid out a piece at a time, since a text field that large is
// too slow to edit: the weaver can save them in full as a text file, keep the first 10,000
// characters (shown first), clear them (confirmed first), or, when they are not much over, shorten
// them by hand. Nothing is written until one of those is chosen and confirmed.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/draft_repository.dart';
import '../data/library_backup.dart' show BackupPlan;
import '../models/draft_meta.dart';

/// The name of the notes action, in a draft's library menu and the editor's overflow menu.
const String kDraftNotesTitle = 'Notes';

/// What these notes are, said in the notes editor and in Help: Ply's own, apart from the WIF file.
const String kDraftNotesKeptLine =
    'Kept with this draft in Ply and its backups. Not printed, and not part of the WIF file.';

/// The most characters of notes over the limit that can still be shortened by hand in the field;
/// longer ones are too slow to edit there and offer the other choices only.
const int kNotesEditableChars = 50000;

/// Lets the weaver save [bytes] as [fileName] where they choose (the app's save dialog, as for a
/// backup). False when they cancelled.
typedef SaveNotesFile = Future<bool> Function(String fileName, Uint8List bytes);

/// [n] with a comma between thousands: 10,000.
String _thousands(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// How many characters [notes] count for against [DraftMeta.maxNotesChars]: as they are saved,
/// without the spaces and line breaks at either end.
int notesLength(String notes) => notes.trim().length;

/// Whether [notes] are over [DraftMeta.maxNotesChars] (see [notesLength]).
bool notesOverLimit(String notes) => notesLength(notes) > DraftMeta.maxNotesChars;

/// The sentence that refuses notes over [DraftMeta.maxNotesChars], [chars] being how many they
/// have. The save dialog and the notes editor both say it.
String notesTooLongText(int chars) =>
    'Notes can be at most ${_thousands(DraftMeta.maxNotesChars)} characters '
    '(these have ${_thousands(chars)}).';

/// The notes editor's count of [chars] against the limit: "1,234 of 10,000 characters".
String notesCountText(int chars) =>
    '${_thousands(chars)} of ${_thousands(DraftMeta.maxNotesChars)} characters';

bool _isLeadSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// The first [DraftMeta.maxNotesChars] characters of [notes], as saved (without spaces and line
/// breaks at either end), cut only between characters as a reader sees them (grapheme clusters:
/// never inside an emoji written as two code units or joined from several, a flag, or a letter with
/// its accent): what "Keep the first 10,000 characters" keeps. [notes] as saved when they fit.
String keepFirstNotes(String notes) {
  final text = notes.trim();
  if (text.length <= DraftMeta.maxNotesChars) return text;
  // Only the clusters up to the limit are visited, however long the notes.
  final clusters = text.characters.iterator;
  var end = 0;
  while (clusters.moveNext()) {
    final next = end + clusters.current.length;
    if (next > DraftMeta.maxNotesChars) break;
    end = next;
  }
  return text.substring(0, end).trimRight();
}

/// The name a draft's full notes are saved under as a text file: "<draft name> notes.txt".
String notesFileName(String draftName) => '${BackupPlan.safeFileStem(draftName)} notes.txt';

/// [text] cut into pieces of about [size] code units for a view that lays out only the pieces on
/// screen, as (start, end) ranges. A piece ends at a line break in the last half of its [size] when
/// there is one (the break itself falls between pieces), else after a space there, else at [size];
/// never inside a character written as two code units. Each piece looks back over half its [size]
/// at most, so the whole split takes time in proportion to the text, whatever it holds.
List<(int, int)> notesPieces(String text, {int size = 2000}) {
  const lineBreakUnit = 0x0A;
  const spaceUnit = 0x20;
  final pieces = <(int, int)>[];
  var start = 0;
  while (text.length - start > size) {
    final limit = start + size;
    final floor = start + size ~/ 2;
    var lineBreak = -1;
    var space = -1;
    for (var k = limit - 1; k >= floor; k--) {
      final unit = text.codeUnitAt(k);
      if (unit == lineBreakUnit) {
        lineBreak = k;
        break;
      }
      if (space < 0 && unit == spaceUnit) space = k;
    }
    if (lineBreak >= 0) {
      pieces.add((start, lineBreak));
      start = lineBreak + 1;
      continue;
    }
    var end = space >= 0 ? space + 1 : limit;
    if (_isLeadSurrogate(text.codeUnitAt(end - 1))) end--;
    pieces.add((start, end));
    start = end;
  }
  pieces.add((start, text.length));
  return pieces;
}

/// Show [notes], the notes of the draft named [draftName]. Resolves to the notes to save (as saved:
/// without spaces and line breaks at either end, at most [DraftMeta.maxNotesChars] characters), or
/// null when nothing is to be saved (Cancel, or Back with nothing changed or the change discarded).
///
/// Within the limit they open in full in an editable field with a count; Save past the limit stays
/// with the save dialog's sentence, and nothing is ever cut short. Over the limit (saved by an
/// earlier version of Ply) they open read-only, in full, with these choices: save them as a text
/// file through [saveFile], keep the first 10,000 characters (shown before it is confirmed), clear
/// them (confirmed first), or, up to [kNotesEditableChars], shorten them by hand in the field.
/// A tap outside never closes it; Back asks before discarding a change.
Future<String?> showDraftNotesDialog(
  BuildContext context, {
  required String draftName,
  required String notes,
  required SaveNotesFile saveFile,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DraftNotesDialog(draftName: draftName, notes: notes, saveFile: saveFile),
  );
}

/// Read the notes of saved draft [id] (named [draftName]) from [repository], show them (see
/// [showDraftNotesDialog]), and save what the weaver keeps: only the notes are written, only when
/// they changed, and only if they are still the ones read (another notes editor may have changed
/// them meanwhile). Says why in a snack bar when the notes cannot be read or saved, and "Notes
/// saved." when they are. Resolves to whether new notes were saved. The screen that calls it keeps
/// a second call for the same draft from starting while one is under way. [stillWanted], asked once
/// the notes are read (large ones take a moment), stops the dialog from opening when the screen has
/// moved on meanwhile (an editor's save under way).
Future<bool> editDraftNotes(
  BuildContext context,
  DraftRepository repository, {
  required String id,
  required String draftName,
  required SaveNotesFile saveFile,
  bool Function()? stillWanted,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String message) => messenger.showSnackBar(SnackBar(content: Text(message)));
  final String notes;
  final String digest;
  try {
    (:notes, :digest) = await repository.readNotesWithDigest(id);
  } on DraftNotesException catch (e) {
    say(e.message);
    return false;
  } catch (e) {
    say('Could not open the notes: $e');
    return false;
  }
  if (!context.mounted || !(stillWanted?.call() ?? true)) return false;
  final edited =
      await showDraftNotesDialog(context, draftName: draftName, notes: notes, saveFile: saveFile);
  if (edited == null || edited == notes) return false;
  try {
    await repository.setNotes(id, edited, expectedDigest: digest);
  } on DraftNotesException catch (e) {
    say(e.message);
    return false;
  } catch (e) {
    say('Could not save the notes: $e');
    return false;
  }
  say('Notes saved.');
  return true;
}

/// What the notes editor shows: the field, the read-only view of notes over the limit, or one of
/// that view's two confirmations.
enum _View { edit, overLimit, keep, clear }

class _DraftNotesDialog extends StatefulWidget {
  const _DraftNotesDialog({required this.draftName, required this.notes, required this.saveFile});

  final String draftName;
  final String notes;
  final SaveNotesFile saveFile;

  @override
  State<_DraftNotesDialog> createState() => _DraftNotesDialogState();
}

class _DraftNotesDialogState extends State<_DraftNotesDialog> {
  /// The notes in full: no length limit on the field, so nothing is ever cut short.
  late final TextEditingController _notes = TextEditingController(text: widget.notes);
  final ScrollController _scroll = ScrollController();

  /// Notes over the limit, or too long to edit in the field even if most of them is the spaces and
  /// blank lines around them, open read-only.
  late _View _view = notesOverLimit(widget.notes) || widget.notes.length > kNotesEditableChars
      ? _View.overLimit
      : _View.edit;

  /// Whether the refusal shows in the field: from the start for notes already over the limit, and
  /// after a Save over it, until the notes fit again.
  late bool _tooLong = notesOverLimit(widget.notes);

  /// The opened notes' count, and what keeping the first 10,000 characters keeps (worked out only
  /// for notes over the limit).
  late final int _chars = notesLength(widget.notes);
  late final String _kept = keepFirstNotes(widget.notes);
  late final List<(int, int)> _pieces = notesPieces(widget.notes);

  /// Whether the notes themselves are over the limit (not only their spaces and blank lines).
  late final bool _overLimit = notesOverLimit(widget.notes);

  /// The count the read-only view gives: the notes as saved when they are over the limit (as the
  /// refusal counts them), else with the spaces and blank lines that make them so long.
  int get _shownChars => _overLimit ? _chars : widget.notes.length;

  bool _savingFile = false;
  bool _fileSaved = false;
  String? _fileStatus;

  bool get _changed => _notes.text != widget.notes;

  @override
  void dispose() {
    _notes.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _save() {
    if (notesOverLimit(_notes.text)) {
      setState(() => _tooLong = true);
      return;
    }
    Navigator.pop(context, _notes.text.trim());
  }

  Future<void> _saveFile() async {
    // Said in a snack bar instead when the dialog has been closed by the time the file is written
    // (a desktop writes it after its save dialog returns).
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _savingFile = true;
      _fileStatus = null;
    });
    String? status;
    var saved = false;
    try {
      // UTF-8, the notes exactly as they are; a lone surrogate (half of a character written as two
      // code units, which no keyboard types) has no UTF-8 form and is written as U+FFFD.
      saved = await widget.saveFile(
          notesFileName(widget.draftName), Uint8List.fromList(utf8.encode(widget.notes)));
      if (saved) status = 'Saved as a text file.';
    } catch (e) {
      status = 'Could not save the text file: $e';
    }
    if (!mounted) {
      if (!saved && status != null) messenger?.showSnackBar(SnackBar(content: Text(status)));
      return;
    }
    setState(() {
      _savingFile = false;
      _fileSaved = _fileSaved || saved;
      _fileStatus = status;
    });
  }

  Future<bool> _confirmDiscard() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard your changes?'),
          content: const Text('Your changes to the notes are not saved.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      ) ??
      false;

  /// Back: closes when nothing would be lost; asks before discarding a change in the field; from a
  /// confirmation, goes back to the notes.
  Future<void> _onBack(bool didPop, Object? _) async {
    if (didPop) return;
    switch (_view) {
      case _View.keep:
      case _View.clear:
        setState(() => _view = _View.overLimit);
      case _View.edit:
        if (await _confirmDiscard() && mounted) Navigator.pop(context);
      case _View.overLimit:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _view == _View.overLimit || (_view == _View.edit && !_changed),
      onPopInvokedWithResult: _onBack,
      child: switch (_view) {
        _View.edit => _editView(context),
        _View.overLimit => _overLimitView(context),
        _View.keep => _keepView(context),
        _View.clear => _clearView(context),
      },
    );
  }

  Widget _muted(BuildContext context, String text, {int? maxLines}) {
    final theme = Theme.of(context);
    return Text(
      text,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }

  Widget _framed(BuildContext context, Widget child) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      );

  Widget _editView(BuildContext context) {
    final chars = notesLength(_notes.text);
    return AlertDialog(
      title: const Text(kDraftNotesTitle),
      scrollable: true,
      content: SizedBox(
        // Wide enough to read a paragraph on a tablet; a phone narrows it to the screen.
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _muted(context, widget.draftName, maxLines: 2),
            const SizedBox(height: 4),
            _muted(context, kDraftNotesKeptLine),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('draft-notes-field'),
              controller: _notes,
              keyboardType: TextInputType.multiline,
              minLines: 5,
              // Longer notes scroll inside the field.
              maxLines: 12,
              decoration: InputDecoration(
                labelText: kDraftNotesTitle,
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
                counterText: notesCountText(chars),
                errorText: _tooLong ? notesTooLongText(chars) : null,
                errorMaxLines: 3,
              ),
              onChanged: (text) => setState(() {
                if (_tooLong) _tooLong = notesOverLimit(text);
              }),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  Widget _overLimitView(BuildContext context) {
    final max = _thousands(DraftMeta.maxNotesChars);
    return AlertDialog(
      title: const Text(kDraftNotesTitle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _muted(context, widget.draftName, maxLines: 2),
            const SizedBox(height: 4),
            _muted(context, kDraftNotesKeptLine),
            const SizedBox(height: 12),
            Text(_overLimit
                ? 'These notes have ${_thousands(_chars)} characters, more than the $max Ply keeps '
                    'now. They are shown in full below. To keep them all, save them as a text '
                    'file, then choose what the draft keeps.'
                : 'These notes have ${_thousands(_shownChars)} characters with the spaces and '
                    'blank lines around them, too many to edit here. They are shown in full below. '
                    'To keep them all, save them as a text file, then choose what the draft '
                    'keeps.'),
            const SizedBox(height: 8),
            Flexible(
              child: _framed(
                context,
                Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: ListView.builder(
                    key: const ValueKey('draft-notes-full'),
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: _pieces.length,
                    itemBuilder: (_, i) =>
                        Text(widget.notes.substring(_pieces[i].$1, _pieces[i].$2)),
                  ),
                ),
              ),
            ),
            if (_fileStatus != null) ...[
              const SizedBox(height: 8),
              Text(_fileStatus!, key: const ValueKey('draft-notes-file-status')),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: _savingFile ? null : _saveFile,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save as a text file'),
                ),
                // While the text file is being saved, nothing that changes the notes is offered.
                if (widget.notes.length <= kNotesEditableChars)
                  OutlinedButton.icon(
                    onPressed: _savingFile ? null : () => setState(() => _view = _View.edit),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Shorten them by hand'),
                  ),
                OutlinedButton.icon(
                  onPressed: _savingFile ? null : () => setState(() => _view = _View.keep),
                  icon: const Icon(Icons.content_cut),
                  label: Text('Keep the first $max characters'),
                ),
                OutlinedButton.icon(
                  onPressed: _savingFile ? null : () => setState(() => _view = _View.clear),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear notes'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  String get _saveFirst => _fileSaved ? '' : ' Save them as a text file first to keep them all.';

  Widget _keepView(BuildContext context) {
    final removed = _shownChars - _kept.length;
    return AlertDialog(
      title: Text('Keep the first ${_thousands(DraftMeta.maxNotesChars)} characters?'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('The notes become the ${_thousands(_kept.length)} characters below, and the other '
                '${_thousands(removed)} are removed.$_saveFirst'),
            const SizedBox(height: 8),
            Flexible(
              child: _framed(
                context,
                SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: Text(_kept, key: const ValueKey('draft-notes-kept')),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _view = _View.overLimit),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _kept),
          child: const Text('Keep'),
        ),
      ],
    );
  }

  Widget _clearView(BuildContext context) {
    return AlertDialog(
      title: const Text('Clear these notes?'),
      content:
          Text('All ${_thousands(_shownChars)} characters are removed from the notes.$_saveFirst'),
      actions: [
        TextButton(
          onPressed: () => setState(() => _view = _View.overLimit),
          child: const Text('Back'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('Clear'),
        ),
      ],
    );
  }
}
