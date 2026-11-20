// The shared "Save pattern" metadata dialog: collects a required name + optional author/notes before
// a draft is first persisted to the library. Used by BOTH the import preview (saving an imported WIF)
// and the editor's first save of a from-scratch draft (meta == null). Returns null on Cancel.
//
// Every field has a length limit (ADR 0007): the name and author [DraftMeta.maxNameChars] and
// [DraftMeta.maxAuthorChars], the notes [DraftMeta.maxNotesChars]. Past one, Save stays in the
// dialog and says how long the text is; nothing is ever cut short.

import 'package:flutter/material.dart';

import '../models/draft_meta.dart';
import 'draft_notes_dialog.dart' show notesLength, notesOverLimit, notesTooLongText;
import 'name_input_dialog.dart' show authorProblem, projectNameProblem;

/// The result of [showSaveDraftDialog]: a required [name] plus optional [author]/[notes].
class SaveDraftInput {
  const SaveDraftInput({required this.name, this.author, required this.notes});
  final String name;
  final String? author;
  final String notes;
}

/// Prompt for the draft's name (+ optional author/notes), seeded with [initialName]. Resolves to the
/// entered [SaveDraftInput], or null if the user cancels.
Future<SaveDraftInput?> showSaveDraftDialog(
  BuildContext context, {
  required String initialName,
}) {
  return showDialog<SaveDraftInput>(
    context: context,
    builder: (_) => _SaveDraftDialog(initialName: initialName),
  );
}

class _SaveDraftDialog extends StatefulWidget {
  const _SaveDraftDialog({required this.initialName});

  final String initialName;

  @override
  State<_SaveDraftDialog> createState() => _SaveDraftDialogState();
}

class _SaveDraftDialogState extends State<_SaveDraftDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName);
  final TextEditingController _author = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  bool _nameEmpty = false;

  /// Set when Save finds the name over [DraftMeta.maxNameChars]; it is never cut short.
  bool _nameTooLong = false;

  /// Set when Save finds the author over [DraftMeta.maxAuthorChars]; it is never cut short.
  bool _authorTooLong = false;

  /// Set when Save finds the notes over [DraftMeta.maxNotesChars]; they are never cut short.
  bool _notesTooLong = false;

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final author = _author.text.trim();
    final nameTooLong = projectNameProblem(name) != null;
    final authorTooLong = authorProblem(author) != null;
    final notesTooLong = notesOverLimit(_notes.text);
    if (name.isEmpty || nameTooLong || authorTooLong || notesTooLong) {
      setState(() {
        _nameEmpty = name.isEmpty;
        _nameTooLong = nameTooLong;
        _authorTooLong = authorTooLong;
        _notesTooLong = notesTooLong;
      });
      return;
    }
    Navigator.pop(
      context,
      SaveDraftInput(
        name: name,
        author: author.isEmpty ? null : author,
        notes: _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save pattern'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Name',
                errorText: _nameEmpty
                    ? 'A name is required'
                    : _nameTooLong
                        ? projectNameProblem(_name.text.trim())
                        : null,
                errorMaxLines: 3,
              ),
              onChanged: (text) {
                if (_nameEmpty) setState(() => _nameEmpty = false);
                if (_nameTooLong) {
                  setState(() => _nameTooLong = projectNameProblem(text.trim()) != null);
                }
              },
            ),
            TextField(
              controller: _author,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Author (optional)',
                errorText: _authorTooLong ? authorProblem(_author.text.trim()) : null,
                errorMaxLines: 3,
              ),
              onChanged: (text) {
                if (_authorTooLong) {
                  setState(() => _authorTooLong = authorProblem(text.trim()) != null);
                }
              },
            ),
            TextField(
              controller: _notes,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Notes (optional)',
                errorText: _notesTooLong ? notesTooLongText(notesLength(_notes.text)) : null,
                errorMaxLines: 3,
              ),
              onChanged: (text) {
                if (_notesTooLong) setState(() => _notesTooLong = notesOverLimit(text));
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
