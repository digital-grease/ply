// The parts every craft's tracker shares (ADR 0023): the banner for a place shown for checking, the
// notes pinned to the place and the notes sheet, the log sheet, and the confirmation before clearing
// a project's progress.

import 'package:flutter/material.dart';

import '../models/progress.dart';
import '../state/progress_controller.dart';

/// Words for a place, in the craft's own terms ("pick 12", "row 3, time 2 through the chart").
typedef PlaceWords = String Function(WorkPlace place);

/// An error in words, for a sentence: a progress record's own sentence, or the error's text (never
/// the bare "Instance of ..." a type without words of its own gives).
String errorWords(Object error) => switch (error) {
      ProgressFileException(:final message) => message,
      ProgressLimitException(:final message) => message,
      _ when '$error'.startsWith('Instance of ') => 'an unexpected problem',
      _ => '$error',
    };

/// Why Start again changed nothing, in words: the record's own sentence, or plainly that it could not
/// be put aside.
String startAgainFailedText(Object error) => error is ProgressFileException
    ? error.message
    : 'Ply could not put your place aside on this device, so nothing was changed '
        '(${errorWords(error)}).';

/// A banner above the place: the engine's sentence, and the actions that settle it.
class TrackerBanner extends StatelessWidget {
  const TrackerBanner({
    required this.message,
    this.needsLook = false,
    this.onRight,
    this.onGoTo,
    this.suggestionLabel,
    this.onSuggestion,
    this.onDismiss,
    super.key,
  });

  final String message;

  /// The place needs the crafter to check it (shown in the error colours, with its actions).
  final bool needsLook;
  final VoidCallback? onRight;
  final VoidCallback? onGoTo;
  final String? suggestionLabel;
  final VoidCallback? onSuggestion;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('tracker-banner'),
      margin: EdgeInsets.zero,
      color: needsLook ? cs.errorContainer : cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message,
                style: TextStyle(color: needsLook ? cs.onErrorContainer : cs.onSecondaryContainer)),
            Wrap(
              spacing: 8,
              children: [
                if (onRight != null)
                  TextButton(
                    key: const ValueKey('tracker-right'),
                    onPressed: onRight,
                    child: const Text('This is right'),
                  ),
                if (onSuggestion != null)
                  TextButton(
                    key: const ValueKey('tracker-suggestion'),
                    onPressed: onSuggestion,
                    child: Text(suggestionLabel ?? 'Go to the step you were on'),
                  ),
                if (onGoTo != null) TextButton(onPressed: onGoTo, child: const Text('Go to…')),
                if (onDismiss != null) TextButton(onPressed: onDismiss, child: const Text('OK')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A line saying the last write failed.
class SaveErrorLine extends StatelessWidget {
  const SaveErrorLine(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: cs.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
              child: Text(message,
                  key: const ValueKey('tracker-save-error'), style: TextStyle(color: cs.error))),
        ],
      ),
    );
  }
}

/// The notes pinned to the place on screen, and Add a note.
class NotesHere extends StatelessWidget {
  const NotesHere({required this.controller, super.key});

  final ProgressController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final notes = controller.notesHere;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.sticky_note_2_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(n.text, style: text.bodyMedium)),
              ],
            ),
          ),
        TextButton.icon(
          key: const ValueKey('tracker-add-note'),
          onPressed: () => editNoteDialog(context, controller),
          icon: const Icon(Icons.add_comment_outlined),
          label: const Text('Add a note here'),
        ),
      ],
    );
  }
}

/// Ask for a note's text and add it at the place on screen (or change [note]). Shows the limit's
/// sentence when one is passed.
Future<void> editNoteDialog(BuildContext context, ProgressController controller,
    {ProgressNote? note}) async {
  final saved = await showDialog<String>(
    context: context,
    builder: (_) => _NoteDialog(initial: note?.text ?? '', changing: note != null),
  );
  if (saved == null) return;
  try {
    if (note == null) {
      await controller.addNote(saved);
    } else {
      await controller.editNote(note.id, saved);
    }
  } on ProgressLimitException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// The note's text field; the dialog owns its controller, so it lives as long as the dialog does.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.initial, required this.changing});

  final String initial;
  final bool changing;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.changing ? 'Change the note' : 'Add a note'),
        content: TextField(
          key: const ValueKey('tracker-note-field'),
          controller: _field,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(
            hintText: 'Started the second ball, mended a broken end…',
            helperText: 'At most ${ProgressLimits.maxNoteChars} characters.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('tracker-note-save'),
            onPressed: () => Navigator.of(context).pop(_field.text),
            child: const Text('Save'),
          ),
        ],
      );
}

String _when(BuildContext context, DateTime t) {
  final l = MaterialLocalizations.of(context);
  final local = t.toLocal();
  return '${l.formatShortDate(local)} ${l.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

/// Every note of the project, with where it is pinned; each can be changed or deleted (asked first).
Future<void> showProgressNotes(
    BuildContext context, ProgressController controller, PlaceWords words) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) {
        final notes = controller.progress.notes.reversed.toList();
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text('Notes', style: Theme.of(ctx).textTheme.titleLarge),
                  subtitle: Text('${notes.length} of ${ProgressLimits.maxNotes}'),
                ),
                if (notes.isEmpty)
                  const ListTile(
                      title: Text('No notes yet. Add one at any place you are working.')),
                for (final n in notes)
                  ListTile(
                    title: Text(n.text),
                    subtitle: Text('${words(n.place)}, ${_when(ctx, n.at)}'),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Note actions',
                      onSelected: (a) async {
                        if (a == 'edit') {
                          await editNoteDialog(ctx, controller, note: n);
                        } else {
                          final ok = await showDialog<bool>(
                            context: ctx,
                            builder: (d) => AlertDialog(
                              title: const Text('Delete this note?'),
                              content: Text(n.text),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.of(d).pop(false),
                                    child: const Text('Cancel')),
                                FilledButton(
                                    onPressed: () => Navigator.of(d).pop(true),
                                    child: const Text('Delete')),
                              ],
                            ),
                          );
                          if (ok == true) await controller.deleteNote(n.id);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Change')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// One log entry in words: what was done, between which places.
String logEntryText(LogEntry e, PlaceWords words, String Function(int count) units) {
  final from = words(e.from), to = words(e.to);
  return switch (e.kind) {
    LogKind.worked => 'Worked ${units(e.count)}: $from to $to',
    LogKind.back => 'Went back ${units(e.count)}: $from to $to',
    LogKind.jump => 'Went to $to (from $from)',
    // A place that stayed on its step (found by its id) while the step's number changed.
    LogKind.fix when from == to => 'Place checked at $to after the pattern changed',
    LogKind.fix => 'Place moved to $to because the pattern changed (it was $from)',
  };
}

/// The completion log, newest first.
Future<void> showProgressLog(
    BuildContext context, Progress progress, PlaceWords words, String Function(int count) units) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final entries = progress.log.reversed.toList();
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text('Log', style: Theme.of(ctx).textTheme.titleLarge),
                subtitle: Text(progress.started == null
                    ? 'Nothing worked yet.'
                    : 'Tracking since ${_when(ctx, progress.started!)}'),
              ),
              for (final e in entries)
                ListTile(
                  dense: true,
                  title: Text(logEntryText(e, words, units)),
                  subtitle: Text(e.start == e.end
                      ? _when(ctx, e.start)
                      : '${_when(ctx, e.start)} to ${_when(ctx, e.end)}'),
                ),
              if (progress.logDropped > 0)
                ListTile(
                  dense: true,
                  title: Text('${progress.logDropped} older '
                      '${progress.logDropped == 1 ? 'entry is' : 'entries are'} no longer kept.'),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Ask before clearing a project's place, log and notes.
Future<bool> confirmClearProgress(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Clear your place?'),
      content: const Text(
          'Your place, the log and your notes for this project are deleted. The pattern is not '
          'changed. This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('tracker-clear-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Clear'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// What the tracker shows when the record cannot be used: a newer record (nothing to do but update),
/// or an unreadable one (Start again moves it aside first).
class TrackerRecordProblem extends StatelessWidget {
  const TrackerRecordProblem(
      {required this.message, this.onStartAgain, this.onTryAgain, super.key});

  final String message;
  final VoidCallback? onStartAgain;

  /// Read the record again (the device could not read it just now; it is never moved aside then).
  final VoidCallback? onTryAgain;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message,
                key: const ValueKey('tracker-record-problem'), textAlign: TextAlign.center),
            if (onStartAgain != null) ...[
              const SizedBox(height: 16),
              const Text(
                'Start again keeps the old record aside and starts from the beginning.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('tracker-start-again'),
                onPressed: onStartAgain,
                child: const Text('Start again'),
              ),
            ],
            if (onTryAgain != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('tracker-try-again'),
                onPressed: onTryAgain,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Previous and Next, Next the larger.
class TrackerControls extends StatelessWidget {
  const TrackerControls(
      {required this.onPrevious, required this.onNext, this.nextLabel = 'Next', super.key});

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String nextLabel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            OutlinedButton.icon(
              key: const ValueKey('tracker-previous'),
              onPressed: onPrevious,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Previous'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('tracker-next'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: onNext,
                icon: const Icon(Icons.chevron_right),
                label: Text(nextLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
