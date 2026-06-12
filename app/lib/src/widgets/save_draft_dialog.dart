// The shared "Save pattern" metadata dialog: collects a required name + optional author/notes before
// a draft is first persisted to the library. Used by BOTH the import preview (saving an imported WIF)
// and the editor's first save of a from-scratch draft (meta == null). Returns null on Cancel.

import 'package:flutter/material.dart';

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

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameEmpty = true);
      return;
    }
    final author = _author.text.trim();
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
                errorText: _nameEmpty ? 'A name is required' : null,
              ),
              onChanged: (_) {
                if (_nameEmpty) setState(() => _nameEmpty = false);
              },
            ),
            TextField(
              controller: _author,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Author (optional)'),
            ),
            TextField(
              controller: _notes,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
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
