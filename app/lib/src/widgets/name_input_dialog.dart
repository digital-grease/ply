import 'package:flutter/material.dart';

import '../models/draft_meta.dart';

/// [n] with a comma between thousands: 1,234.
String _thousands(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Why [name] (trimmed, as saved) cannot be a project's name: longer than [DraftMeta.maxNameChars]
/// (ADR 0007: a sidecar's name has a limit where it is entered, so a name pasted by mistake cannot
/// block a backup). Null when it can. Nothing is cut short: the dialog keeps the text and says how
/// long it is, so a name saved before the limit can be shortened by hand when it is renamed.
String? projectNameProblem(String name) => name.length > DraftMeta.maxNameChars
    ? 'Names can be at most ${DraftMeta.maxNameChars} characters '
        '(this one has ${_thousands(name.length)}).'
    : null;

/// Why [author] (trimmed, as saved) cannot be a weaving draft's author: longer than
/// [DraftMeta.maxAuthorChars]. Null when it can.
String? authorProblem(String author) => author.length > DraftMeta.maxAuthorChars
    ? 'The author can be at most ${DraftMeta.maxAuthorChars} characters '
        '(this has ${_thousands(author.length)}).'
    : null;

/// A single-field "name this thing" dialog. Returns the trimmed name on confirm, or null on cancel
/// (and null for an empty name, so callers never persist a blank title). [validator], when given,
/// says why a trimmed name cannot be used (null when it can); the dialog then stays open with the
/// text, so nothing typed is lost.
///
/// It is a [StatefulWidget] on purpose: it OWNS its [TextEditingController] and disposes it in
/// [State.dispose], i.e. only after the dialog route has fully animated out. Creating the controller
/// in a `showDialog` builder and disposing it right after `await showDialog` returns is a latent
/// use-after-dispose — the route's exit transition rebuilds the [TextField] (re-subscribing to the
/// controller) one more time after the future resolves, which throws "used after being disposed".
Future<String?> promptForName(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initial = '',
  String fieldLabel = 'Name',
  String? Function(String name)? validator,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => NameInputDialog(
      title: title,
      confirmLabel: confirmLabel,
      initial: initial,
      fieldLabel: fieldLabel,
      validator: validator,
    ),
  );
}

class NameInputDialog extends StatefulWidget {
  const NameInputDialog({
    required this.title,
    required this.confirmLabel,
    this.initial = '',
    this.fieldLabel = 'Name',
    this.validator,
    super.key,
  });

  final String title;
  final String confirmLabel;
  final String initial;
  final String fieldLabel;
  final String? Function(String name)? validator;

  @override
  State<NameInputDialog> createState() => _NameInputDialogState();
}

class _NameInputDialogState extends State<NameInputDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _problem => widget.validator?.call(_controller.text.trim());

  void _submit() {
    final v = _controller.text.trim();
    if (_problem != null) return;
    Navigator.pop(context, v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration:
            InputDecoration(labelText: widget.fieldLabel, errorText: _problem, errorMaxLines: 3),
        onChanged: widget.validator == null ? null : (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
