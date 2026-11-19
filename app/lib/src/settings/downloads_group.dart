import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:grphoto/l10n/l10n.dart';
import 'package:grphoto/src/data/settings.dart';
import 'package:grphoto/src/pairing/pairing_widgets.dart';
import 'package:grphoto/src/widgets/gr_dialog.dart';
import 'package:grphoto/src/widgets/gr_text_field.dart';
import 'package:grphoto/src/widgets/group.dart';

/// Settings' Downloads group: the photo library album downloads are saved
/// to, which the user can rename.
class DownloadsGroup extends StatelessWidget {
  const new({required this.settings, required this.album, super.key});

  final SettingsController settings;

  /// The album downloads are saved to now: the user's, or the build's own
  /// while they named none.
  final String album;

  Future<void> _rename(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _AlbumNameDialog(initial: album),
    );
    if (name == null) return;
    settings.albumName = name;
  }

  @override
  Widget build(BuildContext context) => GroupBox(
    children: [
      GroupRow(
        key: const Key('setting-album'),
        icon: Icons.photo_album_outlined,
        title: context.l10n.settingsAlbum,
        subtitle: context.l10n.settingsAlbumSubtitle,
        trailing: TrailingFit.value(context, album),
        chevron: true,
        onTap: () => unawaited(_rename(context)),
      ),
    ],
  );
}

class _AlbumNameDialog extends StatefulWidget {
  const new({required this.initial});

  final String initial;

  @override
  State<_AlbumNameDialog> createState() => _AlbumNameDialogState();
}

class _AlbumNameDialogState extends State<_AlbumNameDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final name = cleanAlbumName(_text.text);
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _text,
    builder: (context, _) => GrDialog(
      title: context.l10n.settingsAlbumTitle,
      message: context.l10n.settingsAlbumNote,
      content: GrTextField(
        key: const Key('album-name-field'),
        controller: _text,
        autofocus: true,
        maxLength: 50,
        inputFormatters: [FilteringTextInputFormatter.deny(albumNameForbidden)],
        textCapitalization: TextCapitalization.words,
        onSubmitted: (_) => _save(),
      ),
      actions: [
        GrDialogAction(
          label: context.l10n.commonCancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        GrDialogAction.answer(
          key: const Key('album-name-save'),
          label: context.l10n.settingsAlbumSave,
          onPressed: cleanAlbumName(_text.text).isEmpty ? null : _save,
        ),
      ],
    ),
  );
}
