import 'package:flutter/material.dart';

/// A single-field "name this thing" dialog. Returns the trimmed name on confirm, or null on cancel
/// (and null for an empty name, so callers never persist a blank title).
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
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => NameInputDialog(
      title: title,
      confirmLabel: confirmLabel,
      initial: initial,
      fieldLabel: fieldLabel,
    ),
  );
}

class NameInputDialog extends StatefulWidget {
  const NameInputDialog({
    required this.title,
    required this.confirmLabel,
    this.initial = '',
    this.fieldLabel = 'Name',
    super.key,
  });

  final String title;
  final String confirmLabel;
  final String initial;
  final String fieldLabel;

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

  void _submit() {
    final v = _controller.text.trim();
    Navigator.pop(context, v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.fieldLabel),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
